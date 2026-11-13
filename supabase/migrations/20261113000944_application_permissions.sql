-- Administrative grants are intentionally outside the exposed public schema.
-- No application is enabled automatically; seed reviewed client IDs separately.
create schema matrix_private;
revoke all on schema matrix_private from public, anon, authenticated, service_role;
create table matrix_private.application_grants (
  owner_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null references auth.oauth_clients(id) on delete cascade,
  app_role text not null check (app_role in ('reader','writer','manager')),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (owner_id,client_id)
);
alter table matrix_private.application_grants enable row level security;
revoke all on matrix_private.application_grants from public, anon, authenticated, service_role;
create trigger application_grants_updated_at before update on matrix_private.application_grants
  for each row execute function public.set_updated_at();

-- Private invoker function, callable only by the trusted connection used by MCP.
create function matrix_private.application_role(p_owner uuid,p_client uuid,p_session uuid)
returns text language sql stable security invoker set search_path='' as $$
  select g.app_role from matrix_private.application_grants g
  join auth.oauth_clients c on c.id=g.client_id and c.deleted_at is null
  join auth.sessions s on s.oauth_client_id=c.id and s.user_id=g.owner_id
  where g.owner_id=p_owner and g.client_id=p_client and s.id=p_session
    and (s.not_after is null or s.not_after>now()) and g.enabled
    and exists(select 1 from auth.oauth_consents o
      where o.client_id=c.id and o.user_id=g.owner_id and o.revoked_at is null)
  limit 1
$$;
revoke all on function matrix_private.application_role(uuid,uuid,uuid) from public,anon,authenticated,service_role;

-- OAuth applications must enter through the MCP authorization boundary. Otherwise
-- an app could ignore its MCP role and call the Data API / invoker RPCs directly.
-- Existing owner policies still apply. Password sessions, trusted server work and
-- the MCP's authenticated owner transaction do not carry an OAuth client claim.
do $$
declare table_name text;
begin
  foreach table_name in array array['profiles','life_periods','entities','sources',
    'memory_nodes','memory_edges','memory_entities','memory_versions',
    'retrieval_history','legacy_directives','matrix_recall_requests'] loop
    execute format('create policy matrix_oauth_mcp_only on public.%I as restrictive for all to authenticated using ((select auth.jwt()->>''client_id'') is null) with check ((select auth.jwt()->>''client_id'') is null)',table_name);
  end loop;
end $$;
