# lib/pc-lights/profile.sh — the hardware profile (~/.config/pc-lights/profile.json, plan §3 and §6)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP2 (profile + detect)
# Public: profile_cmd; PROFILE; profile_state, profile_detected_path,
#         profile_write, profile_merge
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables
# (SC2016: the jq programs are single-quoted on purpose).
# shellcheck shell=bash disable=SC2016,SC2034,SC2153,SC2154

# The profile (schema v1, plan §3): what hardware this machine has (devices,
# facts that detect regenerates), which role each device plays (roles: detect's
# guesses plus the user's edits), how many screens to expect, where the
# sensors are, the LED calibration (never written by detect) and the known
# workarounds. An override point (tests/golden/frozen.sh sets it), read at
# call time.
PROFILE=$STATE_DIR/profile.json

# Detect's last pure result, beside the profile: the merge compares the
# profile with it to tell a detect guess the user left alone from an edit.
profile_detected_path() { echo "${PROFILE%/*}/.profile.detected.json"; }

# profile_state: missing | invalid | ok (for status and the plugin).
profile_state() {
  if [[ ! -f $PROFILE ]]; then echo missing
  elif jq -e '.v == 1 and (.devices | type) == "object" and (.roles | type) == "object"' "$PROFILE" >/dev/null 2>&1; then echo ok
  else echo invalid; fi
}

# profile_write <file>: validate and install as the profile, atomically (tmp +
# mv, a new inode), so the plugin's inotify watcher never reads half a file.
profile_write() {
  jq -e '.v == 1 and (.devices | type) == "object" and (.roles | type) == "object"' "$1" >/dev/null 2>&1 ||
    die "refusing to write an invalid profile ($1)"
  mkdir -p "${PROFILE%/*}"
  if ! { jq . "$1" >"$PROFILE.$$.tmp" && mv -f "$PROFILE.$$.tmp" "$PROFILE"; }; then
    rm -f "$PROFILE.$$.tmp"; die "could not write $PROFILE"
  fi
}

# profile_merge <current> <last detection> <new detection>: prints
# {profile, conflicts: [{unit, kept, detected}], warnings: [...]}. Any file
# may be missing or hold null. Per unit (machine.name, each roles.<R>, each
# sensors.<k>, backends.<b>.enabled):
#   - no current value -> the new detection;
#   - the current value equals the last detection (the user didn't touch it)
#     -> the new detection (null drops it: detect no longer suggests it);
#   - source user/migrate, locked:true, or edited by hand -> kept; a hand
#     edit of a detected value (source detect or openrgb) becomes source "user". When the kept binding
#     differs from the new guess, that is reported as a conflict.
# Without a last detection, a value that differs from the new one is kept as
# it is. devices, workarounds, screens and the backends' facts come from the
# new detection; calibration and unknown top-level keys are carried over.
profile_merge() {
  local f args=()
  for f in "$1" "$2" "$3"; do
    if [[ -s $f ]] && jq -e . "$f" >/dev/null 2>&1; then args+=("$f"); else args+=(/dev/null); fi
  done
  jq -n --slurpfile P "${args[0]}" --slurpfile L "${args[1]}" --slurpfile D "${args[2]}" '
    ($P[0] // null) as $P | ($L[0] // null) as $L | $D[0] as $D
    | ($L != null) as $haslast
    | def bind: if type == "object" then {device, devices} else . end;
      def pinned($c): ($c | type) == "object" and ((($c.source // "") | IN("user", "migrate")) or $c.locked == true);
      # unit($cur; $last; $new) -> {v, keep}
      def unit($cur; $last; $new):
        if $cur == null then {v: $new, keep: false}
        elif pinned($cur) then {v: $cur, keep: true}
        elif $haslast and $cur == $last then {v: $new, keep: false}
        elif ($haslast | not) and $cur == $new then {v: $new, keep: false}
        elif ($haslast | not) then {v: $cur, keep: true}
        else {v: (if ($cur | type) == "object" and (($cur.source // "detect") | IN("detect", "openrgb")) then $cur + {source: "user"} else $cur end), keep: true}
        end;
      def conflict($u; $name; $cur; $new; cmp):
        if $u.keep and $new != null and ($cur | cmp) != ($new | cmp) then [{unit: $name, kept: ($cur | cmp), detected: ($new | cmp)}] else [] end;
      def keysof($a; $b): ($a // {} | keys_unsorted) as $ka | $ka + (($b // {}) | keys_unsorted | map(select(. as $k | $ka | index($k) | not)));
    # roles: the new detection order, then the ones only the profile has
      (reduce keysof($D.roles; $P.roles)[] as $r ({roles: {}, c: []};
        unit($P.roles[$r]; $L.roles[$r]; $D.roles[$r]) as $u
        | (if $u.v != null then .roles[$r] = $u.v else . end)
        | .c += conflict($u; "roles.\($r)"; $P.roles[$r]; $D.roles[$r]; bind))) as $roles
    | (reduce keysof($D.sensors; $P.sensors)[] as $k ({s: {}, c: []};
        unit($P.sensors[$k]; $L.sensors[$k]; $D.sensors[$k]) as $u
        | (if $u.v != null then .s[$k] = $u.v else . end)
        | .c += conflict($u; "sensors.\($k)"; $P.sensors[$k]; $D.sensors[$k]; .))) as $sensors
    | unit($P.machine.name; $L.machine.name; $D.machine.name) as $name
    | (reduce keysof($D.backends; $P.backends)[] as $b ({};
        # never "enabled // true": the alternative operator turns a false into true
        unit($P.backends[$b].enabled; $L.backends[$b].enabled; $D.backends[$b].enabled != false) as $u
        | .[$b] = (($D.backends[$b] // ($P.backends[$b] // {})) + {enabled: ($u.v != false)}
                   | {enabled} + .))) as $backends
    # a device no longer present keeps its roles; a role naming a device the
    # profile does not know is only a warning (the user may be ahead of detect)
    | ([$roles.roles | to_entries[] | .key as $r | (.value.device // empty), (.value.devices // [])[]
        | select(. as $k | $D.devices | has($k) | not) | "role \($r) names unknown device \(.)"]) as $warn
    | ([$roles.roles | to_entries[] | select(.key | test("^screen\\.(fan[0-9]+|pump|main|aux[0-9]+)$"))] | length) as $nscreens
    | {profile: ({v: 1,
                  machine: ($D.machine + {name: $name.v}),
                  backends: $backends,
                  devices: $D.devices,
                  roles: $roles.roles,
                  screens: {expected: ([$nscreens, ($D.screens.expected // 0)] | max)},
                  sensors: $sensors.s}
                 + (if $P.calibration != null then {calibration: $P.calibration} else {} end)
                 + {workarounds: $D.workarounds}
                 + (($P // {}) | del(.v, .machine, .backends, .devices, .roles, .screens, .sensors, .calibration, .workarounds)))
       , conflicts: ($roles.c + $sensors.c + (if $name.keep and $P.machine.name != $D.machine.name then [{unit: "machine.name", kept: $P.machine.name, detected: $D.machine.name}] else [] end)),
       warnings: $warn}
    # Idempotent: when nothing but the timestamp changed, keep the old one.
    | if $P != null and (.profile | del(.machine.detected_at)) == ($P | del(.machine.detected_at)) then .profile = $P else . end'
}

# ---- pc-lights profile ... -----------------------------------------------------------------
PROFILE_USAGE="usage: pc-lights profile show [--json] | path
  | set <role> [<device-key>...] [--managed on|off] [--mount 0|90|180|270] [--label TEXT]
                [--group ROLE] [--argb-size N|none] [--argb-zones i,j,..] [--lock|--unlock]
  | unset <role> | name <machine-name> | backend <lianli|openrgb> on|off
  | calibration on|off|import <file> | prune"

# The role vocabulary (plan §2).
PROFILE_ROLE_RE='^(fans\.[a-z0-9]+|strimer\.[a-z0-9]+|pump\.(ring|logo)|screen\.main\.ring|gpu|board|board\.argb|ram|keyboard|mouse|mousepad|headset|ledstrip\.[0-9]+|other\.[0-9]+|screen\.fan[0-9]+|screen\.(pump|main)|screen\.aux[0-9]+|ignore)$'

# profile_edit <jq filter> [jq args...]: apply a change to the profile under
# the lock and write it back atomically.
profile_edit() {
  local filter=$1; shift
  [[ -f $PROFILE ]] || die "no profile at $PROFILE; run 'pc-lights detect' first"
  jq -e '.v == 1' "$PROFILE" >/dev/null 2>&1 || die "$PROFILE is not a v1 profile"
  take_lock
  jq "$@" "$filter" "$PROFILE" >"$TMP/profile-edit.json" || die "profile edit failed"
  profile_write "$TMP/profile-edit.json"
}

profile_show() {
  [[ -f $PROFILE ]] || { echo "profile: none at $PROFILE (run 'pc-lights detect')"; return 0; }
  jq -r --arg path "$PROFILE" '
    . as $p
    | def dname($k): if $k == null then "-" else (($p.devices[$k].name // "?") + " [\($k)]" + (if $p.devices[$k] == null then " (unknown device)"
                     elif $p.devices[$k].present == false then " (missing)" else "" end)) end;
      def pad($n): tostring | . + (" " * ([$n - length, 1] | max));
    "profile: \($path)",
    "machine: \(.machine.name) (host \(.machine.hostname), detected \(.machine.detected_at))",
    "backends: " + ([.backends | to_entries[] | "\(.key) \(if .value.enabled == false then "disabled" else .value.state end)\(if .value.version then " \(.value.version)" else "" end)"] | join(", ")),
    "roles:",
    (.roles | to_entries[] | .key as $r | .value as $v
      | "  \($r | pad(18))\(([$v.device // empty] + ($v.devices // [])) | map(dname(.)) | join(", ") | pad(64))"
        + ([(if $v.managed == false then "unmanaged" else empty end), (if $v.mount != null then "mount \($v.mount)" else empty end),
            (if $v.argb then "argb zones \($v.argb.zones | map(tostring) | join(",")) size \($v.argb.size // "none")" else empty end),
            (if $v.locked then "locked" else empty end), "\($v.source // "?")/\($v.confidence // "?")",
            (if $v.label then "\"\($v.label)\"" else empty end)] | join("  "))),
    "screens expected: \(.screens.expected // 0)",
    "sensors: " + ([.sensors // {} | to_entries[] | "\(.key) \(.value.driver // .value.kind)\(if .value.label then " (\(.value.label))" else "" end)"] | join(", ") | if . == "" then "none" else . end),
    "calibration: " + (if .calibration == null then "none" elif .calibration.enabled then "on (\(.calibration.classes | keys | join(" ")))" else "off" end),
    (if ((.workarounds // {}) | length) > 0 then "workarounds: " + ([.workarounds | to_entries[]
       | "\(.key) \(if .value.present then "installed" else "not installed" end)\(if .value.needed == true then ", needed" elif .value.needed == false then ", not needed" else "" end)"] | join("; "))
     else empty end),
    (if ([.devices[] | select(.present == false)] | length) > 0 then
       "missing devices: " + ([.devices | to_entries[] | select(.value.present == false) | .key] | join(", ")) else empty end),
    ([.devices | to_entries[] | .key as $k | select([$p.roles[] | (.device // empty), (.devices // [])[]] | index($k) | not)] as $free
     | if ($free | length) > 0 then "devices without a role: " + ($free | map(.key) | join(", ")) else empty end)' "$PROFILE"
}

# profile set <role> [<device-key>...] [options]: a user edit (source "user",
# confidence "sure"), which detect keeps from then on.
profile_set() {
  local role=${1:-} a keys=() opts='{}' v
  [[ -n $role ]] || die "$PROFILE_USAGE"
  [[ $role =~ $PROFILE_ROLE_RE ]] || die "unknown role '$role' (see plan §2: fans.<pos>, strimer.<n>, pump.ring, screen.fan<n>, gpu, board, ram, mouse, ...)"
  shift
  while (( $# )); do
    a=$1; shift
    case $a in
      --managed)
        [[ ${1:-} =~ ^(on|off)$ ]] || die "--managed on|off"
        opts=$(jq -c --argjson m "$([[ $1 == on ]] && echo true || echo false)" '.managed = $m' <<<"$opts"); shift ;;
      --mount)
        [[ ${1:-} =~ ^(0|90|180|270)$ ]] || die "--mount 0|90|180|270"
        opts=$(jq -c --argjson m "$1" '.mount = $m' <<<"$opts"); shift ;;
      --label)
        [[ $# -ge 1 ]] || die "--label TEXT"
        opts=$(jq -c --arg l "$1" '.label = $l' <<<"$opts"); shift ;;
      --group)
        [[ ${1:-} =~ ^fans\.[a-z0-9]+$ ]] || die "--group fans.<pos>"
        opts=$(jq -c --arg g "$1" '.group = $g' <<<"$opts"); shift ;;
      --argb-size)
        [[ ${1:-} =~ ^([0-9]+|none)$ ]] || die "--argb-size N|none"
        v=$([[ $1 == none ]] && echo null || echo "$1")
        opts=$(jq -c --argjson s "$v" '.argb_size = $s' <<<"$opts"); shift ;;
      --argb-zones)
        [[ ${1:-} =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--argb-zones i,j,..."
        opts=$(jq -c --arg z "$1" '.argb_zones = ($z | split(",") | map(tonumber))' <<<"$opts"); shift ;;
      --lock) opts=$(jq -c '.locked = true' <<<"$opts") ;;
      --unlock) opts=$(jq -c '.locked = false' <<<"$opts") ;;
      -*) die "$PROFILE_USAGE" ;;
      *) keys+=("$a") ;;
    esac
  done
  (( ${#keys[@]} > 0 )) || [[ $opts != '{}' ]] || die "$PROFILE_USAGE"
  [[ -f $PROFILE ]] || die "no profile at $PROFILE; run 'pc-lights detect' first"
  for a in "${keys[@]}"; do
    jq -e --arg k "$a" '.devices | has($k)' "$PROFILE" >/dev/null ||
      die "no device '$a' in the profile (see: pc-lights profile show; keys look like lianli:mac:... or openrgb:<name>#0)"
  done
  if (( ${#keys[@]} == 0 )); then
    jq -e --arg r "$role" '.roles | has($r)' "$PROFILE" >/dev/null || die "role $role has no device yet: name one"
  fi
  profile_edit '
    (.roles[$r] // {}) as $old
    | (if ($keys | length) == 0 then $old
       elif ($keys | length) == 1 and $r != "ram" and $r != "ignore" then ($old | del(.devices)) + {device: $keys[0]}
       else ($old | del(.device)) + {devices: $keys} end) as $b
    | ($b + ($o | del(.argb_size, .argb_zones))
       | if $o | has("argb_size") then .argb = ((.argb // {zones: []}) + {size: $o.argb_size}) else . end
       | if $o | has("argb_zones") then .argb = ((.argb // {size: null}) + {zones: $o.argb_zones}) else . end
       | if .locked == false then del(.locked) else . end
       | .source = "user" | .confidence = "sure") as $new
    | .roles[$r] = $new' --arg r "$role" --argjson keys "$(printf '%s\n' "${keys[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" --argjson o "$opts"
  jq -r --arg r "$role" '"\($r): \(.roles[$r] | tojson)"' "$PROFILE"
}

# profile prune: forget the devices marked missing, and the roles that only
# pointed at them.
profile_prune() {
  profile_edit '
    ([.devices | to_entries[] | select(.value.present == false) | .key]) as $gone
    | .devices |= with_entries(select(.key as $k | $gone | index($k) | not))
    | .roles |= (with_entries(
        if .value.devices then .value.devices -= $gone else . end
        | select((.value.device == null or (.value.device as $d | $gone | index($d) | not))
                 and (.value.devices == null or (.value.devices | length) > 0))))'
  echo "pruned; $(jq '.devices | length' "$PROFILE") devices, $(jq '.roles | length' "$PROFILE") roles left"
}

profile_cmd() {
  local sub=${1:-show}
  shift || true
  case $sub in
    show)
      if [[ ${1:-} == --json ]]; then
        [[ -f $PROFILE ]] || die "no profile at $PROFILE; run 'pc-lights detect'"
        jq . "$PROFILE"
      else
        profile_show
      fi
      ;;
    path) echo "$PROFILE" ;;
    set) profile_set "$@" ;;
    unset)
      [[ ${1:-} =~ $PROFILE_ROLE_RE ]] || die "usage: pc-lights profile unset <role>"
      profile_edit 'del(.roles[$r])' --arg r "$1"
      echo "removed role $1 (a later detect may suggest it again; 'set $1 --managed off' keeps it undriven)"
      ;;
    name)
      [[ -n ${1:-} ]] || die "usage: pc-lights profile name <machine-name>"
      profile_edit '.machine.name = $n' --arg n "$1"
      echo "machine name: $1 (themes stamped led.calibrated_for=$1 skip calibration here)"
      ;;
    backend)
      [[ ${1:-} =~ ^[a-z0-9_-]+$ && ${2:-} =~ ^(on|off)$ ]] || die "usage: pc-lights profile backend <name> on|off"
      profile_edit '.backends[$b] = ((.backends[$b] // {state: "unknown"}) + {enabled: $e} | {enabled} + .)' \
        --arg b "$1" --argjson e "$([[ $2 == on ]] && echo true || echo false)"
      echo "backend $1: $2"
      ;;
    calibration)
      case ${1:-} in
        on | off)
          jq -e '.calibration != null' "$PROFILE" >/dev/null 2>&1 || die "no calibration in the profile; import one first"
          profile_edit '.calibration.enabled = $e' --argjson e "$([[ $1 == on ]] && echo true || echo false)"
          echo "calibration $1"
          ;;
        import)
          [[ -f ${2:-} ]] || die "usage: pc-lights profile calibration import <file> (a calibration object or a profile holding one)"
          jq -e '(.classes // .calibration.classes) | type == "object"' "$2" >/dev/null 2>&1 || die "$2 has no calibration classes"
          profile_edit '.calibration = ($c[0] | if has("classes") then . else .calibration end)' --slurpfile c "$2"
          echo "calibration imported from $2"
          ;;
        *) die "usage: pc-lights profile calibration on|off|import <file>" ;;
      esac
      ;;
    prune) profile_prune ;;
    *) die "$PROFILE_USAGE" ;;
  esac
}
