#!/usr/bin/env node
// JS <-> jq parity for LedColor.js (plan §4, "the parity contract between C
// and A"). LedColor.js must give byte-identical answers to the engine's jq
// for calibrate_hex, led_safe_hex, th_hsv/th_fromhsv, th_mix and, once
// lib/pc-lights/editor.jq exists, led_hints. One jq run evaluates the whole
// sweep; any difference fails.
//
//   node tests/editor/parity.mjs            # 200 random colours + edges x every class
//   PARITY_N=2000 node tests/editor/parity.mjs
import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const lib = join(root, 'lib', 'pc-lights')
// LedColor.js is a QML ".pragma library" script: drop the pragma and read
// its function declarations as a module body.
const src = readFileSync(join(root, 'LedColor.js'), 'utf8').replace(/^\.pragma library\s*$/m, '')
const names = [...src.matchAll(/^function (\w+)\(/gm)].map(m => m[1])
const L = new Function(src + '\nreturn {' + names.join(',') + '}')()

const presets = JSON.parse(readFileSync(join(lib, 'calibration-presets.json'), 'utf8'))
const photo = presets['lianli-photo'].classes
const classes = { none: null, empty: {}, ...photo, gainy: { gain: [1, 0.85, 1.1], warm_gr_max: 0.5, pink_gr_max: 0.45, pink_br_max: 0.7 } }

// Deterministic sweep: edges, every pure hue at 5 degrees, then random.
let seed = 0x5eed
const rnd = () => (seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296
const hex2 = n => n.toString(16).padStart(2, '0')
const colours = ['000000', 'ffffff', '808080', '7f7f7f', 'ff0000', '00ff00', '0000ff', 'ffff00', 'ff00ff', '00ffff',
  'ffc048', 'ffd0e6', 'fff0f6', '00e5ff', 'ff4a9a', 'ff1a70', 'ff1a8c', 'c040ff', '010000', 'FF4A9A', '#ff4a9a', '#FFD0E6',
  'e6e6e6', '1a0d12', 'ff9a30', 'ff7ab6', 'd4106a', '262626', '404040', 'ccff00']
for (let h = 0; h < 360; h += 5) colours.push(L.hsvToHex(h, 1, 1), L.hsvToHex(h, 0.3, 0.9), L.hsvToHex(h, 0.8, 0.2))
const N = Number(process.env.PARITY_N || 200)
for (let i = 0; i < N; i++) colours.push(hex2(Math.floor(rnd() * 256)) + hex2(Math.floor(rnd() * 256)) + hex2(Math.floor(rnd() * 256)))

const hasEditor = existsSync(join(lib, 'editor.jq'))
// editor.jq is spliced in after theme.jq, the way editor.sh's ed_jq loads it
// (jq 1.8.2 can't have a module include another).
const editorDefs = hasEditor ? readFileSync(join(lib, 'editor.jq'), 'utf8') : ''
const cals = [false, true].map(on => ({ applies: on, classes: photo, fix_classes: photo }))
const cases = []
for (const c of colours) for (const k of Object.keys(classes)) cases.push({ hex: c, cls: k })

// jq side: one program over the whole sweep.
const prog = `$cases | map(. as $x | $cls[$x.cls] as $c | {
    cal: ($x.hex | calibrate_hex($c)),
    safe: ($x.hex | led_safe_hex),
    hsv: ($x.hex | ltrimstr("#") | ascii_downcase | th_rgb | th_hsv),
    back: ($x.hex | th_rgb | th_hsv | th_fromhsv | th_tohex),
    mix: th_mix($x.hex; "ff1a70"; 0.5)
    ${hasEditor ? ', hints: ($cals | map(. as $cal | led_hints($x.hex; $x.cls; $cal))), shows: ($cals | map(. as $cal | $x.hex | ed_show($x.cls; $cal))), pal: ($cals | map(. as $cal | ($x.hex | ltrimstr("#") | ascii_downcase) as $v | {palette: {primary: $v}, v: 3} | ed_palette(.; $cal; $classes) | .primary.hints))' : ''}
  })`
// The sweep goes in on stdin: a big sweep overflows the argument list.
const out = execFileSync('jq', ['-c', '-L', lib, '--argjson', 'cls', JSON.stringify(classes), '--argjson', 'cals', JSON.stringify(cals), '--argjson', 'classes', JSON.stringify(Object.keys(photo)), `include "theme";\n${editorDefs}\n. as $cases | ` + prog],
  { input: JSON.stringify(cases), encoding: 'utf8', maxBuffer: 1 << 28 })
const want = JSON.parse(out)

let fails = 0
const report = (what, i, got, exp) => {
  if (++fails <= 20) console.error(`FAIL ${what} ${cases[i].hex} ${cases[i].cls}: js ${JSON.stringify(got)} jq ${JSON.stringify(exp)}`)
}
cases.forEach((c, i) => {
  const w = want[i]
  const cal = L.calibrate(c.hex, classes[c.cls])
  if (cal !== w.cal) report('calibrate_hex', i, cal, w.cal)
  const safe = L.ledSafe(c.hex)
  if (safe !== w.safe) report('led_safe_hex', i, safe, w.safe)
  const hsv = L.hsv(L.rgb(c.hex))
  if (JSON.stringify(hsv) !== JSON.stringify(w.hsv)) report('th_hsv', i, hsv, w.hsv)
  const back = L.toHex(L.fromHsv(...hsv))
  if (back !== w.back) report('th_fromhsv', i, back, w.back)
  const mix = L.mix(c.hex, 'ff1a70', 0.5)
  if (mix !== w.mix) report('th_mix', i, mix, w.mix)
  if (hasEditor) {
    const h = cals.map(cal => L.hints(c.hex, c.cls, cal))
    if (JSON.stringify(h) !== JSON.stringify(w.hints)) report('led_hints', i, h, w.hints)
    const sh = cals.map(cal => L.shows(c.hex, c.cls, cal))
    if (JSON.stringify(sh) !== JSON.stringify(w.shows)) report('ed_show', i, sh, w.shows)
    // ed_palette's hints on the primary (LED-safe derivation on).
    const v = c.hex.replace(/^#/, '').toLowerCase()
    const ph = cals.map(cal => L.paletteHints(v, L.ledSafe(v), Object.keys(photo), cal))
    if (JSON.stringify(ph) !== JSON.stringify(w.pal)) report('ed_palette hints', i, ph, w.pal)
  }
})
const checks = cases.length * (hasEditor ? 8 : 5)
console.log(`parity: ${colours.length} colours x ${Object.keys(classes).length} classes, ${checks} checks, ${fails} differences`
  + (hasEditor ? '' : ' (led_hints skipped: lib/pc-lights/editor.jq not there yet)'))
process.exit(fails ? 1 : 0)
