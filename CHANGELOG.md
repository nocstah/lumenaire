# Changelog

## Unreleased

### RAM drift: a gradient that moves

- A theme's RAM gradient can drift: `"ram": {"gradient": [...], "drift":
  {"period": 120}}` slides the colours slowly along the sticks as one closed
  loop, one whole loop per period (docs/THEMES.md "RAM drift"). The sticks'
  own effects can't do this in your colours.
- `lumenaire-ram-drift.service` does it with a private OpenRGB that sees
  only the RAM. The engine stops it before every OpenRGB call (so two
  OpenRGBs never share the SMBus) and starts it after an apply only when the
  lights are on and the theme drifts. `lumenaire install --units` installs
  it; it is never enabled on its own. `lumenaire ram-drift status` shows it.
- Themes without `drift` apply exactly as before.

### Lian Li screens: off really goes dark, and images show up

- Turning the screens off left them at full brightness: the daemon saves
  the brightness in a live reload but never sends it to the panel. Every
  live reload now sends each screen its brightness directly.
- A fan screen that goes from a video to a still image on a theme switch
  kept the old picture (the daemon wipes the panel while stopping the old
  video and never re-sends the image). Those screens are now refreshed
  once the switch settles.

### Portrait monitors get their own animated wallpaper

- A theme can ship a portrait version of an animated wallpaper beside it,
  `backgrounds/.animated/<still>.portrait.mp4`: it plays on every monitor
  turned a quarter, the main clip on the rest. Without one a portrait
  monitor shows the main clip, as before. A clip you gave one monitor in
  Motion Wallpaper's panel stays yours.
- `lumenaire install --desktop` adds `motion-wallpaper-monitors.service`,
  which follows monitors being plugged in, unplugged or turned.

### Wallpaper settings per theme in the panel

- A **Wallpaper** row under the night theme, with the Motion Wallpaper
  plugin: "Animated · pauses while you work", "Animated", "Still" or "No
  animated version" for the theme the desktop follows, and a switch between
  animated and still. It opens the theme's **Wallpaper page**; so does
  Wallpaper… in any card's right-click menu.
- The page sets the theme's own: Animated wallpaper, Pause while you work
  (it holds still while you use the keyboard or mouse), Resume after 3 s ·
  5 s · 10 s · 30 s, and While you work: Freeze or Show still image. Every
  change applies at once, no Save; Use defaults takes the theme back. The
  engine's `lumenaire desktop` does the work (contract v1.4).

### Screens in the editor

- The editor has a **Screens** section: the case's LCDs as a small map (the
  top fans in a row, the side column, the pump in the middle, the 8.8" screen
  under it; another PC gets its own layout, a round pump drawn round), each
  showing its media as a picture. A changed screen has the accent outline;
  one line under the map says the first thing that matters ("Fan 3 couldn't
  be prepared", "Pump: preparing… 42 %", "Updating…", "On the case").
- A tile opens that **screen's page**: its picture with Change… and Remove,
  its brightness (in steps of 5, "Use default" to go back), for the pump a
  list of clips that take turns (reorder by dragging, ↑ ↓ or the keyboard,
  add and remove, Change every 1 min · 5 min · 15 min · 1 h · Off, Shuffle),
  and for the 8.8" screen Shows: Clock and stats or Picture or video.
- **Change…** opens a picker with three places to look: This theme, Library
  (your other themes and the L-Connect clips) and My files (Videos and
  Pictures), with search, best fits first and one short line per file ("0:12",
  "Picture", "0:42 · cropped", "Doesn't fit"). A file that fits is prepared
  at once; one of another shape opens a **crop page**: drag the frame, zoom,
  pick the moment of a video, and Use.
- Preparing runs in the engine's own capped unit, never in the shell:
  "Preparing… 42 %" with Cancel, or "Couldn't prepare it" with Try again or
  Choose another (why is the tooltip). Save waits until it's done. When no
  editor shows it, the main page says so in one notice.
- Your files are only read. File names, sizes and paths stay in tooltips.

### A calmer panel, and new themes in two steps

- The main page reads top to bottom: the name and the active theme with
  **Edit**, ⋯ (Refresh, Rebuild previews, Show log under the last change) and
  ✕; calm notices; one row of readings (coolant, pump, the mean fan speed,
  CPU, GPU, with the detail in their tooltips); Lights and Screens as tiles,
  with one row for the pump video and one for the night theme under them, so
  every quick control shows without scrolling; then the themes in two
  columns without swatch strips. The footer and the command-line
  instructions are gone.
- Corners follow Omarchy: square when Hyprland's rounding is 0, rounded like
  the rest of the shell when a theme rounds, switches included. Swatches,
  colour chips and previews cap theirs so they keep their shape.
- **New theme** is a two-step page: start from one colour, your desktop's
  colours, a copy of a theme or a surprise palette, then name it (the name as
  you type it; a one-click fix when it's taken). The editor opens on the new
  draft with the preview on the case at once.
- **Editing** starts from Edit in the header, the pencil on a card or its
  right-click menu (Edit, Duplicate, Rename…, Delete…); the "Edit…" mode is
  gone. The editor shows Show on case, the three theme colours (Main, Second,
  Accent) and one row per part of the case, with Advanced (vivid LED colours,
  this PC's colour correction, the heat warning colour) folded away.
- Leaving the editor never asks: the draft is kept, the card says "Draft", and
  reopening it says so in one line. Save on the theme that is on the case
  also applies it; saving another offers "Use it now?".
- Three kinds of button (primary, outlined, icon) and plain words throughout;
  see DESIGN.md.

### Renamed to Lumenaire

- The product is now **Lumenaire** (OmaLights is retired: the name was taken).
  The Omarchy plugin is "Lumenaire for Omarchy".
- **The plugin id changes** from `io.github.nocstah.omalights` to
  `io.github.nocstah.lumenaire`, so Omarchy sees a new plugin: disable the old
  id, add the new one and enable it in the same bar slot (its bar settings
  move with it only if you copy them), then remove the old folder. The IPC
  target is now `lumenaire` (`omarchy-shell lumenaire status`), the log prefix
  `[lumenaire]`, the repository `github.com/nocstah/lumenaire`.
- The engine command is `lumenaire` (`bin/lumenaire`); `pc-lights` keeps
  working as an alias (`bin/pc-lights` execs it), and `install` links both
  `~/.local/bin/lumenaire` and `~/.local/bin/pc-lights`. The plugin looks for
  `lumenaire` first, then `pc-lights`, then its bundled copy.
- Unchanged, so nothing on disk has to move: the units and the hook, the
  journal tag `pc-lights`, `~/.config/pc-lights/`, `~/.cache/pc-lights/`, the
  `PCL_*` environment variables and the engine's own output.

### Works on any PC (engine)

- The `pc-lights` engine now ships in this repository (`bin/pc-lights` plus
  `lib/pc-lights/`), and `pc-lights install` sets it up: it checks the
  requirements, links `~/.local/bin/pc-lights`, and with `--units`, `--hook`,
  `--examples` and `--workarounds` installs the systemd user units, the
  Omarchy theme-set hook, the example themes and the TL fan LCD wake step.
  Nothing existing is overwritten without `--replace`/`--force`, every
  replaced file is backed up, and `--dry-run` shows each step and diff.
- A hardware profile (`pc-lights detect`) names the devices in your case by
  role, so themes no longer carry serials; you can correct its guesses and
  re-detect without losing them.
- Detect reads the ARGB header size from OpenRGB's saved sizes
  (`~/.config/OpenRGB/sizes.ors`), so a fresh profile resizes the headers
  the way OpenRGB does; without that file the size stays unset. A size you
  set, or one `migrate` seeded, still wins.
- Theme format v3: a palette is enough for a complete theme, roles override
  it, screens are keyed by role and only get media of their shape. v2 themes
  keep working; `pc-lights migrate` converts them. See `docs/THEMES.md`.
- Per-PC LED colour calibration for themes that weren't tuned on this PC
  (`docs/CALIBRATION.md`).
- Three palette-only example themes: aurora, ember and glacier.
- `tools/auto-theme` writes v3 themes with no serials, skips screen media on a
  PC without LCDs, and takes its 8.8" CPU widget from the detected sensor
  (`--schema 2` keeps the old output).
- Documentation in `docs/` (engine, profile, themes, calibration, backends),
  and the README now covers installing the engine on another PC.

### Plugin

- The daemon link reconnects after the daemon was down for more than 2 s (a
  fresh socket per attempt), and pump, fan and missing-device readings clear
  while it is offline.
- A pick superseded from a terminal or script clears quietly instead of
  failing (uses `ui_requested_ns` from `status --json`).
- The header and bar tooltip name lights, screens, skip and schedule changes
  instead of a blank or stale theme; failure tooltips name the failed change.
- Scheduled night/day switches show as theme applies; Retry only shows when
  there is something to retry; one Dismiss clears a failed pick.
- Skip refuses at once while clips are paused, the screens are off or the
  daemon is down; the clip name refreshes after every rotation.
- Theme edits are picked up when the panel opens; the inotify watch and
  nvidia-smi die with the shell.
- Disabled or threshold-less thermal alerts never turn readings red; the
  tooltip says when a CPU/GPU alert does. Theme names are spelled one way.
- The inline confirm scrolls into view and ignores a second click for 400 ms.

## 0.1.0 — 2026-09-24

First version, tested with Omarchy 4 on Hyprland with the `pc-lights` engine
(contract v1) and the `lian-li-linux` daemon.

- Bar widget with the case theme's colour dot, a coolant or pump readout that
  turns red when hot, and "…" while a change runs.
- Panel with a theme grid built from cached previews of each theme's fan,
  pump and 8.8" screens, plus its LED colours; a pick also becomes the day
  theme, re-applies and night overrides ask first.
- Lights and screens switches, clip rotation with Skip and Pause / Resume,
  the night schedule and the Omarchy theme pairing.
- Live pump RPM, coolant, CPU and GPU temperature and per-group fan RPM,
  read-only from the Lian Li daemon's socket, with out-of-range wireless
  devices and screens missing from USB called out.
- Every change runs as a detached systemd unit through `pc-lights --detach`,
  so a shell restart or plugin reload never interrupts an apply; repeated
  picks coalesce and the last one wins.
- Progress, queued, partial and failed states with Retry and Show log; a
  failure stays flagged on the bar until the panel has been opened.
- `omalights` IPC target: status, pick, lights, screens, skip, pause, resume,
  refresh, open and close.
