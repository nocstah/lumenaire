#!/usr/bin/env bash
# run.sh — tests for "pc-lights detect" and "pc-lights profile" (plan §6, §14.4, §14.6).
#
#   tests/detect/run.sh [--engine PATH] [--golden DIR] [--write-golden] [--update-expected] [-v]
#
# Every run is against a fixture $HOME and frozen inputs (tests/detect/overrides.sh
# through the engine's PCL_TEST_OVERRIDES hook): nothing reads the live
# daemon, sysfs or OpenRGB, and nothing writes outside the fixture.
#
#   golden    this machine, from the golden capture's inputs (default
#             ~/.cache/pc-lights/golden/current; ../golden/README.md). The detected profile is
#             compared in substance with the plan's §3 example
#             (tests/fixtures/profile.example-desktop.json) after the real serials
#             and MACs are mapped to the fake ones, and exactly with
#             expected/example-desktop.sanitised.json. Then: idempotence, a manual
#             role edit and a hand edit surviving a re-detect, removed devices
#             kept with present:false, fan LCDs off USB, --probe under the
#             lock, --no-openrgb, the daemon down, profile set/show/prune.
#   a, b, c   the other-machine simulations of §14.6 (fixtures/): OpenRGB
#             only with Intel coretemp and an amdgpu dGPU; SL-INF fans with a
#             round HydroShift LCD pump and no Strimers; nothing at all.
#             Each must equal expected/<name>.json and be idempotent.
#
#   --write-golden     also write <golden>/profile.json for tests/golden/run.sh
#                      --profile real: the detected profile plus what this
#                      machine sets by hand (board.argb size 120, and the §3
#                      calibration imported from tests/fixtures/profile.example-desktop.json)
#   --update-expected  rewrite expected/*.json from this run (review the diff)
# shellcheck disable=SC2016  # jq programs and sh -c bodies are single-quoted on purpose
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
engine=$repo/bin/pc-lights g=$HOME/.cache/pc-lights/golden/current write_golden='' update='' verbose=''
while (( $# )); do
  case $1 in
    --engine) engine=$2; shift 2 ;;
    --golden) g=$2; shift 2 ;;
    --write-golden) write_golden=1; shift ;;
    --update-expected) update=1; shift ;;
    -v) verbose=1; shift ;;
    *) sed -n '2,/^set -euo/{/^# shellcheck/d;/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
engine=$(readlink -f "$engine")
g=$(readlink -f "$g")
GI=$g/inputs
[[ -x $engine ]] || { echo "run.sh: no engine at $engine" >&2; exit 2; }
[[ -f $GI/daemon/ListDevices.json ]] || { echo "run.sh: no golden inputs at $GI" >&2; exit 2; }

real_home=$HOME
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The real OpenRGB must never run from a test (it probes the SMBus): any
# call that gets past the overrides (timeout, env, a subshell) hits this.
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "tests/detect: blocked: openrgb $*" >&2\necho blocked >>"$HOME/openrgb-real-calls.log"\nexit 99\n' >"$work/bin/openrgb"
chmod +x "$work/bin/openrgb"
export PATH=$work/bin:$PATH
passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | head -40 | sed 's/^/     /'; fi; }
# jcheck <name> <jq filter> <file> [jq args...]: pass when jq -e holds.
jcheck() {
  local n=$1 f=$2 file=$3; shift 3
  if jq -e "$@" "$f" "$file" >/dev/null 2>&1; then ok "$n"; else bad "$n" "$(jq -c "$@" "$f" "$file" 2>&1 | head -c 600)"; fi
}
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# fxhome <name> <inputs>: a fresh fixture HOME, with the cached OpenRGB listing
# the inputs have (as the last apply would have left it).
fxhome() {
  local h=$work/$1
  rm -rf "$h"; mkdir -p "$h/.cache/pc-lights" "$h/.config/pc-lights"
  if [[ -f $2/openrgb-list.txt ]]; then cp "$2/openrgb-list.txt" "$h/.cache/pc-lights/openrgb-list.txt"; fi
  echo "$h"
}
# det <home> <inputs> <args...>: the engine against a fixture.
det() {
  local h=$1 fx=$2; shift 2
  HOME=$h PCL_REAL_HOME=$real_home PCL_DETECT_FX=$fx PCL_TEST_OVERRIDES=$here/overrides.sh "$engine" "$@"
}
prof() { echo "$1/.config/pc-lights/profile.json"; }
sha() { sha256sum <"$1" | cut -c1-16; }

echo "engine: $engine ($(sha256sum <"$engine" | cut -c1-16))"
echo "golden: $g"

# ---- golden: this machine ---------------------------------------------------------------
echo "== golden (this machine, frozen inputs)"
H=$(fxhome golden "$GI")
P=$(prof "$H")
if det "$H" "$GI" detect >"$work/g1.out" 2>"$work/g1.err"; then ok "detect exits 0"; else bad "detect exits 0" "$(cat "$work/g1.err")"; fi
check "profile written" test -s "$P"
check "last detection written" test -s "$H/.config/pc-lights/.profile.detected.json"
jcheck "last-run records op detect, rc 0" '.op == "detect" and .rc == 0' "$H/.cache/pc-lights/last-run.json"
check "no busy.json left" test ! -e "$H/.cache/pc-lights/busy.json"
check "cached listing used (no OpenRGB probe)" test ! -e "$H/openrgb-probes.log"
cp "$P" "$work/golden.first.json"

# The fake IDs of the handoff, by role: the real ones never reach the repo.
jq '[(.roles as $r
      | [["fans.side", "02:00:00:00:01:01"], ["fans.bottom", "02:00:00:00:01:02"], ["fans.top", "02:00:00:00:01:03"],
         ["strimer.atx24", "02:00:00:00:02:01"], ["strimer.gpu", "02:00:00:00:02:02"]][]
      | {from: ($r[.[0]].device | ltrimstr("lianli:mac:")), to: .[1]}),
     (.roles as $r | range(1; 6) | {from: ($r["screen.fan\(.)"].device | ltrimstr("lianli:lcd:")), to: "f1f1f1f10000000\(.)"}),
     {from: (.roles["screen.pump"].device | ltrimstr("lianli:lcd:")), to: "a1a1a1a100000006"},
     {from: (.roles["screen.main"].device | ltrimstr("lianli:lcd:")), to: "b8b8b8b800000007"},
     {from: (.roles["pump.ring"].device | ltrimstr("lianli:serial:")), to: "0000c0ffee"}]' "$P" >"$work/idmap.json"
sanitise() {
  jq --slurpfile m "$work/idmap.json" '
    def san: reduce $m[0][] as $x (.; if type == "string" then gsub($x.from; $x.to) else . end);
    walk(if type == "object" then with_entries(.key |= san) elif type == "string" then san else . end)' "$1"
}
sanitise "$P" >"$work/golden.sanitised.json"
leak=$(jq -r '.[].from' "$work/idmap.json" | while read -r id; do grep -c -- "$id" "$work/golden.sanitised.json" || true; done | awk '{ n += $1 } END { print n + 0 }')
if [[ $leak == 0 ]]; then ok "sanitised profile holds no real serial or MAC"; else bad "sanitised profile holds no real serial or MAC" "$leak hits"; fi
# Substance: the §3 example's devices (every field it gives), the role
# bindings and their parameters, the sensors, screens, workarounds and
# backend states. Not compared: labels, source/confidence (the example's
# screen roles are migrate's), board.argb.size (checked on its own below:
# detect reads it from sizes.ors), calibration (never written by detect).
jq -n --slurpfile got "$work/golden.sanitised.json" --slurpfile want "$repo/tests/fixtures/profile.example-desktop.json" '
  $got[0] as $g | $want[0] as $w
  | def sub($a; $b): if ($b | type) == "object" and ($a | type) == "object"
                     then [$b | keys[] as $k | {($k): sub($a[$k]; $b[$k])}] | add // {} else $a end;
    def rolep: del(.label, .source, .confidence) | if .argb then .argb |= del(.size) else . end;
  [ (if ($g.devices | keys) == ($w.devices | keys) then empty else {devices_keys: {extra: (($g.devices | keys) - ($w.devices | keys)), missing: (($w.devices | keys) - ($g.devices | keys))}} end),
    ($w.devices | to_entries[] | select(sub($g.devices[.key]; .value) != .value) | {device: .key, got: sub($g.devices[.key]; .value), want: .value}),
    (if ($g.roles | keys) == ($w.roles | keys) then empty else {roles_keys: {extra: (($g.roles | keys) - ($w.roles | keys)), missing: (($w.roles | keys) - ($g.roles | keys))}} end),
    ($w.roles | to_entries[] | select(($g.roles[.key] // {} | rolep) != (.value | rolep)) | {role: .key, got: ($g.roles[.key] | rolep), want: (.value | rolep)}),
    ($w.sensors | to_entries[] | select(sub($g.sensors[.key]; .value) != .value) | {sensor: .key, got: $g.sensors[.key], want: .value}),
    (if $g.screens != $w.screens then {screens: $g.screens} else empty end),
    ($w.workarounds | to_entries[] | select(($g.workarounds[.key] | {present, needed}) != (.value | {present, needed})) | {workaround: .key, got: $g.workarounds[.key]}),
    ($w.backends | to_entries[] | select($g.backends[.key].state != .value.state) | {backend: .key, got: $g.backends[.key]}),
    (if $g.machine.name != $w.machine.name then {machine: $g.machine} else empty end)
  ]' >"$work/substance.json"
if jq -e 'length == 0' "$work/substance.json" >/dev/null; then ok "matches the plan §3 example in substance (21 devices, 20 roles, sensors, workarounds)"
else bad "matches the plan §3 example in substance" "$(jq -c '.[]' "$work/substance.json")"; fi
jcheck "mounts reproduce today's orientations (fans 1-3: 180, 4-5: 0, pump and 8.8\": 0 + model 90)" '
  [.roles["screen.fan1", "screen.fan2", "screen.fan3", "screen.fan4", "screen.fan5", "screen.pump", "screen.main"].mount] == [180, 180, 180, 0, 0, 0, 0]' "$P"
jcheck "board.argb: zones 0-3, size 120 from OpenRGB's sizes.ors (source openrgb, sure)" '.roles["board.argb"] | .argb == {zones: [0, 1, 2, 3], size: 120}
  and .source == "openrgb" and .confidence == "sure"' "$P"
jcheck "gpu: 30 LEDs, aura layout; ram: 8 per stick" '.roles.gpu.leds == 30 and .roles.gpu.layout == "aura" and .roles.ram.leds_per_device == 8' "$P"
if [[ -n $update ]]; then cp "$work/golden.sanitised.json" "$here/expected/example-desktop.sanitised.json"; fi
if diff <(jq -S . "$here/expected/example-desktop.sanitised.json") <(jq -S . "$work/golden.sanitised.json") >"$work/g.diff"; then
  ok "sanitised profile equals expected/example-desktop.sanitised.json"
else bad "sanitised profile equals expected/example-desktop.sanitised.json" "$(cat "$work/g.diff")"; fi

# Idempotent: a second run changes nothing, and a dry run shows no diff.
s1=$(sha "$P")
det "$H" "$GI" detect >"$work/g2.out" 2>&1 || true
if [[ $(sha "$P") == "$s1" ]] && grep -q "profile unchanged" "$work/g2.out"; then ok "idempotent: a second detect leaves the profile byte-identical"
else bad "idempotent: a second detect leaves the profile byte-identical" "$(cat "$work/g2.out")"; fi
det "$H" "$GI" detect --dry-run >"$work/g3.out" 2>&1 || true
if grep -qx "dry run: no change" "$work/g3.out"; then ok "dry run: no diff"; else bad "dry run: no diff" "$(cat "$work/g3.out")"; fi
det "$H" "$GI" detect --json >"$work/g4.json" 2>/dev/null || true
jcheck "--json summary" '.v == 1 and .changed == false and .written == false and .devices == 21 and (.roles | length) == 20
  and .screens == 7 and .openrgb_listing == "cache" and .conflicts == [] and .profile.v == 1' "$work/g4.json"

# The ARGB size comes from OpenRGB's saved sizes (sizes.ors), never a guess:
# no file, an unreadable one, or headers of different sizes leave it null;
# a new size in OpenRGB follows; a user or migrate value wins over it.
# orsset <in> <out> <n1> <n2> <n3> <n4>: sizes.ors with ARGB_V2_1..4 resized.
orsset() {
  python3 - "$@" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
for z, n in zip(range(1, 5), sys.argv[3:7]):
    name = b'ARGB_V2_%d\0' % z
    o = d.index(name) + len(name) + 4 + 4 + 4       # zone type, min, max
    struct.pack_into('<I', d, o, int(n))
open(sys.argv[2], 'wb').write(d)
PY
}
S=$work/inputs-sizes; cp -r "$GI" "$S"
HS=$(fxhome sizes "$S"); PS=$(prof "$HS")
rm -f "$S/sizes.ors"
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "no sizes.ors: board.argb size null (detect, guess)" '.roles["board.argb"] | .argb == {zones: [0, 1, 2, 3], size: null}
  and .source == "detect" and .confidence == "guess"' "$PS"
printf 'OPENRGB_PROFILE\0\005\0\0\0\377\377' >"$S/sizes.ors"
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "a truncated sizes.ors: size null" '.roles["board.argb"].argb.size == null' "$PS"
orsset "$GI/sizes.ors" "$S/sizes.ors" 120 120 60 120
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "headers of different sizes: size null" '.roles["board.argb"].argb.size == null and .roles["board.argb"].source == "detect"' "$PS"
orsset "$GI/sizes.ors" "$S/sizes.ors" 60 60 60 60
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "all four resized to 60: size 60, source openrgb" '.roles["board.argb"] | .argb.size == 60 and .source == "openrgb" and .confidence == "sure"' "$PS"
cp "$GI/sizes.ors" "$S/sizes.ors"
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "resized back in OpenRGB: detect follows (120)" '.roles["board.argb"].argb.size == 120' "$PS"
det "$HS" "$S" detect --no-openrgb >/dev/null 2>&1 || true
jcheck "--no-openrgb keeps the size" '.roles["board.argb"].argb.size == 120 and .roles["board.argb"].source == "openrgb"' "$PS"
det "$HS" "$S" profile set board.argb --argb-size 90 >/dev/null 2>&1 || true
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "a user size wins over OpenRGB's" '.roles["board.argb"] | .argb.size == 90 and .source == "user"' "$PS"
jq '.roles["board.argb"] |= (.argb.size = 100 | .source = "migrate")' "$PS" >"$work/ps.json" && mv "$work/ps.json" "$PS"
orsset "$GI/sizes.ors" "$S/sizes.ors" 60 60 60 60
det "$HS" "$S" detect >/dev/null 2>&1 || true
jcheck "a migrate size wins over OpenRGB's" '.roles["board.argb"] | .argb.size == 100 and .source == "migrate"' "$PS"
H4=$(fxhome sizes-hand "$GI"); P4=$(prof "$H4")
det "$H4" "$GI" detect >/dev/null 2>&1 || true
jq '.roles["board.argb"].argb.size = 144' "$P4" >"$work/p4.json" && mv "$work/p4.json" "$P4"
det "$H4" "$GI" detect >/dev/null 2>&1 || true
jcheck "a hand edit of OpenRGB's size is kept, now source user" '.roles["board.argb"] | .argb.size == 144 and .source == "user"' "$P4"

# A manual role edit survives a re-detect (profile set), and so does a hand
# edit of the file (it becomes source "user").
side=$(jq -r '.roles["fans.side"].device' "$P") bottom=$(jq -r '.roles["fans.bottom"].device' "$P")
det "$H" "$GI" profile set fans.side "$bottom" --label "Right 3-fan LCD column" >/dev/null 2>"$work/set.err" || bad "profile set" "$(cat "$work/set.err")"
jq '.roles["fans.top"].label = "Top 2-fan LCD row"' "$P" >"$work/p.json" && mv "$work/p.json" "$P"
det "$H" "$GI" detect >"$work/g5.out" 2>&1 || true
jcheck "manual fans.side edit kept (source user)" '.roles["fans.side"] == {device: $b, label: "Right 3-fan LCD column", source: "user", confidence: "sure"}' "$P" --arg b "$bottom"
jcheck "hand-edited fans.top kept, now source user" '.roles["fans.top"].label == "Top 2-fan LCD row" and .roles["fans.top"].source == "user"' "$P"
if grep -q "kept your roles.fans.side" "$work/g5.out"; then ok "the kept edit is reported as a conflict"; else bad "the kept edit is reported as a conflict" "$(cat "$work/g5.out")"; fi
s2=$(sha "$P")
det "$H" "$GI" detect >/dev/null 2>&1 || true
if [[ $(sha "$P") == "$s2" ]]; then ok "idempotent with user edits"; else bad "idempotent with user edits"; fi
det "$H" "$GI" profile set fans.side "$side" --label "3-fan LCD group" >/dev/null 2>&1 || true
det "$H" "$GI" detect >/dev/null 2>&1 || true
s3=$(sha "$P")

# Removing devices: the GPU Strimer and the last fan LCD vanish from
# ListDevices and sysfs. They stay with present:false, their roles hold, and
# the screen numbering does not shift.
R=$work/inputs-removed; cp -r "$GI" "$R"
gstrim=$(jq -r '.roles["strimer.gpu"].device | ltrimstr("lianli:mac:")' "$P")
lcd5=$(jq -r '.roles["screen.fan5"].device | ltrimstr("lianli:lcd:")' "$P")
fan4=$(jq -r '.roles["screen.fan4"].device' "$P")
jq --arg m "$gstrim" --arg s "$lcd5" '.data |= map(select(.serial != $m and .serial != $s))' "$GI/daemon/ListDevices.json" >"$R/daemon/ListDevices.json"
awk -F'\t' -v s="$lcd5" '$4 != s' "$GI/sysfs-usb.tsv" >"$R/sysfs-usb.tsv"
det "$H" "$R" detect >"$work/g6.out" 2>&1 || bad "detect with devices removed" "$(cat "$work/g6.out")"
jcheck "removed devices kept with present:false" '.devices["lianli:mac:\($m)"].present == false and .devices["lianli:lcd:\($s)"].present == false
  and ([.devices[] | select(.present == false)] | length) == 2' "$P" --arg m "$gstrim" --arg s "$lcd5"
jcheck "their roles survive, numbering holds" '.roles["strimer.gpu"].device == "lianli:mac:\($m)" and .roles["screen.fan5"].device == "lianli:lcd:\($s)"
  and .roles["screen.fan4"].device == $f4 and .screens.expected == 7' "$P" --arg m "$gstrim" --arg s "$lcd5" --arg f4 "$fan4"
if grep -q "missing (kept with present:false)" "$work/g6.out"; then ok "detect reports the missing devices"; else bad "detect reports the missing devices" "$(cat "$work/g6.out")"; fi
det "$H" "$GI" detect >/dev/null 2>&1 || true
jcheck "back on USB: present again" '[.devices[] | select(.present == false)] | length == 0' "$P"
if [[ $(sha "$P") == "$s3" ]]; then ok "back to the same profile once the devices return"; else bad "back to the same profile once the devices return"; fi

# --no-openrgb keeps the OpenRGB devices as they were; the daemon down keeps
# the Lian Li ones (state "down"), roles untouched either way.
det "$H" "$GI" detect --no-openrgb >/dev/null 2>&1 || true
jcheck "--no-openrgb: OpenRGB devices and roles kept" '([.devices[] | select(.backend == "openrgb" and .present)] | length) == 5
  and .roles.gpu != null and .roles.ram != null and .backends.openrgb.state == "unknown"' "$P"
D=$work/inputs-down; cp -r "$GI" "$D"; rm -rf "$D/daemon"
det "$H" "$D" detect >/dev/null 2>&1 || true
jcheck "daemon down: Lian Li devices kept present, state down" '([.devices[] | select(.backend == "lianli" and .present)] | length) == 16
  and .backends.lianli.state == "down" and .backends.lianli.version == "1.1.2" and (.roles | length) == 20' "$P"
det "$H" "$GI" detect >/dev/null 2>&1 || true
jcheck "full detect again restores the states" '.backends.lianli.state == "ok" and .backends.openrgb.state == "ok"' "$P"

# profile show / set / prune
if det "$H" "$GI" profile show >"$work/show.out" 2>&1 && grep -q '^roles:' "$work/show.out" && grep -q 'fans.side' "$work/show.out"; then
  ok "profile show"; else bad "profile show" "$(cat "$work/show.out")"; fi
check "profile show --json is the profile" cmp -s <(det "$H" "$GI" profile show --json) <(jq . "$P")
check "profile set rejects an unknown role" bash -c '! "$@"' _ det "$H" "$GI" profile set fans-side "$side"
if ! det "$H" "$GI" profile set gpu lianli:mac:00:00:00:00:00:00 >/dev/null 2>&1; then ok "profile set rejects an unknown device"; else bad "profile set rejects an unknown device"; fi
det "$H" "$GI" profile set mouse --managed on >/dev/null 2>&1 || true
jcheck "profile set --managed on" '.roles.mouse.managed == true and .roles.mouse.source == "user"' "$P"
det "$H" "$GI" profile set screen.fan1 --mount 90 --lock >/dev/null 2>&1 || true
jcheck "profile set --mount/--lock" '.roles["screen.fan1"].mount == 90 and .roles["screen.fan1"].locked == true' "$P"
# A backend the user switched off stays off across a re-detect (jq's // must
# never turn that false into the default true).
det "$H" "$GI" profile backend openrgb off >/dev/null 2>&1 || true
det "$H" "$GI" detect >/dev/null 2>&1 || true
jcheck "profile backend openrgb off survives a re-detect" '.backends.openrgb.enabled == false and .backends.lianli.enabled == true' "$P"
det "$H" "$GI" profile backend openrgb on >/dev/null 2>&1 || true
det "$H" "$GI" detect >/dev/null 2>&1 || true
jcheck "profile backend openrgb on again" '.backends.openrgb.enabled == true' "$P"
# The §8 detect verbs are the same scanners: be_lianli_detect/be_openrgb_detect
# write the {backend, state, version, devices} shape detect itself uses.
BD=$work/be-detect; mkdir -p "$BD"
printf 'be_lianli_detect "%s"; be_openrgb_detect "%s"; exit 0\n' "$BD" "$BD" >"$work/be-detect.sh"
HOME=$H PCL_REAL_HOME=$real_home PCL_DETECT_FX=$GI PCL_TEST_OVERRIDES=$work/be-over.sh \
  bash -c 'cat "$1" "$2" >"$3"; "$4" status >/dev/null' _ "$here/overrides.sh" "$work/be-detect.sh" "$work/be-over.sh" "$engine" 2>/dev/null || true
jcheck "be_lianli_detect: the §8 shape, the same devices detect found" '.backend == "lianli" and .state == "ok" and .version == "1.1.2"
  and (.devices | length) == 16' "$BD/lianli.json"
jcheck "be_openrgb_detect: the §8 shape from the cached listing" '.backend == "openrgb" and .state == "ok" and (.devices | length) == 5
  and .listing == "cache"' "$BD/openrgb.json"
det "$H" "$R" detect >/dev/null 2>&1 || true
det "$H" "$R" profile prune >/dev/null 2>&1 || true
jcheck "profile prune forgets missing devices and their roles" '([.devices[] | select(.present == false)] | length) == 0
  and .roles["strimer.gpu"] == null and .roles["screen.fan5"] == null and (.devices | length) == 19' "$P"

# The fan LCDs off USB on a first detect (the case migrate must refuse):
# no screen.fan roles, but the daemon config still counts 7 screens.
O=$work/inputs-offusb; cp -r "$GI" "$O"
jq '.data |= map(select(.family != "TlFlexLcd"))' "$GI/daemon/ListDevices.json" >"$O/daemon/ListDevices.json"
awk -F'\t' '!($2 == "1cbe" && $3 == "a018")' "$GI/sysfs-usb.tsv" >"$O/sysfs-usb.tsv"
H2=$(fxhome offusb "$O")
det "$H2" "$O" detect >/dev/null 2>&1 || true
jcheck "fan LCDs off USB: no screen.fan roles, expected still 7" '([.roles | keys[] | select(startswith("screen.fan"))] | length) == 0
  and .screens.expected == 7 and .roles["screen.pump"] != null' "$(prof "$H2")"

# No cached listing: detect probes OpenRGB once, under the lock, and caches
# the listing; --probe probes again.
H3=$(fxhome probe "$GI"); rm -f "$H3/.cache/pc-lights/openrgb-list.txt"
det "$H3" "$GI" detect >/dev/null 2>&1 || true
if [[ $(cat "$H3/openrgb-probes.log" 2>/dev/null) == locked ]]; then ok "no cache: one probe, with the lock held"; else bad "no cache: one probe, with the lock held" "$(cat "$H3/openrgb-probes.log" 2>/dev/null)"; fi
check "the probe's listing is cached" cmp -s "$H3/.cache/pc-lights/openrgb-list.txt" "$GI/openrgb-list.txt"
det "$H3" "$GI" detect >/dev/null 2>&1 || true
det "$H3" "$GI" detect --probe >/dev/null 2>&1 || true
if [[ $(wc -l <"$H3/openrgb-probes.log") == 2 ]]; then ok "cache reused; --probe probes again"; else bad "cache reused; --probe probes again"; fi
check "probed profile equals the cached one" cmp -s "$(prof "$H3")" "$work/golden.first.json"

# ---- the golden profile for tests/golden/run.sh --profile real ----------------------------
if [[ -n $write_golden ]]; then
  HG=$(fxhome write-golden "$GI")
  det "$HG" "$GI" detect >/dev/null
  det "$HG" "$GI" profile set board.argb --argb-size 120 >/dev/null
  det "$HG" "$GI" profile calibration import "$repo/tests/fixtures/profile.example-desktop.json" >/dev/null
  jq . "$(prof "$HG")" >"$g/profile.json.tmp" && mv -f "$g/profile.json.tmp" "$g/profile.json"
  echo "wrote $g/profile.json ($(sha "$g/profile.json"))"
fi

check "the real openrgb was never called" bash -c '! compgen -G "$1/*/openrgb-real-calls.log" >/dev/null' _ "$work"

# ---- other machines (§14.6) -------------------------------------------------------------------
for fx in "$here"/fixtures/*/; do
  name=$(basename "$fx"); fx=${fx%/}
  echo "== $name"
  Hx=$(fxhome "m-$name" "$fx"); Px=$(prof "$Hx")
  if det "$Hx" "$fx" detect >"$work/$name.out" 2>&1; then ok "$name: detect exits 0"; else bad "$name: detect exits 0" "$(cat "$work/$name.out")"; fi
  if [[ -n $update ]]; then jq . "$Px" >"$here/expected/$name.json"; fi
  if diff <(jq -S . "$here/expected/$name.json") <(jq -S . "$Px") >"$work/$name.diff" 2>&1; then ok "$name: equals expected/$name.json"
  else bad "$name: equals expected/$name.json" "$(cat "$work/$name.diff")"; fi
  s=$(sha "$Px"); det "$Hx" "$fx" detect >/dev/null 2>&1 || true
  if [[ $(sha "$Px") == "$s" ]]; then ok "$name: idempotent"; else bad "$name: idempotent"; fi
  check "$name: profile show" det "$Hx" "$fx" profile show
  if [[ -n $verbose ]]; then sed 's/^/     /' "$work/$name.out"; fi
done
PA=$(prof "$work/m-a-openrgb-intel") PB=$(prof "$work/m-b-slinf-round-pump") PC=$(prof "$work/m-c-nothing")
jcheck "a: lianli absent, OpenRGB ok" '.backends.lianli.state == "absent" and .backends.openrgb.state == "ok"' "$PA"
jcheck "a: coretemp Package id 0, amdgpu dGPU with its PCI address, jc42 x2" '.sensors.cpu == {kind: "hwmon", driver: "coretemp", input: "temp1_input", label: "Package id 0", scale: 0.001}
  and .sensors.gpu.driver == "amdgpu" and .sensors.gpu.integrated == false and .sensors.gpu.pci == "0000:03:00.0"
  and .sensors.gpu_integrated == null and .sensors.ram.count == 2 and .sensors.coolant == null' "$PA"
jcheck "a: board + addressable headers (size null), linear GPU, 2 DRAM x 10, keyboard/ledstrip unmanaged" '
  .roles["board.argb"].argb == {zones: [1, 2, 3], size: null} and .roles.gpu.layout == "linear" and .roles.gpu.leds == 4
  and .roles.ram.leds_per_device == 10 and (.roles.ram.devices | length) == 2 and .roles.keyboard.managed == false
  and .roles["ledstrip.1"].managed == false' "$PA"
jcheck "a: the Lian Li hub OpenRGB sees is ignored, never bound" '.roles.ignore.devices == ["openrgb:Lian Li Uni Hub - SL Infinity#0"]
  and .devices["openrgb:Lian Li Uni Hub - SL Infinity#0"].kind == "duplicate"' "$PA"
jcheck "a: GPU location unwrapped, Razer-style trailing spaces trimmed" '.devices["openrgb:Corsair Vengeance Pro RGB#1"].match.location == "I2C: SMBus I801 adapter at efa0, address 0x59"' "$PA"
jcheck "a: workarounds are OpenRGB-only, lax not needed on Intel" '(.workarounds | keys) == ["openrgb.lianli_detectors_off", "openrgb.smbus_lax"]
  and .workarounds["openrgb.smbus_lax"].needed == false and .workarounds["openrgb.lianli_detectors_off"].needed == false' "$PA"
jcheck "b: SL-INF groups (no LCDs: bottom, then fans.1), no Strimers" '.roles["fans.bottom"].device == "lianli:mac:02:00:00:00:03:02"
  and .roles["fans.1"].device == "lianli:mac:02:00:00:00:03:01" and ([.roles | keys[] | select(startswith("strimer"))] | length) == 0
  and .devices["lianli:mac:02:00:00:00:03:01"].regions == ["outer"]' "$PB"
jcheck "b: the round HydroShift LCD is screen.pump (mount 0) and its ring pump.ring" '.roles["screen.pump"].device == "lianli:lcd:d0d0d0d000000001"
  and .roles["screen.pump"].mount == 0 and .roles["pump.ring"].device == "lianli:serial:d0d0d0d000000001" and .screens.expected == 1
  and .devices["lianli:lcd:d0d0d0d000000001"].panel == [480, 480]' "$PB"
jcheck "b: zenpower Tdie, NVIDIA via nvidia-smi, coolant from the AIO, OpenRGB absent" '.sensors.cpu.driver == "zenpower" and .sensors.cpu.label == "Tdie"
  and .sensors.gpu == {kind: "nvidia-smi", index: 0, name: "NVIDIA GeForce RTX 4070"} and .sensors.coolant.device == "lianli:serial:d0d0d0d000000001"
  and .backends.openrgb.state == "absent" and .workarounds["lianli.wake_fan_lcds"].needed == false' "$PB"
jcheck "c: nothing at all" '.backends.lianli.state == "absent" and .backends.openrgb.state == "absent" and .devices == {} and .roles == {}
  and .sensors == {} and .workarounds == {} and .screens.expected == 0' "$PC"
# No CPU hwmon at all but the Intel package thermal zone: the last CPU fallback.
TZ=$work/inputs-tz; cp -r "$here/fixtures/c-nothing" "$TZ"
printf 'thermal_zone3\ttype\tx86_pkg_temp\n' >>"$TZ/hwmon.tsv"
Htz=$(fxhome tz "$TZ"); det "$Htz" "$TZ" detect >/dev/null 2>&1 || true
jcheck "c + x86_pkg_temp zone: cpu from the thermal zone" '.sensors.cpu == {kind: "thermal_zone", type: "x86_pkg_temp", scale: 0.001}' "$(prof "$Htz")"

echo "passed $passed, failed $failed"
(( failed == 0 ))
