import { makeHandler } from './manager-fixture.ts';
const assert = {
  equal(actual: unknown, expected: unknown, message = 'Values differ') {
    if (actual !== expected) throw new Error(message);
  },
  deepEqual(actual: unknown, expected: unknown) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Objects differ');
  },
  ok(value: unknown) { if (!value) throw new Error('Expected truthy value'); },
  throws(fn: () => unknown) {
    try { fn(); } catch { return; }
    throw new Error('Expected exception');
  },
};
import { makeOAuthVerifier } from '../supabase/functions/matrix-mcp/oauth.ts';
import { readConfig } from '../supabase/functions/matrix-mcp/config.ts';
import {  schemas, rejectSecrets, type Backend } from '../supabase/functions/matrix-mcp/core.ts';

const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const url = 'https://example.supabase.co';
function token(overrides: Record<string, unknown> = {}) {
  const claims = { sub: owner, iss: url + '/auth/v1', role: 'authenticated', aud: 'authenticated', client_id: owner, session_id: other, exp: Date.now() / 1000 + 300, ...overrides };
  return 'test.' + btoa(JSON.stringify(claims)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '') + '.test';
}

Deno.test('OAuth requires verified session, configured owner and OAuth client', async () => {
  let calls = 0;
  const fetcher = (async (input, init) => {
    calls++;
    assert.equal(input, url + '/auth/v1/user');
    assert.ok(new Headers(init?.headers).get('Authorization')?.startsWith('Bearer '));
    return Response.json({ id: owner, is_anonymous: false });
  }) as typeof fetch;
  const verify = makeOAuthVerifier(url, 'test-api-key', owner, fetcher);
  assert.deepEqual(await verify(token()), {clientId:owner,sessionId:other});
  for (const invalid of [{ sub: other }, { iss: 'https://wrong.example/auth/v1' }, { role: 'service_role' }, { aud: 'other' }, { client_id: undefined }, { session_id: undefined }, { exp: 1 }]) {
    assert.equal(await verify(token(invalid)), false);
  }
  assert.equal(await verify('ordinary-api-key'), false);
  assert.equal(calls, 1, 'Invalid claims must be rejected before Auth');
  for (const response of [Response.json({}, { status: 401 }), Response.json({ id: other }), Response.json({ id: owner, is_anonymous: true })]) {
    const rejected = makeOAuthVerifier(url, 'test-api-key', owner, (async () => response) as typeof fetch);
    assert.equal(await rejected(token()), false);
  }
  const unavailable = makeOAuthVerifier(url, 'test-api-key', owner, (async () => { throw new Error('offline'); }) as typeof fetch);
  assert.equal(await unavailable(token()), false);
});

Deno.test('configuration fails closed without an owner and never embeds deployment identity', () => {
  const env: Record<string, string> = { MATRIX_OWNER_ID: owner, SUPABASE_URL: url + '/', SUPABASE_ANON_KEY: 'test-key', SUPABASE_DB_URL: 'postgres://test' };
  assert.equal(readConfig(k => env[k]).url, url);
  for (const key of Object.keys(env)) assert.throws(() => readConfig(k => k === key ? undefined : env[k]));
  assert.throws(() => readConfig(k => k === 'MATRIX_OWNER_ID' ? 'invalid' : env[k]));
  assert.throws(() => readConfig(k => k === 'SUPABASE_URL' ? 'https://user:pass@example.com' : env[k]));
});

Deno.test('tool inputs reject owner override and retain idempotency contract', () => {
  const payload = { event_key: 'test:fact:one', memory_type: 'fact', title: 'Test', content: 'Synthetic', source: { type: 'testimony' } };
  assert.equal(schemas.remember.parse(payload).event_key, payload.event_key);
  assert.throws(() => schemas.remember.parse({ ...payload, owner_id: other }));
  assert.throws(() => schemas.remember.parse({ ...payload, lifecycle_status: 'archived' }));
  assert.throws(() => schemas.search.parse({ query: 'test', limit: 1000 }));
  assert.throws(() => rejectSecrets({ content: '-----BEGIN PRIVATE KEY-----' }));
});

Deno.test('HTTP boundary rejects unauthorized requests and routes authenticated tools', async () => {
  let searches = 0;
  const db = Object.fromEntries(Object.keys(schemas).map(k => [k, async (args: unknown) => {
    if (k === 'search') searches++;
    return { ok: true, args };
  }])) as Backend;
  const resource = url + '/functions/v1/matrix-mcp';
  const handler = makeHandler(db, async t => t === 'valid', resource);
  const request = (body: unknown, headers: Record<string, string> = {}, method = 'POST') => new Request(resource, { method, headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', Authorization: 'Bearer valid', ...headers }, ...(method === 'POST' ? { body: JSON.stringify(body) } : {}) });
  const metadata = await handler(new Request(resource + '/oauth-protected-resource'));
  assert.deepEqual((await metadata.json()).authorization_servers, [url + '/auth/v1']);
  assert.equal((await handler(request({}, { Authorization: '' }))).status, 401);
  assert.equal((await handler(request({}, { Origin: 'https://evil.example' }))).status, 403);
  assert.equal((await handler(request({}, {}, 'GET'))).status, 405);
  assert.equal((await handler(request({}, { 'Content-Type': 'text/plain' }))).status, 415);
  assert.equal((await handler(request({ text: 'x'.repeat(131073) }))).status, 413);
  const list = await handler(request({ jsonrpc: '2.0', id: 1, method: 'tools/list' }));
  assert.equal(list.status, 200);
  const listed = await list.json();
  assert.equal(listed.result.tools.length, 8);
  const response = await handler(request({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'search', arguments: { query: 'synthetic' } } }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).result.structuredContent.ok, true);
  assert.equal(searches, 1);
});

Deno.test('supersede validates scope, exact target timestamp and forbids nested identity or extra replacements', () => {
  const request={target_id:owner,expected_updated_at:'2026-11-12T18:00:00.123456Z',scope:'partial',reason:'Only the deadline changed',
    replacement:{event_key:'test:decision:replacement',memory_type:'decision',title:'Updated',content:'New deadline',source:{type:'note'}}};
  assert.equal(schemas.supersede.parse(request).expected_updated_at,request.expected_updated_at);
  for(const invalid of [{scope:'unknown'},{reason:''},{expected_updated_at:undefined},{owner_id:other},
    {replacement:{...request.replacement,owner_id:other}},
    {replacement:{...request.replacement,relations:[{type:'supersedes',target_node_id:other}]}},
    {replacement:{...request.replacement,metadata:{_matrix_supersession:{request_hash:'fake'}}}}]) {
    assert.throws(()=>schemas.supersede.parse({...request,...invalid}));
  }
});

Deno.test('supersede routes once, protects secrets and returns actionable conflict errors without data leaks',async()=>{
  let calls=0; let code='';
  const db=Object.fromEntries(Object.keys(schemas).map(k=>[k,async(_args:unknown)=>{
    if(k==='supersede')calls++;
    if(code)throw Object.assign(new Error('private database details'),{code});
    return {status:'created',memory_id:other};
  }])) as Backend;
  const resource=url+'/functions/v1/matrix-mcp';
  const handler=makeHandler(db,async t=>t==='valid',resource);
  const invoke=async(args:unknown)=>{
    const response=await handler(new Request(resource,{method:'POST',headers:{Authorization:'Bearer valid','Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'supersede',arguments:args}})}));
    return (await response.json()).result;
  };
  const args={target_id:owner,expected_updated_at:'2026-11-12T18:00:00.123456Z',scope:'full',reason:'Changed',replacement:{event_key:'test:decision:replacement',memory_type:'decision',title:'Updated',content:'New decision',source:{type:'note'}}};
  assert.equal((await invoke(args)).structuredContent.status,'created');
  assert.equal(calls,1);
  assert.equal((await invoke({...args,replacement:{...args.replacement,content:'-----BEGIN PRIVATE KEY-----'}})).isError,true);
  assert.equal(calls,1);
  for(code of ['P4090','P4091','P4040','22023']){
    const result=await invoke(args);
    assert.equal(result.isError,true);
    assert.ok(!JSON.stringify(result).includes('private database details'));
    assert.ok(!JSON.stringify(result).includes('reintentar el guardado'));
  }
});
