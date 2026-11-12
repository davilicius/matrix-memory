
revoke all on function public.archive_memory_version() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.validate_memory_edge_owner() from public, anon, authenticated;
revoke all on function public.validate_memory_entity_owner() from public, anon, authenticated;

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke all on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$$;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists life_periods_own on public.life_periods;
drop policy if exists entities_own on public.entities;
drop policy if exists sources_own on public.sources;
drop policy if exists memory_nodes_own on public.memory_nodes;
drop policy if exists memory_edges_own on public.memory_edges;
drop policy if exists memory_entities_own on public.memory_entities;
drop policy if exists memory_versions_select_own on public.memory_versions;
drop policy if exists retrieval_history_own on public.retrieval_history;
drop policy if exists legacy_directives_own on public.legacy_directives;

create policy profiles_select_own on public.profiles
  for select using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy life_periods_own on public.life_periods
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy entities_own on public.entities
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy sources_own on public.sources
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy memory_nodes_own on public.memory_nodes
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy memory_edges_own on public.memory_edges
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy memory_entities_own on public.memory_entities
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy memory_versions_select_own on public.memory_versions
  for select using (owner_id = (select auth.uid()));
create policy retrieval_history_own on public.retrieval_history
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy legacy_directives_own on public.legacy_directives
  for all using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

create index if not exists life_periods_owner_id_idx on public.life_periods(owner_id);
create index if not exists sources_owner_id_idx on public.sources(owner_id);
create index if not exists memory_nodes_source_id_idx on public.memory_nodes(source_id);
create index if not exists memory_nodes_life_period_id_idx on public.memory_nodes(life_period_id);
create index if not exists memory_nodes_parent_id_idx on public.memory_nodes(parent_id);
create index if not exists memory_edges_source_node_id_idx on public.memory_edges(source_node_id);
create index if not exists memory_edges_target_node_id_idx on public.memory_edges(target_node_id);
create index if not exists memory_edges_source_id_idx on public.memory_edges(source_id);
create index if not exists memory_entities_memory_node_id_idx on public.memory_entities(memory_node_id);
create index if not exists memory_entities_entity_id_idx on public.memory_entities(entity_id);
create index if not exists memory_versions_owner_id_idx on public.memory_versions(owner_id);
create index if not exists memory_versions_memory_node_id_idx on public.memory_versions(memory_node_id);
create index if not exists retrieval_history_owner_id_idx on public.retrieval_history(owner_id);
create index if not exists legacy_directives_owner_id_idx on public.legacy_directives(owner_id);
