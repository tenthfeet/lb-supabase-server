#!/usr/bin/env bash
# Phase 0 — determine what access we have to the Lovable Cloud database,
# and produce the list of tables that actually carry data.
#
# Run from the project root in Git Bash:
#     bash phase0-check-db-access.sh
#
# Optional, to unlock more of the report:
#     SERVICE_ROLE=eyJ... bash phase0-check-db-access.sh
#
# Read-only throughout. Nothing here writes to any database.

set -uo pipefail

SRC="https://pcuzksquykmyboxxrawb.supabase.co"

# Publishable key comes straight from the committed .env — no need to paste it.
KEY=$(grep '^VITE_SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2- | tr -d '"')
if [ -z "${KEY:-}" ]; then
  echo "FAIL: could not read VITE_SUPABASE_PUBLISHABLE_KEY from .env — run this from the project root."
  exit 1
fi

SERVICE_ROLE="${SERVICE_ROLE:-}"

# All 47 tables, grouped by what we expect anon to be able to read.
CONTENT_TABLES="admin_contact_info admin_content_blocks admin_coupon_settings
admin_course_categories admin_course_levels admin_course_paths admin_courses
admin_custom_sections admin_diagrams admin_exit_popup_settings admin_faqs
admin_feature_flags admin_i18n_templates admin_lead_gate_settings admin_locales
admin_offers admin_payment_lock_settings admin_pricing_plans admin_reason_options
admin_reason_sets admin_reasons admin_revisions admin_rule_cards admin_settings
admin_sibling_settings admin_student_works admin_syllabus admin_videos
price_courses price_list_periods price_slabs"

PROTECTED_TABLES="admission_attempts admission_events coupon_configs coupon_reveals
coupons enrollments faq_unknown_questions leads otp_challenges payment_locks
publish_requests slot_holds user_accounts user_roles xsell_events xsell_mappings"

# PostgREST returns the exact row count in Content-Range when asked.
# Range: 0-0 keeps the body to a single row so this stays cheap.
count_rows() {
  local table="$1" auth="$2"
  local hdrs
  hdrs=$(curl -s -D - -o /dev/null -m 20 \
    -H "apikey: $auth" \
    -H "Authorization: Bearer $auth" \
    -H "Range: 0-0" \
    -H "Prefer: count=exact" \
    "$SRC/rest/v1/$table?select=*" 2>/dev/null)

  local status
  status=$(printf '%s' "$hdrs" | head -1 | awk '{print $2}')
  case "$status" in
    200|206)
      printf '%s' "$hdrs" | tr -d '\r' | grep -i '^content-range:' \
        | sed -E 's|.*/||' | tail -1
      ;;
    401|403) echo "DENIED" ;;
    404)     echo "NO-TABLE" ;;
    *)       echo "HTTP-${status:-???}" ;;
  esac
}

echo "==============================================================="
echo " Phase 0 — Lovable Cloud access probe"
echo " Source: $SRC"
echo "==============================================================="
echo

# ---------------------------------------------------------------- Route C
echo "--- ROUTE C: publishable key (always available) ---------------"
echo
probe=$(count_rows admin_courses "$KEY")
if [ "$probe" = "DENIED" ] || [ "$probe" = "HTTP-000" ]; then
  echo "  admin_courses -> $probe"
  echo "  Route C is NOT working. Check the key in .env and your network."
  echo
else
  echo "  Reachable. Row counts for content tables:"
  echo
  empty=""
  for t in $CONTENT_TABLES; do
    n=$(count_rows "$t" "$KEY")
    case "$n" in
      0)       empty="$empty $t" ;;
      DENIED)  printf '    %-28s %s  <-- expected readable, is not\n' "$t" "$n" ;;
      *)       printf '    %-28s %s\n' "$t" "$n" ;;
    esac
  done
  if [ -n "$empty" ]; then
    echo
    echo "  Empty (nothing to migrate):"
    for t in $empty; do echo "      $t"; done
  fi
  echo
fi

# ---------------------------------------------------------------- Route B
echo "--- ROUTE B: service role key ---------------------------------"
echo
if [ -z "$SERVICE_ROLE" ]; then
  echo "  Not tested — no SERVICE_ROLE in the environment."
  echo "  If Lovable's backend settings show the service_role key, re-run as:"
  echo "      SERVICE_ROLE=<key> bash phase0-check-db-access.sh"
  echo
else
  probe=$(count_rows leads "$SERVICE_ROLE")
  if [ "$probe" = "DENIED" ]; then
    echo "  leads -> DENIED. That key is not a service_role key."
  else
    echo "  Working. Row counts for protected tables:"
    echo
    for t in $PROTECTED_TABLES; do
      n=$(count_rows "$t" "$SERVICE_ROLE")
      printf '    %-28s %s\n' "$t" "$n"
    done
  fi
  echo
fi

# ---------------------------------------------------------------- Route A
echo "--- ROUTE A: direct Postgres ----------------------------------"
echo
echo "  Cannot be probed without a password. To check by hand:"
echo
echo "    1. Open the project in Lovable -> Cloud / Backend panel."
echo "    2. Look for a database connection string, or a link through to"
echo "       the Supabase dashboard (Project Settings -> Database)."
echo "    3. Test it:"
echo "         psql \"<connection string>\" -c '\\dt public.*'"
echo
echo "  Do NOT reset the database password to obtain one. Lovable Cloud holds"
echo "  that credential internally and a reset may break the client's editing"
echo "  environment."
echo

echo "==============================================================="
echo " Interpreting this"
echo "==============================================================="
echo
echo " Route C alone is enough to migrate all site CONTENT."
echo " leads / enrollments need Route A or B — check whether their row"
echo " counts above justify chasing that access."
echo
