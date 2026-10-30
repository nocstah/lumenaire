# Lumenaire

Lumenaire for Omarchy is the Omarchy bar interface for `lumenaire` (alias
`pc-lights`), the engine behind the
desktop's case lighting: Lian Li TL fans, Strimer cables, the HydroShift pump
ring and screen, the 8.8" screen, and the GPU, board and RAM through OpenRGB.
People use it to pick a case theme, turn the lights or the LCD screens off and
on, move the pump clip along, set how each theme's desktop wallpaper moves
(with the Motion Wallpaper plugin), and glance at pump and coolant readings.

`lumenaire` owns everything that changes the hardware: themes and their files,
the lock, the Lian Li daemon and OpenRGB writes, the night schedule, the
Omarchy theme pairing and the preview images. The plugin never writes a colour,
a daemon setting or a theme file. It starts engine commands, reads
`lumenaire status --json` and `themes --json`, and reads telemetry from the
daemon's socket with a fixed whitelist of read-only methods.

A theme apply takes 20 s to three minutes and can fall back to a daemon
restart. So every change runs as its own detached systemd unit, never as a
child of the shell, and the panel follows it from the engine's bookkeeping
files. Closing the panel, reloading the plugin or restarting the shell never
interrupts it. The interface is explicit about what is happening: which step
an apply is on and for how long, what is queued behind it, what failed and
which devices missed it. A failure stays visible until it has been seen.

Behaviour rules:

- A pick also becomes the day theme. Picking during the night overrides the
  night theme until the next boundary, and asks first.
- Re-applying the active theme asks first.
- Repeated picks coalesce; the last one wins and the others never start.
- Lights, screens and the schedule wait while an apply holds the lock; the
  panel says so rather than queueing them silently.
- With the lights off, a pick is saved and applies at lights on; the panel says
  which theme the screens still show.
- The daemon going away is shown, not hidden; nothing is retried behind the
  user's back except reconnecting.
- Missing values show "—", never a stale number presented as fresh.

Themes are made and edited in the panel too: a short New theme flow (start
from one colour, the desktop's colours, a copy or a surprise, then name it)
and an editor with a live preview on the case. Every edit lands in an engine
draft, so leaving never loses work, and nothing reaches the saved theme until
Save.

Each screen's media is edited from the same editor: a map of the case shows
what every screen plays; a screen's page picks media from the theme, the
library or your own files, crops anything that doesn't fit, sets brightness,
and for the pump manages the clips it takes turns with. Preparing runs in
the background with progress, and the case previews the change before Save.

The panel leaves out editing the night hours or the Omarchy map (those stay
on the `lumenaire` command line), trimming video and editing the 8.8"
screen's widgets (planned), telemetry history, and any direct write to the
daemon or OpenRGB.
