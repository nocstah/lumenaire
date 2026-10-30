#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# engine-contract.sh — contract v1 tests for the pc-lights engine that
# Lumenaire fronts: run bookkeeping (busy.json, last-run.json, pending/),
# --detach and its exit codes, pick coalescing, clips next --nowait,
# pause/resume, status --json and themes --json, and contract v1.1:
# sensors --json, the profile/labels/coverage fields, --detach detect and a
# v3 theme without a profile (portability plan §9, §14 step 3), and contract
# v1.2: the theme preview (editor plan §1.5-§1.7, tests/preview/checks.sh,
# in its own fixture: session lifecycle, the yields on pick/on/off/
# apply-openrgb, the schedule deferral, the clip skip, the reaper, the
# unmeasured refusal, the request shapes per device type, status/themes v1.2),
# and the screens (screens plan: theme screens and media, v1.3's media field,
# the preview's screens part and the on/off screens yields, in section 9).
#
#   tests/engine-contract.sh [engine]   (or PCL=<engine>; default ~/.local/bin/pc-lights)
#
# It runs the real engine against a fixture $HOME: the pc-lights state files
# and the Lian Li config of the migration-era golden capture, the Omarchy
# theme name, and its frozen v2 theme folders linked in (cp -al on the same
# filesystem, cp -as across): ~/.cache/pc-lights/golden/v2/{inputs,themes-v2}
# (tests/golden/README.md), never the live state or theme dir, which is v3
# since the cut-over and needs a profile the fixture does not have. The
# engine's test hook (PCL_TEST_OVERRIDES) sources a stub file that replaces
# lianli_lights, lianli_screens, apply_openrgb and swap_clip with a log line
# and a sleep, and blocks the daemon socket, OpenRGB and unit stops, so
# nothing here touches the lights, the screens, the daemon or a real
# pc-lights lock. Detached runs are real transient units
# (pc-lights-ui-<op>-<ns>) running the fixture; the test stops any it left.
# PCL_TEST_ROOT sets where the fixture goes (default: a mktemp dir).
set -euo pipefail

PCL=$(readlink -f "${1:-${PCL:-$HOME/.local/bin/pc-lights}}")
[[ -x $PCL ]] || { echo "no engine at $PCL" >&2; exit 2; }
# shellcheck source=golden/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/golden/lib.sh"
V2T=$(golden_v2_themes) || exit 2
V2I=$(readlink -f "$GOLDEN_V2/inputs")
ROOT=${PCL_TEST_ROOT:-$(mktemp -d)}
fx=$ROOT/fx-$$
C=$fx/.config/pc-lights
K=$fx/.cache/pc-lights
stubs=$fx/stubs.sh
t_start=$EPOCHSECONDS
passed=0 failed=0
units=() bg=()

cleanup() {
  local p u
  for p in "${bg[@]}"; do kill -9 -- "-$p" 2>/dev/null || kill -9 "$p" 2>/dev/null || true; done
  for u in "${units[@]}"; do systemctl --user stop "$u.service" 2>/dev/null || true; done
  if [[ -z ${KEEP_FIXTURE:-} ]]; then rm -rf "$fx"; fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || printf '     %s\n' "$2"; }
# check <name> <cmd...>: pass when the command succeeds.
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
# jcheck <name> <jq filter> <json>: pass when jq -e holds.
jcheck() {
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then ok "$1"; else bad "$1" "$(jq -c "$2" <<<"$3" 2>&1 | head -c 300)"; fi
}

pcl() { HOME=$fx PCL_TEST_OVERRIDES=$stubs "$PCL" "$@"; }
sj() { pcl status --json; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# wait_for <seconds> <cmd...>: poll every 0.1 s until the command succeeds.
wait_for() {
  local end=$(( $(now_ms) + $1 * 1000 )); shift
  until "$@" >/dev/null 2>&1; do
    (( $(now_ms) < end )) || return 1
    sleep 0.1
  done
}
unit_live() { systemctl --user is-active -q "$1.service" 2>/dev/null; }
units_gone() { local u; for u in "$@"; do ! unit_live "$u" || return 1; done; }
hm() { date -d "@$(( EPOCHSECONDS + $1 ))" +%H:%M; }
# Day: the night window starts in 2 h. Night: it started 2 h ago.
sched_day() { printf '{"enabled":true,"night_theme":"stealth","night_start":"%s","night_end":"%s"}\n' "$(hm 7200)" "$(hm 10800)" >"$C/schedule.json"; }
sched_night() { printf '{"enabled":true,"night_theme":"stealth","night_start":"%s","night_end":"%s"}\n' "$(hm -7200)" "$(hm 7200)" >"$C/schedule.json"; }
stub_sleep() { echo "$1" >"$fx/stub-sleep"; }
claims() { grep -c " $1" "$fx/claims.log" 2>/dev/null || true; }

# ---- fixture -----------------------------------------------------------------
mkdir -p "$C" "$K" "$fx/.config/lianli" "$fx/.local/state/omarchy/current"
for f in scheme day-scheme lights screens alerts.json omarchy-map.json; do
  if [[ -f $V2I/state/$f ]]; then cp "$V2I/state/$f" "$C/$f"; fi
done
cp -al "$V2T" "$C/themes" 2>/dev/null || {
  rm -rf "$C/themes"; cp -as "$V2T" "$C/themes"; }
chmod u+w "$C/themes"
cp "$V2I/lianli/config.json" "$fx/.config/lianli/config.json"
echo sakura >"$fx/.local/state/omarchy/current/theme.name"
echo sakura >"$C/scheme"; echo sakura >"$C/day-scheme"; echo on >"$C/lights"; echo on >"$C/screens"
rm -f "$C/clips"
sched_day
# A theme that fails validation, for the die case.
mkdir -p "$C/themes/broken"
jq '.fans.top = "not-a-colour"' "$V2T/sakura/theme.json" >"$C/themes/broken/theme.json"
stub_sleep 0

cat >"$stubs" <<'STUBS'
# Sourced by pc-lights (PCL_TEST_OVERRIDES): no hardware, no daemon, no units.
stub() {
  printf '%s %s %s\n' "$EPOCHSECONDS" "${PCL_UNIT:-cli}" "$*" >>"$HOME/stub.log"
  sleep "$(cat "$HOME/stub-sleep" 2>/dev/null || echo 2)"
}
lianli_lights() { stub "lianli_lights $*"; }
lianli_screens() { stub "lianli_screens $*"; }
apply_openrgb() { stub apply_openrgb; }
swap_clip() { stub "swap_clip $*"; }
detect_cmd() { stub "detect $*"; }
# Belt and braces: nothing reaches the daemon, OpenRGB or a real unit.
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
openrgb() { echo "openrgb blocked in test" >&2; return 1; }
systemctl() {
  case " $* " in
    *" is-active "* | *" list-units "*) command systemctl "$@" ;;
    *) echo "blocked: systemctl $*" >>"$HOME/stub.log"; return 0 ;;
  esac
}
# Tag the fixture's journal lines and count claims.
eval "real_$(declare -f log)"
log() { real_log "[test] $*"; }
eval "real_$(declare -f claim_run)"
claim_run() { echo "${PCL_UNIT:-cli} $*" >>"$HOME/claims.log"; real_claim_run "$@"; }
STUBS

echo "engine: $PCL"
echo "fixture: $fx"

# ---- 0. the stubs are live (abort before any unit starts if not) -------------
pcl on lights >/dev/null 2>&1 || true
if ! grep -q 'cli lianli_lights on' "$fx/stub.log" 2>/dev/null || ! grep -q 'cli apply_openrgb' "$fx/stub.log"; then
  echo "ABORT: the stub file was not sourced; refusing to run anything that could reach the hardware" >&2
  exit 1
fi
ok "stubs replace the hardware calls"
lr=$(cat "$K/last-run.json" 2>/dev/null || echo null)
jcheck "on lights: last-run rc 0, op on, target lights" '.v == 1 and .rc == 0 and .op == "on" and .target == "lights" and .error == null and .fallback == false and .missed_devices == []' "$lr"
check "on lights: busy.json removed at exit" test ! -e "$K/busy.json"

# ---- 1. status --json / themes --json in several states ----------------------
s=$(sj)
jcheck "status: normal" '.v == 1 and .theme == "sakura" and .day_theme == "sakura" and .lights == "on"
  and .screens_show == "sakura" and .busy == null and .pending == [] and (.daemon_unit | type == "string")
  and .schedule.enabled and .schedule.period == "day" and .schedule.override == false
  and .omarchy.current == "sakura" and .omarchy.paired and (.rotation | type == "array")
  and .screens_on_usb.want == 7 and (.previews_building | type == "boolean")' "$s"
n=$(find "$C/themes" -mindepth 2 -maxdepth 2 -name theme.json | wc -l)
tj=$(pcl themes --json)
jcheck "themes: one entry per theme ($n), colours and swatches" "length == $n and all(.[]; (.name | type == \"string\")
  and (.swatch | length > 0 and length <= 6 and all(test(\"^#[0-9a-f]{6}$\")))
  and (.colors | type == \"object\") and (.preview_stale | type == \"boolean\"))
  and ([.[] | .auto] == ([.[] | .auto] | sort)) and ([.[] | select(.active)] | length == 1)" "$tj"

jcheck "themes: an invalid colour is left out of the lists" '.[] | select(.name == "broken") | .colors.fans_top == [] and (.colors.fans_bottom | length) == 1' "$tj"
rm -f "$K/busy.json" "$K/last-run.json" "$K/ui-requested" "$K"/pending/*.json
jcheck "status: no bookkeeping files" '.busy == null and .last_run == null and .pending == [] and .ui_requested == null' "$(sj)"

echo off >"$C/lights"; echo hellfire >"$C/scheme"
jcheck "status: lights off, screens still show the old theme" '.lights == "off" and .theme == "hellfire" and .screens_show == "sakura"' "$(sj)"
echo on >"$C/lights"; echo sakura >"$C/scheme"

sched_night
jcheck "status: night override" '.schedule.period == "night" and .schedule.override == true and .schedule.night_theme == "stealth"' "$(sj)"
sched_day

cp "$fx/.config/lianli/config.json" "$fx/config.full"
head -c 700 "$fx/config.full" >"$fx/.config/lianli/config.json"
echo '{"theme": "sak' >"$K/clips.json"
rc=0; out=$(sj) || rc=$?
jcheck "status: truncated config.json/clips.json give null sections, rc $rc" '.alert == null and .screens_show == null and .clips.paused_at == null and (.rotation | type == "array")' "$out"
cp "$fx/config.full" "$fx/.config/lianli/config.json"; rm -f "$K/clips.json"
jcheck "themes: still valid" 'type == "array" and length > 0' "$(pcl themes --json)"

# ---- 2. lock independence, clips next --nowait -------------------------------
setsid flock "$K/lock" sleep 30 & bg+=($!); disown
wait_for 5 bash -c "! flock -n '$K/lock' true"
t0=$(now_ms); out=$(sj); t1=$(now_ms)
if (( t1 - t0 < 300 )) && jq -e .v >/dev/null <<<"$out"; then ok "status --json with the lock held: $((t1 - t0)) ms"; else bad "status --json with the lock held: $((t1 - t0)) ms"; fi
t0=$(now_ms); rc=0; pcl clips next --nowait >/dev/null 2>&1 || rc=$?; t1=$(now_ms)
if (( rc == 75 && t1 - t0 < 100 )); then ok "clips next --nowait with the lock held: exit 75 in $((t1 - t0)) ms"
else bad "clips next --nowait with the lock held: exit $rc in $((t1 - t0)) ms"; fi
kill -9 -- "-${bg[-1]}" 2>/dev/null || true

# A run killed with SIGKILL leaves busy.json behind; readers ignore it.
stub_sleep 30
setsid bash -c "HOME='$fx' PCL_TEST_OVERRIDES='$stubs' '$PCL' on lights" >/dev/null 2>&1 & bg+=($!); disown
wait_for 10 jq -e '.op == "on"' "$K/busy.json" || true
jcheck "status: busy while a run holds the lock" '.busy.op == "on" and .busy.target == "lights" and .busy.step == "lian li"' "$(sj)"
kill -9 -- "-${bg[-1]}" 2>/dev/null || true
wait_for 5 bash -c "flock -n '$K/lock' true" || true
check "SIGKILL leaves a stale busy.json" test -e "$K/busy.json"
jcheck "status: stale busy.json (dead pid) reads as busy null" '.busy == null' "$(sj)"
stub_sleep 0

# ---- 3. --detach validation --------------------------------------------------
before=$(systemctl --user list-units --all --plain --no-legend 'pc-lights-ui-*' | wc -l)
rc=0; out=$(pcl --detach pick nosuch 2>/dev/null) || rc=$?
after=$(systemctl --user list-units --all --plain --no-legend 'pc-lights-ui-*' | wc -l)
if (( rc == 2 )) && jq -e '.error | type == "string"' >/dev/null <<<"$out" && (( before == after )) &&
   [[ -z $(find "$K/pending" -name '*.json') ]]; then ok "--detach pick nosuch: exit 2, {\"error\"}, no unit, no pending"
else bad "--detach pick nosuch: exit $rc, out $out, units $before -> $after"; fi
rc=0; out=$(pcl --detach pick broken 2>/dev/null) || rc=$?
if (( rc == 2 )) && jq -e '.error | test("invalid")' >/dev/null <<<"$out"; then ok "--detach pick <invalid theme>: exit 2 with the verdict"; else bad "--detach pick broken: exit $rc $out"; fi
rc=0; out=$(pcl --detach on nowhere 2>/dev/null) || rc=$?
if (( rc == 2 )) && jq -e .error >/dev/null <<<"$out"; then ok "--detach on <bad target>: exit 2"; else bad "--detach on nowhere: exit $rc"; fi
for args in "clips next" "switch sakura" "status" "schedule tick"; do
  read -ra argv <<<"$args"
  rc=0; out=$(pcl --detach "${argv[@]}" 2>/dev/null) || rc=$?
  if (( rc == 2 )) && jq -e '.error | startswith("usage")' >/dev/null <<<"$out"; then ok "--detach $args: usage, exit 2"; else bad "--detach $args: exit $rc $out"; fi
done

# ---- 4. three rapid picks: the last one wins ---------------------------------
: >"$fx/claims.log"
setsid flock "$K/lock" sleep 60 & bg+=($!); disown; holder=${bg[-1]}
wait_for 5 bash -c "! flock -n '$K/lock' true"
picks=(abyss arctic cyberpunk) punits=()
for t in "${picks[@]}"; do
  rc=0; out=$(pcl --detach pick "$t" 2>/dev/null) || rc=$?
  if (( rc == 0 )) && jq -e '.queued == true' >/dev/null <<<"$out"; then
    u=$(jq -r .unit <<<"$out"); punits+=("$u"); units+=("$u")
  else bad "--detach pick $t: exit $rc $out"; fi
done
(( ${#punits[@]} == 3 )) && ok "--detach pick x3: queued, exit 0"
s=$(sj)
jcheck "status: three pending picks while the lock is held" '(.pending | length) == 3 and all(.pending[]; .source == "ui" and .op == "pick" and .due == null) and .ui_requested == "cyberpunk"' "$s"
jcheck "status: ui_requested_ns is the last pick's ns" ".ui_requested_ns == \"${punits[2]##*-}\"" "$s"
kill -9 -- "-$holder" 2>/dev/null || true
if wait_for 40 units_gone "${punits[@]}"; then ok "picks finished"; else bad "picks still running after 40 s"; fi
c=$(claims 'pick ')
if [[ $c == 1 ]] && grep -q "${punits[2]} pick  cyberpunk" "$fx/claims.log"; then ok "exactly one pick claimed (the last)"; else bad "pick claims: $c" "$(cat "$fx/claims.log")"; fi
sup=$(journalctl --user -t pc-lights --since "@$t_start" -o cat --no-pager 2>/dev/null | grep -E '^\[test\] pick: (abyss|arctic) superseded$' | sort -u | wc -l)
if (( sup == 2 )); then ok "journal: two picks superseded"; else bad "journal: $sup superseded picks"; fi
lr=$(cat "$K/last-run.json")
jcheck "last-run: pick cyberpunk rc 0 in its unit" ".op == \"pick\" and .theme == \"cyberpunk\" and .rc == 0 and .unit == \"${punits[2]}\" and .error == null and .skipped == false" "$lr"
check "pick: scheme and day-scheme are cyberpunk" bash -c "[[ \$(cat '$C/scheme') == cyberpunk && \$(cat '$C/day-scheme') == cyberpunk ]]"
check "pick: pending/ empty, busy.json gone" bash -c "[[ -z \$(find '$K/pending' -name '*.json') && ! -e '$K/busy.json' ]]"

# ---- 4b. a pick whose systemd-run fails leaves the queued one in charge ------
: >"$fx/claims.log"
mkdir -p "$fx/fakebin"
printf '#!/bin/sh\necho "fake systemd-run: refusing" >&2\nexit 1\n' >"$fx/fakebin/systemd-run"; chmod +x "$fx/fakebin/systemd-run"
setsid flock "$K/lock" sleep 60 & bg+=($!); disown; holder=${bg[-1]}
wait_for 5 bash -c "! flock -n '$K/lock' true"
out=$(pcl --detach pick abyss 2>/dev/null); u=$(jq -r .unit <<<"$out"); units+=("$u")
rc=0; out=$(PATH=$fx/fakebin:$PATH pcl --detach pick arctic 2>/dev/null) || rc=$?
if (( rc == 3 )) && jq -e .error >/dev/null <<<"$out"; then ok "--detach pick with a failing systemd-run: exit 3"; else bad "failing systemd-run: exit $rc $out"; fi
check "exit 3: ui-requested still names the queued pick" bash -c "[[ \$(cat '$K/ui-requested') == 'abyss ${u##*-}' ]]"
kill -9 -- "-$holder" 2>/dev/null || true
wait_for 40 units_gone "$u" || true
jcheck "exit 3: the queued pick still applied" ".op == \"pick\" and .theme == \"abyss\" and .unit == \"$u\" and .rc == 0" "$(cat "$K/last-run.json")"

# ---- 5. last-run.json: die, SIGTERM, night skip ------------------------------
rc=0; pcl switch broken >/dev/null 2>&1 || rc=$?
jcheck "last-run: die (exit $rc) keeps the error" '.op == "switch" and .theme == "broken" and .rc == 1 and (.error | test("invalid"))' "$(cat "$K/last-run.json")"

stub_sleep 30
out=$(pcl --detach on lights 2>/dev/null); u=$(jq -r .unit <<<"$out"); units+=("$u")
# shellcheck disable=SC2016 # jq variables
if wait_for 10 jq -e --arg u "$u" '.unit == $u and .step == "lian li"' "$K/busy.json"; then ok "busy.json: the detached run, step \"lian li\""; else bad "busy.json never showed $u"; fi
jcheck "status: busy carries the unit and step" ".busy.unit == \"$u\" and .busy.op == \"on\" and .busy.step == \"lian li\" and (.busy.since | type == \"number\")" "$(sj)"
systemctl --user kill "$u.service"
wait_for 10 units_gone "$u" || true
jcheck "last-run: SIGTERM gives rc 143" ".unit == \"$u\" and .rc == 143 and .op == \"on\" and (.error | test(\"SIGTERM\"))" "$(cat "$K/last-run.json")"
check "SIGTERM: busy.json and pending entry removed" bash -c "[[ ! -e '$K/busy.json' && ! -e '$K/pending/$u.json' ]]"
stub_sleep 0

sched_night
rc=0; pcl switch abyss >/dev/null 2>&1 || rc=$?
jcheck "last-run: night switch is skipped (exit $rc)" '.op == "switch" and .theme == "abyss" and .rc == 0 and .skipped == true and (.error | startswith("night: kept"))' "$(cat "$K/last-run.json")"
sched_day

# ---- 5b. a fired Omarchy switch drops out behind a newer request -------------
: >"$fx/claims.log"
echo gruvbox >"$K/omarchy-requested"
PCL_SLUG=sakura PCL_ASKED=$(date +%s%N) pcl switch abyss >/dev/null 2>&1 || true
check "switch: Omarchy moved on, no claim" test ! -s "$fx/claims.log"
echo sakura >"$K/omarchy-requested"
asked=$(date +%s%N); echo "arctic $(date +%s%N)" >"$K/ui-requested"
PCL_SLUG=sakura PCL_ASKED=$asked pcl switch abyss >/dev/null 2>&1 || true
check "switch: a later UI pick wins, no claim" test ! -s "$fx/claims.log"
sup=$(journalctl --user -t pc-lights --since "@$t_start" -o cat --no-pager 2>/dev/null | grep -cE '^\[test\] switch: abyss superseded' || true)
if (( sup == 2 )); then ok "journal: two switches superseded"; else bad "journal: $sup superseded switches"; fi
PCL_SLUG=sakura PCL_ASKED=$(date +%s%N) pcl switch cyberpunk >/dev/null 2>&1 || true
jcheck "switch: newer than the last pick, it applies" '.op == "switch" and .theme == "cyberpunk" and .rc == 0 and .skipped == false' "$(cat "$K/last-run.json")"
rm -f "$K/omarchy-requested"

# ---- 6. schedule tick: quiet unless it acts ----------------------------------
jq -r '.schedule | "\(.last_boundary) \(.period)"' <<<"$(sj)" >"$K/schedule-boundary"
sum=$(sha256sum "$K/last-run.json"); cl=$(wc -l <"$fx/claims.log")
pcl schedule tick >/dev/null 2>&1
if [[ $(sha256sum "$K/last-run.json") == "$sum" && $(wc -l <"$fx/claims.log") == "$cl" && ! -e $K/busy.json ]]; then
  ok "no-op schedule tick writes nothing"; else bad "no-op schedule tick wrote bookkeeping"; fi
rm -f "$K/schedule-boundary"
pcl schedule tick >/dev/null 2>&1
jcheck "schedule tick at a boundary claims a run" '.op == "schedule-tick" and .rc == 0' "$(cat "$K/last-run.json")"

# ---- 7. clips next --nowait, pause/resume ------------------------------------
# A theme with a real two-clip folder (the linked themes may be symlinks,
# which the rotation's folder scan skips).
mkdir -p "$C/themes/rotor/media/pump"
: >"$C/themes/rotor/media/pump/a.mp4"; : >"$C/themes/rotor/media/pump/b.mp4"
echo '{"screens":[{"serial":"a1a1a1a100000006","_where":"pump","type":"video","path":"media/pump/a.mp4","orientation":90,"clips":["media/pump"],"rotate":300}]}' >"$C/themes/rotor/theme.json"
echo rotor >"$C/scheme"
now=$EPOCHSECONDS
jq -n --arg t "$(cat "$C/scheme")" --argjson now "$now" \
  '{theme: $t, since: ($now - 100), screens: {"a1a1a1a100000006": {index: 0, since: ($now - 50), clip: "x/pump.mp4"}}}' >"$K/clips.json"
rc=0; pcl clips next --nowait >/dev/null 2>&1 || rc=$?
jcheck "clips next --nowait: exit $rc, claims clips-next" ".op == \"clips-next\" and .rc == 0 and $rc == 0" "$(cat "$K/last-run.json")"
check "clips next: the stub swap ran" grep -q 'cli swap_clip a1a1a1a100000006' "$fx/stub.log"
jq -n --arg t "$(cat "$C/scheme")" --argjson now "$now" \
  '{theme: $t, since: ($now - 100), screens: {"a1a1a1a100000006": {index: 1, since: ($now - 50), clip: "x/pump-2.mp4"}}}' >"$K/clips.json"
pcl clips pause >/dev/null
s1=$(sj)
jcheck "pause: clips off, paused_at set, rotation paused" '.clips.state == "off" and (.clips.paused_at | type == "number") and all(.rotation[]; .paused)' "$s1"
sleep 2
s2=$(sj)
n1=$(jq -c '[.rotation[].next_in]' <<<"$s1") n2=$(jq -c '[.rotation[].next_in]' <<<"$s2")
if [[ $n1 == "$n2" && $n1 != "[]" ]]; then ok "pause: countdown frozen at $n1"; else bad "pause: countdown $n1 -> $n2"; fi
swaps=$(grep -c swap_clip "$fx/stub.log" || true)
rc=0; pcl clips next --nowait >/dev/null 2>&1 || rc=$?
jcheck "clips next while paused: skipped with the reason, exit $rc" ".op == \"clips-next\" and .rc == 0 and .skipped == true and .error == \"clips are paused\" and $rc == 0" "$(cat "$K/last-run.json")"
if [[ $(grep -c swap_clip "$fx/stub.log" || true) == "$swaps" ]]; then ok "clips next while paused: no swap"; else bad "clips next while paused swapped a clip"; fi
sleep 8
pcl clips resume >/dev/null
jcheck "resume: since shifted by >= 10 s, paused_at gone" "(.since - ($now - 100)) >= 10 and (.screens[\"a1a1a1a100000006\"].since - ($now - 50)) >= 10 and (has(\"paused_at\") | not)" "$(cat "$K/clips.json")"
jcheck "resume: clips on" '.clips.state == "on" and .clips.paused_at == null' "$(sj)"

# ---- 8. contract v1.1: sensors, profile, coverage, detect, v3 -----------------
# No profile yet: v stays 1, v_minor 1 or later (v1.2 is additive), the profile block says "missing" and
# every new field is there with an empty value.
echo sakura >"$C/scheme"; rm -f "$K/clips.json"
s=$(sj)
jcheck "v1.1 status, no profile: v 1, v_minor >= 1, profile missing, want from config" '.v == 1 and .v_minor >= 1
  and .profile.state == "missing" and .profile.backends == {} and .profile.new_devices == [] and .profile.groups == []
  and .profile.pump_device == null and .labels == {} and .screens_on_usb.want == 7' "$s"
tj=$(pcl themes --json)
jcheck "v1.1 themes, no profile: schema 2, palette null, coverage null" 'all(.[]; .schema == 2 and .palette == null and .coverage == null)' "$tj"
echo '{"v": 2, "devices": "not a profile"}' >"$C/profile.json"
jcheck "v1.1 status, bad profile: invalid, still exit 0" '.profile.state == "invalid" and .v == 1' "$(sj)"

# The sanitised profile (fake MACs and serials): the real config's device ids
# are not in it, so it reads as stale, and the v2 themes, whose screen serials
# are the real ones, as made for another PC.
cp "$(dirname "$(readlink -f "$0")")/fixtures/profile.example-desktop.json" "$C/profile.json"
s=$(sj)
jcheck "v1.1 status, profile: machine, backends, sensors, groups, pump, labels" '.v == 1 and .v_minor >= 1
  and (.profile.state | IN("ok", "stale")) and .profile.machine == "example-desktop" and .profile.screens == 7
  and .profile.backends.lianli.state == "ok" and .profile.backends.lianli.devices == 14
  and .profile.backends.openrgb.devices == 5 and .profile.missing_devices == []
  and .profile.sensors.cpu == "k10temp" and .profile.sensors.gpu == "nvidia-smi"
  and .profile.pump_device == "hid:0416:8051:8-7.2.3"
  and .profile.groups == ["fans", "strimers", "rings", "gpu", "board", "ram"]
  and .labels["wireless:02:00:00:00:01:01"] == "Right 3-fan LCD column"
  and .labels["hid:1cbe:a068:8-7.2.2"] == "HydroShift II OLED Curve pump" and .screens_on_usb.want == 7' "$s"
jcheck "v1.1 status, profile: stale lists the unmatched daemon ids" '.profile.state == "stale"
  and (.profile.new_devices | length) > 0 and all(.profile.new_devices[]; startswith("wireless:"))' "$s"
# "lights off" writes an Off entry for every device, the wired receivers
# included; detect marks those as duplicates, and they must still count as known
# (2026-09-25: they were reported as new devices, so the profile read "stale").
cp "$fx/.config/lianli/config.json" "$fx/config.pre-dup"
jq '.rgb.devices += [{device_id: "hid:43a8:0102:8-12.2.4", zones: [{zone_index: 0, effect: {mode: "Off", colors: [[0,0,0]]}}]}]' \
  "$fx/config.pre-dup" >"$fx/.config/lianli/config.json"
jcheck "v1.1 status: a duplicate device in the config is not a new device" \
  'all(.profile.new_devices[]; startswith("hid:43a8:") | not)' "$(sj)"
cp "$fx/config.pre-dup" "$fx/.config/lianli/config.json"
jq '.screens.expected = 5 | .devices["lianli:lcd:f1f1f1f100000005"].present = false' \
  "$C/profile.json" >"$C/profile.tmp" && mv "$C/profile.tmp" "$C/profile.json"
s=$(sj)
jcheck "v1.1 status: want from profile.screens.expected, missing_devices" '.screens_on_usb.want == 5
  and .profile.missing_devices == ["lianli:lcd:f1f1f1f100000005"]' "$s"
line=$(pcl status 2>/dev/null | grep '^screens on USB:' || true)
if [[ $line =~ ^screens\ on\ USB:\ [0-9]+\ of\ 5$ ]]; then ok "v1.1 text status: \"$line\""; else bad "v1.1 text status: \"$line\""; fi
cp "$(dirname "$(readlink -f "$0")")/fixtures/profile.example-desktop.json" "$C/profile.json"
tj=$(pcl themes --json)
jcheck "v1.1 themes, profile: schema and coverage on every theme" 'all(.[]; (.schema | IN(2, 3))
  and (.coverage.summary | IN("full", "partial", "leds-only", "foreign")) and (.coverage.roles | type == "object")
  and (.coverage.counts.total | type == "number") and (.coverage.missing | type == "array"))' "$tj"
jcheck "v1.1 themes: sakura (real serials) is foreign to the fake profile, LEDs still covered" '.[] | select(.name == "sakura")
  | .coverage.summary == "foreign" and .coverage.roles["fans.side"] == "group" and .coverage.roles["screen.pump"] == "none"
  and .coverage.roles.mouse == "unmanaged"' "$tj"

# A palette-only v3 theme: compiled against the profile, colours derived.
mkdir -p "$C/themes/v3demo"
echo '{"v": 3, "_about": "palette only", "palette": {"primary": "00ffd0", "secondary": "0050ff"}}' >"$C/themes/v3demo/theme.json"
tj=$(pcl themes --json)
jcheck "v1.1 themes: a v3 theme has schema 3, its palette, derived colours and coverage" '.[] | select(.name == "v3demo")
  | .schema == 3 and .palette.primary == "00ffd0" and .colors.fans_top == ["#00ffd0"] and .colors.fans_bottom == ["#0050ff"]
  and (.swatch | length) > 0 and .coverage.counts.palette > 0 and .coverage.summary == "leds-only"' "$tj"
check "v1.1: the compiled EFF is cached" compgen -G "$K/compiled/v3demo.*.json"

# sensors --json on this machine (read-only), then on fixture sysfs trees.
out=$(pcl sensors --json)
jcheck "v1.1 sensors: shape (profile sources resolved to files)" '.v == 1 and .source == "profile"
  and (.cpu == null or (.cpu.kind == "hwmon" and (.cpu.scale | type == "number") and (.cpu.available | type == "boolean")))
  and (.gpu == null or (.gpu.kind == "nvidia-smi" and (.gpu.cmd | type == "array")) or .gpu.kind == "hwmon")
  and (.gpus | type == "array") and (.ram | type == "array")
  and .coolant.device_id == "hid:0416:8051:8-7.2.3" and .pump.field == "fan_rpms"' "$out"
# Another PC: Intel coretemp, an amdgpu dGPU (boot VGA, 16 GiB), jc42 RAM, no NVIDIA.
T=$fx/sysfs
mkdir -p "$T/sys/class/hwmon"/hwmon{0,1,2,3} "$T/sys/devices/pci/0000:03:00.0" "$T/proc"
echo coretemp >"$T/sys/class/hwmon/hwmon0/name"
echo 45000 >"$T/sys/class/hwmon/hwmon0/temp1_input"; echo 'Package id 0' >"$T/sys/class/hwmon/hwmon0/temp1_label"
echo 44000 >"$T/sys/class/hwmon/hwmon0/temp2_input"; echo 'Core 0' >"$T/sys/class/hwmon/hwmon0/temp2_label"
echo amdgpu >"$T/sys/class/hwmon/hwmon1/name"; ln -s "$T/sys/devices/pci/0000:03:00.0" "$T/sys/class/hwmon/hwmon1/device"
echo 1 >"$T/sys/devices/pci/0000:03:00.0/boot_vga"; echo 17179869184 >"$T/sys/devices/pci/0000:03:00.0/mem_info_vram_total"
echo 51000 >"$T/sys/class/hwmon/hwmon1/temp1_input"; echo edge >"$T/sys/class/hwmon/hwmon1/temp1_label"
echo jc42 >"$T/sys/class/hwmon/hwmon2/name"; echo 38000 >"$T/sys/class/hwmon/hwmon2/temp1_input"
echo nvme >"$T/sys/class/hwmon/hwmon3/name"; echo 40000 >"$T/sys/class/hwmon/hwmon3/temp1_input"
{ echo "source '$stubs'"; echo "SENSORS_SYS='$T/sys' SENSORS_PROC='$T/proc'"; } >"$fx/sysfs.sh"
psens() { HOME=$fx PCL_TEST_OVERRIDES=$fx/sysfs.sh "$PCL" sensors --json; }
rm -f "$C/profile.json"
jcheck "v1.1 sensors, Intel + amdgpu dGPU, no profile: detected" ".source == \"detected\"
  and .cpu.driver == \"coretemp\" and .cpu.label == \"Package id 0\" and .cpu.input == \"$T/sys/class/hwmon/hwmon0/temp1_input\"
  and .gpu.kind == \"hwmon\" and .gpu.driver == \"amdgpu\" and .gpu.integrated == false and .gpu.available
  and .gpus == [] and (.ram | length) == 1 and .ram[0].driver == \"jc42\"
  and .coolant == {kind: \"lianli\", device_id: null, field: \"coolant_temps\"}" "$(psens)"
cp "$(dirname "$(readlink -f "$0")")/fixtures/profile.example-desktop.json" "$C/profile.json"
jcheck "v1.1 sensors: a profile source this machine lacks reads as unavailable" '.source == "profile"
  and .cpu.driver == "k10temp" and .cpu.available == false and .cpu.input == null and .gpu.available == false' "$(psens)"
rm -f "$C/profile.json"
rm -rf "$T/sys/class/hwmon"/*
jcheck "v1.1 sensors, nothing at all: nulls and empty lists" '.cpu == null and .gpu == null and .gpus == [] and .ram == []' "$(psens)"
# The median of 20 runs in ms, re-measured once when over budget: a few slow
# runs on a busy machine (parallel test suites, ffmpeg jobs) shouldn't fail
# the check, a real slowdown still does.
median_ms() {
  local i t0 t1 ts=()
  for i in {1..20}; do t0=$(now_ms); pcl "$@" >/dev/null; t1=$(now_ms); ts+=($((t1 - t0))); done
  printf '%s\n' "${ts[@]}" | sort -n | sed -n 10p
}
timing_check() {
  local label=$1 budget=$2 m; shift 2
  m=$(median_ms "$@")
  (( m <= budget )) || { sleep 2; m=$(median_ms "$@"); }
  if (( m <= budget )); then ok "$label: median $m ms a run (<= $budget)"; else bad "$label: median $m ms a run (> $budget)"; fi
}
timing_check "v1.1 sensors --json" 30 sensors --json
cp "$(dirname "$(readlink -f "$0")")/fixtures/profile.example-desktop.json" "$C/profile.json"
pcl themes --json >/dev/null
for c in status themes; do timing_check "v1.1 $c --json" 40 "$c" --json; done

# --detach detect: queued in its own unit (detect_cmd is stubbed); bad
# arguments come back at once.
rc=0; out=$(pcl --detach detect --bogus 2>/dev/null) || rc=$?
if (( rc == 2 )) && jq -e '.error | startswith("usage")' >/dev/null <<<"$out"; then ok "--detach detect --bogus: usage, exit 2"; else bad "--detach detect --bogus: exit $rc $out"; fi
rc=0; out=$(pcl --detach detect --no-openrgb 2>/dev/null) || rc=$?
if (( rc == 0 )) && jq -e '.queued == true' >/dev/null <<<"$out"; then
  u=$(jq -r .unit <<<"$out"); units+=("$u"); ok "--detach detect: queued, exit 0"
  wait_for 20 units_gone "$u" || true
  check "--detach detect: ran detect in the unit" grep -q "$u detect --no-openrgb" "$fx/stub.log"
else bad "--detach detect: exit $rc $out"; fi

# A v3 theme with no profile fails validation before anything is applied.
rm -f "$C/profile.json"
n0=$(wc -l <"$fx/stub.log")
rc=0; out=$(pcl --detach pick v3demo 2>/dev/null) || rc=$?
if (( rc == 2 )) && jq -e '.error | test("profile|detect")' >/dev/null <<<"$out"; then ok "--detach pick <v3, no profile>: exit 2 ($(jq -r .error <<<"$out"))"
else bad "--detach pick <v3, no profile>: exit $rc $out"; fi
rc=0; pcl switch v3demo >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ $(wc -l <"$fx/stub.log") == "$n0" ]]; then ok "switch <v3, no profile>: exit $rc, nothing applied"
else bad "switch <v3, no profile>: exit $rc, stub calls $n0 -> $(wc -l <"$fx/stub.log")"; fi
rm -rf "$C/themes/v3demo"

# ---- 8b. screens (screens plan §1.2): theme screens, the media command, v1.3 ----
cp "$(dirname "$(readlink -f "$0")")/fixtures/profile.example-desktop.json" "$C/profile.json"
mkdir -p "$C/themes/v3screens"
echo '{"v": 3, "_about": "palette only", "palette": {"primary": "00ffd0"}}' >"$C/themes/v3screens/theme.json"
rc=0; out=$(pcl theme screens v3screens --json 2>/dev/null) || rc=$?
jcheck "theme screens --json (exit $rc): the v1 view, every screen role in map order, none from a palette-only theme" '.v == 1 and .draft == false
  and ([.screens[].role] | length) == 7 and (.map.order | length) == 7 and all(.screens[]; .source == "none" and .entry == null and .media == null)
  and .coverage.summary == "leds-only" and .editable and (.sig | test("^[0-9a-f]{16}$"))' "$out"
rc=0; out=$(pcl theme screens v2nope --json 2>/dev/null) || rc=$?
jcheck "theme screens of an unknown theme: exit 2 not-found (exit $rc)" ".code == \"not-found\" and $rc == 2" "$out"
rc=0; out=$(pcl theme media set v3screens screen.fan1 none --json 2>/dev/null) || rc=$?
jcheck "theme media without a draft: exit 2 not-found (exit $rc)" ".code == \"not-found\" and $rc == 2" "$out"
rc=0; pcl media --bogus >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then ok "media <unknown verb>: refused (exit $rc)"; else bad "media <unknown verb> exited 0"; fi
jcheck "status --json: v1.3 media (running, jobs) once v_minor is 3" \
  'if .v_minor >= 3 then (.media | type == "object") and (.media.jobs | type == "array") and (.media.running | type == "number") else .v_minor == 2 end' "$(sj)"
rm -rf "$C/themes/v3screens"
rm -f "$C/profile.json"

# ---- 9. contract v1.2: the theme preview (its own fixture) ---------------------
# shellcheck source=preview/checks.sh
source "$(dirname "$(readlink -f "$0")")/preview/checks.sh"
preview_suite "$PCL" "$ROOT"

echo
echo "passed $passed, failed $failed"
(( failed == 0 ))
