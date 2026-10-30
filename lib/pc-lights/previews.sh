# lib/pc-lights/previews.sh — preview images for the plugin (~/.cache/pc-lights/previews)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP6 (JSON v1.1, sensors, previews)
# Public: previews build_preview preview_stale pump_serials grab seek_of is_video heavy
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# ---- preview images for the plugin ------------------------------------------
# previews/<name>.webp, 684x267: the five fan screens (96x96, 3-fan group then
# 2-fan group, repeated in order if a theme has fewer) and the pump (204x96)
# across the top, the 8.8" screen (684x171) below. Screen art only: the plugin
# draws the LED colours itself from "themes --json". Every ffmpeg/magick call
# goes through pcl-heavy (own capped cgroup), one at a time, and nothing is
# written into the theme folders. <name>.json is the stamp: the sha256 of
# theme.json and [path, mtime, size] of every input.
# heavy <cmd...>: pcl-heavy beside the engine (a checkout or the plugin
# folder), else on PATH (waiting at most 120 s for a slot), else the media
# pipeline's capped scope (media.sh media_capped), else plain nice: never in
# the caller's cgroup when there is any way around it.
heavy() {
  local h
  h=$(dirname "$(readlink -f "$0")")/pcl-heavy
  if [[ -x $h ]]; then PCL_HEAVY_WAIT=120 "$h" "$@"
  elif h=$(command -v pcl-heavy 2>/dev/null); then PCL_HEAVY_WAIT=120 "$h" "$@"
  elif declare -F media_capped >/dev/null; then media_capped "$@"
  else nice -n 10 "$@"; fi
}

preview_stale() {
  local d=$THEME_DIR/$1 w=$PREVIEWS/$1.webp
  [[ -f $w && -f $PREVIEWS/$1.json ]] || return 0
  [[ -n $(find "$d/theme.json" "$d/media" "$d/us88" "$d/src/preview-us88.jpg" -newer "$w" -print -quit 2>/dev/null) ]]
}

is_video() { [[ ${1,,} =~ \.(mp4|mov|webm|mkv|gif)$ ]]; }

# seek_of <src>: a third of the way into a video, 0 for anything else.
seek_of() {
  local dur
  if [[ -f $1 ]] && is_video "$1"; then
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)
    if [[ $dur =~ ^[0-9]+(\.[0-9]+)?$ ]]; then awk -v d="$dur" 'BEGIN { printf "%.3f\n", d / 3 }'; return 0; fi
  fi
  echo 0
}

# grab <src> <w> <h> <out> [seek]: one frame scaled to cover w x h and
# centre-cropped; black if the source is missing or unreadable. The
# one-tile-at-a-time fallback for build_preview.
grab() {
  local src=$1 w=$2 h=$3 out=$4 ss=${5:-0}
  if [[ -f $src ]] && is_video "$src"; then
    heavy ffmpeg -nostdin -v error -y -ss "$ss" -i "$src" -frames:v 1 -update 1 \
      -vf "scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h" "$out" 2>/dev/null ||
      log "previews: could not grab a frame of $src"
  elif [[ -f $src ]]; then
    heavy magick "${src}[0]" -resize "${w}x${h}^" -gravity center -extent "${w}x${h}" "$out" 2>/dev/null ||
      log "previews: could not read $src"
  fi
  [[ -s $out ]] || heavy magick -size "${w}x${h}" xc:black "$out"
}

# pump_serials: the USB serials of the pump screens, one per line. The
# profile's screen.pump role first; without a profile, every HydroShift II
# LCD (1cbe:a068) on USB. build_preview also takes a screen whose _where
# names a pump, so a theme made elsewhere still finds its pump tile.
pump_serials() {
  local d v p s pf
  pf=$(profile_file)
  if [[ -f $pf ]]; then
    jq -r '(.devices // {}) as $dev | (.roles // {}) | to_entries[]
      | select(.key == "screen.pump") | .value.device // empty
      | $dev[.].match.usb_serial // ltrimstr("lianli:lcd:")' "$pf" 2>/dev/null || true
    return 0
  fi
  for d in "$SENSORS_SYS"/bus/usb/devices/*; do
    [[ -r $d/idVendor && -r $d/idProduct && -r $d/serial ]] || continue
    read -r v <"$d/idVendor" || continue
    read -r p <"$d/idProduct" || continue
    if [[ $v == 1cbe && $p == a068 ]] && read -r s <"$d/serial"; then echo "$s"; fi
  done
  return 0
}

# build_preview <name>: reads the theme's compiled EFF (risk 14: a v3
# theme.json has no screens[] with serials; the EFF does). Paths in it stay
# relative to the theme folder. The stamp keeps the sha256 of theme.json,
# which is what preview_stale and the plugin compare.
build_preview() {
  local name=$1 root=$THEME_DIR/$1 sf=$THEME_DIR/$1/theme.json w=$TMP/preview-$1 out=$PREVIEWS/$1.webp
  local kind p fans=() pump= tpl= bg= strip= i n size args=() fg= srcs=() sizes=() seeks=() inputs=() eff
  mkdir -p "$w"
  eff=$(eff_file "$name")
  [[ -f $eff ]] || eff=$sf
  while IFS=$'\t' read -r kind p; do
    case $kind in
      fan) fans+=("$p") ;;
      pump) [[ -n $pump ]] || pump=$p ;;
      tpl) [[ -n $tpl ]] || tpl=$p ;;
    esac
  done < <(jq -r --arg root "$root" --arg pumps "$(pump_serials)" '
    def abs: if startswith("/") then . else $root + "/" + . end;
    ($pumps | split("\n") | map(select(length > 0))) as $pump
    | ((.screens // [])[] | select(.type != "custom" and (.path | type) == "string")
      | if (.serial | IN($pump[])) or ((._where // "") | test("pump|HydroShift"; "i")) then "pump" else "fan" end
        + "\t" + (.path | abs)),
    ((.templates // [])[] | strings | "tpl\t" + abs)' "$eff" 2>/dev/null || true)
  if [[ -f $tpl ]]; then
    bg=$(jq -r '.background.path // empty' "$tpl" 2>/dev/null || true)
    if [[ -n $bg && $bg != /* ]]; then bg=$root/$bg; fi
  fi
  # The 8.8" strip: a real template render if it is newer than the template,
  # else the template's background (an image, or the first frame of a video),
  # else any us88 background image, else black.
  if [[ -f $root/src/preview-us88.jpg && ( -z $tpl || $root/src/preview-us88.jpg -nt $tpl ) ]]; then
    strip=$root/src/preview-us88.jpg
  elif [[ -n $bg && -f $bg ]]; then
    strip=$bg
  else
    strip=$(compgen -G "$root/us88/*background*.png" | head -n1 || true)
  fi
  # Seven sources: five fans (repeated in order when there are fewer), the
  # pump, the strip. Videos are grabbed a third of the way in, the strip at
  # its first frame; the (light) duration probes run side by side.
  n=${#fans[@]}
  for i in 0 1 2 3 4; do
    if (( n > 0 )); then srcs+=("${fans[i % n]}"); else srcs+=(""); fi
    sizes+=(96x96)
  done
  srcs+=("$pump" "$strip"); sizes+=(204x96 684x171)
  for i in 0 1 2 3 4 5; do seek_of "${srcs[i]}" >"$w/seek$i" & done
  wait
  for i in 0 1 2 3 4 5; do seeks+=("$(cat "$w/seek$i")"); done
  seeks+=(0)
  # One ffmpeg decodes all seven and stacks them (missing ones are black)...
  for i in 0 1 2 3 4 5 6; do
    size=${sizes[i]}
    if [[ -f ${srcs[i]} ]] && is_video "${srcs[i]}"; then args+=(-ss "${seeks[i]}" -i "${srcs[i]}")
    elif [[ -f ${srcs[i]} ]]; then args+=(-i "${srcs[i]}")
    else args+=(-f lavfi -i "color=c=black:s=$size:d=1"); fi
    fg+="[$i:v]scale=${size%x*}:${size#*x}:force_original_aspect_ratio=increase,crop=${size%x*}:${size#*x},setsar=1,format=rgb24[t$i];"
  done
  fg+="[t0][t1][t2][t3][t4][t5]hstack=inputs=6[top];[top][t6]vstack=inputs=2"
  if ! heavy ffmpeg -nostdin -v error -y "${args[@]}" -filter_complex "$fg" -frames:v 1 -update 1 \
      "$w/all.png" 2>/dev/null || [[ ! -s $w/all.png ]]; then
    # ...or, if one source trips it up, one tile at a time.
    for i in 0 1 2 3 4 5 6; do
      grab "${srcs[i]}" "${sizes[i]%x*}" "${sizes[i]#*x}" "$w/t$i.png" "${seeks[i]}"
    done
    heavy magick \( "$w"/t{0..5}.png +append \) "$w/t6.png" -append "$w/all.png" || true
  fi
  if ! [[ -s $w/all.png ]] || ! heavy magick "$w/all.png" -quality 82 "webp:$out.tmp"; then
    rm -rf "$out.tmp" "$w"
    log "previews: composing $name failed"
    return 1
  fi
  mv -f "$out.tmp" "$out"
  for p in "$sf" "${srcs[@]}"; do [[ -n $p && -f $p ]] && inputs+=("$p"); done
  stat --printf '%n\t%Y\t%s\n' "${inputs[@]}" 2>/dev/null | awk '!seen[$0]++' |
    jq -Rn --arg sha "$(sha256sum <"$sf" | cut -d' ' -f1)" '
      {theme_sha256: $sha, inputs: [inputs | split("\t") | [.[0], (.[1] | tonumber), (.[2] | tonumber)]]}' |
    put_json "$PREVIEWS/$name.json"
  rm -rf "$w"
  echo "previews: $name -> $out"
}

previews() {
  local a force= names=() built=0 t0=$EPOCHSECONDS
  # One build at a time; a second request while one runs has nothing to add.
  exec 6>"$CACHE/previews.lock"
  flock -n 6 || { echo "pc-lights: previews: another build is running" >&2; exit 0; }
  for a in "$@"; do
    if [[ $a == --force ]]; then force=1; continue; fi
    theme_exists "$a" || die "no theme $THEME_DIR/$a/theme.json"
    names+=("$a")
  done
  if (( ${#names[@]} == 0 )); then
    for a in "$THEME_DIR"/*/theme.json; do
      if [[ -f $a ]]; then a=${a%/theme.json}; names+=("${a##*/}"); fi
    done
  fi
  for a in "${names[@]}"; do
    [[ -n $force ]] || preview_stale "$a" || continue
    if build_preview "$a"; then built=$((built + 1)); fi
  done
  if (( built > 0 )); then log "previews: built $built in $((EPOCHSECONDS - t0)) s"; fi
}
