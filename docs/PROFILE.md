# The hardware profile

Themes don't name devices. They say what colour the fans, the Strimers or the
pump ring should be, and which art goes on a fan screen. The **hardware
profile**, `~/.config/pc-lights/profile.json`, is what connects those roles to
the real devices in your PC. `lumenaire detect` writes it; you can correct its
guesses; themes and the plugin read it.

- [First run](#first-run)
- [Roles](#roles)
- [What detect looks at](#what-detect-looks-at)
- [Correcting the profile](#correcting-the-profile)
- [Screens: order and mounting](#screens-order-and-mounting)
- [Sensors](#sensors)
- [Workarounds](#workarounds)
- [Schema](#schema)

## First run

```bash
lumenaire detect --dry-run     # what it found, as a diff; writes nothing
lumenaire detect               # write ~/.config/pc-lights/profile.json
lumenaire profile show         # roles, devices, sensors
lumenaire explain aurora       # what a theme would put on each device
lumenaire render aurora        # the exact values, still without touching anything
lumenaire pick aurora
```

Detect takes a few seconds. It reads the Lian Li daemon (read-only calls) and
the OpenRGB device list that the last apply cached. With no cache, or with
`--probe`, it runs `openrgb --list-devices` while holding the engine lock (~/.cache/pc-lights/lock)
(a probe next to a running apply can upset some RAM controllers).
`--no-openrgb` leaves OpenRGB out. From the plugin, **Detect** runs the same
command in its own unit.

Without a profile, v2 themes still apply as they always did, and a v3 theme
stops at validation with "no hardware profile; run `lumenaire detect`",
before anything is touched.

## Roles

A role is a named place in the case. Themes give roles colours; the profile
binds each role to a device.

| Role | What | Group key in themes |
| --- | --- | --- |
| `fans.<pos>`: `side`, `top`, `bottom`, `front`, `rear`, `radiator`, `1`…`n` | a group of fans; each has an `inner` and `outer` region (TL fans: the inner edges and the outer bars of the frame; fans without regions use `outer`) | `fans` |
| `strimer.atx24`, `strimer.gpu`, `strimer.<n>` | Strimer cables: an effect with 6 colours, mode, speed, direction | `strimers` |
| `pump.ring` | the AIO pump's light ring | `rings` |
| `screen.main.ring` | the ring around the Universal Screen | `rings` |
| `gpu` | the graphics card | — |
| `board`, `board.argb` | the motherboard's own LEDs; its addressable RGB headers | `board` |
| `ram` | every RAM stick, as one strip | — |
| `keyboard`, `mouse`, `mousepad`, `headset`, `ledstrip.<n>`, `other.<n>` | peripherals and strips; **not managed** unless you turn them on | `peripherals` |
| `screen.fan<n>` | a fan LCD | `screen.fan` |
| `screen.pump`, `screen.main`, `screen.aux<n>` | the pump LCD, the main (largest) screen, other screens | — |
| `ignore` | devices detect decided not to drive (a wired duplicate of a wireless fan group) | — |

A theme value for a role wins over its group key, which wins over the value
derived from the palette. See [THEMES.md](THEMES.md).

**Peripherals are never touched by default.** A keyboard or mouse with its own
lighting app, or that you like as it is, stays as it is. Turn one on with
`lumenaire profile set keyboard --managed on`.

## What detect looks at

**Lian Li** (through the daemon's `ListDevices` and `GetRgbCapabilities`, and
USB serials from sysfs):
- A wired receiver that is the same fans as a wireless group (it reports a
  `wireless_group_mac`, or is named "TL Flex LCD Controller") goes to `ignore`.
- Anything with fans and RGB is a fan group. Its position is a **guess**,
  marked as one: the group with LCDs and the most fans is `fans.side`, a group
  without LCDs `fans.bottom`, the next group with LCDs `fans.top`, then
  `fans.1`… Correct it if your case is laid out differently.
- Strimers by LED count: 160 or more is `strimer.atx24`, 100-159 `strimer.gpu`.
- HydroShift, Galahad and wireless AIO LED controllers are `pump.ring`; the
  Universal Screen's lighting is `screen.main.ring`.
- LCDs: HydroShift and Galahad LCDs are `screen.pump`, the largest Universal
  Screen is `screen.main`, fan LCDs are `screen.fan1`… (see below).

**OpenRGB** (the `--list-devices` output):
- Type Motherboard: `board`, plus `board.argb` for zones named like ARGB,
  D_LED, ADD, JRAINBOW or Addressable. Their LED count comes from the sizes
  you saved in OpenRGB's Resize dialog (`~/.config/OpenRGB/sizes.ors`): when
  every header there has the same size, detect uses it (`"source":
  "openrgb"`, sure). Without that file, or with headers of different sizes,
  the size is left alone (`"size": null`) unless you set one. A size you set
  (`profile set board.argb --argb-size N`) or `migrate` seeded always wins.
- Type GPU: `gpu`. Type DRAM: `ram`, every stick in listing order.
- Keyboard, Mouse, Mousemat, Headset: the matching role, not managed.
- A device named "Lian Li …" is a warning (OpenRGB's Lian Li detectors should
  be off), never bound.

Devices are keyed by something stable: a MAC for wireless gear, the USB serial
for LCDs, the serial or family for wired controllers, the name plus an index
for OpenRGB. The USB path is kept only as a hint, because it changes when you
move a dongle to another port.

## Correcting the profile

```bash
lumenaire profile show
lumenaire profile set fans.top lianli:mac:02:00:00:00:01:03
lumenaire profile set mouse --managed on
```

You can also edit `profile.json` by hand (it is plain JSON). Re-running detect
keeps your edits: for each role, sensor, backend switch and the machine name,

- a value you never touched is replaced by the new detection;
- a value you changed (or that `migrate` set, or that has `"locked": true`)
  is **kept**, marked `"source": "user"`, and detect reports the conflict.

Devices and workarounds are facts: they always come from the new detection. A
device that is gone stays listed with `"present": false`, so the roles
pointing at it survive (fan LCDs that are off USB after a shutdown, a Strimer
out of radio range). `status --json` reports new and missing devices, and the
plugin offers to detect again.

## Screens: order and mounting

Fan LCDs are grouped with the fan group they belong to (the receiver on the
same USB hub). Groups are ordered by fan count (most first), then MAC; screens
within a group by USB port. That gives `screen.fan1`, `screen.fan2`, … in the
order a theme's `screen.fan` list is dealt out.

Each screen role has an optional `"mount"`: how the screen is physically
rotated in **your** case (0, 90, 180 or 270). The engine adds it to the model's
default orientation, so a theme never has to know that one fan column is
mounted upside down. Set it with a hand edit, for example
`"screen.fan1": {…, "mount": 180}`.

## Sensors

`profile.sensors` says where the plugin's readings come from:

| Key | Picks |
| --- | --- |
| `cpu` | hwmon `zenpower` (Tdie), then `k10temp` (Tctl), then `coretemp` (Package id 0), then the `x86_pkg_temp` thermal zone |
| `gpu` | NVIDIA (through `nvidia-smi`), then an `amdgpu` card that drives the display or has 4 GiB of VRAM or more, then Intel `xe`/`i915` with VRAM |
| `gpu_integrated` | the integrated GPU, kept apart so it is never mistaken for the real one |
| `coolant`, `pump` | the Lian Li device with a pump |
| `ram` | `spd5118` / `jc42` |

hwmon numbers change between boots, so the profile stores the driver and
input, and `lumenaire sensors --json` resolves the path each time.

## Workarounds

Detect also records known problems and whether their fix is in place, under
`workarounds` (facts, regenerated every time):

| Id | Means |
| --- | --- |
| `lianli.wake_fan_lcds` | TL fan LCDs present: after a shutdown their receivers keep them off USB. `lumenaire install --workarounds` installs the wake step. |
| `lianli.fixed_binary` | a patched lianli-daemon is in use through a drop-in; flagged when its version differs from the installed package. See `workarounds/lianli/README-fixed-daemon.md`. |
| `openrgb.lianli_detectors_off` | OpenRGB's Lian Li detectors are off, as they should be. |
| `openrgb.smbus_lax` | RAM on an AMD SMBus that needs `acpi_enforce_resources=lax`. |

## Schema

`"v": 1`. Everything except `roles`, `sensors`, `calibration` and
`machine.name` is regenerated by detect.

```ts
Profile {
  v: 1
  machine: { name, hostname, detected_at, detect_version }   // name: yours to change; calibration uses it
  backends: { lianli|openrgb|…: { enabled, state: "ok"|"absent"|"down"|"no-devices"|"error", message?, version? } }
  devices: { [key]: Device }
  roles: { [role]: RoleBinding }
  screens: { expected }                      // "N of <expected>" in status
  sensors: { cpu?, gpu?, gpu_integrated?, coolant?, pump?, ram? }
  calibration?: Calibration                  // see CALIBRATION.md; detect never writes it
  workarounds: { [id]: { present, needed, note, … } }
}
DeviceKey = "lianli:mac:<mac>" | "lianli:lcd:<usb serial>" | "lianli:serial:<serial>"
          | "lianli:family:<Family>[#n]" | "openrgb:<name>#<i>"
Device { backend, present, name, family?, type?, kind, match: {…}, seen_id?, usb?,
         fans?, leds?, regions?, zones?, panel?: [w, h], lcd_group?, duplicate_of? }
RoleBinding { device? | devices?, managed? (default true), label?, source: "detect"|"openrgb"|"user"|"migrate",
              confidence: "sure"|"guess", mount?, group?, leds?, layout?, argb?: {zones, size},
              leds_per_device?, match_name?, locked? }
```

A short example (made-up IDs):

```json
{
  "v": 1,
  "machine": {"name": "my-pc", "hostname": "my-pc", "detected_at": "2026-09-24T16:00:00+02:00", "detect_version": 1},
  "backends": {"lianli": {"enabled": true, "state": "ok"}, "openrgb": {"enabled": true, "state": "ok"}},
  "devices": {
    "lianli:mac:02:00:00:00:01:01": {"backend": "lianli", "present": true, "name": "UNI FAN TL V3 Wireless LCD",
      "family": "Tlv2Led", "kind": "fan_group", "fans": 3, "leds": 78, "regions": ["inner", "outer"],
      "match": {"mac": "02:00:00:00:01:01"}},
    "lianli:lcd:f1f1f1f100000001": {"backend": "lianli", "present": true, "name": "TL Flex LCD",
      "family": "TlFlexLcd", "kind": "lcd", "panel": [400, 400], "lcd_group": "lianli:mac:02:00:00:00:01:01",
      "match": {"usb_serial": "f1f1f1f100000001"}},
    "openrgb:ENE DRAM#0": {"backend": "openrgb", "present": true, "name": "ENE DRAM", "type": "DRAM",
      "kind": "ram", "leds": 8, "match": {"name": "ENE DRAM"}}
  },
  "roles": {
    "fans.side": {"device": "lianli:mac:02:00:00:00:01:01", "label": "Side fans", "source": "detect", "confidence": "guess"},
    "screen.fan1": {"device": "lianli:lcd:f1f1f1f100000001", "group": "fans.side", "mount": 180,
      "label": "Side fans, screen 1", "source": "user", "confidence": "sure"},
    "ram": {"devices": ["openrgb:ENE DRAM#0"], "match_name": "ENE DRAM", "leds_per_device": 8,
      "source": "detect", "confidence": "sure"}
  },
  "screens": {"expected": 1},
  "sensors": {"cpu": {"kind": "hwmon", "driver": "k10temp", "input": "temp1_input", "label": "Tctl", "scale": 0.001}},
  "workarounds": {}
}
```
