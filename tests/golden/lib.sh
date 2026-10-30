# lib.sh — shared by tests/golden/capture.sh and run.sh (sourced, not run).
#
# The golden data lives in ~/.cache/pc-lights/golden/<stamp>/, never in the
# repo: the inputs hold this machine's real USB serials and wireless MACs.
# ~/.cache/pc-lights/golden/current points at the capture run.sh uses, and
# ~/.cache/pc-lights/golden/v2 at the migration-era capture (v2 themes, no
# profile) with its frozen theme snapshot themes-v2/ (freeze-v2.sh). See README.md.
# shellcheck shell=bash disable=SC2034

GOLDEN_ROOT=${PCL_GOLDEN_ROOT:-$HOME/.cache/pc-lights/golden}
GOLDEN_V2=$GOLDEN_ROOT/v2
GOLDEN_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FROZEN=$GOLDEN_HERE/frozen.sh
LIVE_SOCK=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock

# The theme names, in order: every folder in the real theme dir with a theme.json.
golden_themes() {
  local f
  for f in "${1:-$HOME/.config/pc-lights/themes}"/*/theme.json; do
    [[ -f $f ]] && basename "$(dirname "$f")"
  done
}

# The v2 theme snapshot the fixtures copy (migrate, engine-contract, editor):
# never the live theme dir, which is v3 since the cut-over.
golden_v2_themes() {
  local d=$GOLDEN_V2/themes-v2
  [[ -f $d/sakura/theme.json ]] || { echo "no v2 theme snapshot at $d (run tests/golden/freeze-v2.sh)" >&2; return 1; }
  readlink -f "$d"
}

# golden_conf <capture> <key> [default]: a key=value from <capture>/capture.conf
# (profile, themes, reference); the default when the capture has none.
golden_conf() {
  local v=''
  if [[ -f $1/capture.conf ]]; then v=$(sed -n "s/^$2=//p" "$1/capture.conf" | tail -1); fi
  echo "${v:-${3:-}}"
}

# golden_snapshot_themes <src> <dst>: a frozen copy of a theme dir. The media
# (video, images, fonts) are hard links where the filesystem allows (never
# edited in place: the engine and editor replace them); everything else is a
# real copy, so an in-place edit of a live theme.json can never reach it.
# Then <dst>.sha256 (paths relative to <dst>) and mode 0700 (real serials).
GOLDEN_MEDIA_RE='.*\.(mp4|webm|mkv|mov|gif|jpe?g|png|webp|bmp|otf|ttf|woff2?)'
golden_snapshot_themes() {
  local src=$1 dst=$2 rel
  [[ -d $src ]] || { echo "golden_snapshot_themes: no theme dir at $src" >&2; return 1; }
  [[ ! -e $dst ]] || { echo "golden_snapshot_themes: $dst exists" >&2; return 1; }
  if cp -al "$src" "$dst" 2>/dev/null; then
    (cd "$src" && find . -type f -regextype posix-extended ! -iregex "$GOLDEN_MEDIA_RE" -print0) |
      while IFS= read -r -d '' rel; do rm -f "$dst/$rel"; cp -p "$src/$rel" "$dst/$rel"; done
  else
    rm -rf "$dst"; cp -a --reflink=auto "$src" "$dst"
  fi
  chmod 700 "$dst"
  (cd "$dst" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$dst.sha256"
}
# golden_check_themes <snapshot> [dir]: every non-media file of <dir> (default
# the snapshot itself) still hashes as snapshotted.
golden_check_themes() {
  [[ -f $1.sha256 ]] || { echo "no manifest $1.sha256" >&2; return 1; }
  grep -Eiv "^[0-9a-f]+  $GOLDEN_MEDIA_RE\$" "$1.sha256" | (cd "${2:-$1}" && sha256sum -c --quiet --strict -)
}

# One read-only daemon request; the raw reply on stdout.
golden_daemon() {
  printf '{"method":"%s"}\n' "$1" | timeout 10 socat -t 10 - "UNIX-CONNECT:$LIVE_SOCK"
}

# The engine's usb_serial_map, verbatim (the same loop and jq): serial -> hid path.
golden_usbmap() {
  local d
  {
    for d in /sys/bus/usb/devices/*; do
      [[ -f $d/idVendor && $(cat "$d/idVendor") == 1cbe && -f $d/serial ]] || continue
      printf '{"serial":"%s","path":"hid:1cbe:%s:%s"}\n' "$(cat "$d/serial")" "$(cat "$d/idProduct")" "$(basename "$d")"
    done
  } | jq -s 'map({(.serial): .path}) | add // {}'
}

# Everything render reads, re-read live, into <dir>: the daemon config and
# templates, the capabilities, the USB serial map, the state files render and
# the probes consult, and ram-ids. clips.json is not a render input (render
# only deletes it), and it moves every few minutes with the clip timer.
golden_render_inputs() {
  local d=$1 f
  mkdir -p "$d"
  cp "$HOME/.config/lianli/config.json" "$d/config.json"
  if [[ -f $HOME/.config/lianli/lcd_templates.json ]]; then cp "$HOME/.config/lianli/lcd_templates.json" "$d/lcd_templates.json"; fi
  golden_daemon GetRgbCapabilities >"$d/GetRgbCapabilities.json"
  golden_usbmap >"$d/usbmap.json"
  for f in scheme screens lights alerts.json omarchy-map.json profile.json; do
    if [[ -f $HOME/.config/pc-lights/$f ]]; then cp "$HOME/.config/pc-lights/$f" "$d/state-$f"; fi
  done
  cp "$HOME/.cache/pc-lights/ram-ids" "$d/ram-ids" 2>/dev/null || true
}

# sha256 lines of a render-input dir, file names only (stable across dirs).
golden_hash_dir() { (cd "$1" && sha256sum -- * | sort -k2); }

# Idle check: no claimed run, nothing queued, and not within 2 min of a
# schedule boundary (00:00 / 07:00 or whatever schedule.json says).
golden_idle() {
  local c=$HOME/.cache/pc-lights s e t now
  if [[ -e $c/busy.json ]]; then echo "busy.json exists (a run holds the lock)"; return 1; fi
  if compgen -G "$c/pending/*.json" >/dev/null; then echo "pending/ has queued requests"; return 1; fi
  s=$(jq -r '.night_start // "00:00"' "$HOME/.config/pc-lights/schedule.json" 2>/dev/null || echo 00:00)
  e=$(jq -r '.night_end // "07:00"' "$HOME/.config/pc-lights/schedule.json" 2>/dev/null || echo 07:00)
  now=$(date +%s)
  for t in "today $s" "today $e" "tomorrow $s" "tomorrow $e" "yesterday $s" "yesterday $e"; do
    t=$(date -d "$t" +%s)
    if (( t - now < 120 && now - t < 120 )); then echo "within 2 min of a schedule boundary ($(date -d "@$t" +%H:%M))"; return 1; fi
  done
  if pgrep -x openrgb >/dev/null; then echo "an openrgb process is running"; return 1; fi
  # The engine lock (a run, or "theme preview --measure" holding it): a
  # non-blocking try, never a wait and never a break.
  if [[ -e $c/lock ]] && ! flock -n "$c/lock" true; then echo "the engine lock is held"; return 1; fi
  return 0
}

# frozen_run <golden dir> <engine> <args...>: the engine against the frozen
# inputs (frozen.sh through the PCL_TEST_OVERRIDES hook). HOME stays real, so
# THEME_DIR and the absolute media paths are this machine's.
frozen_run() {
  local g=$1 engine=$2; shift 2
  PCL_GOLDEN=$g PCL_TEST_OVERRIDES=$FROZEN "$engine" "$@"
}

# The clip-rotation countdown in "clips status" is wall-clock time.
golden_clips_normalise() { sed -E 's/next in [0-9]+s/next in Ns/'; }

# The probes, into <outdir>: probe-{off,themes,rotation,clips,status}.out.
# $3 = off-probe method: "function" (write_lianli_rgb off + openrgb_args off
# called through frozen.sh) or "render" (the engine's own render --state off).
golden_probes() {
  local g=$1 engine=$2 how=${3:-function} out=$4 rc=0
  mkdir -p "$out"
  if [[ $how == render ]]; then
    frozen_run "$g" "$engine" render --state off >"$out/probe-off.out" 2>"$out/probe-off.err" || rc=$?
  else
    PCL_GOLDEN_PROBE=off frozen_run "$g" "$engine" render >"$out/probe-off.out" 2>"$out/probe-off.err" || rc=$?
  fi
  echo "$rc" >"$out/probe-off.rc"
  { frozen_run "$g" "$engine" themes --json 2>"$out/probe-themes.err" |
    jq '[.[] | {name, about, colors, swatch, omarchy_slugs}]' >"$out/probe-themes.out"; } || true
  { frozen_run "$g" "$engine" status --json 2>"$out/probe-rotation.err" |
    jq '.rotation | map({serial, where, count, rotate, shuffle})' >"$out/probe-rotation.out"; } || true
  { frozen_run "$g" "$engine" clips status 2>"$out/probe-clips.err" | golden_clips_normalise >"$out/probe-clips.out"; } || true
  frozen_run "$g" "$engine" status >"$out/probe-status.out" 2>"$out/probe-status.err" || true
  return 0
}
GOLDEN_PROBES=(off themes rotation clips status)
