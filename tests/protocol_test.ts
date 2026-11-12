import {makeHandler, schemas, type Backend} from '../supabase/functions/matrix-mcp/core.ts';
import type {OperationEvent} from '../supabase/functions/matrix-mcp/telemetry.ts';
const url='https://example.supabase.co/functions/v1/matrix-mcp';
const id='11111111-1111-4111-8111-111111111111';
const secret='PRIVATE_PROTOCOL_CANARY';
function eq(a:unknown,b:unknown){if(a!==b)throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);}
function ok(a:unknown){if(!a)throw new Error('Assertion failed');}
const meta=(version='2026-07-28')=>({'io.modelcontextprotocol/protocolVersion':version,'io.modelcontextprotocol/clientCapabilities':{},'io.modelcontextprotocol/clientInfo':{name:'synthetic',version:'1.0'}});
function request(method:string,params:Record<string,unknown>={},headers:Record<string,string>={},version='2026-07-28'){
  return new Request(url,{method:'POST',headers:{Authorization:'Bearer synthetic','Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':version,'Mcp-Method':method,...(method==='tools/call'?{'Mcp-Name':String(params.name)}:{}),...headers},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params:{...params,_meta:meta(version)}})});
}
function fixture(){
  const events:OperationEvent[]=[];const calls:string[]=[];
  const db=Object.fromEntries(Object.keys(schemas).map(name=>[name,async(_args:unknown)=>{calls.push(name);return {status:'ok',synthetic:true};}])) as Backend;
  return {events,calls,handler:makeHandler(db,async token=>token==='synthetic',url,e=>events.push(e))};
}
Deno.test('2026 discovery succeeds directly without initialize or protocol fallback',async()=>{
  const f=fixture();const response=await f.handler(request('server/discover'));const body=await response.json();
  eq(response.status,200);ok(!body.error);ok(body.result.supportedVersions.includes('2026-07-28'));eq(f.calls.length,0);
  eq(f.events.length,1);eq(f.events[0].method,'server/discover');eq(f.events[0].outcome,'success');eq(f.events[0].protocol_version,'2026-07-28');
});
Deno.test('both protocol eras list the same eight tools and dispatch valid inputs once',async()=>{
  const f=fixture();
  const modern=await f.handler(request('tools/list'));const tools=(await modern.json()).result.tools;
  eq(tools.length,8);
  const payload={event_key:'test:fact:protocol',memory_type:'fact',title:'Synthetic',content:'Synthetic',source:{type:'note'}};
  const args:Record<string,unknown>={search:{query:'synthetic'},resolve_current:{query:'synthetic'},fetch:{id},related:{id},list_recent:{},remember:payload,supersede:{target_id:id,expected_updated_at:'2026-11-12T22:00:00Z',scope:'full',reason:'Synthetic',replacement:payload},status:{}};
  for(const name of Object.keys(args)){
    const r=await f.handler(request('tools/call',{name,arguments:args[name]}));const body=await r.json();
    eq(r.status,200);ok(!body.error);ok(!body.result.isError);eq(body.result.structuredContent?.synthetic,true);eq(f.calls.at(-1),name);
  }
  eq(f.calls.length,8);
  const legacy=await f.handler(new Request(url,{method:'POST',headers:{Authorization:'Bearer synthetic','Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'},body:JSON.stringify({jsonrpc:'2.0',id:10,method:'tools/list'})}));
  eq(legacy.status,200);const oldTools=(await legacy.json()).result.tools;
  eq(JSON.stringify(tools.map((t:any)=>t.name)),JSON.stringify(oldTools.map((t:any)=>t.name)));
});
Deno.test('modern metadata mismatches and unknown future versions fail before backend',async()=>{
  for(const headers of [{'MCP-Protocol-Version':'2025-11-25'},{'Mcp-Method':'tools/list'},{'Mcp-Name':'other'}] as Record<string,string>[]){
    const f=fixture();const r=await f.handler(request('tools/call',{name:'status',arguments:{}},headers));eq(r.status,400);eq(f.calls.length,0);eq(f.events[0].outcome,'rejected');
  }
  const f=fixture();const r=await f.handler(request('server/discover',{}, {},'2099-01-01'));eq(r.status,400);eq(f.events[0].error_code,'PROTOCOL_VERSION');eq(f.calls.length,0);
});
Deno.test('modern requests retain OAuth, origin, secret and owner protections',async()=>{
  for(const headers of [{Authorization:''},{Origin:'https://evil.example'}] as Record<string,string>[]){
    const f=fixture();const r=await f.handler(request('server/discover',{},headers));ok(r.status===401||r.status===403);eq(f.calls.length,0);
  }
  const f=fixture();const payload={event_key:'test:fact:private',memory_type:'fact',title:secret,content:'-----BEGIN PRIVATE KEY-----'+secret,source:{type:'note'}};
  const r=await f.handler(request('tools/call',{name:'remember',arguments:payload}));const body=await r.json();ok(body.error||body.result.isError);eq(f.calls.length,0);ok(!JSON.stringify(f.events).includes(secret));
  const g=fixture();const invalid=await g.handler(request('tools/call',{name:'remember',arguments:{...payload,content:'synthetic',owner_id:id}}));const rejected=await invalid.json();ok(rejected.error||rejected.result.isError);eq(g.calls.length,0);eq(g.events[0].error_code,'INVALID_PARAMS');
});

Deno.test('modern write retries preserve payload and backend idempotency results',async()=>{
  const events:OperationEvent[]=[];let seen='';let created=0;
  const db=Object.fromEntries(Object.keys(schemas).map(name=>[name,async(args:unknown)=>{
    const serialized=JSON.stringify(args);if(seen){eq(serialized,seen);return {status:'existing',same_content:true,memory_id:id};}
    seen=serialized;created++;return {status:'created',memory_id:id};
  }])) as Backend;
  const handler=makeHandler(db,async()=>true,url,e=>events.push(e));
  const params={name:'remember',arguments:{event_key:'test:fact:retry',title:'Synthetic',content:'Synthetic',memory_type:'fact',source:{type:'note'}}};
  for(const status of ['created','existing']){const r=await handler(request('tools/call',params));eq(r.status,200);eq((await r.json()).result.structuredContent.status,status);}
  eq(created,1);eq(events[1].outcome,'existing');
});
