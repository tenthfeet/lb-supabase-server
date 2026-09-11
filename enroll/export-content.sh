#!/usr/bin/env bash
# Phase 3 (export half) — pull all site content out of Lovable Cloud into JSON.
#
# Run from the project root in Git Bash:
#     bash export-content.sh [output-dir]
#
# Read-only. Uses only the publishable key already in .env (Route C).
# Tables are written in dependency order; import-content.sh replays that order.

set -uo pipefail

SRC="https://pcuzksquykmyboxxrawb.supabase.co"
OUT="${1:-./content-export}"

KEY=$(grep '^VITE_SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2- | tr -d '"')
if [ -z "${KEY:-}" ]; then
  echo "FAIL: run this from the project root (needs .env)."
  exit 1
fi

mkdir -p "$OUT"

# Dependency order: parents before children. The numeric prefix on each output
# file preserves that order for the import, so it survives shell glob sorting.
#
# Taken from the live FK graph, not from guesswork. The only three dependencies
# among these tables are:
#   admin_course_categories -> admin_courses -> admin_course_levels
#   price_courses, price_list_periods -> price_slabs
# Everything else is independent. Getting this wrong produces a 23503
# "Key (...) is not present in table" at import time.
TABLES="
admin_locales
admin_course_categories
admin_courses
admin_course_levels
admin_syllabus
admin_pricing_plans
admin_contact_info
admin_content_blocks
admin_faqs
admin_feature_flags
admin_i18n_templates
admin_offers
admin_reasons
admin_rule_cards
admin_student_works
admin_coupon_settings
admin_exit_popup_settings
admin_payment_lock_settings
admin_sibling_settings
price_list_periods
price_courses
price_slabs
"

echo "Exporting from $SRC -> $OUT"
echo

i=0
total=0
for t in $TABLES; do
  i=$((i+1))
  n=$(printf '%02d' "$i")
  f="$OUT/${n}_${t}.json"

  body=$(curl -s -m 60 \
    -H "apikey: $KEY" \
    -H "Authorization: Bearer $KEY" \
    -H "Accept: application/json" \
    "$SRC/rest/v1/$t?select=*" 2>/dev/null)

  if [ -z "$body" ]; then
    printf '  %-28s FAILED (empty response)\n' "$t"
    continue
  fi

  # A PostgREST error is a JSON object; a successful select is an array.
  case "$body" in
    \[*) ;;
    *)   printf '  %-28s ERROR: %s\n' "$t" "$(printf '%s' "$body" | head -c 120)"
         continue ;;
  esac

  printf '%s' "$body" > "$f"

  rows=$(printf '%s' "$body" | python -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?")
  total=$((total + ${rows:-0}))

  if [ "$rows" = "1000" ]; then
    printf '  %-28s %5s rows  <-- HIT PAGE LIMIT, needs paging\n' "$t" "$rows"
  else
    printf '  %-28s %5s rows\n' "$t" "$rows"
  fi
done

echo
echo "Total: $total rows across $i tables -> $OUT"
echo
echo "Next: apply the schema to the VPS (Phase 1), then run import-content.sh."
