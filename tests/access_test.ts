import { makeHandler, schemas, type Backend } from '../supabase/functions/matrix-mcp/core.ts';
import { permittedCall, type AppRole, type AppAuthorizer } from '../supabase/functions/matrix-mcp/access.ts';
import type { OperationEvent } from '../supabase/functions/matrix-mcp/telemetry.ts';
const url='https://example.supabase.co/functions/v1/matrix-mcp';
const identity={clientId:'11111111-1111-4111-8111-111111111111',sessionId:'22222222-2222-4222-8222-222222222222'};
const payload={event_key:'test:fact:access',memory_type:'fact',title:'Synthetic',content:'Synthetic',source:{type:'note'}};
function eq(a:unknown,b:unknown){if(JSON.stringify(a)!==JSON.stringify(b))throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);}
function request(method:string,params:Record<string,unknown>={},modern=true){return new Request(url,{method:'POST',headers:{Authorization:'Bearer synthetic','Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':modern?'2026-07-28':'2025-11-25',...(modern?{'Mcp-Method':method,...(method==='tools/call'?{'Mcp-Name':String(params.name)}:{})}:{})},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params:{...params,...(modern?{_meta:{'io.modelcontextprotocol/protocolVersion':'2026-07-28','io.modelcontextprotocol/clientCapabilities':{},'io.modelcontextprotocol/clientInfo':{name:'synthetic',version:'1'},...(params._meta as Record<string,unknown>??{})}}:{})}})});}
function fixture(authorize?:AppAuthorizer){
 const calls:string[]=[];const events:OperationEvent[]=[];
 const db=Object.fromEntries(Object.keys(schemas).map(name=>[name,async(_args:unknown)=>{calls.push(name);return {status:'ok',permissions:['all']};}])) as Backend;
 return {calls,events,handler:makeHandler(db,async()=>identity,url,e=>events.push(e),authorize)};
}
Deno.test('application grants deny by default and unavailable authorization fails closed',async()=>{
 for(const authorize of [undefined,async()=>null,async()=>{throw new Error('PRIVATE_DB_DETAILS');}]){
  const f=fixture(authorize);const r=await f.handler(request('tools/call',{name:'status',arguments:{}}));
  eq(r.status,authorize?.toString().includes('throw')?503:403);eq(f.calls,[]);
  eq(JSON.stringify(f.events).includes('PRIVATE_DB_DETAILS'),false);
  eq(JSON.stringify(f.events).includes(identity.clientId),false);
 }
});
Deno.test('reader, writer and manager catalogs and calls enforce roles in both protocols',async()=>{
 for(const role of ['reader','writer','manager'] as AppRole[])for(const modern of [true,false]){
  const f=fixture(async()=>role);
  const list=await f.handler(request('tools/list',{},modern));const tools=(await list.json()).result.tools.map((t:any)=>t.name);
  eq(tools.length,role==='reader'?6:role==='writer'?7:8);
  const status=await f.handler(request('tools/call',{name:'status',arguments:{}},modern));const result=(await status.json()).result.structuredContent;
  eq(result.application_role,role);eq([...result.permissions].sort(),[...tools].sort());
  const args:Record<string,unknown>={search:{query:'synthetic'},resolve_current:{query:'synthetic'},fetch:{id:identity.clientId},related:{id:identity.clientId},list_recent:{},remember:payload,supersede:{target_id:identity.clientId,expected_updated_at:'2026-11-12T00:00:00Z',scope:'full',reason:'Synthetic',replacement:payload}};
  for(const [name,arguments_] of Object.entries(args)){
   const before=f.calls.length;const allowed=tools.includes(name);
   const r=await f.handler(request('tools/call',{name,arguments:arguments_},modern));eq(r.status,allowed?200:403);eq(f.calls.length,before+Number(allowed));
   if(!allowed)eq(f.events.at(-1)?.error_code,'PERMISSION_DENIED');
  }
 }
});
Deno.test('writer cannot substitute through remember relations or reserved metadata',async()=>{
 const f=fixture(async()=> 'writer');
 for(const extra of [{relations:[{type:'supersedes',target_node_id:identity.clientId}]},{metadata:{_matrix_supersession:{fake:true}}}]){
  eq((await f.handler(request('tools/call',{name:'remember',arguments:{...payload,...extra}}))).status,403);
 }
 eq(f.calls,[]);
 eq(permittedCall('writer','remember',{...payload,relations:[{type:'related_to',target_node_id:identity.clientId}]}),true);
});
Deno.test('mixed legacy batch is rejected before its first write when a later call is forbidden',async()=>{
 const f=fixture(async()=> 'writer');
 const req=request('tools/list',{},false);
 const body=[{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'remember',arguments:payload}},{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'supersede',arguments:{}}}];
 eq((await f.handler(new Request(url,{method:'POST',headers:req.headers,body:JSON.stringify(body)}))).status,403);eq(f.calls,[]);
});
Deno.test('grant changes take effect on the next request and never share roles between clients',async()=>{
 let role:AppRole|null='manager';const f=fixture(async id=>{eq(id,identity);return role;});
 eq((await f.handler(request('tools/list'))).status,200);role='reader';
 eq((await f.handler(request('tools/call',{name:'remember',arguments:payload}))).status,403);role=null;
 eq((await f.handler(request('server/discover'))).status,403);eq(f.calls,[]);
});
Deno.test('invalid authentication never invokes application authorization',async()=>{
 let called=false;const handler=makeHandler({} as Backend,async()=>false,url,()=>{},async()=>{called=true;return 'manager';});
 eq((await handler(request('server/discover'))).status,401);eq(called,false);
});
Deno.test('concurrent clients cannot borrow another client role or body-supplied identity',async()=>{
 const other={clientId:'33333333-3333-4333-8333-333333333333',sessionId:'44444444-4444-4444-8444-444444444444'};
 let writes=0;const events:OperationEvent[]=[];
 const db=Object.fromEntries(Object.keys(schemas).map(name=>[name,async(_args:unknown)=>{if(name==='remember')writes++;return {ok:true};}])) as Backend;
 const handler=makeHandler(db,async token=>token==='writer'?other:identity,url,e=>events.push(e),async id=>id.clientId===other.clientId?'writer':'reader');
 const readReq=request('tools/call',{name:'remember',arguments:payload,_meta:{client_id:other.clientId,application_role:'manager'}});
 const writeReq=request('tools/call',{name:'remember',arguments:payload});writeReq.headers.set('Authorization','Bearer writer');
 const [a,b]=await Promise.all([handler(readReq),handler(writeReq)]);eq(a.status,403);eq(b.status,200);eq(writes,1);
 eq(events.filter(e=>e.application_role==='reader'&&e.error_code==='PERMISSION_DENIED').length,1);
});
