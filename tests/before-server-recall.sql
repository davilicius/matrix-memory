-- Reproduce the old zero-hit bug after table grants but before owner-scope fix.
begin;
insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111');
set local role service_role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare result jsonb;
begin
  perform public.matrix_remember('{"owner_id":"11111111-1111-4111-8111-111111111111","event_key":"before-owner","memory_type":"fact","title":"Regresion","content":"Regresion","source":{"type":"conversation"}}');
  result := public.matrix_recall('{"owner_id":"11111111-1111-4111-8111-111111111111","query":"regresion"}');
  assert jsonb_array_length(result->'hits') = 0, 'Expected old zero-hit bug before owner-scope patch';
  assert (select count(*) from public.memory_nodes) = 1, 'Missing regression fixture';
end $$;
reset role;
rollback;
