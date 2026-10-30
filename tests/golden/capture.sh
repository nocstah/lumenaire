#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# capture.sh — capture the pc-lights goldens (portability plan §7, WP0).
#
#   tests/golden/capture.sh [--engine PATH] [--no-openrgb] [--profile FILE|none] [--themes DIR]
#
# Run while the engine is idle: once before the engine changed (the v2
# capture, now golden/v2), and again after the cut-over (the v3 baseline,
# golden/current; see README.md). It:
#  1. refuses while a run is claimed (busy.json), requests are queued
#     (pending/), the engine lock is held (a run, or "theme preview
#     --measure"), within 2 min of a schedule boundary, or OpenRGB is running;
#  2. keeps the reference engine (default ~/.local/bin/pc-lights): an engine
#     tree (bin/ beside lib/pc-lights/, the installed plugin since the
#     cut-over) is copied to <capture>/engine/; a single-file engine (the
#     pre-portable one) to ~/.cache/pc-lights/pc-lights.pre-portable and
#     <capture>/pc-lights.pre-portable;
#  3. freezes the theme dir (default the live one) into <capture>/themes-v3/
#     (or themes-v2/ while any theme is v2; media hard-linked, manifest
#     <capture>/themes-vN.sha256) and the profile (default the live
#     profile.json when there is one) into <capture>/profile.json, and
#     writes capture.conf (themes, profile, reference) for run.sh;
#  4. snapshots every input render and detect read into
#     ~/.cache/pc-lights/golden/<stamp>/inputs (read-only daemon calls, sysfs,
#     state files, and one "openrgb --list-devices" under the pc-lights lock;
#     --no-openrgb copies the listing the last apply cached instead),
#     with a sha256 manifest;
#  5. renders all themes with the reference engine against the live system
#     (live/<theme>.{out,err,rc}; CLIPS_STATE goes to a scratch file, since
#     render deletes it and it is not an input);
#  6. runs the probes (off state, themes colours, rotation, clips and status
#     text) through frozen.sh (probes/);
#  7. self-checks: the reference engine through frozen.sh (the frozen themes
#     and profile) must reproduce every live render byte for byte, and the
#     live render inputs and themes must still hash as they did before the
#     renders. Otherwise it fails: start over.
# On success ~/.cache/pc-lights/golden/current points at the new capture.
#
# Everything lands outside the repo: the capture holds real serials and MACs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

engine=$HOME/.local/bin/pc-lights orgb=1 profile_src='' themes_src=$HOME/.config/pc-lights/themes
while (( $# )); do
  case $1 in
    --engine) engine=$2; shift 2 ;;
    --no-openrgb) orgb=; shift ;;
    --profile) profile_src=$2; shift 2 ;;
    --themes) themes_src=$2; shift 2 ;;
    *) echo "usage: capture.sh [--engine PATH] [--no-openrgb] [--profile FILE|none] [--themes DIR]" >&2; exit 2 ;;
  esac
done
engine=$(readlink -f "$engine") themes_src=$(readlink -f "$themes_src")
if [[ -z $profile_src && -f $HOME/.config/pc-lights/profile.json ]]; then profile_src=$HOME/.config/pc-lights/profile.json; fi
[[ $profile_src != none ]] || profile_src=''
[[ -z $profile_src || -f $profile_src ]] || { echo "capture.sh: no profile at $profile_src" >&2; exit 2; }
[[ -x $engine ]] || { echo "capture.sh: no engine at $engine" >&2; exit 2; }
[[ -d $themes_src ]] || { echo "capture.sh: no theme dir at $themes_src" >&2; exit 2; }

why=$(golden_idle) || { echo "capture.sh: not idle: $why; try again later" >&2; exit 1; }

stamp=$(date +%Y%m%dT%H%M%S)
g=$GOLDEN_ROOT/$stamp
in=$g/inputs
mkdir -p "$in"/{daemon,lianli,state,cache,systemd} "$g/live" "$g/probes"
chmod 700 "$g"
echo "capture: $g"

# ---- 2. the reference engine ----------------------------------------------------
etree=$(dirname "$(dirname "$engine")")
if [[ -d $etree/lib/pc-lights ]]; then
  # An engine tree: bin/ and lib/ travel together (the engine finds its lib
  # beside itself). ~/.cache/pc-lights/pc-lights.pre-portable stays the v2 one.
  mkdir -p "$g/engine"
  cp -a "$etree/bin" "$etree/lib" "$g/engine/"
  refrel=engine/bin/${engine##*/}
  ref=$g/$refrel
  (cd "$g/engine" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$g/engine.sha256"
  echo "reference engine: $etree -> $ref ($(sha256sum <"$g/engine.sha256" | cut -c1-16))"
else
  ref=$HOME/.cache/pc-lights/pc-lights.pre-portable refrel=pc-lights.pre-portable
  cp "$engine" "$ref.tmp.$$" && mv -f "$ref.tmp.$$" "$ref"
  cp "$ref" "$g/pc-lights.pre-portable"
  sha256sum "$ref" | cut -d' ' -f1 >"$g/engine.sha256"
  echo "reference engine: $ref ($(cat "$g/engine.sha256"))"
  ref=$g/pc-lights.pre-portable
fi

# ---- 3. the frozen themes and profile -------------------------------------------
tv=themes-v3
if jq -e 'select((.v // 2) != 3)' "$themes_src"/*/theme.json >/dev/null 2>&1; then tv=themes-v2; fi
golden_snapshot_themes "$themes_src" "$g/$tv"
pmode=none
if [[ -n $profile_src ]]; then cp -p "$profile_src" "$g/profile.json"; pmode=real; fi
printf '%s\n' "# captured $stamp from $themes_src${profile_src:+ with $profile_src}" \
  "themes=$tv" "profile=$pmode" "reference=$refrel" >"$g/capture.conf"
echo "themes: $themes_src -> $g/$tv ($(wc -l <"$g/$tv.sha256") files); profile: $pmode"
# The frozen runs below read what run.sh will read.
export PCL_GOLDEN_THEME_DIR=$g/$tv
if [[ $pmode == real ]]; then export PCL_GOLDEN_PROFILE=$g/profile.json
else export PCL_GOLDEN_PROFILE=$g/inputs/state/no-profile.json; fi
unshadow() { sed "s#$g/$tv#$themes_src#g"; }

# ---- 4. inputs ------------------------------------------------------------------
golden_render_inputs "$g/before"
for m in GetRgbCapabilities ListDevices GetConfig GetDaemonInfo GetTelemetry; do
  golden_daemon "$m" >"$in/daemon/$m.json"
  jq -e '.status == "ok"' "$in/daemon/$m.json" >/dev/null || { echo "capture.sh: $m failed" >&2; exit 1; }
done
cp "$HOME/.config/lianli/config.json" "$in/lianli/config.json"
cp "$HOME/.config/lianli/lcd_templates.json" "$in/lianli/lcd_templates.json"
golden_usbmap >"$in/usbmap.json"
for d in /sys/bus/usb/devices/*; do
  [[ -f $d/idVendor ]] || continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${d##*/}" "$(cat "$d/idVendor")" "$(cat "$d/idProduct" 2>/dev/null)" \
    "$(cat "$d/serial" 2>/dev/null || true)" "$(cat "$d/manufacturer" 2>/dev/null || true)" "$(cat "$d/product" 2>/dev/null || true)"
done >"$in/sysfs-usb.tsv"
lsusb >"$in/lsusb.txt" 2>/dev/null || true
for f in scheme day-scheme lights screens clips alerts.json schedule.json omarchy-map.json; do
  if [[ -f $HOME/.config/pc-lights/$f ]]; then cp -p "$HOME/.config/pc-lights/$f" "$in/state/$f"; fi
done
cp -p "$HOME/.cache/pc-lights/ram-ids" "$in/cache/ram-ids"
cp -p "$HOME/.cache/pc-lights/clips.json" "$in/cache/clips.json" 2>/dev/null || echo '{}' >"$in/cache/clips.json"
for f in schedule-boundary omarchy-requested; do
  if [[ -f $HOME/.cache/pc-lights/$f ]]; then cp -p "$HOME/.cache/pc-lights/$f" "$in/cache/$f"; fi
done
# hwmon: one row per attribute detect reads (name, temp labels and inputs,
# and the GPU hints boot_vga / mem_info_vram_total behind the device link).
for h in /sys/class/hwmon/hwmon*; do
  printf '%s\tname\t%s\n' "${h##*/}" "$(cat "$h/name" 2>/dev/null || true)"
  printf '%s\tdevice\t%s\n' "${h##*/}" "$(readlink -f "$h/device" 2>/dev/null || true)"
  for f in "$h"/temp*_label "$h"/temp*_input "$h"/device/boot_vga "$h"/device/mem_info_vram_total; do
    [[ -r $f ]] && printf '%s\t%s\t%s\n' "${h##*/}" "${f#"$h"/}" "$(cat "$f" 2>/dev/null || true)"
  done
done >"$in/hwmon.tsv"
cat /proc/driver/nvidia/gpus/*/information >"$in/nvidia-information" 2>/dev/null || : >"$in/nvidia-information"
cat /proc/cmdline >"$in/cmdline"
cp "$HOME/.config/OpenRGB/OpenRGB.json" "$in/OpenRGB.json" 2>/dev/null || true
cp -p "$HOME/.config/OpenRGB/sizes.ors" "$in/sizes.ors" 2>/dev/null || true
cp -rp "$HOME/.config/systemd/user/lianli-daemon.service.d" "$in/systemd/" 2>/dev/null || true
{ pacman -Q lianli-linux-git openrgb 2>&1 || true; } >"$in/pacman-q.txt"
if [[ -z $orgb ]]; then
  # What the last real apply listed (ram_ids caches it); never a new listing.
  if [[ -f $HOME/.cache/pc-lights/openrgb-list.txt ]]; then
    cp -p "$HOME/.cache/pc-lights/openrgb-list.txt" "$in/openrgb-list.txt"
    echo "cached by the last apply: ~/.cache/pc-lights/openrgb-list.txt ($(date -r "$in/openrgb-list.txt" '+%F %T'))" >"$in/openrgb-list.src"
  fi
else
  # The same listing a real apply runs (ram_ids), under the lock so it never
  # runs beside an apply (a second OpenRGB can glitch the ENE RAM controllers).
  echo "openrgb --list-devices (under the pc-lights lock)..."
  flock -w 600 "$HOME/.cache/pc-lights/lock" timeout 120 openrgb --list-devices >"$in/openrgb-list.txt" 2>"$in/openrgb-list.err" ||
    echo "capture.sh: openrgb --list-devices failed (see $in/openrgb-list.err)" >&2
fi
(cd "$in" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum) >"$in/MANIFEST.sha256"

# ---- 5. live renders ------------------------------------------------------------
mapfile -t themes < <(golden_themes "$themes_src")
printf '%s\n' "${themes[@]}" >"$g/themes.txt"
# render deletes CLIPS_STATE; a v3 compile goes to a scratch cache, never the
# live compiled/ (which the engine prunes per theme).
cat >"$g/live-overrides.sh" <<'OVR'
CLIPS_STATE=$TMP/golden-live-clips.json
if declare -F theme_eff >/dev/null; then
  eval "$(declare -f theme_eff | sed '1s/^theme_eff /_golden_theme_eff /')"
  theme_eff() { local CACHE=$TMP/golden-cache; _golden_theme_eff "$@"; }
fi
OVR
for t in "${themes[@]}"; do
  rc=0
  PCL_TEST_OVERRIDES=$g/live-overrides.sh "$ref" render "$t" >"$g/live/$t.out" 2>"$g/live/$t.err" || rc=$?
  echo "$rc" >"$g/live/$t.rc"
done

# ---- 6. probes ------------------------------------------------------------------
golden_probes "$g" "$ref" function "$g/probes"

# ---- 7. self-check --------------------------------------------------------------
golden_render_inputs "$g/after"
if ! diff <(golden_hash_dir "$g/before") <(golden_hash_dir "$g/after") >"$g/moved.diff"; then
  echo "capture.sh: live render inputs moved during the capture (see $g/moved.diff); start over" >&2
  exit 1
fi
if ! golden_check_themes "$g/$tv" "$themes_src" >"$g/themes-moved.txt" 2>&1; then
  echo "capture.sh: the live themes changed during the capture (see $g/themes-moved.txt); start over" >&2
  exit 1
fi
rm -f "$g/themes-moved.txt"
if ! cmp -s "$g/before/GetRgbCapabilities.json" "$in/daemon/GetRgbCapabilities.json"; then
  echo "capture.sh: capabilities changed between reads; start over" >&2; exit 1
fi
fail=0
mkdir -p "$g/selfcheck"
for t in "${themes[@]}"; do
  rc=0
  frozen_run "$g" "$ref" render "$t" >"$g/selfcheck/$t.raw" 2>"$g/selfcheck/$t.err" || rc=$?
  unshadow <"$g/selfcheck/$t.raw" >"$g/selfcheck/$t.out"; rm -f "$g/selfcheck/$t.raw"
  if cmp -s "$g/selfcheck/$t.out" "$g/live/$t.out" && [[ $rc == "$(cat "$g/live/$t.rc")" ]]; then
    printf 'self-check ok   %-28s %s\n' "$t" "$(sha256sum <"$g/live/$t.out" | cut -c1-16)"
  else
    printf 'self-check FAIL %-28s rc %s vs %s\n' "$t" "$rc" "$(cat "$g/live/$t.rc")"; fail=1
  fi
done
(( fail == 0 )) || { echo "capture.sh: the frozen harness does not reproduce the live renders; start over" >&2; exit 1; }
(cd "$g" && sha256sum live/* probes/*.out probes/*.rc) >"$g/GOLDEN.sha256"
ln -sfn "$stamp" "$GOLDEN_ROOT/current"
echo "capture ok: $g (current -> $stamp)"
