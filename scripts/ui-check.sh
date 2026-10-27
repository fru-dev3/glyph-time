#!/bin/zsh
# Runs Glyph Time's UI check twice: a plain folder, then a stand-in Glyph Studio vault. Run it in a
# logged-in session (it opens real windows); it touches no real data. Pictures go to <out dir>.
# Usage: scripts/ui-check.sh [out dir]
set -euo pipefail
cd "${0:A:h}/.."
out=${1:-/tmp/glyph-time-ui}
./scripts/build.sh >/dev/null
app="build/Glyph Time.app/Contents/MacOS/GlyphTime"
pkill -x GlyphTime 2>/dev/null || true
rc=0
for mode in folder vault; do
  dir=$(mktemp -d)
  [[ $mode == vault ]] && mkdir -p "$dir/data/domains/time"
  echo "== $mode"
  GLYPH_TIME_HOST=uitest-local "$app" --uitest "$out/$mode" -folder "$dir" || rc=1
done
exit $rc
