#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-strict}"
case "$mode" in strict|legacy) ;; *) echo 'Use strict or legacy' >&2; exit 2 ;; esac
test_root="$(mktemp -d)"
project="matrix-acl-test-$$"
mkdir -p "$test_root/supabase/migrations"
cat > "$test_root/supabase/config.toml" <<EOF
project_id = "$project"
[db]
port = 55432
major_version = 17
[db.seed]
enabled = false
EOF
cleanup() {
  supabase --workdir "$test_root" stop --no-backup || true
  rm -rf "$test_root"
}
trap cleanup EXIT
sql() {
  docker exec -i "supabase_db_$project" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1
}
suite() {
  { echo "set matrix.test_mode = '$mode';"; cat tests/permissions.sql; } | sql
  supabase --workdir "$test_root" test db --local "$PWD/tests/contract.sql"
}

# Only local containers; no link, project ref, API token or remote database URL.
supabase --workdir "$test_root" db start
if [[ "$mode" == strict ]]; then
  cp tests/no-auto-grants.sql "$test_root/supabase/migrations/0000_test_defaults.sql"
else
  cat > "$test_root/supabase/migrations/0000_test_defaults.sql" <<'SQL'
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;
SQL
fi
cp supabase/migrations/000[12]_*.sql "$test_root/supabase/migrations/"
supabase --workdir "$test_root" migration up --local
if [[ "$mode" == strict ]]; then sql < tests/before-grants.sql; fi
cp supabase/migrations/20261021211445_explicit_server_rpc_grants.sql "$test_root/supabase/migrations/"
supabase --workdir "$test_root" migration up --local
sql < tests/before-server-recall.sql
cp supabase/migrations/20261021212808_server_recall_owner_scope.sql "$test_root/supabase/migrations/"
supabase --workdir "$test_root" migration up --local
suite

# Fresh install/reset with strict defaults recreated BEFORE any Matrix table.
supabase --workdir "$test_root" db reset --local --no-seed
suite

# Reapplication must not broaden ACLs or change behavior.
sql < supabase/migrations/20261021211445_explicit_server_rpc_grants.sql
sql < supabase/migrations/20261021212808_server_recall_owner_scope.sql
suite
supabase --workdir "$test_root" db advisors --local --type security --level warn --fail-on error
