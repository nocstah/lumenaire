#!/usr/bin/env bash
# measure.sh — the theme preview's one-time hardware check (editor plan §5, WP-M).
#
#   tests/preview/measure.sh [--engine PATH] [--only M1,M2,...]
#   lumenaire theme preview --measure          (the same, with this engine)
#
# INTERACTIVE, ON THE REAL CASE. Every step changes the lighting, so each one
# asks first (y = run it, n = skip it, q = stop), tells you what to look for,
# asks what you saw, and then sends the saved look back and asks you to
# confirm it is back. If a step leaves anything wrong, answer "n" at the
# restore question and the script re-applies the active theme in full
# ("lumenaire pick <active>", about 20 s). Automated tests never run this.
#
#   M1  guarded SetRgbEffect on one TL fan group, scope Top: latency, visible,
#       and ~/.config/lianli/config.json plus GetConfig unchanged (not persisted)
#   M2  a Strimer: Drizzling with 6 colours, speed and direction (RgbEffect
#       says "up to 4" colours; the preview needs 6)
#   M3  the pump ring (HydroShift II maps All to Pump) and the 8.8" screen ring
#   M4  the revert from the saved config: must look exactly like before
#   M5  a clip swap (clips next: SetLcdMedia, a config reload) during a
#       preview: does the reload bring the saved lighting back?
#   M6  SetRgbConfig (the fallback): reload latency, then the saved section back
#   M7  one OpenRGB apply of the active theme with the cached RAM ids (no
#       device listing): latency, and no RAM/GPU glitch
#   M8  systemctl --user restart lianli-daemon during a preview: the saved
#       look must come back by itself
#   M9  the screens (screens plan Q1, Q3, Q4): a guarded SetLcdMedia puts
#       another fan screen's clip on one fan screen (timed until the daemon's
#       telemetry says ready; the other screens keep streaming, the LEDs don't
#       blink), a SetLcdBrightness dims the pump (config.json unchanged: not
#       persisted), then the saved entries go back (config.json as before,
#       bar the daemon's own rewrites). It doesn't decide the method.
#
# Gate (plan §5): M1-M4 and M8 pass -> method "effect"; otherwise
# "rgbconfig" (it needs M6). At the end it offers to write the method to
# ~/.config/pc-lights/preview-method, which "theme preview" reads; the
# results go to ~/.cache/pc-lights/preview-measure.json either way.
#
# It holds the engine lock while it works (the schedule and clip timers and
# any apply wait), except around M5's clip swap, and refuses to start while
# a theme preview session is open or another run holds the lock.
# shellcheck disable=SC2016 # engine_eval takes bash code in single quotes
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
engine=$here/../../bin/lumenaire only=''
while (( $# )); do
  case $1 in
    --engine) engine=$2; shift 2 ;;
    --only) only=,$2,; shift 2 ;;
    *) sed -n '2,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
engine=$(readlink -f "$engine")
[[ -x $engine ]] || { echo "measure.sh: no engine at $engine" >&2; exit 2; }
[[ -t 0 || -r /dev/tty ]] || { echo "measure.sh: interactive only (no terminal)" >&2; exit 2; }

STATE=$HOME/.config/pc-lights CACHE=$HOME/.cache/pc-lights
CFG_LIVE=$HOME/.config/lianli/config.json
work=$(mktemp -d)
declare -A R=() NOTE=()
touched=()

finish() {
  if (( ${#touched[@]} )); then echo; echo "Sending the saved look back before stopping..."; restore_touched || true; fi
  if [[ -s $work/m9-revert.jsonl ]]; then echo "Sending the saved screens back before stopping..."; send "$work/m9-revert.jsonl" >/dev/null || true; fi
  exec 9>&- 2>/dev/null || true
  rm -rf "$work"
}
trap finish EXIT

# ---- helpers -------------------------------------------------------------------
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
# ask <question>: y -> 0, n -> 1, q -> stop.
ask() {
  local a
  while :; do
    read -r -p "$1 [y/n/q] " a </dev/tty || a=q
    case $a in
      y | Y | yes) return 0 ;;
      n | N | no) return 1 ;;
      q | Q) echo "Stopped."; exit 1 ;;
    esac
  done
}
wanted() { [[ -z $only || $only == *",$1,"* ]]; }

# engine_eval <bash>: run code inside the engine (every function defined, its
# globals set, nothing dispatched) through its PCL_TEST_OVERRIDES hook.
# Variables pass in through the environment (M_*).
engine_eval() {
  printf '%s\nexit 0\n' "$1" >"$work/eval.sh"
  PCL_TEST_OVERRIDES=$work/eval.sh "$engine" status
}
lock() { exec 9>"$CACHE/lock"; flock -w 10 9 || { echo "measure.sh: another run holds the lock; try again when it is idle" >&2; exit 1; }; }
unlock() { exec 9>&-; }

# send <requests.jsonl>: guarded, one batch; prints "<ms> <ok> <failed>" and
# the errors on stderr.
send() {
  M_REQ=$1 M_OUT=$work/out.jsonl engine_eval '
    t=${EPOCHREALTIME/./}
    daemon_guarded_batch "$M_REQ" "$M_OUT" || { echo "transport: $LIVE_ERR" >&2; exit 1; }
    ms=$(( (${EPOCHREALTIME/./} - t) / 1000 ))
    jq -r "select(.ok | not) | \"  \(.device_id) zone \(.zone): \(.error)\"" "$M_OUT" >&2
    echo "$ms $(jq -s "[.[] | select(.ok)] | length" "$M_OUT") $(jq -s "[.[] | select(.ok | not)] | length" "$M_OUT")"'
}
# The saved look of these devices, from config.json (what the engine's revert sends).
restore_ids() {
  printf '%s\n' "$@" | jq -R . | jq -s . >"$work/touched.json"
  M_T=$work/touched.json M_REQ=$work/revert.jsonl engine_eval '
    jq --slurpfile t "$M_T" "[.rgb.devices // [] | .[] | select(.device_id as \$d | \$t[0] | index(\$d))]" "$CFG_LIVE" >"$TMP/d.json"
    lianli_effect_requests "$TMP/d.json" /dev/null >"$M_REQ"'
  send "$work/revert.jsonl"
}
restore_touched() {
  local r
  r=$(restore_ids "${touched[@]}") || { echo "measure.sh: the revert could not be sent" >&2; return 1; }
  echo "  revert: ${r%% *} ms"
  touched=()
}
# After a step: saved look back, and the user's word on it; else a full re-apply.
restore_check() {
  local active
  (( ${#touched[@]} )) && restore_touched
  if ! ask "Does the case look exactly like before this step?"; then
    active=$(cat "$STATE/scheme")
    echo "Re-applying $active in full (about 20 s)..."
    unlock
    "$engine" pick "$active" || echo "measure.sh: the re-apply failed; run: lumenaire pick $active" >&2
    lock
    return 1
  fi
}
cfg_stamp() { printf '%s %s' "$(sha256sum <"$CFG_LIVE" | cut -c1-16)" "$(stat -c %Y "$CFG_LIVE")"; }
getconfig_sha() { engine_eval 'daemon_call "{\"method\":\"GetConfig\"}" | jq -S .data | sha256sum | cut -c1-16'; }
rgb() { jq -c '[.[] | [(.[0:2], .[2:4], .[4:6]) | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1]]]' <<<"$1"; }
# req <device_id> <zone> <effect json> >> file
req() { jq -nc --arg d "$1" --argjson z "$2" --argjson e "$3" '{method: "SetRgbEffect", params: {device_id: $d, zone: $z, effect: $e}}'; }

# ---- preflight -------------------------------------------------------------------
say "Theme preview hardware check (engine: $engine)"
[[ $(cat "$STATE/lights" 2>/dev/null || echo on) == on ]] || { echo "The lights are off; turn them on first (lumenaire on)." >&2; exit 1; }
systemctl --user is-active -q lianli-daemon || { echo "lianli-daemon is not running." >&2; exit 1; }
if [[ -f $CACHE/preview.json ]] && jq -e '.state != "ended"' "$CACHE/preview.json" >/dev/null 2>&1; then
  echo "A theme preview session is open; end it first (lumenaire theme preview --end)." >&2; exit 1
fi
lock
active=$(cat "$STATE/scheme")
engine_eval 'daemon_call "{\"method\":\"GetRgbCapabilities\"}"' >"$work/caps.json"
jq -e '(.data // .) | length > 0' "$work/caps.json" >/dev/null || { echo "The daemon reports no RGB devices." >&2; exit 1; }
pick_dev() { jq -r --arg re "$1" --arg need "${2:-}" '[(.data // .)[] | select(.device_name | test($re))
  | select($need == "" or ((.effect_regions // []) | index($need)))][0].device_id // empty' "$work/caps.json"; }
TL=$(pick_dev 'TL V3' Top) STRIMER=$(pick_dev 'Strimer') PUMP=$(pick_dev 'HydroShift') RING=$(pick_dev 'Universal Screen')
name_of() { jq -r --arg d "$1" '[(.data // .)[] | select(.device_id == $d)][0].device_name // "?"' "$work/caps.json"; }
echo "Active theme: $active"
echo "TL fan group: ${TL:-none} ($(name_of "${TL:-x}"))"
echo "Strimer:      ${STRIMER:-none}"
echo "Pump ring:    ${PUMP:-none}"
echo "8.8\" ring:    ${RING:-none}"
echo "Take a photo of the case now if you want to compare against it in M4."
ask "Start?" || exit 0
green=$(rgb '["00ff00","00ff00","00ff00","00ff00"]')
static_green=$(jq -nc --argjson c "$green" '{mode: "Static", colors: $c, speed: 2, brightness: 4, disabled: false}')

# ---- M1 ------------------------------------------------------------------------------
if wanted M1 && [[ -n $TL ]]; then
  say "M1: SetRgbEffect on $TL, scope Top (the inner ring of that fan group turns green)"
  if ask "Run M1?"; then
    s0=$(cfg_stamp) g0=$(getconfig_sha)
    req "$TL" 0 "$(jq -c '. + {scope: "Top"}' <<<"$static_green")" >"$work/m1.jsonl"
    touched=("$TL"); r=$(send "$work/m1.jsonl") || r="0 0 1"
    echo "  sent in ${r%% *} ms (ok/failed: ${r#* })"
    sleep 2
    s1=$(cfg_stamp) g1=$(getconfig_sha)
    [[ $s0 == "$s1" && $g0 == "$g1" ]] && NOTE[M1]="config.json and GetConfig unchanged" || NOTE[M1]="PERSISTED: config.json $s0 -> $s1, GetConfig $g0 -> $g1"
    echo "  ${NOTE[M1]}"
    if ask "Did only the inner (top) ring of that fan group turn green, within about a second?" && [[ $s0 == "$s1" && $g0 == "$g1" ]]; then R[M1]=pass; else R[M1]=fail; fi
    NOTE[M1]+="; ${r%% *} ms"
    restore_check || R[M1]=fail
  else R[M1]=skipped; fi
fi

# ---- M2 ------------------------------------------------------------------------------
if wanted M2 && [[ -n $STRIMER ]]; then
  say "M2: $STRIMER Drizzling with 6 colours (red, orange, yellow, green, blue, violet), speed 2, Clockwise"
  if ask "Run M2?"; then
    six=$(rgb '["ff0000","ff8000","ffff00","00ff00","0040ff","a000ff"]')
    req "$STRIMER" 0 "$(jq -nc --argjson c "$six" '{mode: "Drizzling", colors: $c, speed: 2, brightness: 4, direction: "Clockwise", disabled: false}')" >"$work/m2.jsonl"
    touched=("$STRIMER"); r=$(send "$work/m2.jsonl") || r="0 0 1"
    echo "  sent in ${r%% *} ms (ok/failed: ${r#* })"
    if [[ ${r##* } == 0 ]] && ask "Do you see all six colours moving along that Strimer?"; then R[M2]=pass; else R[M2]=fail; fi
    NOTE[M2]="${r%% *} ms"
    restore_check || R[M2]=fail
  else R[M2]=skipped; fi
fi

# ---- M3 ------------------------------------------------------------------------------
if wanted M3 && [[ -n $PUMP$RING ]]; then
  say "M3: the pump ring and the 8.8\" screen ring turn green"
  if ask "Run M3?"; then
    : >"$work/m3.jsonl"; touched=()
    if [[ -n $PUMP ]]; then req "$PUMP" 0 "$static_green" >>"$work/m3.jsonl"; touched+=("$PUMP"); fi
    if [[ -n $RING ]]; then req "$RING" 0 "$static_green" >>"$work/m3.jsonl"; touched+=("$RING"); fi
    r=$(send "$work/m3.jsonl") || r="0 0 1"
    echo "  sent in ${r%% *} ms (ok/failed: ${r#* })"
    if [[ ${r##* } == 0 ]] && ask "Did both rings turn green (the pump ring fully)?"; then R[M3]=pass; else R[M3]=fail; fi
    NOTE[M3]="${r%% *} ms"
    restore_check || R[M3]=fail
  else R[M3]=skipped; fi
fi

# ---- M4 ------------------------------------------------------------------------------
if wanted M4; then
  say "M4: everything from M1-M3 at once, then the revert from the saved config"
  if ask "Run M4?"; then
    : >"$work/m4.jsonl"; touched=()
    if [[ -n $TL ]]; then req "$TL" 0 "$(jq -c '. + {scope: "Top"}' <<<"$static_green")" >>"$work/m4.jsonl"; touched+=("$TL"); fi
    if [[ -n $STRIMER ]]; then req "$STRIMER" 0 "$static_green" >>"$work/m4.jsonl"; touched+=("$STRIMER"); fi
    if [[ -n $PUMP ]]; then req "$PUMP" 0 "$static_green" >>"$work/m4.jsonl"; touched+=("$PUMP"); fi
    if [[ -n $RING ]]; then req "$RING" 0 "$static_green" >>"$work/m4.jsonl"; touched+=("$RING"); fi
    send "$work/m4.jsonl" >/dev/null || true
    sleep 3
    echo "  now the revert..."
    r=$(restore_ids "${touched[@]}") || r="0 0 1"; touched=()
    echo "  revert sent in ${r%% *} ms (ok/failed: ${r#* })"
    if [[ ${r##* } == 0 ]] && ask "Does every light look EXACTLY like before (colours, animation, both fan rings)?"; then R[M4]=pass; else R[M4]=fail; fi
    NOTE[M4]="revert ${r%% *} ms"
    restore_check || R[M4]=fail
  else R[M4]=skipped; fi
fi

# ---- M5 ------------------------------------------------------------------------------
if wanted M5 && [[ -n $TL ]]; then
  say "M5: the TL group's inner ring green, then a clip swap (clips next)"
  if ask "Run M5?"; then
    req "$TL" 0 "$(jq -c '. + {scope: "Top"}' <<<"$static_green")" >"$work/m5.jsonl"
    touched=("$TL"); send "$work/m5.jsonl" >/dev/null || true
    sleep 2
    unlock
    rc=0; "$engine" clips next || rc=$?
    lock
    sleep 3
    if ask "Did the green inner ring go back to the saved colour by itself after the clip swap?"; then
      R[M5]=pass NOTE[M5]="a config reload re-sends the saved RGB: the preview must pause the clips (it does)"
    else
      R[M5]=pass NOTE[M5]="a config reload keeps the preview; pausing the clips is still the safe choice"
    fi
    [[ $rc == 0 ]] || NOTE[M5]+="; clips next exited $rc (no rotating screen?)"
    restore_check || R[M5]=fail
  else R[M5]=skipped; fi
fi

# ---- M6 ------------------------------------------------------------------------------
if wanted M6 && [[ -n $TL ]]; then
  say "M6: SetRgbConfig (the fallback method; it saves to config.json): the TL group's colour, then the saved section back"
  if ask "Run M6?"; then
    jq '.rgb' "$CFG_LIVE" >"$work/saved-rgb.json"
    jq --arg d "$TL" --argjson e "$static_green" '.devices |= map(if .device_id == $d
        then .zones |= map(.effect = $e) | (if .regions then .regions |= map(.effect = ($e + {scope: .effect.scope})) else . end)
        else . end)' "$work/saved-rgb.json" >"$work/m6-rgb.json"
    M_F=$work/m6-rgb.json engine_eval '
      t=${EPOCHREALTIME/./}; pv_send_rgbconfig "$M_F" || { echo "failed: $LIVE_ERR" >&2; exit 1; }
      echo $(( (${EPOCHREALTIME/./} - t) / 1000 ))' >"$work/m6.ms" 2>"$work/m6.err" || true
    echo "  SetRgbConfig + reload: $(cat "$work/m6.ms" 2>/dev/null || echo '?') ms $(cat "$work/m6.err" 2>/dev/null)"
    ok6=; ask "Did that whole fan group turn green?" && ok6=1
    M_F=$work/saved-rgb.json engine_eval 'pv_send_rgbconfig "$M_F"' || echo "  the saved section could not be sent back" >&2
    sleep 1
    if jq -e --slurpfile s "$work/saved-rgb.json" '.rgb == $s[0]' "$CFG_LIVE" >/dev/null; then echo "  config.json holds the saved rgb section again"
    else echo "  WARNING: config.json's rgb section differs from the saved one" >&2; ok6=; fi
    if [[ -n $ok6 ]]; then R[M6]=pass; else R[M6]=fail; fi
    NOTE[M6]="$(cat "$work/m6.ms" 2>/dev/null || echo '?') ms"
    restore_check || R[M6]=fail
  else R[M6]=skipped; fi
fi

# ---- M7 ------------------------------------------------------------------------------
if wanted M7; then
  say "M7: one OpenRGB apply of $active with the cached RAM ids ($(cat "$CACHE/ram-ids" 2>/dev/null || echo none)), no device listing"
  if ask "Run M7?"; then
    r=$(engine_eval '
      eff=$(scheme_file); openrgb_preview_args "$eff" >"$TMP/a.args"
      t=${EPOCHREALTIME/./}; be_openrgb_preview "$eff" "$TMP/a.args" && ok=ok || ok=failed
      echo "$(( (${EPOCHREALTIME/./} - t) / 1000 )) $ok"') || r="? failed"
    echo "  openrgb: ${r% *} ms, ${r#* }"
    if [[ ${r#* } == ok ]] && ask "GPU, board and RAM look like the theme, with no RAM glitch or reset?"; then R[M7]=pass; else R[M7]=fail; fi
    NOTE[M7]="${r% *} ms"
  else R[M7]=skipped; fi
fi

# ---- M8 ------------------------------------------------------------------------------
if wanted M8 && [[ -n $TL ]]; then
  say "M8: the TL group's inner ring green, then systemctl --user restart lianli-daemon"
  if ask "Run M8 (the screens blank for a few seconds while the daemon restarts)?"; then
    req "$TL" 0 "$(jq -c '. + {scope: "Top"}' <<<"$static_green")" >"$work/m8.jsonl"
    send "$work/m8.jsonl" >/dev/null || true
    sleep 2
    systemctl --user restart lianli-daemon
    for _ in {1..30}; do systemctl --user is-active -q lianli-daemon && break; sleep 1; done
    echo "  waiting 20 s for the devices to come back..."; sleep 20
    if ask "Is the saved look back everywhere (the green is gone)?"; then R[M8]=pass; else R[M8]=fail; fi
    touched=()
    restore_check || R[M8]=fail
  else R[M8]=skipped; fi
fi

# ---- M9 ------------------------------------------------------------------------------
# The fan screens and the pump in the daemon config (hid:1cbe:<pid>:<path>;
# a068 is the HydroShift II OLED Curve, a088 the 8.8" Universal Screen).
m9_fans=$(jq -r '[.lcds[]? | select(.type == "video" and (.path | type == "string")
  and (.serial // "" | test("^hid:1cbe:") and (test("^hid:1cbe:a0(68|88):") | not)))] | .[].serial' "$CFG_LIVE" 2>/dev/null || true)
m9_pump=$(jq -r '[.lcds[]? | select(.serial // "" | test("^hid:1cbe:a068:"))][0].serial // empty' "$CFG_LIVE" 2>/dev/null || true)
if wanted M9 && [[ $(wc -w <<<"$m9_fans") -ge 2 ]]; then
  m9_a=$(awk 'NR == 1' <<<"$m9_fans") m9_b=$(awk 'NR == 2' <<<"$m9_fans")
  say "M9: fan screen $m9_a gets the clip of $m9_b (SetLcdMedia), then ${m9_pump:+the pump dims (SetLcdBrightness), then }the saved screens back"
  if ask "Run M9 (one fan screen changes clip; the pump dims)?"; then
    s0=$(cfg_stamp)
    jq -c --arg a "$m9_a" '[.lcds[] | select(.serial == $a)][0]' "$CFG_LIVE" >"$work/m9-saved-a.json"
    jq -nc --slurpfile s "$work/m9-saved-a.json" '{method: "SetLcdMedia", params: {device_id: ("serial:" + $s[0].serial), config: $s[0]}}' >"$work/m9-revert.jsonl"
    b_path=$(jq -r --arg b "$m9_b" '[.lcds[] | select(.serial == $b)][0].path' "$CFG_LIVE")
    gen0=$(engine_eval 'pv_telemetry' | jq -r --arg d "serial:$m9_a" '.[$d].generation // -1')
    jq -nc --slurpfile s "$work/m9-saved-a.json" --arg p "$b_path" '{method: "SetLcdMedia", params: {device_id: ("serial:" + $s[0].serial), config: ($s[0] | .path = $p)}}' >"$work/m9.jsonl"
    t0=${EPOCHREALTIME/./}
    r=$(send "$work/m9.jsonl") || r="0 0 1"
    st=
    for _ in {1..90}; do
      st=$(engine_eval 'pv_telemetry' | jq -r --arg d "serial:$m9_a" --argjson g "$gen0" '.[$d] | select(.generation > $g) | .state // empty')
      [[ $st == ready || $st == failed || $st == waiting_for_device ]] && break
      sleep 0.5
    done
    ms=$(( (${EPOCHREALTIME/./} - t0) / 1000 ))
    echo "  SetLcdMedia sent in ${r%% *} ms; telemetry: ${st:-no change} after $ms ms"
    NOTE[M9]="swap ${st:-no telemetry} in $ms ms"
    ok9=
    if [[ ${r##* } == 0 && $st == ready ]] && ask "Did only that fan screen change (the others kept streaming, no LED blinked)?"; then ok9=1; fi
    if [[ -n $m9_pump ]]; then
      s1=$(cfg_stamp)
      jq -nc --arg d "$m9_pump" '{method: "SetLcdBrightness", params: {device_id: $d, brightness: 30}}' >"$work/m9-b.jsonl"
      r=$(send "$work/m9-b.jsonl") || r="0 0 1"
      sleep 1
      s2=$(cfg_stamp)
      echo "  SetLcdBrightness sent in ${r%% *} ms; config.json $([[ $s1 == "$s2" ]] && echo unchanged || echo "CHANGED ($s1 -> $s2)")"
      NOTE[M9]+="; brightness ${r%% *} ms, $([[ $s1 == "$s2" ]] && echo "not persisted" || echo PERSISTED)"
      if ! { [[ ${r##* } == 0 && $s1 == "$s2" ]] && ask "Did the pump screen dim at once?"; }; then ok9=; fi
      jq -nc --arg d "$m9_pump" --argjson b "$(jq --arg d "$m9_pump" '[.lcds[] | select(.serial == $d)][0].brightness // 100' "$CFG_LIVE")" \
        '{method: "SetLcdBrightness", params: {device_id: $d, brightness: $b}}' >>"$work/m9-revert.jsonl"
    fi
    echo "  now the saved screens back..."
    r=$(send "$work/m9-revert.jsonl") || r="0 0 1"
    : >"$work/m9-revert.jsonl"
    sleep 3
    s3=$(cfg_stamp)
    echo "  revert sent in ${r%% *} ms; config.json ${s0} -> ${s3}"
    if jq -e --slurpfile s "$work/m9-saved-a.json" --arg a "$m9_a" '([.lcds[] | select(.serial == $a)][0] | del(.orientation)) == ($s[0] | del(.orientation))' "$CFG_LIVE" >/dev/null; then
      echo "  config.json holds the saved entry of $m9_a again"
    else echo "  WARNING: config.json's entry of $m9_a differs from the saved one" >&2; ok9=; fi
    if [[ -n $ok9 ]] && ask "Are both screens back exactly as before?"; then R[M9]=pass; else R[M9]=fail; fi
    restore_check || R[M9]=fail
  else R[M9]=skipped; fi
fi

# ---- verdict --------------------------------------------------------------------------
say "Results"
for m in M1 M2 M3 M4 M5 M6 M7 M8 M9; do printf '  %s  %-8s %s\n' "$m" "${R[$m]:-not run}" "${NOTE[$m]:-}"; done
method=
if [[ ${R[M1]:-} == pass && ${R[M2]:-} == pass && ${R[M3]:-} == pass && ${R[M4]:-} == pass && ${R[M8]:-} == pass ]]; then method=effect
elif [[ ${R[M6]:-} == pass ]]; then method=rgbconfig; fi
{
  for m in M1 M2 M3 M4 M5 M6 M7 M8 M9; do printf '%s\t%s\t%s\n' "$m" "${R[$m]:-not-run}" "${NOTE[$m]:-}"; done
} | jq -Rn --arg method "$method" --argjson at "$EPOCHSECONDS" '
  {v: 1, at: $at, method: (if $method == "" then null else $method end),
   steps: [inputs | split("\t") | {(.[0]): {result: .[1], note: .[2]}}] | add}' >"$CACHE/preview-measure.json"
echo "  saved to $CACHE/preview-measure.json"
if [[ -z $method ]]; then
  echo "No method passed the gate (M1-M4 and M8 for effect, M6 for rgbconfig); live preview stays off."
  exit 0
fi
echo "Gate: method \"$method\"."
if ask "Write \"$method\" to $STATE/preview-method (turns live preview on)?"; then
  echo "$method" >"$STATE/preview-method.tmp" && mv "$STATE/preview-method.tmp" "$STATE/preview-method"
  echo "  done"
fi
