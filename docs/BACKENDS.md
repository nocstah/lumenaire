# Lumenaire backends

A backend is the part of the engine that talks to one kind of RGB software: `lianli`
(the lian-li-linux daemon) and `openrgb` (the OpenRGB CLI). Each one is a set of bash
functions named `be_<name>_<verb>`, in `lib/pc-lights/backend-<name>.sh`. Everything
shared between backends (the probe cache, skip notes, the profile lookup, `render`) is in
`lib/pc-lights/backends.sh`.

```
theme.json ─► compile (theme.sh / theme.jq) ─► EFF: v2 keys + _roles + _coverage
                                                 │
profile.json ─► bind (per backend) ◄─────────────┘
                  ├─ be_lianli_build  → $TMP/work-config.json, work-tpl.json
                  └─ be_openrgb_build → $TMP/orgb.args (one argument per line)
render = build every backend + print;  on/off/pick = build + be_*_apply
```

## The interface

| Function | What it does |
|---|---|
| `be_<b>_probe` | Prints one line of JSON, `{"state": "ok\|absent\|down\|no-devices\|error", "message"?}`. It must be cheap: no socket writes and no device probes (`command -v`, `systemctl is-active`, the socket file, the profile). |
| `be_<b>_detect <outdir> [--probe]` | Writes `<outdir>/<b>.json`: `{"backend", "state", "version", "devices": {key: Device}}` (see the notes on each backend below). |
| `be_<b>_validate <eff>` | Prints one problem per line. Printing nothing means the EFF is fine. |
| `be_<b>_build <state> [eff]` | Builds the plan in `$TMP`. It is pure: it only writes to `$TMP`, and it only makes read-only daemon calls. |
| `be_<b>_render` | Prints the built plan in `render`'s format. |
| `be_<b>_apply <state>` | Applies the plan. Together with `be_<b>_screens`, it is the only verb that touches hardware. |
| `be_<b>_screens <state> [eff]` | Optional (only lianli has it): screen media and brightness. |
| `be_<b>_kinds` | Lists the device kinds the backend can drive, for example `fan_group strimer ring lcd`. |

`BACKENDS=(lianli openrgb)` sets the apply order, and `render` prints the sections in that
same order.

### Skipping a backend

`backend_probe <b>` runs the probe once per run and caches the result in `BE_STATE[<b>]`.
Call it outside `$(...)`, or the cache stays in the subshell. If the profile has
`backends.<b>.enabled == false`, the state is `disabled` and the probe doesn't run.

| State | What happens |
|---|---|
| `ok` | The backend runs. |
| `absent`, `no-devices`, `disabled`, `error` | The backend is skipped. `render` prints `# <b>: skipped (<message>)` in place of its section. `on`/`off` log the same text and carry on with the other backends. |
| `down` (lianli only: installed, but the daemon isn't running) | The run dies with the same words as before: `lianli-daemon must be running to read RGB capabilities` (render) or `lianli-daemon is not running` (on/off). |

The skip note only appears for a skipped backend. On a machine where every backend is `ok`,
`render` prints exactly what it printed before backends existed.

### The profile

`be_profile` prints the path of a usable profile. That is `$PROFILE`, or
`$STATE_DIR/profile.json` when `PROFILE` is unset, and the file must be a JSON object with
`"v": 1`. If there is no usable profile, every backend uses the legacy constants. That is
this machine before the portability work, byte for byte: no `ListDevices` call, the device
choice by name regex, and the OpenRGB names and sizes hard-coded in
`backend-openrgb.sh`.

## lianli

- **probe:**
  - `absent`: the daemon isn't active, there is no `lianli-daemon` binary, and there is no socket.
  - `no-devices`: the profile lists no `lianli` device.
  - `down`: the daemon isn't active.
  - `ok`: none of the above.
- **detect:** `be_lianli_detect <outdir>` is a thin wrapper over `detect_lianli`
  (`detect.sh`), the engine's one Lian Li scanner. It writes `lianli.json` in the shape
  above, plus `message`, `scanned` and `config_lcds` (`[{serial, orientation}]` from
  GetConfig), and leaves the raw replies beside it (`ListDevices.json`, `usb.json`, …).
  Only read-only calls: GetDaemonInfo, ListDevices, GetRgbCapabilities, GetConfig, and
  sysfs. The state is `absent`, `down` or `error` when the daemon doesn't answer,
  `no-devices` or `ok` otherwise.
- **build:**
  1. `fetch_caps 1` reads the capabilities.
  2. `build_lianli write_lianli_rgb <state> [eff]` builds the new config and template file
     from `$CFG_LIVE`/`$TPL_LIVE` into `$TMP/work-config.json` and `$TMP/work-tpl.json`.
     The live files are never touched.
- **apply:**
  1. `fetch_caps 12` (it waits up to 60 s for a flaky wireless device).
  2. `apply_live_or_restart`: a live guarded `SetConfig`, with a daemon restart as the
     fallback.
  3. If the theme's screens were rebuilt, `clips.json` is deleted only after the apply
     went through, so the clip rotation starts over. Building (and so `render`) never
     deletes it.

### Binding: daemon `device_id` → role

`be_lianli_bind` writes `$TMP/bind.json` as `{device_id: {key, role, managed, effect}}`.
For each device the daemon reports, it takes the first profile device (`backend: "lianli"`)
whose `match` fits, trying in this order:

1. the wireless MAC: `device_id == "wireless:" + match.mac`;
2. the LCD's USB serial: `usb_serial_map[match.usb_serial] == device_id`;
3. the HID serial: the ListDevices `serial` equals `match.serial` (never for wireless devices);
4. the last seen id: `seen_id == device_id` or `match.device_id == device_id`;
5. the family, but only when both the daemon and the profile have exactly one device of that family.

The device key's role is the first role in the profile that names the key (in `device` or
`devices`). The role gives the effect class:

| Role | Effect class |
|---|---|
| `fans.*` | fan |
| `strimer.*` | strimer |
| `pump.*`, `*.ring` | ring |
| anything else | none: the device name decides, as before |

Without a profile, `bind.json` is `{}` and no daemon call is made.

### How a device's effect is chosen (`write_lianli_rgb`)

- **Bound device** (it has a role):
  - The value comes from `$dsc = $sc + $sc._roles[role]`. The `static`, `on_effect` and
    `tl_regions` jq defs are unchanged; they are simply re-declared inside that scope.
  - The effect class picks the `on_effect` branch.
  - Inner/outer regions (`scope` Top/Bottom) go to fan roles whose capabilities list a
    `Top` effect region.
- **Unbound device:** it gets the group values (`fans`, `strimers`, `rings`) by its name
  regex, exactly as before, and the run logs `profile stale: …`.
- **`managed: false` role**, state `on`: the device keeps its current entry from the
  config, or has no entry if it had none.
- **`ignore` role**, state `on`: the device gets no entry. This is what the old `TL Flex LCD
  Controller` name rule did for the wired TL receivers, the same fans seen over USB. Note
  that the plan said such a device "keeps `$old`". Leaving it out is safer, because after
  an `off` an old entry would be `Off`, and it would then fight the RF path.
- **State `off`:** every device the daemon reports goes to `Off`, whatever its role, as
  before.
- **Devices missing from the capabilities:** their old entries are kept, as before.

A v2 theme has no `_roles`, so a profile changes nothing for it. The same is true of a
compiled theme whose roles all resolve to the group values. The golden stages check both.

## openrgb

- **probe:**
  - `absent`: there is no `openrgb` binary.
  - `no-devices`: the profile lists no `openrgb` device.
  - `ok`: none of the above.
- **Listing cache:** every real apply lists the devices once, to get the RAM ids, and saves
  the whole `openrgb --list-devices` output to `$CACHE/openrgb-list.txt` (tmp + mv). A run
  that lists nothing keeps the previous file. `ram-ids` is still written for `render`,
  which never runs OpenRGB: a listing probes the SMBus, and a second OpenRGB running next
  to an apply can glitch the ENE RAM controllers.
- **One OpenRGB at a time (RAM drift):** a theme's `ram.drift` runs
  `lumenaire-ram-drift.service` (`lib/pc-lights/ramdrift.py run`), which keeps its own
  DRAM-only OpenRGB server up and holds `$CACHE/openrgb.lock` for its whole life. Every
  OpenRGB process the engine starts (the listing in `ram_ids`, `be_openrgb_apply`,
  `be_openrgb_preview`, detect's `detect_openrgb_list`) goes between `orgb_begin`
  (`systemctl --user stop` the unit, synchronous, then `flock -w 60` on
  `openrgb.lock`, fd 5; `PCL_ORGB_WAIT` overrides the 60 s) and `orgb_end`. A lock still
  held after the wait refuses OpenRGB with an error rather than run a second one beside
  it. After an apply, `ram_drift_sync` writes `$CACHE/ram-drift.json` (the stops, span,
  period, window, reverse, fps, LEDs per stick, the stick ids and their listing
  locations) and starts the unit, only with the lights on and a drifting ram; otherwise it
  removes the file. A preview's restore (`ram_drift_resume`) does the same for the
  active theme; `detect --probe` starts the unit again if it was running. Without the unit
  installed (`~/.config/systemd/user/lumenaire-ram-drift.service`) no `systemctl` runs at
  all. The animator: `flock -n` on the lock (busy = exit 0), the private config from the
  user's detector list (none = refuse, exit 1: a list without it would detect
  everything), `openrgb --config … --server --server-host 127.0.0.1 --server-port 6797
  --noautoconnect` (a port the CLI never autoconnects to), a minimal SDK client (protocol
  4: version, client name, controller count/data, `SETCUSTOMMODE`, `UPDATELEDS`), the
  sticks matched by name and listing location, frames on a fixed grid from its start
  (frame 0 = the apply's colours), exit on the lights going off, on SIGTERM (it stops
  its OpenRGB) and when its OpenRGB dies (exit 1; the unit retries 3 times in 10 min).
  Tests: `tests/ramdrift/run.sh`.
- **detect:**
  - `be_openrgb_detect <outdir> [--probe]` is a thin wrapper over `detect_openrgb`
    (`detect.sh`), which parses the cached listing with `detect_openrgb_parse`, the
    engine's one listing parser.
  - It runs `openrgb --list-devices` itself only with `--probe` or when there is no cache.
    In that case the caller must hold the engine lock (~/.cache/pc-lights/lock).
  - Devices are keyed `openrgb:<name>#<i>`, where `i` is the device's index among devices
    with the same name, in listing order.
  - Each device has these fields: `backend`, `present`, `name`, `type`, `kind`, `leds`,
    `zones` (board, peripherals) and `match {name, location}` (`location` only when
    several devices share the name).
  - `kind` comes from the device type:

    | Type | kind |
    |---|---|
    | Motherboard | board |
    | GPU | gpu |
    | DRAM | ram |
    | anything else (keyboard, mouse, LED strip, …) | peripheral |

    A device whose name starts with `Lian Li` gets `kind: "duplicate"` and a note, and is
    never bound: lian-li-linux drives it.
  - The parser skips the junk before the first device, joins wrapped `Version`/`Location`
    lines, trims trailing blanks, and splits quoted zone and LED names.
- **Parameters:** `openrgb_params` writes `$TMP/orgb.json`:
  `{gpu: {name, leds, layout}, board: {name}, argb: {name, zones, size}, ram: {match_name, leds_per_device, picks}, peripherals: [{role, name}]}`.
  - With a profile, it is built from the roles `gpu`, `board`, `board.argb`, `ram` and the
    managed peripherals. Roles with `managed: false` are dropped, and a missing part is `null`.
  - Without a profile, it holds the legacy constants: 30 LEDs with the Aura layout, ARGB
    zones 0–3 resized to 120, and `ENE DRAM` with 8 LEDs per stick.
- **build:** `openrgb_args <state> [eff]` → `openrgb_py <state> <eff> "<ram ids>" <orgb.json>`.
  - The float expressions (the Aura layout, the gradients, `round`) are the old ones
    word for word; only the constants became parameters, so rounding at .5 cannot drift.
  - `board.argb` with `size: null` never resizes the headers. Detect fills the
    size from OpenRGB's `sizes.ors` when the headers there agree.
  - The headers take `_roles["board.argb"].board` when the EFF has it; otherwise they take `board`.
  - A managed peripheral takes `_roles[R].peripheral` (a colour, or `{mode, colors, speed?, brightness?}`)
    and goes black when the lights are off. A peripheral role with no value is left alone.
  - Called without `orgb.json` (as `validate_theme` does), `openrgb_py` uses the legacy constants.
- **apply:** `timeout 120 openrgb <args>`. If there are no arguments, nothing is run.

## `render`

```
lumenaire render [--state on|off] [name]
```

- `--state off` with no name prints the active theme in the header. The output is exactly
  what `off` would write: every device `Off`, the alerts disabled, the screens untouched,
  and the OpenRGB off arguments.
- `render` takes no lock, runs no OpenRGB, and changes nothing. In particular, it no longer
  deletes `clips.json`.

## Adding a backend later (not built)

To add a backend:

1. Write the eight functions above.
2. Add its name to `BACKENDS`.
3. Give its devices DeviceKeys with a `<backend>:` prefix in detect.

### liquidctl

- **probe:** `command -v liquidctl`, and check that `liquidctl list --json` returns something.
- **detect:**
  - NZXT Kraken → `pump.ring` and `pump.logo`;
  - Corsair Commander / iCUE channels → `fans.<n>` and `ledstrip.<n>`.
- **build:** one line per call: `liquidctl --match '<description>' set <channel> color <mode> <hex…>`.
- **apply:** run each line with `timeout 10`.
- **Setup:** it needs `liquidctl initialize all` at login, as an `ExecStartPre` of the login unit.

### openrazer

- **probe:** `python3 -c 'import openrazer.client'` succeeds, and the daemon is on D-Bus.
- **detect:** `DeviceManager().devices` (serial, type) → `keyboard`, `mouse`, `mousepad`
  or `headset`, all **`managed: false` by default**.
- **build/apply:** a Python heredoc, as `openrgb_py` does.

### Two backends that see the same device

Take a Razer mouse that both OpenRGB and openrazer can see. Detect keeps the
vendor-specific backend (`claimed_by`) and marks the other device key `ignore`. The OpenRGB
peripheral list only drives devices whose profile entry has `backend: "openrgb"`.
