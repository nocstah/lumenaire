# lib/pc-lights/theme.sh — theme selection and validation (and, from WP3, compile/EFF and explain)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP3 (theme v3)
# Public: active_name theme_name theme_exists theme_dir scheme_file theme_schema theme_eff
#         theme_jq validate_theme explain_cmd; constant STRIMER_MODES; state THEME
# The v3 logic itself (compile, coverage, calibration, explain rows, v3
# checks) is lib/pc-lights/theme.jq, loaded with theme_jq.
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# A theme is a self-contained folder $THEME_DIR/<name>/ (theme.json, media/,
# us88/ template + assets); paths inside it are relative to that folder.
# The active name lives in $STATE_DIR/scheme; THEME overrides it (render).
THEME=
active_name() { cat "$STATE_DIR/scheme" 2>/dev/null || echo cyberpunk; }
theme_name() { if [[ -n $THEME ]]; then echo "$THEME"; else active_name; fi; }
theme_exists() { [[ $1 =~ ^[A-Za-z0-9._-]+$ && -f $THEME_DIR/$1/theme.json ]]; }
theme_dir() {
  local name; name=$(theme_name)
  theme_exists "$name" || die "theme '$name' not found in $THEME_DIR"
  echo "$THEME_DIR/$name"
}
# The file every builder reads (the EFF, plan §1): a v2 theme.json itself (the
# same path, so the legacy path stays byte for byte), or a v3 theme compiled
# against the hardware profile.
scheme_file() { local d; d=$(theme_dir) || exit 1; theme_eff "$(theme_name)"; }

# ---- theme v3: compile to the EFF (plan §5) ----------------------------------
# Inputs are read at call time, so a test can point them elsewhere: PROFILE
# (profile.sh; frozen.sh sets it), PCL_MODELS (WP2's model table) and
# PCL_CAL_PRESETS. A missing model table or preset file reads as {} (theme.jq
# then uses its built-in plan §4 table).
theme_profile() { echo "${PROFILE:-$STATE_DIR/profile.json}"; }
theme_models() { echo "${PCL_MODELS:-$PCL_LIB/models.json}"; }
theme_presets() { echo "${PCL_CAL_PRESETS:-$PCL_LIB/calibration-presets.json}"; }
# theme_jq <jq args...> <filter>: jq -n with theme.jq loaded and $P, $M, $C bound
# (profile, models, presets; null/{} when missing). The filter comes last.
theme_jq() {
  local f=${*: -1} pf mf cf
  pf=$(theme_profile) mf=$(theme_models) cf=$(theme_presets)
  jq -n -L "$PCL_LIB" "${@:1:$#-1}" \
    --slurpfile pcl_p <([[ -f $pf ]] && cat "$pf" || echo null) \
    --slurpfile pcl_m <([[ -f $mf ]] && cat "$mf" || echo '{}') \
    --slurpfile pcl_c <([[ -f $cf ]] && cat "$cf" || echo '{}') \
    'include "theme"; $pcl_p[0] as $P | $pcl_m[0] as $M | $pcl_c[0] as $C | '"$f"
}
# theme_schema <theme.json>: 3 for a v3 theme, otherwise 2.
theme_schema() { if jq -e '.v == 3' "$1" >/dev/null 2>&1; then echo 3; else echo 2; fi; }
# shellcheck disable=SC2016 # jq filters: $x is jq's, not the shell's
# theme_eff <name>: the EFF path. v3 themes compile into
# $CACHE/compiled/<name>.<sha12>.json, keyed on the bytes of the theme, the
# profile, the model table, the presets and theme.jq; a hit costs one sha256sum.
theme_eff() {
  local name=$1 sf pf key out tsha psha
  sf=$THEME_DIR/$name/theme.json
  [[ -f $sf ]] || die "theme '$name' not found in $THEME_DIR"
  if [[ $(theme_schema "$sf") != 3 ]]; then echo "$sf"; return 0; fi
  pf=$(theme_profile)
  [[ -f $pf ]] || die "theme $name is a v3 theme and there is no hardware profile; run: pc-lights detect"
  jq -e 'type == "object" and (.roles | type == "object")' "$pf" >/dev/null 2>&1 ||
    die "$pf is not a valid hardware profile; run: pc-lights detect"
  jq -e 'type == "object"' "$sf" >/dev/null 2>&1 || die "$sf is not valid JSON"
  { read -r tsha _; read -r psha _; } < <(sha256sum "$sf" "$pf")
  local parts=("$sf" "$pf" "$PCL_LIB/theme.jq") f
  for f in "$(theme_models)" "$(theme_presets)"; do [[ -f $f ]] && parts+=("$f"); done
  key=$(cat "${parts[@]}" | sha256sum)
  out=$CACHE/compiled/$name.${key:0:12}.json
  if [[ ! -s $out ]]; then
    mkdir -p "$CACHE/compiled"
    theme_jq --slurpfile t "$sf" --arg ts "$tsha" --arg ps "$psha" \
      'compile($t[0]; $P; $M; $C) | ._compiled += {theme_sha256: $ts, profile_sha256: $ps}' \
      >"$out.$$.tmp" && [[ -s $out.$$.tmp ]] || { rm -f "$out.$$.tmp"; die "could not compile theme $name"; }
    mv -f "$out.$$.tmp" "$out"
    # One compiled copy per theme: drop the ones for older bytes.
    find "$CACHE/compiled" -maxdepth 1 -name "$name.*.json" ! -name "${out##*/}" -delete 2>/dev/null || true
  fi
  echo "$out"
}
# Everything a theme feeds the daemon and OpenRGB, checked before anything is
# stopped. Prints every problem, then dies if there were any.
STRIMER_MODES='Off Direct Static Rainbow RainbowMorph Breathing Runway Meteor ColorCycle Staggered Tide Mixing Voice Door Render Ripple Reflect TailChasing Paint PingPong Stack StackMulti Neon CoverCycle Wave Racing Lottery Intertwine MeteorShower Collide ElectricCurrent Kaleidoscope BigBang Vortex Pump ColorsMorph TaiChi CrossingOver ColorfulStarryNight StaticStarryNight Bounce TickerTape Fluctuation Transmit Burst MopUp PacMan MeteorRainbow Spring Scan Contest Warning SpanningTeacups Tornado DoubleMeteor MeteorContest MeteorMix ReturnArc DoubleArc HeartBeat HeartBeatRunway Disco SeaFlow Echo ColorfulCity Twinkle Groove Tunnel BreathingRainbow StaticColorful BreathingColorful Snooker BlowUp ShockWave BulletStack Drizzling FadeOut ColorTransfer CrossOver Parallel Endless River Duel Hourglass Pioneer ShuttleRun GradientRibbon RainbowWave ColorfulMeteor Wing Drumming Boomerang CandyBox Transformation'
# shellcheck disable=SC2016 # jq filters: $x is jq's, not the shell's
validate_theme() {
  local name=$1 dir sf af=$STATE_DIR/alerts.json errs p
  theme_exists "$name" || die "theme '$name' not found in $THEME_DIR"
  dir=$THEME_DIR/$name sf=$dir/theme.json
  jq -e 'type == "object"' "$sf" >/dev/null 2>&1 || die "$sf is not valid JSON"
  # A v3 theme: its own schema first, then the compiled EFF goes through the
  # same checks as a v2 file (media paths still come from theme.json).
  local tf=$sf
  if [[ $(theme_schema "$sf") == 3 ]]; then
    errs=$(theme_jq -r --arg modes "$STRIMER_MODES" --slurpfile t "$sf" '$t[0] | v3_problems($modes)') || die "could not check $sf"
    if [[ -n $errs ]]; then
      while IFS= read -r p; do log "theme $name: $p"; done <<<"$errs"
      die "theme $name is invalid; nothing changed"
    fi
    sf=$(theme_eff "$name") || exit 1
  fi
  if [[ -f $af ]] && ! jq -e 'type == "object"' "$af" >/dev/null 2>&1; then
    die "$af is not valid JSON"
  fi
  errs=$(jq -r --arg modes "$STRIMER_MODES" --slurpfile a <(cat "$af" 2>/dev/null || echo '{}') '
    def hex: type == "string" and test("^#?[0-9a-fA-F]{6}$");
    def ok(f): [try f catch false] | length > 0 and all;
    def chk(f; $msg): if ok(f) then empty else $msg end;
    def int($lo; $hi): type == "number" and . == floor and . >= $lo and . <= $hi;
    def alert($w):
      chk(.color == null or (.color | hex); "\($w).color must be 6 hex digits"),
      (("cpu", "gpu") as $k
        | chk(.[$k] == null or (.[$k] | type == "object"); "\($w).\($k) must be an object"),
          chk(.[$k].threshold == null or (.[$k].threshold | type == "number" and . >= 0 and . <= 255);
              "\($w).\($k).threshold must be a number 0-255 (C)"),
          chk(.[$k].color == null or (.[$k].color | hex); "\($w).\($k).color must be 6 hex digits"));
    ($modes | split(" ")) as $ml
    | def fan_colour: hex or (type == "array" and length >= 1 and length <= 4 and all(hex));
      [ chk(.fans.top | fan_colour; "fans.top must be 6 hex digits or a list of 1-4 (one per fan)"),
        chk(.fans.bottom | fan_colour; "fans.bottom must be 6 hex digits or a list of 1-4 (one per fan)"),
        chk(.rings | hex; "rings must be 6 hex digits"),
        chk(.strimers.mode | IN($ml[]); "strimers.mode \(.strimers.mode | tojson) is not a lian-li-linux RgbMode"),
        chk(.strimers.colors | type == "array" and length == 6 and all(hex); "strimers.colors must be exactly 6 hex colours"),
        chk(.strimers.speed | int(0; 4); "strimers.speed must be a whole number 0-4"),
        chk(.strimers.brightness == null or (.strimers.brightness | int(0; 4)); "strimers.brightness must be a whole number 0-4"),
        chk(.strimers.direction | IN("Clockwise", "CounterClockwise", "Up", "Down", "Spread", "Gather");
            "strimers.direction must be Clockwise or CounterClockwise"),
        chk(.alert == null or (.alert | type == "object"); "alert must be an object"),
        (.alert | objects | alert("alert")),
        ($a[0] | objects | alert("alerts.json")),
        chk(.screens == null or (.screens | type == "array"); "screens must be a list"),
        chk(.templates == null or (.templates | type == "array" and all(type == "string")); "templates must be a list of paths"),
        ((.screens // []) | arrays | to_entries[] | .key as $i | .value as $s | "screens[\($i)]" as $w
          | chk($s.serial | type == "string" and length > 0; "\($w).serial missing"),
            chk($s.type | IN("image", "video", "gif", "custom"); "\($w).type must be image, video or custom"),
            chk($s.type | IN("image", "video", "gif") | not or ($s.path | type == "string"); "\($w) needs a path"),
            chk($s.type != "custom" or ($s.template_id | type == "string"); "\($w) (custom) needs a template_id"),
            chk($s.orientation == null or ($s.orientation | type == "number"); "\($w).orientation must be a number"),
            chk($s.brightness == null or ($s.brightness | int(0; 100)); "\($w).brightness must be a whole number 0-100"),
            chk($s.clips == null or ($s.clips | type == "array" and all(type == "string")); "\($w).clips must be a list of files or folders"),
            chk($s.clips == null or $s.type == "video"; "\($w).clips only work on a video screen"),
            chk($s.rotate == null or ($s.rotate | int(30; 86400)); "\($w).rotate must be whole seconds, 30-86400")) ]
    | .[]' "$sf") || die "could not check $sf"
  # Media and template files must exist (relative paths are inside the theme).
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    [[ $p == /* ]] || p=$dir/$p
    [[ -f $p ]] || errs+=$'\n'"missing file $p"
  done < <(jq -r '((.screens // [] | if type == "object" then [.[] | arrays[], objects] else . end)[]? | objects | .path | strings),
                  ((.templates // [])[]? | strings)' "$tf" || echo "/nonexistent: could not list $tf paths")
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    [[ $p == /* ]] || p=$dir/$p
    [[ -e $p ]] || errs+=$'\n'"missing clip $p"
  done < <(jq -r '(.screens // [] | if type == "object" then [.[] | arrays[], objects] else . end)[]? | objects
                  | .clips // [] | .[]? | strings' "$tf" || true)
  # The OpenRGB half (gpu/board/ram), with stand-in RAM ids.
  openrgb_py on "$sf" "ram0 ram1" >/dev/null 2>"$TMP/orgb.err" || errs+=$'\n'"$(cat "$TMP/orgb.err")"
  errs=$(sed '/^$/d' <<<"$errs")
  if [[ -n $errs ]]; then
    while IFS= read -r p; do log "theme $name: $p"; done <<<"$errs"
    die "theme $name is invalid; nothing changed"
  fi
}

# pc-lights explain <theme> [--json]: per role, where its value came from
# (theme = the theme names the role, group = the theme's group key, palette =
# derived, model = a model:<Family> screen entry, none = left as it is,
# unmanaged = the profile says hands off), the value, and the device.
# "raw" is the value before this machine's calibration, when that changed it.
# shellcheck disable=SC2016 # jq filters: $x is jq's, not the shell's
explain_cmd() {
  local name=${1:-} json='' sf pf rows
  [[ ${2:-} == --json ]] && json=1
  [[ -n $name && $name != -* ]] || die "usage: pc-lights explain <theme> [--json]"
  theme_exists "$name" || die "theme '$name' not found in $THEME_DIR"
  sf=$THEME_DIR/$name/theme.json pf=$(theme_profile)
  jq -e 'type == "object"' "$sf" >/dev/null 2>&1 || die "$sf is not valid JSON"
  if [[ $(theme_schema "$sf") == 3 && ! -f $pf ]]; then
    die "theme $name is a v3 theme and there is no hardware profile; run: pc-lights detect"
  fi
  rows=$(theme_jq --slurpfile t "$sf" '
    $t[0] as $T
    | if ($T.v // 2) == 3 then
        {schema: 3, machine: ($P.machine.name // null), calibrated_for: ($T.led.calibrated_for // null),
         calibrated: compile($T; $P; $M; $C)._compiled.calibrated, palette: ($T.palette // null),
         rows: explain_rows($T; $P; $M; $C), coverage: coverage($T; $P; $M)}
      else
        {schema: 2, machine: ($P.machine.name // null), calibrated: false,
         rows: [coverage($T; $P; $M).roles | to_entries[] | .key as $R | ($R | role_kind) as $k
                | ($P.roles[$R].device // ($P.roles[$R].devices // [])[0]) as $dk
                | {role: $R, kind: $k, source: .value, device: $dk, name: ($P.devices[$dk].name // null),
                   label: ($P.roles[$R].label // null),
                   value: (if $k == "screen" then ([$T.screens[]? | select(.serial == ($P.devices[$dk].match.usb_serial // ""))][0]
                             | if . then "\(.type) \(.path // .template_id // "") @\(.orientation)" else null end)
                           elif $k == "peripheral" then null
                           else {fan: {fans: $T.fans}, strimer: $T.strimers, ring: $T.rings, gpu: $T.gpu, board: $T.board, ram: $T.ram}[$k]
                             | if . == null then null else th_show end end)}],
         coverage: coverage($T; $P; $M)}
      end') || die "could not explain theme $name"
  if [[ -n $json ]]; then echo "$rows"; return 0; fi
  jq -r --arg name "$name" '
    "theme \($name): v\(.schema)"
      + (if .machine then ", profile \(.machine)" else ", no hardware profile (legacy groups only)" end)
      + (if .schema == 3 then ", calibration " + (if .calibrated then "applied" elif .calibrated_for then "off (calibrated_for \(.calibrated_for))" else "off" end) else "" end),
    (if .palette then "palette: " + (.palette | to_entries | map("\(.key) \(.value)") | join("  ")) else empty end),
    "coverage: \(.coverage.summary) (\(.coverage.counts.theme) theme, \(.coverage.counts.palette) palette, \(.coverage.counts.none) none of \(.coverage.counts.total))",
    "" ' <<<"$rows"
  jq -r '(.rows[] | [ .role, .source, (.value // "-") + (if .raw then "  (was \(.raw))" else "" end),
                 ((.name // .device // "-") + (if .label then " [\(.label)]" else "" end)) ] | @tsv)' <<<"$rows" |
    column -t -s $'\t' -o '  '
}
