#!/usr/bin/env bash
# tests/migrate/run.sh — pc-lights migrate (portability plan §6, WP5) on a
# fixture $HOME: never the real theme dir, the real profile or the hardware.
#
#   tests/migrate/run.sh [--engine PATH] [--themes-src DIR] [--profile FILE] [--golden] [-k]
#
# The fixture is a copy of the v2 theme folders (theme.json and src/source.json
# are real copies, the media are linked: cp -al on the same filesystem, cp -as
# across) plus a profile, and a stub file (PCL_TEST_OVERRIDES) that blocks
# the daemon, OpenRGB and units and fakes the USB serial map. The folders come
# from --themes-src, default the frozen snapshot ~/.cache/pc-lights/golden/v2/
# themes-v2: never the live theme dir, which is v3 since the cut-over
# (tests/golden/README.md).
#
#   default     the sanitised run: tests/fixtures/profile.example-desktop.json (fake
#               IDs) with its migrate-seeded fields reset to what detect
#               writes, and each theme's screen serials rewritten to the fake
#               ones by position (v2 screens[] order = profile role order), so
#               no real serial ever reaches a file in this repo
#   --profile   a profile with this machine's real IDs; the themes keep their
#               serials (the golden stage needs them)
#   --golden    plan §7 stage c: migrate --out <shadow>, then
#               tests/golden/run.sh --golden ~/.cache/pc-lights/golden/v2
#               --profile real --themes <shadow> must give 12/12 identical
#               renders (needs --profile with the real IDs)
#   -k          keep the fixture (PCL_TEST_ROOT sets where it goes; default a
#               mktemp dir, or for --golden one under ~/.cache/pc-lights: on
#               the theme dir's filesystem cp -al links the media, while
#               cp -as symlinks hide the clip folders' files from "find -type f")
# shellcheck disable=SC2016,SC2012,SC2035 # jq filters in single quotes; fixture names are plain
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# shellcheck source=../golden/lib.sh
source "$repo/tests/golden/lib.sh"

PCL=$repo/bin/pc-lights src='' profile='' golden='' keep=''
while (( $# )); do
  case $1 in
    --engine) PCL=$2; shift 2 ;;
    --themes-src) src=$2; shift 2 ;;
    --profile) profile=$(readlink -f "$2"); shift 2 ;;
    --golden) golden=1; shift ;;
    -k) keep=1; shift ;;
    *) sed -n '2,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
PCL=$(readlink -f "$PCL")
if [[ -z $src ]]; then src=$(golden_v2_themes) || exit 2; fi
[[ -x $PCL ]] || { echo "no engine at $PCL" >&2; exit 2; }
[[ -z $golden || -n $profile ]] || { echo "--golden needs --profile <profile with the real IDs>" >&2; exit 2; }
if [[ -n $golden ]]; then mkdir -p "$HOME/.cache/pc-lights"; fi
ROOT=${PCL_TEST_ROOT:-$(if [[ -n $golden ]]; then mktemp -d -p "$HOME/.cache/pc-lights" migrate-test.XXXXXX; else mktemp -d; fi)}
fx=$ROOT/migrate-fx-$$
C=$fx/.config/pc-lights T=$fx/.config/pc-lights/themes
stubs=$fx/stubs.sh
passed=0 failed=0
cleanup() {
  if [[ -z $keep ]]; then rm -rf "$fx"; if [[ -z ${PCL_TEST_ROOT:-} ]]; then rmdir "$ROOT" 2>/dev/null || true; fi; fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || printf '     %s\n' "${2:0:400}"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
jcheck() { if jq -e "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$(jq -c "$2" "$3" 2>&1 | head -c 300)"; fi; }
pcl() { HOME=$fx PCL_TEST_OVERRIDES=$stubs "$PCL" "$@"; }
# A fingerprint of every file migrate may touch (content + inode count).
state() { (cd "$C" && find . -path ./themes.pre-v3-\* -prune -o -type f \( -name theme.json -o -name source.json -o -name profile.json \) -print0 |
  sort -z | xargs -0 sha256sum); }

# ---- fixture -------------------------------------------------------------------
# build_fixture <dir>: themes from $src, profile, stubs.
build_fixture() {
  local d=$1 t f
  mkdir -p "$d/.config/pc-lights" "$d/.cache/pc-lights"
  cp -al "$src" "$d/.config/pc-lights/themes" 2>/dev/null || {
    rm -rf "$d/.config/pc-lights/themes"; cp -as "$(readlink -f "$src")" "$d/.config/pc-lights/themes"; }
  # The files migrate writes are real copies, never links to the real ones.
  for f in "$d"/.config/pc-lights/themes/*/theme.json "$d"/.config/pc-lights/themes/*/src/source.json; do
    [[ -e $f || -L $f ]] || continue
    t=${f#"$d"/.config/pc-lights/themes/}
    rm -f "$f"; cp -p "$(readlink -f "$src")/$t" "$f"
  done
  if [[ -n $profile ]]; then
    cp "$profile" "$d/.config/pc-lights/profile.json"
  else
    # What detect writes before migrate: mount 0, the model label, board.argb unsized.
    jq '.roles |= with_entries(if (.key | test("^screen\\.(fan[0-9]+|pump|main)$"))
          then .value |= (.mount = 0 | .label = "detect label" | .source = "detect" | .confidence = "guess") else . end)
        | .roles["board.argb"] |= (.argb.size = null | .source = "detect")' \
      "$repo/tests/fixtures/profile.example-desktop.json" >"$d/.config/pc-lights/profile.json"
    sanitise "$d/.config/pc-lights"
  fi
}
# Rewrite the themes' screen serials to the profile's fake ones, by position.
sanitise() {
  local c=$1 f first
  first=$(ls "$c"/themes/*/theme.json | head -1)
  jq -n --slurpfile p "$c/profile.json" --slurpfile t "$first" '
    [$p[0].roles | to_entries[] | select(.key | test("^screen\\.(fan[0-9]+|pump|main)$"))
     | {k: .key, s: ($p[0].devices[.value.device].match.usb_serial)}]
    | sort_by(.k | if startswith("screen.fan") then [0, (ltrimstr("screen.fan") | tonumber)] elif . == "screen.pump" then [1, 0] else [2, 0] end)
    | [., [$t[0].screens[].serial]] | transpose | map({(.[1]): .[0].s}) | add' >"$c/.serialmap.json"
  local old new s
  for f in "$c"/themes/*/theme.json; do
    old=$(sha256sum <"$f" | cut -d' ' -f1)
    jq --slurpfile m "$c/.serialmap.json" '.screens |= (if . then map(.serial = ($m[0][.serial] // ("unmapped-" + .serial))) else . end)' \
      "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    # auto-theme's own output stays its own: its source.json hash follows.
    s=${f%theme.json}src/source.json new=$(sha256sum <"$f" | cut -d' ' -f1)
    if [[ -f $s ]]; then sed -i "s/$old/$new/" "$s"; fi
  done
  rm -f "$c/.serialmap.json"
}
write_stubs() {
  cat >"$1" <<'STUBS'
# Sourced by pc-lights (PCL_TEST_OVERRIDES): no hardware, no daemon, no units.
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
openrgb() { echo "openrgb blocked in test" >&2; return 1; }
systemctl() { echo "blocked: systemctl $*" >>"$HOME/stub.log"; return 0; }
logger() { :; }
# The screens "on USB": every LCD in the profile, minus $HOME/usb-off (serials).
usb_serial_map() {
  jq --rawfile off <(cat "$HOME/usb-off" 2>/dev/null || true) '
    ($off | split("\n") | map(select(. != ""))) as $o
    | [.devices[] | select(.kind == "lcd") | .match.usb_serial | select(. as $s | $o | index($s) | not)
       | {(.): "hid:1cbe:0000:test"}] | add // {}' "$HOME/.config/pc-lights/profile.json" >"$TMP/usbmap.json"
  echo "$TMP/usbmap.json"
}
STUBS
}

build_fixture "$fx"
write_stubs "$stubs"
names=$(cd "$T" && ls -d */ | tr -d / | tr '\n' ' ')
n=$(wc -w <<<"$names")
echo "engine:  $PCL"
echo "fixture: $fx ($n themes, profile ${profile:-fixture (fake IDs)})"
orig=$fx/orig; mkdir -p "$orig"
for t in $names; do
  mkdir -p "$orig/$t"; cp -p "$T/$t/theme.json" "$orig/$t/"
  if [[ -f $T/$t/src/source.json ]]; then cp -p "$T/$t/src/source.json" "$orig/$t/"; fi
done
cp -p "$C/profile.json" "$orig/profile.json"

# ---- golden stage c ------------------------------------------------------------
if [[ -n $golden ]]; then
  shadow=$fx/shadow
  if pcl migrate --out "$shadow" >"$fx/out.log" 2>&1; then ok "migrate --out $shadow"; else bad "migrate --out" "$(tail -5 "$fx/out.log")"; fi
  check "--out left the fixture's themes alone" diff <(cd "$orig" && find . -name theme.json | sort | xargs sha256sum) \
    <(cd "$T" && find . -maxdepth 2 -name theme.json | sort | xargs sha256sum)
  jcheck "--out: every theme is v3" "all(.v == 3)" <(jq -s . "$shadow"/*/theme.json)
  if PCL_GOLDEN_PROFILE_FILE=$shadow/profile.json "$repo/tests/golden/run.sh" --engine "$PCL" --golden "$GOLDEN_V2" --profile real --themes "$shadow" >"$fx/golden.log" 2>&1; then
    ok "golden stage c: $(tail -1 "$fx/golden.log")"
  else
    bad "golden stage c" "$(grep -E 'FAIL|renders' "$fx/golden.log" | head -20 | tr '\n' ' ')"
  fi
  sed 's/^/  | /' "$fx/golden.log"
  echo "passed $passed, failed $failed"
  (( failed == 0 )); exit
fi

# ---- 1. refusals -----------------------------------------------------------------
before=$(state)
jq '.devices |= with_entries(select(.value.family != "TlFlexLcd"))
    | .roles |= with_entries(select(.key | startswith("screen.fan") | not))' "$orig/profile.json" >"$C/profile.json"
if pcl migrate >"$fx/r1.log" 2>&1; then bad "refuses: fan LCDs missing from the profile"; else
  check "refuses: fan LCDs missing from the profile" grep -q "is not a screen role in the profile" "$fx/r1.log"; fi
jq '.devices |= with_entries(if .value.family == "TlFlexLcd" then .value.present = false else . end)' "$orig/profile.json" >"$C/profile.json"
if pcl migrate >"$fx/r2.log" 2>&1; then bad "refuses: fan LCDs marked absent"; else
  check "refuses: fan LCDs marked absent" grep -q "marked absent in the profile" "$fx/r2.log"; fi
cp -p "$orig/profile.json" "$C/profile.json"
jq -r '.devices[] | select(.family == "TlFlexLcd") | .match.usb_serial' "$C/profile.json" >"$fx/usb-off"
if pcl migrate >"$fx/r3.log" 2>&1; then bad "refuses: fan LCDs off USB"; else
  check "refuses: fan LCDs off USB (5 named)" test "$(grep -c 'off USB: ' "$fx/r3.log")" = 5; fi
rm -f "$fx/usb-off"
mv "$C/profile.json" "$C/profile.json.away"
if pcl migrate >"$fx/r4.log" 2>&1; then bad "refuses: no profile"; else check "refuses: no profile" grep -q "no hardware profile" "$fx/r4.log"; fi
mv "$C/profile.json.away" "$C/profile.json"
check "refusals changed nothing" test "$before" == "$(state)"
check "refusals left no backup" test -z "$(ls -d "$C"/themes.pre-v3-* 2>/dev/null)"

# ---- 2. dry run --------------------------------------------------------------------
rc=0; pcl migrate --dry-run >"$fx/dry.log" 2>&1 || rc=$?
check "dry run: exit 0" test "$rc" = 0
check "dry run: $n would migrate, 0 failed" grep -q "dry run: $n theme(s) would migrate, 0 failed" "$fx/dry.log"
check "dry run: prints the profile and theme diffs" grep -q '^+++ sakura/theme.json (v3)' "$fx/dry.log"
check "dry run: changed nothing" test "$before" == "$(state)"
grep -o 'compile: [a-z.-]*' "$fx/dry.log" | tail -1 | sed 's/^/     identity checked with /'

# ---- 3. migrate --------------------------------------------------------------------
rc=0; pcl migrate >"$fx/m1.log" 2>&1 || rc=$?
check "migrate: exit 0" test "$rc" = 0
[[ $rc == 0 ]] || sed 's/^/     /' "$fx/m1.log" | head -30
jcheck "every theme is v3, stamped for the profile's machine" \
  "all(.v == 3 and .led.calibrated_for == \"$(jq -r .machine.name "$C/profile.json")\")" <(jq -s . "$T"/*/theme.json)
jcheck "profile seeded: mounts 180/180/180/0/0/0/0, labels from _where, source migrate" '
  .roles as $r | [range(1; 6) | $r["screen.fan\(.)"].mount] == [180, 180, 180, 0, 0]
  and $r["screen.pump"].mount == 0 and $r["screen.main"].mount == 0
  and $r["screen.fan1"].label == "3-fan group, screen 1 (rotated 180)" and $r["screen.main"].label == "8.8\" Universal Screen"
  and all($r | to_entries[] | select(.key | test("^screen\\.(fan[0-9]|pump|main)$")) | .value; .source == "migrate" and .confidence == "sure")
  and $r["board.argb"].argb == {zones: [0, 1, 2, 3], size: 120} and $r["board.argb"].source == "migrate"' "$C/profile.json"
jcheck "sakura is the plan §4 shape (no orientation, 5 fan entries, models, palette)" '
  (keys_unsorted | .[0:3]) == ["v", "_about", "_led_note"]
  and .palette == {primary: "ff4a9a", secondary: "ff1a70", accent: "ff3a8a", alert: "ff0000"}
  and .roles.fans == {inner: "ff4a9a", outer: "ff1a70", _note: "top = inner octagon edges (LEDs 0-12), bottom = outer bars (13-25)"}
  and (.roles | keys_unsorted) == ["fans", "strimers", "rings", "gpu", "board", "ram"]
  and (.screens | keys_unsorted) == ["screen.fan", "screen.pump", "screen.main"]
  and (.screens["screen.fan"] | length == 5 and all(.model == "TlFlexLcd" and has("orientation") == false and has("serial") == false and has("_where") == false))
  and [.screens["screen.fan"][].path] == ["media/fan-a.mp4", "media/fan-c.mp4", "media/fan-e.mp4", "media/fan-b.mp4", "media/fan-d.mp4"]
  and .screens["screen.pump"] == {type: "video", path: "media/pump.mp4", clips: ["media/pump"], rotate: 300, model: "HydroShift2OledCurveLcd"}
  and .screens["screen.main"] == {type: "custom", template_id: "us88-sakura", model: "UniversalScreen"}
  and .templates == ["us88/us88-sakura.template.json"] and .alert == {color: "ff0000"}' "$T/sakura/theme.json"
jcheck "stealth keeps its per-screen brightness" '[.screens["screen.fan"][].brightness] == [25, 25, 25, 25, 25]
  and .screens["screen.main"].brightness == 40' "$T/stealth/theme.json"
jcheck "matrix keeps its per-fan colour lists" '.roles.fans.inner == ["b4ffb4", "00ff41", "00c030"] and .palette.primary == "b4ffb4"' "$T/matrix/theme.json"
jcheck "cyberpunk (no alert) gets no alert and no palette.alert" '(has("alert") | not) and (.palette | has("alert") | not)' "$T/cyberpunk/theme.json"
# Every theme.json is a new inode (a hard-linked backup keeps the v2 bytes).
bk=$(ls -d "$C"/themes.pre-v3-* 2>/dev/null | head -1)
check "backup dir themes.pre-v3-<date> beside the theme dir" test -n "$bk" -a -f "$bk/.migrate.json"
okb=1
for t in $names; do cmp -s "$orig/$t/theme.json" "$bk/$t/theme.json" || okb=''; done
check "the backup holds every v2 theme.json byte-exact" test -n "$okb"
# The identity, checked again here with theme.jq's own projection when it is there.
if [[ -f $repo/lib/pc-lights/theme.jq ]]; then
  idok=1 idbad=''
  for t in $names; do
    if ! cmp -s <(jq -S -L "$repo/lib/pc-lights" --slurpfile p "$C/profile.json" --slurpfile m "$repo/lib/pc-lights/models.json" \
          'include "theme"; compile(.; $p[0]; $m[0]) | v2_projection($p[0])' "$T/$t/theme.json" 2>&1) \
        <(jq -S -L "$repo/lib/pc-lights" --slurpfile p "$C/profile.json" 'include "theme"; v2_projection($p[0])' "$orig/$t/theme.json" 2>&1); then
      idok='' idbad+=" $t"
    fi
  done
  check "theme.jq: compile(v3) | v2_projection == v2 | v2_projection for all $n${idbad:+ (failed:$idbad)}" test -n "$idok"
fi
# auto-theme's hash follows the new file; nothing else in source.json moves.
for t in $names; do
  [[ -f $T/$t/src/source.json ]] || continue
  if [[ $(jq -r .theme_json_sha256 "$orig/$t/source.json") == "$(sha256sum <"$orig/$t/theme.json" | cut -d' ' -f1)" ]]; then
    check "$t: source.json theme_json_sha256 = sha256(new theme.json)" \
      test "$(jq -r .theme_json_sha256 "$T/$t/src/source.json")" = "$(sha256sum <"$T/$t/theme.json" | cut -d' ' -f1)"
    check "$t: source.json otherwise byte-identical (one line changed)" \
      test "$(diff "$orig/$t/source.json" "$T/$t/src/source.json" | grep -c '^[<>]')" = 2
  else
    check "$t: source.json (hand-edited theme) untouched" cmp -s "$orig/$t/source.json" "$T/$t/src/source.json"
  fi
done
# A hand-edited auto-theme (hash no longer its own) keeps its source.json.
fx4=$fx/edited; build_fixture "$fx4"; write_stubs "$fx4/stubs.sh"
at=$(cd "$T" && grep -l theme_json_sha256 */src/source.json 2>/dev/null | head -1 | cut -d/ -f1)
if [[ -n $at ]]; then
  jq '._edited = true' "$fx4/.config/pc-lights/themes/$at/theme.json" >"$fx4/x" && mv "$fx4/x" "$fx4/.config/pc-lights/themes/$at/theme.json"
  cp -p "$fx4/.config/pc-lights/themes/$at/src/source.json" "$fx4/source.before"
  HOME=$fx4 PCL_TEST_OVERRIDES=$fx4/stubs.sh "$PCL" migrate --only "$at" >"$fx/e.log" 2>&1 || true
  check "$at hand-edited: migrated, source.json untouched" \
    test "$(jq .v "$fx4/.config/pc-lights/themes/$at/theme.json")" = 3 -a -z "$(cmp "$fx4/source.before" "$fx4/.config/pc-lights/themes/$at/src/source.json" 2>&1)"
fi
first=$(state)

# ---- 4. a second run is a no-op ------------------------------------------------------
rc=0; pcl migrate >"$fx/m2.log" 2>&1 || rc=$?
check "second run: exit 0, nothing to migrate" grep -q "nothing to migrate ($n theme(s) already v3)" "$fx/m2.log"
check "second run: changed nothing" test "$first" == "$(state)"

# ---- 5. rollback, byte-exact -------------------------------------------------------
rc=0; pcl migrate --rollback >"$fx/rb.log" 2>&1 || rc=$?
check "rollback: exit 0" test "$rc" = 0
okr=1
for t in $names; do
  cmp -s "$orig/$t/theme.json" "$T/$t/theme.json" || okr=''
  if [[ -f $orig/$t/source.json ]]; then cmp -s "$orig/$t/source.json" "$T/$t/src/source.json" || okr=''; fi
done
check "rollback: every theme.json and source.json byte-exact" test -n "$okr"
rc=0; pcl migrate --rollback >"$fx/rb2.log" 2>&1 || rc=$?
check "rollback twice: exit 0, already v2" test "$rc" = 0 -a "$(grep -c 'already v2' "$fx/rb2.log")" = "$n"

# ---- 6. migrate again: the same bytes ----------------------------------------------
pcl migrate >"$fx/m3.log" 2>&1 || true
check "re-migrate after rollback gives the same files" test "$first" == "$(state)"
# An edited v3 theme is never rolled back over.
jq '.roles.rings = "123456"' "$T/sakura/theme.json" >"$T/sakura/theme.json.x" && mv "$T/sakura/theme.json.x" "$T/sakura/theme.json"
rc=0; pcl migrate --rollback >"$fx/rb3.log" 2>&1 || rc=$?
check "rollback: an edited v3 theme is left alone (exit 1, others restored)" \
  test "$rc" = 1 -a "$(jq .v "$T/sakura/theme.json")" = 3 -a "$(jq '.v // 2' "$T/toxic/theme.json")" = 2

# ---- 7. --only -----------------------------------------------------------------------
fx2=$fx/only; build_fixture "$fx2"; write_stubs "$fx2/stubs.sh"
HOME=$fx2 PCL_TEST_OVERRIDES=$fx2/stubs.sh "$PCL" migrate --only sakura stealth >"$fx/o.log" 2>&1 || true
check "--only sakura stealth: just those two are v3" test "$(jq -r '.v // 2' "$fx2"/.config/pc-lights/themes/*/theme.json | sort | uniq -c | tr -s ' ' | xargs)" = "$((n - 2)) 2 2 3"
if HOME=$fx2 PCL_TEST_OVERRIDES=$fx2/stubs.sh "$PCL" migrate --only nosuchtheme >"$fx/o2.log" 2>&1; then
  bad "--only unknown theme refuses"; else check "--only unknown theme refuses" grep -q "no theme" "$fx/o2.log"; fi

# ---- 8. --out --------------------------------------------------------------------------
fx3=$fx/out; build_fixture "$fx3"; write_stubs "$fx3/stubs.sh"
before3=$(cd "$fx3/.config/pc-lights" && find . -name theme.json -o -name profile.json | sort | xargs sha256sum)
HOME=$fx3 PCL_TEST_OVERRIDES=$fx3/stubs.sh "$PCL" migrate --out "$fx3/shadow" >"$fx/out.log" 2>&1 || true
check "--out: the shadow copy is v3, with profile.json" test "$(jq -r .v "$fx3"/shadow/*/theme.json | sort -u)" = 3 -a -f "$fx3/shadow/profile.json"
check "--out: the fixture's themes and profile untouched" test "$before3" == "$(cd "$fx3/.config/pc-lights" && find . -name theme.json -o -name profile.json | sort | xargs sha256sum)"

echo "passed $passed, failed $failed"
(( failed == 0 ))
