-- Additive owner-scoped API. Existing remember callers retain their contract.
-- One call is one transaction: source, memory, edge, versions and target state.
-- A partial replacement also needs a fresh optimistic-lock token, even when
-- two calls occur within one transaction (where now() is constant).
create or replace function public.stamp_memory_supersession()
returns trigger language plpgsql security invoker set search_path = ''
as $stamp$
begin
  new.updated_at := greatest(clock_timestamp(), old.updated_at + interval '1 microsecond');
  return new;
end;
$stamp$;
revoke all on function public.stamp_memory_supersession() from public, anon, authenticated, service_role;
drop trigger if exists zz_memory_supersession_stamp on public.memory_nodes;
create trigger zz_memory_supersession_stamp before update on public.memory_nodes
for each row when (old.metadata->'last_supersession' is distinct from new.metadata->'last_supersession')
execute function public.stamp_memory_supersession();

create or replace function public.matrix_supersede(p_payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_owner uuid := auth.uid();
  v_target public.memory_nodes%rowtype;
  v_existing public.memory_nodes%rowtype;
  v_new jsonb;
  v_result jsonb;
  v_key text;
  v_scope text;
  v_reason text;
  v_hash text;
  v_id uuid;
  v_expected timestamptz;
  v_edge uuid;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'Authenticated owner required';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
    or not (p_payload ?& array['target_id','expected_updated_at','scope','reason','replacement'])
    or (p_payload - array['target_id','expected_updated_at','scope','reason','replacement']) <> '{}'::jsonb then
    raise exception using errcode = '22023', message = 'Invalid replacement request';
  end if;
  v_id := (p_payload->>'target_id')::uuid;
  v_expected := (p_payload->>'expected_updated_at')::timestamptz;
  v_scope := p_payload->>'scope';
  v_reason := btrim(p_payload->>'reason');
  v_new := p_payload->'replacement';
  if v_id is null or v_expected is null or not isfinite(v_expected)
    or v_scope is null or v_scope not in ('full','partial')
    or v_reason is null or length(v_reason) not between 1 and 2000
    or jsonb_typeof(v_new) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Invalid replacement request';
  end if;
  -- No identity/lifecycle overrides or hidden replacement edges in the payload.
  if (v_new - array['event_key','memory_type','title','content','summary','source',
      'occurred_at','ended_at','valid_from','valid_to','place_text','importance',
      'confidence','truth_status','emotional_intensity','emotional_valence',
      'access_level','parent_id','life_period_id','metadata','entities','relations']) <> '{}'::jsonb
    or (v_new ? 'metadata' and jsonb_typeof(v_new->'metadata') <> 'object')
    or (v_new->'metadata') ? '_matrix_supersession'
    or (v_new ? 'relations' and jsonb_typeof(v_new->'relations') <> 'array') then
    raise exception using errcode = '22023', message = 'Invalid replacement fields';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(v_new->'relations','[]'::jsonb)) r
    where r->>'type' = 'supersedes') then
    raise exception using errcode = '22023', message = 'Use the explicit replacement target';
  end if;
  -- This operation applies immediately. Scheduling historical/future transitions
  -- requires a separate as-of contract and must not silently invalidate today.
  if nullif(v_new->>'valid_from','')::timestamptz > now()
    or nullif(v_new->>'valid_to','')::timestamptz <= now() then
    raise exception using errcode = '22023', message = 'Replacement must be currently valid';
  end if;
  v_key := btrim(v_new->>'event_key');
  if v_key is null or length(v_key) not between 3 and 200
    or v_key !~ '^[a-z0-9][a-z0-9:._-]+$' then
    raise exception using errcode = '22023', message = 'Invalid event_key';
  end if;
  v_hash := encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
  -- Same namespace/order as matrix_remember: a retry and an ordinary save with
  -- the same event_key cannot race each other into partially applied changes.
  perform pg_advisory_xact_lock(hashtextextended(v_owner::text || ':' || v_key,0));
  select * into v_existing from public.memory_nodes
    where owner_id = v_owner and event_key = v_key;
  if found then
    if v_existing.metadata #>> '{_matrix_supersession,request_hash}' is distinct from v_hash then
      raise exception using errcode = 'P4091', message = 'Replacement event_key conflict';
    end if;
    select id into v_edge from public.memory_edges
      where owner_id = v_owner and source_node_id = v_existing.id
        and target_node_id = v_id and relation_type = 'supersedes'
        and metadata->>'request_hash' = v_hash;
    if v_edge is null then
      raise exception using errcode = 'P4091', message = 'Replacement receipt needs review';
    end if;
    return jsonb_build_object('status','existing','same_operation',true,
      'event_key',v_key,'memory_id',v_existing.id,'source_id',v_existing.source_id,
      'replaced_memory_id',v_id,'scope',v_scope,'relation_id',v_edge);
  end if;
  select * into v_target from public.memory_nodes
    where id = v_id and owner_id = v_owner for update;
  if not found then
    raise exception using errcode = 'P4040', message = 'Replacement target unavailable';
  end if;
  if v_target.updated_at is distinct from v_expected
    or v_target.lifecycle_status <> 'active'
    or v_target.valid_from > now() or v_target.valid_to <= now()
    or exists (select 1 from public.memory_edges e where e.owner_id = v_owner
      and e.target_node_id = v_id and e.relation_type = 'supersedes'
      and (e.valid_from is null or e.valid_from <= now())
      and (e.valid_to is null or e.valid_to > now())
      and coalesce(e.metadata->>'supersession_scope','unreviewed') <> 'partial') then
    raise exception using errcode = 'P4090', message = 'Replacement target changed; fetch and review again';
  end if;
  v_new := v_new || jsonb_build_object('lifecycle_status','active',
    'metadata',coalesce(v_new->'metadata','{}'::jsonb) || jsonb_build_object(
      '_matrix_supersession',jsonb_build_object('request_hash',v_hash,'target_id',v_id,'scope',v_scope)),
    'relations',coalesce(v_new->'relations','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'target_node_id',v_id,'type','supersedes','confidence',100,'weight',1,
      'metadata',jsonb_build_object('supersession_scope',v_scope,'scope',v_reason,
        'request_hash',v_hash,'reviewed_at',clock_timestamp(),
        'review_prior',jsonb_build_object('lifecycle_status',v_target.lifecycle_status,
          'updated_at',v_target.updated_at,'valid_from',v_target.valid_from,
          'valid_to',v_target.valid_to,'metadata',v_target.metadata,
          'content_sha256',encode(sha256(convert_to(v_target.content,'UTF8')),'hex'))))));
  v_result := public.matrix_remember(v_new);
  if v_result->>'status' <> 'created' then
    raise exception using errcode = 'P4091', message = 'Replacement event_key conflict';
  end if;
  select id into v_edge from public.memory_edges where owner_id = v_owner
    and source_node_id = (v_result->>'memory_id')::uuid
    and target_node_id = v_id and relation_type = 'supersedes';
  if v_edge is null then raise exception 'Replacement edge missing'; end if;
  perform set_config('app.change_reason','Matrix supersession: ' || v_scope || ' / ' || v_key,true);
  update public.memory_nodes set
    lifecycle_status = case when v_scope = 'full' then 'superseded' else lifecycle_status end,
    metadata = metadata || jsonb_build_object('last_supersession',jsonb_build_object(
      'memory_id',v_result->>'memory_id','scope',v_scope,'event_key',v_key))
    where owner_id = v_owner and id = v_id;
  -- title/content/summary and validity dates of the old memory are never changed.
  return v_result || jsonb_build_object('same_operation',true,
    'replaced_memory_id',v_id,'scope',v_scope,'relation_id',v_edge);
end;
$function$;

revoke all on function public.matrix_supersede(jsonb) from public, anon, service_role;
grant execute on function public.matrix_supersede(jsonb) to authenticated;
comment on function public.matrix_supersede(jsonb) is
  'Atomically create a replacement, scoped supersedes edge and old-memory lifecycle transition under owner RLS. Exact event_key retries only.';
