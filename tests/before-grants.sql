begin;
insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111');
set local role service_role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
begin
  begin
    perform public.matrix_remember('{"owner_id":"11111111-1111-4111-8111-111111111111","event_key":"before","memory_type":"fact","title":"Synthetic","content":"Synthetic","source":{"type":"conversation"}}');
    raise exception 'Expected missing table GRANT before patch';
  exception when insufficient_privilege then
    raise notice 'Reproduced pre-patch failure: %', sqlerrm;
  end;
end $$;
reset role;
rollback;
