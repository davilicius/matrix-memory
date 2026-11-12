-- Matrix 1.2 explicitly supports service_role in matrix_remember/matrix_recall.
-- These SECURITY INVOKER RPCs also require table privileges; BYPASSRLS alone
-- does not grant them. Do not restore broad Supabase default privileges.
-- Workers use SUPABASE_DB_URL, not service_role API keys: this is an RPC fix,
-- not a grant to an assumed worker login.

grant select on table public.life_periods to service_role;
grant select, insert on table public.sources to service_role;
grant select, insert, update on table public.memory_nodes to service_role;
grant select, insert, update on table public.entities to service_role;
grant select, insert, update on table public.memory_entities to service_role;
grant select, insert, update on table public.memory_edges to service_role;
grant select, insert on table public.retrieval_history to service_role;

-- No anon grants, DELETE, TRUNCATE, schema-wide/default grants, queue/Vault
-- access, or RLS/policy changes. UUID defaults need no sequence privileges.
