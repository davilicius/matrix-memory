#!/usr/bin/env bash
set -euo pipefail
# Only the disposable container supplied by run-permissions.sh, never a URL.
container="$1"
[[ "$container" == supabase_db_matrix-acl-test-* ]] || exit 2
sql() { docker exec -i "$container" psql -X -qAt -U postgres -d postgres -v ON_ERROR_STOP=1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sql <<'SQL'
insert into auth.users(id) values ('33333333-3333-4333-8333-333333333333');
insert into public.memory_nodes(id,owner_id,event_key,memory_type,title,content)
values('44444444-4444-4444-8444-444444444444','33333333-3333-4333-8333-333333333333','race:old','fact','Synthetic','Original');
SQL
payload="$(sql <<'SQL'
select jsonb_build_object('target_id',id,'expected_updated_at',updated_at,'scope','partial','reason','Concurrent change',
  'replacement',jsonb_build_object('event_key','race:new','memory_type','decision','title','New','content','Replacement','source',jsonb_build_object('type','note')))
from public.memory_nodes where id='44444444-4444-4444-8444-444444444444';
SQL
)"
cat > "$tmp/first.sql" <<SQL
begin;
set local application_name='matrix_atomic_race';
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
select public.matrix_supersede(\$payload\$$payload\$payload\$::jsonb)->>'status';
select pg_sleep(3);
commit;
SQL
sql < "$tmp/first.sql" > "$tmp/first.out" &
first_pid=$!
ready=false
for _ in $(seq 1 50); do
  if [[ "$(sql <<< "select count(*) from pg_stat_activity where application_name='matrix_atomic_race' and wait_event='PgSleep'")" == 1 ]]; then ready=true; break; fi
  sleep 0.1
done
[[ "$ready" == true ]] || { wait "$first_pid"; cat "$tmp/first.out"; exit 1; }
# The identical retry waits on the event-key lock, then returns existing.
sql > "$tmp/retry.out" <<SQL &
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
select public.matrix_supersede(\$payload\$$payload\$payload\$::jsonb)->>'status';
commit;
SQL
retry_pid=$!
# A different decision with stale evidence waits on the row, then conflicts.
sql > "$tmp/conflict.out" <<SQL &
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
do \$test\$ begin
  begin
    perform public.matrix_supersede(jsonb_set(\$payload\$$payload\$payload\$::jsonb,'{replacement,event_key}','"race:competing"'));
    raise exception 'Concurrent stale decision accepted';
  exception when sqlstate 'P4090' then null; end;
end \$test\$;
commit;
SQL
conflict_pid=$!
wait "$first_pid"
wait "$retry_pid"
wait "$conflict_pid"
grep -qx created "$tmp/first.out"
grep -qx existing "$tmp/retry.out"
sql <<'SQL'
do $$ begin
  assert (select count(*)=2 from public.memory_nodes where owner_id='33333333-3333-4333-8333-333333333333');
  assert (select count(*)=1 from public.memory_edges where owner_id='33333333-3333-4333-8333-333333333333');
  assert (select count(*)=1 from public.sources where owner_id='33333333-3333-4333-8333-333333333333');
end $$;
delete from auth.users where id='33333333-3333-4333-8333-333333333333';
SQL
echo 'Concurrent retry and stale competing update passed'
