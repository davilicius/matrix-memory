-- Run only on the disposable local database created by run-permissions.sh.
-- Assertions raise exceptions so psql ON_ERROR_STOP makes CI fail reliably.
begin;

insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

do $$
declare t text; r text; p text; expected boolean;
begin
  foreach t in array array['profiles','life_periods','entities','sources',
    'memory_nodes','memory_edges','memory_entities','memory_versions',
    'retrieval_history','matrix_recall_requests'] loop
    assert (select relrowsecurity from pg_class
      where oid = ('public.' || t)::regclass), 'RLS disabled: ' || t;
    if current_setting('matrix.test_mode', true) = 'strict' then
      foreach r in array array['anon','authenticated','service_role'] loop
        foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
          expected := case r
            when 'anon' then false
            when 'authenticated' then case t
              when 'profiles' then p in ('SELECT','UPDATE')
              when 'memory_versions' then p = 'SELECT'
              else p in ('SELECT','INSERT','UPDATE','DELETE') end
            when 'service_role' then case
              when t = 'life_periods' then p = 'SELECT'
              when t in ('sources','retrieval_history') then p in ('SELECT','INSERT')
              when t in ('memory_nodes','entities','memory_entities','memory_edges')
                then p in ('SELECT','INSERT','UPDATE')
              else false end
          end;
          assert has_table_privilege(r, 'public.' || t, p) = expected,
            format('Unexpected ACL: %s %s %s', r, t, p);
        end loop;
      end loop;
    end if;
  end loop;
  assert not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
    and proname in ('matrix_remember','matrix_recall','matrix_semantic_recall',
      'matrix_schema_info','recall_memories','memory_context') and prosecdef),
    'Public RPC became SECURITY DEFINER';
  assert not has_schema_privilege('anon', 'private', 'USAGE');
  assert not has_function_privilege('authenticated',
    'private.process_matrix_embedding_jobs(integer,integer,integer)', 'EXECUTE');
  assert not has_function_privilege('authenticated',
    'private.process_matrix_query_embedding_jobs(integer,integer,integer)', 'EXECUTE');
end $$;

insert into public.profiles (id, display_name)
values ('11111111-1111-4111-8111-111111111111', 'Synthetic A');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

do $$
declare a jsonb; b jsonb; result jsonb; payload jsonb; n integer;
begin
  assert public.matrix_schema_info()->>'schema_version' = '1.2';
  insert into public.life_periods(owner_id, name, starts_on)
    values (auth.uid(), 'Synthetic period', '2000-01-01');
  update public.profiles set display_name = 'Synthetic updated' where id = auth.uid();
  payload := '{"event_key":"acl-a","memory_type":"fact","title":"Permisos sintéticos","content":"Prueba permisos sintéticos","source":{"type":"conversation"},"entities":[{"kind":"project","name":"Synthetic"}]}'::jsonb;
  a := public.matrix_remember(payload);
  assert a->>'status' = 'created', 'Authenticated remember failed';
  assert public.matrix_remember(payload)->>'status' = 'existing', 'Idempotency failed';
  b := public.matrix_remember(payload || jsonb_build_object('event_key','acl-a2',
    'relations', jsonb_build_array(jsonb_build_object('target_event_key','acl-a','type','related_to'))));
  assert jsonb_array_length(b->'entity_ids') = 1, 'Entity upsert failed';
  assert jsonb_array_length(b->'relation_ids') = 1, 'Relation insert failed';
  update public.memory_nodes set content = 'Prueba permisos actualizada' where id = (a->>'memory_id')::uuid;
  assert (select count(*) from public.memory_versions) = 1, 'Archive trigger failed';
  result := public.matrix_recall('{"query":"permisos","hops":1}');
  assert jsonb_array_length(result->'hits') = 2, 'Authenticated recall failed';
  assert jsonb_array_length(result->'associations') = 2, 'Graph context failed';
  assert not exists (select 1 from jsonb_array_elements(result->'associations') item
    where item->>'node_id' is null), 'Graph response lost node_id';
  assert (select count(*) from public.recall_memories('permisos', null, 12, null, null, null)) = 2,
    'Legacy recall helper changed';
  assert (select count(*) from public.retrieval_history) = 1;
  assert (select min(recall_count) from public.memory_nodes) = 1;
  insert into public.matrix_recall_requests(owner_id, query_text, query_hash, status, embedding)
    values (auth.uid(), 'permisos', md5('permisos'), 'ready',
      ('[1,' || repeat('0,',382) || '0]')::extensions.vector);
  result := public.matrix_semantic_recall('{"query":"permisos"}');
  assert result->>'status' = 'ready', 'Cached semantic RPC failed';
  begin
    perform public.matrix_recall('{"owner_id":"22222222-2222-4222-8222-222222222222","query":"permisos"}');
    raise exception 'Recall owner spoof accepted';
  exception when raise_exception then
    if sqlerrm <> 'owner_id does not match the authenticated user' then raise; end if;
  end;
  begin
    perform public.matrix_remember(payload || '{"owner_id":"22222222-2222-4222-8222-222222222222"}');
    raise exception 'Owner spoof accepted';
  exception when raise_exception then
    if sqlerrm <> 'owner_id does not match the authenticated user' then raise; end if;
  end;
  begin
    update public.memory_nodes set owner_id = '22222222-2222-4222-8222-222222222222';
    raise exception 'RLS WITH CHECK accepted owner reassignment';
  exception when insufficient_privilege then null;
  end;
end $$;

-- User B cannot read, update or delete A's rows in any Matrix table.
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
do $$
declare t text; n integer; result jsonb;
begin
  foreach t in array array['profiles','life_periods','entities','sources','memory_nodes',
    'memory_edges','memory_entities','memory_versions','retrieval_history','matrix_recall_requests'] loop
    execute format('select count(*) from public.%I', t) into n;
    assert n = 0, 'Cross-user read: ' || t;
  end loop;
  update public.memory_nodes set title = 'Forbidden';
  get diagnostics n = row_count;
  assert n = 0, 'Cross-user update';
  delete from public.memory_nodes;
  get diagnostics n = row_count;
  assert n = 0, 'Cross-user delete';
  result := public.matrix_recall('{"query":"permisos"}');
  assert jsonb_array_length(result->'hits') = 0, 'Cross-user recall';
  begin
    perform private.enqueue_matrix_query_request('33333333-3333-4333-8333-333333333333');
    raise exception 'Private helper accepted missing/foreign request';
  exception when raise_exception then
    if sqlerrm <> 'recall request not found for owner' then raise; end if;
  end;
end $$;

reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $$
declare payload jsonb; a jsonb; b jsonb; result jsonb;
begin
  payload := '{"owner_id":"22222222-2222-4222-8222-222222222222","event_key":"acl-server","memory_type":"fact","title":"Servidor sintético","content":"Prueba de servidor","source":{"type":"conversation"},"entities":[{"kind":"project","name":"Synthetic server"}]}'::jsonb;
  a := public.matrix_remember(payload);
  assert a->>'status' = 'created', 'service_role remember failed';
  assert public.matrix_remember(payload)->>'status' = 'existing', 'Server idempotency failed';
  b := public.matrix_remember(payload || jsonb_build_object('event_key','acl-server-2',
    'relations', jsonb_build_array(jsonb_build_object('target_event_key','acl-server','type','related_to'))));
  assert jsonb_array_length(b->'entity_ids') = 1, 'Server entity upsert failed';
  assert jsonb_array_length(b->'relation_ids') = 1, 'Server relation insert failed';
  result := public.matrix_recall('{"owner_id":"22222222-2222-4222-8222-222222222222","query":"servidor"}');
  assert result->>'history_id' is not null, 'Server history insert failed';
  assert jsonb_array_length(result->'hits') = 2, 'Server recall without user JWT failed';
  assert jsonb_array_length(result->'associations') = 2, 'Server graph without user JWT failed';
  assert auth.uid() is null, 'Server recall changed JWT identity';
  assert (select min(recall_count) from public.memory_nodes
    where owner_id = '22222222-2222-4222-8222-222222222222') = 1;
  begin
    perform public.matrix_recall('{"query":"servidor"}');
    raise exception 'Server recall accepted missing owner';
  exception when raise_exception then
    if sqlerrm <> 'owner_id is required for server-side calls' then raise; end if;
  end;
  -- Interleaved owners on the same server connection must not retain context.
  result := public.matrix_recall('{"owner_id":"11111111-1111-4111-8111-111111111111","query":"permisos","hops":2}');
  assert jsonb_array_length(result->'hits') = 2, 'Server cannot select owner A';
  assert not exists (select 1 from jsonb_array_elements(result->'hits') hit
    join public.memory_nodes n on n.id = (hit->>'id')::uuid
    where n.owner_id <> '11111111-1111-4111-8111-111111111111'), 'Cross-owner hit';
  assert not exists (select 1 from jsonb_array_elements(result->'associations') hit
    join public.memory_nodes n on n.id = (hit->>'node_id')::uuid
    where n.owner_id <> '11111111-1111-4111-8111-111111111111'), 'Cross-owner association';
  assert (select owner_id from public.retrieval_history where id = (result->>'history_id')::uuid)
    = '11111111-1111-4111-8111-111111111111'::uuid, 'Wrong history owner';
  result := public.matrix_recall('{"owner_id":"22222222-2222-4222-8222-222222222222","query":"permisos"}');
  assert jsonb_array_length(result->'hits') = 0, 'Server leaked owner A text results';
  assert auth.uid() is null, 'Server recall retained another owner identity';
  -- Exercise recall's UPDATE privilege when a trusted server supplies a user context.
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  result := public.matrix_recall('{"query":"servidor","hops":1}');
  assert jsonb_array_length(result->'hits') = 2, 'Server recall with user context failed';
  assert jsonb_array_length(result->'associations') = 2, 'Server graph context failed';
  assert (select min(recall_count) from public.memory_nodes where owner_id = auth.uid()) = 2;
end $$;

reset role;
-- Vector search must use the explicit server owner too, even when every user
-- has the same synthetic embedding and every row would be a candidate.
update public.memory_nodes set embedding = ('[1,' || repeat('0,',382) || '0]')::extensions.vector;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $$
declare result jsonb; embedding jsonb;
begin
  embedding := ('[1,' || repeat('0,',382) || '0]')::jsonb;
  result := public.matrix_recall(jsonb_build_object(
    'owner_id','22222222-2222-4222-8222-222222222222',
    'query','nomatchword', 'query_embedding',embedding, 'hops',2));
  assert jsonb_array_length(result->'hits') = 2, 'Server vector recall failed';
  assert not exists (select 1 from jsonb_array_elements(result->'hits') hit
    join public.memory_nodes n on n.id = (hit->>'id')::uuid
    where n.owner_id <> '22222222-2222-4222-8222-222222222222'), 'Cross-owner vector hit';
  assert not exists (select 1 from jsonb_array_elements(result->'associations') hit
    join public.memory_nodes n on n.id = (hit->>'node_id')::uuid
    where n.owner_id <> '22222222-2222-4222-8222-222222222222'), 'Cross-owner vector graph';
  begin
    result := public.matrix_recall(jsonb_build_object(
      'owner_id','33333333-3333-4333-8333-333333333333', 'query','nomatchword',
      'query_embedding',embedding));
    raise exception 'Unknown auth user unexpectedly accepted history write';
  exception when foreign_key_violation then null;
  end;
end $$;
reset role;
set local role authenticated;
do $$
begin
  begin
    perform public.matrix_recall('{"owner_id":"11111111-1111-4111-8111-111111111111","query":"permisos"}');
    raise exception 'Authenticated role without uid selected an owner';
  exception when raise_exception then
    if sqlerrm <> 'an authenticated user or privileged server role is required' then raise; end if;
  end;
end $$;
reset role;
-- Worker SQL paths use the direct database login (postgres in this harness).
-- No Edge HTTP invocation, model download, cron activation or real secrets.
do $$
declare n integer; job record;
begin
  assert (select count(*) from pgmq.q_matrix_embedding_jobs) >= 4, 'Embedding jobs not queued';
  update public.memory_nodes set embedding_status = 'processing', embedding_error = null
    where owner_id = '11111111-1111-4111-8111-111111111111';
  update public.memory_nodes set embedding = ('[1,' || repeat('0,',382) || '0]')::extensions.vector,
    embedding_model = 'Supabase/gte-small', embedding_status = 'ready', embedding_updated_at = now()
    where owner_id = '11111111-1111-4111-8111-111111111111';
  get diagnostics n = row_count;
  assert n = 2, 'Memory worker update failed';
  update public.matrix_recall_requests set status = 'processing', error = null;
  update public.matrix_recall_requests set status = 'ready',
    embedding = ('[1,' || repeat('0,',382) || '0]')::extensions.vector, expires_at = now() + interval '24 hours';
  get diagnostics n = row_count;
  assert n = 1, 'Query worker update failed';
  for job in select msg_id from pgmq.q_matrix_embedding_jobs loop
    perform pgmq.delete('matrix_embedding_jobs', job.msg_id);
  end loop;
  assert (select count(*) from pgmq.q_matrix_embedding_jobs) = 0, 'Worker queue ack failed';
  assert (select count(*) from public.memory_versions) = 1, 'Maintenance created spurious versions';
end $$;

select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$
declare t text; n integer; f regprocedure;
begin
  foreach t in array array['profiles','life_periods','entities','sources','memory_nodes',
    'memory_edges','memory_entities','memory_versions','retrieval_history','matrix_recall_requests'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      assert n = 0, 'Anonymous data leak: ' || t;
    exception when insufficient_privilege then null;
    end;
  end loop;
  foreach f in array array['public.matrix_remember(jsonb)'::regprocedure,
    'public.matrix_recall(jsonb)'::regprocedure,'public.matrix_semantic_recall(jsonb)'::regprocedure,
    'public.matrix_schema_info()'::regprocedure,'public.memory_context(uuid[],integer)'::regprocedure,
    'public.recall_memories(text,extensions.vector,integer,text[],timestamptz,timestamptz)'::regprocedure] loop
    assert not has_function_privilege(current_user, f, 'EXECUTE'), 'Anonymous RPC access: ' || f;
  end loop;
  begin
    perform public.matrix_remember('{}');
    raise exception 'Anonymous RPC was executed';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
select 'permissions regression: PASS' as result;
