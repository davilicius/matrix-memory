// Only bounded operational metadata may enter this event. Never pass request bodies,
// raw headers, user-supplied IDs, exception messages, SQL details or memory contents.
// The protocol version is the sole header-derived field, sanitized below.
export const operations = ['search','resolve_current','fetch','related','list_recent','remember','supersede','status'] as const;
const methods = ['server/discover','initialize','ping','tools/list','tools/call','notifications/initialized','notifications/cancelled'] as const;
export type Outcome = 'success'|'empty'|'existing'|'conflict'|'error'|'rejected'|'accepted';
export type AuthFailure = 'AUTH_INVALID'|'AUTH_UNAVAILABLE';
export type ToolObservation = {outcome:Outcome; error_code?:string; duration_ms:number; result_count?:number; retrieval_mode?:'hybrid'|'text_fallback'};
export type OperationEvent = {
  event:'matrix_operation'; schema_version:1; server_version:string; request_id:string;
  application_role?:'reader'|'writer'|'manager'; protocol_version?:string; timestamp:string; batch_index?:number; duration_ms:number; http_status:number; method:string;
  operation:string; outcome:Outcome; error_code?:string; rpc_code?:number;
  tool_duration_ms?:number; result_count?:number; retrieval_mode?:'hybrid'|'text_fallback';
};
export type EventSink = (event:OperationEvent)=>void;
export const consoleSink:EventSink = event=>console.log(JSON.stringify(event));
export function elapsed(start:number){return Math.round(Math.max(0,performance.now()-start)*100)/100;}
export function safeMethod(value:unknown):string{return methods.includes(value as any)?String(value):'unknown';}
export function safeOperation(value:unknown):string{return operations.includes(value as any)?String(value):'unknown';}
export function classifyError(error:unknown):{outcome:Outcome;error_code:string} {
  const code=(error as {code?:unknown})?.code;
  // Explicit list, never echo arbitrary values from a thrown object.
  if(code==='P4090'||code==='P4091')return {outcome:'conflict',error_code:code};
  if(['P4040','22023','23505','23503','42501','57014','55P03','53300','57P01','08006','CONNECT_TIMEOUT','CONNECTION_CLOSED'].includes(code as string))return {outcome:'error',error_code:String(code)};
  const message=error instanceof Error?error.message:'';
  if(message==='Recuerdo no encontrado.')return {outcome:'error',error_code:'NOT_FOUND'};
  if(message==='Cursor inválido.')return {outcome:'rejected',error_code:'INVALID_CURSOR'};
  if(message==='No guardar credenciales ni claves privadas en Matrix.')return {outcome:'rejected',error_code:'SECRET_REJECTED'};
  return {outcome:'error',error_code:'BACKEND_ERROR'};
}
export function resultObservation(name:string,result:any):Omit<ToolObservation,'duration_ms'> {
  const rows=name==='search'?result?.hits:name==='resolve_current'?[...(result?.current_candidates??[]),...(result?.needs_review??[]),...(result?.historical_candidates??[])]:name==='list_recent'?result?.items:name==='related'?result?.memories:undefined;
  const observation:Omit<ToolObservation,'duration_ms'>={outcome:'success'};
  if(Array.isArray(rows)){observation.result_count=rows.length;if(!rows.length)observation.outcome='empty';}
  if((name==='remember'||name==='supersede')&&result?.status==='existing'){
    observation.outcome='existing';
    if(result.same_content===false||result.same_operation===false){observation.outcome='conflict';observation.error_code='EXISTING_CONTENT_MISMATCH';}
  }
  if(result?.mode==='hybrid'||result?.mode==='text_fallback')observation.retrieval_mode=result.mode;
  return observation;
}

export function safeProtocolVersion(value:string|null):string {
  if(value===null)return 'absent';
  return /^20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/.test(value)?value:'invalid';
}
