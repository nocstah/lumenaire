# lib/pc-lights/backend-lianli.sh — the Lian Li backend (lian-li-linux daemon config, live writes, restarts)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP4 (backends)
# Public: be_lianli_{probe,detect,validate,build,render,apply,screens,kinds} be_lianli_bind
#         lianli_lights lianli_screens write_lianli_rgb screens_config fetch_caps build_lianli apply_live_or_restart apply_lianli live_install daemon_call daemon_guarded push_lcd_brightness nudge_new_image_lcds usb_serial_map thermal_alert_json apply_scheme_screens rewrite_config start_daemon_checked daemon_stop daemon_start missed_devices
#         lianli_effect_plan lianli_effect_requests lianli_screen_plan daemon_guarded_batch daemon_guard_json (the theme preview);
#         constants rgb_jq brightness_jq LIANLI_RGB_JQ LIANLI_EFFECT_REQ_JQ DAEMON_BATCH_TIMEOUT; state LIVE_ERR SCREENS_RESET
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

daemon_stop() { DAEMON_STOPPED=1; systemctl --user stop lianli-daemon; }
daemon_start() { systemctl --user start lianli-daemon; DAEMON_STOPPED=; }

# Colour hex -> [r,g,b] for the daemon config (u8 each). Accepts a leading
# '#', like the OpenRGB side; anything but 6 hex digits is an error, never a
# negative or >255 byte (the daemon rejects the whole file on one bad byte).
rgb_jq='def rgb: (if type == "string" then ltrimstr("#") else "" end) as $h
  | if ($h | test("^[0-9a-fA-F]{6}$")) then
      [$h[0:2], $h[2:4], $h[4:6]] | map(ascii_downcase | explode
        | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1])
    else error("bad colour \(tojson) (want 6 hex digits)") end;'

daemon_call() {
  printf '%s\n' "$1" | timeout 5 socat - "UNIX-CONNECT:$SOCK"
}

# ---- live writes (no daemon restart) -------------------------------------
# The daemon refuses writes unless wrapped in {"method":"Guarded"} with a
# guard copied from GetDaemonInfo: {client_version: <daemon version>,
# protocol_version, instance_id}. It is a compatibility stamp, not a secret
# (lianli-shared daemon.rs WriteGuard); instance_id changes on every daemon
# restart, so it is read fresh for each write. Requests travel via files:
# a whole config is too big for a jq --argjson argument.
LIVE_ERR=
daemon_guarded() {
  local req=$1 info resp
  LIVE_ERR=
  info=$(daemon_call '{"method":"GetDaemonInfo"}' 2>/dev/null) || { LIVE_ERR=transport; return 1; }
  jq -e '.status == "ok" and (.data.capabilities | index("guarded_writes"))' <<<"$info" >/dev/null 2>&1 ||
    { LIVE_ERR=transport; return 1; }
  jq -nc --argjson i "$(jq -c '.data | {client_version: .version, protocol_version, instance_id}' <<<"$info")" \
    --slurpfile r "$req" '{method: "Guarded", params: {guard: $i, request: $r[0]}}' >"$TMP/guarded.json"
  # -t: after sending, keep waiting up to 60 s for the reply (default 0.5 s).
  resp=$(timeout 90 socat -t 60 - "UNIX-CONNECT:$SOCK" <"$TMP/guarded.json" 2>/dev/null) || { LIVE_ERR=transport; return 1; }
  if jq -e '.status == "ok"' <<<"$resp" >/dev/null 2>&1; then return 0; fi
  LIVE_ERR=$(jq -r '.message // "no reply"' <<<"$resp" 2>/dev/null || echo "unreadable reply")
  return 1
}

# ---- batched live writes (the theme preview, plan §1.5) ---------------------
# daemon_guard_json: the write guard from one GetDaemonInfo, compact, or 1.
daemon_guard_json() {
  local info
  info=$(daemon_call '{"method":"GetDaemonInfo"}' 2>/dev/null) || return 1
  jq -ce 'select(.status == "ok" and (.data.capabilities | index("guarded_writes")))
    | .data | {client_version: .version, protocol_version, instance_id}' <<<"$info" 2>/dev/null
}

# daemon_guarded_batch <requests.jsonl> <results.jsonl>: send every request
# (one JSON object a line) guarded, reading the guard once for the whole batch
# and once more if the daemon refuses it or doesn't answer (it restarted in
# between: a new instance_id). No journal wait, no re-send, never a daemon
# restart: a request that fails is reported and the rest still go. One result
# line per request, in order: {i, method, device_id, zone, ok, error}.
# Returns 1 with LIVE_ERR=transport when the guard can't be read (nothing was
# sent), else 0 however many requests failed.
DAEMON_BATCH_TIMEOUT=10
daemon_guarded_batch() {
  local reqs=$1 out=$2 guard line resp i=0 reread= lines=()
  LIVE_ERR=
  : >"$out"
  mapfile -t lines < <(grep -v '^[[:space:]]*$' "$reqs" 2>/dev/null || true)
  (( ${#lines[@]} )) || return 0
  guard=$(daemon_guard_json) || { LIVE_ERR=transport; return 1; }
  : >"$TMP/gb-raw.tsv"
  for line in "${lines[@]}"; do
    while :; do
      jq -nc --argjson g "$guard" --argjson r "$line" '{method: "Guarded", params: {guard: $g, request: $r}}' >"$TMP/gb-req.json"
      resp=$(timeout "$DAEMON_BATCH_TIMEOUT" socat -t 5 - "UNIX-CONNECT:$SOCK" <"$TMP/gb-req.json" 2>/dev/null | head -n1) || resp=
      if [[ -z $reread && $resp != *'"status":"ok"'* ]] &&
         { [[ -z $resp ]] || jq -e '.message // "" | test("authori|guard|instance"; "i")' <<<"$resp" >/dev/null 2>&1; }; then
        reread=1
        guard=$(daemon_guard_json) || { LIVE_ERR=transport; return 1; }
        continue
      fi
      break
    done
    printf '%s\t%s\n' "$i" "${resp:-null}" >>"$TMP/gb-raw.tsv"
    i=$((i + 1))
  done
  jq -nc --rawfile raw "$TMP/gb-raw.tsv" --slurpfile q <(printf '%s\n' "${lines[@]}") '
    [$raw | split("\n")[] | select(length > 0) | split("\t") | (try (.[1:] | join("\t") | fromjson) catch null)] as $r
    | range(0; $q | length) as $i | $q[$i] as $req | ($r[$i] // null) as $resp
    | {i: $i, method: $req.method, device_id: ($req.params.device_id // null), zone: ($req.params.zone // null),
       ok: (($resp | objects | .status) == "ok"),
       error: (if ($resp | objects | .status) == "ok" then null
               else (($resp | objects | .message) // "no reply from lianli-daemon") end)}' >"$out"
}

# Send the built scratch config (and template file) to the running daemon.
# Templates first, so a screen's new template_id already exists when the
# config arrives. Returns 1 with LIVE_ERR=transport when the daemon can't be
# reached or refuses the guard (caller falls back to a restart); any other
# refusal is the daemon rejecting the content, which a restart wouldn't fix.
live_install() {
  if [[ -f $TMP/work-tpl.json ]] && ! cmp -s "$TMP/work-tpl.json" "$TMP/built-from-tpl.json"; then
    jq -c '{method: "SetLcdTemplates", params: {templates: .templates}}' "$TMP/work-tpl.json" >"$TMP/req-tpl.json"
    daemon_guarded "$TMP/req-tpl.json" || return 1
  fi
  jq -c '{method: "SetConfig", params: {config: .}}' "$TMP/work-config.json" >"$TMP/req-cfg.json"
  daemon_guarded "$TMP/req-cfg.json"
}

# The wireless MACs a daemon journal excerpt says missed their lighting
# ("Failed to apply RGB config for wireless:<mac>: ..."), for last-run.json.
missed_devices() {
  mapfile -t RUN_MISSED < <(grep 'Failed to apply RGB config' <<<"$1" |
    grep -oE 'wireless:([0-9a-f]{2}:){5}[0-9a-f]{2}' | cut -d: -f2- | sort -u)
}

# Live apply with a restart fallback. $1 = lights|screens, rest = builder.
# A wireless device that misses its lighting (weak RF) gets the config sent
# again rather than a daemon restart.
# A live config reload saves each screen's brightness but never sends it to
# the panel (2026-09-25: "off screens" left all 7 at full brightness while the
# daemon's own GetConfig said 0), so send SetLcdBrightness to every screen
# ourselves: once right after the reload, and once more after the streams
# restart (about 2 s apart, up to ~5 s), in case a panel re-init resets it.
# Best effort: a failure is logged, never fatal.
LCD_BRIGHTNESS_SETTLE=5
push_lcd_brightness() {
  local n
  jq -c '.lcds[]? | select(.serial | type == "string")
    | {method: "SetLcdBrightness", params: {device_id: .serial, brightness: (.brightness // 100)}}' \
    "$CFG_LIVE" >"$TMP/lcd-bri.jsonl" 2>/dev/null || return 0
  [[ -s $TMP/lcd-bri.jsonl ]] || return 0
  for n in 1 2; do
    (( n == 1 )) || sleep "$LCD_BRIGHTNESS_SETTLE"
    if ! daemon_guarded_batch "$TMP/lcd-bri.jsonl" "$TMP/lcd-bri.out"; then
      log "screen brightness: daemon unreachable ($LIVE_ERR)"; return 0
    fi
  done
  n=$(jq -s '[.[] | select(.ok | not)] | length' "$TMP/lcd-bri.out" 2>/dev/null || echo 0)
  if (( n > 0 )); then log "screen brightness: $n screen(s) refused it"; fi
  return 0
}

# A screen that goes from a video (or a live template) to a still image in a
# live reload keeps showing the old picture (2026-09-25, sakura-light →
# cyberpunk: fan LCDs 0 and 3): the daemon sends the image, then stopping the
# old H.264 stream re-initialises the panel and wipes it, and the image is
# never sent again (a video recovers on its next frame). Re-sending the same
# entry is a no-op (the daemon sees no change), so nudge each such screen:
# SetLcdMedia with the orientation turned 90°, then the real entry. Run after
# the streams settle (push_lcd_brightness waits for that). Best effort.
LCD_NUDGE_GAP=3
nudge_new_image_lcds() {
  local old=$TMP/built-from.json new=$TMP/work-config.json e turn f=$TMP/nudge-req.json
  [[ -s $old && -s $new ]] || return 0
  jq -c --slurpfile o "$old" '
    ([$o[0].lcds[]? | {(.serial // ""): .type}] | add // {}) as $was
    | .lcds[]? | select(.type == "image" and (.serial | type == "string")
                        and ($was[.serial] // "image") != "image")' "$new" >"$TMP/nudge.jsonl" 2>/dev/null || return 0
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    for turn in 90 0; do
      jq -c --argjson t "$turn" '{method: "SetLcdMedia", params: {device_id: ("serial:" + .serial),
        config: (.orientation = (((.orientation // 0) + $t) % 360))}}' <<<"$e" >"$f"
      daemon_guarded "$f" || { log "image screen $(jq -r .serial <<<"$e"): refresh failed ($LIVE_ERR)"; continue 2; }
      if (( turn )); then sleep "$LCD_NUDGE_GAP"; fi
    done
    log "image screen $(jq -r .serial <<<"$e"): refreshed (was a video)"
  done <"$TMP/nudge.jsonl"
  return 0
}

apply_live_or_restart() {
  local what=$1 since journal try; shift
  build_lianli "$@"
  since=$(date '+%Y-%m-%d %H:%M:%S')
  if live_install; then
    # The daemon persists a SetConfig at once, but applies it from its main
    # event loop ("Config reload triggered via IPC"). On 2026-09-24 that loop
    # hung right after a fan-controller reload (the flaky wireless device
    # reconnecting): the config was saved, never applied, and the screens kept
    # the old theme. No reload line within 25 s = wedged loop; a restart loads
    # the config the daemon already saved.
    local waited=0
    until journalctl --user -u lianli-daemon --since "$since" --no-pager 2>/dev/null |
        grep -q 'Config reload triggered via IPC'; do
      if (( waited >= 25 )); then
        log "lianli-daemon saved the config but didn't apply it within 25 s (main loop stuck); restarting it"
        RUN_FALLBACK=1; progress "restarting daemon"
        daemon_stop
        start_daemon_checked "$what"
        return 0
      fi
      sleep 1; waited=$((waited + 1))
    done
    log "applied live (no daemon restart)"
    push_lcd_brightness
    nudge_new_image_lcds
    [[ $what == lights ]] || return 0
    # Up to two re-sends; the third pass only checks whether the last one landed.
    for try in 1 2 3; do
      sleep 12
      journal=$(journalctl --user -u lianli-daemon --since "$since" --no-pager 2>/dev/null || true)
      grep -q 'Failed to apply RGB config' <<<"$journal" || { RUN_MISSED=(); return 0; }
      missed_devices "$journal"
      (( try < 3 )) || break
      log "a device missed its lighting (try $try); sending the config again"
      progress "retrying wireless"
      since=$(date '+%Y-%m-%d %H:%M:%S')
      daemon_guarded "$TMP/req-cfg.json" || break
    done
    log "some device may still be missing its lighting (weak RF); it keeps its previous look"
    return 0
  fi
  [[ $LIVE_ERR == transport ]] || die "lianli-daemon refused the new config: $LIVE_ERR (nothing changed)"
  log "live write unavailable; falling back to a daemon restart"
  RUN_FALLBACK=1; progress "restarting daemon"
  apply_lianli "$@"
  start_daemon_checked "$what"
}

# Replace $CFG (a scratch copy while building) with the output of a jq filter,
# refusing anything that drops the screen map, comes out empty, or holds a
# value the daemon's strict parser would reject (it then drops the whole file
# and runs every light and screen on defaults).
rewrite_config() {
  local lcds
  lcds=$(jq '.lcds | length' "$CFG")
  jq "$@" "$CFG" >"$TMP/config.json" || die "could not build the Lian Li config; nothing changed"
  [[ -s $TMP/config.json ]] || die "jq produced an empty config; nothing changed"
  jq -e --argjson n "$lcds" '(.lcds | length) == $n' "$TMP/config.json" >/dev/null ||
    die "new config lost screen entries; nothing changed"
  jq -e '
    def byte: type == "number" and . == floor and . >= 0 and . <= 255;
    ([.thermal_alert // {} | .[] | objects | .threshold, .alert_color[]?] | all(byte))
    and ([.rgb.devices[]? | (.zones[]?.effect, .regions[]?.effect) | objects
          | (.colors[]?[]?, .speed, .brightness) | select(. != null)] | all(byte))
    and ([.lcds[] | .brightness | select(. != null)] | all(byte and . <= 100))' \
    "$TMP/config.json" >/dev/null ||
    die "new config has an out-of-range colour, speed, threshold or brightness; nothing changed"
  cp "$TMP/config.json" "$CFG"
}

# Build a new config (and template file) against scratch copies while the
# daemon keeps running: "$@" is the builder (write_lianli_rgb, screens_config).
build_lianli() {
  cp "$CFG_LIVE" "$TMP/built-from.json"
  if [[ -f $TPL_LIVE ]]; then cp "$TPL_LIVE" "$TMP/built-from-tpl.json"; else echo '{"templates":[]}' >"$TMP/built-from-tpl.json"; fi
  cp "$TMP/built-from.json" "$TMP/work-config.json"
  cp "$TMP/built-from-tpl.json" "$TMP/work-tpl.json"
  CFG=$TMP/work-config.json TPL_FILE=$TMP/work-tpl.json
  "$@"
  CFG=$CFG_LIVE TPL_FILE=$TPL_LIVE
}

# Build first, then stop the daemon and install. Every check (theme, jq,
# templates, byte ranges) has passed before the daemon goes down. If the live
# file changed between the build and the stop (the daemon rewrites serials),
# rebuild from it; the EXIT trap covers a failure there.
apply_lianli() {
  INSTALLED=
  pkill -x lianli-gui || true
  build_lianli "$@"
  daemon_stop
  if ! cmp -s "$CFG_LIVE" "$TMP/built-from.json" ||
     { [[ -f $TPL_LIVE ]] && ! cmp -s "$TPL_LIVE" "$TMP/built-from-tpl.json"; }; then
    log "Lian Li config changed while building; rebuilding"
    build_lianli "$@"
  fi
  mkdir -p "$TMP/prev"
  cp "$CFG_LIVE" "$TMP/prev/config.json"
  if [[ -f $TPL_LIVE ]]; then cp "$TPL_LIVE" "$TMP/prev/tpl.json"; fi
  cp "$CFG_LIVE" "$CFG_LIVE.bak-pc-lights"
  CFG_GOOD= INSTALLED=1
  cp "$TMP/work-config.json" "$CFG_LIVE"
  cp "$TMP/work-tpl.json" "$TPL_LIVE"
}

# Start the daemon and check it took the new config. For lights, also make
# sure every device got its lighting: a wireless device that misses discovery
# at startup is skipped and never retried, so restart (up to 3 tries) until no
# "Failed to apply RGB config" shows up. A "Failed to load config" means the
# daemon rejected the file: stop it and let the EXIT trap restore the
# previous config and start it again.
start_daemon_checked() {
  local what=${1:-lights} try since journal
  for try in 1 2 3; do
    since=$(date '+%Y-%m-%d %H:%M:%S')
    daemon_start
    if [[ $what == lights ]]; then sleep 25; else sleep 8; fi
    # Read the journal first: piped into grep -q under pipefail, a match
    # SIGPIPEs journalctl and the pipeline reads as "no failure" (this check
    # never fired before 2026-09-24).
    journal=$(journalctl --user -u lianli-daemon --since "$since" --no-pager 2>/dev/null || true)
    if grep -q 'Failed to load config' <<<"$journal"; then
      log "lianli-daemon rejected the new config: $(grep -m1 'Failed to load config' <<<"$journal" | sed 's/.*Failed to load config: //')"
      daemon_stop
      die "new Lian Li config rejected; restoring the previous one"
    fi
    CFG_GOOD=1
    [[ $what == lights ]] || return 0
    if ! grep -q 'Failed to apply RGB config' <<<"$journal"; then
      RUN_MISSED=()
      return 0
    fi
    missed_devices "$journal"
    echo "pc-lights: a device missed its lighting (try $try), restarting daemon" >&2
    daemon_stop
  done
  daemon_start
  echo "pc-lights: some device still missed its lighting after 3 tries" >&2
}

# USB serial -> the daemon's "hid:1cbe:<pid>:<usb path>" form, via sysfs. The
# daemon rewrites serials into that form, so theme entries match either.
usb_serial_map() {
  local d
  {
    for d in /sys/bus/usb/devices/*; do
      [[ -f $d/idVendor && $(cat "$d/idVendor") == 1cbe && -f $d/serial ]] || continue
      printf '{"serial":"%s","path":"hid:1cbe:%s:%s"}\n' "$(cat "$d/serial")" "$(cat "$d/idProduct")" "$(basename "$d")"
    done
  } | jq -s 'map({(.serial): .path}) | add // {}' >"$TMP/usbmap.json"
  echo "$TMP/usbmap.json"
}

# Screen brightness: 0 while the user has the screens off (pc-lights off
# screens wins over any theme), otherwise the theme's per-screen "brightness"
# (0-100), otherwise none (the daemon's default, 100).
brightness_jq='
  def theme_brightness($sc): if $scr == "off" then {brightness: 0}
    elif $sc.brightness != null then {brightness: $sc.brightness} else {} end;'

# Apply the theme's "screens" (media per LCD, keyed by USB serial) and
# install its "templates" into lcd_templates.json, into $CFG/$TPL_FILE (the
# scratch copies build_lianli points them at). $1 = the EFF (default: the
# active theme's). Building changes nothing live: when screens are rebuilt it
# sets SCREENS_RESET, and lianli_lights restarts the clip rotation only once
# the apply went through (render used to delete clips.json).
SCREENS_RESET=
apply_scheme_screens() {
  local sf=${1:-} root map miss
  [[ -n $sf ]] || sf=$(scheme_file)
  root=$(theme_dir)
  jq -e '.screens | length > 0' "$sf" >/dev/null 2>&1 || return 0
  map=$(usb_serial_map)
  # A theme screen with no config entry is left alone, never appended: the
  # config only knows screens by the "hid:1cbe:..." form, so a screen that is
  # off USB right now (TL fan LCDs drop off after a shutdown until
  # lianli-wake-fan-lcds wakes them) can't be matched, and an extra raw-serial
  # entry is never what the daemon wants.
  miss=$(jq -r --slurpfile m "$map" --slurpfile c "$CFG" '
    ($m[0]) as $paths | .screens[] | .serial as $ser | ($paths[$ser] // null) as $hid
    | select([$c[0].lcds[] | select(.serial == $ser or ($hid != null and .serial == $hid))] | length == 0)
    | $ser' "$sf")
  [[ -z $miss ]] || log "screen(s) not on USB or not in the config, left as they are: $(echo $miss)"
  rewrite_config --slurpfile s "$sf" --slurpfile m "$map" --arg root "$root" \
    --arg scr "$(screens_state)" "$brightness_jq"'
    def abs: if . == null or startswith("/") then . else $root + "/" + . end;
    ($m[0]) as $paths
    | reduce ($s[0].screens[]) as $sc (.;
        ($sc.serial) as $ser | ($paths[$ser] // null) as $hid
        | ([.lcds[] | select(.serial == $ser or ($hid != null and .serial == $hid))] | first) as $old
        | ($sc | with_entries(select(.key | startswith("_") | not))
            | {serial: ($hid // $ser), type, path: (.path | abs), orientation, template_id: (.template_id // null)}
            + theme_brightness($sc)) as $new
        | if $old then .lcds |= map(if . == $old then (($old | del(.brightness)) + $new) else . end)
          else . end)'
  local t tf=$TPL_FILE
  [[ -f $tf ]] || echo '{"templates":[]}' >"$tf"
  for t in $(jq -r '.templates[]?' "$sf"); do
    [[ -f $root/$t ]] || die "theme template $root/$t not found"
    jq --arg root "$root" '
      def abs: if . == null or startswith("/") then . else $root + "/" + . end;
      .background.path |= abs
      | .widgets |= map(.kind.font.path |= abs | if .kind.path then .kind.path |= abs else . end)
      | del(.widgets[].kind.font | select(.path == null))' "$root/$t" >"$TMP/newtpl.json"
    jq --slurpfile n "$TMP/newtpl.json" '.templates = ([.templates[] | select(.id != $n[0].id)] + $n)' "$tf" >"$TMP/tpl.json"
    [[ -s $TMP/tpl.json ]] || die "template merge produced an empty file"
    cp "$TMP/tpl.json" "$tf"
  done
  # Every screen is back on its "path": the clip rotation starts over (after the apply).
  SCREENS_RESET=1
}

# Heat warning: the daemon's thermal_alert repaints all Lian Li gear one colour
# while the CPU or GPU is over its threshold (it fills every LED of every zone,
# so unlike TL Static it needs no per-fan colours). Global defaults in
# alerts.json, per-theme "alert" overrides colour/thresholds. Off = dark means
# dark, so the alert is disabled while the lights are off.
thermal_alert_json() {
  local state=$1 sf=${2:-} af=$STATE_DIR/alerts.json g='{}'
  # "on" runs validate_theme first, which refuses a broken alerts.json; "off"
  # only needs .enabled, so a broken file must not block going dark.
  if [[ -f $af ]]; then
    if jq -e 'type == "object"' "$af" >/dev/null 2>&1; then g=$(cat "$af")
    else log "$af is not a JSON object; using the built-in alert defaults"; fi
  fi
  jq -n --arg state "$state" --argjson g "$g" \
    --argjson t "$( [[ -n $sf ]] && jq '.alert // {}' "$sf" || echo '{}')" "$rgb_jq"'
    # u8 in the daemon: whole degrees, clamped to 0-255. ("enabled": false must
    # stay false: the jq alternative operator would turn it into the default.)
    def deg: if type == "number" then floor | if . < 0 then 0 elif . > 255 then 255 else . end
             else error("bad alert threshold \(tojson)") end;
    def src($k; $def):
      {enabled: ($state == "on" and $g.enabled != false and $g[$k].enabled != false),
       threshold: ($t[$k].threshold // $g[$k].threshold // $def | deg),
       alert_color: ($t[$k].color // $t.color // $g[$k].color // $g.color // "ff0000" | rgb)};
    {cpu: src("cpu"; 90), gpu: src("gpu"; 85)}'
}

# Wait (up to 60 s) until every device the config already knows shows up in
# GetRgbCapabilities: a flaky wireless device can be missing from one query.
fetch_caps() {
  local tries=${1:-12} want have i
  want=$(jq '[.rgb.devices[]?.device_id] | length' "$CFG")
  for i in $(seq 1 "$tries"); do
    daemon_call '{"method":"GetRgbCapabilities"}' >"$TMP/caps.json" || true
    have=$(jq --slurpfile cfg "$CFG" '[(.data // .)[].device_id] as $ids
      | [$cfg[0].rgb.devices[]?.device_id | select(. as $d | $ids | index($d))] | length' "$TMP/caps.json" 2>/dev/null || echo 0)
    [[ $have -ge $want ]] && break
    (( i < tries )) && sleep 5
  done
  jq -e '(.data // .) | length > 0' "$TMP/caps.json" >/dev/null 2>&1 ||
    die "daemon returned no RGB devices"
  [[ $have -ge $want ]] || echo "pc-lights: $((want - have)) known device(s) still missing, keeping their old entries" >&2
}

# ---- binding: daemon device_id -> profile role (plan §5) ---------------------------
# be_lianli_bind writes $TMP/bind.json: {device_id: {key, role, managed, effect}}
# for every device the daemon reports that a profile device matches, tried in
# this order: the wireless MAC, the LCD's USB serial (via sysfs), the HID
# serial, the last seen device_id (seen_id, or match.device_id), then the
# family when both the daemon and the profile have exactly one of it. The
# role is the first profile role naming that device key; effect is the effect
# class the role drives (fan, strimer, ring; null = by device name, as before).
# No profile: {} and no daemon call at all, which is the legacy path exactly.
be_lianli_bind() {
  local pf map
  echo '{}' >"$TMP/bind.json"
  pf=$(be_profile) || return 0
  daemon_call '{"method":"ListDevices"}' >"$TMP/list.json" 2>/dev/null || echo '{}' >"$TMP/list.json"
  jq -e . "$TMP/list.json" >/dev/null 2>&1 || echo '{}' >"$TMP/list.json"
  map=$(usb_serial_map)
  jq -n --slurpfile p "$pf" --slurpfile l "$TMP/list.json" --slurpfile c "$TMP/caps.json" --slurpfile m "$map" '
    def arr: if type == "array" then . else [] end;
    $p[0] as $P
    | ($l[0] | (.data // .) | arr) as $L
    | ($c[0] | (.data // .) | arr) as $C
    | ($m[0] // {}) as $usb
    | ([$L[] | {key: .device_id, value: .}] | from_entries) as $ld
    | [$P.devices // {} | to_entries[] | select(.value.backend == "lianli")] as $D
    # The first role that names a device key wins (from_entries keeps the last).
    | ([$P.roles // {} | to_entries[] | .key as $r | .value | objects
        | (.managed != false) as $mg | ([.device] + (.devices // []))[] | strings
        | {key: ., value: {role: $r, managed: $mg}}] | reverse | from_entries) as $rk
    | def famcount($f): [$L[] | select(.family == $f)] | length;
      def pfamcount($f): [$D[] | select(.value.match.family == $f)] | length;
      def keyof($id):
        ($ld[$id] // {}) as $dev
        | first(
            ($D[] | select(.value.match.mac != null and $id == "wireless:" + .value.match.mac) | .key),
            ($D[] | select(.value.match.usb_serial != null and $usb[.value.match.usb_serial] == $id) | .key),
            ($D[] | select(.value.match.serial != null and $dev.serial != null
                           and ($id | startswith("wireless:") | not) and $dev.serial == .value.match.serial) | .key),
            ($D[] | select(.value.seen_id == $id or .value.match.device_id == $id) | .key),
            ($D[] | select(.value.match.family != null and $dev.family == .value.match.family
                           and famcount($dev.family) == 1 and pfamcount($dev.family) == 1) | .key)
          ) // null;
      def effect($r):
        if $r == null then null
        elif $r | test("^fans\\.") then "fan"
        elif $r | test("^strimers?\\.") then "strimer"
        elif $r | test("^pump\\.|\\.ring$") then "ring"
        else null end;
    [$C[].device_id, $L[].device_id] | unique
    | map(. as $id | keyof($id) as $k | select($k != null)
          | ($rk[$k] // {role: null, managed: true}) as $b
          | {key: $id, value: {key: $k, role: $b.role, managed: $b.managed, effect: effect($b.role)}})
    | from_entries' >"$TMP/bind.json" || die "could not bind the Lian Li devices to the profile"
  # A device the profile doesn't know gets the theme's group colours by its
  # name, as before the profile; say so (status --json reports "stale").
  local stale
  stale=$(jq -r --slurpfile b "$TMP/bind.json" '[(.data // .)[] | .device_id | select($b[0][.] == null)] | join(" ")' "$TMP/caps.json")
  [[ -z $stale ]] || log "profile stale: Lian Li device(s) not in the profile, driven by name: $stale (run pc-lights detect)"
}

# The .rgb/.thermal_alert filter write_lianli_rgb runs on the config (with
# rgb_jq in front). A constant so the theme preview (lianli_effect_plan)
# builds the very same device entries: moved here verbatim from
# write_lianli_rgb, which tests/golden/run.sh proves byte for byte. Inputs:
# $c (GetRgbCapabilities), $s (the EFF), $ta (thermal_alert), $bind
# (be_lianli_bind), $state (on|off).
# shellcheck disable=SC2016 # jq, not shell
LIANLI_RGB_JQ='
    ($s[0] // {}) as $sc
    | ($bind[0] // {}) as $bind
    | (.rgb.devices // []) as $old
    | .thermal_alert = $ta[0]
    | .rgb = (.rgb // {enabled: true, openrgb_server: false, openrgb_port: 6743})
    | .rgb.devices = [ ($c[0].data // $c[0])[]
        | (.device_name // .name // "") as $name
        | (($bind[.device_id] // {}) | if .role != null then . else {} end) as $b
        | .device_id as $id
        | if $state == "on" and $b.role == "ignore" then empty
          elif $state == "on" and $b.managed == false then ($old[] | select(.device_id == $id))
          else
          ($sc + ($sc._roles[$b.role // ""] // {})) as $sc
          # TL Static takes colors[fan] per fan (unfilled slots fall back to the
          # renderer defaults, which showed as green/blue fans), so fill all 4.
          # A list gives one colour per fan in the group (fan 1..4; the last one
          # repeats for fans beyond the list): e.g. a bright-to-dark column.
          | def static($hex): (if ($hex | type) == "array" then [$hex[] | rgb] else [$hex | rgb] end) as $l
              | {mode: "Static", colors: [range(0; 4) as $i | $l[[$i, ($l | length) - 1] | min]], speed: 2, brightness: 4, disabled: false};
          def on_effect:
            if test("Strimer") then
              {mode: $sc.strimers.mode, colors: [$sc.strimers.colors[] | rgb], speed: $sc.strimers.speed,
               brightness: ($sc.strimers.brightness // 4), direction: $sc.strimers.direction, disabled: false}
            elif test("HydroShift|Universal Screen") then static($sc.rings)
            else static($sc.fans.bottom)
            end;
          # The wired TL receivers are the same fans seen over USB (V1 dongle) and
          # drive no visible LEDs, so "on" leaves them to the RF path.
          def tl_regions:
            [ {effect: (static($sc.fans.top) + {scope: "Top"}), flip: false},
              {effect: (static($sc.fans.bottom) + {scope: "Bottom"}), flip: false} ];
          # A bound device picks its effect by role (a name on_effect maps to
          # that class); inner/outer regions go to fan roles whose device has
          # Top/Bottom scopes. Unbound: by device name, as before.
          ({fan: "fan", strimer: "Strimer", ring: "HydroShift"}[$b.effect // ""] // $name) as $ename
          | (if $b.effect == "fan" then (.effect_regions // [] | index("Top") != null)
             elif $b.effect != null then false
             else ($name | test("TL V3")) end) as $tl
          | select($state == "off" or $b.role != null or ($name | test("TL Flex LCD Controller") | not))
          | {device_id, mb_rgb_sync: false,
             zones: [ range(0; .zones | length) as $i
               | {zone_index: $i, swap_lr: false, swap_tb: false,
                  effect: (if $state == "off" then
                             {mode: "Off", colors: [[0,0,0]], speed: 2, brightness: 0, disabled: true}
                           else
                             ($ename | on_effect)
                           end)} ]}
          + (if $state == "on" and $tl then {regions: tl_regions} else {} end)
          end ]
      + [ $old[] | select(.device_id as $d | [($c[0].data // $c[0])[].device_id] | index($d) | not) ]'

# Rewrite .rgb and .thermal_alert (and, for "on", the screens and templates)
# for $state from $TMP/caps.json, into $CFG/$TPL_FILE: scratch copies, via
# build_lianli or render. $2 = the EFF (default: the active theme's).
# A device bound to a role gets the theme's value for that role:
# $sc + $sc._roles[role] (a v2-shaped partial) is what the unchanged static,
# on_effect and tl_regions below see. An unbound device (or no profile) gets
# the group values by its name, exactly as before. With "on", a managed:false
# role keeps the device's current entry, and an "ignore"d one (the wired TL
# receivers, the same fans seen over USB) is left out like the name rule
# leaves them out; "off" turns every device Off, as before.
write_lianli_rgb() {
  local state=$1 sf=
  [[ $state == on ]] && sf=${2:-$(scheme_file)}
  thermal_alert_json "$state" "$sf" >"$TMP/alert.json"
  be_lianli_bind
  rewrite_config --slurpfile c "$TMP/caps.json" --slurpfile s "${sf:-/dev/null}" \
    --slurpfile ta "$TMP/alert.json" --slurpfile bind "$TMP/bind.json" --arg state "$state" "$rgb_jq$LIANLI_RGB_JQ"
  [[ $state == on ]] && apply_scheme_screens "$sf"
  return 0
}

# ---- the theme preview's Lian Li plan (plan §1.5) ----------------------------
# lianli_effect_plan <eff> <base.json> <out-devices.json> <out-requests.jsonl> [force.json] [from-config.json]
# The .rgb.devices "on" would write for <eff>, built exactly as
# write_lianli_rgb builds them (LIANLI_RGB_JQ, one GetRgbCapabilities, the
# profile binding) on a scratch copy of <from-config> (default CFG_LIVE),
# without the screens and with the heat alert left as it is; then the
# SetRgbEffect requests that turn <base.json> (a .rgb.devices list: what the
# case shows now) into it. Pure: scratch files and read-only daemon calls.
lianli_effect_plan() {
  local eff=$1 base=$2 out=$3 reqs=$4 force=${5:-/dev/null} from=${6:-$CFG_LIVE}
  cp "$from" "$TMP/pv-config.json"
  CFG=$TMP/pv-config.json
  fetch_caps 1
  jq -c '.thermal_alert // null' "$TMP/pv-config.json" >"$TMP/alert.json"
  be_lianli_bind
  rewrite_config --slurpfile c "$TMP/caps.json" --slurpfile s "$eff" \
    --slurpfile ta "$TMP/alert.json" --slurpfile bind "$TMP/bind.json" --arg state on "$rgb_jq$LIANLI_RGB_JQ"
  CFG=$CFG_LIVE
  jq '.rgb.devices // []' "$TMP/pv-config.json" >"$out"
  lianli_effect_requests "$out" "$base" "$force" >"$reqs"
}

# lianli_effect_requests <devices.json> <base.json> [force.json]: one
# SetRgbEffect a line for every zone or region of <devices> that differs
# from <base> (/dev/null: every one), and for every zone or region of the
# device ids listed in <force>. A device with regions (TL fans: Top/Bottom)
# sends one per region on zone 0, the region's effect carrying its scope;
# any other device one per zone, on its zone_index.
# shellcheck disable=SC2016 # jq, not shell
LIANLI_EFFECT_REQ_JQ='
  (($b[0] // []) | map({key: .device_id, value: .}) | from_entries) as $base
  | (($f[0] // []) | map(strings)) as $force
  | ($n[0] // [])[] | . as $d | ($base[$d.device_id] // null) as $o
  | ($force | index($d.device_id) != null) as $all
  | if ($d.regions | type) == "array" and ($d.regions | length) > 0 then
      $d.regions | to_entries[]
      | select($all or $o == null or (($o.regions // [])[.key] // null) != .value)
      | {method: "SetRgbEffect", params: {device_id: $d.device_id, zone: 0, effect: .value.effect}}
    else
      ($d.zones // [])[] | . as $z
      | select($all or $o == null or ([($o.zones // [])[] | select(.zone_index == $z.zone_index)] | first) != $z)
      | {method: "SetRgbEffect", params: {device_id: $d.device_id, zone: $z.zone_index, effect: $z.effect}}
    end'
lianli_effect_requests() {
  jq -nc --slurpfile n "$1" --slurpfile b "$2" --slurpfile f "${3:-/dev/null}" "$LIANLI_EFFECT_REQ_JQ"
}

# ---- the theme preview's screens part (screens plan §3.1) --------------------
# lianli_screen_plan <eff> <draft> <plan.json> <requests.jsonl> [state dir]
# What each screen must show for the draft's EFF, and the requests that get
# it there. Per EFF screens[] entry (keyed by USB serial):
#   - its role: the profile screen role whose device has that serial;
#   - its config entry: the CFG_LIVE .lcds[] entry whose serial is the USB
#     serial or its hid:1cbe:... form (apply_scheme_screens' match); none:
#     skipped "not-in-config" (never appended: the daemon would add a second
#     entry);
#   - its media resolved for the draft (editor_draft_abspath: the stage, then
#     the media root; absolute, never a scratch path); missing: "missing";
#     a template the daemon doesn't have (TPL_LIVE): "template-missing" (the
#     preview never installs templates);
#   - want = the saved entry (the first-touch snapshot, else CFG_LIVE's)
#     without brightness + {serial: <config serial>, type, path, orientation,
#     template_id} + the entry's brightness when it sets one;
#   - compared with what the screen shows now (the preview's last write for a
#     screen it touched, else CFG_LIVE): "media" when type, path, orientation
#     or template differ (SetLcdMedia, device_id "serial:<config serial>",
#     persisted, a config reload), else "brightness" when the brightness does
#     (SetLcdBrightness, the bare config serial, not persisted), else "none".
# A screen the session touched whose role has no entry any more gets its
# saved entry back ("restore"). <plan.json>: {screens: [{role, serial, cs,
# what, reason, restore, want}]}; <requests.jsonl>: one request a line.
# Pure: reads CFG_LIVE, TPL_LIVE, the USB serial map, the profile and the
# state dir ($CACHE/preview: saved-lcds.json, applied-lcds.json,
# touched-lcds.json); writes only its two outputs.
lianli_screen_plan() {
  local eff=$1 draft=$2 plan=$3 reqs=$4 sd=${5:-$CACHE/preview} map pf rel abs
  map=$(usb_serial_map)
  pf=$(be_profile) || pf=/dev/null
  : >"$TMP/scr-abs.tsv"
  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    if abs=$(editor_draft_abspath "$draft" "$rel" 2>/dev/null) && [[ -f $abs ]]; then printf '%s\t%s\n' "$rel" "$abs" >>"$TMP/scr-abs.tsv"; fi
  done < <(jq -r '.screens[]? | objects | .path | strings' "$eff" 2>/dev/null | sort -u)
  jq -n -L "$PCL_LIB" --slurpfile e "$eff" --slurpfile c "$CFG_LIVE" --slurpfile p "$pf" --slurpfile m "$map" \
    --slurpfile tp <(cat "$TPL_LIVE" 2>/dev/null || echo '{}') --rawfile abs "$TMP/scr-abs.tsv" \
    --slurpfile sv <(cat "$sd/saved-lcds.json" 2>/dev/null || echo '{}') \
    --slurpfile ap <(cat "$sd/applied-lcds.json" 2>/dev/null || echo '{}') \
    --slurpfile tc <(cat "$sd/touched-lcds.json" 2>/dev/null || echo '{}') '
    include "theme";
    ($p[0] // {}) as $P | ($m[0] // {}) as $usb | ($c[0].lcds // []) as $lcds
    | ([($tp[0].templates // [])[]? | .id | strings]) as $tids
    | ($abs | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}) as $abs
    | ($sv[0] | objects // {}) as $saved | ($ap[0] | objects // {}) as $applied | ($tc[0] | objects // {}) as $touched
    | ([screen_roles($P)[] | . as $R | (th_role_dev($P) // {}) as $dv
        | {key: ($dv.match.usb_serial // ($dv._key // "" | ltrimstr("lianli:lcd:"))), value: $R}] | from_entries) as $roleof
    | def cfg_of($ser): ($usb[$ser] // null) as $hid
        | first($lcds[] | select(.serial == $ser or ($hid != null and .serial == $hid))) // null;
      def same_media($a; $b): ($a.type == $b.type) and (($a.path // null) == ($b.path // null))
        and (($a.orientation // 0) == ($b.orientation // 0)) and (($a.template_id // null) == ($b.template_id // null));
      def cfg_of_cs($cs): first($lcds[] | select(.serial == $cs)) // null;
      def classify($want; $cs): (if $touched[$cs] != null then ($applied[$cs] // cfg_of_cs($cs)) else cfg_of_cs($cs) end) as $base
        | if $base == null or (same_media($want; $base) | not) then "media"
          elif ($want.brightness // 100) != ($base.brightness // 100) then "brightness" else "none" end;
    [ ($e[0].screens // [])[] | objects | . as $sc | ($roleof[$sc.serial] // null) as $R | cfg_of($sc.serial) as $old
      | {role: $R, serial: $sc.serial, cs: ($old.serial // null), restore: false}
      + if $old == null then {what: "skip", reason: "not-in-config", want: null}
        elif $sc.type != "custom" and $abs[$sc.path // ""] == null then {what: "skip", reason: "missing", want: null}
        elif $sc.type == "custom" and ($tids | index($sc.template_id) | not) then {what: "skip", reason: "template-missing", want: null}
        else ($old.serial) as $cs
          | ((($saved[$cs] // $old) | del(.brightness))
             + {serial: $cs, type: $sc.type, path: (if $sc.type == "custom" then null else $abs[$sc.path] end),
                orientation: $sc.orientation, template_id: ($sc.template_id // null)}
             + (if $sc.brightness != null then {brightness: $sc.brightness} else {} end)) as $want
          | {what: classify($want; $cs), reason: null, want: $want} end ] as $rows
    | ([$rows[] | .cs | strings]) as $covered
    | ($rows + [$touched | to_entries[] | select(.key as $k | $covered | index($k) | not) | .key as $cs
                | ($saved[$cs] // null) as $want | select($want != null)
                | {role: (.value.role // null), serial: null, cs: $cs, restore: true, reason: null, want: $want,
                   what: classify($want; $cs)}]) as $all
    | {screens: $all}' >"$plan" || return 1
  jq -c '.screens[] | select(.what == "media" or .what == "brightness")
    | if .what == "media" then {method: "SetLcdMedia", params: {device_id: ("serial:" + .cs), config: .want}}
      else {method: "SetLcdBrightness", params: {device_id: .cs, brightness: (.want.brightness // 100)}} end' "$plan" >"$reqs"
}

# The lights through the daemon (a thin wrapper: the contract test stubs it by
# this name). Skipped with a note when there is no Lian Li gear to drive.
lianli_lights() {
  local state=$1
  if backend_skipped lianli; then log "lianli: skipped ($(jq -r '.message // .state' <<<"${BE_STATE[lianli]}"))"; return 0; fi
  systemctl --user is-active -q lianli-daemon || die "lianli-daemon is not running"
  [[ $state == on ]] && validate_theme "$(theme_name)"
  be_lianli_apply "$state"
}

# Screen brightness only: 0 for off; back on, the theme's per-screen
# brightness, or the default for the rest.
screens_config() {
  local state=$1 sf map
  if [[ $state == off ]]; then
    rewrite_config '.lcds |= map(.brightness = 0)'
    return 0
  fi
  sf=$(scheme_file); map=$(usb_serial_map)
  rewrite_config --slurpfile s "$sf" --slurpfile m "$map" --arg scr on "$brightness_jq"'
    ($m[0]) as $paths
    | .lcds |= map(del(.brightness))
    | reduce ($s[0].screens // [] | .[]) as $sc (.;
        ($sc.serial) as $ser | ($paths[$ser] // null) as $hid
        | .lcds |= map(if .serial == $ser or ($hid != null and .serial == $hid)
                       then . + theme_brightness($sc) else . end))'
}

lianli_screens() {
  local state=$1
  if backend_skipped lianli; then log "lianli: skipped ($(jq -r '.message // .state' <<<"${BE_STATE[lianli]}"))"; return 0; fi
  [[ $state == on ]] && validate_theme "$(theme_name)"
  be_lianli_screens "$state"
}

# ---- the §8 interface -----------------------------------------------------------
be_lianli_kinds() { echo "fan_group strimer ring lcd"; }

# Cheap: no socket writes, no device probes. absent = lian-li-linux isn't
# installed; no-devices = the profile lists no Lian Li device; down = it is
# installed but the daemon isn't running (the callers die on that, as before).
be_lianli_probe() {
  local pf
  if ! systemctl --user is-active -q lianli-daemon 2>/dev/null &&
     ! command -v lianli-daemon >/dev/null 2>&1 && [[ ! -S $SOCK ]]; then
    echo '{"state":"absent","message":"lian-li-linux is not installed"}'; return 0
  fi
  if pf=$(be_profile) && ! jq -e '[.devices // {} | .[] | select(.backend == "lianli")] | length > 0' "$pf" >/dev/null 2>&1; then
    echo '{"state":"no-devices","message":"no Lian Li devices in the profile"}'; return 0
  fi
  if ! systemctl --user is-active -q lianli-daemon 2>/dev/null; then
    echo '{"state":"down","message":"lianli-daemon is not running"}'; return 0
  fi
  echo '{"state":"ok"}'
}

# be_lianli_detect <outdir>: <outdir>/lianli.json in the §8 shape {backend,
# state, version, devices: {key: Device}} (plus message, scanned and the
# config's screens in config_lcds), from the daemon's read-only calls
# (GetDaemonInfo, ListDevices, GetRgbCapabilities, GetConfig) and sysfs. A thin
# wrapper over detect.sh's detect_lianli, the one Lian Li scanner; it also
# leaves the raw replies beside it (ListDevices.json, usb.json, ...).
be_lianli_detect() {
  mkdir -p "$1"
  detect_lianli "$1"
}

# be_lianli_validate <eff>: the roles the profile binds must have a value the
# daemon can take, one problem per line.
be_lianli_validate() {
  local pf
  pf=$(be_profile) || return 0
  jq -r --slurpfile p "$pf" '
    . as $e
    | $p[0].roles // {} | to_entries[] | select(.value | objects | (.managed != false))
    | .key as $r
    | select($e._roles != null and ($r | test("^(fans|strimers?|pump)\\.|\\.ring$")))
    | ($e + ($e._roles[$r] // {})) as $sc
    | if ($r | test("^fans\\.")) and ($sc.fans.top == null or $sc.fans.bottom == null) then "\($r): no fan colours (fans.top/bottom)"
      elif ($r | test("^strimers?\\.")) and ($sc.strimers.colors | type) != "array" then "\($r): no strimer effect"
      elif ($r | test("^pump\\.|\\.ring$")) and $sc.rings == null then "\($r): no ring colour"
      else empty end' "$1"
}

# be_lianli_build <state> [eff]: the new config and template file in
# $TMP/work-config.json / work-tpl.json (built from $CFG_LIVE / $TPL_LIVE,
# which stay untouched), from the capabilities read once.
be_lianli_build() {
  fetch_caps 1
  build_lianli write_lianli_rgb "$@"
}

be_lianli_render() {
  echo "# .rgb"; jq '.rgb' "$TMP/work-config.json"
  echo "# .lcds"; jq '.lcds' "$TMP/work-config.json"
  echo "# .thermal_alert"; jq -c '.thermal_alert' "$TMP/work-config.json"
  echo "# templates installed: $(jq -r --slurpfile o "$TMP/built-from-tpl.json" \
    '[.templates[] | select(. as $t | ($o[0].templates | index($t)) | not) | .id] | join(" ")' "$TMP/work-tpl.json")"
}

# be_lianli_apply <state>: build against the live daemon's capabilities (up to
# 60 s for a flaky wireless device) and send it live, restarting the daemon
# only as a fallback. A theme whose screens were rebuilt restarts the clip
# rotation once the apply went through.
be_lianli_apply() {
  local state=$1
  SCREENS_RESET=
  fetch_caps 12
  apply_live_or_restart lights write_lianli_rgb "$state"
  if [[ -n $SCREENS_RESET ]]; then rm -f "$CLIPS_STATE"; fi
}

be_lianli_screens() {
  apply_live_or_restart screens screens_config "$1"
}
