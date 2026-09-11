#!/usr/bin/env bash
# Phase 3 (import half) — push the exported content into the VPS Supabase.
#
# Run from the project root in Git Bash, AFTER the schema exists (Phase 1):
#     SERVICE_ROLE=<VPS secret key> bash import-content.sh [export-dir]
#
# The key is SUPABASE_SECRET_KEY (or SERVICE_ROLE_KEY on older key sets) from
# /opt/supabase/stacks/enroll/.env on the server.
#
# Idempotent: uses upsert on the primary key, so re-running is safe.

set -uo pipefail

DST="${DST:-https://api.enroll.lilbrahmas.org}"
DIR="${1:-./content-export}"

if [ -z "${SERVICE_ROLE:-}" ]; then
  echo "FAIL: set SERVICE_ROLE to the VPS secret/service_role key."
  echo "  On the server:  grep -E '^(SUPABASE_SECRET_KEY|SERVICE_ROLE_KEY)=' /opt/supabase/stacks/enroll/.env"
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "FAIL: no export directory at $DIR — run export-content.sh first."
  exit 1
fi

# The VPS issues BOTH key styles. Which one you pass changes the headers:
#
#   sb_secret_... / sb_publishable_...  new opaque keys. The gateway resolves
#                                       these from `apikey` alone and translates
#                                       them into internal ES256 JWTs. Sending
#                                       them as a Bearer token is not valid --
#                                       they are not JWTs.
#   eyJ...                              legacy service_role JWT, which PostgREST
#                                       reads from Authorization directly.
#
# This mirrors isNewSupabaseApiKey() in src/integrations/supabase/client.ts, so
# the script authenticates the same way the app does.
case "$SERVICE_ROLE" in
  sb_publishable_*)
    echo "FAIL: that is a PUBLISHABLE key — it cannot write past RLS."
    echo "  Use SUPABASE_SECRET_KEY or SERVICE_ROLE_KEY."
    exit 1
    ;;
  sb_secret_*)
    AUTH_ARGS=()
    KEY_STYLE="opaque secret (apikey only)"
    ;;
  *)
    AUTH_ARGS=(-H "Authorization: Bearer $SERVICE_ROLE")
    KEY_STYLE="legacy JWT (apikey + Authorization)"
    ;;
esac

echo "Importing $DIR -> $DST"
echo "Key style: $KEY_STYLE"
echo

fail=0
for f in "$DIR"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .json)
  table="${base#*_}"          # strip the NN_ ordering prefix

  rows=$(python -c 'import json,sys; print(len(json.load(open(sys.argv[1],encoding="utf-8"))))' "$f" 2>/dev/null || echo 0)
  if [ "$rows" = "0" ]; then
    printf '  %-28s skipped (empty)\n' "$table"
    continue
  fi

  resp=$(curl -s -m 120 -w '\n%{http_code}' -X POST \
    -H "apikey: $SERVICE_ROLE" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    --data-binary "@$f" \
    "$DST/rest/v1/$table" 2>/dev/null)

  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')

  case "$code" in
    2*) printf '  %-28s %5s rows OK\n' "$table" "$rows" ;;
    *)  printf '  %-28s HTTP %s\n' "$table" "$code"
        printf '      %s\n' "$(printf '%s' "$body" | head -c 300)"
        fail=$((fail+1))
        ;;
  esac
done

echo
if [ "$fail" -gt 0 ]; then
  echo "$fail table(s) failed."
  echo
  echo "  'column ... does not exist'  -> the VPS schema is behind the export."
  echo "                                  Close the gap found by the Phase 1.2 types diff."
  echo "  'violates foreign key'       -> a parent table failed earlier; fix that first."
  echo "  401 / 403                    -> wrong key, or RLS is blocking. The secret key"
  echo "                                  bypasses RLS; a publishable key does not."
  exit 1
fi

echo "All tables imported. Verify with:"
echo "  curl -s -H \"apikey: \$SERVICE_ROLE\" -H 'Range: 0-0' -H 'Prefer: count=exact' -D - -o /dev/null \"$DST/rest/v1/admin_faqs?select=*\" | grep -i content-range"
echo "  (expect .../103)"
