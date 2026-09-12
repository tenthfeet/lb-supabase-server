#!/usr/bin/env bash
# One-command deploy for enroll.lilbrahmas. RUNS ON THE SERVER AS ROOT.
#
#   deploy-enroll                        # frontend + edge functions
#   deploy-enroll --with-migrations      # ...and apply new migrations
#   deploy-enroll --frontend-only
#   deploy-enroll --functions-only
#   deploy-enroll --migrations-only      # schema only, nothing published
#   deploy-enroll --list-migrations      # what WOULD run; changes nothing
#   deploy-enroll --baseline-migrations  # adopt an unrecorded schema, run nothing
#   deploy-enroll --mark-applied=<file>  # record one migration you ran by hand
#   deploy-enroll --with-migrations --skip-backup   # only if you just took one
#
# Migrations are opt-in on purpose. Schema changes should be a decision, not a
# side effect of pulling code.
#
# Applying them is idempotent. Three things make it so:
#
#   1. The ledger of what has run lives IN THE DATABASE
#      (supabase_migrations.schema_migrations -- the same table the Supabase CLI
#      uses), not in a file beside the stack. A ledger on disk is a second copy
#      of a fact the database already owns, and the two drift the moment either
#      is restored without the other: restore last night's database against
#      today's file and every migration since looks applied; lose the file and
#      all 54 replay over a live schema, which these files do NOT survive.
#      A ledger inside the database is dumped, restored and rolled back WITH
#      the schema it describes, always at the same point in time.
#
#   2. Each file is applied and recorded in ONE transaction. Either the schema
#      moved and the ledger says so, or neither happened and the file is still
#      pending. There is no in-between for a later run to misread -- which is
#      exactly what an interruption between `psql` and `echo >> ledger` used to
#      leave behind.
#
#   3. Only files the ledger has never seen are considered. Re-running a deploy,
#      or deploying ten times in a row, applies nothing twice.
#
# $STACK/.applied-migrations is still written, as a plain-text mirror for humans
# and for continuity with the older docs, but nothing reads it for a decision
# after the one-time import described in the migrations section.
#
# Why the build runs in a container: this server has no Node, and installing
# ea-nodejs would add a package for cPanel's nightly updater to break. Alpine
# keeps native deps (@swc/core, @rollup) on their musl builds, which the
# lockfile already carries.
#
# Uses BUN, not npm. package-lock.json is a stale one-time export (untouched
# since 31 Jul); Lovable actually maintains bun.lock, updated on every
# dependency change (bun.lockb, the older binary lockfile, has been abandoned
# since the initial commit). `npm ci` demands package.json and
# package-lock.json match exactly, so it broke the first time a dependency
# changed. `bun install --frozen-lockfile` reads the lockfile Lovable actually
# keeps current, and fails the same way npm ci did if THAT ever drifts.

set -uo pipefail

REPO=/opt/apps/enroll
STACK=/opt/supabase/stacks/enroll
DOCROOT=/home/enroll/public_html
CPUSER=enroll
BUN_IMAGE=oven/bun:1-alpine

MIGRATIONS=$REPO/supabase/migrations
LEDGER_TABLE=supabase_migrations.schema_migrations
LEDGER_MIRROR=$STACK/.applied-migrations
MIGRATION_LOCK=$STACK/.migrations.lock

# Outside the web root on purpose. A dump under public_html is downloadable by
# anyone who guesses the filename, and it holds every row in the database.
BACKUP_DIR=/opt/backups/enroll
BACKUP_KEEP=10
BACKUP_FILE=

DO_FRONTEND=1
DO_FUNCTIONS=1
DO_MIGRATIONS=0
LIST_ONLY=0
BASELINE=0
SKIP_BACKUP=0
MARK_APPLIED=

# The read-only and record-only modes imply --skip-pull: they answer a question
# about the database as it stands, and moving the checkout underneath the answer
# would make it a different question.
for arg in "$@"; do
  case "$arg" in
    --with-migrations)     DO_MIGRATIONS=1 ;;
    --frontend-only)       DO_FUNCTIONS=0 ;;
    --functions-only)      DO_FRONTEND=0 ;;
    --migrations-only)     DO_MIGRATIONS=1; DO_FRONTEND=0; DO_FUNCTIONS=0 ;;
    --list-migrations)     LIST_ONLY=1;     DO_FRONTEND=0; DO_FUNCTIONS=0; SKIP_PULL=1 ;;
    --baseline-migrations) BASELINE=1;      DO_FRONTEND=0; DO_FUNCTIONS=0; SKIP_PULL=1 ;;
    --mark-applied=*)      MARK_APPLIED=${arg#*=}; DO_FRONTEND=0; DO_FUNCTIONS=0; SKIP_PULL=1 ;;
    --skip-backup)         SKIP_BACKUP=1 ;;
    --skip-pull)           SKIP_PULL=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

say()  { printf '\n=== %s ===\n' "$1"; }
die()  { printf '\nFAILED: %s\n' "$1"; exit 1; }

# ---------------------------------------------------------------- db plumbing
# Every psql call goes through here. The subshell cd is deliberate: `docker
# compose` locates its project by working directory and this script cds around,
# so each call re-anchors itself instead of depending on where it is invoked.
dc()      { ( cd "$STACK" && docker compose "$@" ); }
db_psql() { dc exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
# </dev/null on every call that is not deliberately piping SQL: `docker compose
# exec -T` hands this shell's stdin to the container, and a db call made from
# inside a `while read` loop would otherwise swallow the rest of the loop's
# input -- the same trap as ssh in a while loop.
db_rows() { db_psql -tAq -c "$1" </dev/null 2>/dev/null | tr -d '\r'; }
db_one()  { db_rows "$1" | head -1 | tr -d '[:space:]'; }
sql_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# The Supabase CLI's own ledger table, created here when the stack has never had
# one. `version` and its primary key match what the CLI creates, so a future
# `supabase migration list` reads this correctly; the other columns are nullable
# additions the CLI ignores. Sent as one -c so the whole shape lands or none of
# it does.
LEDGER_DDL="
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS $LEDGER_TABLE (version text PRIMARY KEY);
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS statements text[];
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS name       text;
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS checksum   text;
ALTER TABLE $LEDGER_TABLE ADD COLUMN IF NOT EXISTS applied_at timestamptz NOT NULL DEFAULT now();
"

ledger_ensure() {
  local out
  if ! out=$(db_psql -q -c "$LEDGER_DDL" </dev/null 2>&1); then
    printf '%s\n' "$out" | tail -5
    die "could not create $LEDGER_TABLE"
  fi
}

# One INSERT, printed rather than executed, so the apply path can send it down
# the same pipe as the migration itself and have both commit together.
#
# ON CONFLICT keeps it safe to issue twice: re-recording a file that is already
# ledgered refreshes its checksum instead of erroring, which is what
# --mark-applied and --baseline-migrations rely on.
ledger_insert_sql() {
  local name=$1 sum=$2 ver=${1%%_*} ck=NULL
  [ -n "$sum" ] && ck="'$(sql_lit "$sum")'"
  printf "INSERT INTO %s (version, name, checksum) VALUES ('%s', '%s', %s) ON CONFLICT (version) DO UPDATE SET name = EXCLUDED.name, checksum = EXCLUDED.checksum, applied_at = now();\n" \
    "$LEDGER_TABLE" "$(sql_lit "$ver")" "$(sql_lit "$name")" "$ck"
}

# Append-only text mirror. Never read for a decision -- see the header.
ledger_mirror() {
  touch "$LEDGER_MIRROR" 2>/dev/null || return 0
  grep -qxF "$1" "$LEDGER_MIRROR" 2>/dev/null || echo "$1" >> "$LEDGER_MIRROR"
}

ledger_record() {
  db_psql -q -c "$(ledger_insert_sql "$1" "$2")" </dev/null >/dev/null 2>&1 || return 1
  ledger_mirror "$1"
}

# Statements Postgres refuses to run inside a transaction block, or that only
# behave correctly outside one. A file containing any of them is applied the old
# way -- statement by statement, no rollback -- and says so on its output line.
#
# ALTER TYPE ... ADD VALUE is the one that actually occurs in this repo
# (20260704091240, 20260704092015). Postgres 12+ permits it inside a transaction
# but forbids USING the new value in that same transaction, so a future file
# that adds an enum value and then writes it would fail only because we wrapped
# it. Both current files only add values, so either path works for them; the
# test exists for the file that eventually does both.
tx_hostile() {
  grep -Eiq "(CREATE|DROP|REINDEX)[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+CONCURRENTLY|ALTER[[:space:]]+TYPE[[:space:]]+[^;]*ADD[[:space:]]+VALUE|^[[:space:]]*(VACUUM|BEGIN[[:space:]]*;|COMMIT[[:space:]]*;|ALTER[[:space:]]+SYSTEM|CREATE[[:space:]]+DATABASE)" "$1"
}

# Compares the files on disk with the ledger and fills:
#   APPLIED_N  how many rows the ledger holds
#   PENDING[]  full paths, in the order they would run
#   DRIFT[]    applied files whose contents no longer match what was applied
#   EARLIER[]  pending files older than something already applied
#
# Returns 1 when the ledger table does not exist yet or the database cannot be
# reached, so callers can tell "nothing has been applied" apart from "cannot
# tell" -- two states that must never print the same thing.
scan_migrations() {
  APPLIED_N=0; PENDING=(); DRIFT=(); EARLIER=(); LEDGER_SOURCE=db
  local have rows newest f name ver sum recorded

  have=$(db_one "SELECT count(*) FROM information_schema.tables WHERE table_schema='supabase_migrations' AND table_name='schema_migrations'")
  if [ "${have:-0}" = "1" ]; then
    rows=$(db_rows "SELECT version||'|'||coalesce(checksum,'') FROM $LEDGER_TABLE")
  else
    # No table. That is either a stack that has never had one or a database we
    # cannot reach, and those must not print the same thing.
    [ "$(db_one 'SELECT 1')" = "1" ] || return 1
    rows=
  fi

  # Nothing in the database, but the pre-database ledger is sitting right there.
  # Read from it rather than reporting every migration as pending on a server
  # that simply has not been through adoption yet. Checksums are unknown this
  # way, so drift stays unreported until the real import happens.
  if [ -z "$rows" ] && [ -s "$LEDGER_MIRROR" ]; then
    rows=$(sed 's/[[:space:]].*$//' "$LEDGER_MIRROR" | grep . | cut -d_ -f1 | sed 's/$/|/')
    LEDGER_SOURCE=mirror
  fi

  APPLIED_N=$(printf '%s\n' "$rows" | grep -c .)
  newest=$(printf '%s\n' "$rows" | cut -d'|' -f1 | sort | tail -1)

  for f in "$MIGRATIONS"/*.sql; do
    [ -e "$f" ] || continue
    name=${f##*/}
    ver=${name%%_*}
    recorded=$(printf '%s\n' "$rows" | grep -m1 "^$ver|") || recorded=
    if [ -n "$recorded" ]; then
      sum=${recorded#*|}
      # A blank checksum means the row was adopted rather than applied by this
      # script: there is no recorded content to compare against, so drift is
      # unknowable rather than absent, and saying otherwise would be a lie.
      if [ -n "$sum" ] && [ "$sum" != "$(sha256sum "$f" | cut -d' ' -f1)" ]; then
        DRIFT+=("$name")
      fi
    else
      PENDING+=("$f")
      # Version prefixes are fixed-width timestamps, so string order is time
      # order. A pending file older than the newest applied one arrived out of
      # sequence -- a rebase, or a branch merged late.
      [ -n "$newest" ] && [[ "$ver" < "$newest" ]] && EARLIER+=("$name")
    fi
  done
  return 0
}

# A restore point, taken immediately before the first migration of a run and at
# no other time. Nothing else in this script can lose data.
#
# pg_dump runs INSIDE the db container so its version always matches the server.
# A host-side pg_dump one major version behind refuses to dump at all, and that
# is not a thing to find out while holding a broken schema.
#
# -Fc (custom format) rather than plain SQL: compressed, and pg_restore can pull
# a single table out of it, which is what you actually want at 2am.
take_backup() {
  local stamp size
  mkdir -p "$BACKUP_DIR" 2>/dev/null || die "cannot create $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  stamp=$(date +%Y%m%d-%H%M%S)
  BACKUP_FILE="$BACKUP_DIR/enroll-$stamp.dump"

  printf '  %-70s ' "pg_dump -> ${BACKUP_FILE##*/}"
  if ! dc exec -T db pg_dump -U postgres -Fc postgres > "$BACKUP_FILE" 2>/dev/null; then
    echo "FAILED"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE=
    die "backup failed, so nothing was applied. Fix it, or accept the risk with --skip-backup"
  fi

  # An empty or tiny file means pg_dump wrote its complaint to stderr and exited
  # 0, or the disk filled mid-write. Either way it is not a restore point, and a
  # backup you cannot restore is worse than none, because you will act as though
  # you have one.
  size=$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')
  if [ "${size:-0}" -lt 1024 ]; then
    echo "FAILED"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE=
    die "backup came out at ${size:-0} bytes - not a usable restore point. Nothing was applied."
  fi
  chmod 600 "$BACKUP_FILE" 2>/dev/null || true
  echo "ok ($((size / 1024)) KB)"

  # Keep the last $BACKUP_KEEP. Unbounded dumps fill the disk, and a full disk
  # takes the database down harder than any migration would have.
  ls -1t "$BACKUP_DIR"/enroll-*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
    rm -f "$old" && echo "  pruned old backup: ${old##*/}"
  done
}

# PostgREST caches the schema at boot. Add a table without telling it and every
# request for that table returns PGRST205 "Could not find the table" while psql
# shows it sitting right there -- the most confusing state this stack produces.
#
# The NOTIFY is unconditional: instant, free, and the documented way to do this.
#
# The restart is NOT. Supabase ships two event triggers that already NOTIFY on
# every DDL command, from inside the migration transaction itself -- so on a
# stack that has them the cache was current before this function was called, and
# restarting the container would be downtime bought for nothing. Both were
# confirmed present here on 25 Aug 2026.
#
# Both triggers are required, not either: pgrst_ddl_watch covers
# ddl_command_end, pgrst_drop_watch covers sql_drop. A migration that only drops
# something would slip past the first one on its own.
#
# The restart still happens when they are missing, or when the NOTIFY did not go
# through -- at that point we cannot show the cache is current, and a few
# seconds of API downtime is the cheaper mistake. A restart that fails to come
# back is caught by the unhealthy-container check at the end of the deploy.
reload_postgrest() {
  local notified=0 watchers

  if db_psql -q -c "NOTIFY pgrst, 'reload schema';" </dev/null >/dev/null 2>&1; then
    notified=1
    echo "  NOTIFY pgrst, 'reload schema'  sent"
  else
    echo "  !! NOTIFY pgrst failed"
  fi

  watchers=$(db_one "SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('pgrst_ddl_watch','pgrst_drop_watch')")

  if [ "${watchers:-0}" = "2" ]; then
    if [ "$notified" -eq 1 ]; then
      echo "  pgrst_ddl_watch + pgrst_drop_watch present - the cache followed the DDL itself, no restart needed"
      return 0
    fi
    echo "  !! event triggers are present but the NOTIFY did not go through - restarting rest to be sure"
  else
    echo "  !! pgrst event triggers missing (found ${watchers:-0} of 2) - restarting rest"
  fi

  if dc config --services 2>/dev/null | grep -qx rest; then
    if dc restart rest >/dev/null 2>&1; then
      echo "  rest container restarted"
    else
      echo "  !! could not restart rest. If the API 404s on a new table, run:"
      echo "     cd $STACK && docker compose restart rest"
    fi
  else
    echo "  !! no 'rest' service in this stack - schema cache reload NOT confirmed"
  fi
}

# Every array below is guarded by its own ${#...} first. With `set -u`, bash 4.2
# -- which is what a CentOS 7 era box still ships -- treats "${EMPTY[@]}" as an
# unbound variable and aborts, and this script is the last place that should be
# discovering that.
migration_warnings() {
  if [ ${#DRIFT[@]} -gt 0 ]; then
    echo
    echo "  !! ${#DRIFT[@]} already-applied file(s) have changed since they ran:"
    printf '     %s\n' "${DRIFT[@]}"
    echo "     Nothing here will re-run them. If the change matters it needs a"
    echo "     NEW migration file -- editing history does not reach a database."
  fi
  if [ ${#EARLIER[@]} -gt 0 ]; then
    echo
    echo "  !! ${#EARLIER[@]} pending file(s) are older than migrations already applied:"
    printf '     %s\n' "${EARLIER[@]}"
    echo "     They will still run, i.e. after newer ones. Read them first if"
    echo "     they touch anything a later migration also touched."
  fi
}

[ -d "$REPO/.git" ] || die "$REPO is not a git clone. See SETUP below."

# ---------------------------------------------------------------- generated
# Tracked files that the build rewrites. The sitemap step regenerates
# public/sitemap.xml every time, so without this the clean-tree guard below
# trips on the PREVIOUS deploy's own output and every run after the first fails.
#
# Restoring rather than ignoring keeps the tree honest: what we build from is
# exactly what origin has.
#
# Once these are gitignored and untracked upstream, ls-files stops matching and
# this loop quietly becomes a no-op. Nothing to remove later.
GENERATED="public/sitemap.xml"
for g in $GENERATED; do
  if git -C "$REPO" ls-files --error-unmatch "$g" >/dev/null 2>&1; then
    git -C "$REPO" checkout -- "$g" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------- clean tree
# $REPO is a deployment checkout, not a place to edit. GitHub is upstream.
#
# This matters because `git pull --ff-only` does NOT fail on a locally modified
# tracked file when the incoming commits don't touch it — the edit survives the
# pull and gets deployed, silently, forever. Catching it here is the difference
# between a confusing week and a one-line fix.
dirty=$(git -C "$REPO" status --porcelain --untracked-files=no)
if [ -n "$dirty" ]; then
  echo "FAILED: $REPO has uncommitted changes to tracked files:"
  echo
  printf '%s\n' "$dirty" | sed 's/^/    /'
  echo
  echo "  This is a deployment checkout — edits belong in Lovable, not here."
  echo "  To discard them and deploy what GitHub has:"
  echo "      git -C $REPO checkout -- ."
  echo "  To keep them, commit and push from a real working copy first."
  exit 1
fi

# ---------------------------------------------------------------- pull
if [ -z "${SKIP_PULL:-}" ]; then
  say "Pulling latest"
  before=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" pull --ff-only || die "git pull failed (local changes? deploy key expired?)"
  after=$(git -C "$REPO" rev-parse HEAD)

  if [ "$before" = "$after" ]; then
    echo "Already up to date at ${after:0:9}"
  else
    echo "${before:0:9} -> ${after:0:9}"
    echo
    git -C "$REPO" log --oneline "$before..$after" | head -20
  fi
fi

# ------------------------------------------------------------- pending check
# Surface migrations that will not be applied unless asked.
#
# The question is what this DATABASE is still missing, not what this pull
# brought, so this sits outside the pull: --skip-pull deploys the checkout as it
# stands, and the checkout can just as easily be ahead of the schema.
#
# The git-diff version of this check asked the wrong question. It compared the
# two commits either side of one pull, so a migration you consciously skipped
# was announced exactly once and then never mentioned again, however many
# deploys later it was still missing.
if [ "$DO_MIGRATIONS" -eq 0 ] && [ "$LIST_ONLY" -eq 0 ] && [ "$BASELINE" -eq 0 ] && [ -z "$MARK_APPLIED" ]; then
  if scan_migrations; then
    if [ ${#PENDING[@]} -gt 0 ]; then
      say "Pending migrations"
      echo "  !! ${#PENDING[@]} migration file(s) are not applied to this database, and --with-migrations was NOT given."
      printf '     %s\n' "${PENDING[@]##*/}" | head -10
      [ ${#PENDING[@]} -gt 10 ] && echo "     ...and $(( ${#PENDING[@]} - 10 )) more"
      echo "     The schema will NOT be updated. Re-run with --with-migrations when ready."
    fi
  else
    say "Pending migrations"
    echo "  !! could not read the migration ledger (db container down, or this"
    echo "     stack has never had one) - pending migrations unknown."
  fi
fi

# ---------------------------------------------------------------- migrations
#
# Entered by --with-migrations, --migrations-only, --list-migrations,
# --baseline-migrations and --mark-applied. Everything before the mode switch is
# shared, because each of those needs the same picture of what has run.
if [ "$DO_MIGRATIONS" -eq 1 ] || [ "$LIST_ONLY" -eq 1 ] || [ "$BASELINE" -eq 1 ] || [ -n "$MARK_APPLIED" ]; then
  say "Migrations"

  [ -d "$MIGRATIONS" ] || die "no $MIGRATIONS - is $REPO a full clone?"
  [ -d "$STACK" ]      || die "no $STACK"

  # One deploy at a time. Two overlapping runs would each read the ledger, each
  # see the same file pending, and both apply it -- a ledger cannot protect you
  # from what it has not been told yet. Failing fast beats queueing: whoever
  # started second wants to know a deploy is already running, not to wait
  # quietly and then land on top of it.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$MIGRATION_LOCK" || die "cannot open $MIGRATION_LOCK"
    flock -n 9 || die "another deploy is applying migrations right now ($MIGRATION_LOCK)"
  fi

  [ "$(db_one 'SELECT 1')" = "1" ] \
    || die "cannot reach Postgres in $STACK - try: cd $STACK && docker compose up -d db"

  # Creating the ledger table is itself a write, so --list-migrations does not
  # do it. It reads whatever exists and says where the answer came from.
  [ "$LIST_ONLY" -eq 1 ] || ledger_ensure

  # ---- one-time adoption of the file ledger --------------------------------
  # Servers built before the ledger moved into the database hold their history
  # in $LEDGER_MIRROR. Import it on the one occasion it can be trusted: when the
  # database has no ledger of its own, so there is nothing for it to contradict.
  # After this the file is written but never consulted, and a migration run by
  # hand is recorded with --mark-applied rather than by editing it.
  if [ "$LIST_ONLY" -eq 0 ] && [ "$(db_one "SELECT count(*) FROM $LEDGER_TABLE")" = "0" ]; then
    if [ -s "$LEDGER_MIRROR" ]; then
      echo "  adopting $LEDGER_MIRROR into $LEDGER_TABLE (recorded as applied, NOT re-run)"
      imported=0
      while read -r line; do
        line=${line%%[[:space:]]*}
        [ -n "$line" ] || continue
        sum=
        [ -f "$MIGRATIONS/$line" ] && sum=$(sha256sum "$MIGRATIONS/$line" | cut -d' ' -f1)
        ledger_record "$line" "$sum" || die "could not import $line into $LEDGER_TABLE"
        imported=$((imported+1))
      done < "$LEDGER_MIRROR"
      echo "  imported $imported filename(s)"
      echo "     Checksums were taken from the files as they are on disk now, so"
      echo "     drift is detected from here forward, not retroactively."
    else
      tables=$(db_one "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'")
      if [ "${tables:-0}" != "0" ] && [ "$BASELINE" -eq 0 ]; then
        echo "  This database already has $tables table(s) in public, and nothing"
        echo "  records which migrations built them. Replaying the files over an"
        echo "  existing schema is not safe -- they are not idempotent as a set,"
        echo "  which is the same reason apply-migrations.sh refuses to do it."
        echo
        echo "  If the schema is already current, adopt it without running anything:"
        echo "      deploy-enroll --baseline-migrations"
        echo "  If it is not, restore from backup, or rebuild from an empty schema"
        echo "  with apply-migrations.sh."
        die "refusing to guess what has already been applied"
      fi
    fi
  fi

  # ---- what is on disk, against what the ledger has ------------------------
  # The ledger keys on the timestamp prefix, the way the Supabase CLI does, so
  # two files sharing one would collapse into a single row and the second would
  # never run -- silently, which is the worst way for a schema change to fail.
  dupes=$(for f in "$MIGRATIONS"/*.sql; do [ -e "$f" ] || continue; b=${f##*/}; echo "${b%%_*}"; done | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "  two or more migration files share a version prefix:"
    printf '%s\n' "$dupes" | sed 's/^/      /'
    die "one of them would be skipped without ever saying so"
  fi

  scan_migrations || die "cannot read $LEDGER_TABLE"
  APPLIED_NOW=0

  # ---- mode: record a migration that was run by hand -----------------------
  if [ -n "$MARK_APPLIED" ]; then
    name=${MARK_APPLIED##*/}
    [ -f "$MIGRATIONS/$name" ] || die "no such migration file: $MIGRATIONS/$name"
    is_pending=0
    if [ ${#PENDING[@]} -gt 0 ]; then
      for f in "${PENDING[@]}"; do [ "${f##*/}" = "$name" ] && is_pending=1; done
    fi
    if [ "$is_pending" -eq 1 ]; then
      ledger_record "$name" "$(sha256sum "$MIGRATIONS/$name" | cut -d' ' -f1)" \
        || die "could not record $name"
      echo "  recorded as applied WITHOUT running it:"
      echo "      $name"
      echo "  Only ever do this for a migration you have already run yourself."
    else
      echo "  already recorded as applied: $name"
    fi
    exit 0
  fi

  # ---- mode: report, change nothing ----------------------------------------
  if [ "$LIST_ONLY" -eq 1 ]; then
    ondisk=$(ls -1 "$MIGRATIONS"/*.sql 2>/dev/null | wc -l)
    if [ "$LEDGER_SOURCE" = "mirror" ]; then
      echo "  $ondisk file(s) on disk, $APPLIED_N listed in $LEDGER_MIRROR"
      echo "  ($LEDGER_TABLE is empty or absent - this stack has not been through"
      echo "   adoption yet. The next --with-migrations imports that file, once.)"
    else
      echo "  $ondisk file(s) on disk, $APPLIED_N recorded in $LEDGER_TABLE"
    fi
    echo
    if [ ${#PENDING[@]} -eq 0 ]; then
      echo "  nothing pending"
    else
      echo "  pending (${#PENDING[@]}), in the order --with-migrations would run them:"
      printf '      %s\n' "${PENDING[@]##*/}"
    fi
    migration_warnings
    echo
    echo "  Nothing was changed - this mode only reads."
    exit 0
  fi

  # ---- mode: adopt a schema that was built some other way ------------------
  if [ "$BASELINE" -eq 1 ]; then
    [ "$APPLIED_N" -eq 0 ] \
      || die "$LEDGER_TABLE already has $APPLIED_N row(s) - baseline is only for a schema with no record at all"
    n=0
    for f in "$MIGRATIONS"/*.sql; do
      [ -e "$f" ] || continue
      ledger_record "${f##*/}" "$(sha256sum "$f" | cut -d' ' -f1)" || die "could not record ${f##*/}"
      n=$((n+1))
    done
    echo "  recorded $n migration(s) as applied. NONE of them were executed."
    echo "  That asserts the schema was already current. If it was not, it still"
    echo "  is not, and none of those files will ever run. Check with"
    echo "  schema-fingerprint.sh before trusting it."

  # ---- mode: apply ---------------------------------------------------------
  elif [ ${#PENDING[@]} -eq 0 ]; then
    echo "  nothing pending - the $APPLIED_N recorded migration(s) are all applied"
    migration_warnings
  else
    echo "  $APPLIED_N applied, ${#PENDING[@]} pending"
    migration_warnings
    echo

    # Before the first statement of the first file, and only when something is
    # genuinely about to change. A migration that FAILS now rolls back on its
    # own; this is for the one that succeeds and drops the wrong column, which
    # no amount of transaction discipline can undo.
    if [ "$SKIP_BACKUP" -eq 1 ]; then
      echo "  !! --skip-backup given: no restore point for what follows."
      echo
    else
      take_backup
      echo
    fi

    for f in "${PENDING[@]}"; do
      name=${f##*/}
      sum=$(sha256sum "$f" | cut -d' ' -f1)
      printf '  %-70s ' "$name"

      if tx_hostile "$f"; then
        # No wrapper: this file holds something Postgres will not run inside a
        # transaction. It gets the old behaviour and the old risk -- but only
        # this file, and only because it genuinely needs it.
        if out=$(db_psql -q < "$f" 2>&1); then
          if ledger_record "$name" "$sum"; then
            echo "ok (not atomic)"
            APPLIED_NOW=$((APPLIED_NOW + 1))
          else
            echo "APPLIED, NOT RECORDED"
            die "$name ran but its ledger row did not. Record it before the next deploy or it runs a second time:  deploy-enroll --mark-applied=$name"
          fi
        else
          echo "FAILED"
          printf '%s\n' "$out" | tail -20
          [ -n "$BACKUP_FILE" ] && echo "  restore point: $BACKUP_FILE"
          die "$name failed and could not be rolled back - it cannot run inside a transaction, so the schema may be half updated. Look at it before retrying."
        fi
      else
        # The file and its ledger row, in one transaction. psql opens it before
        # the first statement and commits after the last; ON_ERROR_STOP turns
        # any error into a rollback of all of it, ledger row included. So a
        # failed migration leaves the database exactly as it was and the file
        # simply stays pending -- which is what makes re-running this safe.
        #
        # The lone ';' finishes a final statement the file left unterminated,
        # which psql would otherwise discard in silence at EOF. When the file is
        # well formed it is an empty statement and does nothing.
        #
        # lock_timeout converts "deploy hangs forever behind someone's open
        # transaction" into a plain error. That is only a good trade because the
        # rollback above makes a retry free.
        if out=$( { printf "SET lock_timeout = '60s';\n"
                    cat "$f"
                    printf '\n;\n'
                    ledger_insert_sql "$name" "$sum"
                  } | db_psql -q --single-transaction 2>&1 ); then
          echo "ok"
          APPLIED_NOW=$((APPLIED_NOW + 1))
          ledger_mirror "$name"
        else
          echo "FAILED"
          printf '%s\n' "$out" | tail -20
          die "$name failed and was rolled back - the schema is unchanged and the file is still pending. Fix it upstream and re-run."
        fi
      fi
    done
  fi

  # ---- PostgREST schema cache ----------------------------------------------
  if [ "${APPLIED_NOW:-0}" -gt 0 ]; then
    say "PostgREST schema cache"
    reload_postgrest
  fi

  # ---- RLS audit -----------------------------------------------------------
  # The pass condition is THREE known rows, not zero. otp_challenges, slot_holds
  # and slot_cache have RLS on with no policies by design: each is reached only
  # through the service role or a SECURITY DEFINER RPC, so deny-all for anon is
  # correct and is the safe direction to fail in.
  #
  # Judge the rls_on column, not the row count. A row with rls_on = f is the
  # finding: a table in public is readable by anon until a policy says
  # otherwise, and the publishable key ships in the JavaScript bundle. A fourth
  # row with rls_on = t is a new deny-all table -- check it was meant to be one,
  # then add it here. OPERATIONS.md section 3.
  say "RLS audit (expect 3 rows: otp_challenges, slot_cache, slot_holds -- all rls_on = t)"
  dc exec -T db psql -U postgres -c "SELECT c.relname, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced, count(p.polname) AS policies FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_policy p ON p.polrelid=c.oid WHERE n.nspname='public' AND c.relkind='r' GROUP BY 1,2,3 HAVING NOT c.relrowsecurity OR count(p.polname)=0 ORDER BY 1;" </dev/null

  # ---- GRANT audit ---------------------------------------------------------
  # RLS decides which ROWS a role may see. GRANTs decide whether it may touch
  # the table at all, and they are a separate failure: the table is there, RLS
  # is right, and every request still comes back "permission denied for table
  # x" or PGRST205. A new table gets its privileges from ALTER DEFAULT
  # PRIVILEGES, so one created by a migration that ran as the wrong owner
  # arrives with none at all and nothing else in this deploy would notice.
  #
  # service_role is the one to test: every edge function authenticates as it,
  # and it is the role a table must reach even when anon and authenticated are
  # deliberately shut out (slot_cache is exactly that -- granted to
  # service_role and nobody else, on purpose).
  #
  # has_table_privilege rather than information_schema.role_table_grants: the
  # latter only reports grants involving currently enabled roles, so its answer
  # depends on who is asking.
  if [ "$(db_one "SELECT count(*) FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role')")" = "3" ]; then
    say "GRANT audit (expect: 0 rows)"
    echo "  A row here means that table is unreachable through the API, whatever"
    echo "  its RLS says. Fix with: GRANT SELECT ON public.<table> TO service_role;"
    dc exec -T db psql -U postgres -c "SELECT c.relname AS tbl, has_table_privilege('anon', c.oid, 'SELECT') AS anon, has_table_privilege('authenticated', c.oid, 'SELECT') AS auth, has_table_privilege('service_role', c.oid, 'SELECT') AS service_role FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND NOT has_table_privilege('service_role', c.oid, 'SELECT') ORDER BY 1;" </dev/null
  else
    say "GRANT audit"
    echo "  !! anon / authenticated / service_role not all present - skipped."
    echo "     On a Supabase stack all three exist; check the stock roles.sql ran."
  fi

  if [ "$BASELINE" -eq 1 ]; then
    say "Baseline recorded - nothing was deployed"
    exit 0
  fi
fi

# ---------------------------------------------------------------- functions
if [ "$DO_FUNCTIONS" -eq 1 ]; then
  say "Edge functions"

  # --exclude 'main/' is essential: the stack ships its own dispatch router at
  # volumes/functions/main/index.ts. Overwriting it breaks all 21 functions.
  #
  # -i (--itemize-changes) so we learn whether anything actually moved. rsync
  # already knows; it just was not being asked, and the answer decides whether
  # the runtime needs bouncing below.
  fn_changes=$(rsync -ai --delete --exclude 'main/' \
    "$REPO/supabase/functions/" "$STACK/volumes/functions/") || die "function rsync failed"

  # First itemize column: < > c h mean content moved, * is a message (deleting),
  # and a leading . means nothing changed but an attribute. Only the first kind
  # is a code change; without this filter a directory mtime would look like a
  # deploy and bounce the runtime on every single run.
  fn_changed=$(printf '%s\n' "$fn_changes" | grep -E '^[^.[:space:]]' | wc -l)

  # Derived from the repo, never hardcoded. The old fixed "expect 19" was
  # written when there were 17 functions; there are 21 now, and a number that
  # drifts out of date is worse than no number at all -- it trains you to skim
  # past the one line that would have told you the sync went wrong.
  #
  # dest must be exactly source + main/, because the rsync above mirrors with
  # --delete and excludes only main/. Anything else means it did not land.
  src=$(ls -d "$REPO"/supabase/functions/*/ 2>/dev/null | wc -l)
  [ -d "$REPO/supabase/functions/_shared" ] \
    || die "_shared/ is missing from the repo - the sync would break every function that imports it"
  want=$((src + 1))
  n=$(ls -d "$STACK"/volumes/functions/*/ 2>/dev/null | wc -l)
  echo "  $n directories in volumes/functions (expect $want: $((src - 1)) functions + _shared + main)"

  [ -d "$STACK/volumes/functions/main" ] || die "main/ router is missing — restore it before starting"
  [ "$n" -eq "$want" ] \
    || die "expected $want directories, found $n — the function sync did not land cleanly"

  cd "$STACK" || die "no $STACK"

  # Port gate. Mandatory before any compose up, per adding-instance step 32.
  pub=$(docker compose config | grep -c 'published:')
  loop=$(docker compose config | grep -c 'host_ip: 127.0.0.1')
  if [ "$pub" -ne "$loop" ]; then
    die "PORT GATE: $pub published vs $loop loopback — something would be exposed. Not starting."
  fi
  echo "  port gate: ALL PORTS LOOPBACK"

  dc up -d functions || die "functions failed to start"

  # `up -d` does NOT restart a container that is already running with unchanged
  # config -- it reports "Running" and leaves it alone. The function directory
  # is a bind mount, so new code lands on disk either way, but whether the
  # running edge runtime picks it up depends on its module caching, and env
  # changes are definitely not re-read. We cannot prove it reloads, so when the
  # sync moved something we bounce it: two seconds against shipping code that
  # silently is not live.
  #
  # Unchanged deploys skip this entirely, which is the common case.
  if [ "$fn_changed" -gt 0 ]; then
    echo "  $fn_changed function file(s) changed:"
    printf '%s\n' "$fn_changes" | grep -E '^[^.[:space:]]' | head -10 | sed 's/^/      /'
    [ "$fn_changed" -gt 10 ] && echo "      ...and $((fn_changed - 10)) more"
    dc restart functions || die "functions failed to restart after a code change"
    echo "  functions restarted"
  else
    echo "  no function changes - runtime left running"
  fi

  sleep 5
  dc ps --format '{{.Service}} {{.Status}}' | grep -E '^functions' || true
fi

# ---------------------------------------------------------------- frontend
if [ "$DO_FRONTEND" -eq 1 ]; then
  say "Frontend build"

  [ -f "$REPO/.env.production.local" ] || die "$REPO/.env.production.local missing — the build would point at Lovable Cloud"

  # node:22-alpine was verified absent on this server 2026-08-21 despite the
  # addendum implying the key-generation scripts leave a Node image behind --
  # don't assume either image is present, pull on demand.
  if ! docker image inspect "$BUN_IMAGE" >/dev/null 2>&1; then
    echo "  $BUN_IMAGE not present — pulling (one time, ~80 MB compressed)"
    docker pull "$BUN_IMAGE" || die "could not pull $BUN_IMAGE"
  fi

  # --frozen-lockfile is bun's equivalent of `npm ci`: fails loudly on drift
  # instead of silently rewriting the lockfile.
  #
  # The sitemap step runs as `bun run scripts/generate-sitemap.ts`, NOT
  # `bunx tsx scripts/generate-sitemap.ts` -- confirmed 2026-08-24: tsx's `./cjs`
  # export (dist/cjs/index.cjs) only works through NODE's loader-hook API, which
  # Bun does not implement, and crashes with "Cannot find module './cjs/index.cjs'
  # from ''". Bun transpiles TypeScript natively -- no tsx, no Node hooks, no
  # compat layer needed. The script only touches fs/path/vite's loadEnv, none of
  # which need tsx's machinery.
  #
  # The build step is `bun run vite build`, NOT `bun run build`. package.json
  # has "prebuild": "tsx scripts/generate-sitemap.ts" -- Bun supports npm-style
  # pre/post script hooks, so running the "build" SCRIPT NAME risks silently
  # re-triggering that same broken tsx call from inside this step. Invoking the
  # vite BINARY directly skips script-name resolution entirely, so no hook can
  # fire. `bun run <binary>` resolves from node_modules/.bin the same way
  # `bunx <binary>` does -- only the failing tsx call above used that path
  # before; the binary-lookup mechanism itself was never the problem.
  docker run --rm \
    -v "$REPO":/app -w /app \
    -v enroll_bun_cache:/root/.bun/install/cache \
    "$BUN_IMAGE" sh -c "bun install --frozen-lockfile && bun run scripts/generate-sitemap.ts && bun run vite build" \
    || die "build failed"

  [ -f "$REPO/dist/index.html" ] || die "no dist/index.html after build"

  # Prove the output points at the VPS, not at Lovable Cloud. Cheap, and it
  # catches a wrong or half-populated .env.production.local before users see it.
  #
  # index.html is checked as well as assets/: since the %VITE_*% placeholders
  # landed, the Supabase URL and the canonical/og tags are substituted into the
  # HTML too, and a bad env would show up there first.
  #
  # Paths are named explicitly rather than scanning dist/ — public/videos holds
  # ~230 MB of MP4 that grep has no reason to read.
  SCAN="$REPO/dist/index.html $REPO/dist/assets/"
  if grep -rql "pcuzksquykmyboxxrawb" $SCAN 2>/dev/null; then
    die "build still references the Lovable Cloud project — check .env.production.local"
  fi
  grep -rql "api.enroll.lilbrahmas.org" $SCAN 2>/dev/null \
    || echo "  !! warning: VPS API URL not found in build — verify .env.production.local"

  # A placeholder that survives means its variable was undefined at build time.
  # Vite only warns about this, so without a check it ships silently — a
  # canonical tag reading "%VITE_SITE_URL%/" is worse than a hardcoded one.
  if grep -q '%VITE_' "$REPO/dist/index.html" 2>/dev/null; then
    grep -o '%VITE_[A-Z_]*%' "$REPO/dist/index.html" | sort -u | sed 's/^/    /'
    die "unsubstituted placeholders above — those variables are missing from .env"
  fi

  say "Publishing to $DOCROOT"

  # The --exclude entries are NOT optional. api.enroll.lilbrahmas.org's docroot
  # lives INSIDE public_html; a --delete without them destroys it, taking the
  # API vhost's ACME challenge path with it.
  rsync -a --delete \
    --exclude 'api.enroll.lilbrahmas.org/' \
    --exclude '.well-known/' \
    --exclude '.htaccess' \
    --exclude '__l5e/' \
    "$REPO/dist/" "$DOCROOT/" || die "publish rsync failed"

  chown -R "$CPUSER:$CPUSER" "$DOCROOT"
  find "$DOCROOT" -type f -exec chmod 644 {} +
  find "$DOCROOT" -type d -exec chmod 755 {} +

  [ -f "$DOCROOT/.htaccess" ] || echo "  !! warning: $DOCROOT/.htaccess is missing — deep links will 404"

  # Video originals are NOT in the repo -- src/assets/videos/*.asset.json point
  # at root-relative Lovable paths (/__l5e/assets-v1/...). Unmirrored, those
  # requests hit the SPA rewrite and return index.html with HTTP 200, so the
  # player fails silently. This downloads whatever is missing; present files are
  # skipped on a size check, so it is nearly free after the first run.
  #
  # "__l5e/" is excluded from the rsync above for the same reason ".htaccess"
  # is: --delete would otherwise remove 349 MB of video on every deploy.
  if [ -f /opt/apps/kit/sync-videos.sh ]; then
    say "Video assets"
    REPO="$REPO" DOCROOT="$DOCROOT" CPUSER="$CPUSER" bash /opt/apps/kit/sync-videos.sh || echo "  !! warning: video sync reported a problem - see above"
  else
    echo "  !! warning: /opt/apps/kit/sync-videos.sh not found - videos may serve as HTML"
  fi
fi

# ---------------------------------------------------------------- verify
say "Verification"

code=$(curl -s -o /dev/null -w '%{http_code}' https://enroll.lilbrahmas.org/admin-login)
echo "  frontend deep link      : $code   (expect 200)"

code=$(curl -s -o /dev/null -w '%{http_code}' https://api.enroll.lilbrahmas.org/auth/v1/health)
echo "  auth health             : $code"

unhealthy=$(cd "$STACK" && docker compose ps --format '{{.Service}} {{.Status}}' | grep -vc healthy)
echo "  unhealthy containers    : $unhealthy   (expect 0)"

exposed=$(ss -tln | grep -cE '(0\.0\.0\.0|\*):(8000|5432|6543)')
echo "  exposed supabase ports  : $exposed   (expect 0)"
[ "$exposed" -ne 0 ] && die "PORTS EXPOSED — run: cd $STACK && docker compose down"

say "Done — $(git -C "$REPO" rev-parse --short HEAD)"

# ===========================================================================
# SETUP (once)
#
#  1. On the server, make a deploy key:
#       ssh-keygen -t ed25519 -C "enroll-vps-deploy" -f /root/.ssh/enroll_deploy -N ""
#
#  2. Print it and add to GitHub as a READ-ONLY deploy key
#     (repo -> Settings -> Deploy keys -> Add, leave "Allow write access" OFF):
#       cat /root/.ssh/enroll_deploy.pub
#
#     A deploy key can live on only ONE repository across the whole of GitHub.
#     If the Lovable project is ever moved to a new repo, delete the key from
#     the old repo BEFORE adding it to the new one, or the add is rejected with
#     "Key is already in use".
#
#  3. Tell ssh to use it for github.com — append to /root/.ssh/config:
#       Host github.com
#         IdentityFile /root/.ssh/enroll_deploy
#         IdentitiesOnly yes
#
#  4. Clone:
#       git clone git@github.com:librahmas-hue/lil-brahmas-pathfinder-67845d9c.git /opt/apps/enroll
#
#  5. Create /opt/apps/enroll/.env.production.local (gitignored, so pulls
#     never clobber it):
#       VITE_SUPABASE_URL=https://api.enroll.lilbrahmas.org
#       VITE_SUPABASE_PUBLISHABLE_KEY=<SUPABASE_PUBLISHABLE_KEY from the stack .env>
#
#  6. Put this script at /usr/local/sbin/deploy-enroll and chmod +x it.
#
#  Read-only key means a compromised server cannot push to your repo.
# ===========================================================================
