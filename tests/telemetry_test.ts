import {makeHandler, schemas, type Backend} from '../supabase/functions/matrix-mcp/core.ts';
import {makeOAuthVerifier} from '../supabase/functions/matrix-mcp/oauth.ts';
import {type OperationEvent, type AuthFailure} from '../supabase/functions/matrix-mcp/telemetry.ts';
function eq(a:unknown,b:unknown){if(a!==b)throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);}
function ok(a:unknown){if(!a)throw new Error('Assertion failed');}
const resource='https://example.supabase.co/functions/v1/matrix-mcp';
const marker='PRIVATE_CANARY_DO_NOT_LOG';
const headers={Authorization:'Bearer '+marker,'Content-Type':'application/json',Accept:'application/json, text/event-stream'};
const call=(name:string,args:unknown={})=>({jsonrpc:'2.0',id:marker,method:'tools/call',params:{name,arguments:args}});
const request=(body:unknown,override:Record<string,string>={})=>new Request(resource+'?private='+marker,{method:'POST',headers:{...headers,...override},body:JSON.stringify(body)});
function fixture(fn:Backend['search']=async()=>({ok:true}),auth:(t:string,r?:(v:AuthFailure)=>void)=>Promise<boolean>=async()=>true){
  const events:OperationEvent[]=[];let calls=0;
  const db=Object.fromEntries(Object.keys(schemas).map(k=>[k,async(args:unknown)=>{calls++;return await fn(args);}])) as Backend;
  const handler=makeHandler(db,auth,resource,e=>events.push(e));
  return {events,handler,calls:()=>calls};
}
function last(events:OperationEvent[],response:Response){
  eq(events.length,1);const e=events[0];
  ok(/^[0-9a-f-]{36}$/.test(e.request_id));eq(response.headers.get('X-Matrix-Request-Id'),e.request_id);
  eq(e.http_status,response.status);ok(e.duration_ms>=0);eq(e.server_version,'1.5.0');
  ok(!JSON.stringify(e).includes(marker));return e;
}

Deno.test('telemetry captures success, empty retrieval and fallback without query/results',async()=>{
  for(const [name,args,result,count,outcome] of [
    ['search',{query:marker},{hits:[{content:marker}],mode:'hybrid'},1,'success'],
    ['search',{query:marker},{hits:[],mode:'text_fallback'},0,'empty'],
    ['resolve_current',{query:marker},{current_candidates:[],needs_review:[{content:marker}],historical_candidates:[],mode:'hybrid'},1,'success'],
    ['list_recent',{}, {items:[]},0,'empty'],
    ['related',{id:'11111111-1111-4111-8111-111111111111'},{memories:[]},0,'empty'],
  ] as const){
    const f=fixture(async()=>result);const res=await f.handler(request(call(name,args)));
    const e=last(f.events,res);eq(e.operation,name);eq(e.outcome,outcome);eq(e.result_count,count);ok(e.tool_duration_ms!<=e.duration_ms);
  }
});
Deno.test('telemetry distinguishes new write, exact retry and conflicting duplicate',async()=>{
  const args={event_key:'test:fact:telemetry',title:marker,content:marker,memory_type:'fact',source:{type:'note'}};
  for(const [result,outcome] of [[{status:'created'},'success'],[{status:'existing',same_content:true},'existing'],[{status:'existing',same_content:false},'conflict']] as const){
    const f=fixture(async()=>result);const res=await f.handler(request(call('remember',args)));eq(last(f.events,res).outcome,outcome);eq(f.calls(),1);
  }
});
Deno.test('telemetry classifies DB errors with allowlisted codes and no raw exceptions',async()=>{
  for(const [code,outcome,expected] of [['P4090','conflict','P4090'],['57014','error','57014'],[marker,'error','BACKEND_ERROR']] as const){
    const f=fixture(async()=>{throw Object.assign(new Error(marker),{code,detail:marker});});
    const res=await f.handler(request(call('status')));const e=last(f.events,res);eq(e.outcome,outcome);eq(e.error_code,expected);eq(res.status,200);ok((await res.json()).result.isError);
  }
});
Deno.test('SDK failures before callback are logged including HTTP 200 validation errors',async()=>{
  for(const [body,code] of [[call('search',{query:marker,limit:10000}),'INVALID_PARAMS'],[call(marker),'UNKNOWN_TOOL'],[{jsonrpc:'2.0',id:marker,method:marker},'UNKNOWN_METHOD']] as const){
    const f=fixture();const res=await f.handler(request(body));const e=last(f.events,res);eq(e.error_code,code);eq(e.outcome,'rejected');eq(f.calls(),0);
  }
});
Deno.test('invalid JSON and protocol rejection receive structured logs',async()=>{
  const f=fixture();const res=await f.handler(new Request(resource,{method:'POST',headers,body:'{'+marker}));
  eq(last(f.events,res).error_code,'INVALID_JSON');eq(f.calls(),0);
  const g=fixture();const r=await g.handler(request(call('status'),{Accept:'text/plain'}));
  eq(last(g.events,r).error_code,'NOT_ACCEPTABLE');eq(g.calls(),0);
  const h=fixture();const malformed=await h.handler(request({private:marker}));eq(last(h.events,malformed).error_code,'INVALID_RPC');
  const i=fixture();const protocol=await i.handler(request(call('status'),{'MCP-Protocol-Version':marker}));eq(last(i.events,protocol).error_code,'PROTOCOL_METADATA_INVALID');eq(i.calls(),0);
});
Deno.test('HTTP guards, auth rejection and unexpected failures all emit one safe event',async()=>{
  for(const [override,status,code] of [[{Origin:'https://'+marker+'.invalid'},403,'ORIGIN_DENIED'],[{'Content-Type':'text/plain'},415,'CONTENT_TYPE']] as const){
    const f=fixture();const r=await f.handler(request({},override));const e=last(f.events,r);eq(r.status,status);eq(e.error_code,code);eq(f.calls(),0);
  }
  for(const reason of ['AUTH_INVALID','AUTH_UNAVAILABLE'] as const){
    const f=fixture(undefined,async(_t,report)=>{report?.(reason);return false;});const r=await f.handler(request({}));eq(r.status,401);eq(last(f.events,r).error_code,reason);
  }
  const f=fixture(undefined,async()=>{throw new Error(marker);});const r=await f.handler(request({}));eq(r.status,500);eq(last(f.events,r).error_code,'REQUEST_FAILED');
});
Deno.test('oversized and empty bodies and rate limiting are observable',async()=>{
  const f=fixture();const r=await f.handler(request({text:marker+'x'.repeat(131073)}));eq(last(f.events,r).error_code,'BODY_TOO_LARGE');
  const g=fixture();const r2=await g.handler(new Request(resource,{method:'POST',headers}));eq(last(g.events,r2).error_code,'EMPTY_BODY');
  const h=fixture();
  for(let n=0;n<120;n++)await h.handler(request({}, {'Content-Type':'text/plain'}));
  h.events.length=0;
  const r3=await h.handler(request({}));eq(last(h.events,r3).error_code,'RATE_LIMITED');eq(r3.status,429);
});
Deno.test('secret rejection logs no credential and never reaches backend',async()=>{
  const f=fixture();const r=await f.handler(request(call('remember',{event_key:'test:fact:secret',title:marker,content:'-----BEGIN PRIVATE KEY-----'+marker,memory_type:'fact',source:{type:'note'}})));
  eq(last(f.events,r).error_code,'SECRET_REJECTED');eq(f.calls(),0);ok(!JSON.stringify(f.events).includes('PRIVATE KEY'));
});
Deno.test('concurrent requests have independent IDs and outcomes; logging failure cannot change writes',async()=>{
  const f=fixture(async(args)=>({hits:args.query==='empty'?[]:[{content:marker}]}));
  const rs=await Promise.all([f.handler(request(call('search',{query:'empty'}))),f.handler(request(call('search',{query:marker})))]);
  eq(new Set(f.events.map(e=>e.request_id)).size,2);eq(f.events.filter(e=>e.outcome==='empty').length,1);
  for(const r of rs)ok(f.events.some(e=>e.request_id===r.headers.get('X-Matrix-Request-Id')));
  let writes=0;
  const db=Object.fromEntries(Object.keys(schemas).map(k=>[k,async(_args:unknown)=>{writes++;return {status:'created'};}])) as Backend;
  const handler=makeHandler(db,async()=>true,resource,()=>{throw new Error(marker);});
  const r=await handler(request(call('remember',{event_key:'test:fact:committed',title:marker,content:marker,memory_type:'fact',source:{type:'note'}})));
  eq(r.status,200);eq((await r.json()).result.structuredContent.status,'created');eq(writes,1);
});
Deno.test('OAuth reports infrastructure failures separately from invalid or malformed tokens',async()=>{
  const owner='11111111-1111-4111-8111-111111111111';const url='https://example.supabase.co';
  const token='test.'+btoa(JSON.stringify({sub:owner,iss:url+'/auth/v1',role:'authenticated',aud:'authenticated',client_id:'test-client',session_id:'test-session',exp:Date.now()/1000+300}))+'.test';
  for(const [status,expected] of [[401,'AUTH_INVALID'],[500,'AUTH_UNAVAILABLE'],[429,'AUTH_UNAVAILABLE']] as const){
    const verify=makeOAuthVerifier(url,'synthetic',owner,(async()=>new Response('',{status})) as typeof fetch);
    let code='';eq(await verify(token,c=>{code=c;}),false);eq(code,expected);
  }
  const verify=makeOAuthVerifier(url,'synthetic',owner,(async()=>{throw new Error(marker);}) as typeof fetch);
  let code='';eq(await verify(token,c=>{code=c;}),false);eq(code,'AUTH_UNAVAILABLE');
  eq(await verify('test.%%%malformed.test',c=>{code=c;}),false);eq(code,'AUTH_INVALID');
});

Deno.test('batch requests preserve each operation outcome including SDK validation',async()=>{
  const f=fixture(async(args)=>({hits:args.query==='empty'?[]:[{content:marker}]}));
  const bodies=[call('search',{query:'empty'}),call('search',{query:marker}),call('search',{limit:10000}),call(marker)];
  const r=await f.handler(request(bodies.map((body,index)=>({...body,id:index}))));
  eq(r.status,200);eq(f.events.length,4);eq(f.calls(),2);
  const events=f.events.sort((a,b)=>a.batch_index!-b.batch_index!);
  eq(events[0].outcome,'empty');eq(events[1].outcome,'success');eq(events[2].error_code,'INVALID_PARAMS');eq(events[3].error_code,'UNKNOWN_TOOL');
  eq(new Set(events.map(e=>e.request_id)).size,1);ok(!JSON.stringify(events).includes(marker));
});

Deno.test('protocol diagnostics keep only bounded date versions, never arbitrary header contents',async()=>{
  for(const value of ['2026-07-28','2025-11-25',marker,'2026-99-99','x'.repeat(2000)]){
    const f=fixture();const r=await f.handler(request(call('status'),{'MCP-Protocol-Version':value}));
    const e=last(f.events,r);eq(e.protocol_version,value==='2026-07-28'||value==='2025-11-25'?value:'invalid');
  }
  const f=fixture();const r=await f.handler(request(call('status')));eq(last(f.events,r).protocol_version,'absent');
});
