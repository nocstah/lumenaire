# checks.sh — the theme preview's engine checks (editor plan §4 "B checks"),
# sourced by tests/preview/run.sh and tests/engine-contract.sh, which provide
# ok <name>, bad <name> [detail] and jcheck <name> <jq filter> <json>.
#
#   preview_suite <engine> <scratch dir>
#
# It builds its own fixture $HOME under <scratch dir>: the sanitised
# example-desktop profile (fake MACs and serials), two palette-only v3 themes, a
# daemon config holding the saved theme's look (rendered by the engine
# itself), cached RAM ids, and a draft in the frozen draft schema (plan
# §1.1). tests/preview/stubs.sh is the PCL_TEST_OVERRIDES: the daemon is
# fake-socat (tests/preview/fixtures/daemon), OpenRGB and every apply only
# log, and nothing can reach the lights, the real daemon socket, the real
# openrgb or a real unit (one check starts real transient units, with a
# unique name, running the fixture; they are stopped at the end).
# The worker runs inline (PCL_PREVIEW_INLINE=1) except in that check.
# shellcheck shell=bash disable=SC2016  # jq filters are single-quoted on purpose

preview_suite() {
  local engine=$1 root=$2 here P C K rc out s n sha0 dsha unit t0 pid
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  P=$root/pv-$$ C=$root/pv-$$/.config/pc-lights K=$root/pv-$$/.cache/pc-lights
  unit=pcl-test-preview-$$

  # pcl: the engine in the fixture, worker inline; pcl_units: with real units.
  pcl() { HOME=$P PCL_TEST_OVERRIDES=$here/stubs.sh PCL_PREVIEW_INLINE=1 PCL_PV_SCREEN_WAIT=3 PCL_PV_SCREEN_WAIT_PUMP=3 PCL_PV_RELOAD_SETTLE=0 "$engine" "$@"; }
  pcl_units() { HOME=$P PCL_TEST_OVERRIDES=$here/stubs.sh PCL_PREVIEW_UNIT=$unit "$engine" "$@"; }
  pv() { cat "$K/preview.json" 2>/dev/null || echo null; }
  # with_cfg <requests json>: {r: the requests, d: the daemon config's devices by id}.
  with_cfg() {
    jq -nc --argjson r "$1" --slurpfile c "$P/.config/lianli/config.json" \
      '{r: $r, d: ($c[0].rgb.devices | map({key: .device_id, value: .}) | from_entries), rgb: $c[0].rgb}'
  }
  # A revert request carries the config's effect for that zone or region.
  revert_ok='all(.r[] | select(.method == "SetRgbEffect"); .params as $p | $d[$p.device_id] as $dev
    | if ($dev.regions // [] | length) > 0 then $p.zone == 0 and any($dev.regions[]; .effect == $p.effect)
      else any($dev.zones[]; .zone_index == $p.zone and .effect == $p.effect) end)'
  reqs() { grep -c . "$P/requests.jsonl" 2>/dev/null || true; }
  # draft <jq filter on .theme>: edit the draft, rev + 1 (what "theme set" does).
  draft() {
    jq "(.theme |= ($1)) | .rev += 1 | .updated = now | .updated |= floor" "$C/drafts/calm.json" >"$C/drafts/calm.json.tmp" &&
      mv "$C/drafts/calm.json.tmp" "$C/drafts/calm.json"
  }
  rev() { jq -r .rev "$C/drafts/calm.json"; }
  wait_state() {   # wait_state <seconds> <jq test>
    local end=$(( $(date +%s%N) / 1000000 + $1 * 1000 ))
    until jq -e "$2" "$K/preview.json" >/dev/null 2>&1; do
      (( $(date +%s%N) / 1000000 < end )) || return 1
      sleep 0.1
    done
  }
  pv_cleanup() {
    local u
    for u in $(systemctl --user list-units --all --plain --no-legend "$unit*" 2>/dev/null | awk '{print $1}'); do
      systemctl --user stop "$u" 2>/dev/null || true
    done
    if [[ -n ${pid:-} ]]; then kill -9 -- "-$pid" 2>/dev/null || true; fi
    if [[ -z ${KEEP_FIXTURE:-} ]]; then rm -rf "$P"; fi
  }

  # ---- fixture ------------------------------------------------------------------
  mkdir -p "$C/themes/calm" "$C/themes/other" "$C/themes/oldstyle" "$C/drafts" "$K" "$P/.config/lianli" "$P/bin"
  cp "$here/fake-socat" "$P/bin/socat"; cp "$here/fake-openrgb" "$P/bin/openrgb"
  cp -r "$here/fixtures/daemon" "$P/daemon"
  cp "$here/../fixtures/profile.example-desktop.json" "$C/profile.json"
  echo '{"v": 3, "_about": "saved", "palette": {"primary": "00ffd0", "secondary": "0050ff"}}' >"$C/themes/calm/theme.json"
  echo '{"v": 3, "_about": "other", "palette": {"primary": "ff8000", "secondary": "ffd000"}}' >"$C/themes/other/theme.json"
  echo '{"fans": {"top": "ff0000", "bottom": "00ff00"}, "rings": "0000ff"}' >"$C/themes/oldstyle/theme.json"
  echo calm >"$C/scheme"; echo calm >"$C/day-scheme"; echo on >"$C/lights"; echo on >"$C/screens"
  echo "3 4" >"$K/ram-ids"
  printf '{"enabled":true,"night_theme":"other","night_start":"%s","night_end":"%s"}\n' \
    "$(date -d "@$(( EPOCHSECONDS + 7200 ))" +%H:%M)" "$(date -d "@$(( EPOCHSECONDS + 10800 ))" +%H:%M)" >"$C/schedule.json"
  jq -n '{rgb: {enabled: true, openrgb_server: false, openrgb_port: 6743, devices: []}, lcds: [],
    thermal_alert: {cpu: {enabled: true, threshold: 90, alert_color: [255, 0, 0]},
                    gpu: {enabled: true, threshold: 85, alert_color: [255, 0, 0]}}}' >"$P/.config/lianli/config.json"
  # The saved look: what "on" would write for calm, rendered by the engine.
  pcl render calm >"$P/render.out" 2>/dev/null || true
  awk '/^# \.rgb$/ { f = 1; next } /^# \.lcds$/ { f = 0 } f' "$P/render.out" >"$P/rgb.json"
  if ! jq -e '.devices | length == 7' "$P/rgb.json" >/dev/null 2>&1; then
    bad "preview fixture: render of the saved theme" "$(head -c 300 "$P/render.out")"; pv_cleanup; return 0
  fi
  jq --slurpfile r "$P/rgb.json" '.rgb = $r[0]' "$P/.config/lianli/config.json" >"$P/cfg.tmp" && mv "$P/cfg.tmp" "$P/.config/lianli/config.json"
  : >"$P/requests.jsonl"; rm -f "$P/stub.log" "$P/reads.log"
  sha0=$(sha256sum <"$P/.config/lianli/config.json")
  jq -n --arg sha "$(sha256sum "$C/themes/calm/theme.json" | cut -d' ' -f1)" --arg mr "$C/themes/calm" '
    {v: 1, name: "calm", mode: "edit", from: null, rev: 1, created: 1790000000, updated: 1790000000,
     base_sha256: $sha, media_root: $mr,
     theme: {v: 3, _about: "saved", palette: {primary: "ff4a9a", secondary: "ff1a70"}}}' >"$C/drafts/calm.json"
  echo "preview fixture: $P"

  # ---- the method gate and refusals ---------------------------------------------
  rc=0; out=$(pcl theme preview calm --json 2>/dev/null) || rc=$?
  if (( rc == 2 )) && jq -e '.code == "unmeasured" and (.error | test("hardware check") and test("lumenaire theme preview --measure"))' >/dev/null 2>&1 <<<"$out" &&
     [[ ! -e $K/preview.json ]]; then ok "preview: nothing measured -> exit 2 unmeasured, no session"
  else bad "preview: unmeasured refusal: exit $rc $out"; fi
  echo rgbconfig >"$C/preview-method"
  jq '.preview = {method: "effect"}' "$C/profile.json" >"$C/profile.tmp" && mv "$C/profile.tmp" "$C/profile.json"
  rm -f "$C/preview-method"
  rc=0; out=$(pcl theme preview calm --rev 1 --json 2>/dev/null) || rc=$?
  if (( rc == 0 )) && jq -e '.queued == true and .rev == 1' >/dev/null 2>&1 <<<"$out"; then ok "preview: the profile's preview.method is a measured method"
  else bad "preview: profile preview.method: exit $rc $out"; fi
  jq 'del(.preview)' "$C/profile.json" >"$C/profile.tmp" && mv "$C/profile.tmp" "$C/profile.json"
  echo effect >"$C/preview-method"
  pcl theme preview --end >/dev/null 2>&1 || true
  : >"$P/requests.jsonl"; rm -f "$K/preview.json" "$P/stub.log" "$P/reads.log"; rm -rf "$K/preview"

  rc=0; out=$(pcl theme preview nosuch --json 2>/dev/null) || rc=$?
  jcheck "preview: no draft -> exit 2 not-found (rc $rc)" ".code == \"not-found\" and $rc == 2" "$out"
  echo off >"$C/lights"
  rc=0; out=$(pcl theme preview calm --json 2>/dev/null) || rc=$?
  jcheck "preview: lights off -> exit 2 lights-off (rc $rc)" ".code == \"lights-off\" and $rc == 2" "$out"
  echo on >"$C/lights"
  cp "$C/drafts/calm.json" "$P/draft.good"
  draft '.roles = {"strimer.gpu": {colors: ["zz0000"]}}'
  rc=0; out=$(pcl theme preview calm --json 2>/dev/null) || rc=$?
  jcheck "preview: a draft with problems -> exit 2 invalid with the problems (rc $rc)" \
    ".code == \"invalid\" and $rc == 2 and (.problems | length > 0) and all(.problems[]; .message | type == \"string\")" "$out"
  cp "$P/draft.good" "$C/drafts/calm.json"
  if [[ ! -e $K/preview.json && $(reqs) == 0 ]]; then ok "preview: refusals start no session and send nothing"
  else bad "preview: a refusal left a session or sent $(reqs) requests"; fi

  # ---- the first pass: request shapes per device type ---------------------------------
  t0=$(date +%s%N)
  rc=0; out=$(pcl theme preview calm --rev "$(rev)" --json 2>/dev/null) || rc=$?
  t0=$(( ($(date +%s%N) - t0) / 1000000 ))
  s=$(pv)
  jcheck "preview: first pass live (exit $rc, ${t0} ms inline)" ".state == \"live\" and .method == \"effect\" and .worker == false
    and .applied_rev == $(rev) and .want_rev == $(rev) and .lianli.state == \"ok\" and .lianli.sent == 10
    and .lianli.failed == [] and .openrgb.state == \"ok\" and .ended == null and .error == null and $rc == 0" "$s"
  out=$(jq -sc . "$P/requests.jsonl")
  jcheck "preview: TL fan groups get 2 SetRgbEffect each, zone 0, scopes Top and Bottom" '
    [.[] | select(.params.device_id | startswith("wireless:02:00:00:00:01:"))] as $tl
    | ($tl | length) == 6 and all($tl[]; .method == "SetRgbEffect" and .params.zone == 0)
    and ([$tl[] | .params.effect.scope] | sort) == ["Bottom", "Bottom", "Bottom", "Top", "Top", "Top"]
    and ([$tl[] | .params.device_id] | unique | length) == 3
    and all($tl[]; .params.effect.mode == "Static" and (.params.effect.colors | length) == 4)' "$out"
  jcheck "preview: Strimers get one per zone with 6 colours, mode, speed, direction" '
    [.[] | select(.params.device_id | startswith("wireless:02:00:00:00:02:"))] as $s
    | ($s | length) == 2 and all($s[]; .params.zone == 0 and (.params.effect.colors | length) == 6
      and (.params.effect.mode | type == "string") and (.params.effect.speed | type == "number")
      and (.params.effect.direction | type == "string") and (.params.effect.scope == null))' "$out"
  jcheck "preview: rings (pump, 8.8\" screen) one each on zone 0; the ignored receivers none" '
    ([.[] | select(.params.device_id | IN("hid:0416:8051:8-7.2.3", "hid:0416:8050:8-10.2.3")) | .params.zone] == [0, 0])
    and ([.[] | select(.params.device_id | startswith("hid:43a8"))] == []) and length == 10' "$out"
  jcheck "preview: every write went guarded with the daemon's instance" 'all(.[]; .method == "SetRgbEffect")' "$out"
  if [[ ! -s $P/refused-guard.jsonl && $(grep -c GetDaemonInfo "$P/reads.log") == 1 ]]; then ok "preview: one GetDaemonInfo for the whole batch"
  else bad "preview: GetDaemonInfo $(grep -c GetDaemonInfo "$P/reads.log") times"; fi
  if [[ $(sha256sum <"$P/.config/lianli/config.json") == "$sha0" && ! -e $K/busy.json && ! -e $K/last-run.json ]]; then
    ok "preview: config.json untouched, no busy.json or last-run.json"
  else bad "preview: the preview wrote config.json or the run bookkeeping"; fi
  if [[ $(grep -c 'be_openrgb_preview start' "$P/stub.log") == 1 ]] && ! grep -q -- '--list-devices\| -l ' "$P/stub.log" &&
     grep -q 'be_openrgb_preview start .*-d 3 .*-d 4 ' "$P/stub.log" && [[ ! -e $P/openrgb-real-calls.log ]]; then
    ok "preview: OpenRGB once, with the cached RAM ids, no device listing, never the real openrgb"
  else bad "preview: OpenRGB calls" "$(grep openrgb "$P/stub.log" | cut -c1-200)"; fi

  # ---- the same rev: nothing; one field: one device ------------------------------------
  n=$(reqs)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  if [[ $(reqs) == "$n" && $(grep -c 'be_openrgb_preview start' "$P/stub.log") == 1 ]]; then ok "preview: the same rev again sends nothing"
  else bad "preview: the same rev sent $(( $(reqs) - n )) requests"; fi
  draft '.roles = {"strimer.gpu": {colors: ["00ff00", "00ff00", "00ff00", "00ff00", "00ff00", "00ff00"]}}'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "preview: one Strimer's colours changed -> one request, that Strimer" '
    length == 1 and .[0].params.device_id == "wireless:02:00:00:00:02:02" and .[0].params.zone == 0
    and .[0].params.effect.colors == [[0,255,0],[0,255,0],[0,255,0],[0,255,0],[0,255,0],[0,255,0]]' "$out"
  if [[ $(grep -c 'be_openrgb_preview start' "$P/stub.log") == 1 ]]; then ok "preview: OpenRGB not run when gpu/board/ram are unchanged"
  else bad "preview: OpenRGB ran for a Lian Li-only change"; fi
  jcheck "preview: applied_rev follows" ".applied_rev == $(rev) and .state == \"live\" and .lianli.sent == 1" "$(pv)"
  n=$(reqs)
  draft '.roles += {gpu: "00ff00"}'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  if [[ $(reqs) == "$n" && $(grep -c 'be_openrgb_preview start' "$P/stub.log") == 2 ]] &&
     jq -e '.openrgb.state == "ok" and .openrgb.rev == '"$(rev)" "$K/preview.json" >/dev/null; then
    ok "preview: a gpu-only change runs OpenRGB and sends no Lian Li request"
  else bad "preview: gpu-only change: $(( $(reqs) - n )) requests, $(grep -c 'be_openrgb_preview start' "$P/stub.log") OpenRGB runs"; fi

  # ---- failures, heat alert, a daemon restart mid-batch ---------------------------------
  echo wireless:02:00:00:00:02:01 >"$P/fail-devices"
  draft '.palette.primary = "ff5aa0"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jcheck "preview: a device that fails is listed, the rest applied" '.state == "live" and (.lianli.failed | length) == 1
    and .lianli.failed[0].device_id == "wireless:02:00:00:00:02:01" and (.lianli.failed[0].error | test("unavailable"))' "$(pv)"
  rm -f "$P/fail-devices"; n=$(reqs)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "preview: the same rev re-sends the failed device (Resend)" 'length == 1 and .[0].params.device_id == "wireless:02:00:00:00:02:01"' "$out"
  jcheck "preview: ... and clears the failure" '.lianli.failed == [] and .state == "live"' "$(pv)"
  echo "RGB effect error: thermal alert currently controls RGB" >"$P/daemon-error"
  draft '.palette.primary = "ff6ab0"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jcheck "preview: the heat alert blocks the preview (blocked_by heat-alert)" '.state == "blocked" and .blocked_by == "heat-alert" and .worker == false' "$(pv)"
  rm -f "$P/daemon-error"
  : >"$P/reads.log"; echo $(( $(reqs) + 2 )) >"$P/restart-after"
  draft '.palette.primary = "ff7ac0" | .palette.secondary = "c01060"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  if [[ $(grep -c GetDaemonInfo "$P/reads.log") == 2 && $(grep -c . "$P/refused-guard.jsonl" 2>/dev/null) == 1 ]] &&
     jq -e '.state == "live" and .lianli.failed == []' "$K/preview.json" >/dev/null; then
    ok "preview: a daemon restart mid-batch: the guard is read again once and the batch completes"
  else bad "preview: guard re-read: $(grep -c GetDaemonInfo "$P/reads.log") reads, $(grep -c . "$P/refused-guard.jsonl" 2>/dev/null) refused" "$(pv)"; fi
  echo test-instance-1 >"$P/daemon-instance"

  # ---- the lock: blocked, never queued ----------------------------------------------------
  setsid flock "$K/lock" sleep 30 & pid=$!; disown
  until ! flock -n "$K/lock" true 2>/dev/null; do sleep 0.05; done
  jq -nc --argjson pid "$pid" '{v: 1, pid: $pid, op: "pick", target: null, theme: "hellfire", unit: "pc-lights-ui-pick-1", step: "lian li", since: 1}' >"$K/busy.json"
  draft '.palette.primary = "ff8ad0"'
  t0=$(date +%s%N)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  t0=$(( ($(date +%s%N) - t0) / 1000000 ))
  jcheck "preview: lock held by an apply -> blocked by it in ${t0} ms (<= 3500)" ".state == \"blocked\" and .blocked_by.op == \"pick\"
    and .blocked_by.theme == \"hellfire\" and .worker == false and $t0 <= 3500" "$(pv)"
  kill -9 -- "-$pid" 2>/dev/null || true; pid=
  rm -f "$K/busy.json"
  pcl theme preview --reap >/dev/null 2>&1 || true
  jcheck "preview: the reaper retries a blocked preview once the lock is free" ".state == \"live\" and .applied_rev == $(rev)" "$(pv)"

  # ---- keepalive -------------------------------------------------------------------------
  jq '.touched -= 50 | .edited -= 50' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  s=$(pv)
  pcl theme preview --keepalive >/dev/null 2>&1 || true
  jcheck "preview: --keepalive moves touched, not edited" ".touched >= $EPOCHSECONDS - 2 and .edited == $(jq .edited <<<"$s")" "$(pv)"
  pcl theme preview --keepalive --edited >/dev/null 2>&1 || true
  jcheck "preview: --keepalive --edited moves edited and idle_ends" ".edited >= $EPOCHSECONDS - 2 and .idle_ends == .edited + .idle_ttl" "$(pv)"

  # ---- contract v1.2: status --json, themes --json ---------------------------------------
  s=$(pcl status --json 2>/dev/null)
  jcheck "v1.2 status: v 1, v_minor 2 or later, preview is the session, drafts listed" '.v == 1 and .v_minor >= 2
    and .preview.state == "live" and .preview.theme == "calm" and (.preview.id | startswith("p-"))
    and .drafts == [{name: "calm", mode: "edit", from: null, rev: .drafts[0].rev, updated: .drafts[0].updated}]
    and (.drafts[0].rev | type == "number")' "$s"
  s=$(pcl themes --json 2>/dev/null)
  jcheck "v1.2 themes: draft, editable, edit_block" '
    (.[] | select(.name == "calm") | (.draft | keys) == ["rev", "updated"] and .editable and .edit_block == null)
    and (.[] | select(.name == "other") | .draft == null and .editable and .edit_block == null)
    and (.[] | select(.name == "oldstyle") | .draft == null and (.editable | not) and .edit_block == "v2")' "$s"
  mv "$C/profile.json" "$C/profile.off"
  jcheck "v1.2 themes: no profile -> edit_block no-profile" 'all(.[]; .editable == false and .edit_block == "no-profile")' "$(pcl themes --json 2>/dev/null)"
  mv "$C/profile.off" "$C/profile.json"

  # ---- a pick during a live session: revert first, then the apply --------------------------
  dsha=$(sha256sum <"$C/drafts/calm.json")
  n=$(reqs)
  pcl pick other >/dev/null 2>&1 || true
  s=$(pv)
  jcheck "pick during a preview: ended, cancelled by the pick, reverted" '.state == "ended" and .ended.reason == "cancelled"
    and .ended.by == {op: "pick", theme: "other"} and .ended.reverted == true and .worker == false' "$s"
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "pick during a preview: the revert went out before the apply" '
    (map(.stub == "lianli_lights on") | index(true)) as $i
    | $i != null and $i > 0 and all(.[0:$i][]; .method == "SetRgbEffect")' "$out"
  jcheck "pick during a preview: the revert sends CFG_LIVE's zones and regions for every touched device" \
    ".d as \$d | ([.r[] | select(.method == \"SetRgbEffect\")] | length) == 10 and $revert_ok" "$(with_cfg "$out")"
  if [[ $(sha256sum <"$C/drafts/calm.json") == "$dsha" && ! -e $K/preview/applied-rgb.json ]]; then ok "pick during a preview: the draft is kept, the applied state dropped"
  else bad "pick during a preview: the draft changed or applied-rgb.json is left"; fi
  echo calm >"$C/scheme"

  # ---- on / off / apply-openrgb yield ------------------------------------------------------
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs)
  pcl off lights >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "off during a preview: ended lights-off, no revert (Off replaces everything)" '.state == "ended" and .ended.reason == "lights-off"
    and .ended.reverted == false and .ended.by.op == "off"' "$(pv)"
  jcheck "off during a preview: no SetRgbEffect before the Off apply" '.[0].stub == "lianli_lights off" and length == 1' "$out"
  echo on >"$C/lights"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs)
  pcl on lights >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "on during a preview: reverted first, cancelled by on" '.state == "ended" and .ended.reason == "cancelled" and .ended.by.op == "on" and .ended.reverted' "$(pv)"
  jcheck "on during a preview: the revert precedes the apply" '(map(.stub == "lianli_lights on") | index(true)) as $i | $i != null and $i > 0' "$out"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  pcl apply-openrgb >/dev/null 2>&1 || true
  jcheck "apply-openrgb during a preview: reverted, cancelled by apply-openrgb" '.state == "ended" and .ended.by.op == "apply-openrgb" and .ended.reverted' "$(pv)"

  # ---- the schedule defers, the clips skip ----------------------------------------------
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  printf '{"enabled":true,"night_theme":"other","night_start":"%s","night_end":"%s"}\n' \
    "$(date -d "@$(( EPOCHSECONDS - 7200 ))" +%H:%M)" "$(date -d "@$(( EPOCHSECONDS + 7200 ))" +%H:%M)" >"$C/schedule.json"
  rm -f "$K/schedule-boundary" "$K/last-run.json"
  rc=0; out=$(pcl schedule tick 2>&1) || rc=$?
  if [[ ! -e $K/schedule-boundary && ! -e $K/last-run.json && $(cat "$C/scheme") == calm && $out == *"deferred while a theme preview runs"* ]] &&
     jq -e '.state == "live"' "$K/preview.json" >/dev/null; then ok "schedule tick during a preview: deferred, boundary not marked"
  else bad "schedule tick during a preview: rc $rc, boundary $(cat "$K/schedule-boundary" 2>/dev/null), scheme $(cat "$C/scheme")" "$out"; fi

  mkdir -p "$C/themes/rotor/media/pump"
  : >"$C/themes/rotor/media/pump/a.mp4"; : >"$C/themes/rotor/media/pump/b.mp4"
  echo '{"screens":[{"serial":"a1a1a1a100000006","_where":"pump","type":"video","path":"media/pump/a.mp4","orientation":90,"clips":["media/pump"],"rotate":300}]}' >"$C/themes/rotor/theme.json"
  echo rotor >"$C/scheme"
  jq -n --argjson now "$EPOCHSECONDS" '{theme: "rotor", since: ($now - 1000), screens: {}}' >"$K/clips.json"
  pcl clips tick >/dev/null 2>&1 || true
  if ! grep -q swap_clip "$P/stub.log" 2>/dev/null; then ok "clips tick during a preview: no swap"
  else bad "clips tick during a preview swapped a clip"; fi
  rc=0; pcl clips next --nowait >/dev/null 2>&1 || rc=$?
  jcheck "clips next during a preview: skipped with the reason (exit $rc)" ".op == \"clips-next\" and .skipped == true
    and .error == \"a theme preview is running\" and $rc == 0" "$(cat "$K/last-run.json" 2>/dev/null || echo null)"
  echo calm >"$C/scheme"; rm -f "$K/last-run.json"

  rc=0; out=$(pcl theme preview --end --reason panel-closed --json 2>/dev/null) || rc=$?
  jcheck "preview --end: queued, then ended panel-closed and reverted (exit $rc)" '.state == "ended" and .ended.reason == "panel-closed"
    and .ended.reverted and .ended.by == null' "$(pv)"
  rc=0; out=$(pcl theme preview --end --json 2>/dev/null) || rc=$?
  jcheck "preview --end again: idempotent (exit $rc)" ".queued == false and .ended == true and $rc == 0" "$out"
  pcl schedule tick >/dev/null 2>&1 || true
  jcheck "schedule tick after the preview: the boundary applies" '.op == "schedule-tick" and .theme == "other" and .rc == 0' "$(cat "$K/last-run.json" 2>/dev/null || echo null)"
  echo rotor >"$C/scheme"
  pcl clips tick >/dev/null 2>&1 || true
  if grep -q 'swap_clip a1a1a1a100000006' "$P/stub.log" 2>/dev/null; then ok "clips tick after the preview: the due clip swaps"
  else bad "clips tick after the preview: no swap"; fi
  echo calm >"$C/scheme"; rm -f "$K/clips.json"
  printf '{"enabled":true,"night_theme":"other","night_start":"%s","night_end":"%s"}\n' \
    "$(date -d "@$(( EPOCHSECONDS + 7200 ))" +%H:%M)" "$(date -d "@$(( EPOCHSECONDS + 10800 ))" +%H:%M)" >"$C/schedule.json"

  # ---- the reaper: ui-gone, idle ----------------------------------------------------------
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jq '.touched -= 100' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  n=$(reqs); : >"$P/stub.log"
  pcl theme preview --reap >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "reap: no heartbeat for 100 s -> ended ui-gone, reverted" '.state == "ended" and .ended.reason == "ui-gone" and .ended.reverted' "$(pv)"
  jcheck "reap: the revert requests are CFG_LIVE's" ".d as \$d | (.r | length) > 0 and $revert_ok" "$(with_cfg "$out")"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jq '.edited -= 700' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  pcl clips tick >/dev/null 2>&1 || true
  jcheck "reap from the clip tick: idle past idle_ttl -> ended idle" '.state == "ended" and .ended.reason == "idle" and .ended.reverted' "$(pv)"
  if grep -q 'blocked: systemctl --user stop '"lumenaire-preview-reap.timer" "$P/stub.log"; then ok "reap: an ended session stops the reap timer"
  else bad "reap: the reap timer was never stopped"; fi

  # ---- a worker stopped mid-OpenRGB --------------------------------------------------------
  draft '.roles += {gpu: "0000ff"}'
  jq --argjson r "$(rev)" --argjson now "$EPOCHSECONDS" '.state = "queued" | .ended = null | .worker = true | .want_rev = $r
    | .touched = $now | .edited = $now | .idle_ends = $now + 600' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  echo 3 >"$P/orgb-sleep"; : >"$P/stub.log"; rm -f "$K/busy.json" "$K/last-run.json"
  setsid bash -c "HOME='$P' PCL_TEST_OVERRIDES='$here/stubs.sh' '$engine' theme preview --run" >/dev/null 2>&1 & pid=$!; disown
  wait_state 10 '.openrgb.state == "applying"' || true
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..150}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; pid=
  echo 0 >"$P/orgb-sleep"
  if grep -q 'be_openrgb_preview done' "$P/stub.log"; then ok "worker SIGTERM: the running OpenRGB call finished"
  else bad "worker SIGTERM: OpenRGB was cut short" "$(cat "$P/stub.log")"; fi
  jcheck "worker SIGTERM: a consistent session (worker false, error says so)" '.worker == false and (.error | test("SIGTERM"))
    and .state == "live" and .openrgb.state == "ok"' "$(pv)"
  if [[ ! -e $K/busy.json && ! -e $K/last-run.json ]]; then ok "worker: never writes busy.json or last-run.json"
  else bad "worker wrote the run bookkeeping"; fi
  pcl theme preview --end >/dev/null 2>&1 || true

  # ---- a new request calls off an end still waiting for the lock ------------------
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jq '.state = "ending" | .ending = {reason: "closed", by: null, revert: true} | .worker = true' "$K/preview.json" >"$K/p.tmp" &&
    mv "$K/p.tmp" "$K/preview.json"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jcheck "a request during a queued end calls the end off" '.state == "queued" and .ending == null and .worker == true and .ended == null' "$(pv)"
  pcl theme preview --run >/dev/null 2>&1 || true
  jcheck "... and the waiting worker does a pass instead" '.state == "live" and .worker == false and .ended == null' "$(pv)"
  pcl theme preview --end >/dev/null 2>&1 || true

  # ---- method rgbconfig: SetRgbConfig, and the snapshot sent back -----------------------
  echo rgbconfig >"$C/preview-method"
  n=$(reqs)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "rgbconfig: one SetRgbConfig carrying the draft's devices, the session says rgbconfig" '
    length == 1 and .[0].method == "SetRgbConfig" and (.[0].params.config.devices | length) == 7
    and .[0].params.config.enabled == true' "$out"
  jcheck "rgbconfig: live" '.state == "live" and .method == "rgbconfig"' "$(pv)"
  if jq -e --slurpfile c "$P/.config/lianli/config.json" '. == $c[0].rgb' "$K/preview/saved-rgb.json" >/dev/null 2>&1; then
    ok "rgbconfig: the saved rgb section is kept while the session lasts"
  else bad "rgbconfig: no saved-rgb.json snapshot"; fi
  n=$(reqs)
  pcl theme preview --end >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "rgbconfig: the end sends the saved rgb section back" \
    '(.r | length) == 1 and .r[0].method == "SetRgbConfig" and .r[0].params.config == .rgb' "$(with_cfg "$out")"
  jcheck "rgbconfig: ended, reverted" '.state == "ended" and .ended.reverted' "$(pv)"
  echo effect >"$C/preview-method"

  # ---- no session: every hook is a no-op --------------------------------------------------
  rm -f "$K/preview.json"; rm -rf "$K/preview"; n=$(reqs); : >"$P/stub.log"
  pcl on lights >/dev/null 2>&1 || true
  pcl pick other >/dev/null 2>&1 || true
  pcl apply-openrgb >/dev/null 2>&1 || true
  pcl clips tick >/dev/null 2>&1 || true
  pcl off lights >/dev/null 2>&1 || true
  if [[ ! -e $K/preview.json && $(tail -n +$((n + 1)) "$P/requests.jsonl" | grep -c SetRgb) == 0 ]] &&
     ! grep -q 'reap.timer' "$P/stub.log"; then ok "no session: on, pick, apply-openrgb, clips tick and off touch no preview state"
  else bad "no session: a hook acted"; fi
  echo on >"$C/lights"; echo calm >"$C/scheme"

  # ---- the screens part (screens plan §3, §7 "B2: tests/preview") ------------------------
  # The config gets the saved theme's screens (fake serials, the daemon's
  # hid: form; fan 5 has no entry), the draft new media on fans 1-3, the
  # saved media on fan 4, a brightness on the pump and a template the
  # daemon doesn't have on the 8.8".
  pcl theme preview --end >/dev/null 2>&1 || true
  rm -f "$K/preview.json"; rm -rf "$K/preview"
  echo effect >"$C/preview-method"; echo calm >"$C/scheme"; echo on >"$C/lights"; echo on >"$C/screens"
  mkdir -p "$C/themes/calm/media"
  echo saved >"$C/themes/calm/media/saved-fan.mp4"; echo new >"$C/themes/calm/media/new-fan.mp4"
  echo pump >"$C/themes/calm/media/pump.mp4"; echo other >"$C/themes/calm/media/other-fan.mp4"
  jq -n '{"f1f1f1f100000001": "hid:1cbe:a018:8-12.2.1", "f1f1f1f100000002": "hid:1cbe:a018:8-12.2.2",
          "f1f1f1f100000003": "hid:1cbe:a018:8-12.2.3", "f1f1f1f100000004": "hid:1cbe:a018:8-12.4.2",
          "f1f1f1f100000005": "hid:1cbe:a018:8-12.4.3", "a1a1a1a100000006": "hid:1cbe:a068:8-7.2.2",
          "b8b8b8b800000007": "hid:1cbe:a088:8-10.2.2"}' >"$P/usbmap.json"
  jq --arg m "$C/themes/calm/media" '
    def lcd($s; $t; $p; $o): {index: null, serial: $s, type: $t, path: $p, fps: null, update_interval_ms: null, rgb: null,
      orientation: $o, sensor: null, sensor_source_1: {type: "cpu_usage"}, sensor_source_2: {type: "cpu_usage"}, doublegauge: null,
      template_id: null, smooth_edges: null, custom_h264: null, aio_512_frame: null};
    .lcds = [lcd("hid:1cbe:a018:8-12.2.1"; "video"; "\($m)/saved-fan.mp4"; 180.0) + {brightness: 25},
             lcd("hid:1cbe:a018:8-12.2.2"; "video"; "\($m)/saved-fan.mp4"; 180.0) + {brightness: 25},
             lcd("hid:1cbe:a018:8-12.2.3"; "video"; "\($m)/saved-fan.mp4"; 180.0) + {brightness: 25},
             lcd("hid:1cbe:a018:8-12.4.2"; "video"; "\($m)/saved-fan.mp4"; 0.0),
             lcd("hid:1cbe:a068:8-7.2.2"; "video"; "\($m)/pump.mp4"; 90.0),
             lcd("hid:1cbe:a088:8-10.2.2"; "custom"; null; 90.0) + {template_id: "us88-calm"}]' \
    "$P/.config/lianli/config.json" >"$P/cfg.tmp" && mv "$P/cfg.tmp" "$P/.config/lianli/config.json"
  echo '{"templates": [{"id": "us88-calm"}]}' >"$P/.config/lianli/lcd_templates.json"
  sha0=$(sha256sum <"$P/.config/lianli/config.json")
  draft '.screens = {"screen.fan": [{type: "video", path: "media/new-fan.mp4", model: "TlFlexLcd"}, {type: "video", path: "media/new-fan.mp4", model: "TlFlexLcd"},
                                    {type: "video", path: "media/new-fan.mp4", model: "TlFlexLcd"}, {type: "video", path: "media/saved-fan.mp4", model: "TlFlexLcd"},
                                    {type: "video", path: "media/saved-fan.mp4", model: "TlFlexLcd"}],
                     "screen.pump": {type: "video", path: "media/pump.mp4", brightness: 40, model: "HydroShift2OledCurveLcd"},
                     "screen.main": {type: "custom", template_id: "us88-missing", model: "UniversalScreen"}}'
  : >"$P/requests.jsonl"; rm -f "$P/reads.log" "$P/stub.log" "$P/telemetry-states"
  echo "1 ready" >"$P/telemetry-after-writes"
  rc=0; pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || rc=$?
  out=$(jq -sc . "$P/requests.jsonl")
  jcheck "screens: SetLcdMedia only for the screens whose media changed (fans 1-3)" '[.[] | select(.method == "SetLcdMedia") | .params.device_id]
    == ["serial:hid:1cbe:a018:8-12.2.1", "serial:hid:1cbe:a018:8-12.2.2", "serial:hid:1cbe:a018:8-12.2.3"]' "$out"
  jcheck "screens: each is the config's own entry: serial kept, the draft's absolute path, model + mount orientation, no brightness" \
    "all(.[] | select(.method == \"SetLcdMedia\") | .params; .config.serial == (.device_id | ltrimstr(\"serial:\"))
      and .config.path == \"$C/themes/calm/media/new-fan.mp4\" and .config.orientation == 180 and .config.type == \"video\"
      and (.config | has(\"brightness\") | not) and .config.template_id == null and .config.sensor_source_1 == {type: \"cpu_usage\"})" "$out"
  jcheck "screens: a brightness alone is a SetLcdBrightness with the bare config serial" \
    '[.[] | select(.method == "SetLcdBrightness")] == [{method: "SetLcdBrightness", params: {device_id: "hid:1cbe:a068:8-7.2.2", brightness: 40}}]' "$out"
  jcheck "screens: fan 4 (same media) nothing; fan 5 (no config entry) never appended; the missing template skipped" \
    '(map(.params.device_id // "" | select(test("8-12\\.4\\.[23]|8-10\\.2\\.2"))) == [])' "$out"
  jcheck "screens go first: every SetLcd* before the first SetRgbEffect" \
    '(map(.method | startswith("SetLcd")) | index(false)) as $i | $i != null and all(.[:$i][]; .method | startswith("SetLcd")) and all(.[$i:][]; .method == "SetRgbEffect")' "$out"
  s=$(pv)
  jcheck "screens part of the session: live, 4 sent; roles from the telemetry (ready), skips with their reasons" '.screens.state == "live" and .screens.sent == 4
    and ([.screens.roles["screen.fan1", "screen.fan2", "screen.fan3"] | .state] == ["ready", "ready", "ready"])
    and .screens.roles["screen.fan1"].what == "media" and .screens.roles["screen.fan1"].gen0 == 30
    and .screens.roles["screen.pump"] == (.screens.roles["screen.pump"] + {state: "ready", what: "brightness"})
    and .screens.roles["screen.fan5"].state == "skipped" and .screens.roles["screen.fan5"].reason == "not-in-config"
    and .screens.roles["screen.main"].reason == "template-missing" and (.screens.roles | has("screen.fan4") | not)
    and .screens.failed == [] and (.screens.ms | type == "number")' "$s"
  jcheck "screens: saved-lcds.json holds the config entries at first touch, byte for byte" \
    '(.l | map({key: .serial, value: .}) | from_entries) as $l
     | (.s | keys) == ["hid:1cbe:a018:8-12.2.1", "hid:1cbe:a018:8-12.2.2", "hid:1cbe:a018:8-12.2.3", "hid:1cbe:a068:8-7.2.2"]
     and all(.s | to_entries[]; .value == $l[.key])' \
    "$(jq -nc --slurpfile s "$K/preview/saved-lcds.json" --slurpfile c "$P/.config/lianli/config.json" '{s: $s[0], l: $c[0].lcds}')"
  if [[ $(sha256sum <"$P/.config/lianli/config.json") == "$sha0" && $(grep -c GetTelemetry "$P/reads.log") -ge 2 && $(grep -c CheckMediaAccess "$P/reads.log") == 1 ]]; then
    ok "screens: one CheckMediaAccess, a telemetry baseline and follow-ups (read-only); config.json untouched by the preview"
  else bad "screens: reads $(tr '\n' ' ' <"$P/reads.log")"; fi
  n=$(reqs)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  if [[ $(reqs) == "$n" ]]; then ok "screens: the same rev again sends nothing"; else bad "screens: the same rev sent $(( $(reqs) - n ))"; fi
  draft '.screens["screen.pump"].brightness = 55'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "screens: a brightness edit alone: one SetLcdBrightness, no reload, no RGB re-send" \
    '. == [{method: "SetLcdBrightness", params: {device_id: "hid:1cbe:a068:8-7.2.2", brightness: 55}}]' "$out"
  n=$(reqs)
  draft '.screens["screen.fan"][1].path = "media/other-fan.mp4"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "screens, method effect: a new clip on fan 2, then the reload's saved RGB sent over again in full" \
    '.[0].method == "SetLcdMedia" and .[0].params.device_id == "serial:hid:1cbe:a018:8-12.2.2" and (.[0].params.config.path | endswith("/other-fan.mp4"))
     and ([.[1:][] | .method] | unique) == ["SetRgbEffect"] and (.[1:] | length) == 10' "$out"
  # the telemetry: failed and off USB
  printf '%s\n' "serial:hid:1cbe:a018:8-12.2.2 failed Media preparation failed: could not decode" "serial:hid:1cbe:a018:8-12.2.3 waiting_for_device" >"$P/telemetry-states"
  draft '.screens["screen.fan"][1].path = "media/new-fan.mp4" | .screens["screen.fan"][2].path = "media/other-fan.mp4"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jcheck "screens: the telemetry maps failed (with the daemon's error) and waiting_for_device (off-usb)" \
    '.screens.roles["screen.fan2"].state == "failed" and (.screens.roles["screen.fan2"].error | test("could not decode"))
     and .screens.roles["screen.fan3"].state == "off-usb" and .screens.failed == [{role: "screen.fan2", error: .screens.roles["screen.fan2"].error}]' "$(pv)"
  rm -f "$P/telemetry-states"
  # the daemon can't read a file: that screen is left as it is
  echo "$C/themes/calm/media/saved-fan.mp4" >"$P/deny-media"
  n=$(reqs)
  draft '.screens["screen.fan"][0].path = "media/saved-fan.mp4"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "screens: CheckMediaAccess refuses a file: no SetLcdMedia for it, the role failed (access)" \
    '([.r[] | select(.method == "SetLcdMedia")] == []) and (.s.screens.roles["screen.fan1"] | .state == "failed" and .reason == "access" and (.error | test("Permission denied")))' \
    "$(jq -nc --argjson r "$out" --argjson s "$(pv)" '{r: $r, s: $s}')"
  rm -f "$P/deny-media"
  # a role that loses its entry gets its saved entry back
  n=$(reqs)
  draft 'del(.screens["screen.pump"])'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "screens: the pump's entry gone: its saved brightness back (the daemon default)" \
    '[.[] | select(.params.device_id | tostring | test("8-7\\.2\\.2"))] == [{method: "SetLcdBrightness", params: {device_id: "hid:1cbe:a068:8-7.2.2", brightness: 100}}]' "$out"
  # the end: screens first (the saved entries, byte for byte), then the lights
  n=$(reqs)
  rc=0; pcl theme preview --end --json >/dev/null 2>&1 || rc=$?
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "end: SetLcdMedia(saved entry, byte for byte) where the media was touched, SetLcdBrightness where only the brightness was" \
    '(.l | map({key: .serial, value: .}) | from_entries) as $l
     | [.r[] | select(.method == "SetLcdMedia")] as $m | ([$m[].params.device_id] | sort) == ["serial:hid:1cbe:a018:8-12.2.1", "serial:hid:1cbe:a018:8-12.2.2", "serial:hid:1cbe:a018:8-12.2.3"]
     and all($m[]; .params.config == $l[.params.device_id | ltrimstr("serial:")])
     and [.r[] | select(.method == "SetLcdBrightness")] == [{method: "SetLcdBrightness", params: {device_id: "hid:1cbe:a068:8-7.2.2", brightness: 100}}]' \
    "$(jq -nc --argjson r "$out" --slurpfile c "$P/.config/lianli/config.json" '{r: $r, l: $c[0].lcds}')"
  jcheck "end: screens before lights" '(map(.method | startswith("SetLcd")) | index(false)) as $i | $i != null and all(.[:$i][]; .method | startswith("SetLcd")) and all(.[$i:][]; .method == "SetRgbEffect")' "$out"
  jcheck "end: ended, lights and screens reverted" '.state == "ended" and .ended.reverted and .ended.screens_reverted == true' "$(pv)"
  if [[ ! -e $K/preview/saved-lcds.json && ! -e $K/preview/touched-lcds.json && ! -e $K/preview/applied-lcds.json ]]; then ok "end: the screens' state files are gone"
  else bad "end: screens state files left: $(ls "$K/preview")"; fi
  # the yields
  draft '.screens["screen.pump"] = {type: "video", path: "media/pump.mp4", brightness: 40, model: "HydroShift2OledCurveLcd"}'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs)
  pcl pick other >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "pick during a preview: the screens reverted first, then the lights, then the apply" \
    '(map(.stub == "lianli_lights on") | index(true)) as $a | (map(.method == "SetRgbEffect") | index(true)) as $r
     | ([.[:$r][] | .method] | unique) == ["SetLcdBrightness", "SetLcdMedia"] and $r < $a' "$out"
  echo calm >"$C/scheme"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs)
  pcl off lights >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "off lights during a preview: the screens reverted, no lights revert, then Off" \
    '([.[] | .method // .stub] | unique) == ["SetLcdBrightness", "SetLcdMedia", "lianli_lights off"] and .[-1].stub == "lianli_lights off"' "$out"
  jcheck "... ended lights-off: reverted false, screens_reverted true" '.ended.reason == "lights-off" and .ended.reverted == false and .ended.screens_reverted' "$(pv)"
  echo on >"$C/lights"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs); : >"$P/stub.log"
  pcl off screens >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "off screens during a preview: ended screens-off, everything sent back (screens first)" \
    '.state == "ended" and .ended.reason == "screens-off" and .ended.by.op == "off" and .ended.reverted and .ended.screens_reverted' "$(pv)"
  if jq -e '.[0].method | startswith("SetLcd")' >/dev/null 2>&1 <<<"$out" && grep -q 'lianli_screens off' "$P/stub.log"; then ok "off screens: the screens revert before the screens off"
  else bad "off screens: the order" "$out"; fi
  echo on >"$C/screens"
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  pcl on screens >/dev/null 2>&1 || true
  jcheck "on screens during a preview: cancelled by on, reverted" '.ended.reason == "cancelled" and .ended.by.op == "on" and .ended.reverted and .ended.screens_reverted' "$(pv)"
  echo off >"$C/screens"
  draft '.screens["screen.pump"].brightness = 45'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jcheck "screens off: the screens part skipped (screens-off), the lights previewed" '.screens.state == "skipped" and .screens.reason == "screens-off" and .state == "live"' "$(pv)"
  if [[ ! -e $K/preview/touched-lcds.json ]]; then ok "screens off: no screen touched"; else bad "screens off: a screen was touched"; fi
  pcl theme preview --end >/dev/null 2>&1 || true
  echo on >"$C/screens"
  # a save that applies: no revert (its pick rewrites the screens), the state dropped
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  n=$(reqs)
  PV_CALL='preview_yield saved calm --no-revert' pcl status >/dev/null 2>&1 || true
  if [[ $(reqs) == "$n" && ! -e $K/preview/touched-lcds.json ]] && jq -e '.ended.reason == "saved" and .ended.reverted == false and .ended.screens_reverted == null' "$K/preview.json" >/dev/null; then
    ok "saved + apply: nothing sent back, the screens' state dropped"
  else bad "saved + apply" "$(pv)"; fi
  # a screens revert that fails keeps its snapshot; the next tick sends it
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  echo "the daemon is busy" >"$P/daemon-error"
  pcl theme preview --end >/dev/null 2>&1 || true
  jcheck "a failed screens revert: ended, screens_reverted false, the error kept" '.state == "ended" and .ended.screens_reverted == false and (.error | test("saved screens"))' "$(pv)"
  if [[ -s $K/preview/saved-lcds.json && -s $K/preview/touched-lcds.json ]]; then ok "... its saved-lcds.json and touched-lcds.json are kept"
  else bad "... the screens state was dropped"; fi
  rm -f "$P/daemon-error"; n=$(reqs)
  pcl clips tick >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  if jq -e 'length > 0 and all(.[]; .method | startswith("SetLcd"))' >/dev/null 2>&1 <<<"$out" && [[ ! -e $K/preview/touched-lcds.json ]]; then
    ok "the clip tick (lock held) sends the saved screens back and drops the state"
  else bad "the tick did not retry the screens revert" "$out"; fi
  # the reaper: ui-gone reverts the screens too
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  jq '.touched -= 100' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  n=$(reqs)
  pcl theme preview --reap >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "reap ui-gone: the screens reverted first, then the lights" '.[0].method | startswith("SetLcd")' "$out"
  jcheck "... ended ui-gone, screens reverted" '.ended.reason == "ui-gone" and .ended.screens_reverted' "$(pv)"
  # method rgbconfig: the screens, then the rgb section
  echo rgbconfig >"$C/preview-method"
  n=$(reqs)
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  out=$(tail -n +$((n + 1)) "$P/requests.jsonl" | jq -sc .)
  jcheck "rgbconfig: the screens first, then one SetRgbConfig (no wait for their reload)" \
    '([.[] | .method] | index("SetRgbConfig")) as $i | $i != null and $i > 0 and all(.[:$i][]; .method | startswith("SetLcd"))' "$out"
  pcl theme preview --end >/dev/null 2>&1 || true
  echo effect >"$C/preview-method"
  # a worker stopped while it follows the telemetry
  rm -f "$P/telemetry-after-writes"
  draft '.screens["screen.fan"][0].path = "media/other-fan.mp4"'
  pcl theme preview calm --rev "$(rev)" --json >/dev/null 2>&1 || true
  pcl theme preview --end >/dev/null 2>&1 || true
  draft '.screens["screen.fan"][0].path = "media/new-fan.mp4"'
  jq --argjson r "$(rev)" --argjson now "$EPOCHSECONDS" '.state = "queued" | .ended = null | .worker = true | .want_rev = $r
    | .touched = $now | .edited = $now | .idle_ends = $now + 600' "$K/preview.json" >"$K/p.tmp" && mv "$K/p.tmp" "$K/preview.json"
  rm -f "$K/busy.json" "$K/last-run.json"
  setsid bash -c "HOME='$P' PCL_TEST_OVERRIDES='$here/stubs.sh' PCL_PV_SCREEN_WAIT=20 '$engine' theme preview --run" >/dev/null 2>&1 & pid=$!; disown
  wait_state 10 '.screens.roles["screen.fan1"].state == "sent"' || true
  sleep 0.5
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..60}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then bad "worker SIGTERM while following: still running"; kill -9 -- "-$pid" 2>/dev/null || true
  else ok "worker SIGTERM while following the telemetry: it stops at once"; fi
  pid=
  jcheck "... a consistent session: live, worker false, the screen still sent" '.state == "live" and .worker == false and (.error | test("SIGTERM"))
    and .screens.roles["screen.fan1"].state == "sent"' "$(pv)"
  if [[ ! -e $K/busy.json && ! -e $K/last-run.json ]]; then ok "screens: the preview never writes busy.json or last-run.json"
  else bad "screens: run bookkeeping written"; fi
  pcl theme preview --end >/dev/null 2>&1 || true
  jq '.lcds = []' "$P/.config/lianli/config.json" >"$P/cfg.tmp" && mv "$P/cfg.tmp" "$P/.config/lianli/config.json"
  draft 'del(.screens)'
  rm -f "$K/preview.json" "$P/usbmap.json"; rm -rf "$K/preview"; echo calm >"$C/scheme"; echo on >"$C/lights"

  # ---- real transient units: the worker and the reap timer -------------------------------
  if systemctl --user is-system-running >/dev/null 2>&1 || systemctl --user list-units >/dev/null 2>&1; then
    rc=0; out=$(pcl_units theme preview calm --rev "$(rev)" --json 2>/dev/null) || rc=$?
    if (( rc == 0 )) && wait_state 15 '.state == "live" and .worker == false'; then
      ok "units: the worker ran in its own transient unit ($unit-w*) and went live"
    else bad "units: worker unit: exit $rc $out" "$(pv)"; fi
    if systemctl --user is-active -q "$unit-reap.timer"; then ok "units: the reap timer runs while the session lasts"
    else bad "units: no reap timer $unit-reap.timer"; fi
    rc=0; pcl_units theme preview --end --json >/dev/null 2>&1 || rc=$?
    if wait_state 15 '.state == "ended" and .ended.reverted'; then ok "units: --end queued to a worker unit, reverted"
    else bad "units: --end did not end the session" "$(pv)"; fi
  else
    ok "units: skipped (no user systemd)"
  fi
  pv_cleanup
}
