# frozen.sh — pins a pc-lights engine to a golden capture's frozen inputs.
#
# Sourced by the engine through its PCL_TEST_OVERRIDES hook, after every
# function is defined:
#
#   PCL_GOLDEN=~/.cache/pc-lights/golden/<stamp> PCL_TEST_OVERRIDES=tests/golden/frozen.sh pc-lights render sakura
#
# It works for the reference engine (pc-lights.pre-portable) and the new one:
# both keep these globals and function names as override points, read at call
# time (portability plan §7): CFG_LIVE CFG TPL_LIVE TPL_FILE STATE_DIR PROFILE
# RAM_CACHE CLIPS_STATE THEME_DIR, daemon_call daemon_guarded usb_serial_map.
# THEME_DIR stays real, so the absolute media paths in .lcds match the capture.
#
#   PCL_GOLDEN           the capture dir (required)
#   PCL_GOLDEN_PROFILE   profile.json to use (default <capture>/inputs/state/profile.json,
#                        which does not exist: no profile)
#   PCL_GOLDEN_THEME_DIR another theme dir (migrate's shadow copy); run.sh
#                        maps that prefix back to the real one before diffing
#   PCL_GOLDEN_PROBE=off print the off state in render's format and exit
#
# Nothing here can reach the hardware: the daemon socket, guarded writes,
# unit changes and OpenRGB are replaced, and every write lands in $TMP.
# shellcheck shell=bash disable=SC2034

: "${PCL_GOLDEN:?frozen.sh needs PCL_GOLDEN=<golden capture dir>}"
G=$PCL_GOLDEN/inputs
[[ -f $G/lianli/config.json ]] || { echo "frozen.sh: no capture at $PCL_GOLDEN" >&2; exit 97; }

CFG_LIVE=$G/lianli/config.json CFG=$G/lianli/config.json
TPL_LIVE=$G/lianli/lcd_templates.json TPL_FILE=$G/lianli/lcd_templates.json
STATE_DIR=$G/state
SCHED=$STATE_DIR/schedule.json DAY_SCHEME=$STATE_DIR/day-scheme
PROFILE=${PCL_GOLDEN_PROFILE:-$G/state/profile.json}
# ram_ids rewrites RAM_CACHE when it re-reads OpenRGB, so it gets a scratch
# copy too: a builder calling ram_ids/openrgb_args must never touch the capture.
RAM_CACHE=$TMP/golden-ram-ids
cp "$G/cache/ram-ids" "$RAM_CACHE" 2>/dev/null || true
# render deletes CLIPS_STATE (apply_scheme_screens restarts the rotation), so
# it gets a scratch copy.
CLIPS_STATE=$TMP/golden-clips.json
cp "$G/cache/clips.json" "$CLIPS_STATE" 2>/dev/null || true
if [[ -n ${PCL_GOLDEN_THEME_DIR:-} ]]; then THEME_DIR=$PCL_GOLDEN_THEME_DIR; fi
# A v3 theme compiles into $CACHE/compiled, which the live engine shares and
# prunes per theme: a test's compile (another profile, another theme.jq) goes
# to a scratch cache instead. The reference v2 engine has no theme_eff.
golden_cache_wrap() {
  declare -F theme_eff >/dev/null || return 0
  eval "$(declare -f theme_eff | sed '1s/^theme_eff /_golden_theme_eff /')"
  theme_eff() { local CACHE=$TMP/golden-cache; _golden_theme_eff "$@"; }
}
golden_cache_wrap

daemon_call() {
  local m
  m=$(jq -r .method <<<"$1")
  [[ -f $G/daemon/$m.json ]] || { echo "frozen.sh: no frozen reply for $m" >&2; return 1; }
  cat "$G/daemon/$m.json"
}
daemon_guarded() { LIVE_ERR=blocked-in-golden; return 1; }
usb_serial_map() { cp "$G/usbmap.json" "$TMP/usbmap.json"; echo "$TMP/usbmap.json"; }
# LCDs on USB, from the captured sysfs table (vendor 1cbe, a018/a068/a088).
usb_screens() { awk -F'\t' '$2 == "1cbe" && $3 ~ /^(a018|a068|a088)$/ { n++ } END { print n + 0 }' "$G/sysfs-usb.tsv"; }
lsusb() { cat "$G/lsusb.txt"; }
systemctl() {
  case " $* " in
    *" is-active "*)
      case " $* " in *" -q "* | *" --quiet "*) ;; *) echo active ;; esac
      return 0 ;;
    *) echo "blocked: systemctl $*" >&2; return 1 ;;
  esac
}
systemd-run() { echo "blocked: systemd-run $*" >&2; return 1; }
journalctl() { return 0; }
openrgb() { cat "$G/openrgb-list.txt"; }   # detect only; render never calls it
# The function above doesn't catch "timeout 120 openrgb …" (timeout execs the
# binary through PATH), so a stub binary goes first in PATH too: it serves the
# frozen listing and refuses anything else, which must never reach the real
# SMBus devices from a test (2026-09-24: a test listed the real devices twice).
mkdir -p "$TMP/golden-bin"
cat >"$TMP/golden-bin/openrgb" <<STUB
#!/bin/sh
case " \$* " in *" --list-devices "*|*" -l "*) exec cat "$G/openrgb-list.txt" ;; esac
echo "frozen.sh: refused real openrgb \$*" >&2; exit 97
STUB
chmod +x "$TMP/golden-bin/openrgb"
PATH=$TMP/golden-bin:$PATH
logger() { :; }
pkill() { return 1; }

# The off state, in render's format: what "off" would write (.rgb all Off,
# alerts disabled, screens untouched) and the OpenRGB off arguments. The
# header names the active theme, as "render --state off" with no name would.
if [[ ${PCL_GOLDEN_PROBE:-} == off ]]; then
  THEME=$(active_name)
  fetch_caps 1
  build_lianli write_lianli_rgb off
  echo "# theme: $THEME (screens state: $(screens_state))"
  echo "# .rgb"; jq '.rgb' "$TMP/work-config.json"
  echo "# .lcds"; jq '.lcds' "$TMP/work-config.json"
  echo "# .thermal_alert"; jq -c '.thermal_alert' "$TMP/work-config.json"
  echo "# templates installed: $(jq -r --slurpfile o "$TMP/built-from-tpl.json" \
    '[.templates[] | select(. as $t | ($o[0].templates | index($t)) | not) | .id] | join(" ")' "$TMP/work-tpl.json")"
  RAM_IDS=$(cat "$RAM_CACHE" 2>/dev/null || true)
  [[ -n ${RAM_IDS// /} ]] || RAM_IDS='RAM0 RAM1'
  RAM_IDS_DONE=1
  golden_args=()
  openrgb_args off >"$TMP/orgb.args" || die "could not build the OpenRGB command"
  mapfile -t golden_args <"$TMP/orgb.args"
  echo "# openrgb (RAM ids: $RAM_IDS)"
  printf '%q ' timeout 120 openrgb "${golden_args[@]}"; echo
  exit 0
fi
