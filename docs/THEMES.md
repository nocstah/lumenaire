# Writing themes

A theme is the whole look of the case in one folder: the colours of every
light, and optionally what each LCD screen shows. Themes live in
`~/.config/pc-lights/themes/<name>/`; the folder name is the theme's name.

- [The smallest theme](#the-smallest-theme)
- [Folder layout](#folder-layout)
- [Schema (v3)](#schema-v3)
- [What the palette fills in](#what-the-palette-fills-in)
- [Lighting roles](#lighting-roles)
- [Screens](#screens)
- [Heat warning](#heat-warning)
- [Colours that work on LEDs](#colours-that-work-on-leds)
- [Checking a theme](#checking-a-theme)
- [Editing themes](#editing-themes)
- [Editing screens](#editing-screens)
- [v2 themes and migrate](#v2-themes-and-migrate)
- [Generated themes (auto-theme)](#generated-themes-auto-theme)

## The smallest theme

```json
{
  "v": 3,
  "_about": "Aurora: northern lights over a dark sky.",
  "palette": {"primary": "00ff8a", "secondary": "7a1aff", "accent": "00d8ff", "alert": "ff2a00"}
}
```

That is a complete theme. lumenaire derives every light in the case from the
palette and leaves the screens as they are. It works on any PC, whatever
hardware it has. The three examples in `examples/themes/` (aurora, ember,
glacier) are like this; `lumenaire install --examples` copies them in.

Colours are 6 hex digits without `#` (a leading `#` is accepted).

## Folder layout

```
themes/<name>/
  theme.json      the theme; every path in it is relative to this folder
  media/          images and videos for the screens
  us88/           a Universal Screen template, its background and font
  src/            anything you used to make it (prompts, sources); ignored
                  (src/media.json: where the editor's media came from, below)
```

Keep a theme self-contained: put its files in its folder and never point it at
files elsewhere, so it can be copied, shared or backed up as one folder. To
start from an existing theme, copy it with hard links
(`cp -al themes/aurora themes/mine`), then **replace** files rather than
editing them in place, since hard-linked files share their content.

## Schema (v3)

```ts
{
  v: 3
  _about?: string                 // one or two sentences; the plugin shows it
  "_*"?: any                      // notes, ignored
  led?: { calibrated_for?: string }       // see CALIBRATION.md
  palette: { primary, secondary?, accent?, alert?, led_safe?: bool }
  motion?: { mode?, speed?: 0-4, direction?: "Clockwise"|"CounterClockwise" }   // Strimer defaults
  roles?: { [role or group]: value }      // explicit values; override the palette
  alert?: { color?, cpu?: {threshold?, color?}, gpu?: {threshold?, color?} }
  screens?: { [screen role | "screen.fan" | "model:<Family>"]: entry | [entry, …] }
  templates?: [path]                      // Universal Screen templates to install
}
```

Only `v` and `palette.primary` are required. `secondary` defaults to
`primary`, `accent` to the mix of the two.

## What the palette fills in

For every role in your profile that the theme doesn't set:

| Role | Gets |
| --- | --- |
| `fans.*` | `inner`: primary, `outer`: secondary |
| `strimer.*` | `{mode: motion.mode or "Drizzling", colors: [p, s, a, p, s, a], speed: motion.speed or 2, direction: motion.direction or "Clockwise"}` |
| `pump.ring`, `screen.main.ring` | accent |
| `gpu` | a gradient primary → secondary |
| `board`, `board.argb` | accent |
| `ram` | a gradient primary → accent → secondary across all sticks |
| `keyboard` (only when managed) | primary |
| `mouse`, `mousepad`, `headset`, `other` | never derived: a theme must name them |
| heat warning | `palette.alert`, else `alerts.json` |

Derived colours are made LED-safe (hue kept, saturation and value pushed to
full) unless `palette.led_safe` is `false`. Your explicit values are used as
written.

## Lighting roles

Set a whole group with its group key, or one role by name; a role beats its
group, and both beat the palette:

```json
"roles": {
  "fans": {"inner": "00ff8a", "outer": "7a1aff"},
  "fans.top": {"inner": "00d8ff", "outer": "7a1aff"},
  "strimers": {"mode": "Wave", "colors": ["00ff8a", "00d8ff", "7a1aff", "00ff8a", "00d8ff", "7a1aff"], "speed": 1, "direction": "Clockwise"},
  "rings": "00d8ff",
  "gpu": {"gradient": ["00ff8a", "7a1aff"]},
  "board": "7a1aff",
  "ram": {"gradient": ["00ff8a", "00d8ff", "7a1aff"], "span": "across"},
  "keyboard": "00ff8a"
}
```

| Key | Forms |
| --- | --- |
| `fans`, `fans.<pos>` | `{"inner": hex, "outer": hex}`; each may also be a list of 1-4 hex, one per fan in the group (the last repeats), e.g. a bright-to-dark cascade |
| `strimers`, `strimer.<name>` | `{"mode", "colors": [6 hex], "speed": 0-4, "direction"}`. `mode` is a lian-li-linux effect (Static, Wave, Drizzling, Meteor, Rainbow, Breathing, …); wave-like modes cycle through exactly 6 colour slots, so give 6 |
| `rings`, `pump.ring`, `screen.main.ring` | hex |
| `gpu` | `"hex"`; `{"gradient": [a, b]}`; `{"gradient": [3+ stops]}` (evenly spaced); `{"mode": "<OpenRGB mode>", "colors": [...], "speed"?, "brightness"?}` |
| `board`, `board.argb` | `"hex"` or `{"mode", "colors"}` |
| `ram` | `"hex"`; `{"gradient": [2+], "span": "across"\|"stick", "drift"?: {...}}`; `{"leds": [hex per LED]}`; `{"mode", "colors", "speed"?}`. `drift` slides the gradient slowly along the sticks: see [RAM drift](#ram-drift) |
| `peripherals`, `keyboard`, `mouse`, … | `"hex"` or `{"mode", "colors"}`; only applied to devices you set to managed |

OpenRGB mode names depend on the device; `openrgb --list-devices` lists them.

### RAM drift

The RAM's own effects can't move a gradient in your colours (on ENE sticks the
modes that take colours only breathe, flash or chase; the colour cycles are
rainbows). A gradient with `drift` moves anyway, in software:

```json
"ram": {"gradient": ["ff6a2a", "ff1a70", "9020d8", "ff4a9a"], "span": "across",
        "drift": {"period": 120, "window": 0.5, "reverse": false, "fps": 4}}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `period` | 120 | seconds for one whole loop of the colours, 20-3600 |
| `window` | 0.5 | the share of the loop the sticks show at once, 0.1-1 |
| `reverse` | false | false: colours move toward higher LED numbers (with `span: "across"`, from the first stick into the second); true: the other way |
| `fps` | 4 | frames a second, 1-10 (at 120 s and 4 fps a step is about one colour level) |

- The stops are a closed loop: the last blends back into the first, so the
  flow never jumps. 2-8 stops.
- An apply writes the first frame as ordinary Direct colours. After it (lights
  on), the engine starts `lumenaire-ram-drift.service`, which moves on from
  that frame. It runs a private OpenRGB server that detects only the RAM
  sticks (`~/.cache/pc-lights/ram-drift/openrgb/OpenRGB.json`: your detector
  list with every other detector off) and sends frames over the OpenRGB SDK
  on 127.0.0.1:6797. Unchanged frames aren't sent.
- The engine stops the unit before every OpenRGB call it makes (an apply, a
  theme preview, `detect`), so there is only ever one OpenRGB on the SMBus,
  and starts it again only when the lights are on and the theme drifts. Lights
  off, or a theme without `drift`, leave it stopped.
- `render` prints a `# ram drift: ...` line after the OpenRGB command;
  `lumenaire ram-drift status` shows the unit and what it drives. The unit
  comes with `lumenaire install --units`; without it the RAM keeps the first
  frame.
- The editor edits the stops and the span and keeps `drift`; change its
  numbers in theme.json.

## Screens

Screens are keyed by **role**, never by serial, so a theme works on any PC:

```json
"screens": {
  "screen.fan": [
    {"type": "video", "path": "media/fan-a.mp4", "model": "TlFlexLcd"},
    {"type": "video", "path": "media/fan-b.mp4", "model": "TlFlexLcd"}
  ],
  "screen.pump": {"type": "video", "path": "media/pump.mp4", "model": "HydroShift2OledCurveLcd",
                  "clips": ["media/pump"], "rotate": 300},
  "screen.main": {"type": "custom", "template_id": "us88-aurora", "model": "UniversalScreen"}
},
"templates": ["us88/us88-aurora.template.json"]
```

**Which entry a screen gets.** For each screen role in the profile, in order:
the entry for that exact role (`screen.fan3`), else the list for its base
(`screen.fan`, dealt out in order and repeated), else `model:<Family>` (for
example `"model:HydroShiftLcd"` for a round pump screen).

**Fit.** `model` says what the media was made for. A screen only gets an entry
made for the same shape (square, round, wide curve, strip). Landscape pump art
never lands on a round pump screen: that screen is left as it is, and the
plugin shows the theme as "Partial". Leave `model` out to allow any screen.

| Model | Shape | Make media at | Default orientation |
| --- | --- | --- | --- |
| `TlFlexLcd`, `TlLcd`, `Tlv2Lcd`, `SlInfFlexLcd` | square | 400 × 400 | 0 |
| `HydroShiftLcd`, `Galahad2Lcd` | round | 480 × 480 | 0 |
| `HydroShift2OledCurveLcd` | wide curve | 2288 × 1080 (landscape) | 90 |
| `UniversalScreen` | strip | 1920 × 480 (landscape), templates | 90 |

**Orientation.** Leave it out. The engine uses the model's default plus the
screen's `mount` from your profile (how it is physically rotated in your
case). Set `"orientation"` on an entry only to override both.

**Entry fields.** `type`: `image`, `video`, `gif` or `custom` (a template).
`path` (image/video/gif) or `template_id` (custom). Optional: `brightness`
0-100 (default 100; while screens are off every screen gets 0), `clips`
(files or folders of videos to rotate through) with `rotate` (seconds,
30-86400) and `shuffle`.

**Video.** H.264 MP4 at the size above. The pump OLED plays at most 60 fps and
needs a clip under about 2 min at 24 fps. Seamless loops look best: make every
motion's period divide the loop length.

**Templates** (Universal Screen): the lian-li-linux template JSON (widgets for
time, date, CPU and GPU temperature, RAM, custom commands; a background image
or video; fonts). Paths inside it are relative to the theme folder. Give each
template a unique `id` and point `template_id` at it. Preview one before
applying: `lib/pc-lights/tools/lcd-preview us88/mine.template.json out.jpg`
(read-only, through the daemon). L-Connect `.template` files from Windows can
be decoded with `tools/nrbf.py`.

## Heat warning

lian-li-linux can repaint all Lian Li gear one colour while the CPU or GPU is
at or above a threshold. `~/.config/pc-lights/alerts.json` sets the defaults;
a theme overrides them:

```json
"alert": {"color": "00b4ff", "cpu": {"threshold": 90}, "gpu": {"threshold": 85, "color": "ff00c0"}}
```

Pick an alert colour that stands out from the theme (a blue warning on a warm
theme, red on a cool one). `palette.alert` is the short form of
`alert.color`. `lumenaire off` always disables the warning.

## Colours that work on LEDs

LEDs don't look like your monitor. What we learned from photos of real
hardware:

- **Green is much brighter on LEDs.** Warm colours with a green-to-red ratio
  above about 0.6 (gold `ffc048`, bronze `c07a10`) come out lemon-yellow. For
  gold or amber keep G/R around 0.35-0.6 (`ff9a30`, `ff6a00`); on fan frames,
  which are the most green-heavy, aim for G/R 0.3 or less (`ff7a1a`,
  `ff4a00`).
- **Pastels wash out to white.** Any near-white tint reads as white. Pinks
  need low green (G/R under about 0.4: `ff4a9a`, `ff1a70`, not `ffd0e6`).
- **Blues, cyans and magentas behave.** `00e5ff` reads as true cyan. Magenta
  like `ff2bd6` leans violet; for hot pink add red and drop blue (`ff1a8c`).
- **Dark colours go muddy or off.** Use saturated, bright colours for anything
  meant to be seen; near-black only for a deliberately dim night theme.
- **Judge from a photo, never from the hex on screen.** LCD art looks right
  where LED colours don't.

[CALIBRATION.md](CALIBRATION.md) turns these rules into a per-PC correction
that the engine applies for you.

## Checking a theme

```bash
lumenaire explain mine     # each role: theme / group / palette / none, the value, the device
lumenaire render mine      # validation plus exactly what "on" would write; touches nothing
lumenaire pick mine        # apply it (it also becomes the day theme)
```

`themes --json` gives each theme a **coverage** summary for this PC, which the
plugin shows as a chip: `full` (every role and screen has a value), `partial`
(some screens have nothing that fits), `leds-only` (no screen media for this
PC), or `foreign` (a v2 theme made for other hardware).

## Editing themes

The plugin's theme editor (and anything else) edits themes through
`lumenaire theme`. Edits go to a **draft**, never to the theme itself, until
you save. It needs a v3 theme and a hardware profile (exit 5 otherwise).

```bash
lumenaire theme new mine --palette primary=00ff8a,secondary=7a1aff   # palette only
lumenaire theme duplicate sakura sakura-2    # = new sakura-2 --from sakura (a v2 theme is converted)
lumenaire theme edit sakura                  # open (or resume) a draft of a saved theme
lumenaire theme set sakura /palette/accent ff3a8a /roles/fans.side/inner ff4a9a
lumenaire theme set sakura --unset /roles/fans.side          # back to the group / palette
lumenaire theme show sakura                  # the draft: every role, its source, what the LEDs get
lumenaire theme save sakura                  # or --as sakura-3; --apply / --no-apply
lumenaire theme revert sakura | discard sakura
lumenaire theme rename sakura blossom | delete blossom
lumenaire theme history sakura | restore sakura <stamp>
```

Add `--json` for the plugin's answer: one JSON object (the editor view for
`new`, `edit`, `show` and `set`), or `{"error", "code", "problems"?}` with
exit 2 (bad input: `usage`, `invalid`, `exists`, `not-found`, `bad-name`,
`in-use`, `stale-rev`, and for screens `no-role`, `unfit`, `unsupported`,
`media-pending`), 4 (the saved file changed since editing began), 5
(`not-v3`, `no-profile`) or 75 (an apply holds the lock; try again).

**Paths** are JSON Pointers into the v3 theme, with `/` between parts
because role names contain dots: `/palette/primary`, `/roles/fans.side/inner`,
`/roles/strimer.gpu/colors/2`, `/roles/ram/gradient/1`, `/led/calibrated_for`,
`/_about` (`~1` is a `/` inside a name, `~0` a `~`). A value like `FF4A9A` or
`#ff4a9a` becomes `"ff4a9a"`, `null` removes the path, anything else is read
as JSON (`3`, `["ff0000","00ff00"]`) or else as text. `--patch-json` takes
`[{"op": "replace"|"add"|"remove", "path", "value"}]`. After each edit the
theme is tidied: hex in lower case, empty roles (and an empty `roles`)
dropped, `"v": 3` kept. Setting `/roles/fans/inner` on a fan group written as
one colour splits it into `{inner, outer}`. `set` never refuses a value that
breaks the schema: the problems come back in the view, each with its path,
and `save` refuses until they are fixed. `--base-rev N` makes a set fail
(`stale-rev`) when another editor changed the draft in between.

**The view** (`show --json`) lists each lighting role of this PC with its
fields (fan `inner`/`outer`; Strimer `mode`, `speed`, `direction`, `colors`;
ring and board `colour`; GPU and RAM `stops` or one `colour`, RAM `span`),
and per field: its `source` (`role`: the theme names this role; `group`: the
theme's `fans`/`strimers`/`rings` key; `palette`: derived), the path that
value comes from (`source_path`), and `shows`, what the LEDs get after this
PC's calibration. Per-fan lists and OpenRGB `{mode, colors}` values are
read-only there (`form: "readonly"`): edit theme.json, or replace them with
one colour. Screens have their own view and verbs: see [Editing
screens](#editing-screens).

**LED hints.** Each colour carries the lessons from "Colours that work on
LEDs" as codes: `near_white` (S < 0.15, V > 0.8), `pastel` (S < 0.45,
V > 0.8), `warm_green` (hue 0-70°, red the largest channel, G/R above 0.6, or
0.3 on TL fans), `pink_green` (hue 290-360°, red largest, G/R above 0.4),
`violet_magenta` (fans only: hue 295-320°, B at least 0.8·R) and `dark`
(V < 0.25). Green checks skip near-neutrals. Each hint has a `fix`: the
`lianli-photo` preset's correction for that class (pastel and dark are made
LED-safe first; `ff1a8c` for violet; none for near-white). When this PC's
calibration applies and changes the colour, a hint it cures turns `info`
and says what the LEDs get instead (always for the two green hints). Palette
colours are judged as the derived lights use them (made LED-safe unless
`led_safe` is false).

**Saving is safe.** A save validates the draft like any apply would
(schema, compile, media, OpenRGB), refuses when the saved file changed since
editing began (unless `--force`), links the old `theme.json` into
`~/.config/pc-lights/theme-history/<name>/` (the newest 30 are kept) and
writes the new one as a new file, so hard-linked copies keep their bytes. A
new or duplicated theme is built as a hidden `.new-<name>` folder, with the
media hard-linked from the source (never its `src/source.json`), and moved
into place in one step. Saving the active theme with the lights on applies
it (a queued pick); a live preview of the draft ends with the save. `delete`
moves the folder to `~/.config/pc-lights/themes.trash/` and refuses a theme
that is active, the day or night theme, or mapped to an Omarchy theme;
`rename` also rewrites those references, the draft, the history and the
previews. Drafts live in `~/.config/pc-lights/drafts/`.

Generated `omarchy-*` themes can be edited, but a saved edit stops
auto-theme refreshing them: duplicate one instead. They can't be renamed.

## Editing screens

What each LCD screen shows is edited in the same draft, by screen **role**
(`screen.fan3`, `screen.pump`, `screen.main`), never by the file layout of
`screens`: the engine works out where each edit goes.

```bash
lumenaire theme screens sakura-2 --json              # every screen: what it shows, from where, how it fits
lumenaire media prepare ~/Videos/moon.mp4 --for screen.fan3 --draft sakura-2 --then set
                                                     # cropped and encoded for the screen, in the draft's stage
lumenaire theme media set sakura-2 screen.fan3 j-1790000400123-4821    # a finished job's output
lumenaire theme media set sakura-2 screen.fan3 media/fan-b.mp4        # a file the draft already has
lumenaire theme media set sakura-2 screen.fan2 media/fan-b.mp4 --all-fans   # the same on every fan screen
lumenaire theme media set sakura-2 screen.pump none  # the theme leaves that screen as it is
lumenaire theme media clips sakura-2 screen.pump add media/rain-0badc0de.mp4 --at 1
lumenaire theme media clips sakura-2 screen.pump move 2 0 | remove 1 | order 2,0,1
lumenaire theme media rotate sakura-2 screen.pump 300 --shuffle on   # or off
lumenaire theme media mode sakura-2 screen.main media | template     # the 8.8": a picture or video, or its template
lumenaire theme set sakura-2 /screens/@screen.pump/brightness 80     # brightness, rotate, shuffle, orientation
```

`media prepare`, `media list` and the other `media` verbs belong to the media
pipeline ([MEDIA.md](MEDIA.md)). Every `theme media` verb takes
`--base-rev N` (a stale draft: exit 2 `stale-rev`), `--with-screens` (the
screens view rides along as `screens_view`) and `--json` (the editor view plus
`notes`, for example "Rotation turned off: pictures can't take turns.").

**Where an edit goes.** A role with its own entry (`"screen.pump": {...}`) is
edited there. A role that takes its entry from a list (`"screen.fan": [a, b]`,
or `"model:TlFlexLcd": [...]`) is edited in the list at its own index; a list
shorter than the screens reading it is first dealt out to one entry each (the
same look, nothing shared any more). A role that shares one object with every
fan (`"screen.fan": {...}`) gets its own copy, `"screen.fan3": {...}`. The
screens view says which, per role, in `target` (`kind`: `role`, `list` or
`create`, the `path`, and the `expand` ops that run first) and lists the
roles reading the same entry now in `shared_with`.

**Role aliases.** `/screens/@<role>/<field>` in `theme set` (`brightness`,
`rotate`, `shuffle` and `orientation`) is resolved against the draft as it is
when the edit lands, so a slider never needs to know the file's layout. A
role that shows nothing from the theme yet has no brightness to set: choose
media for it first.

**Media rules.** `set` keeps the entry's other fields (brightness, a rotation)
and records the screen's model. It refuses media made for another shape
(exit 2 `unfit`: a pump clip on a square fan, a 16:9 video on a fan; prepare
it first) and a job that hasn't finished (`media-pending`). A picture on a
rotating screen ends the rotation. `none` removes a role's own entry; a role
that shares a list or object with others can't be emptied alone.

**Clips.** A rotation is the list `[path] + clips`, folders expanded (videos,
sorted by name, as the clip timer plays them). An edit writes it back as
files: `path` is the first, `clips` the rest (a folder is never written back).
One clip left: no `clips` and no `rotate`. At most 64 clips; `rotate` is 30 to
86400 seconds, `off` keeps the list.

**The 8.8".** `mode media` shows a picture or video and keeps the template id
in `_prev`; `mode template` shows the template again (from `_prev`, or the
theme's only template) and keeps the media in `_prev`. `templates` is never
touched, so the template stays installed and nothing is lost. `_prev` is a
note: nothing compiles it, but a save keeps its media.

**Staging.** New media never goes into a theme folder while you edit: `media
prepare` writes it to the draft's stage, `~/.config/pc-lights/drafts/<name>.media/media/`,
named by content (`<name>-<sha8>.<ext>`). A path in the draft resolves in the
stage first, then in the theme folder, so validation, the preview and
`theme screens` all see the staged files.

**Saving media.** A save puts every staged file the draft uses into the theme
folder under the same name (a hard link, or a copy across filesystems); a
staged file identical to one the theme already has is not linked, its
references move to that file. `src/media.json` records where each new file
came from (`{v: 1, files: {<file>: {source, recipe, model, prepared}}}`), and
it is written before the files, so an interrupted save leaves nothing the
media GC can't account for. A save waits while media for the draft is still
being prepared (exit 2 `media-pending`; `--force` saves without it and stops
those jobs). Discarding, renaming or deleting a draft stops its jobs and
takes its stage along; the GC (`lumenaire media gc`) never deletes a file a
theme, its history, a draft, the daemon config or a preview still uses.

**The screens view** (`theme screens --json`) has, per screen role in the
profile: `short` and `label`, its place on the case map (`group`, `place`:
top, left, right, bottom or centre, `wide`, `index` and `of` in its group),
the device, `model`, `shape`, `media_size` and `orientation`; `source` (`theme`,
`model`, `none`, `unmanaged`) and `unfit` (the model a theme's media was
made for, when it doesn't fit); `target` and `shared_with`; `changed` (what
compile sends differs from the saved theme's, or the theme a duplicate came
from); the `entry`; `media` (`rel`, `where`: stage, root or missing, `abs`,
`title`, `thumb`, `thumb_state`, `probe` and `fit`); `brightness` (`path`,
the role alias, `value`, `effective`); `clips`; `template` and `modes` (the
8.8"); `pending` (the job the role waits for: `state`, `progress`, `then`,
`error`); and `problems` (`missing`, `broken`, `unfit-media`, `long`,
`low-res`, `huge`, `template-missing`). Around them: `map` (the fan groups
and every role in map order), `coverage`, `disk` (the stage's bytes, free
space, a `warn`), `limits`, `sig` (changes whenever `screens` or `templates`
do; the editor view's `screens.sig` is the same) and the problems validation
finds in `screens`. `tests/fixtures/screens.sakura.json` is a frozen example.

## v2 themes and migrate

Older themes (no `"v"`, or `"v": 2`) put the lighting keys at the top level
(`fans.top` for the inner edges, `fans.bottom` for the outer bars, `strimers`,
`rings`, `gpu`, `board`, `ram`) and key `screens[]` by USB serial with an
explicit `orientation`. They still apply exactly as before, but they only fit
the PC they were made on.

`lumenaire migrate` converts them:

```bash
lumenaire migrate --dry-run    # the diff, per theme
lumenaire migrate              # backs up themes/ to themes.pre-v3-<date>, then converts
lumenaire migrate --rollback   # puts the backup back
```

It needs a profile whose screen roles cover every serial in your themes (so
run detect while all screens are on USB). It moves each screen's rotation into
the profile's `mount`, renames `fans.top`/`fans.bottom` to `inner`/`outer`,
stamps `led.calibrated_for` with your machine name (so your hand-tuned colours
are never recalibrated), and refuses to write any theme whose compiled result
isn't identical to the original.

**Naming clash.** In a v2 file `fans.top` means the inner LED region; in v3 it
is the top-mounted fan group. Never mix the two in one file.

## Generated themes (auto-theme)

With the Omarchy hook installed, every Omarchy theme without a mapping gets a
case theme `omarchy-<slug>`, built by `tools/auto-theme` in a few seconds:
lighting from the Omarchy palette (hues kept, made LED-safe; light themes use
their accent family), and, when your profile has LCD screens, fan loops, a pump
pan and a Universal Screen banner cut from the wallpaper. It is rebuilt when
the Omarchy theme's colours or wallpaper change, and never overwrites a
`theme.json` you edited by hand. Map a slug to your own theme instead in
`~/.config/pc-lights/omarchy-map.json`:

```json
{"_default": "auto", "tokyo-night": "glacier", "gruvbox": "ember"}
```
