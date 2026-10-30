# Golden captures

`run.sh` renders every theme through `frozen.sh` (the capture's frozen daemon
replies, config, sysfs and state files) and compares stdout and the exit code
byte for byte with what the reference engine rendered live at capture time.
The captures live in `~/.cache/pc-lights/golden/<stamp>/`, never in this repo:
they hold the machine's real USB serials and MACs (each capture is mode 0700).

No test reads the live theme dir, profile or state files. Each capture
carries its own frozen theme snapshot and profile, named in its
`capture.conf`:

| link | capture | themes | profile | reference engine |
|------|---------|--------|---------|------------------|
| `current` | post-cut-over baseline | `themes-v3/` (the live v3 themes at capture time) | `real` (`profile.json`, the live one at capture time) | `engine/bin/lumenaire` (copy of the installed tree) |
| `v2` | migration-era capture (before the cut-over) | `themes-v2/` (frozen from `~/.config/pc-lights/themes.pre-v3-<date>` by `freeze-v2.sh`) | `none` (`profile.json` is detect's, for `--profile real`) | `pc-lights.pre-portable` |

A snapshot keeps media (video, images, fonts) as hard links and copies
everything else, with a manifest beside it (`themes-vN.sha256`). `run.sh`
refuses to run when a snapshot's non-media files no longer match it.

## Suites after the cut-over

```sh
tests/golden/run.sh --engine bin/lumenaire                    # current: v3, profile real
tests/golden/run.sh --engine bin/lumenaire --profile nocal    # same, calibration off
tests/golden/run.sh --engine bin/lumenaire --golden ~/.cache/pc-lights/golden/v2
#   = --golden …/v2 --themes …/v2/themes-v2 --profile none (the migration-era check)
tests/migrate/run.sh --engine bin/lumenaire                   # fixture from golden/v2/themes-v2
tests/migrate/run.sh --engine bin/lumenaire --profile ~/.cache/pc-lights/golden/v2/profile.json --golden
tests/engine-contract.sh bin/lumenaire                        # fixture from golden/v2 (themes-v2, inputs/state)
tests/editor/run.sh bin/lumenaire                             # golden section: golden/v2 sakura + profile
tests/detect/run.sh --engine bin/lumenaire                    # inputs of golden/current
```

`--themes DIR` and `--profile` still override `capture.conf`. `--live`
renders against the real `$HOME` (that is its purpose); its side-by-side
fallback runs the capture's `reference` engine.

## A new baseline

When the live themes or profile change on purpose (a theme edit, a new
detect), capture again while the engine is idle:

```sh
pcl-heavy tests/golden/capture.sh --no-openrgb
```

It refuses while `busy.json` exists, `pending/` has requests, the engine lock
is held (a run, or `lumenaire theme preview --measure`), OpenRGB runs, or
within 2 minutes of a schedule boundary (00:00 / 07:00); try again later, and
never break the lock. `--no-openrgb` takes the OpenRGB listing the last apply
cached (`~/.cache/pc-lights/openrgb-list.txt`) instead of running `openrgb`.
It only reads the live state: renders write to scratch files (`CLIPS_STATE`,
and a scratch `compiled/` cache for v3 themes). On success `current` points at
the new capture; older ones stay usable with `--golden`.

`freeze-v2.sh` was a one-off: it froze `themes.pre-v3-<date>` into the
migration-era capture and pointed `v2` at it. Run it again only to rebuild a
lost `themes-v2/`.
