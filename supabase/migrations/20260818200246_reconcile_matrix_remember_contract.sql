
alter table public.memory_nodes add column if not exists event_key text;
do $m$ begin
  if not exists(select 1 from pg_constraint
    where conrelid='public.memory_nodes'::regclass
      and conname='memory_nodes_event_key_check') then
    alter table public.memory_nodes add constraint memory_nodes_event_key_check
      check(event_key is null or length(btrim(event_key)) between 1 and 200);
  end if;
end $m$;
create unique index if not exists memory_nodes_owner_event_key_uidx
on public.memory_nodes(owner_id,event_key) where event_key is not null;
comment on column public.memory_nodes.event_key is
'Stable idempotency key unique per owner; prevents duplicate memories from repeated ingestion.';

CREATE OR REPLACE FUNCTION public.matrix_remember(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_auth_id uuid := auth.uid();
  v_owner_id uuid;
  v_payload_owner uuid;
  v_event_key text;
  v_memory_id uuid;
  v_source_id uuid;
  v_life_period_id uuid;
  v_parent_id uuid;
  v_entity jsonb;
  v_entity_id uuid;
  v_entity_ids uuid[] := '{}'::uuid[];
  v_relation jsonb;
  v_target_id uuid;
  v_relation_id uuid;
  v_relation_ids uuid[] := '{}'::uuid[];
  v_source jsonb;
  v_occurred_at timestamptz;
  v_existing record;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be a JSON object';
  end if;

  v_payload_owner := nullif(btrim(p_payload->>'owner_id'), '')::uuid;

  if v_auth_id is not null then
    if v_payload_owner is not null and v_payload_owner <> v_auth_id then
      raise exception 'owner_id does not match the authenticated user';
    end if;
    v_owner_id := v_auth_id;
  else
    if current_user not in ('postgres', 'service_role', 'supabase_admin') then
      raise exception 'an authenticated user or privileged server role is required';
    end if;
    v_owner_id := v_payload_owner;
  end if;

  if v_owner_id is null then
    raise exception 'owner_id is required for server-side calls';
  end if;

  v_event_key := nullif(btrim(p_payload->>'event_key'), '');
  if v_event_key is null then
    raise exception 'event_key is required';
  end if;
  if length(v_event_key) > 200 then
    raise exception 'event_key must be 200 characters or fewer';
  end if;

  if nullif(btrim(p_payload->>'memory_type'), '') is null then
    raise exception 'memory_type is required';
  end if;
  if nullif(btrim(p_payload->>'title'), '') is null then
    raise exception 'title is required';
  end if;
  if nullif(btrim(p_payload->>'content'), '') is null then
    raise exception 'content is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_owner_id::text || ':' || v_event_key, 0)
  );

  select n.id, n.source_id
    into v_existing
  from public.memory_nodes n
  where n.owner_id = v_owner_id
    and n.event_key = v_event_key;

  if found then
    return jsonb_build_object(
      'status', 'existing',
      'event_key', v_event_key,
      'memory_id', v_existing.id,
      'source_id', v_existing.source_id,
      'entity_ids', coalesce((
        select jsonb_agg(me.entity_id order by me.entity_id)
        from public.memory_entities me
        where me.owner_id = v_owner_id
          and me.memory_node_id = v_existing.id
      ), '[]'::jsonb),
      'relation_ids', coalesce((
        select jsonb_agg(e.id order by e.id)
        from public.memory_edges e
        where e.owner_id = v_owner_id
          and e.source_node_id = v_existing.id
      ), '[]'::jsonb)
    );
  end if;

  v_occurred_at := nullif(btrim(p_payload->>'occurred_at'), '')::timestamptz;
  v_parent_id := nullif(btrim(p_payload->>'parent_id'), '')::uuid;

  if v_parent_id is not null and not exists (
    select 1 from public.memory_nodes n
    where n.id = v_parent_id and n.owner_id = v_owner_id
  ) then
    raise exception 'parent_id does not belong to the owner or does not exist';
  end if;

  v_life_period_id := nullif(btrim(p_payload->>'life_period_id'), '')::uuid;
  if v_life_period_id is not null then
    if not exists (
      select 1 from public.life_periods lp
      where lp.id = v_life_period_id and lp.owner_id = v_owner_id
    ) then
      raise exception 'life_period_id does not belong to the owner or does not exist';
    end if;
  else
    select lp.id
      into v_life_period_id
    from public.life_periods lp
    where lp.owner_id = v_owner_id
      and lp.starts_on <= coalesce(v_occurred_at::date, current_date)
      and (lp.ends_on is null or lp.ends_on >= coalesce(v_occurred_at::date, current_date))
    order by lp.starts_on desc nulls last
    limit 1;
  end if;

  if nullif(btrim(p_payload->>'source_id'), '') is not null then
    v_source_id := (p_payload->>'source_id')::uuid;
    if not exists (
      select 1 from public.sources s
      where s.id = v_source_id and s.owner_id = v_owner_id
    ) then
      raise exception 'source_id does not belong to the owner or does not exist';
    end if;
  else
    v_source := p_payload->'source';
    if v_source is null or jsonb_typeof(v_source) <> 'object' then
      raise exception 'source object or source_id is required';
    end if;
    if nullif(btrim(v_source->>'type'), '') is null then
      raise exception 'source.type is required';
    end if;

    insert into public.sources (
      owner_id, source_type, title, uri, storage_path, content_text,
      captured_at, checksum, metadata
    )
    values (
      v_owner_id,
      v_source->>'type',
      nullif(btrim(v_source->>'title'), ''),
      nullif(btrim(v_source->>'uri'), ''),
      nullif(btrim(v_source->>'storage_path'), ''),
      nullif(v_source->>'content_text', ''),
      nullif(btrim(v_source->>'captured_at'), '')::timestamptz,
      nullif(btrim(v_source->>'checksum'), ''),
      coalesce(v_source->'metadata', '{}'::jsonb)
    )
    returning id into v_source_id;
  end if;

  insert into public.memory_nodes (
    owner_id, event_key, memory_type, title, content, summary,
    occurred_at, ended_at, valid_from, valid_to, place_text,
    importance, emotional_intensity, emotional_valence, confidence,
    truth_status, lifecycle_status, access_level,
    source_id, life_period_id, parent_id, metadata
  )
  values (
    v_owner_id,
    v_event_key,
    p_payload->>'memory_type',
    p_payload->>'title',
    p_payload->>'content',
    nullif(p_payload->>'summary', ''),
    v_occurred_at,
    nullif(btrim(p_payload->>'ended_at'), '')::timestamptz,
    nullif(btrim(p_payload->>'valid_from'), '')::timestamptz,
    nullif(btrim(p_payload->>'valid_to'), '')::timestamptz,
    nullif(btrim(p_payload->>'place_text'), ''),
    coalesce((p_payload->>'importance')::smallint, 50),
    coalesce((p_payload->>'emotional_intensity')::smallint, 0),
    coalesce((p_payload->>'emotional_valence')::smallint, 0),
    coalesce((p_payload->>'confidence')::smallint, 70),
    coalesce(nullif(p_payload->>'truth_status', ''), 'reported'),
    coalesce(nullif(p_payload->>'lifecycle_status', ''), 'active'),
    coalesce(nullif(p_payload->>'access_level', ''), 'private'),
    v_source_id,
    v_life_period_id,
    v_parent_id,
    coalesce(p_payload->'metadata', '{}'::jsonb)
      || jsonb_build_object('event_key', v_event_key)
  )
  returning id into v_memory_id;

  if p_payload ? 'entities' and jsonb_typeof(p_payload->'entities') <> 'array' then
    raise exception 'entities must be a JSON array';
  end if;

  for v_entity in
    select value from jsonb_array_elements(coalesce(p_payload->'entities', '[]'::jsonb))
  loop
    if nullif(btrim(v_entity->>'kind'), '') is null
       or nullif(btrim(v_entity->>'name'), '') is null then
      raise exception 'each entity requires kind and name';
    end if;

    insert into public.entities as existing (
      owner_id, kind, canonical_name, aliases, description, metadata
    )
    values (
      v_owner_id,
      v_entity->>'kind',
      v_entity->>'name',
      coalesce(
        array(select jsonb_array_elements_text(coalesce(v_entity->'aliases', '[]'::jsonb))),
        '{}'::text[]
      ),
      nullif(v_entity->>'description', ''),
      coalesce(v_entity->'metadata', '{}'::jsonb)
    )
    on conflict (owner_id, kind, lower(canonical_name))
    do update set
      aliases = (
        select coalesce(array_agg(distinct alias_value order by alias_value), '{}'::text[])
        from unnest(existing.aliases || excluded.aliases) as alias_value
      ),
      description = coalesce(existing.description, excluded.description),
      metadata = existing.metadata || excluded.metadata,
      updated_at = now()
    returning id into v_entity_id;

    insert into public.memory_entities (
      owner_id, memory_node_id, entity_id, role, weight
    )
    values (
      v_owner_id,
      v_memory_id,
      v_entity_id,
      coalesce(nullif(v_entity->>'role', ''), 'mentioned'),
      coalesce((v_entity->>'weight')::numeric, 0.5)
    )
    on conflict (memory_node_id, entity_id, role)
    do update set weight = greatest(public.memory_entities.weight, excluded.weight);

    v_entity_ids := array_append(v_entity_ids, v_entity_id);
  end loop;

  if p_payload ? 'relations' and jsonb_typeof(p_payload->'relations') <> 'array' then
    raise exception 'relations must be a JSON array';
  end if;

  for v_relation in
    select value from jsonb_array_elements(coalesce(p_payload->'relations', '[]'::jsonb))
  loop
    v_target_id := nullif(btrim(v_relation->>'target_node_id'), '')::uuid;

    if v_target_id is null and nullif(btrim(v_relation->>'target_event_key'), '') is not null then
      select n.id into v_target_id
      from public.memory_nodes n
      where n.owner_id = v_owner_id
        and n.event_key = v_relation->>'target_event_key';
    end if;

    if v_target_id is null or not exists (
      select 1 from public.memory_nodes n
      where n.id = v_target_id and n.owner_id = v_owner_id
    ) then
      raise exception 'each relation requires a valid target_node_id or target_event_key owned by the user';
    end if;

    if nullif(btrim(v_relation->>'type'), '') is null then
      raise exception 'each relation requires type';
    end if;

    insert into public.memory_edges as existing (
      owner_id, source_node_id, target_node_id, relation_type,
      weight, confidence, valid_from, valid_to, source_id, metadata
    )
    values (
      v_owner_id,
      v_memory_id,
      v_target_id,
      v_relation->>'type',
      coalesce((v_relation->>'weight')::numeric, 0.5),
      coalesce((v_relation->>'confidence')::smallint, 70),
      nullif(btrim(v_relation->>'valid_from'), '')::timestamptz,
      nullif(btrim(v_relation->>'valid_to'), '')::timestamptz,
      v_source_id,
      coalesce(v_relation->'metadata', '{}'::jsonb)
    )
    on conflict (owner_id, source_node_id, target_node_id, relation_type)
    do update set
      weight = greatest(existing.weight, excluded.weight),
      confidence = greatest(existing.confidence, excluded.confidence)
    returning id into v_relation_id;

    v_relation_ids := array_append(v_relation_ids, v_relation_id);
  end loop;

  return jsonb_build_object(
    'status', 'created',
    'event_key', v_event_key,
    'memory_id', v_memory_id,
    'source_id', v_source_id,
    'life_period_id', v_life_period_id,
    'entity_ids', to_jsonb(v_entity_ids),
    'relation_ids', to_jsonb(v_relation_ids)
  );
end;
$function$;

revoke all on function public.matrix_remember(jsonb) from public,anon;
grant execute on function public.matrix_remember(jsonb) to authenticated,service_role;
