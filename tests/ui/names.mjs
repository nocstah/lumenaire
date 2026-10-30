#!/usr/bin/env node
// Unit checks for the New theme page's pure helpers:
//   Format.js   slugify, nameIssue, nextFree, freeDisplay (the names people type)
//   Palette.js  fromMain, fromDesktop, surprise, colourName (the palettes it makes)
//
//   node tests/ui/names.mjs
//
// The .pragma library files are read as function bodies, the way
// tests/editor/parity.mjs reads LedColor.js; Palette.js gets LedColor.js as its
// import. Any failed check prints and exits 1.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
function lib(name, deps = {}) {
  const src = readFileSync(join(root, name), 'utf8').replace(/^\.pragma library\s*$/m, '').replace(/^\.import .*$/mg, '')
  const names = [...src.matchAll(/^function (\w+)\(/gm), ...src.matchAll(/^const (\w+) =/gm)].map(m => m[1])
  return new Function(...Object.keys(deps), src + '\nreturn {' + names.join(',') + '}')(...Object.values(deps))
}
const LedColor = lib('LedColor.js')
const Format = lib('Format.js')
const Palette = lib('Palette.js', { LedColor })

let fails = 0, checks = 0
const eq = (what, got, want) => {
  checks++
  if (JSON.stringify(got) !== JSON.stringify(want)) { fails++; console.error(`FAIL ${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`) }
}
const ok = (what, cond) => { checks++; if (!cond) { fails++; console.error(`FAIL ${what}`) } }

// ---- slugify: typed name -> engine name ------------------------------------------
const ENGINE = /^[a-z0-9][a-z0-9._-]{0,47}$/
for (const [typed, want] of [
  ['Neon Cyan', 'neon-cyan'], ['  Sakura 2 ', 'sakura-2'], ['hello   world', 'hello-world'], ['Rosé Été!', 'rose-ete'],
  ['--hi--', 'hi'], ['My_Theme.v2', 'my_theme.v2'], ['a -- b', 'a-b'], ['日本', ''], ['!!!', ''], ['', ''],
  ['Omarchy Blue', 'omarchy-blue'], ['x'.repeat(60), 'x'.repeat(48)], ['Night / Day', 'night-day'], ['CAPS', 'caps']])
  eq(`slugify(${JSON.stringify(typed)})`, Format.slugify(typed), want)
for (const typed of ['Neon Cyan', 'a.b.c', 'Über Theme', '  x  ', 'x'.repeat(80) + ' y', '---a---b---', '9 lives'])
  ok(`slugify(${JSON.stringify(typed)}) is an engine name`, ENGINE.test(Format.slugify(typed)))
// The display name comes back from the slug the way the grid shows it.
eq('themeName(slugify("neon cyan"))', Format.themeName(Format.slugify('neon cyan')), 'Neon Cyan')

// ---- nameIssue: friendly problems with a one-click fix ------------------------------
const taken = ['sakura', 'sakura-2', 'hellfire', 'neon-cyan']
eq('free name', Format.nameIssue('Night Owl', taken, ''), null)
eq('empty: no hint', Format.nameIssue('   ', taken, ''), { text: '', fix: '' })
eq('taken: next free as typed', Format.nameIssue('Sakura', taken, ''), { text: 'Sakura already exists.', fix: 'Sakura 3' })
eq('taken, keeps the case typed', Format.nameIssue('neon cyan', taken, ''), { text: 'Neon Cyan already exists.', fix: 'neon cyan 2' })
eq('symbols only', Format.nameIssue('!!!', taken, ''), { text: 'Use letters or numbers.', fix: '' })
eq('omarchy prefix', Format.nameIssue('Omarchy Blue', taken, ''), { text: 'Omarchy names are kept for generated themes.', fix: 'Blue' })
eq('rename to itself is no clash', Format.nameIssue('Hellfire', taken, 'hellfire'), null)
eq('a draft name counts as taken', Format.nameIssue('Sakura 2', taken, ''), { text: 'Sakura 2 already exists.', fix: 'Sakura 3' })
eq('nextFree', Format.nextFree('Sakura copy', ['sakura-copy', 'sakura-copy-2']), 'Sakura copy 3')
eq('freeDisplay free', Format.freeDisplay('Neon Violet', taken), 'Neon Violet')
eq('freeDisplay taken', Format.freeDisplay('Hellfire', taken), 'Hellfire 2')
for (const typed of ['Sakura', 'Neon Cyan', 'Omarchy Blue']) {
  const fix = Format.nameIssue(typed, taken, '').fix
  ok(`the fix for ${typed} is free`, fix !== '' && Format.nameIssue(fix, taken, '') === null)
}

// ---- palettes: LED colours only -----------------------------------------------------
// A generated colour is saturated at full value and outside the bands these
// LEDs render badly (amber-to-yellow reads lemon, the magenta band leans
// violet on the fans); the three stay apart so the LEDs tell them apart.
const hue = h => LedColor.hexToHsv(h)[0]
const dist = (a, b) => { const d = Math.abs(a - b) % 360; return Math.min(d, 360 - d) }
const ledTrue = h => {
  const [hh, s, v] = LedColor.hexToHsv(h)
  return s > 0.99 && v > 0.99 && !(hh > 19.5 && hh < 74.5) && !(hh > 292.5 && hh < 314.5)
}
const checkPalette = (what, p, mainIsGenerated) => {
  ok(`${what}: three colours`, !!p && ['primary', 'secondary', 'accent'].every(k => LedColor.isHex(p[k])))
  if (!p) return
  for (const k of mainIsGenerated ? ['primary', 'secondary', 'accent'] : ['secondary', 'accent'])
    ok(`${what}: ${k} ${p[k]} is an LED colour`, ledTrue(p[k]))
  ok(`${what}: apart`, dist(hue(p.primary), hue(p.secondary)) >= 17 && dist(hue(p.primary), hue(p.accent)) >= 17 && dist(hue(p.secondary), hue(p.accent)) >= 17)
}
// The presets are the LED lessons' colours as written (ff1a8c, the hot pink
// that stays pink on fan frames, is not fully saturated): vivid, and outside
// the bands.
const vivid = h => {
  const [hh, s, v] = LedColor.hexToHsv(h)
  return s >= 0.85 && v > 0.99 && !(hh > 19.5 && hh < 74.5) && !(hh > 292.5 && hh < 314.5)
}
for (const hex of Palette.PRESETS) {
  ok(`preset ${hex} is vivid and LED-true`, vivid(hex))
  checkPalette(`fromMain(${hex})`, Palette.fromMain(hex), false)
}
for (const hex of ['ffd0e6', 'ff9a30', 'ffc048', '3e6b96', 'ff00ff', 'ffff00', '20c000', '00e5ff'])
  checkPalette(`fromMain(${hex})`, Palette.fromMain(hex), false)
eq('fromMain keeps the colour picked', Palette.fromMain('#FFD0E6').primary, 'ffd0e6')
eq('fromMain on grey: a cool-white family', Palette.fromMain('808080'), { primary: '808080', secondary: '9fb4ff', accent: 'd8e0ff' })
eq('fromMain on junk', Palette.fromMain('nope'), null)
for (let seed = 1; seed <= 60; seed++) checkPalette(`surprise(${seed})`, Palette.surprise(seed), true)
eq('surprise is repeatable', Palette.surprise(42), Palette.surprise(42))
ok('surprise varies', new Set(Array.from({ length: 12 }, (_, i) => Palette.surprise(i + 1).primary)).size > 6)

const sakura = 'accent = "#F78DBB"\nred = "#F4727F"\ngreen = "#9CCB8F"\nyellow = "#E9C27E"\nblue = "#8FA3EA"\nmagenta = "#E994C8"\ncyan = "#7FCDC3"\n'
const glass = 'mode = "light"\naccent = "#3E6B96"\nred = "#FF3B30"\nyellow = "#FF9500"\ngreen = "#34C759"\ncyan = "#32ADE6"\nblue = "#007AFF"\nmagenta = "#AF52DE"\n'
checkPalette('fromDesktop(sakura)', Palette.fromDesktop(sakura), true)
checkPalette('fromDesktop(glass-white)', Palette.fromDesktop(glass), true)
ok('fromDesktop(sakura) keeps the pink accent', dist(hue(Palette.fromDesktop(sakura).primary), hue('f78dbb')) < 2)
ok('a light desktop stays near its accent', dist(hue(Palette.fromDesktop(glass).secondary), hue('3e6b96')) <= 60)
checkPalette('fromDesktop(gold accent)', Palette.fromDesktop('accent = "#D4AF37"\nred = "#C0392B"\n'), true)
eq('fromDesktop on greys: a cool-white family', Palette.fromDesktop('accent = "#808080"\nforeground = "#eeeeee"\n'), { primary: 'ffffff', secondary: '9fb4ff', accent: 'd8e0ff' })
eq('fromDesktop on nothing', Palette.fromDesktop(''), null)

// ---- colour names for suggestions -----------------------------------------------------
for (const [hex, want] of [['00e5ff', 'Neon Cyan'], ['ff1a8c', 'Neon Pink'], ['ffd0e6', 'Pale Pink'], ['ff0000', 'Neon Red'],
                          ['808080', 'Silver'], ['ffffff', 'White'], ['300060', 'Deep Violet'], ['a6ff00', 'Neon Lime']])
  eq(`colourName(${hex})`, Palette.colourName(hex), want)

console.log(`names: ${checks} checks, ${fails} failed`)
process.exit(fails ? 1 : 0)
