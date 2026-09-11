#!/usr/bin/env bash
# Mirror Lovable-hosted video assets onto this server. RUNS ON THE SERVER AS ROOT.
#
#   bash /opt/apps/kit/sync-videos.sh
#
# WHY THIS EXISTS
#
# The video originals were removed from the repo to keep it light (see the
# comment at the top of src/lib/videoAssets.ts). What remains is a manifest per
# video at src/assets/videos/<name>.mp4.asset.json, whose "url" field is a
# ROOT-RELATIVE Lovable path:
#
#     /__l5e/assets-v1/<asset_id>/<original_filename>
#
# On lovable.app that path is served by Lovable's asset infrastructure. On this
# server nothing serves it, so the SPA rewrite in .htaccess catches it and
# returns index.html with HTTP 200. The <video> element receives HTML and fails
# silently -- no console error, no broken-image icon, just a player that never
# plays.
#
# This script downloads each asset once and stores it at the SAME path under the
# docroot, so the existing URLs resolve locally. Nothing in Lovable changes, and
# the repo stays light.
#
# After the first run the site no longer depends on Lovable for video playback.
# The only remaining dependency is fetching a NEWLY added video, which fails
# loudly here rather than silently in a browser.

set -uo pipefail

REPO=${REPO:-/opt/apps/enroll}
DOCROOT=${DOCROOT:-/home/enroll/public_html}
CPUSER=${CPUSER:-enroll}
SRC=${VIDEO_SRC_HOST:-https://lil-brahmas-pathfinder.lovable.app}

MANIFESTS="$REPO/src/assets/videos"

if [ ! -d "$MANIFESTS" ]; then
  echo "No manifest directory at $MANIFESTS — nothing to sync."
  exit 0
fi

count=$(ls -1 "$MANIFESTS"/*.asset.json 2>/dev/null | wc -l)
if [ "$count" -eq 0 ]; then
  echo "No .asset.json manifests found — nothing to sync."
  exit 0
fi

echo "Syncing $count video asset(s) from $SRC"
echo

ok=0; got=0; fail=0

for m in "$MANIFESTS"/*.asset.json; do
  # One python call, tab-separated, so a filename with spaces stays intact.
  read -r url size name < <(python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d['url'], d['size'], d['original_filename'])
" "$m" 2>/dev/null)

  if [ -z "${url:-}" ]; then
    printf '  %-40s MANIFEST UNREADABLE\n' "$(basename "$m")"
    fail=$((fail+1)); continue
  fi

  target="$DOCROOT$url"

  # Size is the integrity check. A truncated download from an earlier run would
  # otherwise look present and serve a corrupt file forever.
  if [ -f "$target" ] && [ "$(stat -c%s "$target" 2>/dev/null)" = "$size" ]; then
    printf '  %-40s ok (%s MB)\n' "$name" "$((size/1048576))"
    ok=$((ok+1)); continue
  fi

  mkdir -p "$(dirname "$target")"
  printf '  %-40s downloading %s MB ... ' "$name" "$((size/1048576))"

  # .part then mv, so an interrupted run never leaves a half file in place that
  # the size check would have to catch on the next pass.
  if curl -fsSL --retry 2 -m 900 -o "$target.part" "$SRC$url"; then
    actual=$(stat -c%s "$target.part" 2>/dev/null || echo 0)
    if [ "$actual" = "$size" ]; then
      mv -f "$target.part" "$target"
      echo "done"
      got=$((got+1))
    else
      rm -f "$target.part"
      echo "SIZE MISMATCH (got $actual, expected $size)"
      fail=$((fail+1))
    fi
  else
    rm -f "$target.part"
    echo "DOWNLOAD FAILED"
    fail=$((fail+1))
  fi
done

if [ -d "$DOCROOT/__l5e" ]; then
  chown -R "$CPUSER:$CPUSER" "$DOCROOT/__l5e"
  find "$DOCROOT/__l5e" -type f -exec chmod 644 {} +
  find "$DOCROOT/__l5e" -type d -exec chmod 755 {} +
fi

echo
echo "  present: $ok   downloaded: $got   failed: $fail"

if [ "$fail" -gt 0 ]; then
  echo
  echo "  A failure here means those videos will serve index.html instead of"
  echo "  video/mp4 -- the player will fail silently in the browser."
  echo "  Check the asset is still reachable:"
  echo "      curl -sI $SRC<url-from-manifest> | head -3"
  exit 1
fi

echo
echo "  Verify one end-to-end (expect content-type: video/mp4, NOT text/html):"
echo "      curl -sI https://enroll.lilbrahmas.org$(python3 -c "
import json,glob,sys
f=sorted(glob.glob('$MANIFESTS/*.asset.json'))[0]
print(json.load(open(f,encoding='utf-8'))['url'])
" 2>/dev/null) | head -4"
