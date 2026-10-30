#!/usr/bin/env bash
# run.sh — end-to-end "other machine" simulations (portability plan §14.6).
#
#   tests/e2e/run.sh [--engine PATH] [-v]
#
# For each machine in tests/detect/fixtures (a-openrgb-intel: OpenRGB only,
# Intel coretemp and an amdgpu dGPU; b-slinf-round-pump: SL-INF fans and a
# round HydroShift LCD pump, no Strimers, no OpenRGB; c-nothing), in a fresh
# fixture $HOME with tests/e2e/overrides.sh as PCL_TEST_OVERRIDES:
#   1. pc-lights detect writes a v1 profile;
#   2. the three examples/themes and one migrated real theme
#      (tests/theme/sakura.v3.json, the v3 sakura with empty stand-in media)
#      render: exit 0, a skip note for every backend with nothing to drive,
#      no error on stderr; sakura's pump media is never put on a round pump
#      (coverage "none", and the pump's config entry is left as it was);
#   3. status --json, themes --json and sensors --json are valid contract v1(.1);
#   4. install --dry-run and --all --dry-run exit 0, would link both names
#      (lumenaire and its alias pc-lights), and write nothing.
# PCL_E2E_KEEP=1 keeps the scratch dir (printed by bash -x) for a look.
# Nothing reaches the daemon, sysfs, the units or OpenRGB: a refusing
# "openrgb" goes first in PATH, and the overrides replace every device read.
# shellcheck disable=SC2016  # jq filters are single-quoted on purpose
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
engine=$repo/bin/pc-lights verbose=''
while (( $# )); do
  case $1 in
    --engine) engine=$2; shift 2 ;;
    -v) verbose=1; shift ;;
    *) sed -n '2,/^set -euo/{/^# shellcheck/d;/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
engine=$(readlink -f "$engine")
[[ -x $engine ]] || { echo "run.sh: no engine at $engine" >&2; exit 2; }

real_home=$HOME
work=$(mktemp -d)
trap '[[ -n ${PCL_E2E_KEEP:-} ]] || rm -rf "$work"' EXIT
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "tests/e2e: blocked: openrgb $*" >&2\necho blocked >>"$HOME/openrgb-real-calls.log"\nexit 99\n' >"$work/bin/openrgb"
chmod +x "$work/bin/openrgb"
export PATH=$work/bin:$PATH

passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | head -30 | sed 's/^/     /'; fi; }
jcheck() {   # jcheck <name> <jq filter> <json text> [jq args...]
  local n=$1 f=$2 j=$3; shift 3
  if jq -e "$@" "$f" >/dev/null 2>&1 <<<"$j"; then ok "$n"; else bad "$n" "$(jq -c "$@" "$f" 2>&1 <<<"$j" | head -c 600)"; fi
}
# Errors a render must not print (log lines like "profile stale" are fine).
errs() { grep -iE 'error|fail|refus|cannot|could not|not found|invalid|missing|blocked' "$1" || true; }

# fakesys <fixture> <root>: a sysfs/procfs tree from the fixture's tables.
fakesys() {
  local fx=$1 root=$2 h k v d pd bus
  mkdir -p "$root/sys/class/hwmon" "$root/sys/devices" "$root/proc"
  while IFS=$'\t' read -r h k v; do
    [[ -n $h ]] || continue
    d=$root/sys/class/hwmon/$h; mkdir -p "$d"
    case $k in
      device) if [[ -n $v ]]; then pd=$root/sys/devices/${v##*/}; mkdir -p "$pd"; ln -sfn "$pd" "$d/device"; fi ;;
      *) printf '%s\n' "$v" >"$d/$k" ;;
    esac
  done <"$fx/hwmon.tsv"
  if [[ -s $fx/nvidia-information ]]; then
    bus=$(awk -F':[ \t]+' '/^Bus Location:/ { print $2 }' "$fx/nvidia-information")
    mkdir -p "$root/proc/driver/nvidia/gpus/$bus"
    cp "$fx/nvidia-information" "$root/proc/driver/nvidia/gpus/$bus/information"
  fi
}

echo "engine: $engine ($(sha256sum <"$engine" | cut -c1-16))"
for fxdir in "$repo"/tests/detect/fixtures/*/; do
  fxdir=${fxdir%/} m=${fxdir##*/}
  echo "== $m"
  H=$work/$m/home SYS=$work/$m/fake; mkdir -p "$H/.cache/pc-lights" "$H/.config/pc-lights/themes"
  if [[ -f $fxdir/openrgb-list.txt ]]; then cp "$fxdir/openrgb-list.txt" "$H/.cache/pc-lights/openrgb-list.txt"; fi
  fakesys "$fxdir" "$SYS"
  pcl() { HOME=$H PCL_REAL_HOME=$real_home PCL_DETECT_FX=$fxdir PCL_E2E_SYS=$SYS PCL_TEST_OVERRIDES=$here/overrides.sh "$engine" "$@"; }

  # 1. detect
  if pcl detect >"$work/$m/detect.out" 2>"$work/$m/detect.err"; then ok "$m: detect exits 0"
  else bad "$m: detect exits 0" "$(cat "$work/$m/detect.err")"; fi
  P=$H/.config/pc-lights/profile.json
  jcheck "$m: a v1 profile" '.v == 1 and (.devices | type) == "object" and (.roles | type) == "object"' "$(cat "$P" 2>/dev/null || echo null)"
  lianli=$(jq -r '[.devices[] | select(.backend == "lianli" and .present)] | length' "$P" 2>/dev/null || echo 0)
  orgb=$(jq -r '[.devices[] | select(.backend == "openrgb" and .present and .kind != "duplicate")] | length' "$P" 2>/dev/null || echo 0)

  # 2. themes: the examples and the migrated sakura (empty stand-in media).
  for d in "$repo"/examples/themes/*/; do cp -r "$d" "$H/.config/pc-lights/themes/"; done
  S=$H/.config/pc-lights/themes/sakura
  mkdir -p "$S/media/pump" "$S/us88"
  cp "$repo/tests/theme/sakura.v3.json" "$S/theme.json"
  for f in fan-a fan-b fan-c fan-d fan-e pump pump/1; do : >"$S/media/$f.mp4"; done
  echo '{"id": "us88-sakura", "background": {"path": "us88/bg.png"}, "widgets": []}' >"$S/us88/us88-sakura.template.json"
  echo aurora >"$H/.config/pc-lights/scheme"
  for t in aurora ember glacier sakura; do
    rc=0; pcl render "$t" >"$work/$m/$t.out" 2>"$work/$m/$t.err" || rc=$?
    e=$(errs "$work/$m/$t.err")
    if (( rc == 0 )) && [[ -z $e ]]; then ok "$m: render $t (exit 0, no errors)"
    else bad "$m: render $t: exit $rc" "$(cat "$work/$m/$t.err")"; fi
    [[ -z $verbose ]] || sed 's/^/     | /' "$work/$m/$t.out" | head -12
    note_ok=1
    if (( lianli == 0 )) && ! grep -q '^# lianli: skipped (' "$work/$m/$t.out"; then note_ok=; fi
    if (( orgb == 0 )) && ! grep -q '^# openrgb: skipped (' "$work/$m/$t.out"; then note_ok=; fi
    if (( lianli > 0 )) && ! grep -q '^# .rgb$' "$work/$m/$t.out"; then note_ok=; fi
    if (( orgb > 0 )) && ! grep -q '^# openrgb (RAM ids: ' "$work/$m/$t.out"; then note_ok=; fi
    if [[ -n $note_ok ]]; then ok "$m: render $t: a section per backend, a skip note for each with nothing to drive"
    else bad "$m: render $t: sections and skip notes" "$(grep '^#' "$work/$m/$t.out")"; fi
  done
  # A round pump never gets the wide-curve pump clips.
  tj=$(pcl themes --json 2>"$work/$m/themes.err" || true)
  if jq -e '.roles["screen.pump"] != null' "$P" >/dev/null 2>&1; then
    jcheck "$m: sakura's pump media is not put on the round pump (coverage none)" \
      '.[] | select(.name == "sakura") | .coverage.roles["screen.pump"] == "none"' "$tj"
    want=$(jq -c '.lcds' "$fxdir/lianli/config.json")
    got=$(sed -n '/^# .lcds$/,/^# .thermal_alert$/p' "$work/$m/sakura.out" | sed '1d;$d' | jq -c .)
    if [[ $got == "$want" ]]; then ok "$m: render sakura leaves the pump's config entry as it was"
    else bad "$m: render sakura changed the pump's config entry" "$got"; fi
  fi

  # 3. the JSON contract
  sj=$(pcl status --json 2>"$work/$m/status.err" || true)
  jcheck "$m: status --json is v1.1 with the profile" '.v == 1 and .v_minor >= 1 and .profile.state == "ok"
    and (.screens_on_usb.want | type == "number") and (.screens_on_usb.have | type == "number")
    and (.labels | type == "object") and (.profile.backends | type == "object")' "$sj"
  jcheck "$m: themes --json lists the 4 themes with schema 3 and coverage" 'length == 4
    and all(.[]; .schema == 3 and (.coverage.summary | type == "string") and (.colors | type == "object"))' "$tj"
  se=$(pcl sensors --json 2>"$work/$m/sensors.err" || true)
  jcheck "$m: sensors --json is valid" '.v == 1 and .source == "profile" and (.gpus | type == "array") and (.ram | type == "array")
    and ([.cpu, .gpu][] | . == null or (.available | type == "boolean"))' "$se"
  case $m in
    a-*) jcheck "$m: sensors: coretemp package, the amdgpu dGPU, two jc42" '.cpu.driver == "coretemp" and .cpu.available
           and .gpu.driver == "amdgpu" and .gpu.integrated == false and .gpu.available and (.ram | length) == 2 and .coolant == null' "$se" ;;
    b-*) jcheck "$m: sensors: zenpower Tdie, NVIDIA via nvidia-smi, coolant from the AIO" '.cpu.driver == "zenpower" and .cpu.label == "Tdie"
           and .cpu.available and .gpu.kind == "nvidia-smi" and .coolant.device_id == "hid:0416:7398:3-4" and .pump.field == "fan_rpms"' "$se" ;;
    c-*) jcheck "$m: sensors: nothing at all" '.cpu == null and .gpu == null and .gpus == [] and .ram == [] and .coolant == null' "$se" ;;
  esac

  # 4. install --dry-run: says what it would do, writes nothing.
  before=$(find "$H" -printf '%P %s %T@\n' | sort | sha256sum)
  for args in "--dry-run" "--all --dry-run"; do
    rc=0
    # shellcheck disable=SC2086
    pcl install $args >"$work/$m/install.out" 2>&1 || rc=$?
    if (( rc == 0 )) && grep -q 'dry run' "$work/$m/install.out" && grep -q 'would.*link .*/.local/bin/lumenaire -> .*/bin/lumenaire$' "$work/$m/install.out" \
         && grep -q 'would.*link .*/.local/bin/pc-lights -> .*/bin/lumenaire$' "$work/$m/install.out"; then
      ok "$m: install $args: exit 0, would link the engine as lumenaire and pc-lights"
    else bad "$m: install $args: exit $rc" "$(cat "$work/$m/install.out")"; fi
  done
  if [[ $(find "$H" -printf '%P %s %T@\n' | sort | sha256sum) == "$before" ]]; then ok "$m: install --dry-run wrote nothing"
  else bad "$m: install --dry-run wrote into the fixture HOME"; fi
  if [[ -e $H/openrgb-real-calls.log ]]; then bad "$m: something tried to run the real openrgb"; else ok "$m: the real openrgb was never run"; fi
done

echo
echo "passed $passed, failed $failed"
(( failed == 0 ))
