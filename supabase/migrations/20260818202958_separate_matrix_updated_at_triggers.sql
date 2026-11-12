create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  new.updated_at := now();
  return new;
end
$function$;

create or replace function public.set_memory_node_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if row(
    old.event_key, old.memory_type, old.title, old.content, old.summary, old.occurred_at,
    old.ended_at, old.valid_from, old.valid_to, old.place_text, old.importance,
    old.emotional_intensity, old.emotional_valence, old.confidence, old.truth_status,
    old.lifecycle_status, old.access_level, old.source_id, old.life_period_id, old.parent_id,
    old.metadata
  ) is distinct from row(
    new.event_key, new.memory_type, new.title, new.content, new.summary, new.occurred_at,
    new.ended_at, new.valid_from, new.valid_to, new.place_text, new.importance,
    new.emotional_intensity, new.emotional_valence, new.confidence, new.truth_status,
    new.lifecycle_status, new.access_level, new.source_id, new.life_period_id, new.parent_id,
    new.metadata
  ) then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;
  return new;
end
$function$;

drop trigger if exists memory_nodes_set_updated_at on public.memory_nodes;

create trigger memory_nodes_set_updated_at
before update on public.memory_nodes
for each row
execute function public.set_memory_node_updated_at();

comment on function public.set_updated_at() is
  'Generic updated_at trigger for public tables.';

comment on function public.set_memory_node_updated_at() is
  'Memory-specific updated_at trigger that ignores embedding-only maintenance changes.';
