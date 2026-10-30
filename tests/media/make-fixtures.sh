#!/usr/bin/env bash
# tests/media/make-fixtures.sh <dir> — the media tests/media/run.sh works on,
# made on the fly from ffmpeg lavfi patterns (a few seconds; nothing is
# committed, nothing personal). A file that is already there is kept, so a
# dir can be reused between runs (PCL_MEDIA_FIXTURES). Every ffmpeg and
# magick call goes through pcl-heavy (its own capped cgroup) when there is
# one, unless run.sh already runs inside one (PCL_MEDIA_TEST_HEAVY).
#
#   sq.mp4        testsrc2 400x400, 2 s, h264 yuv420p      exact fan fit (remux)
#   wide.mp4      1920x1080 at 60 fps, 2 s                  fps cap, 16:9 crop
#   pump.mp4      2288x1080, 2 s                            exact pump fit
#   strip.mp4     1920x480, 2 s                             exact 8.8" fit
#   long.mp4      blue 2288x1080, 200 s, 10 fps, crf 40     trim and estimate
#   inter.mp4     720x576 interlaced (top field first)      yadif
#   portrait.mov  stored 1920x1080 (left red, right blue), rotated 90 on display
#   quad.png      4000x3000, red | lime over blue | yellow   crop correctness
#   alpha.png     400x300, transparent round a lime square  flattened to black
#   alpha.mov     qtrle argb 640x480, 2 s, transparent corners
#   anim.gif      10 frames; still.gif one frame
#   tiny.png      64x64                                     low-res
#   huge.jpg      9000x6000                                 a large image
#   exif6.jpg     stored 600x400 with EXIF orientation 6 (400x600 on display)
#   audio.mp4     a sine only                               no-picture
#   broken.mp4    4 KiB of deterministic junk               broken
#   empty.mp4     0 bytes
#   "name with space -x.mp4", "new<LF>line.mp4"            odd names (copies of sq.mp4)
#   hevc10.mkv    only with libx265: 10-bit PQ              the hdr path
set -euo pipefail
out=${1:?usage: make-fixtures.sh <dir>}
mkdir -p "$out"
# (run.sh already holds a slot for the whole run: a nested pcl-heavy would
# wait for a second one)
heavy=()
if [[ -z ${PCL_MEDIA_TEST_HEAVY:-} ]] && command -v pcl-heavy >/dev/null 2>&1; then heavy=(pcl-heavy); fi
ff() { "${heavy[@]}" ffmpeg -nostdin -hide_banner -v error -y "$@"; }
# mk <name> <cmd...>: make it unless it is there (written to a temp name first).
mk() {
  local n=$1; shift
  [[ -s $out/$n ]] && return 0
  "$@" || { echo "make-fixtures: could not make $n" >&2; return 1; }
}
x264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -movflags +faststart)

mk sq.mp4 ff -f lavfi -i testsrc2=s=400x400:r=30:d=2 "${x264[@]}" "$out/sq.mp4"
mk wide.mp4 ff -f lavfi -i testsrc2=s=1920x1080:r=60:d=2 "${x264[@]}" "$out/wide.mp4"
mk pump.mp4 ff -f lavfi -i testsrc2=s=2288x1080:r=30:d=2 "${x264[@]}" "$out/pump.mp4"
mk strip.mp4 ff -f lavfi -i testsrc2=s=1920x480:r=30:d=2 "${x264[@]}" "$out/strip.mp4"
mk long.mp4 ff -f lavfi -i color=c=blue:s=2288x1080:r=10:d=200 -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p \
  -movflags +faststart "$out/long.mp4"
mk inter.mp4 ff -f lavfi -i testsrc2=s=720x576:r=25:d=2 -vf setfield=tff -c:v libx264 -flags +ildct+ilme -x264opts tff=1 \
  -pix_fmt yuv420p "$out/inter.mp4"
if [[ ! -s $out/portrait.mov ]]; then
  ff -f lavfi -i "color=c=red:s=1920x1080:r=30:d=2,drawbox=x=960:y=0:w=960:h=1080:color=blue:t=fill" "${x264[@]}" "$out/.land.mp4"
  ff -display_rotation:v:0 90 -i "$out/.land.mp4" -c copy "$out/portrait.mov"
  rm -f "$out/.land.mp4"
fi
mk quad.png "${heavy[@]}" magick -size 2000x1500 xc:red xc:lime +append \( -size 2000x1500 xc:blue xc:yellow +append \) -append \
  "$out/quad.png"
mk alpha.png "${heavy[@]}" magick -size 400x300 xc:none -fill lime -draw "rectangle 150,100 250,200" "PNG32:$out/alpha.png"
mk alpha.mov ff -f lavfi -i "color=c=black:s=640x480:r=30:d=2,format=rgba,geq=r=0:g=255:b=0:a='255*gt(X,160)*lt(X,480)*gt(Y,120)*lt(Y,360)'" \
  -c:v qtrle -pix_fmt argb "$out/alpha.mov"
mk anim.gif ff -f lavfi -i testsrc2=s=200x150:r=10:d=1 "$out/anim.gif"
mk still.gif ff -f lavfi -i testsrc2=s=200x150:r=10:d=1 -frames:v 1 "$out/still.gif"
mk tiny.png ff -f lavfi -i testsrc2=s=64x64 -frames:v 1 "$out/tiny.png"
mk huge.jpg ff -f lavfi -i "gradients=s=9000x6000:c0=0x203040:c1=0xff8040:seed=1" -frames:v 1 -q:v 8 "$out/huge.jpg"
if [[ ! -s $out/exif6.jpg ]]; then
  ff -f lavfi -i "color=c=red:s=600x400,drawbox=x=0:y=0:w=300:h=400:color=blue:t=fill" -frames:v 1 -q:v 3 "$out/.plain.jpg"
  # an APP1 Exif segment with Orientation = 6 right after SOI
  python3 - "$out/.plain.jpg" "$out/exif6.jpg" <<'PY'
import struct, sys
src = open(sys.argv[1], 'rb').read()
tiff = b'II*\x00' + struct.pack('<I', 8) + struct.pack('<H', 1) + struct.pack('<HHII', 0x0112, 3, 1, 6) + struct.pack('<I', 0)
app1 = b'Exif\x00\x00' + tiff
open(sys.argv[2], 'wb').write(src[:2] + b'\xff\xe1' + struct.pack('>H', len(app1) + 2) + app1 + src[2:])
PY
  rm -f "$out/.plain.jpg"
fi
mk audio.mp4 ff -f lavfi -i sine=frequency=440:duration=2 -c:a aac "$out/audio.mp4"
if [[ ! -s $out/broken.mp4 ]]; then
  # "ftyp" then junk: looks like an MP4 to a name check, isn't one
  { printf '\0\0\0\30ftypisom\0\0\2\0'; head -c 4072 < <(yes 'lumenaire media test junk 0123456789'); } >"$out/broken.mp4"
fi
: >"$out/empty.mp4"
[[ -s "$out/name with space -x.mp4" ]] || cp "$out/sq.mp4" "$out/name with space -x.mp4"
[[ -s "$out/new"$'\n'"line.mp4" ]] || cp "$out/sq.mp4" "$out/new"$'\n'"line.mp4"
if [[ $(ffmpeg -hide_banner -encoders 2>/dev/null || true) == *" libx265 "* ]]; then
  mk hevc10.mkv ff -f lavfi -i testsrc2=s=640x360:r=30:d=2 \
    -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc -c:v libx265 -preset ultrafast \
    -pix_fmt yuv420p10le -x265-params log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc "$out/hevc10.mkv"
fi
echo "make-fixtures: $(find "$out" -maxdepth 1 -type f | wc -l) files in $out"
