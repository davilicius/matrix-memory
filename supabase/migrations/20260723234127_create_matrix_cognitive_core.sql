
create extension if not exists vector with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  full_name text,
  birth_date date,
  timezone text not null default 'America/Mexico_City',
  default_language text not null default 'es',
  biography text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.life_periods (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  description text,
  starts_on date,
  ends_on date,
  importance smallint not null default 50 check (importance between 0 and 100),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on is null or starts_on is null or ends_on >= starts_on)
);

create table public.entities (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in (
    'person','organization','place','project','device','technology',
    'concept','event','document','other'
  )),
  canonical_name text not null,
  aliases text[] not null default '{}',
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index entities_owner_kind_name_uidx
  on public.entities (owner_id, kind, lower(canonical_name));
create index entities_name_trgm_idx
  on public.entities using gin (canonical_name extensions.gin_trgm_ops);

create table public.sources (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  source_type text not null check (source_type in (
    'conversation','document','email','photo','audio','video','note',
    'database','web','sensor','testimony','other'
  )),
  title text,
  uri text,
  storage_path text,
  content_text text,
  captured_at timestamptz,
  checksum text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.memory_nodes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  memory_type text not null check (memory_type in (
    'episode','fact','decision','intention','project','reflection',
    'preference','procedure','identity','hypothesis'
  )),
  title text not null,
  content text not null,
  summary text,
  occurred_at timestamptz,
  ended_at timestamptz,
  valid_from timestamptz,
  valid_to timestamptz,
  place_text text,
  importance smallint not null default 50 check (importance between 0 and 100),
  emotional_intensity smallint not null default 0 check (emotional_intensity between 0 and 100),
  emotional_valence smallint not null default 0 check (emotional_valence between -100 and 100),
  confidence smallint not null default 70 check (confidence between 0 and 100),
  truth_status text not null default 'reported' check (truth_status in (
    'reported','verified','inferred','disputed','unknown'
  )),
  lifecycle_status text not null default 'active' check (lifecycle_status in (
    'active','superseded','archived'
  )),
  access_level text not null default 'private' check (access_level in (
    'private','trusted','family','legacy'
  )),
  source_id uuid references public.sources(id) on delete set null,
  life_period_id uuid references public.life_periods(id) on delete set null,
  parent_id uuid references public.memory_nodes(id) on delete set null,
  embedding extensions.vector(384),
  embedding_model text not null default 'Supabase/gte-small',
  fts tsvector generated always as (
    setweight(to_tsvector('spanish', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('spanish', coalesce(summary, '')), 'B') ||
    setweight(to_tsvector('spanish', coalesce(content, '')), 'C') ||
    setweight(to_tsvector('spanish', coalesce(place_text, '')), 'D')
  ) stored,
  recall_count integer not null default 0,
  last_recalled_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ended_at is null or occurred_at is null or ended_at >= occurred_at),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  check (parent_id is null or parent_id <> id)
);

create index memory_nodes_owner_type_idx
  on public.memory_nodes (owner_id, memory_type, occurred_at desc);
create index memory_nodes_owner_status_idx
  on public.memory_nodes (owner_id, lifecycle_status);
create index memory_nodes_fts_idx
  on public.memory_nodes using gin (fts);
create index memory_nodes_embedding_hnsw_idx
  on public.memory_nodes using hnsw (embedding extensions.vector_cosine_ops);

create table public.memory_edges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  source_node_id uuid not null references public.memory_nodes(id) on delete cascade,
  target_node_id uuid not null references public.memory_nodes(id) on delete cascade,
  relation_type text not null check (relation_type in (
    'related_to','caused','resulted_in','part_of','involves',
    'occurred_before','occurred_after','contradicts','supersedes',
    'supports','inspired','depends_on','same_topic_as','located_at'
  )),
  weight numeric(4,3) not null default 0.500 check (weight between 0 and 1),
  confidence smallint not null default 70 check (confidence between 0 and 100),
  valid_from timestamptz,
  valid_to timestamptz,
  source_id uuid references public.sources(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (source_node_id <> target_node_id),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  unique (owner_id, source_node_id, target_node_id, relation_type)
);

create index memory_edges_source_idx
  on public.memory_edges (owner_id, source_node_id);
create index memory_edges_target_idx
  on public.memory_edges (owner_id, target_node_id);

create table public.memory_entities (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  memory_node_id uuid not null references public.memory_nodes(id) on delete cascade,
  entity_id uuid not null references public.entities(id) on delete cascade,
  role text not null default 'mentioned',
  weight numeric(4,3) not null default 0.500 check (weight between 0 and 1),
  created_at timestamptz not null default now(),
  unique (memory_node_id, entity_id, role)
);

create index memory_entities_node_idx
  on public.memory_entities (owner_id, memory_node_id);
create index memory_entities_entity_idx
  on public.memory_entities (owner_id, entity_id);

create table public.memory_versions (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  memory_node_id uuid not null references public.memory_nodes(id) on delete cascade,
  version_no integer not null,
  snapshot jsonb not null,
  change_reason text,
  created_at timestamptz not null default now()
);

create index memory_versions_node_idx
  on public.memory_versions (owner_id, memory_node_id, version_no desc);

create table public.retrieval_history (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  query_text text not null,
  result_node_ids uuid[] not null default '{}',
  feedback smallint check (feedback between -1 and 1),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index retrieval_history_owner_created_idx
  on public.retrieval_history (owner_id, created_at desc);

create table public.legacy_directives (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  beneficiary_contact text,
  instructions text not null,
  activation_condition text,
  is_active boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, full_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'full_name'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

insert into public.profiles (id, display_name, full_name)
select
  id,
  coalesce(raw_user_meta_data->>'display_name', raw_user_meta_data->>'full_name', split_part(email, '@', 1)),
  raw_user_meta_data->>'full_name'
from auth.users
on conflict (id) do nothing;

create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger life_periods_set_updated_at before update on public.life_periods
  for each row execute function public.set_updated_at();
create trigger entities_set_updated_at before update on public.entities
  for each row execute function public.set_updated_at();
create trigger sources_set_updated_at before update on public.sources
  for each row execute function public.set_updated_at();
create trigger memory_nodes_set_updated_at before update on public.memory_nodes
  for each row execute function public.set_updated_at();
create trigger legacy_directives_set_updated_at before update on public.legacy_directives
  for each row execute function public.set_updated_at();

create or replace function public.validate_memory_edge_owner()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  source_owner uuid;
  target_owner uuid;
begin
  select owner_id into source_owner from public.memory_nodes where id = new.source_node_id;
  select owner_id into target_owner from public.memory_nodes where id = new.target_node_id;
  if source_owner is null or target_owner is null then
    raise exception 'Memory edge references a missing node';
  end if;
  if new.owner_id <> source_owner or new.owner_id <> target_owner then
    raise exception 'Memory edge may only connect nodes owned by the same user';
  end if;
  return new;
end;
$$;

create trigger memory_edges_validate_owner
  before insert or update on public.memory_edges
  for each row execute function public.validate_memory_edge_owner();

create or replace function public.validate_memory_entity_owner()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  node_owner uuid;
  linked_entity_owner uuid;
begin
  select owner_id into node_owner from public.memory_nodes where id = new.memory_node_id;
  select owner_id into linked_entity_owner from public.entities where id = new.entity_id;
  if node_owner is null or linked_entity_owner is null then
    raise exception 'Memory entity link references a missing record';
  end if;
  if new.owner_id <> node_owner or new.owner_id <> linked_entity_owner then
    raise exception 'Memory entity link may only join records owned by the same user';
  end if;
  return new;
end;
$$;

create trigger memory_entities_validate_owner
  before insert or update on public.memory_entities
  for each row execute function public.validate_memory_entity_owner();

create or replace function public.archive_memory_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_version integer;
begin
  select coalesce(max(version_no), 0) + 1
    into next_version
  from public.memory_versions
  where memory_node_id = old.id;

  insert into public.memory_versions (
    owner_id, memory_node_id, version_no, snapshot, change_reason
  )
  values (
    old.owner_id,
    old.id,
    next_version,
    to_jsonb(old) - 'fts' - 'embedding',
    coalesce(current_setting('app.change_reason', true), 'Actualización de memoria')
  );
  return new;
end;
$$;

create trigger memory_nodes_archive_version
  before update on public.memory_nodes
  for each row
  when (
    old.title is distinct from new.title or
    old.content is distinct from new.content or
    old.summary is distinct from new.summary or
    old.memory_type is distinct from new.memory_type or
    old.truth_status is distinct from new.truth_status or
    old.lifecycle_status is distinct from new.lifecycle_status or
    old.occurred_at is distinct from new.occurred_at or
    old.valid_from is distinct from new.valid_from or
    old.valid_to is distinct from new.valid_to
  )
  execute function public.archive_memory_version();

alter table public.profiles enable row level security;
alter table public.life_periods enable row level security;
alter table public.entities enable row level security;
alter table public.sources enable row level security;
alter table public.memory_nodes enable row level security;
alter table public.memory_edges enable row level security;
alter table public.memory_entities enable row level security;
alter table public.memory_versions enable row level security;
alter table public.retrieval_history enable row level security;
alter table public.legacy_directives enable row level security;

create policy profiles_select_own on public.profiles
  for select using (id = auth.uid());
create policy profiles_update_own on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

create policy life_periods_own on public.life_periods
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy entities_own on public.entities
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy sources_own on public.sources
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy memory_nodes_own on public.memory_nodes
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy memory_edges_own on public.memory_edges
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy memory_entities_own on public.memory_entities
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy memory_versions_select_own on public.memory_versions
  for select using (owner_id = auth.uid());
create policy retrieval_history_own on public.retrieval_history
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy legacy_directives_own on public.legacy_directives
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

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
set search_path = public, extensions
as $$
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
      order by ts_rank_cd(n.fts, websearch_to_tsquery('spanish', p_query_text)) desc
    ) as rank_ix
  from filtered n
  where coalesce(trim(p_query_text), '') <> ''
    and n.fts @@ websearch_to_tsquery('spanish', p_query_text)
  order by rank_ix
  limit least(greatest(p_match_count, 1), 30) * 3
),
semantic as (
  select
    n.id,
    row_number() over (order by n.embedding <=> p_query_embedding) as rank_ix
  from filtered n
  where p_query_embedding is not null
    and n.embedding is not null
  order by rank_ix
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
    coalesce(0.30 / (1 + c.text_rank), 0) +
    coalesce(0.45 / (1 + c.semantic_rank), 0) +
    (n.importance::double precision / 100.0) * 0.10 +
    (n.confidence::double precision / 100.0) * 0.05 +
    (n.emotional_intensity::double precision / 100.0) * 0.05 +
    case
      when coalesce(trim(p_query_text), '') <> ''
       and lower(n.title) like '%' || lower(trim(p_query_text)) || '%'
      then 0.05 else 0
    end
  )::double precision as score
from candidates c
join filtered n on n.id = c.id
order by score desc
limit least(greatest(p_match_count, 1), 30);
$$;

create or replace function public.memory_context(
  p_seed_ids uuid[],
  p_hops integer default 1
)
returns table (
  node_id uuid,
  depth integer,
  activation double precision,
  memory_type text,
  title text,
  summary text,
  occurred_at timestamptz,
  truth_status text
)
language sql
stable
security invoker
set search_path = public
as $$
with recursive walk(node_id, depth, activation, path) as (
  select n.id, 0, 1.0::double precision, array[n.id]
  from public.memory_nodes n
  where n.owner_id = auth.uid()
    and n.id = any(p_seed_ids)
    and n.lifecycle_status = 'active'

  union all

  select
    case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end,
    w.depth + 1,
    w.activation * e.weight::double precision * 0.75,
    w.path || case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end
  from walk w
  join public.memory_edges e
    on e.owner_id = auth.uid()
   and (e.source_node_id = w.node_id or e.target_node_id = w.node_id)
  where w.depth < least(greatest(p_hops, 0), 2)
    and not (
      case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end
      = any(w.path)
    )
),
ranked as (
  select w.node_id, min(w.depth) as depth, max(w.activation) as activation
  from walk w
  group by w.node_id
)
select
  n.id,
  r.depth,
  r.activation,
  n.memory_type,
  n.title,
  n.summary,
  n.occurred_at,
  n.truth_status
from ranked r
join public.memory_nodes n on n.id = r.node_id
where n.owner_id = auth.uid()
order by r.depth, r.activation desc, n.importance desc;
$$;

grant execute on function public.recall_memories(
  text, extensions.vector, integer, text[], timestamptz, timestamptz
) to authenticated;
grant execute on function public.memory_context(uuid[], integer) to authenticated;

comment on table public.memory_nodes is
  'Atomic autobiographical and professional memories with provenance, temporal context, salience and semantic embeddings.';
comment on table public.memory_edges is
  'Typed temporal, causal, semantic and evidential links used for associative recall.';
comment on table public.sources is
  'Immutable-oriented provenance for conversations, files, media and other original evidence.';
comment on table public.legacy_directives is
  'Inactive-by-default future access instructions. This table does not grant access by itself.';
