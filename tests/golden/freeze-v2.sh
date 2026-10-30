#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# freeze-v2.sh — freeze the v2 themes into the migration-era golden capture
# (once, after the cut-over; see README.md).
#
#   tests/golden/freeze-v2.sh [--capture DIR] [--from DIR]
#
#   --capture  the v2 capture (default: what ~/.cache/pc-lights/golden/v2
#              points at, else what current points at while it has no
#              capture.conf, i.e. is still the pre-cut-over capture)
#   --from     the v2 theme dir (default ~/.config/pc-lights/themes.pre-v3-*,
#              the one migrate left; must be v2 throughout)
#
# It writes <capture>/themes-v2/ (media hard-linked, the rest copied; mode
# 0700), <capture>/themes-v2.sha256, <capture>/capture.conf (themes=themes-v2,
# profile=none, reference=pc-lights.pre-portable), and points golden/v2 at
# the capture. It only reads the source; it never touches the live state.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

cap='' from=''
while (( $# )); do
  case $1 in
    --capture) cap=$(readlink -f "$2"); shift 2 ;;
    --from) from=$(readlink -f "$2"); shift 2 ;;
    *) sed -n '2,/^set -euo/{/^# shellcheck/d;/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
if [[ -z $cap ]]; then
  if [[ -e $GOLDEN_V2 ]]; then cap=$(readlink -f "$GOLDEN_V2")
  elif [[ ! -f $GOLDEN_ROOT/current/capture.conf ]]; then cap=$(readlink -f "$GOLDEN_ROOT/current")
  else echo "freeze-v2.sh: no v2 capture found; pass --capture" >&2; exit 2; fi
fi
if [[ -z $from ]]; then
  mapfile -t c < <(ls -d "$HOME"/.config/pc-lights/themes.pre-v3-* 2>/dev/null)
  (( ${#c[@]} == 1 )) || { echo "freeze-v2.sh: ${#c[@]} themes.pre-v3-* dirs; pass --from" >&2; exit 2; }
  from=$(readlink -f "${c[0]}")
fi
[[ -f $cap/themes.txt && -d $cap/live ]] || { echo "freeze-v2.sh: no golden capture at $cap" >&2; exit 2; }
if jq -e 'select(.v == 3)' "$from"/*/theme.json >/dev/null 2>&1; then
  echo "freeze-v2.sh: $from has v3 themes" >&2; exit 2
fi
mapfile -t want <"$cap/themes.txt"
for t in "${want[@]}"; do [[ -f $from/$t/theme.json ]] || { echo "freeze-v2.sh: $from lacks $t" >&2; exit 2; }; done

echo "capture: $cap"
echo "from:    $from"
golden_snapshot_themes "$from" "$cap/themes-v2"
golden_check_themes "$cap/themes-v2"
if [[ ! -f $cap/capture.conf ]]; then
  printf '%s\n' '# the migration-era capture: v2 themes (frozen in themes-v2/), no profile' \
    themes=themes-v2 profile=none reference=pc-lights.pre-portable >"$cap/capture.conf"
fi
ln -sfn "${cap##*/}" "$GOLDEN_V2"
echo "themes-v2: $(wc -l <"$cap/themes-v2.sha256") files, manifest $(sha256sum <"$cap/themes-v2.sha256" | cut -c1-16)"
echo "v2 -> ${cap##*/}"
