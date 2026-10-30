#!/usr/bin/env bash
# The real Service.qml's screen-editor API (plan §5.4) and desktop wallpaper
# API (contract v1.4) against a canned engine.
#
#   tests/ui/service-smoke.sh
#
# The panel renders (tests/render.py) run on tests/FakeService.qml; this runs
# the Service itself, offscreen in quickshell, with LUMENAIRE_PCL_BIN pointed
# at tests/ui/fake-engine (the frozen contract views as replies). HOME and
# XDG_RUNTIME_DIR are scratch folders, so nothing reaches your config, the
# engine or the Lian Li daemon. It checks what the Service makes of each
# reply (service-smoke.qml logs a line per step) and the exact commands it
# sends, in order: one draft change at a time, --base-rev and --with-screens
# on each, edits waiting behind the change in flight; one wallpaper change at
# a time, shown at once and settled by the engine's view, a refusal in one
# line, "Use defaults" as the defaults, and a re-read when the engine's cache
# of the desktop changes.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
command -v quickshell >/dev/null || { echo "service-smoke: quickshell not found; skipped"; exit 0; }
[[ -d /usr/share/omarchy/shell/Ui ]] || { echo "service-smoke: no Omarchy shell; skipped"; exit 0; }
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
mkdir -p "$w/root/Lights" "$w/home/.cache/pc-lights/desktop" "$w/run"
chmod 700 "$w/run"
for n in Ui Commons; do ln -s "/usr/share/omarchy/shell/$n" "$w/root/$n"; done
cp "$repo"/*.qml "$repo"/*.js "$w/root/Lights/"
cp "$here/service-smoke.qml" "$w/root/shell.qml"
: >"$w/calls.log"
env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
  HOME="$w/home" XDG_RUNTIME_DIR="$w/run" XDG_CONFIG_HOME="$w/home/.config" XDG_CACHE_HOME="$w/home/.cache" \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_BACKEND=software LIBGL_ALWAYS_SOFTWARE=1 \
  LUMENAIRE_PCL_BIN="$here/fake-engine" SMOKE_LOG="$w/calls.log" \
  timeout 90 quickshell -p "$w/root" --no-color >"$w/out.log" 2>&1 || true

fails=0 checks=0
want() {   # want <file> <fixed string>
  checks=$((checks + 1))
  grep -qF -- "$2" "$1" || { fails=$((fails + 1)); echo "FAIL: no \"$2\" in $(basename "$1")"; }
}
for line in 'SMOKE ready v_minor=4' 'SMOKE view roles=7 editable=true state=idle' 'SMOKE list items=7' \
            'SMOKE frame for=/x/planet37.mp4 src=1920x1080' 'SMOKE job j-1790000400123-4821 state=encoding thumb=/t.webp' \
            "\"text\":\"Rotation turned off: pictures can't take turns.\"" 'SMOKE cancelled jobFor=null' \
            'SMOKE closed screensView=null state=closed' \
            'SMOKE desktop available=true home=sakura stub=null' \
            'SMOKE desktop view theme=hellfire has_animated=null pause=true line=Applies when Hellfire is on' \
            'SMOKE desktop optimistic pause=false' 'SMOKE desktop invalid=false,false' \
            'SMOKE desktop settled settings={"animated":true,"pause_while_active":false,"resume_after_idle":10,"while_active":"still"} custom=true' \
            "SMOKE desktop error=That theme isn't there any more. local={}" \
            'SMOKE desktop reset settings={"animated":true,"pause_while_active":true,"resume_after_idle":5,"while_active":"freeze"} custom=false error=""' \
            'SMOKE desktop watch reread=true' 'SMOKE desktop closed state=closed view=null' 'SMOKE DONE'; do
  want "$w/out.log" "$line"
done
calls=(
  'theme edit sakura-2 --json'
  'theme screens sakura-2 --json'
  'media jobs --draft sakura-2 --json'
  'media list --for screen.fan3 --source library --draft sakura-2 --limit 60 --json'
  'media frame /x/planet37.mp4 --time 12.4 --max 960 --json'
  'media prepare /x/planet37.mp4 --for screen.fan3 --draft sakura-2 --then set --crop 656,236,608,608 --time 12.4 --json'
  'theme media set sakura-2 screen.fan3 media/fan-a.mp4 --base-rev 3 --with-screens --json'
  'theme set sakura-2 --patch-json [{"op":"add","path":"/screens/@screen.fan3/brightness","value":60}] --base-rev 3 --with-screens --json'
  'theme media clips sakura-2 screen.pump move 0 1 --base-rev 3 --with-screens --json'
  'theme media rotate sakura-2 screen.pump 900 --shuffle on --base-rev 3 --with-screens --json'
  'theme media mode sakura-2 screen.main template --base-rev 3 --with-screens --json'
  'theme media clips sakura-2 screen.pump add media/x.mp4 --at 2 --base-rev 3 --with-screens --json'
  'theme media clips sakura-2 screen.pump remove 1 --base-rev 3 --with-screens --json'
  'media cancel j-1790000400123-4821 --json'
  'theme set sakura-2 --patch-json [{"op":"remove","path":"/screens/@screen.fan3/brightness"}] --base-rev 3 --with-screens --json'
  'desktop --theme hellfire --json'
  'desktop set --theme hellfire pause false'
  'desktop set --theme hellfire resume 10'
  'desktop set --theme hellfire while still'
  'desktop set --theme nope animated false'
  'desktop --theme nope --json'
  'desktop reset --theme hellfire'
  'desktop --theme hellfire --json'
)
for c in "${calls[@]}"; do want "$w/calls.log" "$c"; done
# In order: the lines above appear in the log in this sequence.
checks=$((checks + 1))
if ! python3 - "$w/calls.log" "${calls[@]}" <<'EOF'
import sys
log = open(sys.argv[1]).read().splitlines()
at = -1
for c in sys.argv[2:]:
    try:
        i = next(k for k in range(at + 1, len(log)) if log[k] == c)
    except StopIteration:
        sys.exit(f'out of order: {c}')
    at = i
EOF
then fails=$((fails + 1)); echo "FAIL: the engine calls are out of order"; fi
checks=$((checks + 1))
if grep -E 'TypeError|ReferenceError|is not a function|Cannot read property' "$w/out.log"; then fails=$((fails + 1)); echo "FAIL: script errors"; fi
if (( fails )); then echo "--- quickshell"; grep -v 'Socket error\|IPC server' "$w/out.log" | tail -30; echo "--- engine calls"; cat "$w/calls.log"; fi
echo "service-smoke: $checks checks, $fails failed"
exit $(( fails > 0 ))
