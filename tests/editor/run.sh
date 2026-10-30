#!/usr/bin/env bash
# tests/editor/run.sh — the theme editor's engine half (editor plan §1.1-§1.4,
# §4 "A checks"): drafts, pointer edits, the editor view, save with history,
# delete, rename, history/restore, the LED hints and the calibration parity.
#
#   tests/editor/run.sh [engine]   (default: the repo's bin/lumenaire)
#
# Everything runs against fixture $HOMEs in a mktemp dir (PCL_TEST_ROOT sets
# where): v3 themes from tests/theme/sakura.v3.json and examples/themes, a
# v2 copy of sakura, an auto-theme, and tests/fixtures/profile.example-desktop.json
# (fake IDs). The engine's test hook (PCL_TEST_OVERRIDES) blocks the daemon,
# OpenRGB, systemctl and systemd-run, stubs the queued pick, and routes
# "theme <verb>" straight to editor_cmd (so the suite runs before or after
# the core's dispatcher routes it). Nothing touches the lights, the live
# config or a real unit.
#
# When this machine has them, a last section also edits a v3 sakura that
# migrate --out built from the frozen v2 sakura against the golden profile
# (~/.cache/pc-lights/golden/v2/{themes-v2/sakura,profile.json}, real IDs;
# tests/golden/README.md; never the live theme dir): only inside the
# fixture, and nothing from it is printed. PCL_EDITOR_NO_GOLDEN=1 skips it.
# shellcheck disable=SC2016 # jq filters in single quotes
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
PCL=$(readlink -f "${1:-$repo/bin/lumenaire}")
LIB=$repo/lib/pc-lights
FX=$repo/tests/fixtures
PROF=$FX/profile.example-desktop.json
V3=$repo/tests/theme/sakura.v3.json
[[ -x $PCL ]] || { echo "no engine at $PCL" >&2; exit 2; }
ROOT=${PCL_TEST_ROOT:-}
if [[ -n $ROOT ]]; then mkdir -p "$ROOT"; T=$(mktemp -d -p "$ROOT" editor.XXXXXX); else T=$(mktemp -d); fi
cleanup() { if [[ -z ${KEEP_FIXTURE:-} ]]; then rm -rf "$T"; else echo "fixture kept: $T"; fi; }
trap cleanup EXIT
passed=0 failed=0

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || head -c 600 <<<"$2" | sed 's/^/     /'; echo; }
# run <cmd...>: stdout in $out, stderr in $err, exit code in $rc.
run() { rc=0; out=$("$@" 2>"$T/stderr") || rc=$?; err=$(<"$T/stderr"); }
# jc <name> <jq filter> [json]: pass when jq -e holds on $out (or the json).
jc() {
  local j=${3-$out}
  if jq -e "$2" >/dev/null 2>&1 <<<"$j"; then ok "$1"; else bad "$1" "$(jq -c "$2" <<<"$j" 2>&1 | head -c 300) :: $(head -c 300 <<<"$j") $err"; fi
}
# rcis <name> <rc> [code]: the last run exited <rc> (with error code <code>).
rcis() {
  if [[ $rc == "$2" ]] && { [[ -z ${3:-} ]] || [[ $(jq -r .code <<<"$out" 2>/dev/null) == "$3" ]]; }; then ok "$1"
  else bad "$1" "rc=$rc out=$out err=$err"; fi
}
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# ---- fixture HOME ------------------------------------------------------------------
H=$T/home C=$T/home/.config/pc-lights K=$T/home/.cache/pc-lights
TD=$C/themes
mkdir -p "$TD" "$K/previews" "$H/.config/lianli"
d=sakura
mkdir -p "$TD/$d/media/pump" "$TD/$d/us88" "$TD/$d/src"
for f in fan-a fan-b fan-c fan-d fan-e pump; do echo "$d $f" >"$TD/$d/media/$f.mp4"; done
echo "$d clip" >"$TD/$d/media/pump/1.mp4"; echo '{}' >"$TD/$d/us88/us88-sakura.template.json"
echo '{"note": "art sources"}' >"$TD/$d/src/prompts.json"
cp "$V3" "$TD/sakura/theme.json"
cp -r "$repo/examples/themes/." "$TD/"
mkdir -p "$TD/stealth" && jq '._about = "stealth: a night theme"' "$repo/examples/themes/glacier/theme.json" >"$TD/stealth/theme.json"
mkdir -p "$TD/sakura2" && jq 'del(._roles)' "$FX/eff.sakura.json" >"$TD/sakura2/theme.json"
mkdir -p "$TD/omarchy-test/src"
echo '{"v": 3, "palette": {"primary": "ff4a00", "secondary": "ff1400"}}' >"$TD/omarchy-test/theme.json"
jq -n --arg h "$(sha256sum <"$TD/omarchy-test/theme.json" | cut -c1-64)" '{generator: "auto-theme v2", theme_json_sha256: $h}' \
  >"$TD/omarchy-test/src/source.json"
cp "$PROF" "$C/profile.json"
echo sakura >"$C/scheme"; echo sakura >"$C/day-scheme"; echo on >"$C/lights"; echo on >"$C/screens"
printf '{\n  "enabled": true,\n  "night_theme": "stealth",\n  "night_start": "00:00",\n  "night_end": "07:00"\n}\n' >"$C/schedule.json"
printf '{\n  "_default": "auto",\n  "rose-pine": "sakura",\n  "sakura": "sakura",\n  "nord": "glacier"\n}\n' >"$C/omarchy-map.json"
printf '{"theme": "sakura", "since": 1790000000, "screens": {}}\n' >"$K/clips.json"
echo webp >"$K/previews/aurora.webp"; echo '{}' >"$K/previews/aurora.json"
echo webp >"$K/previews/sakura.webp"; echo '{"name": "sakura"}' >"$K/previews/sakura.json"

cat >"$T/over.sh" <<'EOF'
# Sourced by the engine (PCL_TEST_OVERRIDES): no hardware, no daemon, no units.
if [[ $(type -t editor_cmd) != function ]]; then source "$PCL_LIB/editor.sh"; fi
logger() { :; }
systemctl() { echo "blocked: systemctl $*" >>"$HOME/stub.log"; return 1; }
systemd-run() { echo "blocked: systemd-run $*" >>"$HOME/stub.log"; return 1; }
openrgb() { echo "blocked: openrgb" >&2; return 1; }
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
lianli_lights() { echo "lianli_lights $*" >>"$HOME/stub.log"; }
apply_openrgb() { echo "apply_openrgb" >>"$HOME/stub.log"; }
ed_queue_pick() { echo "pick $1" >>"$HOME/stub.log"; echo '{"queued": true, "unit": "pc-lights-ui-pick-test"}'; }
preview_live() { [[ -f $HOME/preview-live ]]; }
preview_yield() { echo "preview_yield $*" >>"$HOME/stub.log"; rm -f "$HOME/preview-live"; }
if [[ -n ${T_CALL:-} ]]; then eval "$T_CALL"; exit $?; fi
if [[ ${1:-} == theme && ${2:-} != preview ]]; then shift; editor_cmd "$@"; exit $?; fi
EOF
eng() { env HOME="$H" PCL_TEST_OVERRIDES="$T/over.sh" "$PCL" "$@"; }
th() { eng theme "$@"; }
ecall() { T_CALL=$1 eng status; }
# ej <filter>: jq with theme.jq + editor.jq (the way ed_jq loads them) and $P/$M/$C.
ej() {
  jq -n -L "$LIB" --slurpfile p "$PROF" --slurpfile c "$LIB/calibration-presets.json" --slurpfile m "$LIB/models.json" \
    "${@:1:$#-1}" 'include "theme"; '"$(<"$LIB/editor.jq")"' $p[0] as $P | $m[0] as $M | $c[0] as $C | '"${*: -1}"
}
sha() { sha256sum <"$1" | cut -c1-64; }
MODES=$(sed -n "s/^STRIMER_MODES='\(.*\)'$/\1/p" "$LIB/theme.sh")

# The §1.4 schema every view must hold.
SCHEMA='
  def colourf: (.path | type == "string") and has("value") and (.source | IN("role", "group", "palette"))
    and has("source_path") and has("shows") and (.changed | type == "boolean") and (.hints | type == "array");
  def listf: (.path | type == "string") and (.value | type == "array") and (.shows | type == "array")
    and (.hints | type == "array" and all(.[]; type == "array"));
  def hint: (.code | type == "string") and (.level | IN("warn", "info")) and (.text | type == "string") and has("fix");
  .v == 1 and (.name | type == "string") and (.mode | IN("edit", "new", "duplicate", "saved"))
  and (.rev | type == "number") and (.dirty | type == "boolean") and (.draft | type == "boolean")
  and (.saved | type == "object" and has("exists", "sha256", "active", "day", "night", "auto", "mapped_slugs"))
  and has("base_sha256") and (.conflict | type == "boolean") and (.auto | type == "boolean")
  and has("machine") and has("media_root") and has("from") and has("updated")
  and (.calibration | has("enabled", "applies", "reason", "calibrated_for", "classes", "fix_classes")
       and (.reason | IN("on", "off-in-profile", "stamped")))
  and .theme.v == 3 and (.about | has("path", "value"))
  and (.palette | has("primary", "secondary", "accent", "alert", "led_safe"))
  and all(.palette.primary, .palette.secondary, .palette.accent; has("path", "value", "set", "derived_use", "shows", "hints") and all(.hints[]; hint))
  and (.palette.led_safe.value | type == "boolean")
  and (.groups | type == "array") and all(.groups[]; has("group", "roles", "set", "path"))
  and (.roles | type == "array" and length > 0)
  and all(.roles[]; has("role", "kind", "form", "group", "label", "device", "present", "managed", "backend", "class",
                        "source", "editable", "readonly_reason", "fields")
                    and (.form | IN("fan", "strimer", "colour", "gradient", "readonly")) and (.source | IN("role", "group", "palette")))
  and all(.roles[] | select(.form == "fan") | .fields | .inner, .outer; colourf and all(.hints[]; hint))
  and all(.roles[] | select(.form == "strimer") | .fields; has("mode", "speed", "direction", "colors")
          and (.colors | listf) and (.colors.value | length == 6) and (.colors.hints | length == 6))
  and all(.roles[] | select(.form == "colour") | .fields.colour; colourf)
  and all(.roles[] | select(.form == "gradient") | .fields; (.shape.value | IN("solid", "gradient"))
          and (if .shape.value == "gradient" then (.stops | listf) else (.colour | colourf) end))
  and (.screens | has("editable", "coverage", "summary")) and (.problems | type == "array")
  and all(.problems[]; has("path", "level", "message"))
  and (.limits | has("strimer_modes", "directions", "speed", "gradient_stops", "fan_list_max")) and has("preview")'

echo "engine:  $PCL"
echo "fixture: $T"

echo "# the frozen fixture (tests/fixtures/editor.sakura.json)"
jc "editor.sakura.json holds the §1.4 schema" "$SCHEMA" "$(cat "$FX/editor.sakura.json")"
jq '.theme' "$FX/editor.sakura.json" >"$T/fx-theme.json"
if out=$(ej --slurpfile t "$T/fx-theme.json" --arg modes "$MODES" '
    editor_view({v: 1, name: "sakura-2", mode: "duplicate", from: "sakura", rev: 3, created: 1790000000, updated: 1790000400,
                 base_sha256: null, media_root: "/home/you/.config/pc-lights/themes/sakura", theme: $t[0]};
                {exists: false, sha256: null, theme: null}; $P; $M; $C; $modes;
                {draft: true, active: false, day: false, night: false, mapped_slugs: [], auto: false, problems: [], preview: null})' 2>&1) &&
   diff <(jq -S . <<<"$out") <(jq -S . "$FX/editor.sakura.json") >"$T/d"; then
  ok "editor_view still gives exactly the frozen fixture"
else bad "editor_view still gives exactly the frozen fixture" "$(head -40 "$T/d" 2>/dev/null) $out"; fi

echo "# show, and the editable checks"
run th show sakura --json
rcis "show sakura (saved): exit 0" 0
jc "saved view: §1.4 schema" "$SCHEMA"
jc "saved view: mode saved, not a draft, active/day/mapped" '.mode == "saved" and .draft == false and .dirty == false and .rev == 0
  and .saved.exists and .saved.active and .saved.day and (.saved.night | not) and .saved.mapped_slugs == ["rose-pine", "sakura"]
  and .base_sha256 == .saved.sha256 and .machine == "example-desktop"'
jc "saved view: stamped sakura is not calibrated" '.calibration.enabled and (.calibration.applies | not) and .calibration.reason == "stamped"'
jc "saved view: 12 lighting roles, profile order within kinds, no mouse/screens/ignore" '[.roles[].role] == ["fans.side", "fans.bottom", "fans.top",
  "strimer.atx24", "strimer.gpu", "pump.ring", "screen.main.ring", "gpu", "board", "board.argb", "ram"]'
jc "saved view: groups fans/strimers/rings from the theme" '[.groups[] | [.group, .set, (.roles | length)]] == [["fans", true, 3], ["strimers", true, 2], ["rings", true, 2]]'
jc "saved view: screens summary, editable (v3 + screen roles), sig of screens + templates" '.screens.editable == true and .screens.coverage == "full"
  and .screens.summary == "5 fan videos, pump video, main template" and (.screens.sig | test("^[0-9a-f]{16}$"))'
run th show sakura2 --json
rcis "show a v2 theme: 5 not-v3" 5 not-v3
run th edit sakura2 --json
rcis "edit a v2 theme: 5 not-v3" 5 not-v3
run th show nope --json
rcis "show an unknown theme: 2 not-found" 2 not-found
mv "$C/profile.json" "$C/profile.away"
run th edit sakura --json
rcis "no profile: 5 no-profile" 5 no-profile
run th new fresh --json
rcis "new without a profile: 5 no-profile" 5 no-profile
mv "$C/profile.away" "$C/profile.json"
jc "error object: {error, code}" '(.error | type == "string") and .code == "no-profile"'

echo "# names"
nb=0
for n in 'Bad' '-x' 'a b' '.hidden' "$(printf 'x%.0s' {1..49})"; do
  run th new "$n" --json
  if [[ $rc != 2 ]] || ! jq -e '.code | IN("bad-name", "usage")' >/dev/null <<<"$out"; then bad "bad name '$n' refused" "rc=$rc $out"; nb=1; fi
done
if (( nb == 0 )); then ok "bad names refused with 2 (bad-name/usage)"; fi
run th new omarchy-mine --json; rcis "new omarchy-*: 2 bad-name" 2 bad-name
run th new aurora --json; rcis "new with an existing name: 2 exists" 2 exists

echo "# new (palette only)"
run th new mine --palette primary=#00FF8A,accent=00d8ff --json
rcis "new mine: exit 0" 0
jc "new view: §1.4 schema, mode new, rev 1, dirty, no media root" "$SCHEMA"' and .mode == "new" and .rev == 1 and .dirty and .draft
  and .from == null and .media_root == null and (.saved.exists | not)'
jc "new view: palette set/derived, secondary default" '.palette.primary.value == "00ff8a" and .palette.primary.set
  and .palette.accent.value == "00d8ff" and .palette.secondary.value == "7a1aff" and .theme.palette == {primary: "00ff8a", secondary: "7a1aff", accent: "00d8ff"}'
jc "new view: every role from the palette, leds-only coverage" 'all(.roles[]; .source == "palette") and .screens.coverage == "leds-only"
  and .screens.summary == "No screen media: the screens keep what they show."'
jc "new view: unstamped, so calibrated here" '.calibration.applies and .calibration.reason == "on"'
check "draft file is 0600" test "$(stat -c %a "$C/drafts/mine.json")" = 600
jc "draft file: the §1.1 schema" '.v == 1 and .name == "mine" and .mode == "new" and .from == null and .rev == 1
  and (.created | type == "number") and .updated == .created and .base_sha256 == null and .media_root == null and .theme.v == 3' "$(cat "$C/drafts/mine.json")"
run th new mine --json; rcis "new with a name that has a draft: 2 exists" 2 exists
run th new bad1 --palette primary=zz0000 --json; rcis "new with a bad palette hex: 2 invalid" 2 invalid

echo "# set: pointers, values, normalising"
run th set mine /roles/fans.side/inner FFC048 /roles/strimers/speed 3 --json
rcis "set two pointers: exit 0" 0
jc "set: rev 2, hex lower-cased without #" '.rev == 2 and .theme.roles["fans.side"] == {inner: "ffc048"} and .theme.roles.strimers == {speed: 3}'
jc "per-field sources: fan inner from the role, outer from the palette" '(.roles[] | select(.role == "fans.side") | .fields) as $f
  | $f.inner.source == "role" and $f.inner.source_path == "/roles/fans.side/inner"
    and $f.outer.source == "palette" and $f.outer.source_path == "/palette/secondary"
    and (.roles[] | select(.role == "fans.side") | .source) == "role"
    and (.roles[] | select(.role == "fans.top") | .source) == "palette"'
jc "per-field sources: strimer speed from the group, colours from the palette" '(.roles[] | select(.role == "strimer.gpu") | .fields) as $f
  | $f.speed == {path: "/roles/strimer.gpu/speed", value: 3, source: "group", source_path: "/roles/strimers/speed"}
    and $f.colors.source == "palette" and $f.mode.value == "Drizzling" and $f.mode.source == "palette" and $f.mode.source_path == null'
jc "warm hint on the fan field: warm_green, calibration corrects it" '(.roles[] | select(.role == "fans.side") | .fields.inner) as $i
  | $i.shows != "ffc048" and $i.changed and ($i.hints | map(.code) == ["warm_green"]) and $i.hints[0].level == "info"'
run th set mine /roles/strimer.gpu/colors '["ff0000","00ff00","0000ff","ff0000","00ff00","0000ff"]' /roles/strimer.gpu/mode Wave /motion/direction CounterClockwise --json
jc "strimer partial override: colours+mode from the role, speed group, direction from motion" '(.roles[] | select(.role == "strimer.gpu") | .fields) as $f
  | $f.colors.source == "role" and $f.mode.source == "role" and $f.speed.source == "group"
    and $f.direction == {path: "/roles/strimer.gpu/direction", value: "CounterClockwise", source: "palette", source_path: "/motion/direction"}
    and ((.roles[] | select(.role == "strimer.atx24") | .fields.colors.source) == "palette")'
run th set mine /roles/fans.side/inner null --json
jc "unset the last field: the role is pruned" '.theme.roles | has("fans.side") | not'
run th set mine --unset /roles/strimers/speed --unset /roles/strimer.gpu --unset /motion/direction --json
jc "unset everything: roles and motion pruned, v stays 3" '(.theme | has("roles") | not) and (.theme | has("motion") | not) and .theme.v == 3 and (.theme | keys_unsorted[0]) == "v"'
run th set mine /_x~1y '"a/b"' /_t~0 '{"k": null}' --json
jc "~1 and ~0 unescape; _ keys kept as they are" '.theme["_x/y"] == "a/b" and .theme["_t~"] == {k: null}'
run th set mine --patch-json '[{"op":"remove","path":"/_x~1y"},{"op":"remove","path":"/_t~0"},{"op":"add","path":"/roles/ram","value":{"gradient":["ff0000","0000ff"]}},{"op":"add","path":"/roles/ram/gradient/1","value":"00FF00"},{"op":"add","path":"/roles/ram/gradient/-","value":"#ffffff"}]' --json
jc "patch: add inserts into a list, - appends, hex normalised" '.theme.roles.ram.gradient == ["ff0000", "00ff00", "0000ff", "ffffff"] and (.theme | has("_x/y") | not)'
jc "ram gradient field: role source, span default across" '(.roles[] | select(.role == "ram") | .fields) as $f
  | $f.shape.value == "gradient" and $f.stops.source == "role" and $f.stops.value == ["ff0000", "00ff00", "0000ff", "ffffff"]
    and ($f.stops.hints[3] | map(.code)) == ["near_white"] and $f.span.value == "across"'
rev=$(jq .rev <<<"$out")
run th set mine /roles/gpu ff0000 --base-rev $((rev - 1)) --json
rcis "set with a stale --base-rev: 2 stale-rev" 2 stale-rev
run th set mine /roles/gpu ff0000 --base-rev "$rev" --json
rcis "set with the current --base-rev: 0" 0
jc "gpu as one colour: shape solid" '.rev == '"$((rev + 1))"' and ((.roles[] | select(.role == "gpu") | .fields) | .shape.value == "solid" and .colour.value == "ff0000" and .colour.source == "role")'
run th set mine /roles/fans ff0000 --json
run th set mine /roles/fans/inner 00ff00 --json
jc "a fan group written as one colour splits into inner/outer when one is set" '.theme.roles.fans == {inner: "00ff00", outer: "ff0000"}'
run th set mine /roles/strimers/speed 9 /roles/fans.top '["ff0000","00ff00","0000ff"]' --json
rcis "set never fails on content" 0
jc "content problems come back in the view, with pointers" '[.problems[] | .path] | index("/roles/strimers/speed") != null'
jc "per-fan list: read-only form with a reason" '(.roles[] | select(.role == "fans.top")) | .form == "readonly" and (.editable | not) and (.readonly_reason | startswith("Per-fan list (3 colours)"))'
run th set mine palette/primary ff0000 --json; rcis "a pointer must start with /: 2 usage" 2 usage
run th set mine /roles/gpu/gradient/0 ff0000 --json; rcis "set inside a colour string: 2 invalid" 2 invalid
run th set mine /v 2 --json; rcis "/v is fixed: 2 invalid" 2 invalid
run th set nodraft /palette/primary ff0000 --json; rcis "set without a draft: 2 not-found" 2 not-found
run th unset mine /roles/strimers/speed /roles/fans.top --json
jc "unset verb" '.theme.roles | (.strimers | has("speed") | not) and (has("fans.top") | not)'
run th set mine /roles/gpu '{"mode": "Rainbow"}' --json
jc "OpenRGB {mode} value: read-only" '(.roles[] | select(.role == "gpu")) | .form == "readonly" and (.readonly_reason | test("OpenRGB mode Rainbow"))'
run th set mine /roles/gpu null --json

echo "# the functions package B consumes"
out=$(ecall 'editor_draft_file mine; editor_draft_rev mine; editor_media_root mine; echo "[$(editor_media_root nope)]"; editor_draft_rev nope || echo "no-rev $?"' 2>&1)
if [[ $out == "$C/drafts/mine.json"$'\n'[0-9]*$'\n[]\nno-rev 1' ]]; then ok "editor_draft_file / _rev / editor_media_root"
else bad "editor_draft_file / _rev / editor_media_root" "$out"; fi
if eff=$(ecall 'editor_draft_eff mine' 2>&1) && [[ $eff == "$K/compiled/draft-mine."????????????".json" ]] &&
   jq -e '._compiled.schema == 3 and (.fans | has("top", "bottom")) and (._roles | length) > 0' "$eff" >/dev/null; then
  ok "editor_draft_eff: \$CACHE/compiled/draft-<name>.<key>.json, a compiled EFF"
else bad "editor_draft_eff" "$eff"; fi
eff2=$(ecall 'editor_draft_eff mine' 2>&1)
check "editor_draft_eff: same key for the same draft" test "$eff2" = "$eff"
if [[ -z $(ecall 'editor_draft_problems mine' 2>&1) ]]; then ok "editor_draft_problems: a valid draft prints nothing"
else bad "editor_draft_problems: a valid draft prints nothing" "$(ecall 'editor_draft_problems mine' 2>&1)"; fi
th set mine /roles/strimers/colors '["ff0000"]' >/dev/null 2>&1
out=$(ecall 'editor_draft_problems mine' 2>&1)
if [[ $out == "roles.strimers.colors must be exactly 6 hex colours" ]]; then ok "editor_draft_problems: one line per problem"
else bad "editor_draft_problems: one line per problem" "$out"; fi
out=$(ecall 'editor_draft_problems mine --fast' 2>&1)
check "editor_draft_problems --fast: the same schema problems" test "$out" = "roles.strimers.colors must be exactly 6 hex colours"
check "no draft file for a theme without one" test ! -e "$C/drafts/sakura.json"
out=$(ecall 'editor_drafts_json'); jc "editor_drafts_json: [{name, mode, from, rev, updated}]" 'length == 1 and .[0].name == "mine" and .[0].mode == "new" and (.[0] | keys) == ["from", "mode", "name", "rev", "updated"]'
run th drafts --json; jc "theme drafts --json: {drafts: [...]}" '.drafts | length == 1'

echo "# save: problems, new folder"
run th save mine --json
rcis "save a draft with problems: 2 invalid" 2 invalid
jc "save problems carry pointers" '.problems == [{path: "/roles/strimers/colors", level: "error", message: "roles.strimers.colors must be exactly 6 hex colours"}]'
check "nothing saved" test ! -e "$TD/mine"
th set mine /roles/strimers/colors null >/dev/null
run th save mine --json
rcis "save a new theme: exit 0" 0
jc "save result" '.saved and .name == "mine" and .created and .history == null and .apply == null'
check "the new theme is in place, the draft gone" test -f "$TD/mine/theme.json" -a ! -e "$C/drafts/mine.json"
check "no .new-* folder left behind" test -z "$(find "$TD" -maxdepth 1 -name '.new-*')"
jc "saved bytes are the draft's theme" '.v == 3 and .palette.primary == "00ff8a"' "$(cat "$TD/mine/theme.json")"
if ecall 'validate_theme mine && echo VALID' 2>&1 | grep -q VALID; then ok "the saved theme validates like any other"; else bad "the saved theme validates"; fi

echo "# duplicate (media linked, src/source.json never copied)"
run th duplicate sakura sakura-2 --json
rcis "duplicate sakura sakura-2: exit 0" 0
jc "duplicate view: mode duplicate, from sakura, media root sakura, screens from sakura" "$SCHEMA"' and .mode == "duplicate" and .from == "sakura"
  and .media_root == "'"$TD/sakura"'" and .screens.summary == "5 fan videos, pump video, main template (from sakura)" and .problems == []'
th set sakura-2 /palette/primary ffd0e6 /roles/fans.side '{"inner":"ffc048"}' /roles/fans.top '{"outer":"ff2bd6"}' /led null >/dev/null
run th show sakura-2 --json
jq --arg r "/home/you/.config/pc-lights/themes/sakura" '.media_root = $r | .rev = 3 | .created = 1790000000 | .updated = 1790000400' <<<"$out" >"$T/view.json"
if diff <(jq -S . "$T/view.json") <(jq -S . "$FX/editor.sakura.json") >"$T/d"; then ok "engine view of the same draft == the frozen fixture (bar paths and times)"
else bad "engine view of the same draft == the frozen fixture" "$(head -30 "$T/d")"; fi
cp "$TD/sakura/src/prompts.json" "$T/prompts.before"
echo '{"generator": "hand"}' >"$TD/sakura/src/source.json"
run th save sakura-2 --json
rcis "save the duplicate: exit 0" 0
check "media hard-linked, not copied" test "$(stat -c %i "$TD/sakura-2/media/fan-a.mp4")" = "$(stat -c %i "$TD/sakura/media/fan-a.mp4")"
check "src/ copied without source.json" test -f "$TD/sakura-2/src/prompts.json" -a ! -e "$TD/sakura-2/src/source.json"
check "the original sakura untouched" cmp -s "$TD/sakura/theme.json" "$V3"
rm -f "$TD/sakura/src/source.json"

echo "# edit + save an existing theme: new inode, history, twins keep their bytes"
mkdir -p "$T/twin"; ln "$TD/sakura/theme.json" "$T/twin/theme.json"
old_ino=$(stat -c %i "$TD/sakura/theme.json") old_sha=$(sha "$TD/sakura/theme.json")
run th edit sakura --json
rcis "edit sakura: exit 0" 0
jc "edit view: mode edit, rev 1, base = saved sha, not dirty" "$SCHEMA"' and .mode == "edit" and .rev == 1 and (.dirty | not)
  and .base_sha256 == "'"$old_sha"'" and .saved.sha256 == .base_sha256 and (.conflict | not) and .media_root == "'"$TD/sakura"'"'
th set sakura /palette/accent ff0066 >/dev/null
run th edit sakura --json
jc "edit again resumes the draft" '.rev == 2 and .dirty and .theme.palette.accent == "ff0066"'
run th edit sakura --fresh --json
jc "edit --fresh starts over" '.rev == 1 and (.dirty | not)'
th set sakura /palette/accent ff0066 >/dev/null
run th save sakura --no-apply --json
rcis "save sakura: exit 0" 0
jc "save result: history entry, not created" '.saved and (.created | not) and (.history | test("/theme-history/sakura/[0-9]{8}T[0-9]{6}Z-'"${old_sha:0:12}"'\\.json$"))'
check "theme.json is a new inode" test "$(stat -c %i "$TD/sakura/theme.json")" != "$old_ino"
check "the hard-linked twin keeps the old bytes" test "$(sha "$T/twin/theme.json")" = "$old_sha"
hist=$(jq -r .history <<<"$out")
check "the history entry is the old inode" test "$(stat -c %i "$hist")" = "$old_ino"
jc "saved: the edit is in" '.palette.accent == "ff0066"' "$(cat "$TD/sakura/theme.json")"
check "--no-apply: no pick queued" test -z "$(grep -s '^pick' "$H/stub.log")"

echo "# conflict, --force, apply"
th edit sakura >/dev/null 2>&1
th set sakura /palette/accent ff0070 >/dev/null
jq '._about = "changed elsewhere"' "$TD/sakura/theme.json" >"$T/x.json" && mv "$T/x.json" "$TD/sakura/theme.json"
run th show sakura --json
jc "the view flags the conflict" '.conflict'
run th save sakura --json
rcis "save after the file changed: 4 conflict" 4 conflict
echo '{"theme": "sakura", "state": "live"}' >"$K/preview.json"; touch "$H/preview-live"
run th save sakura --force --json
rcis "save --force: exit 0" 0
jc "active theme, lights on: saved and applied (queued pick), preview ended" '.apply.queued == true and .preview_ended'
check "the pick was queued for sakura" grep -q '^pick sakura$' "$H/stub.log"
check "the preview was ended without a revert" grep -q '^preview_yield saved sakura --no-revert$' "$H/stub.log"
check "history: two entries now" test "$(find "$C/theme-history/sakura" -name '*.json' | wc -l)" = 2
: >"$H/stub.log"
th edit glacier >/dev/null 2>&1; th set glacier /palette/accent 0080ff >/dev/null
echo '{"theme": "glacier", "state": "live"}' >"$K/preview.json"; touch "$H/preview-live"
run th save glacier --json
jc "a theme that isn't active: not applied, preview ended with a revert" '.apply == null and .preview_ended'
check "revert: preview_yield without --no-revert" grep -q '^preview_yield saved glacier$' "$H/stub.log"
touch "$H/preview-live"
th edit mine >/dev/null 2>&1; th set mine /palette/accent ff8001 >/dev/null
run th save mine --json
jc "a preview of another draft is left alone" '(.preview_ended | not)'
rm -f "$H/preview-live" "$K/preview.json"
echo off >"$C/lights"
th edit sakura >/dev/null 2>&1; th set sakura /palette/accent ff0071 >/dev/null
run th save sakura --json
jc "lights off: the active theme is saved, not applied" '.apply == null'
echo on >"$C/lights"
th edit ember >/dev/null 2>&1; th set ember /palette/accent ff8000 >/dev/null
run th save ember --as ember-2 --apply --json
jc "save --as: a new theme; --apply queues it" '.name == "ember-2" and .created and .apply.queued'
check "save --as leaves the original untouched" cmp -s "$TD/ember/theme.json" "$repo/examples/themes/ember/theme.json"

echo "# a new folder appears meanwhile; .new-* folders stay out of the list"
th new racer >/dev/null 2>&1
mkdir -p "$TD/racer"
run th save racer --json
rcis "the name appeared meanwhile: 2 exists" 2 exists
check "no .new-* left behind" test -z "$(find "$TD" -maxdepth 1 -name '.new-*')"
check "the draft is kept" test -f "$C/drafts/racer.json"
rmdir "$TD/racer"
mkdir -p "$TD/.new-ghost.1"; cp "$TD/aurora/theme.json" "$TD/.new-ghost.1/"
if eng themes --json 2>/dev/null | jq -e 'all(.[]; .name | startswith(".") | not)' >/dev/null; then ok "themes --json never lists a half-built .new-* folder"
else bad "themes --json never lists a half-built .new-* folder"; fi
rm -rf "$TD/.new-ghost.1"

echo "# discard, revert"
run th revert racer --json; rcis "revert a new theme: 2 usage" 2 usage
run th discard racer --json
jc "discard" '.discarded and .name == "racer"'
check "draft gone" test ! -e "$C/drafts/racer.json"
run th discard racer --json; rcis "discard again: 2 not-found" 2 not-found
th edit glacier >/dev/null 2>&1; th set glacier /palette/primary ff0000 >/dev/null
run th revert glacier --json
jc "revert: back to saved as a new rev" ".rev == 3 and (.dirty | not) and .theme == $(jq -c . "$TD/glacier/theme.json")"
th discard glacier >/dev/null

echo "# omarchy-* auto themes"
run th edit omarchy-test --json
rcis "edit an auto theme: allowed" 0
jc "auto theme view: auto true" '.auto and .saved.auto'
check "a warning that saving stops auto-refresh" grep -q 'auto-refresh' <<<"$err"
th discard omarchy-test >/dev/null
run th rename omarchy-test mine-auto --json; rcis "rename an auto theme: 2 bad-name" 2 bad-name
run th rename aurora omarchy-x --json; rcis "rename to omarchy-*: 2 bad-name" 2 bad-name

echo "# v2 -> v3 through new --from"
run th new sakura2-v3 --from sakura2 --json
rcis "new --from a v2 theme: exit 0" 0
jc "converted: v3, stamped for this machine, fans inner/outer" '.mode == "duplicate" and .theme.v == 3 and .theme.led.calibrated_for == "example-desktop"
  and .theme.roles.fans.inner == "ff4a9a" and (.theme.screens | has("screen.fan"))'
eff=$(ecall 'editor_draft_eff sakura2-v3' 2>&1)
if [[ $(jq -n -L "$LIB" --slurpfile a "$TD/sakura2/theme.json" --slurpfile b "$eff" --slurpfile p "$PROF" \
     'include "theme"; ($a[0] | v2_projection($p[0])) == ($b[0] | v2_projection($p[0]))') == true ]]; then
  ok "its compile matches the v2 theme's projection"
else bad "its compile matches the v2 theme's projection" "$(diff <(jq -S -n -L "$LIB" --slurpfile a "$TD/sakura2/theme.json" --slurpfile p "$PROF" 'include "theme"; $a[0] | v2_projection($p[0])') <(jq -S -n -L "$LIB" --slurpfile b "$eff" --slurpfile p "$PROF" 'include "theme"; $b[0] | v2_projection($p[0])'))"; fi
th discard sakura2-v3 >/dev/null

echo "# delete"
run th delete sakura --json; rcis "delete the active theme: 2 in-use" 2 in-use
jc "in-use lists every reference" '[.problems[].message] == ["active", "day", "map:rose-pine", "map:sakura"]'
run th delete stealth --json; rcis "delete the night theme: 2 in-use" 2 in-use
run th delete glacier --json; rcis "delete a mapped theme: 2 in-use" 2 in-use
th edit aurora >/dev/null 2>&1
run th delete aurora --json
rcis "delete aurora: exit 0" 0
t_dir=$(jq -r .trash <<<"$out")
check "moved to the trash, whole" test -f "$t_dir/theme.json" -a ! -e "$TD/aurora" -a "${t_dir%/*}" = "$C/themes.trash"
check "draft and previews dropped" test ! -e "$C/drafts/aurora.json" -a ! -e "$K/previews/aurora.webp" -a ! -e "$K/previews/aurora.json"
run th delete aurora --json; rcis "delete again: 2 not-found" 2 not-found

echo "# rename rewrites every reference byte for byte"
for f in scheme day-scheme schedule.json omarchy-map.json; do cp -p "$C/$f" "$T/$f.before"; done
cp -p "$K/clips.json" "$T/clips.before"
th duplicate sakura blossom-copy >/dev/null 2>&1
th edit sakura >/dev/null 2>&1
exec 9>"$K/lock"; flock 9
run th rename sakura blossom --json
rcis "rename while an apply holds the lock: 75" 75 busy
exec 9>&-
run th rename sakura blossom --json
rcis "rename sakura blossom: exit 0" 0
check "folder moved" test -f "$TD/blossom/theme.json" -a ! -e "$TD/sakura"
check "scheme rewritten" test "$(cat "$C/scheme")" = blossom
check "day-scheme rewritten" test "$(cat "$C/day-scheme")" = blossom
check "omarchy-map: values only, byte for byte" diff <(sed 's/: "sakura"/: "blossom"/' "$T/omarchy-map.json.before") "$C/omarchy-map.json"
check "clips.json .theme, byte for byte" diff <(sed 's/"theme": "sakura"/"theme": "blossom"/' "$T/clips.before") "$K/clips.json"
check "schedule.json untouched (night is stealth)" cmp -s "$T/schedule.json.before" "$C/schedule.json"
check "its draft follows (name)" test -f "$C/drafts/blossom.json" -a ! -e "$C/drafts/sakura.json"
jc "the draft is renamed and its media root follows" '.name == "blossom" and .media_root == "'"$TD/blossom"'"' "$(cat "$C/drafts/blossom.json")"
jc "a copy's draft follows too (from, media root)" '.from == "blossom" and .media_root == "'"$TD/blossom"'"' "$(cat "$C/drafts/blossom-copy.json")"
check "history folder follows" test -d "$C/theme-history/blossom" -a ! -e "$C/theme-history/sakura"
check "previews follow" test -f "$K/previews/blossom.webp" -a -f "$K/previews/blossom.json" -a ! -e "$K/previews/sakura.webp"
jc "result lists what changed" '.renamed and .from == "sakura" and .to == "blossom" and (.updated | length) >= 7'
run th rename stealth midnight --json
check "schedule.json night_theme, byte for byte" diff <(sed 's/"night_theme": "stealth"/"night_theme": "midnight"/' "$T/schedule.json.before") "$C/schedule.json"
run th rename glacier blossom --json; rcis "rename onto an existing theme: 2 exists" 2 exists
run th rename nope x --json; rcis "rename an unknown theme: 2 not-found" 2 not-found
th discard blossom >/dev/null; th discard blossom-copy >/dev/null

echo "# history and restore"
run th history blossom --json
jc "history: newest first, stamp + sha12" '.name == "blossom" and (.entries | length) >= 3
  and all(.entries[]; (.stamp | test("^[0-9]{8}T[0-9]{6}Z$")) and (.sha12 | test("^[0-9a-f]{12}$")) and (.bytes > 0))
  and (.entries | map(.stamp) == (map(.stamp) | sort | reverse))'
first=$(jq -r '.entries[-1] | "\(.stamp)-\(.sha12)"' <<<"$out")
before=$(sha "$TD/blossom/theme.json") n_before=$(jq '.entries | length' <<<"$out")
sleep 1
run th restore blossom "$first" --json
rcis "restore the oldest entry: exit 0" 0
check "restored bytes = the V3 fixture sakura" cmp -s "$TD/blossom/theme.json" "$V3"
run th history blossom --json
jc "the replaced file went to the history first" "(.entries | length) == $((n_before + 1)) and .entries[0].sha12 == \"${before:0:12}\""
run th restore blossom 20200101T000000Z --json; rcis "restore an unknown stamp: 2 not-found" 2 not-found
mkdir -p "$C/theme-history/glacier"
for i in $(seq 1 34); do printf '{"i": %d}\n' "$i" >"$C/theme-history/glacier/$(printf '202001%02dT0000%02dZ-%012d' "$i" "$i" "$i").json"; done
th edit glacier >/dev/null 2>&1; th set glacier /palette/accent 0070ff >/dev/null; th save glacier >/dev/null 2>&1
check "history keeps 30 entries, the newest included" test "$(find "$C/theme-history/glacier" -name '*.json' | wc -l)" = 30
check "the oldest went first" test ! -e "$C/theme-history/glacier/20200101T000001Z-000000000001.json"

echo "# LED hints (plan §4 table) and the calibration parity"
CALJ=$(jq -c '{applies: false, classes: .calibration.classes, fix_classes: .calibration.classes}' "$PROF")
out=$(ej --argjson cal "$CALJ" '[led_hints("ffc048"; "tl_fan"; $cal), led_hints("ffd0e6"; "tl_fan"; $cal), led_hints("00e5ff"; "tl_fan"; $cal),
  led_hints("ff2bd6"; "tl_fan"; $cal), led_hints("ff2bd6"; "strimer"; $cal), led_hints("101010"; "ring"; $cal), led_hints("f4f4f4"; "strimer"; $cal),
  led_hints("ff9020"; "strimer"; $cal), led_hints("ff9020"; "tl_fan"; $cal), led_hints("ffffff"; "tl_fan"; $cal), led_hints("#FFC048"; "tl_fan"; $cal)]')
jc "ffc048 on tl_fan: warm_green, fix ~ ff4c1d" '.[0] | map(.code) == ["warm_green"] and .[0].level == "warn"
  and (.[0].fix as $f | ["ff4c1d", "ff4d1d", "ff4b1d", "ff4c1c", "ff4c1e"] | index($f) != null)'
jc "ffd0e6: pastel and pink_green" '.[1] | map(.code) == ["pastel", "pink_green"]'
jc "00e5ff: no hints" '.[2] == []'
jc "ff2bd6 on a fan: violet_magenta with fix ff1a8c; not on a strimer" '(.[3] | map(.code) == ["violet_magenta"] and .[0].fix == "ff1a8c") and .[4] == []'
jc "101010: dark; f4f4f4: near_white (no fix)" '(.[5] | map(.code)) == ["dark"] and (.[6] | map(.code)) == ["near_white"] and .[6][0].fix == null'
jc "ff9020: fine on a strimer (G/R 0.56), warm on a fan (> 0.3)" '.[7] == [] and (.[8] | map(.code)) == ["warm_green"]'
jc "white: near_white only; # and upper case accepted" '(.[9] | map(.code)) == ["near_white"] and .[10] == .[0]'
out=$(ej --argjson cal "$(jq -c '.applies = true' <<<"$CALJ")" '[led_hints("ffc048"; "tl_fan"; $cal), led_hints("ffd0e6"; "tl_fan"; $cal)]')
jc "calibration applies: warm_green becomes info with what the LEDs get" '.[0][0].level == "info" and (.[0][0].text | test("the LEDs get ff4.1d"))'
jc "ffd0e6 calibrated to ff6699: both hints corrected" '.[1] | map(.level) == ["info", "info"] and all(.[]; .text | test("ff6699"))'
# The parity: what the view shows is calibrate_hex exactly, per class, and
# the role rows show exactly what compile sends.
out=$(ej --argjson cal "$(jq -c '.applies = true' <<<"$CALJ")" '
  [range(0; 200) as $i | ([($i * 7919) % 256, ($i * 104729 + 17) % 256, ($i * 1299709 + 91) % 256] | th_tohex)] as $cs
  | [$cs[] as $h | ("tl_fan", "fan", "strimer", "ring", "gpu", "board", "ram", "peripheral") as $k
     | select(($h | ed_show($k; $cal)) != ($h | calibrate_hex($P.calibration.classes[$k] // null)))] | length')
if [[ $out == 0 ]]; then ok "ed_show == calibrate_hex on 200 colours x every class"; else bad "ed_show == calibrate_hex" "$out"; fi
jq 'del(.led) | .roles.fans.inner = "ffd0e6" | .roles["fans.side"] = {outer: "ffc048"} | .roles["strimer.gpu"] = {colors: ["ffc048", "ffd0e6", "ff7ab6", "00e5ff", "ff2bd6", "f4f4f4"]}
    | .roles["pump.ring"] = "ffc048" | .roles.board = "ffd0e6" | .roles.gpu.gradient = ["ffc048", "ff9a30"]' "$V3" >"$T/uncal.json"
out=$(ej --slurpfile t "$T/uncal.json" --arg modes "$MODES" '
  editor_view({name: "x", mode: "new", rev: 1, theme: $t[0]}; {exists: false}; $P; $M; $C; $modes; {draft: true}) as $v
  | compile($t[0]; $P; $M; $C)._roles as $r
  | [$v.roles[] | . as $row | ($r[$row.role] | to_entries[0].value) as $e
     | if $row.form == "fan" then [$row.fields.inner.shows, $row.fields.outer.shows] == [$e.top, $e.bottom]
       elif $row.form == "strimer" then [$row.fields.colors.shows, $row.fields.mode.value, $row.fields.speed.value, $row.fields.direction.value] == [$e.colors, $e.mode, $e.speed, $e.direction]
       elif $row.form == "colour" then $row.fields.colour.shows == $e
       elif $row.fields.shape.value == "gradient" then $row.fields.stops.shows == $e.gradient and ($row.role != "ram" or $row.fields.span.value == $e.span)
       else $row.fields.colour.shows == $e end] | {n: length, ok: all, calibrated: $v.calibration.applies}')
jc "every role row shows exactly what compile sends (calibrated theme)" '.n == 11 and .ok and .calibrated'

echo "# screens (screens plan §1.2-§1.4, §4, §7 'B2: tests/editor')"
# Its own fixture $HOME: sakura with media files, the us88 template, the
# daemon's installed templates; B1's pipeline stood in for by fakes (probes
# from a table, thumbnails keyed by the file name, job records under
# $CACHE/media/jobs, cancels logged), so the views are exact with or without
# lib/pc-lights/media.sh.
S2=$T/scr H2=$T/scr/home
C2=$H2/.config/pc-lights K2=$H2/.cache/pc-lights TD2=$H2/.config/pc-lights/themes
mkdir -p "$TD2/sakura/media/pump" "$TD2/sakura/us88" "$TD2/sakura/src" "$K2/media/jobs" "$H2/.config/lianli" "$S2/tmp"
for f in fan-a fan-b fan-c fan-d fan-e pump; do echo "sakura $f" >"$TD2/sakura/media/$f.mp4"; done
echo "sakura pump 2" >"$TD2/sakura/media/pump/pump-2.mp4"
echo '{"id": "us88-sakura", "background": {"path": "us88/bg.png"}}' >"$TD2/sakura/us88/us88-sakura.template.json"
echo jpg >"$TD2/sakura/src/preview-us88.jpg"
echo '{"v": 1, "files": {"media/pump.mp4": {"source": "/x/pump.mov", "recipe": null, "model": "HydroShift2OledCurveLcd", "prepared": 1}}}' >"$TD2/sakura/src/media.json"
cp "$V3" "$TD2/sakura/theme.json"
cp -r "$repo/examples/themes/glacier" "$TD2/glacier"
cp "$PROF" "$C2/profile.json"
echo sakura >"$C2/scheme"; echo sakura >"$C2/day-scheme"; echo on >"$C2/lights"; echo on >"$C2/screens"
echo '{"templates": [{"id": "us88-sakura"}]}' >"$H2/.config/lianli/lcd_templates.json"
cat >"$S2/over.sh" <<'EOF'
# The editor's fixture overrides (as over.sh), and B1's pipeline as fakes
# (media.sh loads itself on first use: loaded first, so the fakes stay).
if [[ $(type -t editor_cmd) != function ]]; then source "$PCL_LIB/editor.sh"; fi
if declare -F md_load >/dev/null; then md_load; fi
logger() { :; }
systemctl() { echo "blocked: systemctl $*" >>"$HOME/stub.log"; return 1; }
systemd-run() { echo "blocked: systemd-run $*" >>"$HOME/stub.log"; return 1; }
openrgb() { echo "blocked: openrgb" >&2; return 1; }
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
lianli_lights() { echo "lianli_lights $*" >>"$HOME/stub.log"; }
apply_openrgb() { echo "apply_openrgb" >>"$HOME/stub.log"; }
ed_queue_pick() { echo "pick $1" >>"$HOME/stub.log"; echo '{"queued": true, "unit": "pc-lights-ui-pick-test"}'; }
preview_live() { return 1; }
media_probe_json() {
  local b=${1##*/}
  case $b in
    fan-a.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":12,"fps":24,"size":2929166}' ;;
    fan-b.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":12,"fps":24,"size":2871203}' ;;
    fan-c.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":12,"fps":24,"size":3010442}' ;;
    fan-d.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":12,"fps":24,"size":2790518}' ;;
    fan-e.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":12,"fps":24,"size":2954873}' ;;
    pump.mp4) echo '{"kind":"video","w":2288,"h":1080,"dw":2288,"dh":1080,"duration":12,"fps":24,"size":11697230}' ;;
    pump-2.mp4) echo '{"kind":"video","w":2288,"h":1080,"dw":2288,"dh":1080,"duration":10,"fps":24,"size":9876543}' ;;
    planet37-*.mp4) echo '{"kind":"video","w":400,"h":400,"dw":400,"dh":400,"duration":42,"fps":30,"size":3100000}' ;;
    wide-*.mp4) echo '{"kind":"video","w":1920,"h":1080,"dw":1920,"dh":1080,"duration":400,"fps":30,"size":600000000}' ;;
    tiny-*.png) echo '{"kind":"image","w":64,"h":64,"dw":64,"dh":64,"duration":null,"fps":null,"size":900}' ;;
  esac
}
media_probe_many() { local p; for p in "$@"; do media_probe_json "$p" | head -n1 | grep . || echo null; done; }
media_thumb() { local p k; for p in "$@"; do k=$(printf '%s' "${p##*/}" | sha1sum | cut -c1-40); echo "$CACHE/thumbs/${k:0:2}/$k.webp"; done; }
media_job_file() { echo "$CACHE/media/jobs/$1.json"; }
media_cancel_job() {
  echo "cancel $1" >>"$HOME/stub.log"
  local f=$CACHE/media/jobs/$1.json
  if [[ -f $f ]]; then jq '.state = "cancelled"' "$f" >"$f.tmp" && mv "$f.tmp" "$f"; fi
}
if [[ -f $HOME/kill-at-install ]]; then ed_install() { rm -f "$HOME/kill-at-install"; kill -9 $$; }; fi
if [[ -n ${T_CALL:-} ]]; then eval "$T_CALL"; exit $?; fi
if [[ ${1:-} == theme && ${2:-} != preview ]]; then shift; editor_cmd "$@"; exit $?; fi
EOF
s2() { env HOME="$H2" TMPDIR="$S2/tmp" PCL_TEST_OVERRIDES="$S2/over.sh" "$PCL" "$@"; }
t2() { s2 theme "$@"; }
c2() { T_CALL=$1 s2 status; }
job2() {   # job2 <id> <state> <role> <model> [output rel] [then]: a job record
  jq -n --arg id "$1" --arg st "$2" --arg role "$3" --arg m "$4" --arg rel "${5:-}" --arg "then" "${6:-set}" \
    --arg abs "$C2/drafts/${DRAFT:-sakura-2}.media/${5:-}" --arg d "${DRAFT:-sakura-2}" '
    {v: 1, id: $id, kind: "prepare", state: $st, draft: $d, role: $role, model: $m, then: $then, at: null,
     source: {path: "/home/you/Videos/src.mp4"}, recipe: {v: 1, mode: "encode", key: "k-\($id)"},
     progress: {frac: 0.42}, output: (if $rel == "" then null else {rel: $rel, abs: $abs, bytes: 100, reused: false} end),
     error: null, applied: null}' >"$K2/media/jobs/$1.json"
}
thumbs2() { local f k; for f in "$@"; do k=$(printf '%s' "$f" | sha1sum | cut -c1-40); mkdir -p "$K2/thumbs/${k:0:2}"; echo webp >"$K2/thumbs/${k:0:2}/$k.webp"; done; }
thumbs2 fan-a.mp4 fan-b.mp4 fan-c.mp4 fan-d.mp4 fan-e.mp4 pump.mp4 pump-2.mp4 planet37-3fa9c2d1.mp4
sums_before=$(cd "$TD2" && sha256sum ./*/theme.json)

# -- the saved theme (no draft)
run t2 screens sakura --json
rcis "theme screens sakura (saved): exit 0" 0
jc "saved screens view: v1, not a draft, rev 0, sig, editable, 7 roles in profile order" '.v == 1 and .draft == false and .rev == 0 and .mode == "saved"
  and (.sig | test("^[0-9a-f]{16}$")) and .editable and ([.screens[].role] == ["screen.fan1", "screen.fan2", "screen.fan3", "screen.fan4", "screen.fan5", "screen.pump", "screen.main"])'
jc "map: fans.top row on top, fans.side column right, map order" '.map.order == ["screen.fan4", "screen.fan5", "screen.pump", "screen.fan1", "screen.fan2", "screen.fan3", "screen.main"]
  and .map.groups == [{group: "fans.top", label: "2-fan LCD group", place: "top", axis: "row", roles: ["screen.fan4", "screen.fan5"]},
                      {group: "fans.side", label: "Right 3-fan LCD column", place: "right", axis: "column", roles: ["screen.fan1", "screen.fan2", "screen.fan3"]}]'
jc "place hints: pump centre, main bottom and wide, fans by group; index/of in the group" '
  (.screens | map({key: .role, value: [.place, .wide, .index, .of]}) | from_entries) as $x
  | $x["screen.pump"] == ["centre", false, null, null] and $x["screen.main"] == ["bottom", true, null, null]
    and $x["screen.fan1"] == ["right", false, 0, 3] and $x["screen.fan5"] == ["top", false, 1, 2]'
jc "targets: the fan list by index, pump and main their own entry; nothing shared" '
  ([.screens[:5][] | .target] == [range(0; 5) as $i | {kind: "list", key: "screen.fan", index: $i, path: "/screens/screen.fan/\($i)", expand: []}])
  and (.screens[5].target == {kind: "role", key: "screen.pump", index: null, path: "/screens/screen.pump", expand: []})
  and all(.screens[]; .shared_with == [] and .changed == false)'
jc "orientation: model + mount (fans 1-3 at 180, the pump and 8.8\" at 90)" '[.screens[].orientation] == [180, 180, 180, 0, 0, 90, 90]'
jc "pump: folder-form clips expanded, rotate 300" '.screens[5].clips == {rotate: 300, shuffle: false, folder_form: true, max: 64,
  items: [{i: 0, rel: "media/pump.mp4", from: "path", where: "root", title: "pump", thumb: .screens[5].clips.items[0].thumb, thumb_state: "ready", duration: 12},
          {i: 1, rel: "media/pump/pump-2.mp4", from: "folder", where: "root", title: "pump 2", thumb: .screens[5].clips.items[1].thumb, thumb_state: "ready", duration: 10}]}'
jc "main: the template (installed, preview art), modes template|media; no media" '.screens[6] | .template.id == "us88-sakura" and .template.rel == "us88/us88-sakura.template.json"
  and .template.installed and (.template.thumb | endswith("/sakura/src/preview-us88.jpg")) and .modes == {current: "template", can: ["template", "media"]} and .media == null'
jc "media: where root, probe, exact fit, thumb ready; brightness via the role alias" '.screens[0] | .media.where == "root" and .media.probe == {kind: "video", w: 400, h: 400, duration: 12, fps: 24, bytes: 2929166}
  and .media.fit.state == "exact" and .media.thumb_state == "ready" and .brightness == {path: "/screens/@screen.fan1/brightness", value: null, effective: 100}'
jc "coverage full, limits, no problems" '.coverage == {summary: "full", missing: []} and .limits.rotate == [30, 86400] and .limits.rotate_choices == [60, 300, 900, 3600] and .problems == []'
exec 9>"$K2/lock"; flock 9
t0=$(date +%s%N); run t2 screens sakura --json; t1=$(( ($(date +%s%N) - t0) / 1000000 ))
exec 9>&-
rcis "theme screens is lock-free (the main lock held): exit 0 in ${t1} ms" 0
run t2 screens sakura
if [[ $rc == 0 && $out == *"Pump [theme]: video media/pump.mp4 (root), 2 clips every 300 s"* ]]; then ok "theme screens (text)"; else bad "theme screens (text)" "$out"; fi
run t2 screens nope --json; rcis "theme screens of an unknown theme: 2 not-found" 2 not-found

# -- the frozen fixture (tests/fixtures/screens.sakura.json): a duplicate
# whose fan 3 took a prepared clip, with the pump waiting for another
run t2 duplicate sakura sakura-2 --json
rcis "duplicate sakura sakura-2" 0
st2=$(c2 'editor_draft_stage sakura-2 --create')
if [[ $st2 == "$C2/drafts/sakura-2.media" && -d $st2/media && $(stat -c %a "$st2") == 700 ]]; then ok "editor_draft_stage --create: drafts/<name>.media, 0700"
else bad "editor_draft_stage --create" "$st2 $(stat -c %a "$st2" 2>&1)"; fi
check "editor_draft_stage --create without a draft: 1" bash -c "! T_CALL='editor_draft_stage nodraft --create' $(printf '%q ' env HOME="$H2" TMPDIR="$S2/tmp" PCL_TEST_OVERRIDES="$S2/over.sh" "$PCL") status"
printf 'x%.0s' {1..100} >"$st2/media/planet37-3fa9c2d1.mp4"
echo "staged fan-a" >"$st2/media/fan-a.mp4"
out=$(c2 'editor_draft_abspath sakura-2 media/fan-a.mp4 && editor_draft_abspath sakura-2 media/fan-b.mp4 && editor_draft_abspath sakura-2 media/pump && { editor_draft_abspath sakura-2 media/nope.mp4 || echo "rc=$?"; }')
if [[ $out == "$st2/media/fan-a.mp4"$'\n'"$TD2/sakura/media/fan-b.mp4"$'\n'"$TD2/sakura/media/pump"$'\n'"rc=1" ]]; then ok "editor_draft_abspath: the stage first, then the media root; folders too; 1 when missing"
else bad "editor_draft_abspath" "$out"; fi
rm -f "$st2/media/fan-a.mp4"
job2 j-1790000300000-1111 "done" screen.fan3 TlFlexLcd media/planet37-3fa9c2d1.mp4
run t2 media set sakura-2 screen.fan3 j-1790000300000-1111 --json
rcis "theme media set <role> j-<job>: exit 0" 0
jc "media set: the editor view + notes; rev 2; the list entry replaced, model the role's family" '.rev == 2 and .notes == []
  and .theme.screens["screen.fan"][2] == {type: "video", path: "media/planet37-3fa9c2d1.mp4", model: "TlFlexLcd"}'
jc "media set from a job: media_sources records where it came from" \
  '.media_sources["media/planet37-3fa9c2d1.mp4"] | .source == "/home/you/Videos/src.mp4" and .model == "TlFlexLcd" and .recipe.mode == "encode" and (.at | type == "number")' \
  "$(cat "$C2/drafts/sakura-2.json")"
job2 j-1790000400123-4821 encoding screen.pump HydroShift2OledCurveLcd "" clip-add
out=$(c2 'editor_media_pending sakura-2 screen.pump j-1790000400123-4821 && echo rc=0 || echo "rc=$?"')
check "editor_media_pending: noted, nothing replaced" test "$out" = "rc=0"
jq '.rev = 14' "$C2/drafts/sakura-2.json" >"$S2/d.json" && mv "$S2/d.json" "$C2/drafts/sakura-2.json"
run t2 screens sakura-2 --json
jq --arg h "$H2" '(.. | strings) |= sub($h; "/home/you") | .disk.free_bytes = 3400000000000 | .disk.stage_bytes = 3100000' <<<"$out" >"$S2/view.json"
if diff <(jq -S . "$S2/view.json") <(jq -S . "$FX/screens.sakura.json") >"$S2/d"; then ok "engine screens view == the frozen fixture (bar \$HOME, disk)"
else bad "engine screens view == the frozen fixture" "$(head -40 "$S2/d")"; fi
jc "the editor view's screens: editable, the same sig as the screens view" ".screens.editable and .screens.sig == \"$(jq -r .sig "$S2/view.json")\"" "$(t2 show sakura-2 --json)"
jq '.rev = 3' "$C2/drafts/sakura-2.json" >"$S2/d.json" && mv "$S2/d.json" "$C2/drafts/sakura-2.json"
out=$(c2 'editor_media_pending sakura-2 screen.pump j-2 && echo rc=0 || echo "rc=$?"')
check "editor_media_pending: a newer job prints the one it replaced" test "$out" = $'j-1790000400123-4821\nrc=0'
out=$(c2 'editor_media_pending sakura-2 screen.pump "" j-other && editor_media_pending sakura-2 screen.pump "" j-2 && echo rc=0 || echo "rc=$?"')
jc "editor_media_pending <role> \"\" <only-if>: cleared only when it is that job" '.pending_media == null' "$(cat "$C2/drafts/sakura-2.json")"
check "editor_media_pending without a draft: 1" bash -c "! T_CALL='editor_media_pending nodraft screen.pump j-1' $(printf '%q ' env HOME="$H2" TMPDIR="$S2/tmp" PCL_TEST_OVERRIDES="$S2/over.sh" "$PCL") status"

# -- editor_media_apply (B1's runner calls it under its job)
printf 'clip' >"$st2/media/rain-0badc0de.mp4"
job2 j-1790000500000-2222 finishing screen.pump HydroShift2OledCurveLcd media/rain-0badc0de.mp4 clip-add
jq '.at = 1' "$K2/media/jobs/j-1790000500000-2222.json" >"$S2/j" && mv "$S2/j" "$K2/media/jobs/j-1790000500000-2222.json"
c2 'editor_media_pending sakura-2 screen.pump j-1790000500000-2222' >/dev/null
rev0=$(jq .rev "$C2/drafts/sakura-2.json")
out=$(c2 'editor_media_apply sakura-2 "$CACHE/media/jobs/j-1790000500000-2222.json" && echo rc=0 || echo "rc=$?"')
if [[ $out == "$((rev0 + 1))"$'\nrc=0' ]]; then ok "editor_media_apply clip-add: 0, the new rev on stdout"; else bad "editor_media_apply clip-add" "$out"; fi
jc "clip-add --at 1: the list written out as files, the wait over" '.theme.screens["screen.pump"] | .path == "media/pump.mp4"
  and .clips == ["media/rain-0badc0de.mp4", "media/pump/pump-2.mp4"] and .rotate == 300' "$(cat "$C2/drafts/sakura-2.json")"
jc "... pending_media cleared, media_sources noted" '(.pending_media == null) and (.media_sources | has("media/rain-0badc0de.mp4"))' "$(cat "$C2/drafts/sakura-2.json")"
c2 'editor_media_pending sakura-2 screen.pump j-newer' >/dev/null
out=$(c2 'editor_media_apply sakura-2 "$CACHE/media/jobs/j-1790000500000-2222.json" 2>/dev/null && echo rc=0 || echo "rc=$?"')
check "editor_media_apply of a superseded job: 1, nothing changed" test "$out" = "rc=1"
job2 j-1790000500000-3333 finishing screen.pump HydroShift2OledCurveLcd media/rain-0badc0de.mp4 none
c2 'editor_media_pending sakura-2 screen.pump j-1790000500000-3333' >/dev/null
out=$(c2 'editor_media_apply sakura-2 "$CACHE/media/jobs/j-1790000500000-3333.json" && echo rc=0 || echo "rc=$?"')
jc "editor_media_apply then=none: 0, the wait ends, the theme unchanged" '.pending_media == null' "$(cat "$C2/drafts/sakura-2.json")"
out=$(c2 'editor_media_apply nodraft "$CACHE/media/jobs/j-1790000500000-3333.json" && echo rc=0 || echo "rc=$?"')
check "editor_media_apply without a draft: 1" test "$out" = "rc=1"

# -- theme media set: refusals, none, a picture into a rotation, stale-rev, --all-fans
job2 j-1790000600000-4444 "done" screen.pump HydroShift2OledCurveLcd media/rain-0badc0de.mp4
run t2 media set sakura-2 screen.fan1 j-1790000600000-4444 --json
rcis "a pump clip on a fan: 2 unfit" 2 unfit
printf 'w' >"$st2/media/wide-11112222.mp4"
run t2 media set sakura-2 screen.fan1 media/wide-11112222.mp4 --json
rcis "a 16:9 video on a square fan (probed shape): 2 unfit" 2 unfit
run t2 media set sakura-2 screen.fan1 none --json
rcis "none on a shared fan list: 2 invalid" 2 invalid
run t2 media set sakura-2 screen.fan1 media/nope.mp4 --json
rcis "a path that doesn't resolve: 2 not-found" 2 not-found
run t2 media set sakura-2 screen.fan1 j-nosuch-1 --json
rcis "an unknown job: 2 not-found" 2 not-found
run t2 media set sakura-2 screen.fan1 "$TD2/sakura/media/fan-b.mp4" --json
rcis "an absolute path (a file outside the theme): 2 usage" 2 usage
run t2 media set sakura-2 screen.fan1 media/../../glacier/theme.json --json
rcis "a path climbing out of the theme: 2 usage" 2 usage
job2 j-1790000600000-5555 encoding screen.fan1 TlFlexLcd media/planet37-3fa9c2d1.mp4
run t2 media set sakura-2 screen.fan1 j-1790000600000-5555 --json
rcis "a job still running: 2 media-pending" 2 media-pending
run t2 media set sakura-2 screen.fan9 media/fan-b.mp4 --json
rcis "a role the profile doesn't have: 2 no-role" 2 no-role
rev=$(jq .rev "$C2/drafts/sakura-2.json")
run t2 media set sakura-2 screen.fan1 media/fan-b.mp4 --base-rev $((rev - 1)) --json
rcis "media set with a stale --base-rev: 2 stale-rev" 2 stale-rev
printf 'p' >"$st2/media/still-12345678.png"
c2 'editor_media_pending sakura-2 screen.pump j-1790000400123-4821' >/dev/null
jq '.state = "encoding"' "$K2/media/jobs/j-1790000400123-4821.json" >"$S2/j" && mv "$S2/j" "$K2/media/jobs/j-1790000400123-4821.json"
: >"$H2/stub.log"
run t2 media set sakura-2 screen.pump media/still-12345678.png --base-rev "$rev" --with-screens --json
rcis "a picture on the rotating pump: exit 0" 0
jc "... the rotation ends with a note; brightness and model kept" '.notes == ["Rotation turned off: pictures can'"'"'t take turns."]
  and .theme.screens["screen.pump"] == {type: "image", path: "media/still-12345678.png", model: "HydroShift2OledCurveLcd"}'
jc "--with-screens: the screens view rides along" '.screens_view.v == 1 and (.screens_view.screens[5].media.type == "image") and .screens_view.screens[5].clips == null'
check "set stops the role's other pending job" grep -q '^cancel j-1790000400123-4821$' "$H2/stub.log"
run t2 media set sakura-2 screen.pump none --json
jc "none on the pump's own entry: removed" '.theme.screens | has("screen.pump") | not'
run t2 media set sakura-2 screen.pump none --json
jc "none again: no change, a note, same rev" '.notes == ["screen.pump shows nothing from this theme already."] and .rev == '"$(jq .rev "$C2/drafts/sakura-2.json")"
run t2 media set sakura-2 screen.fan2 media/fan-e.mp4 --all-fans --json
jc "--all-fans: one entry dealt to every fan, the screen.fanN overrides gone" '.theme.screens["screen.fan"] == [{type: "video", path: "media/fan-e.mp4", model: "TlFlexLcd"}]
  and ([.theme.screens | keys[] | select(test("^screen\\.fan[0-9]"))] == []) and (.notes | index("Every fan screen shows it now.") != null)'
run t2 media set sakura-2 screen.pump media/fan-e.mp4 --all-fans --json
rcis "--all-fans on the pump: 2 usage" 2 usage

# -- where an edit goes: expansion, shared entries, model entries, overrides
t2 set sakura-2 --patch-json '[{"op":"replace","path":"/screens/screen.fan","value":[{"type":"video","path":"media/fan-a.mp4","model":"TlFlexLcd"},{"type":"video","path":"media/fan-b.mp4","model":"TlFlexLcd"}]},{"op":"add","path":"/screens/screen.fan5","value":{"type":"video","path":"media/fan-e.mp4","model":"TlFlexLcd"}}]' >/dev/null
run t2 screens sakura-2 --json
jc "a 2-entry fan list: dealt 0,1,0,1; expand deals it out to 5; shared_with names the others" '
  (.screens[0] | .target.expand == [{op: "replace", path: "/screens/screen.fan", value: [{type: "video", path: "media/fan-a.mp4", model: "TlFlexLcd"},
      {type: "video", path: "media/fan-b.mp4", model: "TlFlexLcd"}, {type: "video", path: "media/fan-a.mp4", model: "TlFlexLcd"},
      {type: "video", path: "media/fan-b.mp4", model: "TlFlexLcd"}, {type: "video", path: "media/fan-a.mp4", model: "TlFlexLcd"}]}]
    and .shared_with == ["screen.fan3"])
  and .screens[1].shared_with == ["screen.fan4"] and .screens[3].entry.path == "media/fan-b.mp4"'
jc "a role override wins over the list: its own target, nothing shared" '.screens[4] | .target.kind == "role" and .target.path == "/screens/screen.fan5" and .shared_with == [] and .entry.path == "media/fan-e.mp4"'
run t2 set sakura-2 /screens/@screen.fan3/brightness 30 --json
jc "@role brightness on a short list: dealt out first, then the field" '.theme.screens["screen.fan"] | length == 5 and .[2] == {type: "video", path: "media/fan-a.mp4", model: "TlFlexLcd", brightness: 30}
  and .[0].brightness == null and .[4].brightness == null'
run t2 set sakura-2 /screens/@screen.fan4/brightness 60 /screens/@screen.fan4/brightness 61 --json
jc "@role again: no second expansion (idempotent)" '.theme.screens["screen.fan"] | length == 5 and .[3].brightness == 61 and .[2].brightness == 30'
run t2 set sakura-2 /screens/@screen.fan3/brightness 140 --json
rcis "@role brightness 140: set, like any value" 0
jc "... and the range problem comes back with its pointer" '[.problems[] | .path] | index("/screens/screen.fan/2/brightness") != null'
run t2 set sakura-2 /screens/@screen.fan3/brightness null --json
jc "@role null: the field removed" '.theme.screens["screen.fan"][2] | has("brightness") | not'
run t2 set sakura-2 /screens/@screen.fan9/brightness 40 --json; rcis "@role of an unknown role: 2 no-role" 2 no-role
run t2 set sakura-2 /screens/@screen.fan1/path '"x.mp4"' --json; rcis "@role of a field without an alias: 2 invalid" 2 invalid
run t2 set sakura-2 /screens/@screen.pump/brightness 50 --json; rcis "@role on a screen showing nothing from the theme: 2 invalid" 2 invalid
t2 set sakura-2 --patch-json '[{"op":"replace","path":"/screens/screen.fan","value":{"type":"video","path":"media/fan-c.mp4","model":"TlFlexLcd"}},{"op":"remove","path":"/screens/screen.fan5"},{"op":"add","path":"/screens/model:HydroShift2OledCurveLcd","value":[{"type":"video","path":"media/pump.mp4"}]}]' >/dev/null
run t2 screens sakura-2 --json
jc "an object shared by every fan: create, its copy first" '.screens[1] | .target == {kind: "create", key: "screen.fan2", index: null, path: "/screens/screen.fan2",
  expand: [{op: "add", path: "/screens/screen.fan2", value: {type: "video", path: "media/fan-c.mp4", model: "TlFlexLcd"}}]}
  and .shared_with == ["screen.fan1", "screen.fan3", "screen.fan4", "screen.fan5"]'
jc "a model list reaches the pump: source model, target list model:<Family>/0" '.screens[5] | .source == "model" and .target.kind == "list" and .target.path == "/screens/model:HydroShift2OledCurveLcd/0"'
run t2 set sakura-2 /screens/@screen.fan2/brightness 20 --json
jc "@role on a shared object: a per-role copy with the field, the shared one untouched" '.theme.screens["screen.fan2"] == {type: "video", path: "media/fan-c.mp4", model: "TlFlexLcd", brightness: 20}
  and .theme.screens["screen.fan"] == {type: "video", path: "media/fan-c.mp4", model: "TlFlexLcd"}'
run t2 media set sakura-2 screen.fan3 none --json; rcis "none on a shared object: 2 invalid" 2 invalid
jq '.roles["screen.fan5"].managed = false' "$C2/profile.json" >"$S2/p.json" && cp "$C2/profile.json" "$S2/profile.keep" && mv "$S2/p.json" "$C2/profile.json"
run t2 screens sakura-2 --json
jc "an unmanaged screen: source unmanaged, no target, no entry" '.screens[4] | .managed == false and .source == "unmanaged" and .target == null and .entry == null and .changed == false'
mv "$S2/profile.keep" "$C2/profile.json"

# -- clips, rotate, shuffle (canonical forms)
t2 set sakura-2 --patch-json '[{"op":"replace","path":"/screens/screen.pump","value":{"type":"video","path":"media/pump.mp4","clips":["media/pump"],"rotate":300,"model":"HydroShift2OledCurveLcd"}}]' >/dev/null
run t2 media clips sakura-2 screen.pump add media/rain-0badc0de.mp4 --json
jc "clips add: appended; the folder written out as its files" '.theme.screens["screen.pump"] | .path == "media/pump.mp4" and .clips == ["media/pump/pump-2.mp4", "media/rain-0badc0de.mp4"]'
run t2 media clips sakura-2 screen.pump move 2 0 --json
jc "clips move 2 0: the moved clip becomes path" '.theme.screens["screen.pump"] | .path == "media/rain-0badc0de.mp4" and .clips == ["media/pump.mp4", "media/pump/pump-2.mp4"]'
run t2 media clips sakura-2 screen.pump order 1,2,0 --json
jc "clips order 1,2,0" '.theme.screens["screen.pump"] | .path == "media/pump.mp4" and .clips == ["media/pump/pump-2.mp4", "media/rain-0badc0de.mp4"]'
run t2 media clips sakura-2 screen.pump order 1,1,0 --json; rcis "clips order that isn't a permutation: 2 usage" 2 usage
run t2 media clips sakura-2 screen.pump remove 7 --json; rcis "clips remove out of range: 2 usage" 2 usage
run t2 media clips sakura-2 screen.pump add media/still-12345678.png --json; rcis "clips add a picture: 2 invalid" 2 invalid
run t2 media rotate sakura-2 screen.pump 60 --shuffle on --json
jc "rotate 60 --shuffle on" '.theme.screens["screen.pump"] | .rotate == 60 and .shuffle == true'
run t2 media rotate sakura-2 screen.pump 20 --json; rcis "rotate below 30 s: 2 usage" 2 usage
run t2 media rotate sakura-2 screen.pump 86401 --json; rcis "rotate above a day: 2 usage" 2 usage
run t2 media rotate sakura-2 screen.pump off --shuffle off --json
jc "rotate off --shuffle off: the list kept" '.theme.screens["screen.pump"] | (has("rotate") | not) and (has("shuffle") | not) and (.clips | length) == 2'
t2 media rotate sakura-2 screen.pump 300 --shuffle on >/dev/null
t2 media clips sakura-2 screen.pump remove 2 >/dev/null
run t2 media clips sakura-2 screen.pump remove 0 --json
jc "one clip left: no clips, no rotate, shuffle kept (true), a note" '.theme.screens["screen.pump"] == {type: "video", path: "media/pump/pump-2.mp4", model: "HydroShift2OledCurveLcd", shuffle: true}
  and .notes == ["One clip left: it plays on its own."]'
run t2 media clips sakura-2 screen.pump remove 0 --json; rcis "removing the only clip: 2 invalid" 2 invalid
run t2 media rotate sakura-2 screen.pump 60 --json
jc "rotate on one clip: kept, with a note" '.theme.screens["screen.pump"].rotate == 60 and .notes == ["Add another clip to take turns."]'

# -- the 8.8": template <-> a picture or video
run t2 media mode sakura-2 screen.main media --json; rcis "mode media with nothing to show: 2 invalid" 2 invalid
printf 's' >"$st2/media/strip-aaaaaaaa.mp4"
run t2 media mode sakura-2 screen.main media media/strip-aaaaaaaa.mp4 --json
jc "mode media <src>: the video, the template id kept in _prev, templates[] kept" '.theme.screens["screen.main"] == {type: "video", model: "UniversalScreen", path: "media/strip-aaaaaaaa.mp4", _prev: {template_id: "us88-sakura"}}
  and .theme.templates == ["us88/us88-sakura.template.json"]'
run t2 screens sakura-2 --json
jc "view: modes current media, the template still offered, _prev media kept by save" '.screens[6] | .modes == {current: "media", can: ["template", "media"]} and .template.id == "us88-sakura" and .media.rel == "media/strip-aaaaaaaa.mp4"'
run t2 media mode sakura-2 screen.main template --json
jc "mode template: custom again, the media kept in _prev" '.theme.screens["screen.main"] == {type: "custom", model: "UniversalScreen", _prev: {type: "video", path: "media/strip-aaaaaaaa.mp4"}, template_id: "us88-sakura"}'
run t2 media mode sakura-2 screen.main media --json
jc "mode media: back from _prev" '.theme.screens["screen.main"] | .type == "video" and .path == "media/strip-aaaaaaaa.mp4" and ._prev == {template_id: "us88-sakura"} and (has("template_id") | not)'
run t2 media mode sakura-2 screen.fan1 template --json; rcis "mode on a fan screen: 2 invalid" 2 invalid
jc "the draft validates (staged media through the shadow)" '.problems == []' "$(t2 show sakura-2 --json)"

# -- save: staged media into the new folder, deduped, provenance first
t2 media clips sakura-2 screen.pump add j-1790000600000-4444 >/dev/null
jq '.theme.screens["screen.fan1"] = {type: "video", path: "media/dup-99999999.mp4", model: "TlFlexLcd"}' "$C2/drafts/sakura-2.json" >"$S2/d.json" && mv "$S2/d.json" "$C2/drafts/sakura-2.json"
echo "sakura fan-b" >"$st2/media/dup-99999999.mp4"
cp -p "$TD2/sakura/src/media.json" "$S2/sakura-media.json.before"
ino_strip=$(stat -c %i "$st2/media/strip-aaaaaaaa.mp4")
job2 j-1790000700000-6666 encoding screen.fan2 TlFlexLcd
c2 'editor_media_pending sakura-2 screen.fan2 j-1790000700000-6666' >/dev/null
run t2 save sakura-2 --json
rcis "save while media is being prepared: 2 media-pending" 2 media-pending
check "... nothing saved" test ! -e "$TD2/sakura-2"
: >"$H2/stub.log"
run t2 save sakura-2 --force --json
rcis "save --force: exit 0" 0
check "... and the running job is stopped" grep -q '^cancel j-1790000700000-6666$' "$H2/stub.log"
check "the staged video is in the new theme, the same inode as staged" test "$(stat -c %i "$TD2/sakura-2/media/strip-aaaaaaaa.mp4" 2>/dev/null)" = "$ino_strip"
jc "staged files already in the theme (same bytes) are not linked: the reference moves" '.screens["screen.fan1"].path == "media/fan-b.mp4"' "$(cat "$TD2/sakura-2/theme.json")"
check "... no copy of it" test ! -e "$TD2/sakura-2/media/dup-99999999.mp4"
jc "src/media.json: the new files with their provenance, the source theme's entries kept" '.v == 1 and (.files | has("media/strip-aaaaaaaa.mp4") and has("media/rain-0badc0de.mp4") and has("media/pump.mp4"))
  and .files["media/rain-0badc0de.mp4"].model == "HydroShift2OledCurveLcd" and (.files["media/rain-0badc0de.mp4"].prepared | type == "number")' "$(cat "$TD2/sakura-2/src/media.json")"
check "the source theme's src/media.json keeps its bytes (a hard-linked copy is replaced, never written)" cmp -s "$S2/sakura-media.json.before" "$TD2/sakura/src/media.json"
check "the draft is gone, and so are the staged copies nothing needs any more (media_gc_draft)" test ! -e "$C2/drafts/sakura-2.json" -a ! -e "$st2/media/strip-aaaaaaaa.mp4"
if s2 status >/dev/null 2>&1 && T_CALL='validate_theme sakura-2 && echo VALID' s2 status 2>&1 | grep -q VALID; then ok "the saved theme validates (every file in its own folder)"
else bad "the saved theme validates" "$(T_CALL='validate_theme sakura-2' s2 status 2>&1 | tail -3)"; fi

# -- edit + save an existing theme: new inode, twins, a kill between the links and theme.json
DRAFT=sakura
t2 edit sakura --json >/dev/null
st3=$(c2 'editor_draft_stage sakura --create')
printf 'moon' >"$st3/media/moon-1234abcd.mp4"
t2 media set sakura screen.fan3 media/moon-1234abcd.mp4 >/dev/null
mkdir -p "$S2/twin"; ln "$TD2/sakura/theme.json" "$S2/twin/theme.json"
old_ino=$(stat -c %i "$TD2/sakura/theme.json") old_sha=$(sha "$TD2/sakura/theme.json")
touch "$H2/kill-at-install"
s2 theme save sakura --no-apply --json >/dev/null 2>&1 || true
check "killed between the links and theme.json: theme.json untouched" test "$(sha "$TD2/sakura/theme.json")" = "$old_sha"
check "... the linked file is there and recorded in src/media.json (the GC knows it is the editor's)" \
  bash -c "[[ -f '$TD2/sakura/media/moon-1234abcd.mp4' ]] && jq -e '.files[\"media/moon-1234abcd.mp4\"]' '$TD2/sakura/src/media.json' >/dev/null"
check "... the draft and its staged file are kept" test -f "$C2/drafts/sakura.json" -a -f "$st3/media/moon-1234abcd.mp4"
run t2 save sakura --no-apply --json
rcis "the save again: exit 0" 0
check "theme.json is a new inode; its hard-linked twin keeps the old bytes" bash -c "[[ \$(stat -c %i '$TD2/sakura/theme.json') != '$old_ino' && \$(sha256sum <'$S2/twin/theme.json' | cut -c1-64) == '$old_sha' ]]"
jc "the saved theme names the new clip" '.screens["screen.fan"][2].path == "media/moon-1234abcd.mp4"' "$(cat "$TD2/sakura/theme.json")"
check "the new clip was linked once (no -2 copy)" test ! -e "$TD2/sakura/media/moon-1234abcd-2.mp4"

# -- discard, rename, delete take the stage along (never what the daemon shows)
DRAFT=sakura-6
t2 duplicate sakura sakura-6 >/dev/null
st6=$(c2 'editor_draft_stage sakura-6 --create'); printf 'shown' >"$st6/media/shown-56565656.mp4"
jq -n --arg p "$st6/media/shown-56565656.mp4" '{rgb: {devices: []}, lcds: [{serial: "hid:1cbe:a018:8-12.2.1", type: "video", path: $p, orientation: 180}]}' \
  >"$H2/.config/lianli/config.json"
t2 discard sakura-6 >/dev/null
check "GC keeps a staged file the daemon config shows (a preview)" test -f "$st6/media/shown-56565656.mp4"
rm -f "$H2/.config/lianli/config.json"
c2 'ed_gc_draft sakura-6' >/dev/null
check "... and removes it once nothing shows it" test ! -e "$st6/media/shown-56565656.mp4"
DRAFT=sakura-4
t2 duplicate sakura sakura-4 >/dev/null
st4=$(c2 'editor_draft_stage sakura-4 --create'); printf 'q' >"$st4/media/q-12121212.mp4"
job2 j-1790000800000-7777 encoding screen.fan1 TlFlexLcd media/q-12121212.mp4
c2 'editor_media_pending sakura-4 screen.fan1 j-1790000800000-7777' >/dev/null
: >"$H2/stub.log"
run t2 discard sakura-4 --json
check "discard: the draft's jobs stop, its stage goes" bash -c "grep -q '^cancel j-1790000800000-7777\$' '$H2/stub.log' && [[ ! -e '$st4' ]]"
t2 duplicate sakura sakura-5 >/dev/null; t2 save sakura-5 >/dev/null 2>&1
t2 edit sakura-5 >/dev/null
st5=$(c2 'editor_draft_stage sakura-5 --create'); printf 'r' >"$st5/media/r-34343434.mp4"
DRAFT=sakura-5 job2 j-1790000800000-8888 encoding screen.fan1 TlFlexLcd media/r-34343434.mp4
st5b=$(c2 'editor_draft_stage sakura-5')
t2 edit sakura-5 --fresh >/dev/null
if [[ $(c2 'declare -F media_gc_draft >/dev/null && echo b1' 2>/dev/null) == b1 ]]; then
  check "edit --fresh: the old draft's staged media goes (media_gc_draft)" test ! -e "$st5b/media/r-34343434.mp4"
else ok "edit --fresh: (no media.sh: its stage waits for the draft to go)"; fi
st5=$(c2 'editor_draft_stage sakura-5 --create'); printf 'r' >"$st5/media/r-34343434.mp4"
run t2 rename sakura-5 blossom --json
rcis "rename a theme with a draft and staged media: exit 0" 0
check "rename: the stage moves with the draft" test -f "$C2/drafts/blossom.media/media/r-34343434.mp4" -a ! -e "$st5"
jc "rename: the job record follows (draft, output path)" '.draft == "blossom" and (.output.abs | startswith("'"$C2/drafts/blossom.media/"'"))' "$(cat "$K2/media/jobs/j-1790000800000-8888.json")"
check "rename: the draft resolves its staged file under the new name" test "$(c2 'editor_draft_abspath blossom media/r-34343434.mp4')" = "$C2/drafts/blossom.media/media/r-34343434.mp4"
run t2 delete blossom --json
check "delete: the theme to the trash, the draft and its stage gone" bash -c "[[ ! -e '$TD2/blossom' && ! -e '$C2/drafts/blossom.json' && ! -e '$C2/drafts/blossom.media' ]]"

# -- nothing but saves wrote a theme.json
sums_after=$(cd "$TD2" && sha256sum ./glacier/theme.json)
if [[ $(grep ' ./glacier/theme.json$' <<<"$sums_before") == "$sums_after" ]]; then ok "reads and draft verbs leave other themes' theme.json alone"
else bad "another theme's theme.json changed"; fi

echo "# golden profile: a v3 sakura that migrate --out built from the frozen v2 sakura"
GV2=${PCL_GOLDEN_ROOT:-$HOME/.cache/pc-lights/golden}/v2
GP=$GV2/profile.json LS=$GV2/themes-v2/sakura
if [[ -n ${PCL_EDITOR_NO_GOLDEN:-} || ! -f $GP || ! -f $LS/theme.json ]] || [[ $(jq -r '.v // 2' "$LS/theme.json") == 3 ]]; then
  echo "skip (no golden v2 capture with its frozen themes, or PCL_EDITOR_NO_GOLDEN)"
else
  G=$T/golden C2=$T/golden/.config/pc-lights
  mkdir -p "$C2/themes" "$G/.cache/pc-lights"
  cp -as "$(readlink -f "$LS")" "$C2/themes/sakura"
  rm -f "$C2/themes/sakura/theme.json"; cp -p "$LS/theme.json" "$C2/themes/sakura/theme.json"
  rm -f "$C2/themes/sakura/src/source.json"
  cp "$GP" "$C2/profile.json"; echo sakura >"$C2/scheme"; echo off >"$C2/lights"
  cat >"$T/gover.sh" <<'EOF'
source "$T_OVER"
usb_serial_map() {
  jq '[.devices[] | select(.kind == "lcd") | .match.usb_serial | select(. != null) | {(.): "hid:1cbe:0000:test"}] | add // {}' \
    "$HOME/.config/pc-lights/profile.json" >"$TMP/usbmap.json"
  echo "$TMP/usbmap.json"
}
EOF
  geng() { env HOME="$G" T_OVER="$T/over.sh" PCL_TEST_OVERRIDES="$T/gover.sh" "$PCL" "$@"; }
  if geng migrate --out "$G/v3" >"$T/gmig.log" 2>&1 && [[ $(jq -r .v "$G/v3/sakura/theme.json") == 3 ]]; then
    ok "migrate --out: v3 sakura against the golden profile"
    # The editor's HOME: the migrated folder and its seeded profile.
    rm -rf "$C2/themes"; mv "$G/v3" "$C2/themes"; mv "$C2/themes/profile.json" "$C2/profile.json"
    v3sha=$(sha "$C2/themes/sakura/theme.json")
    effa=$(T_CALL='scheme_file' geng status 2>/dev/null)
    run geng theme edit sakura --json
    if [[ $rc == 0 ]] && jq -e "$SCHEMA"' and .problems == [] and .calibration.reason == "stamped" and all(.roles[]; .form != "readonly")' >/dev/null <<<"$out"; then
      ok "edit: the §1.4 view, no problems, stamped, every role editable"
    else bad "edit the golden sakura" "rc=$rc $(jq -c '[.problems, .code, .error]' <<<"$out" 2>/dev/null)"; fi
    if [[ -z $(T_CALL='editor_draft_problems sakura' geng status 2>&1) ]]; then ok "the full validation (media under the media root, OpenRGB) passes"
    else bad "the full validation passes" "$(T_CALL='editor_draft_problems sakura' geng status 2>&1 | sed 's/[0-9a-f]\{12,\}/<id>/g' | head -5)"; fi
    effd=$(T_CALL='editor_draft_eff sakura' geng status 2>/dev/null)
    if cmp -s <(jq -S 'del(._compiled)' "$effa") <(jq -S 'del(._compiled)' "$effd"); then ok "the unedited draft compiles to the saved EFF, byte for byte"
    else bad "the unedited draft compiles to the saved EFF"; fi
    run geng theme set sakura /palette/accent ff3a8b --json
    run geng theme set sakura /palette/accent ff3a8a --json
    run geng theme save sakura --json
    rcis "save the round trip: exit 0" 0
    jq -S . "$C2/themes/sakura/theme.json" >"$T/g.after"
    if jq -S . "$(jq -r .history <<<"$out")" | cmp -s - "$T/g.after"; then ok "the round trip saves the same theme (as JSON)"
    else bad "the round trip saves the same theme"; fi
    effs=$(T_CALL='scheme_file' geng status 2>/dev/null)
    if cmp -s <(jq -S 'del(._compiled)' "$effa") <(jq -S 'del(._compiled)' "$effs"); then ok "and it compiles to the same EFF"
    else bad "and it compiles to the same EFF"; fi
    check "sha of the migrated file was the base" test -n "$v3sha"
  else
    bad "migrate --out against the golden profile" "$(grep -v '[0-9a-f]\{12\}' "$T/gmig.log" | tail -5)"
  fi
fi

echo "# $passed passed, $failed failed"
(( failed == 0 ))
