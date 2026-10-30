#!/usr/bin/env bash
# tests/fixtures/media/make.sh — the small images the media fixtures point at
# (tests/fixtures/media.*.json: "thumb" and "path" are relative to
# tests/fixtures), so the render harness (tests/render.py) needs no ffmpeg.
# They are committed; run this only to rebuild them. Every source is an
# ffmpeg lavfi pattern (no real media, nothing personal), then made the way
# the engine makes them (lib/pc-lights/media.sh): thumbnails are webp, 256 px
# on the long side, quality 70; crop frames are JPEG, 960 px at most.
#
#   tests/fixtures/media/make.sh [out dir]   (default: this folder)
set -euo pipefail
out=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
mkdir -p "$out"
heavy=()
if command -v pcl-heavy >/dev/null 2>&1; then heavy=(pcl-heavy); fi
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# src <name> <lavfi graph>: one frame of the pattern as a PNG in $w.
src() { "${heavy[@]}" ffmpeg -nostdin -v error -y -f lavfi -i "$2" -frames:v 1 "$w/$1.png"; }
# thumb <src> <out.webp>: the engine's thumbnail.
thumb() {
  "${heavy[@]}" ffmpeg -nostdin -v error -y -i "$w/$1.png" -frames:v 1 \
    -vf scale=256:256:force_original_aspect_ratio=decrease -c:v libwebp -quality 70 "$out/$2"
}
# frame <src> <out.jpg>: the engine's crop frame (long side at most 960).
frame() {
  "${heavy[@]}" ffmpeg -nostdin -v error -y -i "$w/$1.png" -frames:v 1 \
    -vf "scale='if(gte(iw,ih),min(960,iw),-2)':'if(gte(iw,ih),-2,min(960,ih))'" -q:v 6 "$out/$2"
}

src pump "gradients=s=2288x1080:c0=0x2a0a4a:c1=0x00c8ff:c2=0xff3aa0:x0=0:y0=0:x1=2288:y1=1080:seed=7,drawbox=x=900:y=300:w=500:h=480:color=white@0.35:t=fill"
src pump-theme "mandelbrot=s=2288x1080:maxiter=120:start_scale=2.4"
src pump-upload "gradients=s=2280x1080:c0=0x001020:c1=0x00ffaa:c2=0x650370:seed=3"
src alpha-overlay "color=c=black:s=1080x1392,drawbox=x=240:y=396:w=600:h=600:color=0x00d8ff:t=40,drawbox=x=390:y=546:w=300:h=300:color=0xff4a9a:t=30"
src wide "testsrc2=s=1920x1080"
src fan "mandelbrot=s=400x400:maxiter=90:start_x=-0.75:start_y=0.1:start_scale=0.6"
src fan-a "gradients=s=400x400:c0=0xff4a9a:c1=0x1a0010:x0=200:y0=200:x1=0:y1=0:type=radial:seed=1"
src fan-b "smptebars=s=400x400"
src strip "gradients=s=1920x480:c0=0x0b0020:c1=0xff1a70:c2=0x7a1aff:x0=0:y0=240:x1=1920:y1=240:seed=5"
src picture "color=c=red:s=800x600,drawbox=x=400:y=0:w=400:h=300:color=lime:t=fill,drawbox=x=0:y=300:w=400:h=300:color=blue:t=fill,drawbox=x=400:y=300:w=400:h=300:color=yellow:t=fill"
src portrait "gradients=s=1080x1920:c0=0xff9a30:c1=0x200008:x0=540:y0=0:x1=540:y1=1920:seed=9"
src tiny "testsrc2=s=64x64"

thumb pump pump-clip.webp
thumb pump-theme pump-theme.webp
thumb pump-upload pump-upload.webp
thumb alpha-overlay alpha-overlay.webp
thumb wide wide.webp
thumb fan fan-clip.webp
thumb fan-a fan-a.webp
thumb fan-b fan-b.webp
thumb strip strip.webp
thumb picture picture.webp
thumb portrait portrait.webp
frame wide frame-wide.jpg
frame picture frame-picture.jpg
frame portrait frame-portrait.jpg
frame tiny frame-tiny.jpg
ls -l "$out"
