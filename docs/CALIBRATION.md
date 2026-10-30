# LED colour calibration

The same hex colour looks different on different LEDs. RGB LEDs render green
far brighter than a monitor, so warm colours drift towards yellow and pale
tints turn white, and each kind of device drifts by a different amount. A
theme written as "the colour I mean" therefore needs a small, per-PC
correction to look right. That correction lives in the `calibration` section
of your hardware profile, and the engine applies it when it compiles a theme.

- [When it applies](#when-it-applies)
- [Classes](#classes)
- [The three corrections](#the-three-corrections)
- [Setting it up](#setting-it-up)
- [Worked numbers](#worked-numbers)

## When it applies

Calibration is on when `profile.calibration.enabled` is `true`, and it
applies to a theme **unless** the theme says it was already tuned on this
PC:

```json
"led": {"calibrated_for": "my-pc"}
```

where `my-pc` is `profile.machine.name`. That stamp is how hand-tuned themes
stay exactly as written on the PC they were tuned on, and get corrected on
every other one. `lumenaire migrate` stamps the themes it converts. New
themes, palette-only themes, the examples and auto-generated themes carry no
stamp, so they are always calibrated.

Calibration never changes a file. It runs inside `compile`, on every colour
the theme produces: palette-derived values, explicit role values, gradient
stops, per-fan lists and Strimer colours. Screens (LCD art) are never touched.

`machine.name` defaults to the hostname. Change it in the profile if you want
a stable name across reinstalls; detect keeps your edit.

## Classes

Each device is corrected by its class:

| Class | Devices |
| --- | --- |
| `tl_fan` | Lian Li TL fan frames (the most green-heavy) |
| `fan` | other Lian Li fans |
| `strimer` | Strimer cables |
| `ring` | pump rings, the Universal Screen ring |
| `gpu`, `board`, `ram` | OpenRGB devices of that type |
| `peripheral` | keyboards, mice, strips |

A class that isn't listed is left alone (identity).

## The three corrections

For a colour (R, G, B), with R the largest channel where it matters:

1. **Gain** `"gain": [r, g, b]`: each channel is multiplied, rounded and
   clamped to 0-255. Use it for a device with a plain colour cast.
2. **Warm cut** `"warm_gr_max"`: for hues from 0° to 70° (red, orange,
   amber, gold) whose G/R is above the limit, green is cut to
   `R × warm_gr_max` and blue scaled by the same factor. Gold stays gold
   instead of turning lemon.
3. **Pink cut** `"pink_gr_max"` (and optional `"pink_br_max"`): for hues from
   290° to 360° (magenta, pink, rose) whose G/R is above the limit, green is
   cut to `R × pink_gr_max` and blue capped at `R × pink_br_max`. Pale pink
   stays pink instead of turning white.

Neutral colours, blues, cyans and greens pass through the cuts unchanged.

## Setting it up

```json
"calibration": {
  "enabled": true,
  "note": "tuned from photos, 2026-09",
  "classes": {
    "tl_fan":  {"warm_gr_max": 0.3, "pink_gr_max": 0.4, "pink_br_max": 0.6},
    "strimer": {"warm_gr_max": 0.6, "pink_gr_max": 0.4},
    "ring":    {"warm_gr_max": 0.6, "pink_gr_max": 0.4},
    "gpu":     {"warm_gr_max": 0.6, "pink_gr_max": 0.4},
    "ram":     {"warm_gr_max": 0.6, "pink_gr_max": 0.4},
    "board":   {"warm_gr_max": 0.6, "pink_gr_max": 0.4}
  }
}
```

That block is a good starting point for Lian Li TL fans with Strimers and an
OpenRGB GPU, board and RAM. It ships as the preset `lianli-photo` in
`lib/pc-lights/calibration-presets.json`, so the short form is enough, with
your own `classes` merged over the preset's per class and field:

```json
"calibration": {"enabled": true, "preset": "lianli-photo",
                "classes": {"ram": {"gain": [1, 0.9, 1]}}}
```

Add it to `profile.json` by hand (detect never writes calibration and keeps
what you write). The preset `identity` changes nothing.

To tune it for your own case:

1. Make a throwaway test theme with one warm colour and one pink on every
   role (for example `palette: {"primary": "ffc048", "secondary": "ffd0e6"}`)
   and apply it with calibration off.
2. **Take a photo** in normal room light and compare it with the colours you
   meant. Don't go by memory or by what the colour is called; a photo is the
   only reliable judge.
3. Lower `warm_gr_max` for a class whose gold reads yellow, `pink_gr_max` for
   one whose pink reads white, and add a `gain` for a plain cast. Turn
   calibration on, apply, photograph again.
4. `lumenaire explain <theme>` and `lumenaire render <theme>` show the
   calibrated values without applying anything.

Calibration corrects drift; it can't create colours a device can't show.
Very dark colours still look muddy and near-whites still read white; see the
colour notes in [THEMES.md](THEMES.md#colours-that-work-on-leds).

## Worked numbers

With the preset above:

| Theme colour | Class | Result | Why |
| --- | --- | --- | --- |
| `ffc048` (gold) | `tl_fan` | about `ff4c1d` | G/R 0.75 cut to 0.3: reads as gold on a TL frame |
| `ffc048` (gold) | `strimer` | about `ff9939` | G/R cut to 0.6 |
| `ffd0e6` (pale pink) | `tl_fan` | `ff6699` | G/R cut to 0.4, blue capped at 0.6 |
| `00e5ff` (cyan) | any | `00e5ff` | not warm, not pink: unchanged |
| `ff4a00` (deep orange) | `tl_fan` | `ff4a00` | G/R 0.29 is already under the limit |
