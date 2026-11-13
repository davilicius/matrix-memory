-- The exact private authorizer and public RLS restrictions, with synthetic data.
begin;
insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222');
insert into auth.oauth_clients(id,registration_type,redirect_uris,grant_types,client_name,client_type,token_endpoint_auth_method)
values ('33333333-3333-4333-8333-333333333333','dynamic','https://example.invalid/callback','authorization_code','Synthetic test','public','none');
insert into auth.sessions(id,user_id,oauth_client_id)
values ('44444444-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333');
insert into auth.oauth_consents(id,user_id,client_id,scopes)
values ('55555555-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333','email');
do $$
declare o uuid='11111111-1111-4111-8111-111111111111';c uuid='33333333-3333-4333-8333-333333333333';s uuid='44444444-4444-4444-8444-444444444444';r text;
begin
 assert matrix_private.application_role(o,c,s) is null;
 insert into matrix_private.application_grants(owner_id,client_id,app_role) values(o,c,'reader');
 foreach r in array array['reader','writer','manager'] loop
  update matrix_private.application_grants set app_role=r where owner_id=o and client_id=c;
  assert matrix_private.application_role(o,c,s)=r;
 end loop;
 assert matrix_private.application_role('22222222-2222-4222-8222-222222222222',c,s) is null;
 assert matrix_private.application_role(o,c,o) is null;
 update matrix_private.application_grants set enabled=false where owner_id=o and client_id=c;
 assert matrix_private.application_role(o,c,s) is null;
 update matrix_private.application_grants set enabled=true where owner_id=o and client_id=c;
 update auth.oauth_consents set revoked_at=now() where client_id=c;
 assert matrix_private.application_role(o,c,s) is null;
 update auth.oauth_consents set revoked_at=null where client_id=c;
 update auth.sessions set not_after=now()-interval '1 second' where id=s;
 assert matrix_private.application_role(o,c,s) is null;
 update auth.sessions set not_after=null where id=s;
 update auth.oauth_clients set deleted_at=now() where id=c;
 assert matrix_private.application_role(o,c,s) is null;
 update auth.oauth_clients set deleted_at=null where id=c;
 assert matrix_private.application_role(o,c,s)='manager';
 foreach r in array array['anon','authenticated','service_role'] loop
  assert not has_schema_privilege(r,'matrix_private','usage');
  assert not has_table_privilege(r,'matrix_private.application_grants','select');
  assert not has_table_privilege(r,'matrix_private.application_grants','insert');
  assert not has_function_privilege(r,'matrix_private.application_role(uuid,uuid,uuid)','execute');
 end loop;
 assert not (select prosecdef from pg_proc where oid='matrix_private.application_role(uuid,uuid,uuid)'::regprocedure);
 assert (select count(*)=11 from pg_policies where schemaname='public' and policyname='matrix_oauth_mcp_only' and permissive='RESTRICTIVE');
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
select public.matrix_remember('{"event_key":"access:fact:seed","memory_type":"fact","title":"Synthetic","content":"Synthetic","source":{"type":"note"}}');
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","client_id":"33333333-3333-4333-8333-333333333333"}',true);
do $$
declare t text;rows bigint;
begin
 foreach t in array array['profiles','life_periods','entities','sources','memory_nodes','memory_edges','memory_entities','memory_versions','retrieval_history','legacy_directives','matrix_recall_requests'] loop
  execute format('select count(*) from public.%I',t) into rows;
  assert rows=0,'OAuth Data API reads must not bypass MCP';
 end loop;
 begin
  perform public.matrix_remember('{"event_key":"access:fact:blocked","memory_type":"fact","title":"Synthetic","content":"Must not persist","source":{"type":"note"}}');
  raise exception 'OAuth RPC write bypassed MCP';
 exception when insufficient_privilege then null;end;
 update public.memory_nodes set content='Must not persist';get diagnostics rows=row_count;assert rows=0;
 delete from public.memory_nodes;get diagnostics rows=row_count;assert rows=0;
 begin
  perform matrix_private.application_role(auth.uid(),'33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444');
  raise exception 'Public caller accessed private authorizer';
 exception when insufficient_privilege then null;end;
end $$;
-- The trusted owner transaction used by MCP still sees unchanged content.
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
do $$ begin assert (select content='Synthetic' from public.memory_nodes where event_key='access:fact:seed');end $$;
rollback;
