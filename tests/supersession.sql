-- Synthetic data only. The whole suite rolls back, including fault injection.
begin;
insert into auth.users(id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

do $$ begin
  assert not (select prosecdef from pg_proc where oid='public.matrix_supersede(jsonb)'::regprocedure);
  assert not has_function_privilege('anon','public.matrix_supersede(jsonb)','execute');
  assert not has_function_privilege('service_role','public.matrix_supersede(jsonb)','execute');
  assert has_function_privilege('authenticated','public.matrix_supersede(jsonb)','execute');
end $$;

create function pg_temp.fail_supersession_test() returns trigger language plpgsql as $$
begin
  if old.event_key = 'atomic:old:abort' then raise exception using errcode='P7777', message='Synthetic late failure'; end if;
  return new;
end $$;
create trigger zz_atomic_fault before update on public.memory_nodes
  for each row execute function pg_temp.fail_supersession_test();

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
do $$
declare
  old_id uuid; partial_id uuid; abort_id uuid; foreign_id uuid; result jsonb;
  request jsonb; partial_request jsonb; abort_request jsonb; replacement jsonb;
  before_nodes bigint; before_sources bigint; before_edges bigint; before_versions bigint;
begin
  replacement := '{"event_key":"atomic:new:full","memory_type":"decision","title":"New decision","content":"Synthetic new content","summary":"New","source":{"type":"note"}}';
  old_id := (public.matrix_remember(replacement || '{"event_key":"atomic:old:full","content":"Old preserved content"}')->>'memory_id')::uuid;
  partial_id := (public.matrix_remember(replacement || '{"event_key":"atomic:old:partial","content":"First fact; second fact remains valid"}')->>'memory_id')::uuid;
  abort_id := (public.matrix_remember(replacement || '{"event_key":"atomic:old:abort"}')->>'memory_id')::uuid;
  request := jsonb_build_object('target_id',old_id,'expected_updated_at',(select updated_at from public.memory_nodes where id=old_id),
    'scope','full','reason','Decision changed','replacement',replacement);
  result := public.matrix_supersede(request);
  assert result->>'status'='created';
  assert (select lifecycle_status='superseded' and content='Old preserved content' and valid_to is null from public.memory_nodes where id=old_id);
  assert (select lifecycle_status='active' from public.memory_nodes where id=(result->>'memory_id')::uuid);
  assert (select metadata->>'supersession_scope'='full' and metadata#>>'{review_prior,lifecycle_status}'='active'
    from public.memory_edges where id=(result->>'relation_id')::uuid);
  assert exists(select 1 from public.memory_versions where memory_node_id=old_id and snapshot->>'content'='Old preserved content');
  select count(*) into before_nodes from public.memory_nodes;
  select count(*) into before_sources from public.sources;
  select count(*) into before_edges from public.memory_edges;
  select count(*) into before_versions from public.memory_versions;
  assert public.matrix_supersede(request)->>'status'='existing';
  assert (select count(*)=before_nodes from public.memory_nodes);
  assert (select count(*)=before_sources from public.sources);
  assert (select count(*)=before_edges from public.memory_edges);
  assert (select count(*)=before_versions from public.memory_versions);

  begin
    perform public.matrix_supersede(jsonb_set(request,'{reason}','"Different operation"'));
    raise exception 'Conflicting retry accepted';
  exception when sqlstate 'P4091' then null; end;
  begin
    perform public.matrix_supersede(jsonb_set(request,'{replacement,event_key}','"atomic:wrong:key"'));
    raise exception 'Already replaced target accepted';
  exception when sqlstate 'P4090' then null; end;
  begin
    perform public.matrix_supersede(jsonb_set(request,'{replacement,event_key}','"atomic:old:partial"'));
    raise exception 'Ordinary remember key accepted as replacement';
  exception when sqlstate 'P4091' then null; end;

  partial_request := request || jsonb_build_object('target_id',partial_id,
    'expected_updated_at',(select updated_at from public.memory_nodes where id=partial_id),
    'scope','partial','reason','Only first fact changes',
    'replacement',replacement || '{"event_key":"atomic:new:partial"}');
  begin
    perform public.matrix_supersede(partial_request || '{"expected_updated_at":"1999-01-01T00:00:00Z"}');
    raise exception 'Stale target accepted';
  exception when sqlstate 'P4090' then null; end;
  result := public.matrix_supersede(partial_request);
  assert (select lifecycle_status='active' and content='First fact; second fact remains valid' and metadata#>>'{last_supersession,scope}'='partial'
    from public.memory_nodes where id=partial_id);
  assert (select metadata->>'supersession_scope'='partial' and metadata->>'scope'='Only first fact changes'
    from public.memory_edges where id=(result->>'relation_id')::uuid);
  assert public.matrix_supersede(partial_request)->>'status'='existing';
  begin
    perform public.matrix_supersede(jsonb_set(partial_request,'{replacement,event_key}','"atomic:partial:stale"'));
    raise exception 'Stale partial target accepted within same transaction';
  exception when sqlstate 'P4090' then null; end;

  -- Fault occurs after creation of the new memory/source/edge. All must roll back.
  abort_request := request || jsonb_build_object('target_id',abort_id,
    'expected_updated_at',(select updated_at from public.memory_nodes where id=abort_id),
    'replacement',replacement || '{"event_key":"atomic:new:abort"}');
  select count(*) into before_nodes from public.memory_nodes;
  select count(*) into before_sources from public.sources;
  select count(*) into before_edges from public.memory_edges;
  select count(*) into before_versions from public.memory_versions;
  begin
    perform public.matrix_supersede(abort_request);
    raise exception 'Fault injection did not run';
  exception when sqlstate 'P7777' then null; end;
  assert (select count(*)=before_nodes from public.memory_nodes), 'Orphan memory after failure';
  assert (select count(*)=before_sources from public.sources), 'Orphan source after failure';
  assert (select count(*)=before_edges from public.memory_edges), 'Orphan edge after failure';
  assert (select count(*)=before_versions from public.memory_versions), 'Orphan version after failure';
  assert (select lifecycle_status='active' from public.memory_nodes where id=abort_id);

  begin
    perform public.matrix_supersede(abort_request || '{"owner_id":"22222222-2222-4222-8222-222222222222"}');
    raise exception 'Owner override accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.matrix_supersede(jsonb_set(abort_request,'{replacement,relations}',
      jsonb_build_array(jsonb_build_object('type','supersedes','target_node_id',partial_id))));
    raise exception 'Hidden extra replacement accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.matrix_supersede(jsonb_set(abort_request,'{replacement,valid_from}','"2999-01-01T00:00:00Z"'));
    raise exception 'Future transition accepted';
  exception when sqlstate '22023' then null; end;

  perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
  begin
    perform public.matrix_supersede(abort_request);
    raise exception 'Cross-owner target accepted';
  exception when sqlstate 'P4040' then null; end;
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.matrix_supersede(abort_request);
    raise exception 'Missing identity accepted';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
