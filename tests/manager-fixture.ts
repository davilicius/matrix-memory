import { makeHandler as handler, type Backend } from '../supabase/functions/matrix-mcp/core.ts';
import type { AuthFailure, EventSink } from '../supabase/functions/matrix-mcp/telemetry.ts';
export function makeHandler(db:Backend, authenticate:(t:string,r?:(v:AuthFailure)=>void)=>Promise<boolean>,resource:string,sink?:EventSink){
 return handler(db,async(t,r)=>await authenticate(t,r)?{clientId:'11111111-1111-4111-8111-111111111111',sessionId:'22222222-2222-4222-8222-222222222222'}:false,resource,sink,async()=> 'manager');
}
