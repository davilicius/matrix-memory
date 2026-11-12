
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

do $m$ begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.memory_nodes'::regclass
      and conname = 'memory_nodes_embedding_status_check'
  ) then
    alter table public.memory_nodes add constraint memory_nodes_embedding_status_check
      check (embedding_status in ('pending','processing','ready','error'));
  end if;
end $m$;

create or replace function private.matrix_embedding_hash(
  p_title text, p_summary text, p_content text, p_place_text text
) returns text language sql immutable set search_path = '' as $m$
  select md5(concat_ws(E'\n\n', coalesce(p_title, ''), coalesce(p_summary, ''),
    coalesce(p_content, ''), coalesce(p_place_text, '')))
$m$;

create or replace function private.prepare_matrix_embedding()
returns trigger language plpgsql security invoker set search_path = '' as $m$
declare v_hash text;
begin
  v_hash := private.matrix_embedding_hash(new.title,new.summary,new.content,new.place_text);
  if tg_op = 'INSERT' or v_hash is distinct from old.embedding_input_hash then
    new.embedding := null;
    new.embedding_status := 'pending';
    new.embedding_input_hash := v_hash;
    new.embedding_updated_at := null;
    new.embedding_error := null;
  end if;
  return new;
end $m$;

create or replace function private.enqueue_matrix_embedding()
returns trigger language plpgsql security definer set search_path = '' as $m$
begin
  if new.embedding_status = 'pending' and (
    tg_op = 'INSERT'
    or new.embedding_input_hash is distinct from old.embedding_input_hash
    or old.embedding_status is distinct from 'pending'
  ) then
    perform pgmq.send(
      queue_name => 'matrix_embedding_jobs',
      msg => jsonb_build_object('memory_id',new.id,'owner_id',new.owner_id,'input_hash',new.embedding_input_hash)
    );
  end if;
  return new;
end $m$;

create or replace function public.archive_memory_version()
returns trigger language plpgsql security invoker set search_path = '' as $m$
declare next_version integer; substantive_change boolean;
begin
  substantive_change := row(
    old.event_key,old.memory_type,old.title,old.content,old.summary,old.occurred_at,
    old.ended_at,old.valid_from,old.valid_to,old.place_text,old.importance,
    old.emotional_intensity,old.emotional_valence,old.confidence,old.truth_status,
    old.lifecycle_status,old.access_level,old.source_id,old.life_period_id,old.parent_id,old.metadata
  ) is distinct from row(
    new.event_key,new.memory_type,new.title,new.content,new.summary,new.occurred_at,
    new.ended_at,new.valid_from,new.valid_to,new.place_text,new.importance,
    new.emotional_intensity,new.emotional_valence,new.confidence,new.truth_status,
    new.lifecycle_status,new.access_level,new.source_id,new.life_period_id,new.parent_id,new.metadata
  );
  if not substantive_change then return new; end if;
  select coalesce(max(mv.version_no),0)+1 into next_version
  from public.memory_versions mv where mv.memory_node_id=old.id;
  insert into public.memory_versions(owner_id,memory_node_id,version_no,snapshot,change_reason)
  values(
    old.owner_id,old.id,next_version,
    to_jsonb(old)-'fts'-'embedding'-'embedding_status'-'embedding_input_hash'
      -'embedding_updated_at'-'embedding_error'-'recall_count'-'last_recalled_at'-'updated_at',
    coalesce(current_setting('app.change_reason',true),'Actualización de memoria')
  );
  return new;
end $m$;

create or replace function public.set_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $m$
begin
  if row(
    old.event_key,old.memory_type,old.title,old.content,old.summary,old.occurred_at,
    old.ended_at,old.valid_from,old.valid_to,old.place_text,old.importance,
    old.emotional_intensity,old.emotional_valence,old.confidence,old.truth_status,
    old.lifecycle_status,old.access_level,old.source_id,old.life_period_id,old.parent_id,old.metadata
  ) is distinct from row(
    new.event_key,new.memory_type,new.title,new.content,new.summary,new.occurred_at,
    new.ended_at,new.valid_from,new.valid_to,new.place_text,new.importance,
    new.emotional_intensity,new.emotional_valence,new.confidence,new.truth_status,
    new.lifecycle_status,new.access_level,new.source_id,new.life_period_id,new.parent_id,new.metadata
  ) then new.updated_at:=now(); else new.updated_at:=old.updated_at; end if;
  return new;
end $m$;

drop trigger if exists memory_nodes_prepare_embedding on public.memory_nodes;
create trigger memory_nodes_prepare_embedding
before insert or update of title,summary,content,place_text on public.memory_nodes
for each row execute function private.prepare_matrix_embedding();

select pgmq.create('matrix_embedding_jobs');

drop trigger if exists memory_nodes_enqueue_embedding on public.memory_nodes;
create trigger memory_nodes_enqueue_embedding
after insert or update of title,summary,content,place_text,embedding_status on public.memory_nodes
for each row execute function private.enqueue_matrix_embedding();

revoke all on function private.matrix_embedding_hash(text,text,text,text) from public,anon,authenticated;
revoke all on function private.prepare_matrix_embedding() from public,anon,authenticated;
revoke all on function private.enqueue_matrix_embedding() from public,anon,authenticated;

update public.memory_nodes set title=title
where embedding is null or embedding_input_hash is null;
