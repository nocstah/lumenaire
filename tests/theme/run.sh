#!/usr/bin/env bash
# tests/theme/run.sh — theme v3 (plan §4, §5): compile, calibration, palette
# derivation, screens by role/model, coverage, validation and explain.
#
#   tests/theme/run.sh [engine]   (default: the repo's bin/pc-lights)
#
# Pure jq tests run theme.jq against tests/fixtures/profile.example-desktop.json
# (fake serials and MACs) and a models stub (lib/pc-lights/models.json from
# WP2 is used instead when it exists). The engine tests run bin/pc-lights
# against a fixture $HOME in a mktemp dir, through PCL_TEST_OVERRIDES: only
# explain, theme_eff and validate_theme run, nothing reaches the daemon,
# OpenRGB, the units or the live config. PCL_THEME_TEST_STUB=1 forces the
# models stub even when WP2's models.json exists.
# shellcheck disable=SC2016  # the single-quoted strings are jq filters
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
PCL=$(readlink -f "${1:-$repo/bin/pc-lights}")
LIB=$repo/lib/pc-lights
FX=$repo/tests/fixtures
PROF=$FX/profile.example-desktop.json
MODELS=$here/models.stub.json
[[ -f $LIB/models.json && -z ${PCL_THEME_TEST_STUB:-} ]] && MODELS=$LIB/models.json
PRESETS=$LIB/calibration-presets.json
V3=$here/sakura.v3.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
passed=0 failed=0

ok() { passed=$((passed + 1)); echo "ok   $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [[ -z ${2:-} ]] || head -20 <<<"$2" | sed 's/^/     /'; }
tj() {   # tj <theme.json> <profile.json> <filter>: theme.jq with $T $P $M $C bound
  jq -n -L "$LIB" --slurpfile t "$1" --slurpfile p "$2" --slurpfile m "$MODELS" --slurpfile c "$PRESETS" \
    "include \"theme\"; \$t[0] as \$T | \$p[0] as \$P | \$m[0] as \$M | \$c[0] as \$C | $3"
}
# check <name> <theme.json> <profile.json> <filter over $T $P $M $C that must print true>
check() {
  local name=$1 out
  if out=$(tj "$2" "$3" "$4" 2>&1) && [[ $out == true ]]; then ok "$name"; else bad "$name" "$out"; fi
}
# Variants of the fixture profile and themes.
jq '.machine.name = "elsewhere"' "$PROF" >"$T/p-other.json"
jq '.calibration.enabled = false' "$PROF" >"$T/p-nocal.json"
jq 'del(.roles["strimer.atx24"], .roles["strimer.gpu"], .roles.gpu, .roles["screen.main.ring"], .roles["screen.fan4"], .roles["screen.fan5"])' \
  "$PROF" >"$T/p-missing.json"
jq '.devices["lianli:lcd:a1a1a1a100000006"] += {family: "HydroShiftLcd", name: "HydroShift LCD", panel: [480, 480]}' \
  "$PROF" >"$T/p-round.json"
jq '.roles.keyboard = {device: "openrgb:Kb#0", managed: true, source: "user", confidence: "sure"}
    | .devices["openrgb:Kb#0"] = {backend: "openrgb", present: true, name: "Kb", type: "Keyboard", kind: "peripheral"}' \
  "$PROF" >"$T/p-kbd.json"
echo '{"v": 3, "palette": {"primary": "00c8ff", "secondary": "8000ff"}}' >"$T/palette-only.json"
echo '{"v": 3, "palette": {"primary": "40a0c0", "led_safe": false}}' >"$T/no-led-safe.json"
jq 'del(.led)' "$V3" >"$T/sakura-unstamped.json"
jq '.screens = {"model:TlFlexLcd": [{"type": "image", "path": "a.png"}, {"type": "image", "path": "b.png"}],
                "screen.fan2": {"type": "image", "path": "own.png", "orientation": 270}}' "$V3" >"$T/by-model.json"
jq 'del(._roles)' "$FX/eff.sakura.json" >"$T/sakura.v2.json"
jq '.screens |= map(.serial = "0000000000000000")' "$T/sakura.v2.json" >"$T/foreign.v2.json"

echo "# compile: sakura v3 == the v2 sakura (legacy keys, screens, _roles)"
tj "$V3" "$PROF" 'compile($T; $P; $M; $C)' >"$T/eff.json"
if diff <(jq -S 'del(._roles, ._coverage, ._compiled, .palette)' "$T/eff.json") \
        <(jq -S 'del(._roles)' "$FX/eff.sakura.json") >"$T/d" 2>&1; then ok "legacy keys equal eff.sakura.json"
else bad "legacy keys equal eff.sakura.json" "$(cat "$T/d")"; fi
if diff <(jq '.screens' "$T/eff.json") <(jq '.screens' "$FX/eff.sakura.json") >"$T/d" 2>&1; then ok "screens equal, same order and key order"
else bad "screens equal, same order and key order" "$(cat "$T/d")"; fi
if diff <(jq -S '._roles' "$T/eff.json") <(jq -S '._roles' "$FX/eff.sakura.json") >"$T/d" 2>&1; then ok "_roles equal eff.sakura.json"
else bad "_roles equal eff.sakura.json" "$(cat "$T/d")"; fi
if [[ $(jq -c '[.screens[].orientation]' "$T/eff.json") == '[180,180,180,0,0,90,90]' ]]; then ok "orientation = model + mount, printed as integers"
else bad "orientation = model + mount, printed as integers" "$(jq -c '[.screens[].orientation]' "$T/eff.json")"; fi
check "stamped for this machine: not calibrated" "$V3" "$PROF" 'compile($T; $P; $M; $C)._compiled == {schema: 3, machine: "example-desktop", calibrated: false}'
check "_coverage: groups, theme screens, mouse unmanaged" "$V3" "$PROF" '
  compile($T; $P; $M; $C)._coverage as $c
  | $c["fans.side"] == "group" and $c.gpu == "theme" and $c.mouse == "unmanaged" and $c["screen.pump"] == "theme"
    and ($c | has("ignore") | not) and ([$c[]] | length) == 19'
check "v2 theme compiles to itself" "$T/sakura.v2.json" "$PROF" 'compile($T; $P; $M; $C) == $T'
if [[ $(jq -n -L "$LIB" --slurpfile a "$T/sakura.v2.json" --slurpfile b "$T/eff.json" --slurpfile p "$PROF" \
     'include "theme"; ($a[0] | v2_projection($p[0])) == ($b[0] | v2_projection($p[0]))') == true ]]; then
  ok "v2_projection(v2 sakura) == v2_projection(compile(v3 sakura))"
else bad "v2_projection(v2 sakura) == v2_projection(compile(v3 sakura))"; fi
a=$(tj "$V3" "$PROF" 'compile($T; $P; $M; $C) | del(._compiled)'); b=$(tj "$V3" "$T/p-nocal.json" 'compile($T; $P; $M; $C) | del(._compiled)')
if [[ $a == "$b" ]]; then ok "calibration on vs off: same EFF for a stamped theme"; else bad "calibration on vs off: same EFF for a stamped theme"; fi

echo "# calibration (plan §5 formulas)"
check "ffc048 on tl_fan -> ~ff4c1d (each channel within 1)" "$V3" "$PROF" '
  ("ffc048" | calibrate_hex($P.calibration.classes.tl_fan) | th_rgb) as $a | ("ff4c1d" | th_rgb) as $b
  | [range(3) as $i | ($a[$i] - $b[$i]) | fabs <= 1] | all'
check "ffc048 on strimer -> ff9939 (plan: ~ff9939)" "$V3" "$PROF" '("ffc048" | calibrate_hex($P.calibration.classes.strimer)) == "ff9939"'
check "near-neutrals pass calibration unchanged (ffffff, f0f0f0, e8e8f0)" "$V3" "$PROF" '[("ffffff", "f0f0f0", "e8e8f0") | calibrate_hex($P.calibration.classes.tl_fan)] == ["ffffff", "f0f0f0", "e8e8f0"]'
check "ffd0e6 on tl_fan -> ff6699" "$V3" "$PROF" '("ffd0e6" | calibrate_hex($P.calibration.classes.tl_fan)) == "ff6699"'
check "missing class is the identity" "$V3" "$PROF" '("ffd0e6" | calibrate_hex(null)) == "ffd0e6" and ("#FFC048" | calibrate_hex($P.calibration.classes.peripheral)) == "#FFC048"'
check "saturated colours pass unchanged" "$V3" "$PROF" '[("ff0000", "ff4a9a", "00ff88", "3050ff") | calibrate_hex($P.calibration.classes.tl_fan)] == ["ff0000", "ff4a9a", "00ff88", "3050ff"]'
check "gain multiplies, rounds and clamps" "$V3" "$PROF" '("808080" | calibrate_hex({gain: [2, 1, 0.5]})) == "ff8040"'
check "unstamped theme is calibrated here (fans on tl_fan, strimers on strimer)" "$T/sakura-unstamped.json" "$PROF" '
  ($T | .roles.fans.inner = "ffd0e6" | .roles.strimers.colors[0] = "ffc048") as $t | compile($t; $P; $M; $C)
  | ._compiled.calibrated and ._roles["fans.side"].fans.top == "ff6699" and .fans.top == "ff6699"
    and ._roles["strimer.gpu"].strimers.colors[0] == "ff9939" and .strimers.colors[0] == "ff9939"'
check "stamp for another machine is calibrated too" "$V3" "$T/p-other.json" 'compile($T; $P; $M; $C)._compiled.calibrated'
check "profile preset + class override merge" "$T/sakura-unstamped.json" "$PROF" '
  ($P | .calibration = {enabled: true, preset: "lianli-photo", classes: {tl_fan: {pink_br_max: 0.2}}}) as $p
  | ($T | .roles.fans.inner = "ffd0e6") as $t | compile($t; $p; $M; $C)._roles["fans.side"].fans.top == "ff6633"'

echo "# palette-only themes"
check "every managed lighting role gets a derived value" "$T/palette-only.json" "$PROF" '
  compile($T; $P; $M; $C) as $e
  | ([$P.roles | to_entries[] | select((.key | role_kind) | IN("fan", "strimer", "ring", "gpu", "board", "ram")) | .key] - ($e._roles | keys)) == []
    and ([$e._coverage | to_entries[] | select((.key | role_kind) != "screen" and .key != "mouse") | .value] | unique) == ["palette"]'
check "derived values follow the §5 table (led_safe on)" "$T/palette-only.json" "$T/p-nocal.json" '
  compile($T; $P; $M; $C) as $e | ("00c8ff" | led_safe_hex) as $p | ("8000ff" | led_safe_hex) as $s
  | ($e.palette.accent | led_safe_hex) as $a
  | $e._roles["fans.top"].fans == {top: $p, bottom: $s}
    and $e._roles["strimer.gpu"].strimers == {mode: "Drizzling", colors: [$p, $s, $a, $p, $s, $a], speed: 2, direction: "Clockwise"}
    and $e._roles["pump.ring"].rings == $a and $e._roles.board.board == $a
    and $e._roles.gpu.gpu == {gradient: [$p, $s]} and $e._roles.ram.ram == {gradient: [$p, $a, $s], span: "across"}
    and $e.fans == {top: $p, bottom: $s} and $e.rings == $a'
check "palette-only colours are all 6 hex digits and saturated" "$T/palette-only.json" "$PROF" '
  [compile($T; $P; $M; $C) | (.fans, .strimers.colors, .rings, .gpu, .board, .ram) | .. | strings | select((th_hex | not) and (IN("Drizzling", "Clockwise", "across") | not))] == []
  and ([compile($T; $P; $M; $C)._roles[] | .. | strings | select(th_hex) | th_rgb | th_hsv | .[1] >= 0.99 and .[2] >= 0.99] | all)'
check "led_safe false keeps the palette colours" "$T/no-led-safe.json" "$T/p-nocal.json" '
  compile($T; $P; $M; $C) | .fans.top == "40a0c0" and .rings == "40a0c0"'
check "no screens in the theme: screens [] and every screen role none" "$T/palette-only.json" "$PROF" '
  compile($T; $P; $M; $C) | .screens == [] and ([._coverage | to_entries[] | select(.key | startswith("screen.fan")) | .value] | unique) == ["none"]'
check "mouse is never derived, keyboard is when managed" "$T/palette-only.json" "$T/p-kbd.json" '
  compile($T; $P; $M; $C) | ._roles.mouse == null and ._coverage.mouse == "unmanaged"
    and ._roles.keyboard.peripheral != null and ._coverage.keyboard == "palette"'
s1=$(tj "$T/palette-only.json" "$PROF" 'coverage($T; $P; $M).summary'); s2=$(tj "$V3" "$PROF" 'coverage($T; $P; $M) | "\(.summary) \(.counts.total) \(.counts.none)"')
if [[ $s1 == '"leds-only"' && $s2 == '"full 18 0"' ]]; then ok "coverage summary: palette-only leds-only, sakura full 18/18"
else bad "coverage summary: palette-only leds-only, sakura full 18/18" "$s1 / $s2"; fi

echo "# missing roles, screens by role and model"
check "roles missing from the profile are skipped quietly" "$V3" "$T/p-missing.json" '
  compile($T; $P; $M; $C) | (._roles | has("strimer.gpu") or has("gpu") or has("screen.main.ring") | not)
    and .strimers.mode == "Drizzling" and .gpu.gradient != null and (.screens | length) == 5'
check "round pump screen: wide-curve media -> coverage none, no entry" "$V3" "$T/p-round.json" '
  compile($T; $P; $M; $C) | ._coverage["screen.pump"] == "none" and (.screens | length) == 6
    and ([.screens[].serial] | index("a1a1a1a100000006") | not)'
check "round pump: coverage summary partial, missing screen.pump" "$V3" "$T/p-round.json" '
  coverage($T; $P; $M) | .summary == "partial" and .missing == ["screen.pump"]'
check "model:<Family> lists cycle, a role entry wins, explicit orientation kept" "$T/by-model.json" "$PROF" '
  compile($T; $P; $M; $C) | [.screens[] | select(.serial | startswith("f1f1")) | [.path, .orientation]]
    == [["a.png", 180], ["own.png", 270], ["a.png", 180], ["b.png", 0], ["a.png", 0]]
  and ._coverage["screen.fan1"] == "model" and ._coverage["screen.fan2"] == "theme" and ._coverage["screen.pump"] == "none"'
check "no profile: legacy keys only, no screens" "$T/palette-only.json" "$T/p-nocal.json" '
  compile($T; null; $M; $C) | ._roles == {} and .screens == [] and (.fans.top | th_hex)'

echo "# v2 coverage and validation"
check "v2 theme on its machine: full" "$T/sakura.v2.json" "$PROF" 'coverage($T; $P; $M).summary == "full"'
check "v2 theme from another machine: foreign" "$T/foreign.v2.json" "$PROF" 'coverage($T; $P; $M).summary == "foreign"'
check "v3_problems: sakura v3 is clean" "$V3" "$PROF" '[$T | v3_problems("Drizzling Static")] == []'
check "v3_problems: bad values are reported" "$V3" "$PROF" '
  [$T | .palette.primary = "red" | .roles.fanz = "ff0000" | .roles.strimers.speed = 9 | .screens["screen.pump"].rotate = 5
      | .screens["screen.fan"][0].serial = "x" | v3_problems("Drizzling Static")] | length == 5'

echo "# engine: theme_eff, validate_theme, explain (fixture HOME)"
H=$T/home; TD=$H/.config/pc-lights/themes
mkdir -p "$TD/sakura/media/pump" "$TD/sakura/us88" "$TD/sakura2/media/pump" "$TD/sakura2/us88" "$TD/palette"
for d in sakura sakura2; do
  for f in fan-a fan-b fan-c fan-d fan-e pump; do : >"$TD/$d/media/$f.mp4"; done
  : >"$TD/$d/media/pump/1.mp4"; echo '{}' >"$TD/$d/us88/us88-sakura.template.json"
done
cp "$V3" "$TD/sakura/theme.json"
cp "$T/sakura.v2.json" "$TD/sakura2/theme.json"
cp "$T/palette-only.json" "$TD/palette/theme.json"
echo sakura >"$H/.config/pc-lights/scheme"
cat >"$T/over.sh" <<'EOF'
# PROFILE is an override point set here (the engine never reads it from the
# environment: profile.sh sets it at load time).
PROFILE=$T_PROF
logger() { :; }
systemctl() { echo "blocked: systemctl $*" >&2; return 1; }
openrgb() { echo "blocked: openrgb" >&2; return 1; }
daemon_call() { return 1; }
if [[ -n ${T_CALL:-} ]]; then eval "$T_CALL"; exit $?; fi
EOF
eng() { env HOME="$H" T_PROF="${T_PROFILE:-$PROF}" PCL_MODELS="$MODELS" PCL_TEST_OVERRIDES="$T/over.sh" "$PCL" "$@"; }
ecall() { T_CALL=$1 eng status; }
if out=$(ecall 'scheme_file' 2>&1) && [[ $out == "$H/.cache/pc-lights/compiled/sakura."*.json ]] &&
   [[ $(jq -S 'del(._roles, ._coverage, ._compiled, .palette)' "$out") == "$(jq -S 'del(._roles)' "$FX/eff.sakura.json")" ]]; then
  ok "scheme_file compiles a v3 theme into \$CACHE/compiled/<name>.<sha12>.json"
else bad "scheme_file compiles a v3 theme" "$out"; fi
if [[ $(jq -r '._compiled | "\(.theme_sha256 | length) \(.profile_sha256 | length)"' "$out") == "64 64" ]]; then ok "_compiled carries theme and profile sha256"
else bad "_compiled carries theme and profile sha256"; fi
out2=$(ecall 'scheme_file' 2>&1); if [[ $out2 == "$out" && $(find "$H/.cache/pc-lights/compiled" -name 'sakura.*' | wc -l) == 1 ]]; then ok "cache hit, one copy per theme"
else bad "cache hit, one copy per theme" "$out2"; fi
out=$(T_CALL='THEME=sakura2 scheme_file' eng status 2>&1); if [[ $out == "$TD/sakura2/theme.json" ]]; then ok "v2 theme: EFF is theme.json itself"
else bad "v2 theme: EFF is theme.json itself" "$out"; fi
if out=$(ecall 'validate_theme sakura && validate_theme sakura2 && validate_theme palette && echo VALID' 2>&1) && [[ $out == *VALID ]]; then
  ok "validate_theme: v3 sakura, v2 sakura, palette-only all valid"
else bad "validate_theme: v3 sakura, v2 sakura, palette-only all valid" "$out"; fi
rm "$TD/sakura/media/fan-e.mp4"
if out=$(ecall 'validate_theme sakura' 2>&1); then bad "validate_theme: missing media is reported" "$out"
elif [[ $out == *"missing file $TD/sakura/media/fan-e.mp4"* ]]; then ok "validate_theme: missing media is reported"
else bad "validate_theme: missing media is reported" "$out"; fi
: >"$TD/sakura/media/fan-e.mp4"
jq '.roles.strimers.mode = "Nope"' "$V3" >"$TD/palette/theme.json"
if out=$(ecall 'validate_theme palette' 2>&1); then bad "validate_theme: bad v3 value dies" "$out"
elif [[ $out == *'roles.strimers.mode "Nope" is not a lian-li-linux RgbMode'* ]]; then ok "validate_theme: bad v3 value dies with the reason"
else bad "validate_theme: bad v3 value dies with the reason" "$out"; fi
cp "$T/palette-only.json" "$TD/palette/theme.json"
if out=$(T_PROFILE=$T/none.json ecall 'validate_theme sakura' 2>&1); then bad "v3 without a profile dies" "$out"
elif [[ $out == *"no hardware profile; run: pc-lights detect"* ]]; then ok "v3 without a profile dies before anything (run: pc-lights detect)"
else bad "v3 without a profile dies" "$out"; fi
if out=$(T_PROFILE=$T/none.json ecall 'validate_theme sakura2 && echo VALID' 2>&1) && [[ $out == *VALID ]]; then ok "v2 without a profile still validates"
else bad "v2 without a profile still validates" "$out"; fi
if out=$(eng explain sakura 2>&1) && grep -q '^fans.side  *group  *inner ff4a9a outer ff1a70' <<<"$out" &&
   grep -q '^screen.fan1  *theme  *video media/fan-a.mp4 @180 (model 0 + mount 180)' <<<"$out" &&
   grep -q '^mouse  *unmanaged' <<<"$out"; then ok "explain: role, source, value, device"
else bad "explain: role, source, value, device" "$out"; fi
if out=$(eng explain palette --json 2>&1) && jq -e '.schema == 3 and .calibrated and ([.rows[] | select(.role == "fans.side")][0].source == "palette")' <<<"$out" >/dev/null; then
  ok "explain --json: palette-only theme, calibration applied"
else bad "explain --json" "$out"; fi
if out=$(eng explain sakura2 2>&1) && grep -q '^screen.pump  *theme  *video media/pump.mp4 @90' <<<"$out"; then ok "explain: v2 theme"
else bad "explain: v2 theme" "$out"; fi

echo "# $passed passed, $failed failed"
(( failed == 0 ))
