#!/usr/bin/env python3
"""Make the screen-editor render thumbnails from the committed theme previews.

The theme previews in tests/fixtures/previews/ (684x267, drawn by make.py there) hold five fan
screens (top left), the pump (top right, about 2.15:1) and the 8.8" strip
(bottom, about 4:1). This cuts them into small webp thumbnails the way the
engine keeps them (the long side at most 256 px), plus a few "photos" of
other shapes for My files and the frame grabs the crop page shows, so the
UI fixtures (tests/fixtures/{editor-screens*,screen-*,picker-*,crop-*}.json)
look like real media without shipping any. Needs Pillow; the outputs are
committed, so tests/render.py needs neither this nor ffmpeg.

  python tests/ui/make-thumbs.py
"""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]
src = root / 'tests/fixtures/previews'
out = Path(__file__).resolve().parent / 'thumbs'
out.mkdir(exist_ok=True)


def save(im, name, q=70):
    im = im.convert('RGB')
    if max(im.size) > 256 and not name.endswith('.jpg'):
        im.thumbnail((256, 256), Image.LANCZOS)
    if name.endswith('.jpg'):
        im.save(out / name, quality=82)
    else:
        im.save(out / name, 'WEBP', quality=q, method=6)


# The cuts the fixtures use: theme -> fan screens (1-5), pump, strip.
CUTS = {'sakura': ([1, 2, 3, 4, 5], True, True), 'arctic': ([1, 2, 3, 4], False, False), 'cyberpunk': ([3], True, False),
        'toxic': ([2], True, False), 'synthwave': ([], True, True), 'abyss': ([], True, False), 'hellfire': ([], True, False),
        'gilded-noir': ([], True, False)}
for theme, (fans, pump, strip) in CUTS.items():
    im = Image.open(src / f'{theme}.webp').convert('RGB')
    # The five fan screens, 96 px apart.
    for i in fans:
        save(im.crop(((i - 1) * 96 + 1, 1, (i - 1) * 96 + 95, 95)), f'{theme}-fan{i}.webp')
    if pump:
        save(im.crop((482, 1, 683, 95)), f'{theme}-pump.webp')
    if strip:
        save(im.crop((0, 97, 684, 267)), f'{theme}-strip.webp')

# "Photos" of other shapes, from the strips' scenery (My files).
def strip(theme):
    return Image.open(src / f'{theme}.webp').convert('RGB').crop((0, 97, 684, 267))

save(strip('arctic').crop((300, 0, 602, 170)).resize((384, 216), Image.LANCZOS), 'photo-wide-arctic.webp')
save(strip('synthwave').crop((250, 0, 552, 170)).resize((384, 216), Image.LANCZOS), 'photo-wide-synthwave.webp')
save(strip('toxic').crop((360, 0, 587, 170)).resize((256, 192), Image.LANCZOS), 'photo-43-toxic.webp')
save(strip('hellfire').crop((420, 0, 516, 170)).resize((144, 256), Image.LANCZOS), 'photo-tall-hellfire.webp')
save(strip('abyss').crop((40, 20, 104, 84)), 'photo-tiny-abyss.webp')

# Frame grabs for the crop page (media frame --json: at most 960 px).
Image.open(out / 'photo-wide-arctic.webp').resize((640, 360), Image.LANCZOS).save(out / 'frame-wide-arctic.jpg', quality=82)
Image.open(out / 'photo-43-toxic.webp').resize((640, 480), Image.LANCZOS).save(out / 'frame-43-toxic.jpg', quality=82)
Image.open(out / 'photo-tiny-abyss.webp').save(out / 'frame-tiny-abyss.jpg', quality=90)
Image.open(out / 'photo-wide-synthwave.webp').resize((640, 360), Image.LANCZOS).save(out / 'frame-wide-synthwave.jpg', quality=82)
print(len(list(out.iterdir())), 'files,', sum(p.stat().st_size for p in out.iterdir()) // 1024, 'KiB')
