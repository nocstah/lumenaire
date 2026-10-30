# Screen media

`lumenaire media` finds pictures and videos for the LCD screens, reads what
they are, shows a frame to crop on, and prepares a copy that fits a screen
exactly. The theme editor (`lumenaire theme screens`, `theme media ...`, see
[THEMES.md](THEMES.md)) and the plugin's Screen page are built on it. The code
is `lib/pc-lights/media.sh` and its jq half `lib/pc-lights/media.jq`.

Nothing here writes next to a source file, changes one, or talks to the
lian-li-linux daemon. Prepared media go to the draft's stage (or a file you
name); the preview and a save put them on the case.

- [Why media is prepared](#why-media-is-prepared)
- [Commands](#commands)
- [The JSON answers](#the-json-answers)
- [Fit and crop](#fit-and-crop)
- [How a file is prepared](#how-a-file-is-prepared)
- [Jobs](#jobs)
- [The index and thumbnails](#the-index-and-thumbnails)
- [Files](#files)
- [GC](#gc)
- [With the editor](#with-the-editor)
- [Testing](#testing)

## Why media is prepared

The daemon stretches whatever it gets to the panel (`scale=W:H`, then the
screen's orientation): it never crops. It also transcodes every video again
on each load, with libx264 `ultrafast` and no bitrate cap, into a temp file
of at most 256 MiB that must be done within 120 s, and plays at most 30 fps
here (`default_fps`). So a file is only safe on a screen when it already has
that screen's exact size and a length the daemon can transcode. Preparing
makes such a copy:

| Model | Size | fps | Longest clip | libx264 | Stills |
| --- | --- | --- | --- | --- | --- |
| TL / SL fan LCDs | 400 x 400 | 30 | 120 s | crf 20, 4M | PNG or JPEG |
| HydroShift / Galahad round pumps | 480 x 480 | 30 | 120 s | crf 20, 4M | PNG or JPEG |
| HydroShift II OLED Curve (pump) | 2288 x 1080 | 30 | 120 s, less when the estimate says so | crf 22, 12M | PNG |
| Universal Screen 8.8" | 1920 x 480 | 30 | 180 s | crf 21, 8M | PNG or JPEG |
| Vision 9.2", Lancool 207 | their media size | 30 | 180 s | crf 21, 8M | PNG or JPEG |

These come from `lib/pc-lights/models.json`: `prep` per LCD model
(`{fps, max_s, crf, maxrate, image}`; `_prep_defaults` for a model without
one) and `lconnect`, the L-Connect library folders made for the model.
`compile` reads neither key.

## Commands

```
lumenaire media list --for <role|model> [--source theme:<name>|library|files] [--draft <name>]
                     [--query <text>] [--offset N] [--limit N (60)] --json
lumenaire media probe <file> --json
lumenaire media frame <file> [--time <s>] [--max <px> (960)] --json
lumenaire media thumb <file>... [--now] --json
lumenaire media prepare <file> --for <role|model>
                        (--draft <name> [--then set|clip-add|none] [--at N] | --out <file>)
                        [--crop x,y,w,h] [--time <s>] [--start <s>] [--duration <s>] [--json]
lumenaire media jobs [--draft <name>] [--all] --json
lumenaire media cancel <job-id> [--json]
lumenaire media gc [--dry-run] [--json]
lumenaire media --run-job <id>      (internal: a job's runner, in its unit)
lumenaire media --index             (internal: the indexer, in its unit)
```

`--for` takes a screen role of the hardware profile (`screen.fan3`,
`screen.pump`, `screen.main`) or an LCD model (`TlFlexLcd`); a role needs a
profile, a model doesn't. Nothing takes the engine's main lock.

**Exit codes.** 0 ok; 1 an internal error; 2 bad input, with `{"error",
"code"}` on stdout; 3 systemd-run could not start the job; 5 no profile.

| `code` | Meaning |
| --- | --- |
| `usage` | a flag or value is wrong |
| `invalid` | not a regular readable file (a FIFO, a device, a folder), an `--out` that exists, a crop without a size |
| `not-found` | no such file, draft or job |
| `no-role` | `--for` is neither a screen role of the profile nor an LCD model |
| `broken` | ffprobe can't read it (junk, an empty file) |
| `no-picture` | it has no picture (sound only, album art only) |
| `unsupported` | it has a picture this PC can't decode |
| `too-large` | more than 16384 px on a side |
| `disk-full` | less free space than 1.2 x the output estimate + 1 GiB |
| `stage-full` | every draft's unsaved media together would pass `PCL_MEDIA_STAGE_CAP` (4 GiB) |
| `missing-tool` | ffmpeg, ffprobe or ImageMagick (`magick`) is missing: "Screen editing needs ffmpeg and ImageMagick" |
| `no-profile` (exit 5) | `--for <role>` without a hardware profile |

`probe` also answers 2 for an unreadable file, with the record and `code`.

## The JSON answers

The frozen examples are `tests/fixtures/media.list.library.json`,
`media.list.theme.json`, `media.job.running.json`, `media.job.done.json`,
`media.job.failed.json` and `media.frame.json` (their `thumb` and `path` are
relative to `tests/fixtures`; the engine's are absolute).

**`media list`**

```json
{"v": 1, "source": "library",
 "for": {"role": "screen.pump", "model": "HydroShift2OledCurveLcd", "shape": "wide-curve", "media": [2288, 1080]},
 "total": 151, "offset": 0, "limit": 60, "indexing": {"state": "running", "done": 80, "of": 151},
 "tools_missing": [], "truncated": false,
 "groups": [{"id": "lconnect:HydroShift2OledCurveLcd", "label": "Pump clips"}, {"id": "themes", "label": "Other themes"}],
 "items": [{"id": "m-3fa9c2d1e0", "path": "/home/you/Videos/lian-li/hydroshift-ii-oled-curve/video/001bgnew_260414135722.mp4",
            "rel": null, "where": null, "group": "lconnect:HydroShift2OledCurveLcd", "title": "001bgnew 260414135722",
            "kind": "video", "w": 2288, "h": 1080, "duration": 5.0, "fps": 60, "bytes": 11697230, "mtime": 1790000000,
            "probe_state": "ready", "error": null, "thumb": "/home/you/.cache/pc-lights/thumbs/3f/3fa9....webp",
            "thumb_state": "ready", "made_for": "HydroShift2OledCurveLcd",
            "fit": {"state": "exact", "keep": 1.0, "scale": 1.0, "score": 1.0, "note": null},
            "in_use": [], "used_by": []}]}
```

- Sources. `library`: every other theme's `media/` (hard-linked copies are
  one item; `in_use` names the themes), then the library folders
  (`~/Videos/lian-li`; `~/.config/pc-lights/media.json` `{"library": [...],
  "files": [...]}` sets both lists). `files`: the XDG Videos and Pictures
  folders of this `$HOME` (else `~/Videos`, `~/Pictures`), without the
  library folders, the themes, `~/.config/pc-lights` and
  `~/.cache/pc-lights`, 6 folders deep. `theme:<name>`: the draft's stage
  and media root (or the saved theme), `media/` and `us88/`; items carry
  `rel`, `where` (`stage` or `root`) and `used_by` (the screen keys that name
  them); new files are probed right away.
- Never listed: hidden files and folders, `*.h264` (the daemon's pre-rotated
  streams), and folders named `temp`, `template`, `modulars`, `preview`,
  `thumbnail`, `overlay-snapshots`, `color-analysis-cache`. Folders reached
  through a link aren't followed. At most 5000 files are read
  (`truncated`).
- Groups, in this order: clips made for this shape (`lconnect:<Model>`,
  "Pump clips", "Fan clips", "8.8" clips"), "Other themes", "Your L-Connect
  uploads" (anything under `uploaded/`), "Library", clips made for other
  shapes; for files "Videos", "Pictures". Within a group: probed items by
  `fit.score`, then the newest; pending ones after them, unreadable ones last.
- `made_for`: the model an L-Connect folder is for (models.json `lconnect`),
  or the model a theme's screen entry gives the file.
- `--query`: a case-insensitive substring of the title or the parent folder.
- `probe_state`: `ready`, `pending` (not indexed yet) or `failed` (then
  `error` says why); `thumb_state` the same for the thumbnail.
- `indexing.state`: `running` (the indexer was started for what is pending),
  `done`, or `off` (no ffprobe, or `PCL_MEDIA_INDEX=off`).
- `title`: the name without its extension or a staged copy's `-<sha8>`, `_`
  and `-` as spaces, a space between a word and a number ("planet37" ->
  "planet 37").

**`media probe`**: the record the index keeps.

```json
{"path": "/home/you/Videos/phone/clip.mov", "size": 88040000, "mtime": 1788300000, "kind": "video",
 "container": "mov,mp4,m4a,3gp,3g2,mj2", "codec": "h264", "pix_fmt": "yuv420p", "w": 1920, "h": 1080,
 "dw": 1080, "dh": 1920, "rotation": 90, "sar": 1, "fps": 30, "duration": 31.2, "frames": 936,
 "alpha": false, "hdr": false, "interlaced": false, "audio": true, "error": null}
```

`dw` x `dh` is what a viewer sees: a 90/270 rotation (a phone video's
display matrix, a photo's EXIF orientation 5-8) swaps them, a non-square
pixel aspect widens them. `kind` is `video`, `image` (a still, a one-frame
GIF or video) or `animation` (a GIF or APNG with more frames). `alpha` from
the pixel format (rgba, argb, bgra, yuva..., a GIF); `hdr` for PQ and HLG.
`error`: `null`, `broken`, `no-picture`, `unsupported` or `missing`. Videos
and GIFs are read with `ffprobe` (10 s at most), stills with `magick
identify -ping`.

**`media frame`**: `{path, time, w, h, src_w, src_h, duration, kind}`. One
JPEG in display orientation, its long side at most `--max` (960), taken at
`--time` (default a third in, kept inside the clip). Crop coordinates are in
`src_w` x `src_h` pixels. Cached per file and moment.

**`media thumb`**: `{"thumbs": [{path, thumb, state}]}`. `--now` makes up to 8
at once; the rest are queued for the indexer.

**The job record** (`$CACHE/media/jobs/<id>.json`; `media prepare` answers
`{"job": <record>}`):

```json
{"v": 1, "id": "j-1790000400123-4821", "kind": "prepare", "state": "encoding",
 "draft": "sakura-2", "role": "screen.fan3", "model": "TlFlexLcd", "then": "set", "at": null, "dest": null,
 "source": {"path": "...", "size": 5210000, "mtime": 1790000000, "kind": "video", "w": 1920, "h": 1080, "duration": 42.0, "fps": 30},
 "request": {"crop": [656, 236, 608, 608], "time": 12.4, "start": null, "duration": null},
 "recipe": {"v": 1, "mode": "encode", "crop": [656, 236, 608, 608], "time": 12.4, "start": 0, "duration": 42.0,
            "fps": 30, "size": [400, 400], "codec": "h264", "crf": 20, "maxrate": "4M", "bg": null, "key": "<sha256>"},
 "estimate": null,
 "progress": {"frac": 0.42, "out_time": 17.7, "speed": 3.1, "eta": 8},
 "unit": "lumenaire-media-j-1790000400123-4821", "pid": 48213,
 "started": 1790000400, "updated": 1790000406, "ended": null,
 "output": null, "warnings": [], "error": null, "applied": null}
```

- `state`: `queued`, `waiting` (for a heavy slot), `probing`, `estimating`
  (capped models), `encoding`, `finishing`, then `done`, `failed` or
  `cancelled`.
- `recipe.mode`: `encode`, `remux` (an exact h264 source: stream copy),
  `still` (a picture made to size) or `copy` (a picture already exact).
  `bg` is `black` when transparency is flattened. `key` identifies the
  output (the choices that shape it, the source's path, size and mtime, the
  prep version; not `time`).
- `estimate` (capped models): `{method: sampled|fallback, bytes_per_s,
  speed, by_size_s, by_speed_s, by_hw_s, max_s, limit_s}`.
- `output`: `{rel, abs, bytes, sha256, reused}`; `reused` when an earlier
  output (same recipe, or the same bytes) is used instead of a new file.
- `warnings`: `trimmed` ("Uses the first 2:00.", `keep_s`), `low-res`,
  `hdr` ("Colours may look flat"), `huge`, `alpha`.
- `error`: `{code, text}`: `unsupported`, `no-picture`, `broken`,
  `disk-full`, `stage-full`, `stopped` (killed or timed out), `busy` (no
  heavy slot in 30 min), `no-draft` (the draft went away), `not-applied`
  (the draft refused the output), or on a cancelled job `superseded`.
- `applied`: `{rev, at}` once the draft took it.

**`media jobs`**: `{v, running, jobs: [records, newest first]}`: the jobs
that run or ended in the last day (`--draft`: one draft's; `--all`: every
record, kept 7 days). A job whose runner is gone (killed hard, a reboot)
ends here as `failed`/`stopped`.

**`media cancel`**: `{cancelled, id, state}`; idempotent; `cancelled` is
false for a job that had already finished.

**`media gc`**: `{deleted: [paths], freed_bytes, kept_referenced,
unused_hand_placed: [paths], history_bytes, caches: {thumbs, frames, jobs,
work, bytes}, dry_run}`.

**`status --json`** (contract v1.3, `"v_minor": 3`) adds `media: {running,
jobs: [{id, draft, role, state, progress, error, then, applied}]}`: the
running jobs and the ones that ended in the last hour, newest first, at most
20 (`progress` is `progress.frac`).

## Fit and crop

`media_fit($probe; $target)` (media.jq) scores a file for a screen:

| Term | Definition |
| --- | --- |
| `keep` | the share of the picture a centre crop to the screen's aspect keeps: `min(r, 1/r)`, r = source aspect / screen aspect |
| `scale` | screen width / crop width in source pixels (above 1: upscaled) |
| `score` | `keep^1.5 x (scale > 1 ? scale^-0.5 : 1) x (made for this shape 1.05, for another 0.9, unknown 1)`, at most 1 |
| `state` | `exact` (the screen's size), `scaled` (keep >= 0.98), `cropped` (keep >= 0.6), `poor`, `unknown` (not probed, or unreadable) |
| `note` | `long` (over the model's `max_s`), `low-res` (scale > 1.25), `hdr`, `alpha`, or null |

A 16:9 video on the pump keeps 0.839 of the picture (score 0.704), a square
one 0.472 (poor).

`--crop x,y,w,h` is in display pixels (after rotation and EXIF orientation).
The engine fixes it: an aspect more than 1 % off the screen's is shrunk
around its centre, a crop bigger than the frame is scaled down, then moved
inside the frame, and all four numbers are made even. Without `--crop` it is
the centre "cover" crop.

## How a file is prepared

**Video, GIF animation**, into H.264 MP4:

```
ffmpeg -nostdin -y [-ss START] -i SRC -t DUR -map 0:v:0 -an -sn -dn -map_metadata -1 -map_chapters -1 \
  -vf "[yadif,]crop=CW:CH:CX:CY,scale=W:H:flags=lanczos,setsar=1,fps=FPS,format=yuv420p" \
  -c:v libx264 -preset veryfast -crf CRF -maxrate MR -bufsize 2MR -g 2FPS -threads T -pix_fmt yuv420p \
  -movflags +faststart -progress <work>/progress -nostats <work>/out.mp4
```

FPS is the source's, at most `prep.fps` (30); T is half the CPUs, 1-8.
Transparent sources (qtrle `.mov`, GIFs) go over a black
`color` source with `overlay`. Interlaced sources get `yadif`. HDR is
converted without tone mapping (warning `hdr`). Sound, subtitles, chapters
and metadata (a phone's location) are dropped.

**Remux**: a source that is already exact (h264 yuv420p, the screen's size,
no rotation or crop, at most 60 fps, not longer than the model's limit) is
copied stream for stream (`-c copy`, about 0.1 s).

**Stills** into PNG (a PNG, GIF or BMP source, a transparent one, or the
pump: `prep.image` `png`) or JPEG:

```
magick SRC[0] -auto-orient -background black -alpha remove -alpha off -crop CWxCH+CX+CY +repage \
  -filter Lanczos -resize WxH! -strip -quality 95 OUT
```

with ffmpeg as the fallback. A picture that is already exact in the right
format is copied (`cp --reflink=auto`; never a hard link to your file).

**The length** (plan §2.6). Longer sources keep the first `prep.max_s`
seconds (`--start`/`--duration` choose another window). Models with a
transcode cap (the pump, `transcode_cap_mb` 256) get an estimate first:
three 4 s samples (at 10, 50 and 90 %) go through the recipe and are then
encoded the way the daemon does (libx264 ultrafast, no B-frames, 4 threads,
the panel's transposed size). Then

```
limit = min(max_s, 0.8 x 256 MiB / (bytes/s x 1.25), 100 s x speed [, 0.8 x 256 MiB / (w h fps / 4 / 8) with hardware_video])
```

When sampling fails, `0.8 x 256 MiB / (1080 x 2288 x fps / 4 / 8)` stands in
(92 s at 30 fps, 115 s at 24 fps). Clips of 20 s or less skip the estimate.

**Disk.** Before a job starts, and again once its length is known: free
space for 1.2 x the estimate (length x maxrate / 8 x 1.1) and 1 GiB where
the scratch and the output live (`disk-full`), and for a draft's job every
stage together under `PCL_MEDIA_STAGE_CAP` (`stage-full`).

**Where outputs go.** A draft's job: `drafts/<name>.media/media/<stem>-<sha8>.<ext>`
(the stem is the source's name, `[a-z0-9-]`, 24 characters at most; sha8
from the output's bytes). A file is never changed after it lands; a new
choice is a new name. `--out <file>`: that file, which must not exist.

**Dedupe.** A recipe the draft (`media_sources`) or its theme
(`src/media.json`) already made is reused as it is (`reused: true`, no
encode). An output whose bytes equal a file in the stage or the theme's
`media/` is not stored twice.

## Jobs

`media prepare` checks the request (the file, the tools, the role, a probe,
the disk), writes the record and starts the runner in its own unit, then
answers within about 150 ms:

```
systemd-run --user --quiet --collect --unit=lumenaire-media-<id> \
  -p MemoryMax=<PCL_MEDIA_MEM, else a quarter of the RAM, 1-4 GiB> -p MemorySwapMax=512M \
  -p CPUWeight=20 -p CPUQuota=<CPUs x 50>% -p Nice=10 -p IOSchedulingClass=idle \
  -p KillMode=control-group -p TimeoutStopSec=15 -p RuntimeMaxSec=1800 \
  --setenv=HOME=... -- lumenaire media --run-job <id>
```

- **Slots.** The runner first takes a `flock -n` slot of pcl-heavy's
  (`$XDG_RUNTIME_DIR/pcl-heavy/slot<i>`, i < `PCL_HEAVY_SLOTS`, 2), so theme
  previews, auto-themes and media jobs share one machine-wide limit. It is
  `waiting` meanwhile and gives up after `PCL_MEDIA_WAIT` (1800 s) with
  `busy`.
- **Progress** comes from ffmpeg's `-progress`: probing 2 %, estimating
  10 % (capped models), encoding 85 %, finishing 3 %; `frac` only grows,
  and the record is written at most every 0.5 s (tmp + mv).
- **A draft's job.** The draft waits for it (`pending_media[role]`; a save
  waits too). A new prepare for the same screen of the same draft cancels
  the older job (`cancelled`, error `superseded`). When the output is
  there, the draft takes it as `--then` says: `set` (the screen's picture
  or video), `clip-add` (a clip, `--at N` or last), `none` (it only stops
  waiting; `theme media set <role> j-<id>` uses it later). A draft that went
  away meanwhile gives `no-draft`; the output stays in the job's scratch
  for GC.
- **Cancel.** `media cancel` stops the unit (or TERMs an inline runner); the
  runner removes its scratch and partial output and ends the record; a
  cancelled job's screen stops waiting.
- **Nothing heavy runs in the caller's cgroup.** A job and the indexer run
  in their units; `media frame`, `media thumb --now`, `previews` without
  pcl-heavy, and inline test jobs run each ffmpeg or magick call in its own
  scope (`media_capped`: `systemd-run --user --scope -p MemoryMax=1G
  -p CPUWeight=20 nice -n 10 ...`; without a user systemd, `nice` and
  `prlimit --as`).

## The index and thumbnails

`media list` never probes (except a theme's few new files): it lists the
files with `find -printf`, joins them with the index in one jq pass, and
marks what isn't in it `pending`. Then it writes the page it answered first,
then the rest, to `index.want` and starts the indexer unit
(`lumenaire-media-index`, one per user, CPUQuota 25 %). The indexer probes
and thumbnails in that order, adds 25 files at a time to the index and
touches `index.stamp` (the plugin watches it and lists the page again). It
stops when nothing wanted is left, then compacts the index (one record per
path, gone files dropped).

A thumbnail is a webp, 256 px on its long side, quality 70, at a third of a
video (transparency over black), kept by `sha1(path \0 size \0 mtime)`: a
changed file gets a new one. One that can't be made leaves a `<k>.fail`
marker, retried only when the file changes.

## Files

| Path | What |
| --- | --- |
| `~/.config/pc-lights/drafts/<name>.media/media/` | a draft's prepared media (0700; the editor's stage) |
| `~/.config/pc-lights/media.json` | optional: `{"library": [folders], "files": [folders]}` (`~` is your home) |
| `<theme>/src/media.json` | where each editor-made file came from: `{v: 1, files: {rel: {source, recipe, model, prepared}}}` (written by the editor's save) |
| `~/.cache/pc-lights/media/jobs/<id>.json` | job records (`<id>.cancel` while a cancel runs) |
| `~/.cache/pc-lights/media/work/<id>/` | a job's scratch |
| `~/.cache/pc-lights/media/index.jsonl`, `index.want`, `thumb.want`, `index.stamp` | the probe index and its queue |
| `~/.cache/pc-lights/thumbs/<k:0:2>/<k>.webp` | thumbnails |
| `~/.cache/pc-lights/media/frames/<k>/<ms>-<max>.jpg` | crop frames |
| `~/.cache/pc-lights/media/hashes.tsv` | sha256 by device, inode, size and mtime (save and dedupe) |

## GC

`media gc` (also after a save, a discard, a rename and a preview's end, as
`media_gc_draft <name>`) deletes a file only when **both** hold:

1. It may go: it is in a draft's stage, or a theme lists it in its
   `src/media.json` (the editor made it). Files you placed in a theme are
   never deleted; `--dry-run` lists the unused ones as `unused_hand_placed`.
2. Nothing references it: not the daemon's config (`config.json`
   `.lcds[].path`, the templates' paths in `lcd_templates.json`), not any
   theme (`theme.json`, `theme.known-good.json`: paths, clips and every file
   in a clip folder, `_prev`, templates and the paths inside them), not the
   history (`theme-history/<name>/*.json`, against that theme's folder), not
   a draft (through its stage and its media root), not a job that runs or
   whose output waits for the draft, not the preview's saved or applied
   screens.

The candidates are listed first and the references read afterwards, under
the editor's `drafts/.lock`, so a save or a job landing meanwhile is never
cut short. A theme's `src/media.json` loses what was deleted (tmp + mv, as
themes share it through hard links). The stage of a draft that is gone goes
too. The caches: thumbnails over 300 MB (oldest first), frames older than a
day, ended jobs older than 7 days, scratch without a running job (an
orphaned output after a day).

Media replaced by a save stays while a history entry needs it (the newest 30
saves); `history_bytes` says how much that is.

## With the editor

The editor (lib/pc-lights/editor.sh) provides the draft side:
`editor_draft_stage <name> [--create]`, `editor_draft_abspath <name> <rel>`,
`editor_media_pending <name> <role> <job> [<only-if>]` and
`editor_media_apply <name> <jobfile>` (0 applied, printing the new rev; 1
superseded or no draft; 2 not applied). media.sh stands in for them (they
die "not implemented") when editor.sh is older.

media.sh provides, for the editor's screens view and its save: `media_cmd`,
`media_probe_json <abs>` (and `media_probe_many <abs>...`, one record a
line, the index first, up to 8 probes at a time), `media_thumb <abs>...` (the
thumbnail path per file, queueing missing ones), `media_job_file <id>`,
`media_jobs_json [--draft <name>] [--all]`, `media_cancel_job <id>
[superseded] [--nowait]`, `media_gc_draft <name>`, `media_gc [--dry-run]`,
`media_capped <cmd...>`, `media_sha256 <file>`, `media_rename_draft <old>
<new>`, and in media.jq `media_fit`, `media_title`, `media_target`,
`media_crop`.

Every engine command sources media.sh, but a plain source reads only its
head: the constants, the stand-ins and these entry points, which load the
rest of the file on first use (`md_load`), so `status --json` and the other
commands don't pay for parsing the pipeline. A `PCL_TEST_OVERRIDES` hook that
replaces a media internal (an `md_*` function) calls `md_load` first.

## Testing

`tests/media/run.sh [engine]` runs everything above against a fixture
`$HOME` with `PCL_MEDIA_INLINE=1` (jobs and the indexer run in the calling
process, each ffmpeg and magick call in its own scope) and stubs that keep
the daemon, OpenRGB and every unit but its own away. Its media come from
`tests/media/make-fixtures.sh <dir>` (lavfi patterns, a few seconds);
`tests/fixtures/media/make.sh` rebuilt the small committed images the
render harness uses. The run takes one pcl-heavy slot for itself.

Knobs (tests, and the curious):

| Variable | Effect |
| --- | --- |
| `PCL_MEDIA_INLINE=1` | jobs and the indexer run in the calling process |
| `PCL_MEDIA_INDEX=off` | never start the indexer |
| `PCL_MEDIA_UNIT` | the unit name prefix (`lumenaire-media`) |
| `PCL_HEAVY_DIR`, `PCL_HEAVY_SLOTS` | the slot folder and count (pcl-heavy's) |
| `PCL_MEDIA_WAIT` | seconds to wait for a slot (1800) |
| `PCL_MEDIA_MEM` | a job unit's MemoryMax |
| `PCL_MEDIA_STAGE_CAP` | every stage together (4G) |
| `PCL_MEDIA_FREE_BYTES` | pretend this much disk is free |
| `PCL_MEDIA_LIST_CAP`, `PCL_MEDIA_THUMB_CAP` | files a list reads (5000), thumbnail bytes kept (300 MB) |
| `PCL_MEDIA_READRATE` | ffmpeg `-readrate` for encodes (slow jobs to cancel) |
| `PCL_MEDIA_NO_SCOPE=1` | no systemd scopes: nice + prlimit |
| `PCL_MEDIA_FIXTURES` | tests/media/run.sh reuses this media folder |
