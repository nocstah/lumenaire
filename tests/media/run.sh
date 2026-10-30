#!/usr/bin/env bash
# tests/media/run.sh — the screen media pipeline (screens plan §2, §7 "B1"):
# media.jq's fit, crop and title maths; media list (library, files, theme;
# exclusions, ranking, inode dedupe, query, paging, truncation); the index
# and thumbnail lifecycle; probe; crop frames; media prepare for every kind
# of source (exact model sizes, codecs, alpha, crops in display space,
# trims and the pump estimate, remux/copy, reuse, refusals, disk and stage
# caps); jobs (then set / clip-add, cancel, supersede, progress, a draft
# that vanishes); status --json v1.3; GC's protections; the sources never
# change; and, where a user systemd runs, a job in its capped unit.
#
#   tests/media/run.sh [engine]   (default: the repo's bin/lumenaire)
#
# Everything runs in a fixture $HOME (mktemp; PCL_TEST_ROOT sets where) with
# PCL_MEDIA_INLINE=1 (jobs and the indexer run in the calling process, each
# ffmpeg/magick in its own capped scope) and PCL_TEST_OVERRIDES stubs: no
# daemon, no OpenRGB, systemd-run only for scopes and this run's own
# lumenaire-media-t<pid>-* units. The media come from make-fixtures.sh
# (PCL_MEDIA_FIXTURES=<dir> reuses a dir). The whole run takes one of
# pcl-heavy's machine-wide slots (it re-executes itself through pcl-heavy),
# and its jobs share a private slot dir, so it never waits on itself.
# KEEP_FIXTURE=1 keeps the fixture.
# shellcheck disable=SC2016 # jq filters in single quotes
# shellcheck disable=SC2015 # "cond && ok ... || bad ...": ok always returns 0
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
if [[ -z ${PCL_MEDIA_TEST_HEAVY:-} ]] && command -v pcl-heavy >/dev/null 2>&1; then
  exec env PCL_MEDIA_TEST_HEAVY=1 pcl-heavy "$0" "$@"
fi
PCL=$(readlink -f "${1:-$repo/bin/lumenaire}")
LIB=$repo/lib/pc-lights
FX=$repo/tests/fixtures
[[ -x $PCL ]] || { echo "no engine at $PCL" >&2; exit 2; }
ROOT=${PCL_TEST_ROOT:-}
if [[ -n $ROOT ]]; then mkdir -p "$ROOT"; T=$(mktemp -d -p "$ROOT" media.XXXXXX); else T=$(mktemp -d); fi
UNITP=lumenaire-media-t$$
cleanup() {
  local u p
  for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
  for u in $(systemctl --user list-units --all --plain --no-legend "$UNITP-*" 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$u" >/dev/null 2>&1 || true
  done
  if [[ -z ${KEEP_FIXTURE:-} ]]; then rm -rf "$T"; else echo "fixture kept: $T"; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
passed=0 failed=0 skipped=0

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || head -c 900 <<<"$2" | sed 's/^/     /'; echo; }
skip() { skipped=$((skipped + 1)); printf 'skip %s\n' "$1"; }
# run <cmd...>: stdout in $out, stderr in $err, exit code in $rc.
run() { rc=0; out=$("$@" 2>"$T/stderr") || rc=$?; err=$(<"$T/stderr"); }
# jc <name> <jq filter> [json]: pass when jq -e holds on $out (or the json).
jc() {
  local j=${3-$out}
  if jq -e "$2" >/dev/null 2>&1 <<<"$j"; then ok "$1"; else bad "$1" "$(jq -c "$2" <<<"$j" 2>&1 | head -c 300) :: $(head -c 600 <<<"$j") ${err:-}"; fi
}
# jcf <name> <fixture file> <jq filter>: jc on $out with the fixture as $f.
jcf() {
  if jq -e --slurpfile fx "$2" '$fx[0] as $f | '"$3" >/dev/null 2>&1 <<<"$out"; then ok "$1"
  else bad "$1" "$(head -c 600 <<<"$out")"; fi
}
rcis() {
  if [[ $rc == "$2" ]] && { [[ -z ${3:-} ]] || [[ $(jq -r .code <<<"$out" 2>/dev/null) == "$3" ]]; }; then ok "$1"
  else bad "$1" "rc=$rc out=$(head -c 400 <<<"$out") err=$(head -c 300 <<<"$err")"; fi
}
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# ---- the media (make-fixtures.sh) --------------------------------------------------
FXM=${PCL_MEDIA_FIXTURES:-$T/fx}
"$here/make-fixtures.sh" "$FXM" >/dev/null
M=$FXM

# ---- fixture HOME ------------------------------------------------------------------
H=$T/home C=$H/.config/pc-lights K=$H/.cache/pc-lights TD=$H/.config/pc-lights/themes
V=$H/Videos/lian-li P=$H/Pictures
mkdir -p "$TD/sakura/media/pump" "$TD/sakura/us88" "$TD/sakura/src" "$H/.config/lianli" "$T/slots" \
  "$V/hydroshift-ii-oled-curve/video" "$V/hydroshift-ii-oled-curve/preview" "$V/flex-lcd/video" "$V/flex-lcd/temp" \
  "$V/uploaded/hydroshift-ii-oled-curve/fullscreen" "$V/themes/deep-orange" "$H/Videos/phone" "$H/Videos/.hidden" "$P"
cp "$repo/tests/theme/sakura.v3.json" "$TD/sakura/theme.json"
cp "$FX/profile.example-desktop.json" "$C/profile.json"
for f in fan-a fan-b fan-c fan-d fan-e; do cp "$M/sq.mp4" "$TD/sakura/media/$f.mp4"; done
cp "$M/pump.mp4" "$TD/sakura/media/pump.mp4"; cp "$M/pump.mp4" "$TD/sakura/media/pump/pump-2.mp4"
jq -n '{id: "us88-sakura", background: {type: "image", path: "us88/bg.png"}}' >"$TD/sakura/us88/us88-sakura.template.json"
cp "$M/strip.mp4" "$TD/sakura/us88/strip.mp4"
ffmpeg -nostdin -v error -y -i "$M/strip.mp4" -frames:v 1 "$TD/sakura/us88/bg.png"
cp -al "$TD/sakura" "$TD/hellfire"
cp "$M/pump.mp4" "$V/hydroshift-ii-oled-curve/video/001bgnew_260414135722.mp4"
cp "$M/alpha.mov" "$V/hydroshift-ii-oled-curve/video/alpha_rings.mov"
printf 'stream' >"$V/hydroshift-ii-oled-curve/video/001bgnew_260414135722.h264"
cp "$M/pump.mp4" "$V/hydroshift-ii-oled-curve/preview/p.mp4"
cp "$M/sq.mp4" "$V/flex-lcd/temp/t.mp4"
cp "$M/sq.mp4" "$V/flex-lcd/video/planet37.mp4"
cp "$M/pump.mp4" "$V/uploaded/hydroshift-ii-oled-curve/fullscreen/20260919145236.mp4"
cp "$M/wide.mp4" "$V/themes/deep-orange/ember-sky.mp4"
cp "$M/portrait.mov" "$H/Videos/phone/portrait.mov"
cp "$M/name with space -x.mp4" "$H/Videos/phone/"
cp "$M/new"$'\n'"line.mp4" "$H/Videos/phone/"
cp "$M/sq.mp4" "$H/Videos/.hidden/secret.mp4"
cp "$M/quad.png" "$M/tiny.png" "$M/broken.mp4" "$P/"
echo sakura >"$C/scheme"; echo on >"$C/lights"; echo on >"$C/screens"
jq -n --arg p "$TD/sakura/media/fan-a.mp4" '{lcds: [{serial: "hid:1cbe:a018:8-12.2.1", type: "video", path: $p, orientation: 180}],
  hardware_video: false, default_fps: 30.0}' >"$H/.config/lianli/config.json"
echo '{"templates": []}' >"$H/.config/lianli/lcd_templates.json"

cat >"$T/over.sh" <<EOF
# Sourced by the engine (PCL_TEST_OVERRIDES): no daemon, no OpenRGB, systemd
# only for scopes and this run's own units ($UNITP-*).
logger() { :; }
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
openrgb() { echo "blocked: openrgb" >&2; return 1; }
systemd-run() {
  case " \$* " in
    *" --scope "* | *" --unit=$UNITP-"*) command systemd-run "\$@" ;;
    *) echo "blocked: systemd-run \$*" >>"\$HOME/stub.log"; return 1 ;;
  esac
}
systemctl() {
  case " \$* " in
    *" $UNITP-"*) command systemctl "\$@" ;;
    *) echo "blocked: systemctl \$*" >>"\$HOME/stub.log"; return 1 ;;
  esac
}
EOF
cat >>"$T/over.sh" <<'EOF'
if ! declare -F media_cmd >/dev/null || [[ $(declare -f media_cmd) == *"not installed"* ]]; then source "$PCL_LIB/media.sh"; fi
# B2's draft functions: the real ones, or (PCL_MEDIA_DRAFT_STUBS=1, or while
# editor.sh lacks them) small stand-ins that do what the contract says.
if [[ -n ${PCL_MEDIA_DRAFT_STUBS:-} || $(declare -f editor_media_apply) == *md_standin* ]]; then
  editor_draft_stage() {
    local d=$STATE_DIR/drafts/$1.media
    if [[ ${2:-} == --create ]]; then [[ -f $STATE_DIR/drafts/$1.json ]] || return 1; (umask 077 && mkdir -p "$d/media"); fi
    echo "$d"
  }
  editor_draft_abspath() {
    local r; r=$(jq -r '.media_root // empty' "$STATE_DIR/drafts/$1.json" 2>/dev/null)
    if [[ -e $STATE_DIR/drafts/$1.media/$2 ]]; then echo "$STATE_DIR/drafts/$1.media/$2"
    elif [[ -n $r && -e $r/$2 ]]; then echo "$r/$2"; else return 1; fi
  }
  editor_media_pending() {
    local f=$STATE_DIR/drafts/$1.json old
    [[ -f $f ]] || return 1
    old=$(jq -r --arg r "$2" '.pending_media[$r] // empty' "$f")
    if [[ -n ${4:-} && $old != "$4" ]]; then return 0; fi
    jq --arg r "$2" --arg j "${3:-}" '.pending_media = ((.pending_media // {}) | if $j == "" then del(.[$r]) else .[$r] = $j end)' \
      "$f" >"$f.t" && mv "$f.t" "$f"
    if [[ -n $old && $old != "${3:-}" ]]; then echo "$old"; fi
  }
  editor_media_apply() {
    local f=$STATE_DIR/drafts/$1.json j=$2
    [[ -f $f ]] || return 1
    [[ $(jq -r --arg r "$(jq -r .role "$j")" '.pending_media[$r] // empty' "$f") == "$(jq -r .id "$j")" ]] || return 1
    jq --slurpfile j "$j" '$j[0] as $j | ($j.output.rel) as $rel
      | (if ($rel | test("\\.(png|jpe?g)$")) then "image" else "video" end) as $type
      | if $j.then == "clip-add" then .theme.screens[$j.role].clips = ((.theme.screens[$j.role].clips // []) + [$rel])
        elif $j.then == "set" then .theme.screens[$j.role] = ((.theme.screens[$j.role] // {}) + {type: $type, path: $rel, model: $j.model})
        else . end
      | .pending_media |= del(.[$j.role]) | .rev += 1
      | .media_sources[$rel] = {source: $j.source.path, recipe: $j.recipe, model: $j.model, at: 0}' "$f" >"$f.t" && mv "$f.t" "$f"
    jq -r .rev "$f"
  }
fi
if [[ -n ${T_CALL:-} ]]; then eval "$T_CALL"; exit $?; fi
if [[ ${1:-} == media ]]; then shift; media_cmd "$@"; exit $?; fi
if [[ ${1:-} == theme && ${2:-} != preview ]]; then shift; editor_cmd "$@"; exit $?; fi
EOF
ENV=(HOME="$H" PCL_MEDIA_INLINE=1 PCL_MEDIA_INDEX=off PCL_HEAVY_DIR="$T/slots" PCL_MEDIA_UNIT="$UNITP"
     PCL_TEST_OVERRIDES="$T/over.sh")
eng() { env "${ENV[@]}" "$PCL" "$@"; }
m() { eng media "$@"; }
ecall() { T_CALL=$1 eng status; }
# mj <jq args...> <filter>: jq with theme.jq and media.jq, $M the models.
mj() { jq -n -L "$LIB" --slurpfile m "$LIB/models.json" "${@:1:$#-1}" 'include "theme"; '"$(<"$LIB/media.jq")"' $m[0] as $M | '"${*: -1}"; }
sha() { sha256sum <"$1" | cut -c1-64; }
J=$K/media/jobs
# px <image> <x> <y>: "r g b" (0-255) of one pixel.
px() { magick "$1" -format "%[fx:int(255*p{$2,$3}.r+0.5)] %[fx:int(255*p{$2,$3}.g+0.5)] %[fx:int(255*p{$2,$3}.b+0.5)]" info:; }
# frame0 <video> <out.png>: its first frame.
frame0() { ffmpeg -nostdin -v error -y -i "$1" -frames:v 1 "$2"; }
# colour <"r g b"> <red|lime|blue|black|yellow>: roughly that colour.
colour() {
  local r g b; read -r r g b <<<"$1"
  case $2 in
    red) (( r > 190 && g < 70 && b < 70 )) ;; lime) (( g > 190 && r < 70 && b < 70 )) ;;
    blue) (( b > 190 && r < 70 && g < 70 )) ;; black) (( r < 30 && g < 30 && b < 30 )) ;;
    yellow) (( r > 190 && g > 190 && b < 70 )) ;; *) return 1 ;;
  esac
}
# vinfo <file>: codec w h pix_fmt fps(num/den) duration audio-streams
vinfo() {
  ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,pix_fmt,avg_frame_rate:format=duration -of json "$1" |
    jq -c '{codec: ([.streams[] | select(.codec_type == "video")][0].codec_name), w: ([.streams[] | select(.codec_type == "video")][0].width),
      h: ([.streams[] | select(.codec_type == "video")][0].height), pix: ([.streams[] | select(.codec_type == "video")][0].pix_fmt),
      fps: ([.streams[] | select(.codec_type == "video")][0].avg_frame_rate | split("/") | map(tonumber) | .[0] / .[1]),
      duration: (.format.duration | tonumber), audio: ([.streams[] | select(.codec_type == "audio")] | length)}'
}
# newjob: the job file created since snap_jobs.
jobs_now() { local f; for f in "$J"/j-*.json; do if [[ -f $f ]]; then f=${f##*/}; echo "${f%.json}"; fi; done; }
snap_jobs() { mapfile -t JOBS_BEFORE < <(jobs_now); }
newjob() { comm -13 <(printf '%s\n' "${JOBS_BEFORE[@]}" | sort) <(jobs_now | sort) | head -n1; }

# The sources: sha, mtime and link count before anything runs (plan §6.1).
src_state() {
  local f
  while IFS= read -r -d '' f; do
    printf '%q %s %s\n' "$f" "$(stat -c '%s %Y %h' -- "$f")" "$(sha256sum <"$f" | cut -c1-16)"
  done < <(find "$M" "$H/Videos" "$P" -type f -print0 | sort -z)
}
src_state >"$T/src.before"

echo "engine:  $PCL"
echo "fixture: $T"
echo "media:   $M"

echo "# the frozen fixtures (tests/fixtures/media.*.json)"
jc "media.list.library.json: the list shape" '.v == 1 and .source == "library" and (.for | has("role", "model", "shape", "media"))
  and (.total | type == "number") and has("offset", "limit", "truncated", "tools_missing")
  and (.indexing | has("state", "done", "of")) and all(.groups[]; has("id", "label"))
  and all(.items[]; has("id", "path", "rel", "where", "group", "title", "kind", "w", "h", "duration", "fps", "bytes", "mtime",
    "probe_state", "error", "thumb", "thumb_state", "made_for", "fit", "in_use", "used_by")
    and (.fit | has("state", "keep", "scale", "score", "note")))' "$(cat "$FX/media.list.library.json")"
jc "media.list.theme.json: rel and where on every item" '.source == "theme:sakura-2" and all(.items[]; (.rel | type == "string") and (.where | IN("stage", "root")))' \
  "$(cat "$FX/media.list.theme.json")"
for s in running "done" failed; do
  jc "media.job.$s.json: the record shape" '.v == 1 and (.id | test("^j-[0-9]+-[0-9]+$")) and .kind == "prepare"
    and (.state | IN("queued", "waiting", "probing", "estimating", "encoding", "finishing", "done", "failed", "cancelled"))
    and has("draft", "role", "model", "then", "at", "dest", "source", "request", "recipe", "estimate", "progress", "unit", "pid", "started",
            "updated", "ended", "output", "warnings", "error", "applied")
    and (.progress | has("frac", "out_time", "speed", "eta")) and (.recipe | has("v", "mode", "crop", "time", "start", "duration",
            "fps", "size", "codec", "crf", "maxrate", "bg", "key"))' "$(cat "$FX/media.job.$s.json")"
done
jc "media.frame.json: the frame shape" 'keys == (["duration", "h", "kind", "path", "src_h", "src_w", "time", "w"])' "$(cat "$FX/media.frame.json")"
run mj --slurpfile l "$FX/media.list.library.json" '
  [$l[0].items[] | select(.probe_state == "ready") | . as $i
   | media_fit({dw: .w, dh: .h, duration, kind, made_for, made_for_aspect: (models($M).lcd[.made_for // ""].aspect // null)};
               media_target("HydroShift2OledCurveLcd"; $M)) == $i.fit] | all'
jc "media_fit reproduces every fit in media.list.library.json" '. == true'

echo "# models.json: prep and lconnect"
run mj 'models($M).lcd | to_entries | map(.value.kind == "lcd" and (.value.prep | type == "object")
  and (.value.prep | has("fps", "max_s", "crf", "maxrate", "image"))) | all'
jc "every LCD model has prep {fps, max_s, crf, maxrate, image}" '. == true'
run mj '[media_target("TlFlexLcd"; $M), media_target("HydroShift2OledCurveLcd"; $M), media_target("UniversalScreen"; $M)]
  | map([.crf, .maxrate, .max_s, .image])'
jc "fans crf 20 / 4M, pump 22 / 12M / png, 8.8\" 21 / 8M / 180 s" '. == [[20, "4M", 120, "auto"], [22, "12M", 120, "png"], [21, "8M", 180, "auto"]]'
run mj 'media_lc_map($M)'
jc "L-Connect folders map to their models" '.["flex-lcd"] == "TlFlexLcd" and .["tlflex-lcd"] == "TlFlexLcd"
  and .["hydroshift-ii-oled-curve"] == "HydroShift2OledCurveLcd" and .["universal-screen-8.8-inch"] == "UniversalScreen"'
run mj '$M._prep_defaults | del(._about)'
jc "_prep_defaults is a note with the defaults" '. == {fps: 30, max_s: 120, crf: 21, maxrate: "8M", image: "auto"}'

echo "# media.jq: titles, fit, crop"
run mj '["/a/planet37.mp4", "/a/001bgnew_260414135722.mp4", "/s/media/planet37-3fa9c2d1.mp4", "/x/fan-a.mp4",
  "/x/mp4v2 x264.MOV", "/x/.mp4", "/x/IMG_1234.JPG"] | map(media_title)'
jc "media_title" '. == ["planet 37", "001bgnew 260414135722", "planet 37", "fan a", "mp4v2 x264", "untitled", "IMG 1234"]'
run mj '
  def t($m): media_target($m; $M);
  def f($w; $h; $m): media_fit({dw: $w, dh: $h, kind: "video", duration: 10}; t($m));
  {fan_exact: f(400; 400; "TlFlexLcd"), fan_wide: f(1920; 1080; "TlFlexLcd"), fan_tiny: f(64; 64; "TlFlexLcd"),
   pump_exact: f(2288; 1080; "HydroShift2OledCurveLcd"), pump_wide: f(1920; 1080; "HydroShift2OledCurveLcd"),
   pump_sq: f(400; 400; "HydroShift2OledCurveLcd"), pump_near: f(2280; 1080; "HydroShift2OledCurveLcd"),
   strip_exact: f(1920; 480; "UniversalScreen"), strip_wide: f(1920; 1080; "UniversalScreen"),
   round: f(480; 480; "HydroShiftLcd"), vision: f(1920; 464; "Vision9p2"), aux: f(1472; 720; "Lancool207")}'
jc "fit states per model" '.fan_exact.state == "exact" and .pump_exact.state == "exact" and .strip_exact.state == "exact"
  and .round.state == "exact" and .vision.state == "exact" and .aux.state == "exact"
  and .pump_near.state == "scaled" and .pump_wide.state == "cropped" and .pump_sq.state == "poor" and .strip_wide.state == "poor"'
jc "fit numbers: 16:9 on the pump keeps 0.839, scale 1.192, score 0.704" '.pump_wide.keep == 0.839 and .pump_wide.scale == 1.192 and .pump_wide.score == 0.704'
jc "fit numbers: square on the pump keeps 0.472; 1080p on a fan 0.5625" '.pump_sq.keep == 0.472 and .fan_wide.keep == 0.563 and .fan_wide.scale == 0.37'
jc "a 64 px source on a fan: scaled, low-res" '.fan_tiny.state == "scaled" and .fan_tiny.note == "low-res" and .fan_tiny.scale == 6.25'
run mj '
  (media_target("HydroShift2OledCurveLcd"; $M)) as $t
  | {long: media_fit({dw: 2288, dh: 1080, kind: "video", duration: 200}; $t).note,
     alpha: media_fit({dw: 2288, dh: 1080, kind: "video", duration: 5, alpha: true}; $t).note,
     hdr: media_fit({dw: 2288, dh: 1080, kind: "video", duration: 5, hdr: true}; $t).note,
     still_long: media_fit({dw: 2288, dh: 1080, kind: "image"}; $t).note,
     same_shape: media_fit({dw: 1920, dh: 1080, kind: "video", duration: 5, made_for: "X", made_for_aspect: "wide-curve"}; $t).score,
     other_shape: media_fit({dw: 1920, dh: 1080, kind: "video", duration: 5, made_for: "TlFlexLcd", made_for_aspect: "square"}; $t).score,
     unknown: media_fit(null; $t), broken: media_fit({dw: 10, dh: 10, error: "broken"}; $t).state}'
jc "notes: long, alpha, hdr; stills are never long" '.long == "long" and .alpha == "alpha" and .hdr == "hdr" and .still_long == null'
jc "made for the same shape x1.05, another x0.9" '.same_shape == 0.739 and .other_shape == 0.634'
jc "unprobed and broken: unknown" '.unknown == {state: "unknown", keep: null, scale: null, score: null, note: null} and .broken == "unknown"'
run mj '{cover_fan_wide: media_crop(null; 1920; 1080; 400; 400), cover_pump_portrait: media_crop(null; 1080; 1920; 2288; 1080),
  cover_strip: media_crop(null; 1920; 1080; 1920; 480), given: media_crop([0, 0, 1500, 1500]; 4000; 3000; 400; 400),
  off_aspect: media_crop([100, 100, 1000, 500]; 1920; 1080; 400; 400), near_aspect: media_crop([10, 10, 403, 400]; 1920; 1080; 400; 400),
  outside: media_crop([1800, 900, 600, 600]; 1920; 1080; 400; 400), too_big: media_crop([-50, 10, 5000, 5000]; 401; 301; 400; 400),
  odd: media_crop([11, 13, 301, 301]; 1001; 1001; 400; 400)}'
jc "crop: centre cover per shape" '.cover_fan_wide == [420, 0, 1080, 1080] and .cover_pump_portrait == [0, 704, 1080, 508] and .cover_strip == [0, 300, 1920, 480]'
jc "crop: a crop in the model's aspect is kept" '.given == [0, 0, 1500, 1500]'
jc "crop: more than 1 % off the aspect shrinks around its centre; within 1 % it stays" '.off_aspect == [350, 100, 500, 500] and .near_aspect == [10, 10, 402, 400]'
jc "crop: moved inside the frame, scaled down when too big, all even" '.outside == [1320, 480, 600, 600] and .too_big == [100, 0, 300, 300]
  and (.odd | all(. % 2 == 0)) and .odd == [10, 12, 300, 300]'
run mj '[models($M).lcd | to_entries[] | .key as $k | media_crop(null; 3000; 2000; .value.media[0]; .value.media[1])
  | . as [$x, $y, $w, $h] | ($w / $h) / (models($M).lcd[$k].media[0] / models($M).lcd[$k].media[1]) | . > 0.99 and . < 1.01] | all'
jc "crop: every model's cover crop has its aspect (within 1 %)" '. == true'

echo "# media list: the library"
run m list --for screen.pump --json
rcis "list --for screen.pump: exit 0" 0
jc "list: the §1.3b shape" '.v == 1 and .source == "library" and .for == {role: "screen.pump", model: "HydroShift2OledCurveLcd", shape: "wide-curve", media: [2288, 1080]}
  and .offset == 0 and .limit == 60 and .truncated == false and .tools_missing == [] and (.indexing | has("state", "done", "of"))'
jcf "list: the keys of the frozen fixture (top, items, fit)" "$FX/media.list.library.json" \
  '(keys == ($f | keys)) and all(.items[]; keys == ($f.items[0] | keys) and (.fit | keys) == ($f.items[0].fit | keys))'
jc "list: not probed yet: pending, unknown fit, no thumbnail, indexing off" 'all(.items[]; .probe_state == "pending" and .fit.state == "unknown"
  and .thumb == null and .thumb_state == "pending") and .indexing.state == "off" and .indexing.done == 0'
jc "list: *.h264, preview/, temp/ and hidden folders left out" '[.items[].path | select(test("\\.h264$|/preview/|/temp/|/\\.hidden/"))] == []'
jc "list: hard-linked themes are one item each, in_use lists both" '[.items[] | select(.group == "themes")] | length == 7 and all(.[]; .in_use == ["hellfire", "sakura"])'
jc "list: groups and labels" '[.groups[] | [.id, .label]] == [["lconnect:HydroShift2OledCurveLcd", "Pump clips"], ["themes", "Other themes"],
  ["lconnect:uploads", "Your L-Connect uploads"], ["library", "Library"], ["lconnect:TlFlexLcd", "Fan clips"]]'
jc "list: L-Connect folders give made_for" '[.items[] | select(.path | test("/flex-lcd/video/")) | .made_for] == ["TlFlexLcd"]
  and [.items[] | select(.group == "lconnect:uploads") | .made_for] == ["HydroShift2OledCurveLcd"]'
jc "list: ids are m-<10 hex>, titles from the names" 'all(.items[]; .id | test("^m-[0-9a-f]{10}$")) and any(.items[]; .title == "001bgnew 260414135722")'
cp "$K/media/index.want" "$T/want.1"
want_first=$(tr '\0' '\n' <"$T/want.1" | head -n1)
[[ $want_first == "$(jq -r '.items[0].path' <<<"$out")" ]] && ok "index.want starts with the page's first item" || bad "index.want starts with the page's first item" "$want_first"
run m list --for screen.pump --offset 3 --limit 2 --json
jc "paging: offset 3, limit 2, total unchanged" '.offset == 3 and .limit == 2 and (.items | length) == 2 and .total == 12'
page=$(jq -r '.items[].path' <<<"$out")
[[ $(tr '\0' '\n' <"$K/media/index.want" | head -n2) == "$page" ]] && ok "index.want: a later page's items come first" || bad "index.want: a later page's items come first"
run env "${ENV[@]}" PCL_MEDIA_INDEX= "$PCL" media list --for screen.pump --json
rcis "list with the indexer on (inline: it runs after the answer)" 0
jc "that answer was still the pending one" 'all(.items[]; .probe_state == "pending") and .indexing.state == "running"'
check "index.stamp touched, index.jsonl written" test -f "$K/media/index.stamp" -a -s "$K/media/index.jsonl"
run m list --for screen.pump --json
jc "after indexing: every item ready, thumbnails ready, indexing done" 'all(.items[]; .probe_state == "ready" and .thumb_state == "ready" and (.thumb | test("/thumbs/[0-9a-f]{2}/[0-9a-f]{40}\\.webp$")))
  and .indexing == {state: "done", done: 12, of: 12}'
jc "ranking: the exact pump clip first, then the rest of its group" '.items[0].path | endswith("/001bgnew_260414135722.mp4")'
jc "ranking: exact 1.0; 16:9 cropped keep 0.839; a square fan clip poor" '(.items[0].fit | .state == "exact" and .score == 1)
  and ([.items[] | select(.title == "ember sky") | .fit | .state == "cropped" and .keep == 0.839] == [true])
  and ([.items[] | select(.title == "planet 37") | .fit.state] == ["poor"])'
jc "ranking: within a group by score (then newest)" '[.items[] | select(.group == "themes") | .fit.score] as $s | $s == ($s | sort | reverse)'
jc "the 4:3 alpha overlay on the pump: cropped, low-res" '[.items[] | select(.title == "alpha rings") | .fit | [.state, .keep, .note]] == [["cropped", 0.629, "low-res"]]'
nth=0 nbad=0
while IFS= read -r t; do
  nth=$((nth + 1))
  if ! [[ $(magick identify -format '%m %w %h' "$t" 2>/dev/null) =~ ^WEBP\ ([0-9]+)\ ([0-9]+)$ ]] || (( BASH_REMATCH[1] > 256 || BASH_REMATCH[2] > 256 )); then nbad=$((nbad + 1)); fi
done < <(jq -r '.items[].thumb' <<<"$out")
(( nth == 12 && nbad == 0 )) && ok "thumbnails: webp, 256 px at most on each side" || bad "thumbnails: webp, 256 px at most on each side" "$nth thumbs, $nbad bad"
run m list --for screen.pump --query EMBER --json
jc "--query: case-insensitive over the title" '.total == 1 and .items[0].title == "ember sky"'
run m list --for screen.pump --query deep-orange --json
jc "--query: and the parent folder" '.total == 1 and .items[0].title == "ember sky"'
run m list --for screen.pump --query nothing-like-it --json
jc "--query: nothing matches" '.total == 0 and .items == []'
run m list --for TlFlexLcd --json
jc "--for a model needs no role" '.for.role == null and .for.model == "TlFlexLcd" and .for.shape == "square"'
jc "for a fan: the fan clips' group first" '.groups[0].id == "lconnect:TlFlexLcd" and .items[0].title == "planet 37"'
run env "${ENV[@]}" PCL_MEDIA_LIST_CAP=5 "$PCL" media list --for screen.pump --json
jc "at most PCL_MEDIA_LIST_CAP files, then truncated" '.truncated == true and .total == 5'
run m list --for screen.nope --json
rcis "--for an unknown role: 2 no-role" 2 no-role
run m list --for screen.pump --source moon --json
rcis "--source moon: 2 usage" 2 usage
run m list --json
rcis "no --for: 2 usage" 2 usage
mv "$C/profile.json" "$C/profile.away"
run m list --for screen.pump --json
rcis "a role without a profile: 5 no-profile" 5 no-profile
run m list --for HydroShift2OledCurveLcd --json
rcis "a model without a profile: fine" 0
mv "$C/profile.away" "$C/profile.json"

echo "# media list: my files"
run m list --for screen.fan1 --source files --json
rcis "list --source files: exit 0" 0
jc "files: Videos and Pictures, not the library, the themes, the state or hidden folders" '[.items[].path | select(test("/lian-li/|/\\.config/|/\\.cache/|/\\.hidden/"))] == []
  and ([.items[].group] | unique) == ["pictures", "videos"]'
jc "files: odd names survive (spaces, a newline)" 'any(.items[]; .path | endswith("/name with space -x.mp4")) and any(.items[]; .path | endswith("/new\nline.mp4"))'
jc "files: group labels Videos and Pictures" '.groups == [{id: "videos", label: "Videos"}, {id: "pictures", label: "Pictures"}]'
eng media --index >/dev/null 2>&1 || true
run m list --for screen.fan1 --source files --json
jc "files after indexing: the broken file is failed, with a .fail thumbnail" '[.items[] | select(.path | endswith("/broken.mp4")) | [.probe_state, .error, .thumb_state]] == [["failed", "broken", "failed"]]'
jc "files: the portrait video is probed in display orientation" '[.items[] | select(.path | endswith("/portrait.mov")) | [.w, .h]] == [[1080, 1920]]'
jc "files: a name with a newline is indexed like any other" '[.items[] | select(.path | endswith("/new\nline.mp4")) | [.probe_state, .thumb_state]] == [["ready", "ready"]]'
jc "failed items go last in their group" '[.items[] | select(.group == "pictures") | .probe_state] | last == "failed"'
fails=$(find "$K/thumbs" -name '*.fail' | wc -l)
(( fails >= 1 )) && ok ".fail markers written for what can't be read" || bad ".fail markers written for what can't be read"

echo "# probe"
declare -A PX=(
  [portrait.mov]='.kind == "video" and .w == 1920 and .h == 1080 and .dw == 1080 and .dh == 1920 and .rotation == 90 and .error == null'
  [exif6.jpg]='.kind == "image" and .w == 600 and .h == 400 and .dw == 400 and .dh == 600 and .error == null'
  [alpha.mov]='.kind == "video" and .codec == "qtrle" and .alpha == true'
  [alpha.png]='.kind == "image" and .alpha == true'
  [anim.gif]='.kind == "animation" and .frames == 10 and .fps == 10'
  [still.gif]='.kind == "image" and .frames == 1'
  [wide.mp4]='.kind == "video" and .fps == 60 and .duration == 2 and .audio == false and .dw == 1920'
  [huge.jpg]='.kind == "image" and .dw == 9000 and .dh == 6000'
)
for f in "${!PX[@]}"; do
  run m probe "$M/$f" --json
  jc "probe $f" "${PX[$f]}"
done
if [[ -f $M/hevc10.mkv ]]; then run m probe "$M/hevc10.mkv" --json; jc "probe hevc10.mkv: hdr" '.hdr == true and .codec == "hevc"'
else skip "probe hevc10.mkv (no libx265)"; fi
run m probe "$M/audio.mp4" --json; rcis "probe a sound file: 2 no-picture" 2 no-picture
run m probe "$M/broken.mp4" --json; rcis "probe junk: 2 broken" 2 broken
run m probe "$M/empty.mp4" --json; rcis "probe an empty file: 2 broken" 2 broken
mkfifo "$T/x.mp4"
run m probe "$T/x.mp4" --json; rcis "probe a FIFO: 2 invalid" 2 invalid
run m probe "$T/nope.mp4" --json; rcis "probe a missing file: 2 not-found" 2 not-found
run m probe "$T" --json; rcis "probe a folder: 2 invalid" 2 invalid
run ecall "media_probe_many '$M/sq.mp4' '$M/tiny.png' '$M/sq.mp4'"
[[ $(wc -l <<<"$out") == 3 && $(sed -n 3p <<<"$out") == "$(sed -n 1p <<<"$out")" ]] && ok "media_probe_many: one line per path, repeats answered" || bad "media_probe_many: one line per path" "$out"

echo "# frame"
run m frame "$M/portrait.mov" --json
jc "frame: the §1.3 shape, display orientation, at a third" 'keys == (["duration", "h", "kind", "path", "src_h", "src_w", "time", "w"]) and .w == 540 and .h == 960
  and .src_w == 1080 and .src_h == 1920 and .time == 0.667 and .kind == "video"'
p1=$(jq -r .path <<<"$out")
colour "$(px "$p1" 270 100)" blue && colour "$(px "$p1" 270 860)" red && ok "frame: the top of the displayed picture is on top" || bad "frame: display orientation" "$(px "$p1" 270 100) / $(px "$p1" 270 860)"
m1=$(stat -c %Y "$p1"); sleep 1
run m frame "$M/portrait.mov" --json
[[ $(jq -r .path <<<"$out") == "$p1" && $(stat -c %Y "$p1") == "$m1" ]] && ok "frame: cached per (file, moment)" || bad "frame: cached"
run m frame "$M/wide.mp4" --time 99 --json
jc "frame: the moment is clamped to the end" '.time == 1.95 and .w == 960 and .h == 540'
run m frame "$M/wide.mp4" --time 1 --max 300 --json
jc "frame: --max bounds the long side" '.w == 300 and .h >= 166 and .h <= 170'
run m frame "$M/exif6.jpg" --json
jc "frame: an EXIF-rotated photo, upright" '.w == 400 and .h == 600 and .kind == "image" and .time == 0'
colour "$(px "$(jq -r .path <<<"$out")" 200 100)" blue && ok "frame: EXIF orientation applied" || bad "frame: EXIF orientation applied"
run m frame "$M/alpha.mov" --json
colour "$(px "$(jq -r .path <<<"$out")" 5 5)" black && colour "$(px "$(jq -r .path <<<"$out")" 320 240)" lime && ok "frame: transparency over black" || bad "frame: transparency over black"
run m frame "$M/audio.mp4" --json; rcis "frame of a sound file: 2 no-picture" 2 no-picture

echo "# thumb"
run m thumb "$M/tiny.png" "$M/anim.gif" --now --json
jc "thumb --now: made at once" '(.thumbs | length) == 2 and all(.thumbs[]; .state == "ready" and (.thumb | endswith(".webp")))'
run env "${ENV[@]}" PCL_MEDIA_INDEX= "$PCL" media thumb "$M/strip.mp4" --json
jc "thumb without --now: queued (inline: made after the answer)" '.thumbs[0].state == "pending" and .thumbs[0].thumb == null'
run ecall "media_thumb '$M/strip.mp4'"
[[ -f $out ]] && ok "media_thumb: the path, and the file is there once the indexer ran" || bad "media_thumb" "$out"

echo "# prepare: outputs (--out)"
O=$T/out
mkdir -p "$O"
declare -A DIMS=([TlFlexLcd]="400 400" [HydroShift2OledCurveLcd]="2288 1080" [UniversalScreen]="1920 480" [HydroShiftLcd]="480 480"
                 [Vision9p2]="1920 464" [Lancool207]="1472 720")
for mdl in "${!DIMS[@]}"; do
  run m prepare "$M/wide.mp4" --for "$mdl" --out "$O/wide-$mdl.mp4" --json
  vi=$(vinfo "$O/wide-$mdl.mp4" 2>/dev/null || echo '{}')
  read -r w h <<<"${DIMS[$mdl]}"
  jc "prepare wide.mp4 for $mdl: exactly ${w}x$h, h264 yuv420p, no audio, 30 fps" \
    ".codec == \"h264\" and .w == $w and .h == $h and .pix == \"yuv420p\" and .audio == 0 and .fps == 30 and (.duration - 2 | fabs) < 0.1" "$vi"
done
jcf "the job record: the keys of the frozen fixture" "$FX/media.job.done.json" \
  '(.job | keys) == ($f | keys) and (.job.recipe | keys) == ($f.recipe | keys) and (.job.progress | keys) == ($f.progress | keys)
   and (.job.output | keys) == ($f.output | keys) and (.job.source | keys) == ($f.source | keys)'
jc "the job record: done, --out, encode recipe" '.job.state == "done" and .job.draft == null and .job.then == null and .job.recipe.mode == "encode"
  and .job.recipe.fps == 30 and .job.output.rel == null and (.job.output.sha256 | length) == 64'
run m prepare "$M/sq.mp4" --for TlFlexLcd --out "$O/sq.mp4" --json
jc "an exact source is remuxed" '.job.recipe.mode == "remux" and .job.state == "done"'
jc "remux: still exactly 400x400 h264" '.w == 400 and .h == 400 and .codec == "h264"' "$(vinfo "$O/sq.mp4")"
run m prepare "$M/pump.mp4" --for HydroShift2OledCurveLcd --out "$O/pump.mp4" --json
jc "an exact pump clip is remuxed (short: no estimate)" '.job.recipe.mode == "remux" and .job.estimate == null'
run m prepare "$M/anim.gif" --for TlFlexLcd --out "$O/anim.mp4" --json
jc "an animated GIF becomes an mp4" '.job.recipe.mode == "encode" and .job.recipe.codec == "h264" and .job.recipe.bg == "black"'
jc "GIF -> mp4: 400x400 h264, its 10 fps kept" '.codec == "h264" and .w == 400 and .h == 400 and .fps == 10' "$(vinfo "$O/anim.mp4")"
run m prepare "$M/still.gif" --for TlFlexLcd --out "$O/still.png" --json
jc "a one-frame GIF is a picture: PNG" '.job.recipe.mode == "still" and .job.recipe.codec == "png"'
jc "still.gif -> 400x400 PNG" '. == "PNG 400 400"' "\"$(magick identify -format '%m %w %h' "$O/still.png")\""
run m prepare "$M/quad.png" --for TlFlexLcd --crop 0,0,1500,1500 --out "$O/quad-red.png" --json
jc "a PNG stays PNG" '.job.recipe.codec == "png" and .job.recipe.crop == [0, 0, 1500, 1500]'
colour "$(px "$O/quad-red.png" 200 200)" red && ok "crop the red quadrant: the centre is red" || bad "crop the red quadrant" "$(px "$O/quad-red.png" 200 200)"
run m prepare "$M/quad.png" --for TlFlexLcd --crop 2400,1600,1500,1400 --out "$O/quad-yellow.png" --json
jc "an off-aspect crop is fixed to the model's (centre kept)" '.job.recipe.crop == [2450, 1600, 1400, 1400]'
colour "$(px "$O/quad-yellow.png" 200 200)" yellow && ok "crop the yellow quadrant: the centre is yellow" || bad "crop the yellow quadrant" "$(px "$O/quad-yellow.png" 200 200)"
run m prepare "$M/huge.jpg" --for TlFlexLcd --out "$O/huge.jpg" --json
jc "a JPEG becomes JPEG" '.job.recipe.codec == "jpeg" and .job.state == "done"'
jc "huge.jpg -> 400x400 JPEG" '. == "JPEG 400 400"' "\"$(magick identify -format '%m %w %h' "$O/huge.jpg")\""
run m prepare "$M/huge.jpg" --for HydroShift2OledCurveLcd --out "$O/huge-pump.png" --json
jc "the pump always gets PNG (prep.image png)" '.job.recipe.codec == "png"'
jc "huge.jpg -> 2288x1080 PNG" '. == "PNG 2288 1080"' "\"$(magick identify -format '%m %w %h' "$O/huge-pump.png")\""
run m prepare "$M/alpha.png" --for TlFlexLcd --out "$O/alpha.png" --json
jc "a transparent picture: PNG over black" '.job.recipe.codec == "png" and .job.recipe.bg == "black" and any(.job.warnings[]; .code == "alpha")'
colour "$(px "$O/alpha.png" 2 2)" black && colour "$(px "$O/alpha.png" 200 200)" lime && ok "alpha.png: the corner is black, the square lime" || bad "alpha.png flattened" "$(px "$O/alpha.png" 2 2) $(px "$O/alpha.png" 200 200)"
run m prepare "$M/alpha.mov" --for TlFlexLcd --out "$O/alpha.mp4" --json
frame0 "$O/alpha.mp4" "$T/alpha0.png"
colour "$(px "$T/alpha0.png" 3 3)" black && colour "$(px "$T/alpha0.png" 200 200)" lime && ok "alpha.mov: the corner is black, the centre green" || bad "alpha.mov flattened" "$(px "$T/alpha0.png" 3 3) $(px "$T/alpha0.png" 200 200)"
run m prepare "$M/portrait.mov" --for TlFlexLcd --crop 0,0,1080,1080 --out "$O/portrait-top.mp4" --json
jc "a portrait crop is in display pixels" '.job.recipe.crop == [0, 0, 1080, 1080] and .job.source.w == 1080 and .job.source.h == 1920'
frame0 "$O/portrait-top.mp4" "$T/portrait0.png"
colour "$(px "$T/portrait0.png" 200 200)" blue && ok "portrait crop: the top of the picture (blue)" || bad "portrait crop" "$(px "$T/portrait0.png" 200 200)"
run m prepare "$M/exif6.jpg" --for TlFlexLcd --crop 0,0,400,400 --out "$O/exif6.jpg" --json
colour "$(px "$O/exif6.jpg" 200 100)" blue && ok "an EXIF-rotated photo is cropped upright" || bad "EXIF crop" "$(px "$O/exif6.jpg" 200 100)"
run m probe "$M/inter.mp4" --json
jc "probe an interlaced video" '.interlaced == true'
run m prepare "$M/inter.mp4" --for TlFlexLcd --out "$O/inter.mp4" --json
jc "an interlaced source is deinterlaced (yadif)" '.job.state == "done"'
[[ $(ffprobe -v error -show_entries stream=field_order -of csv=p=0 "$O/inter.mp4") == progressive ]] && ok "deinterlaced: the output is progressive" || bad "deinterlaced: the output is progressive"
run m prepare "$M/tiny.png" --for TlFlexLcd --out "$O/tiny.png" --json
jc "a 64 px picture: upscaled with low-res" 'any(.job.warnings[]; .code == "low-res")'
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=s=400x400 -frames:v 1 "$T/exact.png"
run m prepare "$T/exact.png" --for TlFlexLcd --out "$O/exact.png" --json
jc "an exact PNG is copied" '.job.recipe.mode == "copy"'
[[ $(stat -c %i "$O/exact.png") != "$(stat -c %i "$T/exact.png")" && $(stat -c %h "$T/exact.png") == 1 ]] && ok "copy: a new file, never a hard link to the source" || bad "copy is not a link"
if [[ -f $M/hevc10.mkv ]]; then
  run m prepare "$M/hevc10.mkv" --for TlFlexLcd --out "$O/hevc.mp4" --json
  jc "an HDR source: converted with the hdr warning" '.job.state == "done" and any(.job.warnings[]; .code == "hdr")'
  jc "hdr -> 8-bit yuv420p h264" '.pix == "yuv420p" and .codec == "h264"' "$(vinfo "$O/hevc.mp4")"
fi
run m prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/sq.mp4" --json
rcis "--out onto an existing file: 2 invalid" 2 invalid
run m prepare "$M/wide.mp4" --for TlFlexLcd --out "$M/wide.mp4" --json
rcis "--out onto the source: 2 invalid" 2 invalid

echo "# prepare: refusals"
run m prepare "$M/broken.mp4" --for TlFlexLcd --out "$O/b.mp4" --json; rcis "junk: 2 broken" 2 broken
run m prepare "$M/audio.mp4" --for TlFlexLcd --out "$O/a.mp4" --json; rcis "sound only: 2 no-picture" 2 no-picture
run m prepare "$M/empty.mp4" --for TlFlexLcd --out "$O/e.mp4" --json; rcis "an empty file: 2 broken" 2 broken
run m prepare "$T/x.mp4" --for TlFlexLcd --out "$O/f.mp4" --json; rcis "a FIFO: 2 invalid" 2 invalid
run m prepare "$T/nope.mp4" --for TlFlexLcd --out "$O/n.mp4" --json; rcis "a missing file: 2 not-found" 2 not-found
run m prepare "$M/wide.mp4" --out "$O/x.mp4" --json; rcis "no --for: 2 usage" 2 usage
run m prepare "$M/wide.mp4" --for TlFlexLcd --json; rcis "neither --draft nor --out: 2 usage" 2 usage
run m prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/x.mp4" --crop 1,2,3 --json; rcis "a bad --crop: 2 usage" 2 usage
run m prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/x.mp4" --crop 0,0,0,10 --json; rcis "a crop without a width: 2 invalid" 2 invalid
run m prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/x.mp4" --duration 0 --json; rcis "--duration 0: 2 usage" 2 usage
run env "${ENV[@]}" PCL_MEDIA_FREE_BYTES=1000000 "$PCL" media prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/x.mp4" --json
rcis "too little free space: 2 disk-full" 2 disk-full
T_CALL='md_load; md_tools_missing() { echo magick; }; media_cmd prepare "$2" --for TlFlexLcd --out "$3" --json' \
  run env "${ENV[@]}" "$PCL" status "$M/wide.mp4" "$O/x.mp4"
rcis "a missing tool: 2 missing-tool" 2 missing-tool
[[ ! -e $O/x.mp4 && ! -e $O/b.mp4 ]] && ok "refusals leave nothing behind" || bad "refusals leave nothing behind"

echo "# prepare: the pump's length (estimate)"
run m prepare "$M/long.mp4" --for HydroShift2OledCurveLcd --out "$O/long.mp4" --json
jc "a 200 s clip on the pump: sampled estimate" '.job.estimate.method == "sampled" and (.job.estimate.bytes_per_s > 0) and (.job.estimate.speed > 0)
  and .job.estimate.max_s == 120'
jc "the limit is min(max_s, 0.8 x 256 MiB / bytes_per_s, 100 x speed)" '.job.estimate as $e
  | $e.by_size_s == ((268435456 * 0.8 / $e.bytes_per_s) | floor) and $e.limit_s == ([$e.max_s, $e.by_size_s, $e.by_speed_s] | min)'
jc "trimmed to the limit, with the warning" '.job.recipe.duration == .job.estimate.limit_s and any(.job.warnings[]; .code == "trimmed" and .keep_s == 120 and .text == "Uses the first 2:00.")'
jc "the output is no longer than the estimate" "(.duration - $(jq .job.estimate.limit_s <<<"$out")) < 0.2 and .w == 2288" "$(vinfo "$O/long.mp4")"
T_CALL='md_load; md_sample_encode() { return 1; }; media_cmd prepare "$2" --for HydroShift2OledCurveLcd --out "$3" --json' \
  run env "${ENV[@]}" "$PCL" status "$M/long.mp4" "$O/long-fb.mp4"
jc "no samples: the fallback formula, 0.8 x 256 MiB / (1080 x 2288 x fps / 4 / 8)" '.job.estimate.method == "fallback" and .job.recipe.fps == 10
  and .job.estimate.by_size_s == ((268435456 * 0.8 / (1080 * 2288 * 10 / 4 / 8)) | floor) and .job.estimate.limit_s == 120'
jq '.hardware_video = true' "$H/.config/lianli/config.json" >"$T/cfg-hw" && cp "$H/.config/lianli/config.json" "$T/cfg-sw" && mv "$T/cfg-hw" "$H/.config/lianli/config.json"
run m prepare "$M/long.mp4" --for HydroShift2OledCurveLcd --out "$O/long-hw.mp4" --json
jc "hardware_video on: the w h fps / 4 bound joins in" '.job.estimate.by_hw_s == ((268435456 * 0.8 / (1080 * 2288 * 10 / 4 / 8)) | floor)
  and .job.estimate.limit_s == ([.job.estimate.max_s, .job.estimate.by_size_s, .job.estimate.by_speed_s, .job.estimate.by_hw_s] | min)'
mv "$T/cfg-sw" "$H/.config/lianli/config.json"
jq '.HydroShift2OledCurveLcd.transcode_cap_mb = 0.05' "$LIB/models.json" >"$T/models-small.json"
run env "${ENV[@]}" PCL_MODELS="$T/models-small.json" "$PCL" media prepare "$M/long.mp4" --for HydroShift2OledCurveLcd --out "$O/long-small.mp4" --json
jc "a small transcode cap: the size limit wins" '.job.estimate.method == "sampled" and .job.estimate.limit_s == .job.estimate.by_size_s
  and .job.estimate.limit_s < 120 and .job.recipe.duration == .job.estimate.limit_s'
jc "and the clip is that long at most" "(.duration - $(jq .job.estimate.limit_s <<<"$out")) < 0.2" "$(vinfo "$O/long-small.mp4")"

echo "# prepare into a draft: then set, clip-add, reuse"
run eng theme duplicate sakura sakura-2 --json
rcis "theme duplicate sakura sakura-2 (the draft)" 0
DF=$C/drafts/sakura-2.json
STAGE=$C/drafts/sakura-2.media
rev0=$(jq .rev "$DF")
run m prepare "$M/wide.mp4" --for screen.fan3 --draft sakura-2 --json
rcis "prepare --draft --then set (default): exit 0" 0
jc "done and applied: the draft's next rev" ".job.state == \"done\" and .job.then == \"set\" and .job.role == \"screen.fan3\" and .job.model == \"TlFlexLcd\"
  and .job.applied.rev == $((rev0 + 1)) and (.job.output.rel | test(\"^media/wide-[0-9a-f]{8}\\\\.mp4$\")) and .job.output.reused == false"
REL1=$(jq -r .job.output.rel <<<"$out") KEY1=$(jq -r .job.recipe.key <<<"$out")
check "the output is in the draft's stage" test -f "$STAGE/$REL1"
jc "the draft: the role uses it, the wait is over, provenance recorded" "(.pending_media // {} | has(\"screen.fan3\") | not)
  and .media_sources[\"$REL1\"].recipe.key == \"$KEY1\" and .rev == $((rev0 + 1))
  and ([.theme.screens | .. | objects | select(.path? == \"$REL1\")] | length) == 1" "$(cat "$DF")"
nstage=$(find "$STAGE" -type f | wc -l)
run m prepare "$M/wide.mp4" --for screen.fan3 --draft sakura-2 --json
jc "the same recipe again: reused, same file" ".job.state == \"done\" and .job.output.reused == true and .job.output.rel == \"$REL1\""
[[ $(find "$STAGE" -type f | wc -l) == "$nstage" ]] && ok "reuse: no new file in the stage" || bad "reuse: no new file in the stage"
jc "reuse: the draft doesn't wait for it" '(.pending_media // {} | has("screen.fan3") | not)' "$(cat "$DF")"
run m prepare "$M/wide.mp4" --for screen.fan3 --draft sakura-2 --crop 0,0,1080,1080 --json
jc "another crop: a new recipe and a new file" ".job.output.reused == false and .job.output.rel != \"$REL1\" and .job.recipe.key != \"$KEY1\""
run m prepare "$M/pump.mp4" --for screen.pump --draft sakura-2 --then clip-add --json
jc "clip-add: done and applied" '.job.then == "clip-add" and .job.state == "done" and .job.applied != null'
REL2=$(jq -r .job.output.rel <<<"$out")
jc "the pump's clips end with it" "(.theme.screens[\"screen.pump\"].clips | last) == \"$REL2\"" "$(cat "$DF")"
cp "$M/pump.mp4" "$T/pump-twin.mp4"
run m prepare "$T/pump-twin.mp4" --for screen.pump --draft sakura-2 --then none --json
jc "the same bytes from another file: the staged file is used (dedupe)" ".job.output.rel == \"$REL2\" and .job.output.reused == true"
jc "then none: done, the output waits for theme media set" '.job.then == "none" and .job.state == "done"'
revn=$(jq .rev "$DF")
T_CALL='md_load; editor_media_apply() { echo "pc-lights: the fan screens take square media, not this" >&2; return 2; }
  media_cmd prepare "$2" --for screen.fan1 --draft sakura-2 --crop 2,2,300,300 --json' run env "${ENV[@]}" "$PCL" status "$M/sq.mp4"
jc "the draft refuses the output (editor_media_apply 2): failed, not-applied, its reason" '.job.state == "failed"
  and .job.error == {code: "not-applied", text: "the fan screens take square media, not this"} and .job.applied == null
  and (.job.output.rel | type == "string")'
jc "... and the draft is unchanged" ".rev == $revn" "$(cat "$DF")"
T_CALL='md_load; editor_media_apply() { return 1; }
  media_cmd prepare "$2" --for screen.fan1 --draft sakura-2 --crop 4,4,300,300 --json' run env "${ENV[@]}" "$PCL" status "$M/sq.mp4"
jc "the draft waits for another job (editor_media_apply 1): cancelled, superseded" '.job.state == "cancelled"
  and .job.error.code == "superseded" and .job.applied == null'
run m prepare "$M/strip.mp4" --for UniversalScreen --draft sakura-2 --then set --json
rcis "--then set with a model (no role): 2 usage" 2 usage
run m prepare "$M/strip.mp4" --for screen.main --draft nosuch --json
rcis "a draft that doesn't exist: 2 not-found" 2 not-found
run env "${ENV[@]}" PCL_MEDIA_STAGE_CAP=1000 "$PCL" media prepare "$M/wide.mp4" --for screen.fan1 --draft sakura-2 --json
rcis "the drafts' stages over PCL_MEDIA_STAGE_CAP: 2 stage-full" 2 stage-full
run env "${ENV[@]}" PCL_MEDIA_STAGE_CAP=1000 "$PCL" media prepare "$M/wide.mp4" --for TlFlexLcd --out "$O/cap.mp4" --json
jc "the stage cap doesn't apply to --out" '.job.state == "done"'

echo "# jobs: progress, cancel, supersede, a vanishing draft"
cp "$M/long.mp4" "$T/slow1.mp4"
snap_jobs
env "${ENV[@]}" PCL_MEDIA_READRATE=4 "$PCL" media prepare "$T/slow1.mp4" --for screen.fan1 --draft sakura-2 --duration 24 --json >"$T/slow1.out" 2>&1 &
bgp=$!
fr=() id=
for _ in $(seq 1 300); do
  id=$(newjob)
  if [[ -n $id ]]; then fr+=("$(jq -r '.progress.frac' "$J/$id.json" 2>/dev/null || echo x)"); fi
  if ! kill -0 "$bgp" 2>/dev/null; then break; fi
  sleep 0.1
done
wait "$bgp" || true
fr+=("$(jq -r '.progress.frac' "$J/$id.json")")
mono=1 prev=0 distinct=$(printf '%s\n' "${fr[@]}" | sort -u | wc -l)
for f in "${fr[@]}"; do
  [[ $f == x ]] && continue
  if awk -v a="$f" -v b="$prev" 'BEGIN { exit !(a < b) }'; then mono=0; fi
  prev=$f
done
(( mono == 1 && distinct >= 4 )) && [[ ${fr[-1]} == 1 ]] && ok "progress only increases (${#fr[@]} samples, $distinct values, ends at 1)" || bad "progress only increases" "${fr[*]}"
jc "a 24 s window: done, 24 s long" '.job.state == "done" and .job.recipe.duration == 24' "$(cat "$T/slow1.out")"

cp "$M/long.mp4" "$T/slow2.mp4"
snap_jobs
env "${ENV[@]}" PCL_MEDIA_READRATE=2 "$PCL" media prepare "$T/slow2.mp4" --for screen.fan4 --draft sakura-2 --json >"$T/slow2.out" 2>&1 &
bgp=$!
id=
for _ in $(seq 1 200); do
  id=$(newjob)
  if [[ -n $id ]] && jq -e '.state == "encoding" and .progress.frac > 0.03' "$J/$id.json" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
jc "the draft waits for the running job" "(.pending_media[\"screen.fan4\"]) == \"$id\"" "$(cat "$DF")"
check "its scratch has a partial output" test -e "$K/media/work/$id/out.mp4"
run m cancel "$id" --json
jc "cancel: cancelled" ".cancelled == true and .id == \"$id\" and .state == \"cancelled\""
wait "$bgp" || true
jc "the runner ended it cancelled, no output" '.job.state == "cancelled" and .job.output == null and .job.error == null and .job.pid == null' "$(cat "$T/slow2.out")"
[[ ! -e $K/media/work/$id && -z $(find "$STAGE" -name 'slow2*' -o -name '*.tmp' | head -n1) && ! -e $J/$id.cancel ]] &&
  ok "cancel: no scratch, no partial file, no marker" || bad "cancel: no partial files"
jc "cancel: the draft no longer waits" '(.pending_media // {} | has("screen.fan4") | not)' "$(cat "$DF")"
run m cancel "$id" --json
jc "cancel again: idempotent" '.cancelled == true and .state == "cancelled"'
run m cancel j-1-1 --json
rcis "cancel an unknown job: 2 not-found" 2 not-found
run m cancel "$(jq -r .job.id "$T/slow1.out")" --json
jc "cancel a finished job: not cancelled, still done" '.cancelled == false and .state == "done"'

cp "$M/long.mp4" "$T/slow3.mp4"
snap_jobs
env "${ENV[@]}" PCL_MEDIA_READRATE=2 "$PCL" media prepare "$T/slow3.mp4" --for screen.fan5 --draft sakura-2 --json >"$T/slow3.out" 2>&1 &
bgp=$!
for _ in $(seq 1 200); do
  id=$(newjob)
  if [[ -n $id ]] && jq -e '.state == "encoding"' "$J/$id.json" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
run m prepare "$M/tiny.png" --for screen.fan5 --draft sakura-2 --json
jc "a newer prepare for the same screen: done" '.job.state == "done" and .job.recipe.mode == "still"'
wait "$bgp" || true
jc "the older one: cancelled, superseded" '.job.state == "cancelled" and .job.error.code == "superseded"' "$(cat "$T/slow3.out")"
jc "the draft took the newer one" "(.pending_media // {} | has(\"screen.fan5\") | not) and .theme.screens != null" "$(cat "$DF")"

run eng theme duplicate sakura sakura-3 --json
cp "$M/long.mp4" "$T/slow4.mp4"
snap_jobs
env "${ENV[@]}" PCL_MEDIA_READRATE=4 "$PCL" media prepare "$T/slow4.mp4" --for screen.fan2 --draft sakura-3 --duration 8 --json >"$T/slow4.out" 2>&1 &
bgp=$!
for _ in $(seq 1 200); do
  id=$(newjob)
  if [[ -n $id ]] && jq -e '.state == "encoding"' "$J/$id.json" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
rm -f "$C/drafts/sakura-3.json"
wait "$bgp" || true
jc "its draft vanished mid-job: failed no-draft, not applied" '.job.state == "failed" and .job.error.code == "no-draft" and .job.applied == null' "$(cat "$T/slow4.out")"
ORPH=$(jq -r .job.output.abs "$T/slow4.out")
check "the output stays in the job's scratch for GC" test -f "$ORPH"
run m gc --json
check "GC keeps an orphaned output younger than a day" test -f "$ORPH"
touch -d '2 days ago' "$K/media/work/$(jq -r .job.id "$T/slow4.out")"
run m gc --json
[[ ! -e $ORPH ]] && ok "GC removes an orphaned output after a day" || bad "GC removes an orphaned output after a day"

echo "# jobs and status --json (v1.3)"
run m jobs --draft sakura-2 --json
jc "media jobs --draft: the draft's jobs, newest first" '.v == 1 and (.jobs | length) >= 6 and all(.jobs[]; .draft == "sakura-2")
  and ([.jobs[].started] | . == (sort | reverse)) and .running == 0'
run m jobs --all --json
jc "media jobs --all: every record" '(.jobs | length) > 10 and any(.jobs[]; .draft == null)'
run eng status --json
jc "status --json: v_minor 3 and media" '.v == 1 and .v_minor >= 3 and (.media | has("running", "jobs")) and .media.running == 0
  and all(.media.jobs[]; keys == (["applied", "draft", "error", "id", "media_kind", "progress", "role", "state", "then"]))
  and (.media.jobs | length) <= 20'
jq '.state = "encoding" | .pid = 999999 | .unit = null | .ended = null' "$J/$(jq -r .job.id "$T/slow1.out").json" >"$J/j-1000-1.json"
jq '.id = "j-1000-1"' "$J/j-1000-1.json" >"$J/j-1000-1.t" && mv "$J/j-1000-1.t" "$J/j-1000-1.json"
run eng status --json
jc "status: a running job counts" '.media.running == 1 and any(.media.jobs[]; .id == "j-1000-1" and .state == "encoding")'
touch -d '1 minute ago' "$J/j-1000-1.json"
run m jobs --all --json
jc "a job whose runner is gone ends: failed, stopped" 'any(.jobs[]; .id == "j-1000-1" and .state == "failed" and .error.code == "stopped")'

echo "# GC: what it keeps"
mkdir -p "$STAGE/media"
cp "$M/sq.mp4" "$STAGE/media/unused-11111111.mp4"
cp "$M/sq.mp4" "$STAGE/media/live-22222222.mp4"
jq --arg p "$STAGE/media/live-22222222.mp4" '.lcds += [{serial: "hid:x", type: "video", path: $p}]' "$H/.config/lianli/config.json" >"$T/cfg" &&
  mv "$T/cfg" "$H/.config/lianli/config.json"
cp "$M/sq.mp4" "$STAGE/media/tpl-33333333.mp4"
jq --arg p "$STAGE/media/tpl-33333333.mp4" '.templates = [{id: "t", background: {type: "video", path: $p}}]' "$H/.config/lianli/lcd_templates.json" >"$T/tpl" &&
  mv "$T/tpl" "$H/.config/lianli/lcd_templates.json"
mkdir -p "$K/preview"; cp "$M/sq.mp4" "$STAGE/media/pv-44444444.mp4"
jq -n --arg p "$STAGE/media/pv-44444444.mp4" '{"hid:y": {type: "video", path: $p}}' >"$K/preview/applied-lcds.json"
# an editor-made theme file: unused (goes), used by history only (stays), used by the theme (stays); a hand-placed one (stays)
cp "$M/sq.mp4" "$TD/sakura/media/made-a.mp4"; cp "$M/wide.mp4" "$TD/sakura/media/made-hist.mp4"; cp "$M/strip.mp4" "$TD/sakura/media/made-used.mp4"
cp "$M/tiny.png" "$TD/sakura/media/hand.png"
jq -n '{v: 1, files: {"media/made-a.mp4": {source: "/x", model: "TlFlexLcd"}, "media/made-hist.mp4": {source: "/y"}, "media/made-used.mp4": {source: "/z"}}}' \
  >"$TD/sakura/src/media.json.new" && mv "$TD/sakura/src/media.json.new" "$TD/sakura/src/media.json"
ln "$TD/sakura/src/media.json" "$TD/hellfire/src/media.json.twin"
jq '.screens["screen.main"] = {type: "video", path: "media/made-used.mp4", model: "UniversalScreen"}' "$TD/sakura/theme.json" >"$T/th" && mv "$T/th" "$TD/sakura/theme.json"
mkdir -p "$C/theme-history/sakura"
jq '.screens["screen.main"] = {type: "video", path: "media/made-hist.mp4", model: "UniversalScreen"}' "$TD/sakura/theme.json" >"$C/theme-history/sakura/20260901T000000Z-aaaaaaaaaaaa.json"
all_before=$(find "$H" -type f -not -path "$K/*" -print0 | sort -z | xargs -0 sha256sum | sha256sum)
run m gc --dry-run --json
jc "gc --dry-run: the report" '.dry_run == true and (.deleted | type == "array") and (.freed_bytes | type == "number")
  and (.kept_referenced | type == "number") and (.unused_hand_placed | type == "array") and (.history_bytes > 0) and (.caches | has("thumbs", "frames", "jobs", "work"))'
GCOK='($refs | split("\n") | map(select(. != ""))) as $r
  | ([.deleted[] | split("/") | last] | index("made-a.mp4") != null and index("unused-11111111.mp4") != null)
  and all(.deleted[]; (split("/") | last) == "made-a.mp4" or (startswith($stage + "/") and (ltrimstr($stage + "/") | IN($r[]) | not)))'
DREFS=$(jq -r '.theme.screens | .. | objects | (.path? // empty), ((.clips? // [])[]) | strings' "$DF" | sort -u)
out=$(jq -c --arg refs "$DREFS" --arg stage "$STAGE" '. + {ok: ('"$GCOK"')}' <<<"$out")
jc "gc --dry-run: only unused stage files and the unused editor-made file" '.ok == true'
jc "gc --dry-run: hand-placed files are reported, never deleted" '[.unused_hand_placed[] | split("/") | last] == ["hand.png"]'
[[ $(find "$H" -type f -not -path "$K/*" -print0 | sort -z | xargs -0 sha256sum | sha256sum) == "$all_before" ]] && ok "gc --dry-run deletes nothing" || bad "gc --dry-run deletes nothing"
run m gc --json
out=$(jq -c --arg refs "$DREFS" --arg stage "$STAGE" '. + {ok: ('"$GCOK"')}' <<<"$out")
jc "gc: deletes only unused stage files and the unused editor-made file" '.ok == true'
for f in "$STAGE/media/live-22222222.mp4" "$STAGE/media/tpl-33333333.mp4" "$STAGE/media/pv-44444444.mp4" \
         "$TD/sakura/media/made-hist.mp4" "$TD/sakura/media/made-used.mp4" "$TD/sakura/media/hand.png" "$TD/sakura/media/fan-a.mp4"; do
  check "gc kept ${f#"$H"/} (referenced or hand-placed)" test -f "$f"
done
while IFS= read -r f; do check "gc kept the draft's ${f##*/}" test -f "$f"; done < <(jq -r --arg s "$STAGE" '.theme.screens | .. | objects | .path? // empty | select(startswith("media/")) | $s + "/" + .' "$DF" |
  while IFS= read -r p; do [[ -f $p ]] && echo "$p"; done | sort -u)
jc "gc: the theme's provenance loses the deleted file (a new inode; the twin keeps its bytes)" '.files | has("media/made-a.mp4") | not' "$(cat "$TD/sakura/src/media.json")"
jc "the hard-linked twin still lists it" '.files | has("media/made-a.mp4")' "$(cat "$TD/hellfire/src/media.json.twin")"
# a running job's output and a then-none output wait
id=$(jq -r .job.id <<<"$(m prepare "$M/strip.mp4" --for screen.main --draft sakura-2 --then none --json)")
NONE=$(jq -r .output.abs "$J/$id.json")
run m gc --json
check "gc keeps a then-none output until it is used" test -f "$NONE"
cp "$M/sq.mp4" "$STAGE/media/running-55555555.mp4"
jq --arg a "$STAGE/media/running-55555555.mp4" '.id = "j-1000-2" | .state = "finishing" | .output = {rel: "media/running-55555555.mp4", abs: $a}
  | .pid = '"$$"' | .unit = null | .ended = null' "$J/$id.json" >"$J/j-1000-2.json"
run m gc --json
check "gc keeps the output of a job that is finishing" test -f "$STAGE/media/running-55555555.mp4"
jq '.state = "done" | .applied = {rev: 1, at: 1} | .then = "set"' "$J/j-1000-2.json" >"$J/j-1000-2.t" && mv "$J/j-1000-2.t" "$J/j-1000-2.json"
run m gc --json
[[ ! -e $STAGE/media/running-55555555.mp4 ]] && ok "gc: once applied (and unused), it goes" || bad "gc: once applied (and unused), it goes"

echo "# GC: a discarded draft, caches"
run eng theme duplicate sakura sakura-4 --json
run m prepare "$M/sq.mp4" --for screen.fan1 --draft sakura-4 --crop 0,0,200,200 --json
check "sakura-4 has a stage" test -d "$C/drafts/sakura-4.media/media"
run eng theme discard sakura-4 --json
[[ ! -e $C/drafts/sakura-4.media ]] && ok "discard: media_gc_draft removed its stage" || bad "discard: stage removed" "$(find "$C/drafts/sakura-4.media" 2>/dev/null)"
mkdir -p "$K/media/frames/old"; : >"$K/media/frames/old/1-960.jpg"; touch -d '2 days ago' "$K/media/frames/old/1-960.jpg"
jq '.id = "j-1000-3" | .state = "done" | .ended = 1000' "$J/j-1000-2.json" >"$J/j-1000-3.json"
run env "${ENV[@]}" PCL_MEDIA_THUMB_CAP=4000 "$PCL" media gc --json
jc "gc caches: an old frame, a week-old job, thumbnails over the cap" '.caches.frames >= 1 and .caches.jobs >= 1 and .caches.thumbs >= 1'
[[ ! -e $K/media/frames/old/1-960.jpg && ! -e $J/j-1000-3.json ]] && ok "gc caches: gone" || bad "gc caches: gone"
tb=$(find "$K/thumbs" -type f -name '*.webp' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
(( tb <= 4000 )) && ok "thumbnails trimmed to the cap ($tb bytes)" || bad "thumbnails trimmed to the cap" "$tb"

echo "# rename carries the jobs"
run eng theme duplicate sakura sakura-5 --json
run m prepare "$M/sq.mp4" --for screen.fan1 --draft sakura-5 --crop 0,0,300,300 --json
jid=$(jq -r .job.id <<<"$out")
run ecall "media_rename_draft sakura-5 sakura-6"
jc "media_rename_draft: the record follows" '.draft == "sakura-6"' "$(cat "$J/$jid.json")"

if command systemctl --user show-environment >/dev/null 2>&1; then
  echo "# a job in its own unit (user systemd)"
  mkdir -p "$T/uslots"
  mkfifo "$T/release"
  ( exec 9>"$T/uslots/slot0"; flock 9; read -r _ <"$T/release" ) &
  holder=$!
  sleep 0.3
  UENV=(HOME="$H" PCL_HEAVY_DIR="$T/uslots" PCL_HEAVY_SLOTS=1 PCL_MEDIA_UNIT="$UNITP" PCL_TEST_OVERRIDES="$T/over.sh" PCL_MEDIA_INDEX=off)
  run env "${UENV[@]}" "$PCL" media prepare "$M/wide.mp4" --for screen.fan2 --draft sakura-2 --crop 10,10,500,500 --json
  jc "prepare in a unit: queued at once, with its unit" ".job.state == \"queued\" and .job.unit == \"$UNITP-\" + .job.id"
  uid=$(jq -r .job.id <<<"$out") unit=$(jq -r .job.unit <<<"$out")
  for _ in $(seq 1 50); do [[ $(jq -r .state "$J/$uid.json") == waiting ]] && break; sleep 0.2; done
  jc "no free slot: waiting" '.state == "waiting"' "$(cat "$J/$uid.json")"
  props=$(command systemctl --user show "$unit.service" -p MemoryMax -p CPUWeight -p Nice -p KillMode -p RuntimeMaxUSec -p ActiveState)
  grep -q '^CPUWeight=20$' <<<"$props" && grep -q '^MemoryMax=[0-9]' <<<"$props" && grep -q '^Nice=10$' <<<"$props" &&
    grep -q '^KillMode=control-group$' <<<"$props" && grep -q '^ActiveState=active$' <<<"$props" &&
    ok "the unit: MemoryMax, CPUWeight=20, Nice 10, KillMode control-group" || bad "the unit's properties" "$props"
  run env "${UENV[@]}" "$PCL" media cancel "$uid" --json
  jc "cancel stops the unit" '.cancelled == true'
  command systemctl --user is-active -q "$unit.service" && bad "the unit is gone after the cancel" || ok "the unit is gone after the cancel"
  echo release >"$T/release"
  wait "$holder" 2>/dev/null || true
  run env "${UENV[@]}" "$PCL" media prepare "$M/strip.mp4" --for screen.main --draft sakura-2 --then none --crop 0,0,1920,480 --json
  uid=$(jq -r .job.id <<<"$out")
  for _ in $(seq 1 150); do st=$(jq -r .state "$J/$uid.json"); [[ $st == "done" || $st == failed || $st == cancelled ]] && break; sleep 0.2; done
  jc "a job in its unit runs to the end" '.state == "done" and .output.rel != null' "$(cat "$J/$uid.json")"
else
  skip "a job in its own unit (no user systemd)"
fi

echo "# the sources never change"
src_state >"$T/src.after"
if diff "$T/src.before" "$T/src.after" >"$T/src.diff"; then ok "every source: same bytes, mtime and link count; nothing new beside them"
else bad "the sources changed" "$(head -20 "$T/src.diff")"; fi
if [[ -s $H/stub.log ]]; then
  echo "note: calls the stubs refused (none may reach the hardware): $(sort -u "$H/stub.log" | head -c 300 | tr '\n' ';')"
fi

echo
echo "# $passed passed, $failed failed, $skipped skipped"
(( failed == 0 ))
