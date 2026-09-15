#!/usr/bin/env bash
# growth, README step 4: build growth's schema from empty, with a ledger.
# RUNS ON THE SERVER AS ROOT, from WHM -> Terminal:
#
#   bash /root/growth-apply-migrations.sh --plan    # guards and counts; writes nothing
#   bash /root/growth-apply-migrations.sh --apply   # the real run; safe to re-run
#
# Pinned to the checkout read on the workstation on 15 Sep 2026: df414acf,
# 264 migrations, supabase/migrations tree f28ddded7cb1. Any other checkout
# stops it. Migrations added after that belong to deploy-growth (README step 6).
#
# The apply logic is enroll's deploy.sh, trimmed to a build from empty:
#
#   - The ledger is supabase_migrations.schema_migrations, the Supabase CLI's
#     table, in enroll's shape plus a nullable `note` column. enroll's
#     .applied-migrations is never read (STACK-PROVISIONING.md 3.3).
#   - Each file and its ledger row commit in ONE transaction under
#     ON_ERROR_STOP. A failure rolls both back, so the file stays pending and a
#     re-run resumes from it.
#   - A file Postgres will not run inside a transaction (here ALTER TYPE ... ADD
#     VALUE, 6 files) runs without one, and says so.
#   - An empty ledger refuses a non-empty public. A non-empty ledger must be
#     exactly the first N files, in order.
#   - Files that also edit content production created through the app
#     (MIGRATION-RECORD.md 6) are not run when they hold no schema, or run as
#     their leading schema lines only. Either way their ledger row carries a
#     note and the whole file's checksum.
#
# Every guard compares against an exact value. A query that errors prints
# nothing, and nothing never equals the value a guard wants -- unlike enroll's
# apply-migrations.sh, where an unreachable database counted as 0 tables.

set -uo pipefail

STACK=/opt/supabase/stacks/growth
REPO=/opt/apps/growth
MIGRATIONS=$REPO/supabase/migrations
LEDGER_TABLE=supabase_migrations.schema_migrations
LOCK=$STACK/.migrations.lock

EXPECT_TREE=f28ddded7cb1
EXPECT_COUNT=264

# Decided 15 Sep 2026 (MIGRATION-RECORD.md 6). These files write content that
# points at rows production created through the app, so on an empty database
# a foreign key refuses them. What they would write is in the source database
# and arrives with step 5's import.
#
# No schema in the file: not run. The ledger row carries the note.
declare -A SKIP=(
  [20260707153842_8d3142cf-e9a3-4498-b0ae-9dbe1687db7f.sql]='not run: content pages under node 50fb8694, which no migration creates (growth step 4, 15 Sep 2026)'
  [20260707163251_1f6b4cb4-cd90-466f-a812-5631552c63fb.sql]='not run: page_blocks for 11 fixed pages no migration creates (growth step 4, 15 Sep 2026)'
  [20260707175304_f0dd9f64-74ad-4580-a79f-5f4f21630b1c.sql]='not run: content pages under node f0ee2a18, which no migration creates (growth step 4, 15 Sep 2026)'
  [20260726090058_fbbd28ee-6f56-4458-a56b-60048bb16a71.sql]='not run: test-user seed against rows no migration creates (growth step 4, 15 Sep 2026)'
  [20260726090647_46be8578-2c0d-4ed1-9e24-b23c7af3b3b3.sql]='not run: test-user seed against rows no migration creates (growth step 4, 15 Sep 2026)'
)
# Schema first, then content: only the first N lines run, in one transaction
# with the ledger row.
declare -A HEAD_LINES=(
  [20260705175005_29dfb1f0-5769-4abd-aaf2-0199599d379f.sql]=62
  [20260726155545_dac6382f-59f4-4c3b-9b0b-6f0cf0b9cb15.sql]=6
)
declare -A HEAD_NOTE=(
  [20260705175005_29dfb1f0-5769-4abd-aaf2-0199599d379f.sql]='lines 1-62 only: kb_languages and kb_entries; the kb_entries row for department 54c8a7ba not run (growth step 4, 15 Sep 2026)'
  [20260726155545_dac6382f-59f4-4c3b-9b0b-6f0cf0b9cb15.sql]='lines 1-6 only: the computed columns; the field rows for template 144d3aa2 not run (growth step 4, 15 Sep 2026)'
)

case "${1:-}" in
  --plan)  MODE=plan ;;
  --apply) MODE=apply ;;
  *) echo "usage: bash $0 --plan | --apply"; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "STOP: exactly one argument"; exit 2; }

die()     { echo; echo "STOP: $*"; exit 1; }
dc()      { ( cd "$STACK" && docker compose "$@" ); }
db_psql() { dc exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
# </dev/null on every call that is not piping SQL: `docker compose exec -T`
# hands this shell's stdin to the container.
db_rows() { db_psql -tAq -c "$1" </dev/null 2>/dev/null | tr -d '\r'; }
db_one()  { db_rows "$1" | head -1 | tr -d '[:space:]'; }
sql_lit() { printf '%s' "$1" | sed "s/'/''/g"; }
# Error output can quote a failing line. 20260914120009 carries a JWT.
mask()    { sed -E 's/eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]*){0,2}/<jwt masked>/g'; }
is_num()  { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

is_skipped() { [ -n "${SKIP[$1]+x}" ]; }
is_head()    { [ -n "${HEAD_LINES[$1]+x}" ]; }

# enroll's deploy.sh, unchanged.
tx_hostile() {
  grep -Eiq "(CREATE|DROP|REINDEX)[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+CONCURRENTLY|ALTER[[:space:]]+TYPE[[:space:]]+[^;]*ADD[[:space:]]+VALUE|^[[:space:]]*(VACUUM|BEGIN[[:space:]]*;|COMMIT[[:space:]]*;|ALTER[[:space:]]+SYSTEM|CREATE[[:space:]]+DATABASE)" "$1"
}

# No ON CONFLICT: only pending files are recorded, so a conflict is a bug, and
# in the one-transaction path it rolls the file back with it.
ledger_insert_sql() {
  local name=$1 sum=$2 note=${3:-} nt=NULL
  [ -n "$note" ] && nt="'$(sql_lit "$note")'"
  printf "INSERT INTO %s (version, name, checksum, note) VALUES ('%s', '%s', '%s', %s);\n" \
    "$LEDGER_TABLE" "$(sql_lit "${name%%_*}")" "$(sql_lit "$name")" "$(sql_lit "$sum")" "$nt"
}

LEDGER_DDL="
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS $LEDGER_TABLE (version text PRIMARY KEY);
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS statements text[];
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS name       text;
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS checksum   text;
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS applied_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS note       text;
"

echo "growth migrations, $MODE, $(date -u '+%F %T') UTC"

# ---- where we are -----------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root"
grep -qx 'COMPOSE_PROJECT_NAME=growth' "$STACK/.env" || die "$STACK/.env does not say COMPOSE_PROJECT_NAME=growth"
dbok=$(dc ps -a --format '{{.Service}}:{{.Status}}' 2>/dev/null | grep -c '^db:.*(healthy)')
[ "$dbok" = 1 ] || die "growth's db container is not (healthy)"

if [ "$MODE" = apply ]; then
  exec 9>"$LOCK" || die "cannot open $LOCK"
  flock -n 9 || die "another run holds $LOCK"
fi

# ---- the checkout -----------------------------------------------------------
tree=$(git -C "$REPO" rev-parse HEAD:supabase/migrations 2>/dev/null)
[ "${tree:0:12}" = "$EXPECT_TREE" ] || die "migrations tree is '${tree:0:12}', expected $EXPECT_TREE: not the checkout read on the workstation"
[ -z "$(git -C "$REPO" status --porcelain -- supabase/migrations 2>&1)" ] || die "uncommitted or untracked files under supabase/migrations"

mapfile -t FILES < <(cd "$MIGRATIONS" && ls -1 -- *.sql | LC_ALL=C sort)
[ "${#FILES[@]}" = "$EXPECT_COUNT" ] || die "${#FILES[@]} migration files, expected $EXPECT_COUNT"
bad=$(printf '%s\n' "${FILES[@]}" | grep -Evc '^[0-9]{14}_[0-9a-f-]+\.sql$')
[ "$bad" = 0 ] || die "$bad file name(s) not <14 digits>_<id>.sql"
dups=$(printf '%s\n' "${FILES[@]}" | cut -d_ -f1 | uniq -d | tr '\n' ' ')
[ -z "$dups" ] || die "timestamp prefix shared by more than one file: $dups"
for s in "${!SKIP[@]}" "${!HEAD_LINES[@]}"; do [ -f "$MIGRATIONS/$s" ] || die "listed file missing: $s"; done
for s in "${!HEAD_LINES[@]}"; do
  [ -n "${HEAD_NOTE[$s]:-}" ] || die "no note for $s"
  [ "$(wc -l < "$MIGRATIONS/$s")" -gt "${HEAD_LINES[$s]}" ] || die "$s is not longer than its ${HEAD_LINES[$s]} schema lines"
  tx_hostile "$MIGRATIONS/$s" && die "$s holds a statement that cannot run in a transaction"
done
echo "checkout: tree $EXPECT_TREE, $EXPECT_COUNT files, clean"

# ---- the database -----------------------------------------------------------
[ "$(db_one 'SELECT 1')" = 1 ] || die "cannot query growth's database"
cron=$(db_one "SELECT count(*) FROM pg_extension WHERE extname='pg_cron'")
[ "$cron" = 1 ] || die "pg_cron not installed (got '$cron'). CREATE EXTENSION pg_cron comes first"
pub=$(db_one "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'")
is_num "$pub" || die "cannot count tables in public (got '$pub')"

have=$(db_one "SELECT count(*) FROM information_schema.tables WHERE table_schema='supabase_migrations' AND table_name='schema_migrations'")
LEDGERED=()
case "$have" in
  0) ;;
  1) n=$(db_one "SELECT count(*) FROM $LEDGER_TABLE")
     is_num "$n" || die "cannot count ledger rows (got '$n')"
     mapfile -t LEDGERED < <(db_rows "SELECT version FROM $LEDGER_TABLE ORDER BY version")
     [ "${#LEDGERED[@]}" = "$n" ] || die "ledger read ${#LEDGERED[@]} versions but counts $n rows" ;;
  *) die "cannot tell whether the ledger exists (got '$have')" ;;
esac
done_n=${#LEDGERED[@]}

if [ "$done_n" -eq 0 ] && [ "$pub" != 0 ]; then
  die "the ledger is empty but public has $pub table(s): not an empty database"
fi
[ "$done_n" -le "$EXPECT_COUNT" ] || die "ledger has $done_n rows, more than $EXPECT_COUNT files"
for i in "${!LEDGERED[@]}"; do
  [ "${LEDGERED[$i]}" = "${FILES[$i]%%_*}" ] || die "ledger row $((i+1)) is ${LEDGERED[$i]} but file $((i+1)) is ${FILES[$i]}: the ledger is not the first $done_n files"
done
echo "database: pg_cron installed, public tables $pub, ledger rows $done_n"

PENDING=("${FILES[@]:$done_n}")
n_skip=0; n_head=0; n_hostile=0; n_atomic=0; hostile=""; heads=""; skipped=""
for f in "${PENDING[@]}"; do
  if is_skipped "$f"; then n_skip=$((n_skip+1)); skipped="$skipped ${f%%_*}"
  elif is_head "$f"; then n_head=$((n_head+1)); heads="$heads ${f%%_*}:1-${HEAD_LINES[$f]}"
  elif tx_hostile "$MIGRATIONS/$f"; then n_hostile=$((n_hostile+1)); hostile="$hostile ${f%%_*}"
  else n_atomic=$((n_atomic+1)); fi
done
echo "pending: ${#PENDING[@]} = atomic $n_atomic + not atomic $n_hostile + schema lines only $n_head + skipped $n_skip"
[ -n "$hostile" ] && echo "not atomic:$hostile"
[ -n "$heads" ] && echo "schema lines only:$heads"
[ -n "$skipped" ] && echo "to skip:$skipped"

if [ "$MODE" = plan ]; then
  echo "plan only: nothing written"
  exit 0
fi
[ "${#PENDING[@]}" -gt 0 ] || { echo "nothing pending"; exit 0; }

# ---- apply ------------------------------------------------------------------
db_psql -q -c "$LEDGER_DDL" </dev/null >/dev/null 2>&1 || die "could not create $LEDGER_TABLE"
[ "$(db_one "SELECT count(*) FROM information_schema.columns WHERE table_schema='supabase_migrations' AND table_name='schema_migrations' AND column_name IN ('version','name','checksum','applied_at','note')")" = 5 ] \
  || die "$LEDGER_TABLE does not have the expected columns"

echo "applying: . atomic  n not atomic  h schema lines only  s skipped"
ok=0; na=0; hd=0; sk=0; i=$done_n
for f in "${PENDING[@]}"; do
  path=$MIGRATIONS/$f
  sum=$(sha256sum "$path" | cut -d' ' -f1)
  i=$((i+1))

  if is_skipped "$f"; then
    db_psql -q -c "$(ledger_insert_sql "$f" "$sum" "${SKIP[$f]}")" </dev/null >/dev/null 2>&1 \
      || die "could not record skipped $f"
    sk=$((sk+1)); printf 's'

  elif is_head "$f"; then
    # The leading schema lines and the ledger row in one transaction. The
    # checksum recorded is the whole file's, as for any other file.
    if out=$( { printf "SET lock_timeout = '60s';\n"
                head -n "${HEAD_LINES[$f]}" "$path"
                printf '\n;\n'
                ledger_insert_sql "$f" "$sum" "${HEAD_NOTE[$f]}"
              } | db_psql -q --single-transaction 2>&1 ); then
      hd=$((hd+1)); printf 'h'
    else
      echo; echo "FAILED, schema lines only: $f"
      printf '%s\n' "$out" | mask | tail -20
      die "file $i of $EXPECT_COUNT failed and was rolled back: nothing from it applied, and it is still pending"
    fi

  elif tx_hostile "$path"; then
    # No wrapper: Postgres will not run this file inside a transaction.
    if out=$( { cat "$path"; printf '\n;\n'; } | db_psql -q 2>&1 ); then
      db_psql -q -c "$(ledger_insert_sql "$f" "$sum")" </dev/null >/dev/null 2>&1 \
        || die "$f ran but its ledger row did not: record it by hand before any re-run"
      na=$((na+1)); printf 'n'
    else
      echo; echo "FAILED, not atomic: $f"
      printf '%s\n' "$out" | mask | tail -20
      die "$f failed outside a transaction, so it may be half applied. Look before re-running"
    fi

  else
    # The file and its ledger row in one transaction. The lone ';' ends a final
    # statement the file left unterminated, which psql would drop at EOF.
    if out=$( { printf "SET lock_timeout = '60s';\n"
                cat "$path"
                printf '\n;\n'
                ledger_insert_sql "$f" "$sum"
              } | db_psql -q --single-transaction 2>&1 ); then
      ok=$((ok+1)); printf '.'
    else
      echo; echo "FAILED: $f"
      printf '%s\n' "$out" | mask | tail -20
      die "file $i of $EXPECT_COUNT failed and was rolled back: nothing from it applied, and it is still pending"
    fi
  fi
  [ $((i % 50)) -eq 0 ] && printf ' %s\n' "$i"
done
echo

# ---- after ------------------------------------------------------------------
if [ $((ok+na+hd)) -gt 0 ]; then
  if db_psql -q -c "NOTIFY pgrst, 'reload schema';" </dev/null >/dev/null 2>&1; then
    echo "NOTIFY pgrst sent"
  else
    echo "!! NOTIFY pgrst failed: restart the rest container"
  fi
  echo "pgrst event triggers: $(db_one "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('pgrst_ddl_watch','pgrst_drop_watch')") of 2"
fi

rows=$(db_one "SELECT count(*) FROM $LEDGER_TABLE")
echo "this run: atomic $ok, not atomic $na, schema lines only $hd, skipped $sk"
echo "ledger rows: $rows of $EXPECT_COUNT, with a note: $(db_one "SELECT count(*) FROM $LEDGER_TABLE WHERE note IS NOT NULL")"
echo "public tables: $(db_one "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'")"
# Names and schedules only: a job's command can carry a key.
db_rows "SELECT 'cron job '||jobid||': '||jobname||' | '||schedule||' | active '||active||' | calls lovable.app: '||(command LIKE '%lovable.app%') FROM cron.job ORDER BY jobid"
[ "$rows" = "$EXPECT_COUNT" ] || die "the ledger has '$rows' rows after the run, expected $EXPECT_COUNT"
echo "done: every migration is in the ledger"
