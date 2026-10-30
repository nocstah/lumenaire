# lib/pc-lights/preview.sh — the theme editor's live preview: show a draft on the case without saving it
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: editor plan §5 row B (engine preview + core); the screens part:
#         screens plan §8 row B2
# Public: preview_cmd preview_yield preview_live preview_open preview_method
#         preview_reap_locked; constants PREVIEW_FILE PREVIEW_LOCK PREVIEW_DIR
#         PREVIEW_UNIT PREVIEW_HEARTBEAT_TTL PREVIEW_IDLE_TTL
# Uses (builder A, lib/pc-lights/editor.sh): editor_draft_file editor_draft_rev
#         editor_draft_eff editor_draft_problems editor_draft_abspath (stand-ins
#         that die "not implemented" are defined below while editor.sh doesn't
#         provide them); lianli_screen_plan (backend-lianli.sh)
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154,SC2016
#
# How it works (docs/ENGINE.md "Theme preview", editor plan §1.5-§1.6):
# "theme preview <name>" records the wanted draft rev in the session file
# $CACHE/preview.json and starts a worker (a transient unit), which takes the
# main lock for one pass at a time (never queueing behind an apply: 3 s, then
# "blocked"), builds the draft's Lian Li devices with the very jq an apply
# uses and sends only what changed as SetRgbEffect (method "effect": not
# persisted, so a daemon restart brings the saved look back) or a
# SetRgbConfig of the rgb section (method "rgbconfig": persisted, so the
# saved section is kept and must be sent back). GPU, board and RAM follow
# through one OpenRGB call with the cached RAM ids, only when they changed.
# Nothing here writes busy.json or last-run.json. The method is chosen by the
# one-time hardware check (tests/preview/measure.sh): $STATE_DIR/preview-method
# or the profile's preview.method; with neither, preview refuses ("unmeasured").
#
# The screens (screens plan §3): each pass first sends what the draft's
# screens show differently (lianli_screen_plan): a guarded SetLcdMedia per
# screen whose media changed ("serial:<config serial>"; persisted by the
# daemon, a config reload) or a SetLcdBrightness for a brightness alone (the
# bare config serial; not persisted). The config entry of each screen is
# snapshotted the first time the session touches it (saved-lcds.json, beside
# saved-rgb.json), and the end sends it back, screens before lights before
# OpenRGB. A failed screens revert keeps its snapshot, and the schedule and
# clip ticks try again (preview_reap_locked). After the pass, the worker
# follows the daemon's telemetry (unlocked, read-only) until each screen
# reports ready, failed or off USB. Under method effect a screens reload
# re-sends the saved RGB, so the Lian Li part then re-sends every device it
# had sent.
#
# The session file (contract v1.2; also "preview" in status --json):
#   {v: 1, id, theme, draft, state: queued|applying|live|blocked|ending|ended|failed,
#    worker, method: effect|rgbconfig, want_rev, applied_rev,
#    lianli: {state: ok|failed|skipped|null, sent, failed: [{device_id, error}], at, ms},
#    openrgb: {state: idle|pending|applying|ok|failed|skipped, rev, at, ms},
#    screens: {state: idle|sending|live|failed|skipped, reason, sent, at, ms,
#              roles: {<role>: {state: sent|preparing|ready|failed|skipped|off-usb,
#                               what: media|brightness, error, reason, gen0, since}},
#              failed: [{role, error}]},
#    blocked_by: null | {op, theme, unit} | "heat-alert" | "rgb-sync" | "invalid",
#    started, touched, edited, heartbeat_ttl, idle_ttl, idle_ends,
#    ending: null | {reason, by, revert},      (an end that waits for the worker)
#    ended: null | {at, reason, by: {op, theme} | null, reverted, screens_reverted},
#    error: null | string}
# ended.reason: saved reverted panel-closed closed idle ui-gone cancelled lights-off
#   screens-off.
# ended.by.op (reason cancelled): pick schedule omarchy on apply-openrgb.
# ended.reverted: the lights were sent back; screens_reverted: the screens
#   were (null: the session touched none).
# The applied state ($CACHE/preview/): applied-rgb.json touched.json
#   applied-orgb.args saved-rgb.json (lights); saved-lcds.json {config serial:
#   entry at first touch}, applied-lcds.json {config serial: entry last sent},
#   touched-lcds.json {config serial: {role, media}} (screens).

PREVIEW_FILE=$CACHE/preview.json
PREVIEW_LOCK=$CACHE/preview.lock
PREVIEW_DIR=$CACHE/preview
PREVIEW_UNIT=${PCL_PREVIEW_UNIT:-lumenaire-preview}
PREVIEW_HEARTBEAT_TTL=90
PREVIEW_IDLE_TTL=600
# How long the worker follows the daemon's telemetry after sending screens
# (the pump's transcode takes longer).
PV_SCREEN_WAIT=${PCL_PV_SCREEN_WAIT:-20}
PV_SCREEN_WAIT_PUMP=${PCL_PV_SCREEN_WAIT_PUMP:-45}
# Set by a pass: SetLcdMedia requests the daemon took (each a config reload).
SCREENS_MEDIA_SENT=0
# Set while this process holds the main lock (take_lock, the clip tick's
# flock -n, a worker pass): preview_yield reverts at once instead of queueing.
LOCK_HELD=

# ---- builder A's draft functions: stand-ins until editor.sh defines them ------
PCL_EDITOR_STUBBED=
if ! declare -F editor_cmd >/dev/null; then
  PCL_EDITOR_STUBBED=1
  editor_cmd() { die "theme ${1:-}: the theme editor is not installed (lib/pc-lights/editor.sh): not implemented"; }
fi
if ! declare -F editor_draft_file >/dev/null; then PCL_EDITOR_STUBBED=1; editor_draft_file() { die "editor_draft_file: not implemented"; }; fi
if ! declare -F editor_draft_rev >/dev/null; then PCL_EDITOR_STUBBED=1; editor_draft_rev() { die "editor_draft_rev: not implemented"; }; fi
if ! declare -F editor_draft_eff >/dev/null; then PCL_EDITOR_STUBBED=1; editor_draft_eff() { die "editor_draft_eff: not implemented"; }; fi
if ! declare -F editor_draft_problems >/dev/null; then PCL_EDITOR_STUBBED=1; editor_draft_problems() { die "editor_draft_problems: not implemented"; }; fi
if ! declare -F editor_media_root >/dev/null; then PCL_EDITOR_STUBBED=1; editor_media_root() { die "editor_media_root: not implemented"; }; fi
if ! declare -F editor_draft_abspath >/dev/null; then PCL_EDITOR_STUBBED=1; editor_draft_abspath() { die "editor_draft_abspath: not implemented"; }; fi

# ---- the session file ------------------------------------------------------------
# pv_edit [jq args...] <filter>: rewrite preview.json under preview.lock
# (tmp + mv); 1 when there is no session or the filter failed.
pv_edit() {
  (
    # (a name set here: $BASHPID in a redirection would expand in jq's own process)
    t=$PREVIEW_FILE.$BASHPID.tmp
    flock -w 5 6 || exit 1
    [[ -f $PREVIEW_FILE ]] || exit 1
    jq -c --argjson now "$EPOCHSECONDS" "$@" "$PREVIEW_FILE" >"$t" && [[ -s $t ]] && mv -f "$t" "$PREVIEW_FILE"
    rc=$?
    rm -f "$t"
    exit "$rc"
  ) 6>"$PREVIEW_LOCK"
}
# pv_upd <id> [jq args...] <filter>: pv_edit, only while the session is still
# <id> and not ended (a late worker write never revives an ended session).
pv_upd() {
  local id=$1 f=${*: -1}
  pv_edit --arg pvid "$id" "${@:2:$#-2}" "if .id == \$pvid and .state != \"ended\" then ($f) else . end"
}
# pv_get <jq expr>: one raw value from the session ("" when there is none).
pv_get() { jq -r "$1 // empty" "$PREVIEW_FILE" 2>/dev/null || true; }

# A session that isn't over (it may still be showing a draft).
preview_open() {
  [[ -f $PREVIEW_FILE ]] || return 1
  jq -e '.state != "ended"' "$PREVIEW_FILE" >/dev/null 2>&1
}
# A session the UI keeps alive: queued, applying, live or blocked, with a
# heartbeat inside heartbeat_ttl and an edit inside idle_ttl. No file = no
# jq at all (every hook below is a no-op without a session).
preview_live() {
  [[ -f $PREVIEW_FILE ]] || return 1
  jq -e --argjson now "$EPOCHSECONDS" '
    (.state | IN("queued", "applying", "live", "blocked"))
    and ($now - (.touched // 0)) <= (.heartbeat_ttl // 90)
    and ($now - (.edited // .touched // 0)) <= (.idle_ttl // 600)' "$PREVIEW_FILE" >/dev/null 2>&1
}

# The measured preview method: $STATE_DIR/preview-method, else the profile's
# preview.method. Nothing measured: return 1.
preview_method() {
  local m='' pf
  if [[ -f $STATE_DIR/preview-method ]]; then read -r m <"$STATE_DIR/preview-method" || true; fi
  if [[ ! $m =~ ^(effect|rgbconfig)$ ]] && pf=$(be_profile); then
    m=$(jq -r '.preview.method // empty' "$pf" 2>/dev/null || true)
  fi
  [[ $m =~ ^(effect|rgbconfig)$ ]] || return 1
  echo "$m"
}

# pv_fail <exit> <code> <message> [problems]: the CLI's error answer (stderr,
# plus {"error", "code", "problems"?} on stdout with --json), then exit.
PV_JSON=
pv_fail() {
  echo "pc-lights: $3" >&2
  if [[ -n $PV_JSON ]]; then
    jq -nc --arg e "$3" --arg c "$2" --arg p "${4:-}" '{error: $e, code: $c}
      + (if $p == "" then {} else {problems: [$p | split("\n")[] | select(length > 0) | {level: "error", message: .}]} end)'
  fi
  exit "$1"
}

# ---- units -------------------------------------------------------------------------
# The worker runs in its own transient unit (a unique name, so a new one never
# collides with one that is still exiting). KillMode=mixed: a stop sends
# SIGTERM to the worker only, which lets a running openrgb finish (it is
# never killed: the ENE RAM/SMBus risk). PCL_PREVIEW_INLINE=1 (tests) runs it
# in this process instead.
preview_start_worker() {
  local extra=()
  if [[ -n ${PCL_PREVIEW_INLINE:-} ]]; then (preview_run) || true; return 0; fi
  if [[ -n ${PCL_TEST_OVERRIDES:-} ]]; then extra=(--setenv=PCL_TEST_OVERRIDES="$PCL_TEST_OVERRIDES"); fi
  systemd-run --user --quiet --collect --unit="$PREVIEW_UNIT-w$(date +%s%N)" -p KillMode=mixed -p TimeoutStopSec=150 \
    --setenv=HOME="$HOME" --setenv=PCL_PREVIEW_UNIT="$PREVIEW_UNIT" "${extra[@]}" \
    -- "$(readlink -f "$0")" theme preview --run
}
preview_start_reaper() {
  local extra=()
  [[ -z ${PCL_PREVIEW_INLINE:-} ]] || return 0
  if [[ -n ${PCL_TEST_OVERRIDES:-} ]]; then extra=(--setenv=PCL_TEST_OVERRIDES="$PCL_TEST_OVERRIDES"); fi
  systemd-run --user --quiet --collect --unit="$PREVIEW_UNIT-reap" --on-active=30s --on-unit-active=30s \
    --setenv=HOME="$HOME" --setenv=PCL_PREVIEW_UNIT="$PREVIEW_UNIT" "${extra[@]}" \
    -- "$(readlink -f "$0")" theme preview --reap >/dev/null 2>&1 || true
}
preview_stop_reaper() { systemctl --user stop "$PREVIEW_UNIT-reap.timer" >/dev/null 2>&1 || true; }

# ---- the Lian Li and OpenRGB passes --------------------------------------------------
# pv_wait_reload <since>: the daemon applied a persisted write (up to 8 s;
# never a restart). The journal is read first, then grepped (a grep -q in a
# pipe under pipefail can SIGPIPE journalctl into a false "no").
pv_wait_reload() {
  local since=$1 w=0 j
  while :; do
    j=$(journalctl --user -u lianli-daemon --since "$since" --no-pager 2>/dev/null || true)
    grep -q 'Config reload triggered via IPC' <<<"$j" && return 0
    (( w >= 8 )) && return 1
    sleep 1; w=$((w + 1))
  done
}

# pv_send_rgbconfig <rgb.json>: a guarded SetRgbConfig of that rgb section,
# then wait for the reload (method rgbconfig).
pv_send_rgbconfig() {
  local since
  jq -c '{method: "SetRgbConfig", params: {config: .}}' "$1" >"$TMP/pv-rgbcfg.json" || return 1
  since=$(date '+%Y-%m-%d %H:%M:%S')
  daemon_guarded "$TMP/pv-rgbcfg.json" || return 1
  pv_wait_reload "$since" || log "preview: lianli-daemon took the rgb section but no reload showed within 8 s"
  return 0
}

# The saved look for the devices the session touched, sent back. Method
# effect: every zone/region of each touched device from CFG_LIVE. Method
# rgbconfig: the rgb section saved when the session began. 1 when some
# device didn't take it (LIVE_ERR says why).
pv_revert_lianli() {
  local method=$1 errs
  LIVE_ERR=
  if [[ $method == rgbconfig ]]; then
    [[ -f $PREVIEW_DIR/saved-rgb.json ]] || return 0
    pv_send_rgbconfig "$PREVIEW_DIR/saved-rgb.json"
    return
  fi
  [[ -s $PREVIEW_DIR/touched.json ]] || return 0
  jq --slurpfile t "$PREVIEW_DIR/touched.json" '[.rgb.devices // [] | .[] | select(.device_id as $d | $t[0] | index($d))]' \
    "$CFG_LIVE" >"$TMP/pv-revert-dev.json" || { LIVE_ERR="could not read $CFG_LIVE"; return 1; }
  lianli_effect_requests "$TMP/pv-revert-dev.json" /dev/null >"$TMP/pv-revert.jsonl" || return 1
  daemon_guarded_batch "$TMP/pv-revert.jsonl" "$TMP/pv-revert-res.jsonl" || return 1
  errs=$(jq -rs '[.[] | select(.ok | not) | "\(.device_id): \(.error)"] | unique | join("; ")' "$TMP/pv-revert-res.jsonl")
  [[ -z $errs ]] || { LIVE_ERR=$errs; return 1; }
}

# The active theme's GPU, board and RAM, back (only when the session showed
# a draft's). The lock is held.
pv_revert_openrgb() {
  local eff
  [[ -f $PREVIEW_DIR/applied-orgb.args ]] || return 0
  backend_skipped openrgb && return 0
  [[ $(lights_state) == on ]] || return 0
  eff=$( (THEME=; scheme_file) 2>/dev/null ) || { log "preview: could not build the active theme to restore OpenRGB"; return 1; }
  ( openrgb_preview_args "$eff" ) >"$TMP/pv-orgb-revert.args" 2>/dev/null || return 1
  be_openrgb_preview "$eff" "$TMP/pv-orgb-revert.args" || { log "preview: OpenRGB did not take the saved look back"; return 1; }
  ram_drift_resume "$eff"
}

# ---- the screens part (screens plan §3) ----------------------------------------------
# pv_telemetry: {"serial:<config serial>": {generation, state, error}} from one
# read-only GetTelemetry ({} when the daemon doesn't answer).
pv_telemetry() {
  daemon_call '{"method":"GetTelemetry"}' 2>/dev/null | jq -c '
    [(.data.media_preparation // {}) | .[]? | objects | select(.device_id | type == "string")
     | {key: .device_id, value: {generation: (.generation // -1), state: (.state // null),
                                 error: (.error // .last_playback_error // null)}}] | from_entries' 2>/dev/null || echo '{}'
}
# pv_check_access <plan.json>: {<config serial>: error} for the media the
# daemon can't read (one read-only CheckMediaAccess of the media configs the
# plan sends; {} when the check can't run: it is optional).
pv_check_access() {
  local resp
  jq -c --slurpfile tp <(cat "$TPL_LIVE" 2>/dev/null || echo '{}') '
    [.screens[] | select(.what == "media") | .want] as $l | ([$l[] | .template_id | strings]) as $ids
    | {method: "CheckMediaAccess", params: {lcds: $l,
         templates: [($tp[0].templates // [])[]? | select(.id as $i | $ids | index($i))]}}' "$1" >"$TMP/pv-access.json" || { echo '{}'; return 0; }
  jq -e '.params.lcds | length > 0' "$TMP/pv-access.json" >/dev/null 2>&1 || { echo '{}'; return 0; }
  resp=$(timeout 10 socat -t 8 - "UNIX-CONNECT:$SOCK" <"$TMP/pv-access.json" 2>/dev/null | head -n1) || resp=
  jq -c 'if .status == "ok" then
      [(.data.issues // [])[] | objects | (.owner // "" | capture("^LCD\\[serial:(?<s>[^\\]]*)\\]").s) as $cs
       | {key: $cs, value: ("\(.error)" + (if .path then " (\(.path))" else "" end))}] | from_entries
    else {} end' <<<"$resp" 2>/dev/null || echo '{}'
}
# pv_screens_pass <id> <eff> <draft name>: the screens part of one pass (the
# lock is held; it runs before the Lian Li lights, whose reload it would
# otherwise undo under method effect). Sets SCREENS_MEDIA_SENT. Never fails
# the pass: a screen that doesn't take its media is listed in screens.roles.
pv_screens_pass() {
  local id=$1 eff=$2 theme=$3 reason='' t0 ms n rc=0 tel acc
  local plan=$TMP/pv-scr-plan.json reqs=$TMP/pv-scr-reqs.jsonl res=$TMP/pv-scr-res.jsonl
  SCREENS_MEDIA_SENT=0
  if [[ $(screens_state) != on ]]; then reason=screens-off
  elif backend_skipped lianli; then reason=lianli-skipped
  elif ! be_profile >/dev/null; then reason=no-profile
  elif ! systemctl --user is-active -q lianli-daemon; then reason=lianli-down; fi
  if [[ -n $reason ]]; then
    pv_upd "$id" --arg r "$reason" '.screens = ((.screens // {}) + {state: "skipped", reason: $r, at: $now})' || true
    return 0
  fi
  t0=${EPOCHREALTIME/./}
  mkdir -p "$PREVIEW_DIR"
  if ! ( lianli_screen_plan "$eff" "$theme" "$plan" "$reqs" "$PREVIEW_DIR" ) 2>"$TMP/pv-scr.err"; then
    pv_upd "$id" --arg e "screens: $(tail -n1 "$TMP/pv-scr.err" | sed 's/^pc-lights: //')" \
      '.screens = ((.screens // {}) + {state: "failed", at: $now}) | .error = $e' || true
    return 0
  fi
  n=$(grep -c . "$reqs" || true)
  : >"$res"
  acc='{}' tel='{}'
  if (( n > 0 )); then
    # 1. the saved entry of every screen touched for the first time
    jq -n --slurpfile p "$plan" --slurpfile c "$CFG_LIVE" --slurpfile s <(cat "$PREVIEW_DIR/saved-lcds.json" 2>/dev/null || echo '{}') '
      ($s[0] | objects // {}) as $s
      | $s + ([$p[0].screens[] | select(.what == "media" or .what == "brightness") | .cs as $cs | select($s[$cs] == null)
               | {($cs): (first($c[0].lcds[]? | select(.serial == $cs)) // null)}] | add // {})
      | with_entries(select(.value != null))' | put_json "$PREVIEW_DIR/saved-lcds.json"
    # 2. can the daemon read the new media? (a screen it can't is left as it is)
    acc=$(pv_check_access "$plan")
    if [[ $acc != '{}' ]]; then
      jq --argjson a "$acc" '.screens |= map(if .what == "media" and $a[.cs] != null then .what = "denied" | .reason = "access" | .error = $a[.cs] else . end)' \
        "$plan" >"$plan.tmp" && mv -f "$plan.tmp" "$plan"
      jq -c '.screens[] | select(.what == "media" or .what == "brightness")
        | if .what == "media" then {method: "SetLcdMedia", params: {device_id: ("serial:" + .cs), config: .want}}
          else {method: "SetLcdBrightness", params: {device_id: .cs, brightness: (.want.brightness // 100)}} end' "$plan" >"$reqs"
      n=$(grep -c . "$reqs" || true)
    fi
  fi
  if (( n > 0 )); then
    # 3. the telemetry generations before; the screens marked touched before
    # anything is sent (a crash mid-batch still gets them sent back);
    # 4. the batch (one guard read)
    tel=$(pv_telemetry)
    jq -n --slurpfile p "$plan" --slurpfile tc <(cat "$PREVIEW_DIR/touched-lcds.json" 2>/dev/null || echo '{}') '
      ($tc[0] | objects // {}) as $tc
      | $tc + ([$p[0].screens[] | select(.what == "media" or .what == "brightness")
                | {(.cs): {role: (.role // $tc[.cs].role // null), media: (($tc[.cs].media // false) or .what == "media")}}] | add // {})' |
      put_json "$PREVIEW_DIR/touched-lcds.json"
    pv_upd "$id" '.screens = ((.screens // {}) + {state: "sending"})' || true
    daemon_guarded_batch "$reqs" "$res" || rc=1
  fi
  ms=$(( (${EPOCHREALTIME/./} - t0) / 1000 ))
  # 5. what reached the case: applied-lcds (what each screen shows now),
  # touched-lcds (what the end sends back), the session's screens part.
  jq -n --slurpfile p "$plan" --rawfile r "$res" --argjson tel "$tel" --argjson tr "$([[ $rc == 0 ]] && echo true || echo false)" \
    --arg terr "${LIVE_ERR:-}" --argjson now "$EPOCHSECONDS" \
    --slurpfile ap <(cat "$PREVIEW_DIR/applied-lcds.json" 2>/dev/null || echo '{}') \
    --slurpfile tc <(cat "$PREVIEW_DIR/touched-lcds.json" 2>/dev/null || echo '{}') '
    ([$p[0].screens[] | select(.what == "media" or .what == "brightness")]) as $sent
    | ($r | split("\n") | map(select(length > 0) | fromjson)) as $res
    | [range(0; $sent | length) as $i | $sent[$i] + {ok: ($res[$i].ok // false),
         err: (if $tr then ($res[$i].error // (if $res[$i] == null then "no reply from lianli-daemon" else null end))
               else "lianli-daemon did not answer (\($terr))" end)}] as $done
    | ($ap[0] | objects // {}) as $ap | ($tc[0] | objects // {}) as $tc
    | {applied: ($ap + ([$done[] | select(.ok) | {(.cs): .want}] | add // {})),
       touched: ($tc + ([$done[] | {(.cs): {role: (.role // $tc[.cs].role // null), media: (($tc[.cs].media // false) or .what == "media")}}] | add // {})),
       roles: ([$p[0].screens[] | select(.what != "none") | (.role // .cs) as $k | . as $s
                | ([$done[] | select(.cs == $s.cs)] | first) as $d
                | {($k): (if $s.what == "skip" then {state: "skipped", what: "media", error: null, reason: $s.reason, gen0: null, since: $now}
                          elif $s.what == "denied" then {state: "failed", what: "media", error: $s.error, reason: "access", gen0: null, since: $now}
                          elif ($d.ok // false) | not then {state: "failed", what: $s.what, error: ($d.err // "not sent"), reason: null, gen0: null, since: $now}
                          elif $s.what == "brightness" then {state: "ready", what: "brightness", error: null, reason: null, gen0: null, since: $now}
                          else {state: "sent", what: "media", error: null, reason: null,
                                gen0: ($tel["serial:" + $s.cs].generation // null), since: $now} end)}] | add // {}),
       sent: ([$done[] | select(.ok)] | length), n: ($done | length),
       media_sent: ([$done[] | select(.ok and .what == "media")] | length)}' >"$TMP/pv-scr-out.json" || return 0
  jq '.applied' "$TMP/pv-scr-out.json" | put_json "$PREVIEW_DIR/applied-lcds.json"
  jq '.touched' "$TMP/pv-scr-out.json" | put_json "$PREVIEW_DIR/touched-lcds.json"
  [[ $(jq -c '.touched' "$TMP/pv-scr-out.json") != '{}' ]] || rm -f "$PREVIEW_DIR/touched-lcds.json" "$PREVIEW_DIR/applied-lcds.json"
  SCREENS_MEDIA_SENT=$(jq '.media_sent' "$TMP/pv-scr-out.json")
  pv_upd "$id" --slurpfile o "$TMP/pv-scr-out.json" --argjson ms "$ms" '
    $o[0] as $o | (.screens // {}) as $s
    | (($s.roles // {}) + $o.roles) as $roles
    | .screens = ($s + {state: (if $o.n > 0 and $o.sent == 0 then "failed" else "live" end), reason: null,
                        sent: $o.sent, at: $now, ms: $ms, roles: $roles,
                        failed: [$roles | to_entries[] | select(.value.state == "failed") | {role: .key, error: .value.error}]})' || true
  return 0
}
# pv_screens_follow <id>: after a pass (unlocked, read-only), the daemon's
# telemetry every 0.5 s until each screen sent new media reports ready,
# failed or off USB (PV_SCREEN_WAIT s, PV_SCREEN_WAIT_PUMP for the pump; on
# a timeout it stays "sent"). Stops early for a newer rev, an end or SIGTERM.
pv_screens_follow() {
  local id=$1 w=() wait end tel
  [[ -s $PREVIEW_DIR/touched-lcds.json && -f $PREVIEW_FILE ]] || return 0
  mapfile -t w < <(jq -r --slurpfile t "$PREVIEW_DIR/touched-lcds.json" '
    (.screens.roles // {}) | to_entries[] | select(.value.state | IN("sent", "preparing")) | select(.value.what == "media")
    | .key as $r | (first($t[0] | to_entries[] | select(.value.role == $r) | .key) // (if ($t[0] | has($r)) then $r else null end)) as $cs
    | select($cs != null) | "\($r)\t\($cs)\t\(.value.gen0 // -1)"' "$PREVIEW_FILE" 2>/dev/null || true)
  (( ${#w[@]} )) || return 0
  wait=$PV_SCREEN_WAIT
  if printf '%s\n' "${w[@]}" | grep -q '^screen\.pump'$'\t'; then wait=$PV_SCREEN_WAIT_PUMP; fi
  end=$(( EPOCHSECONDS + wait ))
  while (( EPOCHSECONDS < end )) && [[ -z ${PV_TERM:-} ]]; do
    jq -e --arg id "$id" '.id == $id and (.state | IN("live", "applying")) and (.want_rev // 0) <= (.applied_rev // -1)' \
      "$PREVIEW_FILE" >/dev/null 2>&1 || return 0
    tel=$(pv_telemetry)
    printf '%s\n' "${w[@]}" | jq -Rn --argjson tel "$tel" '
      [inputs | split("\t") | . as [$r, $cs, $g] | ($tel["serial:" + $cs] // null) as $t
       | select($t != null and ($t.generation // -1) > ($g | tonumber))
       | {($r): ({ready: {state: "ready", error: null}, failed: {state: "failed", error: ($t.error // "the screen could not play it")},
                  waiting_for_device: {state: "off-usb", error: null}, preparing: {state: "preparing", error: null}}[$t.state // ""]
                 // empty)}] | add // {}' >"$TMP/pv-follow.json"
    if [[ $(<"$TMP/pv-follow.json") != '{}' ]]; then
      pv_upd "$id" --slurpfile u "$TMP/pv-follow.json" '
        .screens.roles = ((.screens.roles // {}) | reduce ($u[0] | to_entries[]) as $x (.; .[$x.key] += $x.value))
        | .screens.failed = [.screens.roles | to_entries[] | select(.value.state == "failed") | {role: .key, error: .value.error}]' || true
      mapfile -t w < <(printf '%s\n' "${w[@]}" | jq -Rr --slurpfile u "$TMP/pv-follow.json" '
        split("\t") | select(($u[0][.[0]].state // "sent") | IN("sent", "preparing")) | join("\t")')
      (( ${#w[@]} )) || return 0
    fi
    sleep 0.5
  done
  return 0
}
# pv_revert_screens: the saved entry back on every screen the session
# touched: SetLcdMedia where the media changed, SetLcdBrightness where only
# the brightness did; one batch. The screens state files go once every screen
# took it; 1 (LIVE_ERR says why) and the files stay otherwise, so the ticks
# can try again.
pv_revert_screens() {
  local errs
  LIVE_ERR=
  [[ -s $PREVIEW_DIR/touched-lcds.json ]] || { rm -f "$PREVIEW_DIR"/applied-lcds.json "$PREVIEW_DIR"/saved-lcds.json; return 0; }
  jq -c --slurpfile s <(cat "$PREVIEW_DIR/saved-lcds.json" 2>/dev/null || echo '{}') '
    to_entries[] | .key as $cs | .value as $t | ($s[0][$cs] // null) as $sv | select($sv != null)
    | if $t.media then {method: "SetLcdMedia", params: {device_id: ("serial:" + $cs), config: $sv}}
      else {method: "SetLcdBrightness", params: {device_id: $cs, brightness: ($sv.brightness // 100)}} end' \
    "$PREVIEW_DIR/touched-lcds.json" >"$TMP/pv-scr-revert.jsonl" 2>/dev/null || { LIVE_ERR="could not read the saved screens"; return 1; }
  if [[ -s $TMP/pv-scr-revert.jsonl ]]; then
    daemon_guarded_batch "$TMP/pv-scr-revert.jsonl" "$TMP/pv-scr-revert-res.jsonl" || { LIVE_ERR=${LIVE_ERR:-transport}; return 1; }
    errs=$(jq -rs '[.[] | select(.ok | not) | "\(.device_id): \(.error)"] | unique | join("; ")' "$TMP/pv-scr-revert-res.jsonl")
    [[ -z $errs ]] || { LIVE_ERR=$errs; return 1; }
  fi
  rm -f "$PREVIEW_DIR"/touched-lcds.json "$PREVIEW_DIR"/applied-lcds.json "$PREVIEW_DIR"/saved-lcds.json
}
# pv_retry_screens: a session ended but its screens didn't take the saved
# entries back (the daemon was away): try again (the main lock is held).
pv_retry_screens() {
  [[ -s $PREVIEW_DIR/touched-lcds.json ]] || return 0
  preview_open && return 0
  systemctl --user is-active -q lianli-daemon 2>/dev/null || return 0
  if pv_revert_screens; then log "preview: the saved screens are back"
  else log "preview: the saved screens still didn't go back (${LIVE_ERR:-unknown}); the next tick tries again"; fi
  return 0
}

# preview_finish <reason> <by-json> <revert 1|""> <openrgb 1|""> [<screens 1|"">]:
# end the session now; the main lock is held. In this order: the screens the
# session touched get their saved entries back (<screens>, default 1), then
# the Lian Li lights unless <revert> is empty (off, a save that applies),
# then OpenRGB when <openrgb> too (the callers that apply OpenRGB themselves
# pass ""). Then state ended and the applied-state files are dropped (the
# screens' only once they are back). A save that applies (<revert> and
# <screens> empty) drops the screens' state as well: its pick rewrites them.
preview_finish() {
  local reason=$1 by=${2:-null} revert=${3:-} orgb=${4:-} scr=${5-1} id method reverted=false sr=null err='' theme
  preview_open || return 0
  id=$(pv_get .id) method=$(pv_get .method) theme=$(pv_get .theme)
  pv_upd "$id" '.state = "ending"' || true
  if [[ -n $scr && -s $PREVIEW_DIR/touched-lcds.json ]]; then
    if pv_revert_screens; then sr=true
    else sr=false err="the saved screens did not all go back: ${LIVE_ERR:-unknown}"; log "preview: $err (the next tick tries again)"; fi
  elif [[ -n $scr ]]; then
    pv_revert_screens || true   # nothing touched: only its leftovers go
  elif [[ -z $revert ]]; then
    rm -f "$PREVIEW_DIR"/touched-lcds.json "$PREVIEW_DIR"/applied-lcds.json "$PREVIEW_DIR"/saved-lcds.json
  fi
  if [[ -n $revert ]]; then
    if pv_revert_lianli "${method:-effect}"; then reverted=true
    else
      log "preview: the saved look did not reach every device: ${LIVE_ERR:-unknown}"
      err="${err:+$err; }the saved look did not reach every device: ${LIVE_ERR:-unknown}"
    fi
    if [[ -n $orgb ]]; then pv_revert_openrgb || true; fi
  fi
  pv_upd "$id" --arg reason "$reason" --argjson by "$by" --argjson rev "$reverted" --argjson sr "$sr" --arg err "$err" '
    .state = "ended" | .worker = false | .ending = null | .blocked_by = null
    | .ended = {at: $now, reason: $reason, by: $by, reverted: $rev, screens_reverted: $sr}
    | .error = (if $err == "" then .error else $err end)' || true
  rm -f "$PREVIEW_DIR"/applied-rgb.json "$PREVIEW_DIR"/applied-orgb.args "$PREVIEW_DIR"/touched.json "$PREVIEW_DIR"/saved-rgb.json
  preview_stop_reaper
  # A saved or discarded draft's staged media the screens no longer show.
  if [[ -n $theme ]] && declare -F ed_gc_draft >/dev/null; then ed_gc_draft "$theme" || true; fi
  local note=$reason
  if [[ $by != null ]]; then note+=" by $(jq -r '.op' <<<"$by")"; fi
  if [[ -n $revert ]]; then note+=", saved look sent back"; fi
  if [[ $sr == true ]]; then note+=", saved screens sent back"; fi
  log "preview: ended ($note)"
}

# preview_end_request <reason> <by-json> <revert 1|""> [<screens 1|"">]: an
# end that needs the lock, handed to the worker (it waits for the lock,
# however long an apply takes). The session reads "ending" until then.
preview_end_request() {
  local reason=$1 by=${2:-null} revert=${3:-} scr=${4-1} start
  start=$(
    exec 6>"$PREVIEW_LOCK"
    t=$PREVIEW_FILE.$BASHPID.tmp
    flock -w 5 6 || exit 1
    [[ -f $PREVIEW_FILE ]] || exit 0
    jq -c --argjson now "$EPOCHSECONDS" --arg reason "$reason" --argjson by "$by" --argjson rv "$([[ -n $revert ]] && echo true || echo false)" \
      --argjson sc "$([[ -n $scr ]] && echo true || echo false)" '
      if .state == "ended" then . else
        .start = (.worker != true) | .state = "ending" | .worker = true
        | .ending = {reason: $reason, by: $by, revert: $rv, screens: $sc} end' "$PREVIEW_FILE" >"$t" || exit 1
    jq -r '.start // false' "$t"
    jq -c 'del(.start)' "$t" | put_json "$PREVIEW_FILE"
    rm -f "$t"
  ) || return 1
  if [[ $start == true ]]; then
    preview_start_worker || { pv_edit '.worker = false | .error = "systemd-run could not start the preview worker"' || true; return 3; }
  fi
}

# preview_yield <op|reason> [theme] [--no-revert] [--openrgb]: something else
# takes the case over; end the session first. <op> is what takes over (pick,
# schedule, omarchy, on, off, apply-openrgb, screens-off): ended.reason
# "cancelled" with by {op, theme} ("off": "lights-off", "screens-off":
# "screens-off", both by {op: off}); its caller applies OpenRGB itself unless
# --openrgb ("on screens", "off screens" don't). <reason> is one of
# ended.reason's words (saved, reverted, closed, ...): by null, and OpenRGB is
# restored too. The screens the session touched always get their saved
# entries back first; the lights too, except for "off" (Off replaces them).
# With the main lock held (LOCK_HELD) the revert happens now (about 1 s);
# otherwise the end is queued to the worker. --no-revert (a save that applies
# right after) sends nothing back. No session: nothing at all.
preview_yield() {
  local what=${1:-} theme='' revert=1 scr=1 reason by=null orgb='' a
  shift || true
  for a in "$@"; do
    case $a in --no-revert) revert='' scr='' ;; --openrgb) orgb=1 ;; *) theme=$a ;; esac
  done
  [[ -f $PREVIEW_FILE ]] || return 0
  preview_open || return 0
  case $what in
    saved | reverted | panel-closed | closed | idle | ui-gone | cancelled | lights-off | screens-off)
      reason=$what orgb=1
      [[ $what != screens-off ]] || by='{"op":"off","theme":null}' ;;
    off) reason=lights-off by='{"op":"off","theme":null}' revert='' orgb='' ;;
    *) reason=cancelled by=$(jq -nc --arg op "$what" --arg t "$theme" '{op: $op, theme: (if $t == "" then null else $t end)}') ;;
  esac
  if [[ -n $LOCK_HELD || ( -z $revert && -z $scr ) ]]; then
    preview_finish "$reason" "$by" "$revert" "$orgb" "$scr"
  else
    preview_end_request "$reason" "$by" "$revert" "$scr" || true
  fi
}

# The reaper's verdict on the session: "ui-gone", "idle" or nothing.
pv_expired() {
  jq -r --argjson now "$EPOCHSECONDS" '
    if .state == "ended" then empty
    elif ($now - (.touched // 0)) > (.heartbeat_ttl // 90) then "ui-gone"
    elif ($now - (.edited // .touched // 0)) > (.idle_ttl // 600) then "idle"
    else empty end' "$PREVIEW_FILE" 2>/dev/null || true
}

# preview_reap_locked: the schedule and clip ticks (main lock held) end an
# expired session, or one whose queued end never ran, themselves, and send
# back the screens an ended session couldn't (the daemon was away).
preview_reap_locked() {
  local why e
  if [[ ! -f $PREVIEW_FILE ]] || ! preview_open; then pv_retry_screens; return 0; fi
  if [[ $(pv_get .state) == ending ]]; then
    e=$(jq -c '.ending // {reason: "closed", by: null, revert: true, screens: true}' "$PREVIEW_FILE")
    preview_finish "$(jq -r .reason <<<"$e")" "$(jq -c .by <<<"$e")" "$(jq -r 'if .revert == false then "" else 1 end' <<<"$e")" 1 \
      "$(jq -r 'if .screens == false then "" else 1 end' <<<"$e")"
    return 0
  fi
  why=$(pv_expired)
  [[ -z $why ]] || preview_finish "$why" null 1 1 1
}

# --reap (the timer, every 30 s): end an expired session through the worker,
# retry a blocked one, restart a lost end; stop the timer once it is over.
preview_reap() {
  local why st w
  if ! preview_open; then preview_stop_reaper; return 0; fi
  why=$(pv_expired) st=$(pv_get .state) w=$(pv_get .worker)
  if [[ -n $why ]]; then
    log "preview: $why; ending the preview"
    preview_end_request "$why" null 1 || true
  elif [[ $st == ending && $w != true ]]; then
    pv_edit '.worker = true' && preview_start_worker || true
  elif [[ $st == blocked && $w != true ]]; then
    pv_edit '.worker = true' && preview_start_worker || true
  fi
}

# ---- the worker -------------------------------------------------------------------
# pv_blocker: who holds the lock, from busy.json ({op, theme, unit}).
pv_blocker() {
  local b
  b=$(raw "$CACHE/busy.json")
  if [[ $b =~ \"pid\":([0-9]+) ]] && kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
    jq -c '{op, theme, unit}' <<<"$b" 2>/dev/null && return 0
  fi
  echo '{"op":"busy","theme":null,"unit":null}'
}

# One pass (the lock is held): build the draft's rev, send the Lian Li part,
# then OpenRGB if its arguments changed. 0 = done for this rev, 1 = failed or
# blocked (the worker stops; the next edit, Resend or the reaper retries).
pv_pass() {
  local id=$1 theme rev eff method t0 base force=/dev/null ms lst=ok sent=0 failed='[]' blk=null orgb='' perr
  theme=$(pv_get .theme) method=$(pv_get .method)
  mkdir -p "$PREVIEW_DIR"
  rev=$( (editor_draft_rev "$theme") 2>/dev/null ) || rev=
  if ! perr=$( (editor_draft_problems "$theme" --fast) 2>"$TMP/pv-probs.err" ); then
    perr=${perr:-$(tail -n1 "$TMP/pv-probs.err" | sed 's/^pc-lights: //')}
    perr=${perr:-could not check the draft}
  fi
  if [[ -n $perr ]]; then
    pv_upd "$id" --arg e "$perr" '.state = "blocked" | .blocked_by = "invalid" | .worker = false | .error = ($e | split("\n")[0])' || true
    return 1
  fi
  if ! eff=$( (editor_draft_eff "$theme") 2>"$TMP/pv-eff.err" ) || [[ ! -f $eff ]]; then
    pv_upd "$id" --arg e "could not build the draft: $(tail -n1 "$TMP/pv-eff.err" | sed 's/^pc-lights: //')" \
      '.state = "failed" | .worker = false | .error = $e' || true
    return 1
  fi
  pv_upd "$id" --argjson rev "${rev:-null}" '.state = "applying" | .blocked_by = null | .error = null' || true

  # OpenRGB: does this rev change its arguments? (the first pass compares with
  # the active theme's; no cached RAM ids = no sticks, never a listing)
  if backend_skipped openrgb; then
    pv_upd "$id" '.openrgb.state = "skipped"' || true
  elif ( openrgb_preview_args "$eff" ) >"$TMP/pv-orgb.args" 2>"$TMP/pv-orgb.err"; then
    if [[ ! -f $PREVIEW_DIR/applied-orgb.args ]]; then
      ( THEME=; openrgb_preview_args "$(scheme_file)" ) >"$TMP/pv-orgb-base.args" 2>/dev/null || : >"$TMP/pv-orgb-base.args"
    else
      cp "$PREVIEW_DIR/applied-orgb.args" "$TMP/pv-orgb-base.args"
    fi
    if ! cmp -s "$TMP/pv-orgb.args" "$TMP/pv-orgb-base.args"; then
      orgb=1
      pv_upd "$id" --argjson rev "${rev:-null}" '.openrgb.state = "pending" | .openrgb.rev = $rev' || true
    fi
  else
    pv_upd "$id" --arg e "$(head -n1 "$TMP/pv-orgb.err" | sed 's/^pc-lights: //')" \
      '.openrgb.state = "failed" | .error = ("OpenRGB: " + $e)' || true
  fi

  # The screens first (screens plan §3.1): under method effect their config
  # reload brings the saved RGB back, so the lights must come after it.
  local since_scr
  since_scr=$(date '+%Y-%m-%d %H:%M:%S')
  pv_screens_pass "$id" "$eff" "$theme" || true

  # Lian Li: diff against what the case shows, send only that.
  t0=${EPOCHREALTIME/./}
  if backend_skipped lianli; then
    lst=skipped
  elif ! systemctl --user is-active -q lianli-daemon; then
    lst=failed failed='[{"device_id":null,"error":"lianli-daemon is not running"}]'
  else
    base=$PREVIEW_DIR/applied-rgb.json
    if [[ ! -f $base ]]; then jq '.rgb.devices // []' "$CFG_LIVE" >"$TMP/pv-base.json"; base=$TMP/pv-base.json; fi
    jq -c '[.lianli.failed // [] | .[].device_id | strings] | unique' "$PREVIEW_FILE" >"$TMP/pv-force.json" && force=$TMP/pv-force.json
    if [[ $method != rgbconfig ]] && (( SCREENS_MEDIA_SENT > 0 )); then
      # The screens' reload re-sent the saved RGB (M5): every device the
      # preview had sent goes again, in full.
      pv_wait_reload "$since_scr" || log "preview: no config reload showed within 8 s after the screens"
      # (the reload line comes before its RGB apply: let that land first)
      sleep "${PCL_PV_RELOAD_SETTLE:-1}"
      if [[ -f $PREVIEW_DIR/applied-rgb.json ]]; then
        jq -c --slurpfile a "$PREVIEW_DIR/applied-rgb.json" '. + [($a[0] // [])[]? | .device_id | strings] | unique' \
          "$TMP/pv-force.json" >"$TMP/pv-force2.json" && mv -f "$TMP/pv-force2.json" "$TMP/pv-force.json"
      fi
    fi
    local from=$CFG_LIVE
    if [[ $method == rgbconfig ]]; then
      jq --slurpfile s "$PREVIEW_DIR/saved-rgb.json" '.rgb = $s[0]' "$CFG_LIVE" >"$TMP/pv-from.json"; from=$TMP/pv-from.json
    fi
    if ! ( lianli_effect_plan "$eff" "$base" "$TMP/pv-new.json" "$TMP/pv-reqs.jsonl" "$force" "$from" ) 2>"$TMP/pv-plan.err"; then
      lst=failed failed=$(jq -nc --arg e "$(tail -n1 "$TMP/pv-plan.err" | sed 's/^pc-lights: //')" '[{device_id: null, error: $e}]')
    elif [[ $method == rgbconfig ]]; then
      sent=$(grep -c . "$TMP/pv-reqs.jsonl" || true)
      if (( sent > 0 )); then
        jq --slurpfile d "$TMP/pv-new.json" '.devices = $d[0]' "$PREVIEW_DIR/saved-rgb.json" >"$TMP/pv-rgb.json"
        if pv_send_rgbconfig "$TMP/pv-rgb.json"; then cp "$TMP/pv-new.json" "$PREVIEW_DIR/applied-rgb.json"
        else lst=failed failed=$(jq -nc --arg e "$LIVE_ERR" '[{device_id: null, error: $e}]'); fi
      fi
    elif ! daemon_guarded_batch "$TMP/pv-reqs.jsonl" "$TMP/pv-res.jsonl"; then
      lst=failed failed='[{"device_id":null,"error":"lianli-daemon did not answer"}]'
    else
      sent=$(jq -s '[.[] | select(.ok)] | length' "$TMP/pv-res.jsonl")
      failed=$(jq -sc '[.[] | select(.ok | not) | {device_id, error}] | unique_by(.device_id)' "$TMP/pv-res.jsonl")
      # What reached the case is the new plan; a failed device is re-sent in full next pass.
      cp "$TMP/pv-new.json" "$PREVIEW_DIR/applied-rgb.json"
      jq -sc --slurpfile t <(cat "$PREVIEW_DIR/touched.json" 2>/dev/null || echo '[]') \
        '($t[0] // []) + [.[].device_id | strings] | unique' "$TMP/pv-res.jsonl" | put_json "$PREVIEW_DIR/touched.json"
      if jq -e 'any(.[]; .error | test("thermal alert"; "i"))' <<<"$failed" >/dev/null; then blk='"heat-alert"'
      elif jq -e 'any(.[]; .error | test("RGB sync|merge"; "i"))' <<<"$failed" >/dev/null; then blk='"rgb-sync"'; fi
    fi
  fi
  ms=$(( (${EPOCHREALTIME/./} - t0) / 1000 ))
  if [[ $lst == failed ]]; then
    pv_upd "$id" --argjson f "$failed" --argjson ms "$ms" '
      .state = "failed" | .worker = false | .lianli = {state: "failed", sent: 0, failed: $f, at: $now, ms: $ms}
      | .error = ($f[0].error // "Lian Li preview failed")' || true
    return 1
  fi
  pv_upd "$id" --arg lst "$lst" --argjson sent "$sent" --argjson f "$failed" --argjson ms "$ms" \
    --argjson rev "${rev:-null}" --argjson blk "$blk" '
    .lianli = {state: $lst, sent: $sent, failed: $f, at: $now, ms: $ms} | .applied_rev = $rev
    | if $blk != null then .state = "blocked" | .blocked_by = $blk | .worker = false else .state = "live" end' || true
  [[ $blk == null ]] || return 1

  # OpenRGB last: 2-20 s, never killed; a TERM that came meanwhile waits for it.
  if [[ -n $orgb && -z ${PV_TERM:-} ]]; then
    pv_upd "$id" '.openrgb.state = "applying"' || true
    t0=${EPOCHREALTIME/./}
    if be_openrgb_preview "$eff" "$TMP/pv-orgb.args"; then
      cp "$TMP/pv-orgb.args" "$PREVIEW_DIR/applied-orgb.args"
      lst=ok
    else
      # Keep the old signature so the next pass tries again.
      [[ -f $PREVIEW_DIR/applied-orgb.args ]] || cp "$TMP/pv-orgb-base.args" "$PREVIEW_DIR/applied-orgb.args"
      lst=failed
    fi
    ms=$(( (${EPOCHREALTIME/./} - t0) / 1000 ))
    pv_upd "$id" --arg st "$lst" --argjson ms "$ms" --argjson rev "${rev:-null}" \
      '.openrgb = {state: $st, rev: $rev, at: $now, ms: $ms}' || true
  fi
  return 0
}

# --run: the worker. Loops until the applied rev catches up with the wanted
# one; each pass takes the main lock for at most 3 s of waiting ("blocked"
# otherwise: it never queues behind an apply), an end waits as long as it
# takes. SIGTERM lets the running daemon or openrgb call finish, then marks
# the session; the reaper reverts it later.
preview_run() {
  local id st next
  PV_TERM=
  trap 'PV_TERM=1' TERM
  [[ -f $PREVIEW_FILE ]] || return 0
  id=$(pv_get .id)
  [[ -n $id ]] || return 0
  while :; do
    st=$(pv_get .state)
    [[ $(pv_get .id) == "$id" && -n $st && $st != ended ]] || return 0
    exec 8>"$LOCK"
    if [[ $st == ending ]]; then
      flock -w 600 8 || { pv_upd "$id" '.worker = false | .error = "the lock was held for 10 min; the preview could not end"' || true; return 0; }
    elif ! flock -w 3 8; then
      exec 8>&-
      pv_upd "$id" --argjson b "$(pv_blocker)" '.state = "blocked" | .blocked_by = $b | .worker = false' || true
      return 0
    fi
    LOCK_HELD=1
    st=$(pv_get .state)
    if [[ $(pv_get .id) != "$id" || $st == ended ]]; then drop_lock; LOCK_HELD=; return 0; fi
    if [[ $st == ending ]]; then
      preview_reap_locked
      drop_lock; LOCK_HELD=
      return 0
    fi
    next=stop
    pv_pass "$id" && next=check
    drop_lock; LOCK_HELD=
    if [[ -n $PV_TERM ]]; then
      pv_upd "$id" '.worker = false | .error = "the preview worker was stopped (SIGTERM)"' || true
      return 0
    fi
    [[ $next == check ]] || return 0
    # The screens just sent: follow the daemon until they play (unlocked,
    # read-only; it stops for a newer rev or an end).
    pv_screens_follow "$id" || true
    if [[ -n $PV_TERM ]]; then
      pv_upd "$id" '.worker = false | .error = "the preview worker was stopped (SIGTERM)"' || true
      return 0
    fi
    # Caught up? (under preview.lock, so a new request either sees worker
    # false and starts a worker, or its rev is seen here)
    next=$(
      exec 6>"$PREVIEW_LOCK"
      flock -w 5 6 || { echo stop; exit 0; }
      jq -r --arg id "$id" '
        if .id != $id or .state == "ended" then "stop"
        elif .state == "ending" then "loop"
        elif .state == "blocked" or .state == "failed" then "stop"
        elif (.applied_rev // -1) >= (.want_rev // 0) then "done"
        else "loop" end' "$PREVIEW_FILE" 2>/dev/null || echo stop
    )
    if [[ $next == "done" ]]; then
      # Re-checked inside the edit: a request may have raised want_rev meanwhile.
      pv_upd "$id" 'if (.applied_rev // -1) >= (.want_rev // 0) then .worker = false else . end' || true
      [[ $(pv_get .worker) == true ]] || return 0
    elif [[ $next != loop ]]; then
      pv_upd "$id" '.worker = false' || true
      return 0
    fi
  done
}

# ---- the CLI ----------------------------------------------------------------------
# theme preview <name> [--rev N] [--idle S] [--json]: show the draft; returns
# at once (the worker does the work).
preview_request() {
  local name='' rev='' idle='' df method probs a out id new start
  while (( $# )); do
    case $1 in
      --rev) [[ ${2:-} =~ ^[0-9]+$ ]] || pv_fail 2 usage "--rev needs a number"; rev=$2; shift 2 ;;
      --idle) [[ ${2:-} =~ ^[0-9]+$ ]] || pv_fail 2 usage "--idle needs seconds"; idle=$2; shift 2 ;;
      --json) PV_JSON=1; shift ;;
      -*) pv_fail 2 usage "usage: pc-lights theme preview <name> [--rev N] [--idle S] [--json]" ;;
      *) [[ -z $name ]] || pv_fail 2 usage "usage: pc-lights theme preview <name> [--rev N] [--json]"; name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || pv_fail 2 usage "usage: pc-lights theme preview <name> [--rev N] [--json]"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || pv_fail 2 bad-name "bad theme name '$name'"
  df=$( (editor_draft_file "$name") 2>/dev/null ) || df=
  [[ -n $df && -f $df ]] || pv_fail 2 not-found "no draft of $name to preview; open it with: lumenaire theme edit $name"
  method=$(preview_method) ||
    pv_fail 2 unmeasured "Live preview needs a one-time hardware check: run lumenaire theme preview --measure"
  [[ $(lights_state) == on ]] || pv_fail 2 lights-off "the lights are off; turn them on to preview"
  if ! probs=$( (editor_draft_problems "$name" --fast) 2>"$TMP/pv-probs.err" ); then
    probs=${probs:-$(tail -n1 "$TMP/pv-probs.err" | sed 's/^pc-lights: //')}
    probs=${probs:-could not check the draft}
  fi
  [[ -z $probs ]] || pv_fail 2 invalid "the draft of $name has problems; the preview keeps its last good state" "$probs"
  [[ -n $rev ]] || rev=$( (editor_draft_rev "$name") 2>/dev/null ) || rev=0
  mkdir -p "$PREVIEW_DIR"
  out=$(
    exec 6>"$PREVIEW_LOCK"
    t=$PREVIEW_FILE.$BASHPID.tmp n=$PREVIEW_FILE.$BASHPID.new
    flock -w 5 6 || exit 1
    new=false
    if ! jq -e '.state != "ended"' "$PREVIEW_FILE" >/dev/null 2>&1; then
      new=true
      rm -f "$PREVIEW_DIR"/applied-rgb.json "$PREVIEW_DIR"/applied-orgb.args "$PREVIEW_DIR"/touched.json "$PREVIEW_DIR"/saved-rgb.json
      # Screens an earlier session couldn't send back keep their snapshot
      # (this session sends them back at its end); anything else is stale.
      [[ -s $PREVIEW_DIR/touched-lcds.json ]] || rm -f "$PREVIEW_DIR"/saved-lcds.json "$PREVIEW_DIR"/applied-lcds.json
      if [[ $method == rgbconfig ]]; then jq '.rgb // {}' "$CFG_LIVE" >"$PREVIEW_DIR/saved-rgb.json" || exit 1; fi
      jq -nc --argjson now "$EPOCHSECONDS" --arg id "p-$(( ${EPOCHREALTIME/./} / 1000 ))" --arg method "$method" \
        --argjson hb "$PREVIEW_HEARTBEAT_TTL" --argjson idle "${idle:-$PREVIEW_IDLE_TTL}" '
        {v: 1, id: $id, theme: null, draft: null, state: "queued", worker: false, method: $method,
         want_rev: null, applied_rev: null,
         lianli: {state: null, sent: 0, failed: [], at: null, ms: null},
         openrgb: {state: "idle", rev: null, at: null, ms: null},
         screens: {state: "idle", reason: null, sent: 0, at: null, ms: null, roles: {}, failed: []},
         blocked_by: null, started: $now, touched: $now, edited: $now,
         heartbeat_ttl: $hb, idle_ttl: $idle, idle_ends: ($now + $idle),
         ending: null, ended: null, error: null}' >"$n" || exit 1
      src=$n
    else
      src=$PREVIEW_FILE
    fi
    jq -c --argjson now "$EPOCHSECONDS" --arg theme "$name" --arg draft "$df" --argjson rev "$rev" \
      --argjson idle "${idle:-null}" --argjson new "$new" '
      .theme = $theme | .draft = $draft | .want_rev = $rev | .touched = $now | .edited = $now
      | .idle_ttl = ($idle // .idle_ttl) | .idle_ends = ($now + .idle_ttl) | .error = null
      # An end still waiting for the lock is called off: the worker that
      # would have run it finds a pass to do instead.
      | if .state == "ending" then .state = "queued" | .ending = null else . end
      | if .worker == true then . else .state = "queued" | .blocked_by = null end
      | ._start = (.worker != true) | .worker = true | ._new = $new' "$src" >"$t" || exit 1
    jq -c '{start: ._start, new: ._new, id}' "$t"
    jq -c 'del(._start, ._new)' "$t" | put_json "$PREVIEW_FILE"
    rm -f "$t" "$n"
  ) || die "could not update $PREVIEW_FILE"
  id=$(jq -r .id <<<"$out") start=$(jq -r .start <<<"$out") new=$(jq -r .new <<<"$out")
  [[ $new == true ]] && preview_start_reaper
  if [[ $start == true ]] && ! preview_start_worker; then
    pv_edit '.worker = false | .error = "systemd-run could not start the preview worker"' || true
    pv_fail 3 systemd-run "systemd-run could not start the preview worker"
  fi
  jq -nc --argjson rev "$rev" --arg id "$id" '{queued: true, rev: $rev, id: $id}'
}

# theme preview --end [--reason R] [--json]: send the saved look back (queued;
# idempotent: no session, or an ended one, is fine).
preview_end_cmd() {
  local reason=closed
  while (( $# )); do
    case $1 in
      --reason)
        [[ ${2:-} =~ ^(panel-closed|reverted|closed)$ ]] || pv_fail 2 usage "--reason must be panel-closed, reverted or closed"
        reason=$2; shift 2 ;;
      --json) PV_JSON=1; shift ;;
      *) pv_fail 2 usage "usage: pc-lights theme preview --end [--reason panel-closed|reverted|closed] [--json]" ;;
    esac
  done
  if ! preview_open; then jq -nc '{queued: false, ended: true}'; return 0; fi
  preview_end_request "$reason" null 1 || pv_fail 3 systemd-run "systemd-run could not start the preview worker"
  jq -nc '{queued: true, ended: false}'
}

# theme preview --keepalive [--edited]: the UI's heartbeat (lock-free, instant).
preview_keepalive() {
  local edited=false
  [[ ${1:-} == --edited ]] && edited=true
  [[ -f $PREVIEW_FILE ]] || return 0
  pv_edit --argjson ed "$edited" '
    if .state == "ended" then . else .touched = $now
      | if $ed then .edited = $now | .idle_ends = ($now + (.idle_ttl // 600)) else . end end' || true
}

# theme preview --measure: the one-time hardware check (interactive).
preview_measure() {
  local m
  # The installed copy ships it as tools/preview-measure (tests/ isn't
  # installed); a git checkout also has tests/preview/measure.sh.
  m=$PCL_LIB/tools/preview-measure
  [[ -x $m ]] || m=$(readlink -f "$PCL_LIB/../../tests/preview/measure.sh" 2>/dev/null) || m=
  [[ -n $m && -x $m ]] || die "the hardware check (tools/preview-measure) is not installed beside the engine"
  exec "$m" --engine "$(readlink -f "$0")" "$@"
}

preview_cmd() {
  local a
  case ${1:-} in
    --status)
      for a in "${@:2}"; do [[ $a == --json ]] || die "usage: pc-lights theme preview --status --json"; done
      if [[ -f $PREVIEW_FILE ]] && jq -e . "$PREVIEW_FILE" >/dev/null 2>&1; then jq -c . "$PREVIEW_FILE"; else echo null; fi ;;
    --end) shift; preview_end_cmd "$@" ;;
    --keepalive) shift; preview_keepalive "$@" ;;
    --run) preview_run ;;
    --reap) preview_reap ;;
    --measure) shift; preview_measure "$@" ;;
    "" | -h | --help)
      die "usage: pc-lights theme preview <name> [--rev N] [--idle S] [--json] | --end [--reason R] | --keepalive [--edited] | --status --json | --measure" ;;
    *) preview_request "$@" ;;
  esac
}
