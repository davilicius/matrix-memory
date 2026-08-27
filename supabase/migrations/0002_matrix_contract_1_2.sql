-- Matrix Memory educational contract 1.2
-- Applies after 0001_matrix_core.sql.
-- Worker deployment and cron activation are intentionally separate.

create extension if not exists pgmq;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

alter table public.memory_nodes
  add column if not exists embedding_status text not null default 'pending',
  add column if not exists embedding_input_hash text,
  add column if not exists embedding_updated_at timestamptz,
  add column if not exists embedding_error text;

do $matrix_constraint$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.memory_nodes'::regclass
      and conname = 'memory_nodes_embedding_status_check'
  ) then
    alter table public.memory_nodes
      add constraint memory_nodes_embedding_status_check
      check (embedding_status in ('pending', 'processing', 'ready', 'error'));
  end if;
end
$matrix_constraint$;

create table if not exists public.retrieval_history (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  query_text text not null,
  result_node_ids uuid[] not null default '{}',
  feedback smallint check (feedback between -1 and 1),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists retrieval_history_owner_created_idx
  on public.retrieval_history (owner_id, created_at desc);

alter table public.retrieval_history enable row level security;
drop policy if exists retrieval_history_own on public.retrieval_history;
create policy retrieval_history_own
  on public.retrieval_history
  for all
  to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create table if not exists public.matrix_recall_requests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  query_text text not null,
  query_hash text not null,
  embedding extensions.vector(384),
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'ready', 'error')),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  unique (owner_id, query_hash)
);

create index if not exists matrix_recall_requests_owner_status_idx
  on public.matrix_recall_requests (owner_id, status, updated_at desc);

alter table public.matrix_recall_requests enable row level security;
drop policy if exists matrix_recall_requests_own on public.matrix_recall_requests;
create policy matrix_recall_requests_own
  on public.matrix_recall_requests
  for all
  to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- Explicit grants keep the project functional when automatic Data API exposure is disabled.
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.life_periods to authenticated;
grant select, insert, update, delete on public.entities to authenticated;
grant select, insert, update, delete on public.sources to authenticated;
grant select, insert, update, delete on public.memory_nodes to authenticated;
grant select, insert, update, delete on public.memory_edges to authenticated;
grant select, insert, update, delete on public.memory_entities to authenticated;
grant select on public.memory_versions to authenticated;
grant select, insert, update, delete on public.retrieval_history to authenticated;
grant select, insert, update, delete on public.matrix_recall_requests to authenticated;

create or replace function private.matrix_embedding_hash(
  p_title text,
  p_summary text,
  p_content text,
  p_place_text text
)
returns text
language sql
immutable
set search_path = ''
as $matrix_function$
  select md5(concat_ws(
    E'\n\n',
    coalesce(p_title, ''),
    coalesce(p_summary, ''),
    coalesce(p_content, ''),
    coalesce(p_place_text, '')
  ));
$matrix_function$;

create or replace function private.prepare_matrix_embedding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $matrix_function$
declare
  v_hash text;
begin
  v_hash := private.matrix_embedding_hash(
    new.title,
    new.summary,
    new.content,
    new.place_text
  );

  if tg_op = 'INSERT' or v_hash is distinct from old.embedding_input_hash then
    new.embedding := null;
    new.embedding_status := 'pending';
    new.embedding_input_hash := v_hash;
    new.embedding_updated_at := null;
    new.embedding_error := null;
  end if;

  return new;
end
$matrix_function$;

create or replace function private.enqueue_matrix_embedding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $matrix_function$
begin
  if new.embedding_status = 'pending'
     and (
       tg_op = 'INSERT'
       or new.embedding_input_hash is distinct from old.embedding_input_hash
       or old.embedding_status is distinct from 'pending'
     ) then
    perform pgmq.send(
      queue_name => 'matrix_embedding_jobs',
      msg => jsonb_build_object(
        'memory_id', new.id,
        'owner_id', new.owner_id,
        'input_hash', new.embedding_input_hash
      )
    );
  end if;

  return new;
end
$matrix_function$;

create or replace function public.archive_memory_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $matrix_function$
declare
  v_next_version integer;
  v_substantive_change boolean;
begin
  v_substantive_change := row(
    old.event_key, old.memory_type, old.title, old.content, old.summary,
    old.occurred_at, old.ended_at, old.valid_from, old.valid_to,
    old.place_text, old.importance, old.emotional_intensity,
    old.emotional_valence, old.confidence, old.truth_status,
    old.lifecycle_status, old.access_level, old.source_id,
    old.life_period_id, old.parent_id, old.metadata
  ) is distinct from row(
    new.event_key, new.memory_type, new.title, new.content, new.summary,
    new.occurred_at, new.ended_at, new.valid_from, new.valid_to,
    new.place_text, new.importance, new.emotional_intensity,
    new.emotional_valence, new.confidence, new.truth_status,
    new.lifecycle_status, new.access_level, new.source_id,
    new.life_period_id, new.parent_id, new.metadata
  );

  if not v_substantive_change then
    return new;
  end if;

  select coalesce(max(mv.version_no), 0) + 1
    into v_next_version
  from public.memory_versions mv
  where mv.memory_node_id = old.id;

  insert into public.memory_versions (
    owner_id,
    memory_node_id,
    version_no,
    snapshot,
    change_reason
  ) values (
    old.owner_id,
    old.id,
    v_next_version,
    to_jsonb(old)
      - 'fts'
      - 'embedding'
      - 'embedding_status'
      - 'embedding_input_hash'
      - 'embedding_updated_at'
      - 'embedding_error'
      - 'recall_count'
      - 'last_recalled_at'
      - 'updated_at',
    coalesce(current_setting('app.change_reason', true), 'Actualización de memoria')
  );

  return new;
end
$matrix_function$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $matrix_function$
begin
  new.updated_at := now();
  return new;
end
$matrix_function$;

create or replace function public.set_memory_node_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $matrix_function$
begin
  if row(
    old.event_key, old.memory_type, old.title, old.content, old.summary,
    old.occurred_at, old.ended_at, old.valid_from, old.valid_to,
    old.place_text, old.importance, old.emotional_intensity,
    old.emotional_valence, old.confidence, old.truth_status,
    old.lifecycle_status, old.access_level, old.source_id,
    old.life_period_id, old.parent_id, old.metadata
  ) is distinct from row(
    new.event_key, new.memory_type, new.title, new.content, new.summary,
    new.occurred_at, new.ended_at, new.valid_from, new.valid_to,
    new.place_text, new.importance, new.emotional_intensity,
    new.emotional_valence, new.confidence, new.truth_status,
    new.lifecycle_status, new.access_level, new.source_id,
    new.life_period_id, new.parent_id, new.metadata
  ) then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;

  return new;
end
$matrix_function$;

drop trigger if exists memory_nodes_set_updated_at on public.memory_nodes;
create trigger memory_nodes_set_updated_at
before update on public.memory_nodes
for each row execute function public.set_memory_node_updated_at();

drop trigger if exists memory_nodes_prepare_embedding on public.memory_nodes;
create trigger memory_nodes_prepare_embedding
before insert or update of title, summary, content, place_text
on public.memory_nodes
for each row execute function private.prepare_matrix_embedding();

select pgmq.create('matrix_embedding_jobs');
select pgmq.create('matrix_query_embedding_jobs');

drop trigger if exists memory_nodes_enqueue_embedding on public.memory_nodes;
create trigger memory_nodes_enqueue_embedding
after insert or update of title, summary, content, place_text, embedding_status
on public.memory_nodes
for each row execute function private.enqueue_matrix_embedding();

create or replace function public.recall_memories(
  p_query_text text,
  p_query_embedding extensions.vector(384),
  p_match_count integer default 12,
  p_memory_types text[] default null,
  p_occurred_after timestamptz default null,
  p_occurred_before timestamptz default null
)
returns table (
  id uuid,
  memory_type text,
  title text,
  content text,
  summary text,
  occurred_at timestamptz,
  importance smallint,
  emotional_intensity smallint,
  confidence smallint,
  truth_status text,
  source_id uuid,
  score double precision
)
language sql
stable
security invoker
set search_path = ''
as $matrix_function$
with filtered as (
  select n.*
  from public.memory_nodes n
  where n.owner_id = auth.uid()
    and n.lifecycle_status = 'active'
    and (p_memory_types is null or n.memory_type = any(p_memory_types))
    and (p_occurred_after is null or n.occurred_at >= p_occurred_after)
    and (p_occurred_before is null or n.occurred_at <= p_occurred_before)
),
full_text as (
  select
    n.id,
    row_number() over (
      order by ts_rank_cd(
        n.fts,
        websearch_to_tsquery('spanish', p_query_text)
      ) desc
    ) as rank_ix
  from filtered n
  where coalesce(trim(p_query_text), '') <> ''
    and n.fts @@ websearch_to_tsquery('spanish', p_query_text)
  limit least(greatest(p_match_count, 1), 30) * 3
),
semantic as (
  select
    n.id,
    row_number() over (order by n.embedding <=> p_query_embedding) as rank_ix
  from filtered n
  where p_query_embedding is not null
    and n.embedding is not null
  limit least(greatest(p_match_count, 1), 30) * 3
),
candidates as (
  select
    coalesce(f.id, s.id) as id,
    f.rank_ix as text_rank,
    s.rank_ix as semantic_rank
  from full_text f
  full outer join semantic s on s.id = f.id
)
select
  n.id,
  n.memory_type,
  n.title,
  n.content,
  n.summary,
  n.occurred_at,
  n.importance,
  n.emotional_intensity,
  n.confidence,
  n.truth_status,
  n.source_id,
  (
    coalesce(0.30 / (1 + c.text_rank), 0)
    + coalesce(0.45 / (1 + c.semantic_rank), 0)
    + (n.importance::double precision / 100.0) * 0.10
    + (n.confidence::double precision / 100.0) * 0.05
    + (n.emotional_intensity::double precision / 100.0) * 0.05
    + case
        when coalesce(trim(p_query_text), '') <> ''
          and lower(n.title) like '%' || lower(trim(p_query_text)) || '%'
        then 0.05
        else 0
      end
  )::double precision as score
from candidates c
join filtered n on n.id = c.id
order by score desc
limit least(greatest(p_match_count, 1), 30);
$matrix_function$;

create or replace function public.matrix_recall(p_payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $matrix_function$
declare
  v_auth_id uuid := auth.uid();
  v_owner_id uuid;
  v_payload_owner uuid;
  v_query text;
  v_embedding extensions.vector(384);
  v_match_count integer;
  v_memory_types text[];
  v_after timestamptz;
  v_before timestamptz;
  v_hops integer;
  v_hits jsonb := '[]'::jsonb;
  v_hit_ids uuid[] := '{}'::uuid[];
  v_seed_ids uuid[] := '{}'::uuid[];
  v_associations jsonb := '[]'::jsonb;
  v_history_id uuid;
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

  v_query := nullif(btrim(p_payload->>'query'), '');
  if v_query is null then
    raise exception 'query is required';
  end if;

  v_match_count := least(
    greatest(coalesce((p_payload->>'limit')::integer, 12), 1),
    30
  );
  v_hops := least(
    greatest(coalesce((p_payload->>'hops')::integer, 1), 0),
    2
  );
  v_after := nullif(btrim(p_payload->>'occurred_after'), '')::timestamptz;
  v_before := nullif(btrim(p_payload->>'occurred_before'), '')::timestamptz;

  if p_payload ? 'memory_types'
     and p_payload->'memory_types' <> 'null'::jsonb
     and jsonb_typeof(p_payload->'memory_types') <> 'array' then
    raise exception 'memory_types must be a JSON array';
  end if;

  if p_payload ? 'memory_types'
     and p_payload->'memory_types' <> 'null'::jsonb then
    select array_agg(value)
      into v_memory_types
    from jsonb_array_elements_text(p_payload->'memory_types') as value;
  end if;

  if p_payload ? 'query_embedding'
     and p_payload->'query_embedding' <> 'null'::jsonb then
    v_embedding := ((p_payload->'query_embedding')::text)::extensions.vector;
  end if;

  with ranked as (
    select *
    from public.recall_memories(
      p_query_text := v_query,
      p_query_embedding := v_embedding,
      p_match_count := v_match_count,
      p_memory_types := v_memory_types,
      p_occurred_after := v_after,
      p_occurred_before := v_before
    )
  )
  select
    coalesce(
      jsonb_agg(to_jsonb(ranked) order by ranked.score desc),
      '[]'::jsonb
    ),
    coalesce(
      array_agg(ranked.id order by ranked.score desc),
      '{}'::uuid[]
    )
  into v_hits, v_hit_ids
  from ranked;

  if cardinality(v_hit_ids) > 0 then
    update public.memory_nodes n
      set recall_count = n.recall_count + 1,
          last_recalled_at = now()
    where n.owner_id = v_owner_id
      and n.id = any(v_hit_ids);

    v_seed_ids := v_hit_ids[1:least(cardinality(v_hit_ids), 5)];

    if v_auth_id is not null and v_hops > 0 then
      select coalesce(
        jsonb_agg(to_jsonb(c) order by c.depth, c.activation desc),
        '[]'::jsonb
      )
      into v_associations
      from public.memory_context(v_seed_ids, v_hops) c;
    end if;
  end if;

  insert into public.retrieval_history (
    owner_id,
    query_text,
    result_node_ids,
    metadata
  ) values (
    v_owner_id,
    v_query,
    v_hit_ids,
    jsonb_build_object(
      'channel', coalesce(p_payload->>'channel', 'rpc'),
      'embedding_model', case
        when v_embedding is null then null
        else 'Supabase/gte-small'
      end,
      'semantic', v_embedding is not null,
      'memory_types', to_jsonb(v_memory_types),
      'occurred_after', v_after,
      'occurred_before', v_before,
      'hops', v_hops,
      'hit_count', cardinality(v_hit_ids)
    )
  ) returning id into v_history_id;

  return jsonb_build_object(
    'query', v_query,
    'history_id', v_history_id,
    'semantic', v_embedding is not null,
    'hits', v_hits,
    'associations', v_associations
  );
end
$matrix_function$;

create or replace function public.matrix_schema_info()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $matrix_function$
select jsonb_build_object(
  'schema_version', '1.2',
  'write_function', 'matrix_remember',
  'write_signature', 'matrix_remember(jsonb)',
  'recall_function', 'matrix_recall',
  'recall_signature', 'matrix_recall(jsonb)',
  'semantic_recall_function', 'matrix_semantic_recall',
  'semantic_recall_signature', 'matrix_semantic_recall(jsonb)',
  'idempotency_field', 'event_key',
  'embedding_model', 'Supabase/gte-small',
  'embedding_dimensions', 384,
  'embedding_mode', 'asynchronous_queue',
  'memory_types', jsonb_build_array(
    'episode', 'fact', 'decision', 'intention', 'project',
    'reflection', 'preference', 'procedure', 'identity', 'hypothesis'
  ),
  'truth_statuses', jsonb_build_array(
    'reported', 'verified', 'inferred', 'disputed', 'unknown'
  ),
  'entity_kinds', jsonb_build_array(
    'person', 'organization', 'place', 'project', 'device',
    'technology', 'concept', 'event', 'document', 'other'
  ),
  'relation_types', jsonb_build_array(
    'related_to', 'caused', 'resulted_in', 'part_of', 'involves',
    'occurred_before', 'occurred_after', 'contradicts', 'supersedes',
    'supports', 'inspired', 'depends_on', 'same_topic_as', 'located_at'
  ),
  'source_types', jsonb_build_array(
    'conversation', 'document', 'email', 'photo', 'audio', 'video',
    'note', 'database', 'web', 'sensor', 'testimony', 'other'
  ),
  'required_fields', jsonb_build_array(
    'event_key', 'memory_type', 'title', 'content'
  ),
  'provenance_rule', 'Provide source_id or a source object',
  'duplicate_behavior', 'Return the existing memory without creating side effects'
);
$matrix_function$;

create or replace function public.matrix_remember(p_payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $matrix_function$
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
    select 1
    from public.memory_nodes n
    where n.id = v_parent_id
      and n.owner_id = v_owner_id
  ) then
    raise exception 'parent_id does not belong to the owner or does not exist';
  end if;

  v_life_period_id := nullif(btrim(p_payload->>'life_period_id'), '')::uuid;
  if v_life_period_id is not null then
    if not exists (
      select 1
      from public.life_periods lp
      where lp.id = v_life_period_id
        and lp.owner_id = v_owner_id
    ) then
      raise exception 'life_period_id does not belong to the owner or does not exist';
    end if;
  else
    select lp.id
      into v_life_period_id
    from public.life_periods lp
    where lp.owner_id = v_owner_id
      and lp.starts_on <= coalesce(v_occurred_at::date, current_date)
      and (
        lp.ends_on is null
        or lp.ends_on >= coalesce(v_occurred_at::date, current_date)
      )
    order by lp.starts_on desc nulls last
    limit 1;
  end if;

  if nullif(btrim(p_payload->>'source_id'), '') is not null then
    v_source_id := (p_payload->>'source_id')::uuid;
    if not exists (
      select 1
      from public.sources s
      where s.id = v_source_id
        and s.owner_id = v_owner_id
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
      owner_id,
      source_type,
      title,
      uri,
      storage_path,
      content_text,
      captured_at,
      checksum,
      metadata
    ) values (
      v_owner_id,
      v_source->>'type',
      nullif(btrim(v_source->>'title'), ''),
      nullif(btrim(v_source->>'uri'), ''),
      nullif(btrim(v_source->>'storage_path'), ''),
      nullif(v_source->>'content_text', ''),
      nullif(btrim(v_source->>'captured_at'), '')::timestamptz,
      nullif(btrim(v_source->>'checksum'), ''),
      coalesce(v_source->'metadata', '{}'::jsonb)
    ) returning id into v_source_id;
  end if;

  insert into public.memory_nodes (
    owner_id,
    event_key,
    memory_type,
    title,
    content,
    summary,
    occurred_at,
    ended_at,
    valid_from,
    valid_to,
    place_text,
    importance,
    emotional_intensity,
    emotional_valence,
    confidence,
    truth_status,
    lifecycle_status,
    access_level,
    source_id,
    life_period_id,
    parent_id,
    metadata
  ) values (
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
  ) returning id into v_memory_id;

  if p_payload ? 'entities'
     and jsonb_typeof(p_payload->'entities') <> 'array' then
    raise exception 'entities must be a JSON array';
  end if;

  for v_entity in
    select value
    from jsonb_array_elements(coalesce(p_payload->'entities', '[]'::jsonb))
  loop
    if nullif(btrim(v_entity->>'kind'), '') is null
       or nullif(btrim(v_entity->>'name'), '') is null then
      raise exception 'each entity requires kind and name';
    end if;

    insert into public.entities as existing (
      owner_id,
      kind,
      canonical_name,
      aliases,
      description,
      metadata
    ) values (
      v_owner_id,
      v_entity->>'kind',
      v_entity->>'name',
      coalesce(
        array(
          select jsonb_array_elements_text(
            coalesce(v_entity->'aliases', '[]'::jsonb)
          )
        ),
        '{}'::text[]
      ),
      nullif(v_entity->>'description', ''),
      coalesce(v_entity->'metadata', '{}'::jsonb)
    )
    on conflict (owner_id, kind, lower(canonical_name))
    do update set
      aliases = (
        select coalesce(
          array_agg(distinct alias_value order by alias_value),
          '{}'::text[]
        )
        from unnest(existing.aliases || excluded.aliases) as alias_value
      ),
      description = coalesce(existing.description, excluded.description),
      metadata = existing.metadata || excluded.metadata,
      updated_at = now()
    returning id into v_entity_id;

    insert into public.memory_entities (
      owner_id,
      memory_node_id,
      entity_id,
      role,
      weight
    ) values (
      v_owner_id,
      v_memory_id,
      v_entity_id,
      coalesce(nullif(v_entity->>'role', ''), 'mentioned'),
      coalesce((v_entity->>'weight')::numeric, 0.5)
    )
    on conflict (memory_node_id, entity_id, role)
    do update set
      weight = greatest(public.memory_entities.weight, excluded.weight);

    v_entity_ids := array_append(v_entity_ids, v_entity_id);
  end loop;

  if p_payload ? 'relations'
     and jsonb_typeof(p_payload->'relations') <> 'array' then
    raise exception 'relations must be a JSON array';
  end if;

  for v_relation in
    select value
    from jsonb_array_elements(coalesce(p_payload->'relations', '[]'::jsonb))
  loop
    v_target_id := nullif(btrim(v_relation->>'target_node_id'), '')::uuid;

    if v_target_id is null
       and nullif(btrim(v_relation->>'target_event_key'), '') is not null then
      select n.id
        into v_target_id
      from public.memory_nodes n
      where n.owner_id = v_owner_id
        and n.event_key = v_relation->>'target_event_key';
    end if;

    if v_target_id is null or not exists (
      select 1
      from public.memory_nodes n
      where n.id = v_target_id
        and n.owner_id = v_owner_id
    ) then
      raise exception 'each relation requires a valid target owned by the user';
    end if;

    if nullif(btrim(v_relation->>'type'), '') is null then
      raise exception 'each relation requires type';
    end if;

    insert into public.memory_edges as existing (
      owner_id,
      source_node_id,
      target_node_id,
      relation_type,
      weight,
      confidence,
      valid_from,
      valid_to,
      source_id,
      metadata
    ) values (
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
end
$matrix_function$;

create or replace function private.process_matrix_embedding_jobs(
  p_batch_size integer default 3,
  p_max_requests integer default 1,
  p_timeout_milliseconds integer default 120000
)
returns void
language plpgsql
security definer
set search_path = ''
as $matrix_function$
declare
  v_batches jsonb[];
  v_batch jsonb;
  v_url text;
  v_secret text;
begin
  select decrypted_secret
    into v_url
  from vault.decrypted_secrets
  where name = 'matrix_project_url';

  select decrypted_secret
    into v_secret
  from vault.decrypted_secrets
  where name = 'matrix_embedding_worker_secret';

  if v_url is null or v_secret is null then
    raise exception 'Matrix worker secrets are not configured';
  end if;

  with numbered_jobs as (
    select
      message || jsonb_build_object('job_id', msg_id) as job_info,
      (row_number() over (order by msg_id) - 1)
        / greatest(p_batch_size, 1) as batch_no
    from pgmq.read(
      queue_name => 'matrix_embedding_jobs',
      vt => greatest(p_timeout_milliseconds / 1000, 30),
      qty => greatest(p_max_requests, 1) * greatest(p_batch_size, 1)
    )
  ),
  batches as (
    select jsonb_agg(
      job_info order by (job_info->>'job_id')::bigint
    ) as items
    from numbered_jobs
    group by batch_no
  )
  select coalesce(array_agg(items), array[]::jsonb[])
    into v_batches
  from batches;

  foreach v_batch in array v_batches loop
    perform net.http_post(
      url => v_url || '/functions/v1/matrix-embedding-worker',
      headers => jsonb_build_object(
        'Content-Type', 'application/json',
        'x-matrix-worker-secret', v_secret
      ),
      body => v_batch,
      timeout_milliseconds => p_timeout_milliseconds
    );
  end loop;
end
$matrix_function$;

create or replace function private.process_matrix_query_embedding_jobs(
  p_batch_size integer default 1,
  p_max_requests integer default 1,
  p_timeout_milliseconds integer default 120000
)
returns void
language plpgsql
security definer
set search_path = ''
as $matrix_function$
declare
  v_batches jsonb[];
  v_batch jsonb;
  v_url text;
  v_secret text;
begin
  select decrypted_secret
    into v_url
  from vault.decrypted_secrets
  where name = 'matrix_project_url';

  select decrypted_secret
    into v_secret
  from vault.decrypted_secrets
  where name = 'matrix_embedding_worker_secret';

  if v_url is null or v_secret is null then
    raise exception 'Matrix worker secrets are not configured';
  end if;

  with numbered_jobs as (
    select
      message || jsonb_build_object('job_id', msg_id) as job_info,
      (row_number() over (order by msg_id) - 1)
        / greatest(p_batch_size, 1) as batch_no
    from pgmq.read(
      queue_name => 'matrix_query_embedding_jobs',
      vt => greatest(p_timeout_milliseconds / 1000, 30),
      qty => greatest(p_max_requests, 1) * greatest(p_batch_size, 1)
    )
  ),
  batches as (
    select jsonb_agg(
      job_info order by (job_info->>'job_id')::bigint
    ) as items
    from numbered_jobs
    group by batch_no
  )
  select coalesce(array_agg(items), array[]::jsonb[])
    into v_batches
  from batches;

  foreach v_batch in array v_batches loop
    perform net.http_post(
      url => v_url || '/functions/v1/matrix-query-embedding-worker',
      headers => jsonb_build_object(
        'Content-Type', 'application/json',
        'x-matrix-worker-secret', v_secret
      ),
      body => v_batch,
      timeout_milliseconds => p_timeout_milliseconds
    );
  end loop;
end
$matrix_function$;

create or replace function private.enqueue_matrix_query_request(
  p_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $matrix_function$
declare
  v_owner_id uuid := auth.uid();
  v_request record;
  v_job_id bigint;
begin
  if v_owner_id is null then
    raise exception 'authenticated user required';
  end if;

  select id, owner_id, query_hash, status
    into v_request
  from public.matrix_recall_requests
  where id = p_request_id
    and owner_id = v_owner_id
  for update;

  if not found then
    raise exception 'recall request not found for owner';
  end if;

  if v_request.status <> 'queued' then
    return;
  end if;

  select pgmq.send(
    'matrix_query_embedding_jobs',
    jsonb_build_object(
      'request_id', v_request.id,
      'owner_id', v_owner_id,
      'query_hash', v_request.query_hash
    )
  ) into v_job_id;

  -- Dispatch immediately for interactive recall. The cron remains the retry path.
  perform private.process_matrix_query_embedding_jobs(1, 1, 120000);
end
$matrix_function$;

create or replace function public.matrix_semantic_recall(p_payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $matrix_function$
declare
  v_owner_id uuid := auth.uid();
  v_query text;
  v_hash text;
  v_request record;
  v_recall_payload jsonb;
begin
  if v_owner_id is null then
    raise exception 'authenticated user required';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be a JSON object';
  end if;

  if nullif(btrim(p_payload->>'owner_id'), '') is not null
     and (p_payload->>'owner_id')::uuid <> v_owner_id then
    raise exception 'owner_id does not match the authenticated user';
  end if;

  v_query := nullif(btrim(p_payload->>'query'), '');
  if v_query is null then
    raise exception 'query is required';
  end if;
  if length(v_query) > 5000 then
    raise exception 'query must be 5000 characters or fewer';
  end if;

  v_hash := md5(lower(v_query));

  perform pg_advisory_xact_lock(
    hashtextextended(v_owner_id::text || ':' || v_hash, 0)
  );

  select *
    into v_request
  from public.matrix_recall_requests
  where owner_id = v_owner_id
    and query_hash = v_hash
  for update;

  if found
     and v_request.status = 'ready'
     and v_request.embedding is not null
     and v_request.expires_at > now() then
    v_recall_payload := p_payload || jsonb_build_object(
      'owner_id', v_owner_id,
      'query', v_query,
      'query_embedding', (v_request.embedding::text)::jsonb,
      'channel', coalesce(p_payload->>'channel', 'skill-sql')
    );

    return jsonb_build_object(
      'status', 'ready',
      'request_id', v_request.id,
      'result', public.matrix_recall(v_recall_payload)
    );
  end if;

  if not found then
    insert into public.matrix_recall_requests (
      owner_id,
      query_text,
      query_hash,
      status
    ) values (
      v_owner_id,
      v_query,
      v_hash,
      'queued'
    ) returning * into v_request;

    perform private.enqueue_matrix_query_request(v_request.id);
  elsif v_request.status in ('error', 'ready')
        or v_request.expires_at <= now() then
    update public.matrix_recall_requests
      set query_text = v_query,
          embedding = null,
          status = 'queued',
          error = null,
          updated_at = now(),
          expires_at = now() + interval '24 hours'
    where id = v_request.id
    returning * into v_request;

    perform private.enqueue_matrix_query_request(v_request.id);
  end if;

  return jsonb_build_object(
    'status', 'pending',
    'request_id', v_request.id,
    'query', v_query,
    'retry_after_ms', 1000
  );
end
$matrix_function$;

-- Seed the embedding queue for rows created before contract 1.2.
update public.memory_nodes
  set title = title
where embedding is null
   or embedding_input_hash is null;

-- Public API permissions.
revoke all on function public.matrix_remember(jsonb) from public, anon;
grant execute on function public.matrix_remember(jsonb) to authenticated, service_role;

revoke all on function public.matrix_recall(jsonb) from public, anon;
grant execute on function public.matrix_recall(jsonb) to authenticated, service_role;

revoke all on function public.matrix_semantic_recall(jsonb) from public, anon;
grant execute on function public.matrix_semantic_recall(jsonb) to authenticated;

revoke all on function public.matrix_schema_info() from public, anon;
grant execute on function public.matrix_schema_info() to authenticated, service_role;

revoke all on function public.recall_memories(
  text,
  extensions.vector,
  integer,
  text[],
  timestamptz,
  timestamptz
) from public, anon;
grant execute on function public.recall_memories(
  text,
  extensions.vector,
  integer,
  text[],
  timestamptz,
  timestamptz
) to authenticated, service_role;

revoke all on function public.memory_context(uuid[], integer) from public, anon;
grant execute on function public.memory_context(uuid[], integer)
  to authenticated, service_role;

-- Trigger and internal function permissions.
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.set_memory_node_updated_at()
  from public, anon, authenticated;
revoke all on function public.archive_memory_version()
  from public, anon, authenticated;

revoke execute on all functions in schema private
  from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.enqueue_matrix_query_request(uuid)
  to authenticated;
alter default privileges in schema private
  revoke execute on functions from public;

comment on function public.set_updated_at() is
  'Generic updated_at trigger for public tables.';
comment on function public.set_memory_node_updated_at() is
  'Memory-specific trigger that ignores embedding and recall maintenance.';
comment on function public.matrix_semantic_recall(jsonb) is
  'Asynchronous semantic recall adapter. Reuse the same payload after pending.';
