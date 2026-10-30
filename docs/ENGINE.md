# The Lumenaire engine

`lumenaire` is the command-line engine of Lumenaire (`pc-lights`, its first
name, stays a working alias; see "Names" below). It owns every light
and LCD screen in the case: it builds the lighting from a theme, writes it to
the backends, keeps it across logins, switches between a day and a night theme,
rotates screen clips and pairs the case with the Omarchy theme. The Lumenaire
for Omarchy bar plugin is only a front end: every change it makes goes through
`lumenaire`.

- [Commands](#commands)
- [How an apply works](#how-an-apply-works)
- [Backends](#backends)
- [Files](#files)
- [Units, hook and timers](#units-hook-and-timers)
- [Schedule, clips and Omarchy pairing](#schedule-clips-and-omarchy-pairing)
- [Theme preview](#theme-preview)
- [Desktop wallpaper](#desktop-wallpaper)
- [The JSON interface (contract v1)](#the-json-interface-contract-v1)
- [Layout of the code](#layout-of-the-code)
- [Testing](#testing)

Related: [PROFILE.md](PROFILE.md) (the hardware profile and `detect`),
[THEMES.md](THEMES.md) (writing themes), [CALIBRATION.md](CALIBRATION.md)
(LED colour correction), [BACKENDS.md](BACKENDS.md) (the backend interface).

## Commands

```
lumenaire on|off [lights|screens|all]   apply the active theme, or go dark (default target: lights)
lumenaire status [--json]               what is set, what is running, what is missing
lumenaire scheme [name]                 list themes / pick the one "on" uses (also the day theme)
lumenaire pick <name>                   pick + apply now, even at night (what the plugin runs)
lumenaire render [name]                 dry run: print what "on" would write, touch nothing
lumenaire themes --json                 the theme list for the plugin
lumenaire previews [--force] [name...]  build theme preview images
lumenaire schedule [status|on|off|tick] day/night theme switching
lumenaire clips [status|on|off|pause|resume|next [--nowait]]
lumenaire omarchy <slug>                pair with an Omarchy theme (the theme-set hook runs this)
lumenaire apply-openrgb                 re-apply the OpenRGB half (the login unit runs this)
lumenaire detect [--probe|--no-openrgb] [--dry-run] [--json]
                                        find your devices, write the hardware profile
lumenaire profile show | set <role> <device-key> | set <role> --managed on|off
lumenaire explain <theme>               role -> where its value comes from -> value -> device
lumenaire sensors --json                CPU/GPU/coolant sensor sources for the plugin
lumenaire migrate [--dry-run] [--only name...] [--rollback] [--verify-render]
                                        convert v2 themes to v3 (see THEMES.md)
lumenaire install [--dry-run] [--units] [--hook] [--examples] [--workarounds] [--desktop]
                  [--replace] [--force] [--all]
lumenaire theme <verb> ...               the theme editor: new, edit, show, set, save, ... (THEMES.md)
lumenaire theme screens <name> [--json]  what each LCD screen of a theme (or its draft) shows (THEMES.md)
lumenaire theme media set|clips|rotate|mode <name> <role> ...
                                        edit a draft's screens (THEMES.md, "Editing screens")
lumenaire media list|probe|frame|thumb|prepare|jobs|cancel|gc ...
                                        screen media: find, crop and encode it for a screen (MEDIA.md)
lumenaire theme preview <name> [--rev N] [--idle S] [--json]
                                        show a theme's draft on the case, unsaved (see "Theme preview")
lumenaire theme preview --end [--reason panel-closed|reverted|closed] | --keepalive [--edited]
                  | --status --json | --measure
lumenaire desktop [--theme T] [--json]  the desktop wallpaper settings of a theme, and what is on screen
lumenaire desktop set [--theme T] animated|pause true|false|toggle | resume <1-600> | while freeze|still
lumenaire desktop reset [--theme T]     the theme drops its own settings and follows the defaults
lumenaire desktop sync|toggle [--json]  apply the desktop's theme / flip its wallpaper moving <-> still
lumenaire desktop watch                 sync on every monitor change (the monitor watcher service)
                                        (see "Desktop wallpaper")
lumenaire --detach <cmd ...>            queue a change in its own systemd user unit
```

Targets: `lights` is every LED (fans, Strimers, pump and screen rings, GPU,
board, RAM, and peripherals you opted in); `screens` is the LCD screens
(brightness 0 or the theme's value); `all` is both.

**Dry-run first.** `render` validates the theme, reads the daemon's
capabilities (read-only) and builds everything on scratch copies. It takes no
lock and never runs OpenRGB (a device probe next to a real apply can glitch
some RAM controllers).

## How an apply works

1. **Validate.** The theme is checked before anything is touched: colours,
   modes, speeds, brightness, that every media and template file exists, and
   (v3) that a hardware profile exists. Every problem is printed and logged
   (`journalctl --user -t pc-lights`), then it stops, with nothing changed.
2. **Compile.** A v3 theme is compiled against the hardware profile into the
   exact per-device values (palette derivation, role lookup, calibration, screen
   orientation). A v2 theme is used as it is. See [THEMES.md](THEMES.md).
3. **Build.** Each backend builds its plan on scratch copies while the devices
   keep running.
4. **Apply.** Lian Li: the new config is sent to the running daemon through its
   guarded live-write interface (a theme switch lands in seconds, no restart).
   If the live write can't be used (daemon restarting, version mismatch), the
   fallback stops the daemon, installs the config and starts it again, with the
   previous config restored if the daemon rejects the new one. OpenRGB: one
   `openrgb` call with every device's mode and colours.
5. **Record.** `busy.json` shows the running step, `last-run.json` how it
   ended (including wireless devices that missed the update).

**Safety rules.** Every state change holds one lock (`~/.cache/pc-lights/lock`,
waits up to 10 min), so the hook, the timers, the login unit, the plugin and
you in a terminal never interleave. An EXIT trap starts lianli-daemon again if
a run dies while it is stopped. A byte-range guard refuses any colour, speed or
brightness outside 0-255 before it reaches the daemon (its parser drops the
whole file on one bad byte).

## Backends

A backend drives one kind of hardware. Two exist today:

| Backend | Drives | Needs |
| --- | --- | --- |
| `lianli` | Lian Li wireless fans (TL, SL, SL-INF), Strimers, HydroShift / Galahad pump rings and LCDs, the Universal Screen and its ring | the `lian-li-linux` user daemon (`lianli-daemon.service`), its socket in `$XDG_RUNTIME_DIR` |
| `openrgb` | GPU, motherboard and ARGB headers, RAM, and (opt-in) keyboards, mice, mousepads, headsets | `openrgb` 0.9 or newer, `i2c-dev` loaded, OpenRGB's udev rules; on AMD `i2c-piix4` and often `acpi_enforce_resources=lax` for RAM |

A backend that is not installed, has no devices, or is disabled in the profile
is skipped: `render` and `status` print a one-line note, and the rest of the
theme still applies. A lianli backend with devices in the profile but the
daemon stopped is an error ("lianli-daemon must be running"), because
applying half a theme would be confusing.

Keep OpenRGB's own Lian Li detectors **off** (Settings, Supported Devices)
when lian-li-linux is installed, so the two never fight over the same gear.
`lumenaire install` warns when they are on.

Adding a backend (liquidctl, openrazer, …) is described in
[BACKENDS.md](BACKENDS.md).

## Files

| Path | What |
| --- | --- |
| `~/.config/pc-lights/themes/<name>/` | one folder per theme (see THEMES.md) |
| `~/.config/pc-lights/profile.json` | the hardware profile (see PROFILE.md) |
| `~/.config/pc-lights/scheme`, `day-scheme` | the active theme, the day theme |
| `~/.config/pc-lights/lights`, `screens`, `clips` | `on`/`off` states |
| `~/.config/pc-lights/alerts.json` | heat-warning defaults (`{"enabled", "cpu": {"threshold"}, "gpu": {...}, "color"}`) |
| `~/.config/pc-lights/schedule.json` | `{"enabled", "night_theme", "night_start", "night_end"}` |
| `~/.config/pc-lights/omarchy-map.json` | Omarchy slug → theme, `"_default": "auto"` |
| `~/.config/pc-lights/tools/` | your own copies of the tools; they win over the shipped ones |
| `~/.config/pc-lights/drafts/` | the editor's drafts (`<name>.json`) and their staged screen media (`<name>.media/media/`) |
| `~/.config/pc-lights/desktop.json` | the desktop wallpaper settings per theme (see "Desktop wallpaper") |
| `~/.cache/pc-lights/` | lock, `busy.json`, `last-run.json`, `pending/`, `previews/`, `clips.json`, the OpenRGB listing cache, compiled themes, `preview.json` and `preview/`, `media/` (jobs, probe index, hashes; MEDIA.md), `thumbs/`, `desktop/` (`owned`, `state.json`, `lock`) |
| `~/.config/lianli/config.json` | lian-li-linux's config: written by lumenaire, never edit it by hand while lumenaire is in use |

The engine always uses `$HOME/.config` and `$HOME/.cache` (not the XDG
variables), so `HOME=<scratch> lumenaire …` is a complete sandbox.

## Units, hook and timers

`lumenaire install --units --hook` puts these in place (see the README):

| Unit | Does |
| --- | --- |
| `pc-lights.service` | at login: a schedule tick, then `apply-openrgb` (OpenRGB devices forget their state at power-off; Lian Li gear keeps its own) |
| `pc-lights-schedule.timer` | every minute: `schedule tick` (acts only at a day/night boundary) |
| `pc-lights-clips.timer` | every 30 s: `clips tick` (swaps a screen's clip when it is due) |
| `pc-lights-feeds.timer` | every minute: `pc-lights-feeds`, cached numbers for LCD template widgets (only installed when `pc-lights-feeds` exists) |
| `~/.config/omarchy/hooks/theme-set.d/pc-lights` | on an Omarchy theme change: `lumenaire omarchy <slug>` in its own transient unit |

`lumenaire install --desktop` adds the desktop wallpaper's callers (see
"Desktop wallpaper"):

| Unit or file | Does |
| --- | --- |
| `~/.local/bin/motion-wallpaper-theme` | the shim (a link to `lib/pc-lights/tools/motion-wallpaper-theme`): `lumenaire desktop sync`, or `toggle` |
| `~/.config/omarchy/hooks/theme-set.d/motion-wallpaper-theme` | on an Omarchy theme change: the shim, which syncs |
| `motion-wallpaper-theme.path` | watches `~/.local/state/omarchy/current` and starts `motion-wallpaper-theme.service` (the shim, a sync) when the wallpaper changes within a theme |
| `motion-wallpaper-monitors.service` | in the graphical session: `motion-wallpaper-theme watch` (`lumenaire desktop watch`), a sync whenever a monitor comes, goes or is turned (enabled and started) |

Transient units: `pc-lights-ui-<op>-<ns>` (plugin changes), `pc-lights-omarchy-*`
(the hook), `pc-lights-apply-*` (debounced Omarchy applies), `pc-lights-previews`,
`lumenaire-preview-w<ns>` (a theme preview pass) and the `lumenaire-preview-reap`
timer (see "Theme preview"; `PCL_PREVIEW_UNIT` renames both), and the media
pipeline's `lumenaire-media-<job>` (one prepare, memory-capped) and
`lumenaire-media-index` (probes and thumbnails; MEDIA.md).

## Schedule, clips and Omarchy pairing

**Schedule.** With `schedule.json` enabled, the timer switches to the night
theme at `night_start` and back to the day theme at `night_end`, once per
boundary, so a manual pick at night holds until the next boundary. The window
may cross midnight.

**Clips.** A theme screen with `"clips"` (files or folders) and `"rotate"`
(seconds) cycles through them. A swap touches only that screen (about 1 s) and
never restarts anything. `clips pause`/`resume` freeze and resume the
countdown.

**Omarchy pairing.** The hook runs `lumenaire omarchy <slug>`, which maps the
slug through `omarchy-map.json`. An unmapped slug (or `"auto"`) runs
`tools/auto-theme <slug>`, which builds `themes/omarchy-<slug>/` from the
Omarchy theme's `colors.toml` and wallpaper in a few seconds: LED-safe lighting
from the palette, and, when the profile has LCD screens, fan, pump and 8.8"
art from the wallpaper. The apply is debounced by 5 s, so flipping through
Omarchy themes applies only the last one. At night the result only becomes the
day theme.

## Theme preview

`lumenaire theme preview <name>` shows the unsaved draft of a theme (the
editor keeps drafts in `~/.config/pc-lights/drafts/`) on the case while you
edit it, and gives the saved look back when you stop. Nothing is saved: the
active theme and the run bookkeeping (`busy.json`, `last-run.json`) never
change, and the daemon config only holds a screen's previewed media while
the preview shows it (see "The screens" below).

**Fast, and only what changed.** A normal apply takes about 20 s (a full
config write, a reload check, wireless re-sends, an OpenRGB device listing).
A preview pass instead:

1. compiles the draft (`editor_draft_eff`) and builds its Lian Li device
   entries with the very filter an apply uses (`LIANLI_RGB_JQ`), against one
   `GetRgbCapabilities`, without the screens or the heat alert;
2. compares them per zone and per region with what the case shows (first
   the saved config, then what the preview last sent);
3. sends only the differences, one guarded `SetRgbEffect` each, through one
   `GetDaemonInfo` for the whole batch (`daemon_guarded_batch`): a TL fan
   group gets one per region (Top and Bottom, on zone 0), a Strimer or a ring
   one per zone. No journal wait, no re-send loop, never a daemon restart; a
   device that fails is listed and sent again on the next pass;
4. runs OpenRGB (GPU, board, RAM) only when its arguments changed, with the
   RAM ids the last real apply cached, never a device listing (it probes the
   SMBus). It is never killed; the next Lian Li pass waits for it.

**Two methods**, chosen once by a hardware check:

| Method | Write | A crash or daemon restart |
| --- | --- | --- |
| `effect` | `SetRgbEffect` per zone/region, not persisted | brings the saved look back by itself |
| `rgbconfig` | `SetRgbConfig` of the rgb section (persisted, reloaded) | the section saved at the start must be sent back; the reaper makes sure it is |

The method comes from `~/.config/pc-lights/preview-method`, else the profile's
`preview.method`. With neither, `theme preview` refuses: exit 2, code
`unmeasured` ("Live preview needs a one-time hardware check: run lumenaire
theme preview --measure"). `--measure` runs `tests/preview/measure.sh`, an
interactive check that asks before each step and puts the saved look back
after it (M1-M8: a TL region, six Strimer colours, the pump and screen rings,
the revert, a clip swap, `SetRgbConfig`, one cached-id OpenRGB apply, a
daemon restart); `effect` needs M1-M4 and M8, `rgbconfig` needs M6. It offers
to write the method file at the end.

**The worker.** `theme preview` records the wanted draft rev in
`~/.cache/pc-lights/preview.json` (under its own small lock,
`preview.lock`), starts a worker unit when none runs, and returns at once:
`{"queued": true, "rev": N, "id": …}`. The worker takes the main lock for one
pass at a time, waiting at most 3 s: with an apply running it marks the
session `blocked` (with that apply's `{op, theme, unit}`) and stops, because
a preview never queues behind an apply; the reaper retries. It loops until the
applied rev catches up with the wanted one. SIGTERM lets the running daemon or
`openrgb` call finish, then marks the session; the unit uses
`KillMode=mixed` so a stop never kills `openrgb`.

**Ending.** `--end` (the editor closed, "Back to saved") queues the revert to
the worker, which waits for the lock as long as it takes. The revert sends
every zone and region of each device the session touched from the saved
config (or the saved rgb section under `rgbconfig`), and OpenRGB for the
active theme if the preview changed it. `--end` is idempotent. The UI sends
`--keepalive` every 30 s (`--edited` also resets the idle timer); the
`lumenaire-preview-reap` timer (every 30 s, and the schedule and clip ticks)
ends a session with no heartbeat for 90 s (`ui-gone`) or no edit for
`idle_ttl` (default 600 s, `--idle`), and stops itself once the session is
over.

**The screens.** Each pass sends the screens first, then the lights (under
method `effect` a screen's config reload re-sends the saved RGB, so the
lights must come after it):

1. `lianli_screen_plan` works out, per screen of the draft's EFF, what it
   must show: the daemon config's own entry for that screen (matched by USB
   serial or its `hid:1cbe:…` form; a screen without one is skipped, never
   appended) with the draft's type, path (absolute: the draft's stage, then
   its media root; never a scratch path), orientation, template and
   brightness. A template the daemon doesn't have is skipped
   (`template-missing`: the preview never installs templates; it shows after
   a save).
2. The config entry of every screen it is about to touch for the first time
   is kept in `preview/saved-lcds.json`.
3. One read-only `CheckMediaAccess`: a file the daemon can't read is left
   out (that screen reads `failed`, reason `access`).
4. One batch: a guarded `SetLcdMedia` (`device_id` `"serial:<config
   serial>"`) for a screen whose media changed, a guarded `SetLcdBrightness`
   (the bare config serial) for a brightness alone. `SetLcdMedia` persists
   (the daemon writes config.json and reloads); `SetLcdBrightness` doesn't.
   A screen the draft no longer names gets its saved entry back.
5. Under `effect`, after a media change: the reload is waited for (up to 8 s)
   and every device the preview had lit is sent again in full.
6. After the pass (the lock dropped), the worker follows `GetTelemetry`
   (read-only, every 0.5 s, up to 20 s, 45 s for the pump) until each new
   screen reports `ready`, `failed` (with the daemon's error) or off USB.

The end sends the screens back first: `SetLcdMedia` with the saved entry
where the media changed, `SetLcdBrightness` where only the brightness did,
then the lights, then OpenRGB. When the screens can't all go back (the
daemon is away), their snapshot stays and the schedule and clip ticks try
again every minute; the media GC never deletes a file the daemon config
names, so a previewed screen never loses its file. With the screens off
(`off screens`) the screens part is skipped (`screens-off`).

**Everything else goes first.** With no session, none of this runs (one file
test). With one:

| Path | While a preview runs |
| --- | --- |
| `pick`, a schedule switch, an Omarchy switch (`switch_to`) | the screens and Lian Li revert first (it holds the lock), then the apply; ended `cancelled` by `{op, theme}` (`pick`, `schedule`, `omarchy`) |
| `on lights`/`all`, `apply-openrgb` | the same (`on`, `apply-openrgb`) |
| `off lights`/`all` | ended `lights-off`: the screens sent back, the lights not (Off replaces them) |
| `on screens` | ended `cancelled` by `on`: everything sent back (OpenRGB too), then the screens' brightness |
| `off screens` | ended `screens-off`: everything sent back, then the screens go dark |
| `schedule tick` | deferred: "schedule: deferred while a theme preview runs", the boundary stays unhandled and the next minute retries (bounded by the heartbeat and idle limits) |
| `clips tick`, `clips next` | no swap (a `SetLcdMedia` reload could re-send the saved lighting); `clips next` ends skipped, "a theme preview is running" |
| `theme save` (the editor) | `preview_yield saved`: ended, no revert when the save applies right away (its pick rewrites the screens), a full revert otherwise |

Lights off refuses a preview (exit 2, `lights-off`); a draft with problems
too (exit 2, `invalid`, with `problems`), and the last good preview stays.

**The session file** (`preview.json`, also `preview` in `status --json`):

```json
{"v": 1, "id": "p-1790000400123", "theme": "sakura-2", "draft": "…/drafts/sakura-2.json",
 "state": "queued|applying|live|blocked|ending|ended|failed", "worker": true, "method": "effect|rgbconfig",
 "want_rev": 14, "applied_rev": 13,
 "lianli": {"state": "ok|failed|skipped", "sent": 7, "failed": [{"device_id": "…", "error": "…"}], "at": 1790000401, "ms": 420},
 "openrgb": {"state": "idle|pending|applying|ok|failed|skipped", "rev": 12, "at": 1790000395, "ms": 8400},
 "blocked_by": null, "started": 1790000300, "touched": 1790000400, "edited": 1790000400,
 "heartbeat_ttl": 90, "idle_ttl": 600, "idle_ends": 1790001000,
 "ending": null, "ended": null, "error": null}
```

`blocked_by` is `null`, `{"op", "theme", "unit"}` (an apply holds the lock),
`"heat-alert"`, `"rgb-sync"` or `"invalid"`. `ending` is `{"reason", "by",
"revert", "screens"}` while an end waits for the lock. `ended` is `{"at",
"reason": "saved|reverted|panel-closed|closed|idle|ui-gone|cancelled|lights-off|screens-off",
"by": {"op", "theme"} | null, "reverted", "screens_reverted"}` (`reverted`:
the lights went back; `screens_reverted`: the screens did, `null` when none
was touched). The screens part:

```json
"screens": {"state": "idle|sending|live|failed|skipped", "reason": null, "sent": 2, "at": 1790000401, "ms": 640,
  "roles": {"screen.pump": {"state": "sent|preparing|ready|failed|skipped|off-usb", "what": "media|brightness",
                            "error": null, "reason": null, "gen0": 30, "since": 1790000401}},
  "failed": [{"role": "screen.fan3", "error": "…"}]}
```

`screens.reason` (skipped): `screens-off`, `lianli-skipped`, `lianli-down`,
`no-profile`; a role's `reason`: `not-in-config`, `missing`,
`template-missing` (skipped) or `access` (failed). The applied state lives
beside it in `~/.cache/pc-lights/preview/`: `applied-rgb.json`,
`touched.json`, `applied-orgb.args`, and `saved-rgb.json` under `rgbconfig`
(the lights); `saved-lcds.json`, `applied-lcds.json` and `touched-lcds.json`
(the screens). `tests/fixtures/preview.live.json` and
`tests/fixtures/preview.screens.json` are frozen examples.

## Desktop wallpaper

The Motion Wallpaper plugin (`nosignal.motion-wallpaper`,
github.com/28allday/Motion-Wallpaper-Omarchy) plays a video as the Omarchy
desktop background. `lumenaire desktop` makes it follow the theme, with
settings per Lumenaire theme. The engine only talks to the plugin; it never
installs or changes it.

**Animated wallpapers.** An Omarchy theme ships an animated version of any of
its wallpapers in a hidden folder beside them, under the still's name:
`backgrounds/.animated/1-moonlit-branch.mp4` (or `.webm`, `.mkv`) for
`backgrounds/1-moonlit-branch.jpg`. Being hidden, Omarchy's wallpaper cycling
never picks it. The theme's own folders are searched first
(`~/.config/omarchy/themes/<slug>/backgrounds`,
`~/.config/omarchy/backgrounds/<slug>`, then the stock
`$OMARCHY_PATH/themes/<slug>/backgrounds`), then the folder of the wallpaper
on screen: Omarchy replaces its working copy (`current/theme`) on every
switch, so a clip played from there could vanish under the player.

**Portrait monitors.** Beside the animated version, a theme may ship a
portrait one, framed for a monitor turned a quarter: `<still>.portrait.mp4`
(or `.webm`, `.mkv`), e.g. `backgrounds/.animated/1-moonlit-branch.portrait.mp4`,
found in the same folders in the same order. A monitor is portrait when
`hyprctl monitors -j` gives it transform 1 or 3 (5 and 7, the same turns
flipped, count too); a disabled monitor isn't listed. The plugin keeps a
clip per monitor (`screenVideos`, its "screen" source) over the main one, so
a sync plays the main clip on every monitor, then gives each connected
portrait monitor the portrait clip (`playOn <connector> <clip>`). Without a
portrait version (another theme, another wallpaper, `animated: false`, the
toggle to still, the user's own main clip), or once the monitor is unplugged
or turned back, a per-monitor clip Lumenaire set is dropped (`clearScreen
<connector>`), so that monitor follows the main clip again.
`~/.cache/pc-lights/desktop/owned-screens.json` (`{"<connector>": "<clip>"}`)
holds what it set. A per-monitor clip the user picked in the plugin's panel
(one that isn't in that file and not in any theme's `.animated` folder,
including a monitor they blanked with `""`) is never replaced or cleared;
nor are they dropped by a main clip change: with per-monitor clips in
place, the main clip goes through `play` (plus `setOutput all` when the
plugin targets one monitor) instead of `playAll`, which clears them all. A
plugin whose status has no `screenVideos` gets no per-monitor calls. A
portrait version without a main one is not used.

**Settings per theme.**

| Setting | `set` key | Values | Default | Sent to the plugin as |
| --- | --- | --- | --- | --- |
| `animated` | `animated` | `true` / `false` | `true` | `playAll` (or `play`) / `stop` of the theme's clip, `playOn` / `clearScreen` of its portrait clip |
| `pause_while_active` | `pause` | `true` / `false` | `true` | `setPauseWhileActive` |
| `resume_after_idle` | `resume` | 1-600 (seconds) | `5` | `setResumeAfterIdle` |
| `while_active` | `while` | `freeze` / `still` | `"freeze"` | `setWhileActive` |

The desktop is on the Lumenaire theme its Omarchy theme pairs with, through
`omarchy-map.json` exactly as the Omarchy pairing does (`omarchy_theme_for`
in bin/lumenaire, which `omarchy_pair` shares): `sakura` and `sakura-light`
both map to `sakura` and share its settings; an unmapped slug (or `"auto"`)
is `omarchy-<slug>`, built or not. Without Omarchy it is the active theme.

The settings live in `~/.config/pc-lights/desktop.json`, never in
`theme.json` (auto-themes are regenerated, and the editor keeps a history of
`theme.json`):

```json
{"v": 1,
 "defaults": {"animated": true, "pause_while_active": true, "resume_after_idle": 5, "while_active": "freeze"},
 "themes": {"sakura": {"animated": false}, "stealth": {"while_active": "still", "resume_after_idle": 30}}}
```

A missing file means all defaults. `defaults` in the file wins over the
built-in ones; a theme lists only what differs. Unknown keys and invalid
values are ignored when read, so a bad hand edit falls back instead of
failing. Writes are atomic (tmp + mv).

**Commands.**

- `desktop [--theme T] [--json]`: the view below (text without `--json`). It
  reads the plugin's status and changes nothing (but for the one-time
  migration, see the end of this section).
- `desktop set [--theme T] <key> <value>`: checks the value, stores it for T
  (default: the desktop's theme), and when T is the desktop's theme applies
  that setting at once: `animated` plays or stops the clip, a pause setting
  sends its setter if the plugin has another value. It prints T's view. A bad
  request exits 2 with `{"error", "code"}`: `usage` (no such key, wrong
  arguments), `invalid` (a bad value), `not-found` (no such theme); `busy`
  (exit 75) if the lock stays held for 10 s.
- `desktop reset [--theme T]`: removes T's own settings from `desktop.json`,
  so it follows the defaults again (the panel's "Use defaults"), applies them
  when T is the desktop's theme, and prints T's view; same exit codes as `set`.
- `desktop sync`: applies the desktop's theme. Each pause setting is sent only
  when it differs from the plugin's status. The theme's clip for the
  wallpaper on screen plays (`playAll`, every monitor) when `animated` is on,
  and its portrait clip on each portrait monitor (see "Portrait monitors");
  otherwise the clip Lumenaire started stops and its per-monitor clips are
  dropped, so `animated: false` acts like "no animated version". With no
  wallpaper at all (a switch half done) the playback stays as it is.
- `desktop toggle` (the key): flips what is on screen. A clip playing (the
  plugin's playback: a clip it holds still while you type counts) stops
  (the still wallpaper) and the theme gets `animated: false`; otherwise the
  theme's clip plays (or, when it has none, the last clip comes back) and the
  theme gets `animated: true`. An OSD says what happened
  (`omarchy osd -i <glyph> -m …`): `󰕧 Sakura · animated wallpaper`,
  `󰋩 Sakura · still wallpaper`, `󰋩 Sakura has no animated wallpaper`.
  The portrait clips follow: dropped when it goes still, played with the
  theme's clip.
- `desktop watch` (the `motion-wallpaper-monitors` service): a sync, then
  one after every monitor change. It reads Hyprland's event socket
  (`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`, else
  the newest one there) through `socat`, and syncs on `monitoradded`,
  `monitorremoved` (and their `v2` forms: a hot-plug) and `configreloaded`
  (a monitor turned in the config). A burst of events settles first (1 s
  quiet, at most 3 s) and gets one sync, each a child `lumenaire desktop
  sync`, so the lock keeps it in line with the hook. Every other event is
  ignored. It exits 1 without a socket and 0 when the stream ends (Hyprland
  restarted); the unit restarts it after 3 s either way. A socket listener
  rather than polling: it costs nothing between events and reacts at once.

`sync` and `toggle` take `--json` to print the view afterwards.

**A clip the user picked is left alone.** `~/.cache/pc-lights/desktop/owned`
is the clip Lumenaire started, and the only one a sync ever stops. A clip on
screen that is neither owned nor the theme's own (picked in the plugin's
panel) is never replaced or stopped by a sync; `user_clip` says so. The
toggle is the user's own choice, so it stops whatever plays. A clip whose
file is gone doesn't count as playing.

**The plugin's IPC.** Each command reads `omarchy-shell motion-wallpaper
status` once, without `-q` (`-q` is quiet: the shell swallows the reply),
and sends changes with `-q`; a sync with nothing to change is that one read.
With the shell down or not answering (`"reason": "shell-down"`) or the plugin
missing (`"no-plugin"`) every command exits 0 with `"available": false`. A
plugin without the pause settings (the unpatched upstream one) gets no
setters. `~/.cache/pc-lights/desktop/lock` (flock, up to 10 s) keeps the
hook, the watchers and the key from racing; `state.json` beside it holds what
the last sync, toggle or set saw (`{v, available, omarchy_theme, theme,
has_animated, portrait, playing, user_clip, at}`), which status --json reads
(its `desktop` block: `{available, theme, settings, playing, portrait, at}`;
`portrait`, additive, is true when the wallpaper on screen has a portrait
version).

**The view** (`desktop --json`), always these keys:

```json
{"v": 1, "available": true, "reason": null, "omarchy_theme": "sakura-light", "theme": "sakura",
 "background": "/home/me/.local/state/omarchy/current/theme/backgrounds/1-moonlit-branch.jpg",
 "has_animated": true, "playing": true, "user_clip": false,
 "screens": [{"name": "DP-3", "portrait": false, "clip": "/home/me/.config/omarchy/themes/sakura/backgrounds/.animated/1-moonlit-branch.mp4", "playing": true},
             {"name": "HDMI-A-1", "portrait": true, "clip": "/home/me/.config/omarchy/themes/sakura/backgrounds/.animated/1-moonlit-branch.portrait.mp4", "playing": true}],
 "settings": {"animated": true, "pause_while_active": true, "resume_after_idle": 5, "while_active": "freeze"},
 "stored": {},
 "defaults": {"animated": true, "pause_while_active": true, "resume_after_idle": 5, "while_active": "freeze"}}
```

`settings` are the values in effect, `stored` the theme's own (partial),
`defaults` what the rest falls back to. `background`, `has_animated`,
`playing` and `user_clip` describe the screen, so they are `null` for a
`--theme` that isn't the desktop's; `playing` and `user_clip` are also `null`
while the plugin can't be asked. `screens` (additive) lists each connected
monitor: `portrait`, the `clip` the plugin is set to show there (its own
clip, else the main clip; `null` when stopped, blanked or unknown) and
whether it is `playing` (that clip's file is there); `null` for another
`--theme`. The text view adds a `monitors:` line when there are several.

**Who calls it.** Four callers, all through the shim
`~/.local/bin/motion-wallpaper-theme` (a link to
`lib/pc-lights/tools/motion-wallpaper-theme`: `exec lumenaire desktop
"${@:-sync}"`, with `~/.local/bin` as a PATH fallback for the units):

1. the Omarchy theme-set hook
   `~/.config/omarchy/hooks/theme-set.d/motion-wallpaper-theme` runs it on
   every theme switch: a sync;
2. `motion-wallpaper-theme.path` watches the folder
   `~/.local/state/omarchy/current` (`PathModified`: `omarchy theme bg set`
   replaces the background link with `ln -nsf`, which a watch on the link
   itself misses) and starts `motion-wallpaper-theme.service`, the shim: a
   sync, so cycling wallpapers within a theme is followed;
3. `motion-wallpaper-monitors.service` runs `motion-wallpaper-theme watch`
   (`desktop watch` above): a sync on every monitor hot-plug, so a portrait
   monitor plugged in gets its clip;
4. a key binding runs `motion-wallpaper-theme toggle`, for instance in
   `~/.config/hypr/bindings.lua`:

   ```lua
   o.bind("SUPER + SHIFT + ALT + SPACE", "Toggle animated wallpaper",
     os.getenv("HOME") .. "/.local/bin/motion-wallpaper-theme toggle")
   ```

`lumenaire install --desktop` puts the shim link, the hook and the three
units in place, enables and starts the path unit and the monitor watcher,
and prints that binding; it never edits `bindings.lua`.

**From the standalone script.** `~/.local/bin/motion-wallpaper-theme` used
to be a script of its own, with a "still" choice per Omarchy theme. The
first `desktop` command (not status --json) moves its state over, once: each
`~/.local/state/motion-wallpaper-theme/still/<slug>` becomes `animated:
false` for the theme the slug pairs with, and the folder is renamed
`still.migrated`; its `owned` moves to `~/.cache/pc-lights/desktop/owned`
(the old file is renamed `owned.migrated`).

## The JSON interface (contract v1)

The plugin reads three lock-free commands and never waits on the lock:

- `status --json` (~20 ms): `{"v": 1, "v_minor": 1, theme, lights, screens,
  busy, pending, last_run, daemon_unit, screens_on_usb: {have, want}, alert,
  schedule, omarchy, rotation, previews_building, profile: {state, machine,
  backends, new_devices, missing_devices, sensors, pump_device, groups},
  labels}`. `"v"` stays 1: every addition is optional, and an older plugin
  keeps working.
- `themes --json`: one entry per theme with its colours, swatch, preview, and
  (v1.1) `schema`, `palette` and `coverage` (how much of the theme this PC can
  show, see THEMES.md).
- `sensors --json`: where the CPU, GPU, coolant, pump and RAM readings come
  from on this PC (`null` when there is none), resolved at call time.
- v1.2 (the theme editor): `status --json` has `"v_minor": 2`, `preview`
  (the session file above, or `null`) and `drafts` (`[{name, mode, from,
  rev, updated}]`); `themes --json` has per theme `draft` (`{rev, updated}`
  or `null`), `editable` and `edit_block` (`null`, `"no-profile"` or `"v2"`).
- v1.3 (screen media): `status --json` has `"v_minor": 3` and `media`
  (`{running, jobs}`, MEDIA.md); the preview session gains `screens`.
  `theme screens --json` is the screens view (THEMES.md, "Editing screens").
- v1.4 (the desktop wallpaper): `status --json` has `"v_minor": 4` and
  `desktop`: `{available, theme, settings, playing, at}`, the desktop's theme
  and its settings from `desktop.json`, `available`, `playing` and `at` from
  the last sync's `state.json` (all three `null` before the first one). No
  IPC: the plugin's live state is `desktop --json` ("Desktop wallpaper").

Changes go through `lumenaire --detach <cmd>`: it validates at once (exit 2
and `{"error": …}` on a bad request), starts the command in its own user unit
and prints `{"queued": true, "unit": …}`. Allowed: `pick <name>`,
`on|off [target]`, `schedule on|off`, `clips next --nowait`,
`previews [--force] [names]`, `detect [--probe|--no-openrgb]`.

## Layout of the code

```
bin/lumenaire                     core: globals, lock, run bookkeeping, schedule,
                                  Omarchy pairing, clips, --detach, the dispatcher
bin/pc-lights                     the old name: a two-line wrapper that execs bin/lumenaire
lib/pc-lights/theme.sh theme.jq   theme lookup, validation, v3 compile, explain
lib/pc-lights/backends.sh         the backend interface, render
lib/pc-lights/backend-*.sh        one file per backend
lib/pc-lights/profile.sh detect.sh  the hardware profile
lib/pc-lights/json.sh sensors.sh previews.sh migrate.sh install.sh
lib/pc-lights/editor.sh editor.jq the theme editor (drafts, set, save, screens, staging; THEMES.md)
lib/pc-lights/media.sh media.jq   screen media: list, probe, thumbnails, prepare jobs, GC (MEDIA.md)
lib/pc-lights/preview.sh          the theme preview: session, worker, reaper, the hooks' preview_yield
lib/pc-lights/desktop.sh          the desktop wallpaper per theme: settings, sync, toggle, the migration
lib/pc-lights/models.json         LCD models: aspect, media size, default orientation
lib/pc-lights/calibration-presets.json
lib/pc-lights/tools/              auto-theme, lcd-preview, nrbf.py, motion-wallpaper-theme (the shim)
systemd/ hooks/ workarounds/ examples/   what `lumenaire install` puts in place
```

The engine finds `lib/` beside its real path, so `~/.local/bin/lumenaire` and
`~/.local/bin/pc-lights` can be symlinks into the plugin folder or a clone.
`PCL_LIB` overrides it. A tool in `~/.config/pc-lights/tools/` wins over the
shipped copy.

**Names.** The product is Lumenaire, the engine command `lumenaire`, and the
Omarchy plugin "Lumenaire for Omarchy" (`io.github.nocstah.lumenaire`, IPC
target `lumenaire`, log prefix `[lumenaire]`). The plugin was briefly named
OmaLights; that name is retired. The engine's first name stays wherever
renaming would move data or break a caller: the `pc-lights` command (an alias),
the units and the hook, the journal tag `pc-lights`, the transient units
(`pc-lights-ui-*`, `pc-lights-previews`), the state folders
`~/.config/pc-lights/` and `~/.cache/pc-lights/`, `lib/pc-lights/`, and the
`PCL_*` environment variables. The engine's own messages still say
`pc-lights`, so its output stays byte-identical to the goldens.

**Tools.** `tools/lcd-preview <template.json> [out.jpg]` renders an LCD
template through the running daemon (read-only). `tools/nrbf.py` decodes
L-Connect `.template` files (.NET BinaryFormatter) so you can port a Windows
screen layout. `tools/auto-theme` is described above; `--schema 2` keeps the
legacy output for an engine that hasn't been migrated.

**Heavy jobs.** Previews and auto-themes run their ffmpeg and ImageMagick work
through `pcl-heavy`, which puts each job in its own memory-capped cgroup and
runs at most two at a time.

## Testing

- `tests/engine-contract.sh` runs the whole CLI contract against a scratch
  `$HOME` with the hardware calls stubbed.
- `PCL_TEST_OVERRIDES=<file>` is sourced after every function is defined and
  before the dispatcher, so a test can replace any function (`daemon_call`,
  `lianli_lights`, `apply_openrgb`, `systemctl`, …). `--detach` passes it on to
  the unit it starts.
- `tests/golden/` compares `render` output byte for byte against captured
  goldens; `tests/detect/`, `tests/theme/` and `tests/migrate/` use sanitised
  fixtures. No test reads the live theme dir: each capture freezes its
  themes and profile (`tests/golden/README.md`).
- `tests/preview/run.sh` (also section 9 of `engine-contract.sh`) tests the
  theme preview against a fake daemon (`fake-socat` first in `PATH`, answers
  from `tests/preview/fixtures/daemon/`, every write recorded; knobs for a
  restart, errors, the screens' telemetry and unreadable media): request
  shapes per device type, diffing, the screens part (only differing screens,
  the device id forms, the snapshot and a byte-exact revert, telemetry
  states), the hooks, the reaper, SIGTERM, both methods.
  `tests/preview/measure.sh` is the manual hardware check; no test runs it.
- `tests/lianli/run.sh` unit-tests the Lian Li helpers that run after a
  live reload (`nudge_new_image_lcds`) with `daemon_guarded`, `log` and
  `sleep` stubbed: which screens get nudged, the order and the exact final
  entry, and a refused send.
- `tests/ramdrift/run.sh [--real-openrgb]` tests the RAM drift: the frame
  math and the animator against `fake_openrgb.py` (a fake SDK server with
  two ENE DRAM sticks: handshake, Direct mode, frame 0 first, stick order,
  skipped unchanged frames, exit on SIGTERM / lights off / a held lock / a
  dead child), then the engine hooks in a fixture `$HOME` with a fake
  `openrgb` and `systemctl` first in `PATH` (the engine runs OpenRGB through
  `timeout`, which a shell-function stub can't catch): stop before every
  OpenRGB call, start after an apply only with the lights on and a drift,
  render untouched, preview and detect, the editor keeping the key.
  `--real-openrgb` adds the real `openrgb --nodetect` (no hardware detected)
  for the SDK handshake and its idle CPU.
- `tests/desktop/run.sh` tests the desktop wallpaper against a fixture
  `$HOME` with `fake-omarchy-shell` (the plugin's IPC on a status file it
  changes; `-q` prints nothing, like the real one) and `fake-omarchy` (the
  OSD) first in PATH: the mapping (checked against what `omarchy_pair`
  queues), set and its exit codes, sync and ownership, the setters only on a
  change, toggle and its OSD, the migration, the shell down, the lock,
  status --json v1.4 with no IPC and its 40 ms median, portrait monitors
  (`fake-hyprctl` gives the monitors from `$HOME/monitors.json`; the fake
  shell knows `playOn`, `clearScreen`, `screens` and `setOutput`): a
  portrait clip or none, two portrait monitors, an unplugged or turned one,
  the user's per-monitor clips left alone, the overrides cleared on a
  theme switch, `animated: false` and the toggle; `desktop watch` against
  `fake-socat` (events from `$HOME/socat-script`); the shim and
  `install --desktop`.
- `tests/editor/run.sh` tests the editor, the screens view (against
  `tests/fixtures/screens.sakura.json`), the `theme media` verbs, staging and
  the media side of save, with B1's pipeline stood in for by fakes.
