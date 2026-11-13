-- Keep explicit denial for non-administrative roles and index FK cleanup.
create policy application_grants_deny_clients on matrix_private.application_grants
  for all to public using(false) with check(false);
create index application_grants_client_idx on matrix_private.application_grants(client_id);
-- Scalar SELECT around auth.jwt() makes the per-statement initplan explicit to
-- both PostgreSQL and Supabase's linter; the authorization predicate is unchanged.
do $$
declare table_name text;
begin
 foreach table_name in array array['profiles','life_periods','entities','sources',
  'memory_nodes','memory_edges','memory_entities','memory_versions',
  'retrieval_history','legacy_directives','matrix_recall_requests'] loop
  execute format('alter policy matrix_oauth_mcp_only on public.%I using (((select auth.jwt()) ->> ''client_id'') is null) with check (((select auth.jwt()) ->> ''client_id'') is null)',table_name);
 end loop;
end $$;
