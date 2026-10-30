# lib/pc-lights/json.sh — machine-readable state for the shell plugin (contract v1) and the text status
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP6 (JSON v1.1, sensors, previews)
# Public: status status_json themes_json usb_screens screens_expected unit_states raw
#         profile_file eff_file eff_files draft_files media_job_raw, DESKTOP_V14_JQ (desktop.sh uses it)
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

status() {
  echo "scheme: $(active_name)"
  echo "saved state: lights=$(cat "$STATE_DIR/lights" 2>/dev/null || echo unknown)" \
    "screens=$(cat "$STATE_DIR/screens" 2>/dev/null || echo unknown)"
  echo "lian li zones: $(jq -c '[.rgb.devices[]?.zones[].effect.mode] | group_by(.) | map({(.[0]): length}) | add // {}' "$CFG")"
  echo "lian li screens: $(jq -c '[.lcds[] | .brightness // 100] ' "$CFG") (brightness per screen)"
  echo "heat alert: $(jq -c '.thermal_alert | map_values({enabled, threshold})' "$CFG")"
  echo "screens on USB: $(usb_screens) of $(screens_expected)"
  echo "lianli-daemon: $(systemctl --user is-active lianli-daemon)"
}

# ---- machine-readable state for the shell plugin (contract v1) -------------
# status --json and themes --json never take the lock, never open the daemon
# socket and never create $STATE_DIR: the plugin runs them on every file
# change it sees. Files come in raw and are parsed inside jq with try, so a
# missing, empty or half-written file (config.json during a fallback restart)
# reads as null and the command still exits 0.
raw() { cat "$1" 2>/dev/null || true; }

# The hardware profile (WP2 writes it; PROFILE is an override point, read at
# call time, so the goldens and the tests can point it elsewhere).
profile_file() { echo "${PROFILE:-$STATE_DIR/profile.json}"; }

# The LCDs this machine should have: profile.screens.expected, else as many
# as the daemon config lists, else 7 (this machine before profiles).
screens_expected() {
  jq -rn --rawfile p <(raw "$(profile_file)") --rawfile c <(raw "$CFG") '
    def pj: try fromjson catch null;
    (($p | pj | objects | .screens.expected | numbers) // ($c | pj | objects | .lcds | arrays | length)
     // 7) | floor'
}

# "<unit> <active state>" for every loaded pc-lights unit and the daemon, in
# one systemctl call (transient units that are gone read as inactive).
unit_states() {
  systemctl --user list-units --all --plain --no-legend --no-pager \
    'pc-lights*' lianli-daemon.service 2>/dev/null | awk '{print $1, $3}' || true
}

# LCDs on USB (vendor 1cbe: TL/SL fan LCDs a018, HydroShift II a068, 8.8" a088).
# The text status and status --json both count them here; an override point.
usb_screens() {
  local d v p n=0
  for d in /sys/bus/usb/devices/*; do
    [[ -r $d/idVendor && -r $d/idProduct ]] || continue
    read -r v <"$d/idVendor" || continue
    [[ $v == 1cbe ]] || continue
    read -r p <"$d/idProduct" || continue
    if [[ $p =~ ^(a018|a068|a088)$ ]]; then n=$((n + 1)); fi
  done
  echo "$n"
}

# ---- contract v1.1 (additive; "v" stays 1, the plugin rejects v > 1) ------
# profile_v11($cfg): on the raw profile.json text, with the parsed daemon
# config ($cfg, or null). Gives {want, profile, labels} for status --json:
#   want     profile.screens.expected, else config.lcds | length, else 7
#   profile  {state: ok|stale|missing|invalid, machine, detected_at, screens,
#             backends: {<b>: {state, enabled, devices}}, new_devices: [device_id],
#             missing_devices: [key], sensors: {<role>: driver|type|kind},
#             pump_device: device_id|null, groups: [fans strimers rings gpu board ram peripherals]}
#            (always every key; null/[]/{} when missing or invalid)
#   labels   {device_id: role label}, for the daemon device list
# "stale" = config.rgb.devices ids that no profile device matches (no socket).
# A device's daemon id is its seen_id, match.device_id or "wireless:<mac>";
# a HID id whose USB path moved still matches by vid:pid when that is unique.
# shellcheck disable=SC2016
PROFILE_V11_JQ='
  def devid: .seen_id // .match.device_id // (if .match.mac then "wireless:" + .match.mac else null end);
  def vidpid: if type == "string" and startswith("hid:") then split(":")[0:3] | join(":") else null end;
  def lighting_group:
    if startswith("fans.") or . == "fans" then "fans"
    elif startswith("strimer.") then "strimers"
    elif endswith(".ring") or . == "pump.logo" then "rings"
    elif . == "gpu" then "gpu" elif . == "board" or . == "board.argb" then "board" elif . == "ram" then "ram"
    elif IN("keyboard", "mouse", "mousepad", "headset") or startswith("ledstrip.") or startswith("other.") then "peripherals"
    else null end;
  def profile_v11($c):
    (try (fromjson | objects) catch null) as $p
    | (if . == "" then "missing" elif $p == null or ($p.v // 0) != 1 or ($p.devices | type) != "object" then "invalid"
       else "ok" end) as $st
    | (if $st == "ok" then $p else {} end) as $p
    | ($p.devices // {}) as $dev
    # Every device detect saw counts as known, duplicates included: a duplicate
    # (e.g. a wired receiver that drives the same fans as a wireless group) is
    # deliberately left alone, and "lights off" still writes it an Off entry.
    | [$dev | to_entries[] | .value | devid | strings] as $ids
    | ([$ids[] | vidpid | strings] | group_by(.) | map(select(length == 1) | .[0])) as $uniq
    | [$c.rgb.devices[]?.device_id | strings | select(. as $i | ($ids | index($i)) == null)
       | select((vidpid) as $v | $v == null or ($uniq | index($v)) == null)] as $new
    | [$dev | to_entries[] | select(.value.present == false and .value.kind != "duplicate") | .key] as $gone
    | ($p.roles // {}) as $roles
    | [[$p.sensors.pump.device, $p.sensors.coolant.device][] | strings | $dev[.] | objects | devid | strings]
      as $pumpids
    | {want: ((($p.screens.expected | numbers) // ($c.lcds | arrays | length) // 7) | floor),
       profile: {
         state: (if $st == "ok" and ($new | length) > 0 then "stale" else $st end),
         machine: ($p.machine.name // null), detected_at: ($p.machine.detected_at // null),
         screens: ($p.screens.expected // null),
         backends: (($p.backends // {}) | with_entries(.key as $b | .value |= (
           {state: (if .enabled == false then "disabled" else .state // "unknown" end), enabled: (.enabled != false),
            devices: ([$dev[] | select(.backend == $b and .present != false and .kind != "duplicate")] | length)}))),
         new_devices: $new, missing_devices: $gone,
         sensors: (($p.sensors // {}) | map_values(objects
           | if .kind == "hwmon" then .driver elif .kind == "thermal_zone" then .type else .kind end)),
         pump_device: ($pumpids[0] // first($dev[] | select(.has_pump == true and .present != false) | devid) // null),
         groups: ([$roles | to_entries[] | select(.value.managed != false) | .key | lighting_group | strings] as $g
                  | ["fans", "strimers", "rings", "gpu", "board", "ram", "peripherals"] | map(select(IN($g[]))))},
       labels: ([$roles | to_entries[] | select(.value.label | type == "string") | .value.label as $l
                 | (.value.device, (.value.devices // [])[]) | strings | $dev[.] | objects | devid | strings
                 | {(.): $l}] | add // {})}
    | if $st == "missing" or $st == "invalid" then .profile.backends = {} | .profile.new_devices = [] else . end;
'

# ---- contract v1.2 (additive; the theme editor, editor plan §1.7) ----------
# The drafts ($STATE_DIR/drafts/<name>.json, builder A's editor.sh writes
# them), each behind a "\x1e" line, for a jq --rawfile: status --json lists
# them, themes --json marks the themes that have one. Nothing when there are
# none (no extra process).
draft_files() {
  local f fs=()
  for f in "$STATE_DIR"/drafts/*.json; do [[ -f $f ]] && fs+=("$f"); done
  (( ${#fs[@]} )) || return 0
  awk 'FNR == 1 { print "\036" } { print }' "${fs[@]}" 2>/dev/null || true
}
# The drafts as {name, mode, from, rev, updated}, sorted by name; unreadable
# ones are left out.
# shellcheck disable=SC2016 # jq, not shell
DRAFTS_JQ='
  def drafts($raw): [$raw | split("\u001e")[] | select(length > 0) | try fromjson catch null | objects
    | select(.name | type == "string") | {name, mode: (.mode // null), from: (.from // null),
      rev: (.rev // null), updated: (.updated // null)}] | sort_by(.name);'

# ---- contract v1.3 (additive; the screen media pipeline, screens plan §7) ---
# The media job records ($CACHE/media/jobs/j-*.json, written by
# lib/pc-lights/media.sh), each behind a "\x1e" line for a jq --rawfile;
# nothing when there are none (no extra process). status --json turns them
# into "media": {running, jobs: [{id, draft, role, state, progress (0-1),
# error, then, applied, media_kind (video/image/gif of the source)}]}: the jobs that run and those that ended in the last
# hour, newest first, at most 20 (the main page's "Preparing ..." notice).
media_job_raw() {
  local f fs=()
  for f in "$CACHE"/media/jobs/j-*.json; do [[ -f $f ]] && fs+=("$f"); done
  (( ${#fs[@]} )) || return 0
  awk 'FNR == 1 { print "\036" } { print }' "${fs[@]}" 2>/dev/null || true
}
# shellcheck disable=SC2016 # jq, not shell
MEDIA_V13_JQ='
  def media_v13($raw; $now):
    def final: IN("done", "failed", "cancelled");
    [$raw | split("\u001e")[] | select(length > 0) | try fromjson catch null | objects | select(.id | type == "string")
     | select((.state | final | not) or ($now - (.ended // .updated // 0)) <= 3600)] as $j
    | {running: ([$j[] | select(.state | final | not)] | length),
       jobs: [$j | sort_by(-(.started // 0), .id) | .[:20][]
              | {id, draft: (.draft // null), role: (.role // null), state, progress: (.progress.frac // null),
                 error: (.error // null), then: (.then // null), applied: (.applied // null),
                 media_kind: (.source.kind // null)}]};'

# ---- contract v1.4 (additive; the desktop wallpaper per theme, desktop.sh) --
# The user's desktop wallpaper settings live in $STATE_DIR/desktop.json
# (desktop.sh writes it): {"v": 1, "defaults": {animated, pause_while_active,
# resume_after_idle, while_active}, "themes": {"<theme>": {partial}}}.
# desk_view($raw; $theme) resolves one theme's settings: the built-in
# defaults, then the file's defaults, then the theme's own, keeping only the
# known keys with valid values (so a bad hand edit falls back instead of
# failing). desktop.sh resolves settings through it too. status --json adds
# "desktop": {available, theme, settings, playing, portrait, at} from
# desktop.json and the last sync's $CACHE/desktop/state.json: no IPC and no
# extra process. portrait (additive): the wallpaper on screen has a portrait
# version (<still>.portrait.<ext>) for portrait monitors; false before a sync.
# shellcheck disable=SC2016 # jq, not shell
DESKTOP_V14_JQ='
  def desk_builtin: {animated: true, pause_while_active: true, resume_after_idle: 5, while_active: "freeze"};
  def desk_clean: if type == "object" then with_entries(select(
      ((.key == "animated" or .key == "pause_while_active") and (.value | type == "boolean"))
      or (.key == "resume_after_idle" and (.value | type == "number") and .value == (.value | floor)
          and .value >= 1 and .value <= 600)
      or (.key == "while_active" and (.value | IN("freeze", "still"))))) else {} end;
  def desk_view($raw; $theme):
    (((try ($raw | fromjson) catch null) | objects) // {}) as $d
    | (desk_builtin + ($d.defaults | desk_clean)) as $def
    | ((($d.themes | objects) // {})[$theme] | desk_clean) as $st
    | {settings: ($def + $st), stored: $st, defaults: $def};
  def desktop_v14($raw; $cache; $theme):
    def bool: if type == "boolean" then . else null end;
    (((try ($cache | fromjson) catch null) | objects) // {}) as $c
    | {available: ($c.available | bool), theme: $theme, settings: desk_view($raw; $theme).settings,
       playing: ($c.playing | bool), portrait: ($c.portrait == true), at: (($c.at | numbers) // null)};'

status_json() {
  local now=$EPOCHSECONDS busy s= e= t=() i best=0 kind=day lb= nb=0 nbs= theme names=() f rot desk='' deskc=''
  busy=$(raw "$CACHE/busy.json")
  if ! [[ $busy =~ \"pid\":([0-9]+) ]] || ! kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then busy=; fi
  # The last and next day/night boundary, as last_boundary/next_boundary
  # work them out, with one date call for the six candidate times.
  if [[ -f $SCHED ]]; then
    IFS=$'\t' read -r s e < <(jq -r '[.night_start // "00:00", .night_end // "07:00"] | @tsv' "$SCHED" 2>/dev/null) || true
  fi
  if [[ -n $s && -n $e && $s != "$e" ]]; then
    mapfile -t t < <(printf '%s\n' "today $s" "today $e" "yesterday $s" "yesterday $e" "tomorrow $s" "tomorrow $e" |
      date -f - +%s 2>/dev/null || true)
    if (( ${#t[@]} == 6 )); then
      for i in 0 1 2 3; do
        if (( t[i] <= now && t[i] > best )); then
          best=${t[i]}
          if (( i % 2 == 0 )); then kind=night; else kind=day; fi
        fi
      done
      for i in 0 1 4 5; do
        if (( t[i] > now && (nb == 0 || t[i] < nb) )); then nb=${t[i]}; fi
      done
      printf -v lb '%(%FT%H:%M)T' "$best"
      printf -v nbs '%(%FT%H:%M)T' "$nb"
    fi
  fi
  theme=$(active_name)
  for f in "$THEME_DIR"/*/theme.json; do
    if [[ -f $f ]]; then f=${f%/theme.json}; names+=("${f##*/}"); fi
  done
  rot=$(rotating_screens 2>/dev/null || true)
  local pend=()
  for f in "$PENDING"/*.json; do [[ -f $f ]] && pend+=("$f"); done
  # The desktop wallpaper settings and the last sync (v1.4), read with the
  # builtin: two more forks would cost status --json a millisecond.
  { IFS= read -r -d '' desk <"$STATE_DIR/desktop.json"; } 2>/dev/null || true
  { IFS= read -r -d '' deskc <"$CACHE/desktop/state.json"; } 2>/dev/null || true
  jq -n --argjson now "$now" --arg theme "$theme" --arg day "$(day_scheme)" \
    --arg lights "$(lights_state)" --arg screens "$(screens_state)" --arg clips "$(clips_state)" \
    --arg busy "$busy" --arg lb "$lb" --arg kind "$kind" --arg nb "$nbs" --arg rot "$rot" \
    --argjson usb "$(usb_screens)" --arg units "$(unit_states)" \
    --rawfile cfg <(raw "$CFG_LIVE") --rawfile sched <(raw "$SCHED") \
    --rawfile boundary <(raw "$BOUNDARY") --rawfile clipsj <(raw "$CLIPS_STATE") \
    --rawfile lastrun <(raw "$CACHE/last-run.json") --rawfile uireq <(raw "$CACHE/ui-requested") \
    --rawfile map <(raw "$STATE_DIR/omarchy-map.json") --rawfile requested <(raw "$CACHE/omarchy-requested") \
    --rawfile current <(raw "$HOME/.local/state/omarchy/current/theme.name") \
    --rawfile prof <(raw "$(profile_file)") \
    --rawfile pend <(if (( ${#pend[@]} )); then awk 1 "${pend[@]}" 2>/dev/null || true; fi) \
    --rawfile preview <(raw "$CACHE/preview.json") --rawfile drafts <(draft_files) \
    --rawfile mjobs <(media_job_raw) --arg desk "$desk" --arg deskc "$deskc" \
    "$nul_jq$PROFILE_V11_JQ$DRAFTS_JQ$MEDIA_V13_JQ$DESKTOP_V14_JQ"'
    def pj: try fromjson catch null;
    def line: rtrimstr("\n") | split("\n")[0] // "";
    def on($s): $s == "active" or $s == "activating";
    ($units | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add // {}) as $u
    | (($cfg | pj | objects) // null) as $c
    | (($clipsj | pj | objects) // null) as $cj
    | (($sched | pj | objects) // null) as $sc
    | (($map | pj | objects) // null) as $m
    | $ARGS.positional as $names
    | ($prof | profile_v11($c)) as $pv
    | ($current | line | n) as $slug
    | (if $slug == null then {maps_to: null, mapping: "none"}
       else (($m // {}) | .[$slug] // ._default // "auto") as $to
         | if $to != "auto" and ($to | IN($names[])) then {maps_to: $to, mapping: "explicit"}
           else {maps_to: ("omarchy-" + $slug), mapping: "default-auto"} end
       end) as $om
    | ($sc != null and $sc.enabled == true) as $en
    | ($en and $kind == "night" and $lb != "") as $night
    | ($clips != "on") as $paused
    | (if $cj != null and $cj.theme == $theme then $cj else null end) as $cs
    | {v: 1, v_minor: 4, ts: $now, theme: $theme, day_theme: $day,
       screens_show: ([$c.lcds[]?.path | strings | capture("/themes/(?<t>[^/]+)/").t]
                      | group_by(.) | max_by(length) | .[0]?),
       lights: $lights, screens: $screens,
       clips: {state: $clips, paused_at: ($cj.paused_at // null)},
       busy: (($busy | pj | objects | {op, target, theme, unit, step, since}) // null),
       pending: [$pend | split("\n")[] | pj | objects
                 | select(.unit as $x | on($u[$x + ".service"]) or on($u[$x + ".timer"]))
                 | {op, target, theme, unit, source, slug, queued, due}] | sort_by(.queued),
       ui_requested: ($uireq | line | split(" ")[0] // "" | n),
       ui_requested_ns: ($uireq | line | split(" ")[1] // "" | n),
       last_run: (($lastrun | pj | objects) // null),
       daemon_unit: ($u["lianli-daemon.service"] // "inactive"
                     | if . == "deactivating" then "inactive" elif . == "reloading" then "active" else . end),
       screens_on_usb: {have: $usb, want: $pv.want},
       alert: (($c.thermal_alert | objects | map_values(objects | {enabled, threshold})) // null),
       schedule: (if $sc == null then null else
         {enabled: $en, night_theme: ($sc.night_theme // null), night_start: ($sc.night_start // null),
          night_end: ($sc.night_end // null), period: (if $night then "night" else "day" end),
          last_boundary: ($lb | n), handled: ($lb != "" and ($boundary | line) == "\($lb) \($kind)"),
          next_boundary: ($nb | n),
          override: ($en and (if $night then $theme != $sc.night_theme else $theme != $day end)),
          timer: ($u["pc-lights-schedule.timer"] // "inactive")} end),
       omarchy: {current: $slug, requested: ($requested | line | n), maps_to: $om.maps_to,
                 mapping: $om.mapping, paired: ($om.maps_to != null and $om.maps_to == $day),
                 generating: ($u | to_entries | any((.key | test("^pc-lights-omarchy-.*\\.service$")) and on(.value)))},
       rotation: [$rot | split("\n")[] | pj | objects
         | ($cs.screens[.serial]? // {}) as $st
         | ($st.since // $cs.since // null) as $since
         | {serial, where, count: (.clips | length), rotate, shuffle, index: ($st.index // 0),
            clip: (($st.clip // .clips[0] // "") | split("/") | last),
            since: $since,
            next_in: (if $since == null then null
                      elif $paused and $cs.paused_at != null then ([.rotate - ($cs.paused_at - $since), 0] | max)
                      else ([.rotate - ($now - $since), 0] | max) end),
            paused: $paused}],
       previews_building: ($u | to_entries | any((.key == "pc-lights-previews.service"
                            or (.key | startswith("pc-lights-ui-previews-"))) and on(.value))),
       profile: $pv.profile, labels: $pv.labels,
       preview: (($preview | pj | objects) // null), drafts: drafts($drafts), media: media_v13($mjobs; $now),
       desktop: desktop_v14($desk; $deskc; $om.maps_to // $theme)}
    ' --args "${names[@]}"
}

# ---- the compiled EFF (plan §1, §5, risk 13) -------------------------------
# A v3 theme compiles against the profile into an EFF (theme.sh theme_eff,
# WP3): a v2-shaped superset (legacy keys, screens[] with serials, _roles,
# _coverage, _compiled) cached as $CACHE/compiled/<name>.<sha12>.json. For
# any other theme the EFF is theme.json itself (the same path).
# theme_eff checks one theme with half a dozen forks; themes --json needs all
# of them in well under 40 ms, so eff_files checks the whole cache at once and
# only calls theme_eff for a theme whose cached EFF is missing or stale.

# eff_files <name...>: "<name>\t<EFF path>" per theme, in order. Only themes
# that say "v": 3 are looked at (a grep picks them). A cached EFF is used when
# it is newer than theme.jq, models.json and calibration-presets.json and its
# _compiled.theme_sha256/profile_sha256 match the files now (one sha256sum
# and one jq for all themes). Otherwise theme_eff compiles it; when that
# fails (no profile, a broken theme) the theme.json path comes back and the
# caller decides (themes --json compiles it inline without a profile).
eff_files() {
  local n sf pf h f e dir=$CACHE/compiled fresh
  local -A sha=() got=()
  local cand=() effs=()
  pf=$(profile_file)
  for n in "$@"; do
    sf=$THEME_DIR/$n/theme.json
    [[ -f $sf ]] && cand+=("$sf")
  done
  if (( ${#cand[@]} )); then
    mapfile -t cand < <(grep -lE '"v"[[:space:]]*:[[:space:]]*3([^0-9.]|$)' -- "${cand[@]}" 2>/dev/null || true)
  fi
  if (( ${#cand[@]} )) && [[ -f $pf ]]; then
    while read -r h f; do sha[$f]=$h; done < <(sha256sum -- "${cand[@]}" "$pf" 2>/dev/null || true)
    for f in "${cand[@]}"; do
      n=${f%/theme.json}; n=${n##*/}
      for e in "$dir/$n".????????????.json; do
        [[ -f $e ]] || continue
        fresh=1
        for h in "$PCL_LIB/theme.jq" "${PCL_MODELS:-$PCL_LIB/models.json}" "${PCL_CAL_PRESETS:-$PCL_LIB/calibration-presets.json}"; do
          if [[ -f $h && ! $e -nt $h ]]; then fresh=; fi
        done
        [[ -n $fresh ]] && effs+=("$e")
      done
    done
    if (( ${#effs[@]} )); then
      while IFS=$'\t' read -r e h f; do
        n=${e##*/}; n=${n%.????????????.json}
        if [[ $h == "${sha[$THEME_DIR/$n/theme.json]:-}" && $f == "${sha[$pf]:-}" ]]; then got[$n]=$e; fi
      done < <(jq -r '[input_filename, ._compiled.theme_sha256 // "", ._compiled.profile_sha256 // ""] | @tsv' \
                 "${effs[@]}" 2>/dev/null || true)
    fi
  fi
  for n in "$@"; do
    sf=$THEME_DIR/$n/theme.json
    if [[ -n ${got[$n]:-} ]]; then
      printf '%s\t%s\n' "$n" "${got[$n]}"
    elif [[ -n ${sha[$sf]:-} ]] && e=$( (theme_eff "$n") 2>/dev/null ) && [[ -f $e ]]; then
      printf '%s\t%s\n' "$n" "$e"
    else
      printf '%s\t%s\n' "$n" "$sf"
    fi
  done
}

# eff_file <name>: the EFF path of one theme.
eff_file() { eff_files "$1" | cut -f2; }

# One entry per theme: its colours (normalised to lower-case #rrggbb lists)
# for the plugin to draw swatches from, where it pairs with Omarchy, and its
# preview image with a staleness flag (no stamp, or theme.json, media/, us88/
# or src/preview-us88.jpg newer than the image). Hand-made themes first, then
# the auto-generated ones, each alphabetically.
# v1.1 adds "schema" (2 or 3), "palette" (v3, else null) and "coverage": how
# much of this machine's profile the theme drives (null without a valid
# profile). Colours come from the compiled EFF, so a v3 theme's colours are
# its resolved ones.
# coverage is theme.jq's (coverage_of the EFF for v3, coverage() for v2):
#   {summary: full|partial|leds-only|foreign,
#    roles: {<role>: theme|group|palette|model|none|unmanaged},
#    counts: {theme (incl. group and model), palette, none, total (managed roles)},
#    missing: [<role> with no value]}
# "foreign": a v2 theme whose screen serials match none of the profile's.
# v1.2 (the theme editor) adds "draft" ({rev, updated} of its unsaved draft,
# or null), "editable" (a v3 theme and a valid profile) and "edit_block"
# (null, "no-profile" or "v2"; no profile wins: detect comes before migrate).
# status --json v1.3 (the screen media pipeline): "v_minor": 3 and "media"
# (media_job_raw above).
# status --json v1.4 (the desktop wallpaper): "v_minor": 4 and "desktop"
# (DESKTOP_V14_JQ above).
# status --json v1.2: "v_minor": 2, "preview" (the session file
# $CACHE/preview.json, lib/pc-lights/preview.sh, or null) and "drafts".
# A v3 theme without a profile is compiled inline (legacy keys only) for its
# colours; its coverage is null like every theme's without a valid profile.
themes_json() {
  local f n files=() names=() effl= inc='include "theme";'
  # theme.jq (WP3) brings compile/coverage/coverage_of; without it (an
  # engine older than v3) v3 themes read as written and coverage is null.
  # shellcheck disable=SC2016 # jq, not shell
  if [[ ! -f $PCL_LIB/theme.jq ]]; then
    inc='def compile($t; $p; $m): $t; def coverage($t; $p; $m): null; def coverage_of($e): null;'
  fi
  for f in "$THEME_DIR"/*/theme.json "$THEME_DIR"/*/src/source.json; do [[ -f $f ]] && files+=("$f"); done
  for f in "$THEME_DIR"/*/theme.json; do
    if [[ -f $f ]]; then f=${f%/theme.json}; names+=("${f##*/}"); fi
  done
  # The compiled EFFs of v3 themes join the inputs (cached; see eff_files).
  if (( ${#names[@]} )); then
    while IFS=$'\t' read -r n f; do
      if [[ $f != "$THEME_DIR/$n/theme.json" ]]; then files+=("$f"); effl+="$n"$'\t'"$f"$'\n'; fi
    done < <(eff_files "${names[@]}")
  fi
  (( ${#files[@]} )) || files=(/dev/null)
  # Every file goes in behind a "\x1e<path>" line, through awk, which ends
  # each file's last line itself: jq -R would join a file that has no final
  # newline (auto-theme's source.json) with the first line of the next one.
  awk 'FNR == 1 { print "\036" FILENAME } { print }' "${files[@]}" |
  jq -Rn -L "$PCL_LIB" --arg active "$(active_name)" --arg day "$(day_scheme)" --arg prev "$PREVIEWS" \
    --arg effl "$effl" --rawfile prof <(raw "$(profile_file)") \
    --rawfile models <(raw "${PCL_MODELS:-$PCL_LIB/models.json}") \
    --rawfile map <(raw "$STATE_DIR/omarchy-map.json") --rawfile sched <(raw "$SCHED") \
    --rawfile alerts <(raw "$STATE_DIR/alerts.json") --rawfile drafts <(draft_files) \
    --rawfile mt <(find "$THEME_DIR" -mindepth 2 \( -name theme.json -o -name theme.known-good.json \
        -o -path '*/src/preview-us88.jpg' -o -path "$THEME_DIR/*/media/*" -o -path "$THEME_DIR/*/us88/*" \) \
        -type f -printf '%P\t%T@\n' 2>/dev/null || true) \
    --rawfile pv <(find "$PREVIEWS" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.json' \) \
        -printf '%f\t%T@\n' 2>/dev/null || true) "$inc$DRAFTS_JQ"'
    def pj: try fromjson catch null;
    def hx: if type == "string" and test("^#?[0-9a-fA-F]{6}$") then "#" + (ltrimstr("#") | ascii_downcase) else empty end;
    def stops: (if type == "string" then [.] elif type == "array" then .
                elif type == "object" then (.gradient // .leds // .colors // []) else [] end) | map(hx);
    def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def times: split("\n") | map(select(length > 0) | split("\t") | {p: .[0], t: (.[1] | tonumber)});
    (reduce inputs as $l ({f: {}, c: null};
       if $l | startswith("\u001e") then .c = ($l | ltrimstr("\u001e")) | .f[.c] = ""
       else .f[.c] += $l + "\n" end) | .f) as $files
    | ($effl | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}) as $effs
    | ($map | pj | objects // {}) as $m
    | ($sched | pj | objects // {}) as $sc
    | ($alerts | pj | objects // {}) as $al
    | ($mt | times) as $mtimes
    | ($pv | times | map({(.p): .t}) | add // {}) as $pvt
    | (($prof | pj | objects | select(.v == 1 and (.devices | type) == "object")) // null) as $p
    | (($models | pj | objects) // {}) as $M
    | (drafts($drafts) | map({(.name): {rev, updated}}) | add // {}) as $dr
    | [ $files | keys[] | select(endswith("/theme.json"))
        | . as $path | (split("/") | .[-2]) as $name
        | ($files[$path] | pj | objects // {}) as $raw
        | (if $effs[$name] then ($files[$effs[$name]] | pj | objects) // $raw
           elif $raw.v == 3 then (try compile($raw; $p; $M) catch $raw)
           else $raw end) as $t
        | ($files[$path | rtrimstr("theme.json") + "src/source.json"] | pj) as $src
        | ((($src | objects | .generator) // "") | tostring | startswith("auto-theme")) as $auto
        | [$mtimes[] | select(.p | startswith($name + "/"))] as $own
        | ([$own[] | select(.p != "\($name)/theme.known-good.json") | .t] | max) as $newest
        | $pvt["\($name).webp"] as $wt
        | {fans_top: ($t.fans.top | stops), fans_bottom: ($t.fans.bottom | stops), rings: ($t.rings | stops),
           strimers: {mode: ($t.strimers.mode // null), colors: ($t.strimers.colors | stops)},
           gpu: ($t.gpu | stops), board: ($t.board | stops), ram: ($t.ram | stops),
           alert: ((try ($t.alert.color // $t.alert.cpu.color) catch null) // $al.color // "ff0000" | hx)} as $colors
        | {name: $name, about: ($raw._about // null), active: ($name == $active), day: ($name == $day),
           night: ($name == $sc.night_theme), auto: $auto,
           known_good: any($own[]; .p == "\($name)/theme.known-good.json"),
           omarchy_slugs: ([$m | to_entries[] | select((.key | startswith("_") | not) and .value == $name) | .key]
                           + (if $auto and ($name | startswith("omarchy-")) then [$name | ltrimstr("omarchy-")] else [] end)
                           | uniq),
           colors: $colors,
           swatch: ($colors.fans_top + $colors.fans_bottom + $colors.rings + $colors.strimers.colors + $colors.gpu
                    | uniq | .[:6]),
           preview: (if $wt != null then "\($prev)/\($name).webp" else null end),
           preview_mtime: (if $wt != null then ($wt | floor) else null end),
           preview_stale: ($wt == null or $pvt["\($name).json"] == null or ($newest != null and $newest > $wt)),
           schema: (if $raw.v == 3 then 3 else 2 end),
           palette: (if $raw.v == 3 then ($raw.palette | objects) // null else null end),
           coverage: (if $p == null then null
                      elif $raw.v == 3 then (try coverage_of($t) catch null)
                      else (try coverage($raw; $p; $M) catch null) end),
           draft: ($dr[$name] // null),
           editable: ($p != null and $raw.v == 3),
           edit_block: (if $p == null then "no-profile" elif $raw.v != 3 then "v2" else null end)} ]
    | sort_by(.auto, .name)'
}
