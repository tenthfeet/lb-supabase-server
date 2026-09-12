#!/usr/bin/env bash
# Phase 1.1 — replay the repo's migrations into the VPS Postgres.
#
# RUNS ON THE SERVER (no psql or tunnel needed on Windows):
#     scp apply-migrations.sh root@184.168.122.104:/root/
#     bash /root/apply-migrations.sh
#
# Assumes the repo is cloned at /opt/apps/enroll (Phase 4.1).

set -uo pipefail

STACK=/opt/supabase/stacks/enroll
MIGRATIONS=/opt/apps/enroll/supabase/migrations

if [ ! -d "$MIGRATIONS" ]; then
  echo "FAIL: $MIGRATIONS not found. Clone the repo first:"
  echo "  git clone https://github.com/librahmas-hue/lil-brahmas-pathfinder-67845d9c.git /opt/apps/enroll"
  exit 1
fi

cd "$STACK" || exit 1

# Refuse to run against a database that already has application tables.
existing=$(docker compose exec -T db psql -U postgres -tAc \
  "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r';" 2>/dev/null | tr -d '[:space:]')

if [ "${existing:-0}" != "0" ]; then
  echo "STOP: public schema already has $existing table(s)."
  echo "These migrations are not idempotent as a set. Replaying them over an"
  echo "existing schema will fail partway and leave it inconsistent."
  echo
  echo "If this is a deliberate rebuild, drop and recreate the schema first:"
  echo "  docker compose exec -T db psql -U postgres -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"
  echo "  ...then re-grant, per the stock roles.sql, before re-running."
  exit 1
fi

count=$(ls -1 "$MIGRATIONS"/*.sql 2>/dev/null | wc -l)
echo "Applying $count migrations from $MIGRATIONS"
echo

# Ledger of what has run, shared with deploy.sh --with-migrations. Without this
# the next deploy would try to replay all of these, and they are not idempotent.
LEDGER="$STACK/.applied-migrations"
: > "$LEDGER"

applied=0
for f in $(ls -1 "$MIGRATIONS"/*.sql | sort); do
  name=$(basename "$f")
  printf '  %-70s ' "$name"
  if out=$(docker compose exec -T db psql -U postgres -v ON_ERROR_STOP=1 -d postgres < "$f" 2>&1); then
    echo "ok"
    echo "$name" >> "$LEDGER"
    applied=$((applied+1))
  else
    echo "FAILED"
    echo
    echo "$out" | tail -20
    echo
    echo "Stopped at migration $((applied+1)) of $count. The schema is now"
    echo "partially built — fix this file, drop the schema, and start over."
    echo "Ledger at $LEDGER records the $applied that did apply."
    exit 1
  fi
done

echo
echo "All $applied migrations applied. Ledger written to $LEDGER."
echo
echo "--- RLS audit (expect: 0 rows) ---"
docker compose exec -T db psql -U postgres -c "SELECT c.relname, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced, count(p.polname) AS policies FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_policy p ON p.polrelid=c.oid WHERE n.nspname='public' AND c.relkind='r' GROUP BY 1,2,3 HAVING NOT c.relrowsecurity OR count(p.polname)=0 ORDER BY 1;"

echo
echo "--- table count (expect: 47) ---"
docker compose exec -T db psql -U postgres -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r';"
