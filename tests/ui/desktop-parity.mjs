#!/usr/bin/env node
// Unit checks for the desktop wallpaper's pure helpers (Format.js, contract
// v1.4) against the engine's frozen views:
//
//   tests/fixtures/desktop.current.json      desktop --json (the desktop's theme, animated version)
//   tests/fixtures/desktop.no-animated.json  … a wallpaper without one
//   tests/fixtures/desktop.other.json        desktop --theme hellfire --json
//   tests/fixtures/desktop.unavailable.json  the shell doesn't answer
//
// It checks the views' shape, the words the main page's row and the page put
// on screen (plain, short, never a path), the values `desktop set` gets, and
// the Resume after choices.
//
//   node tests/ui/desktop-parity.mjs
//
// Format.js is a .pragma library script: it is read as a function body, the
// way tests/ui/names.mjs reads it. Any failed check prints and exits 1.
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const fixtures = join(root, 'tests', 'fixtures')
function lib(name) {
  const src = readFileSync(join(root, name), 'utf8').replace(/^\.pragma library\s*$/m, '').replace(/^\.import .*$/mg, '')
  const names = [...src.matchAll(/^function (\w+)\(/gm), ...src.matchAll(/^const (\w+) =/gm)].map(m => m[1])
  return new Function(src + '\nreturn {' + names.join(',') + '}')()
}
const F = lib('Format.js')
const read = name => JSON.parse(readFileSync(join(fixtures, name), 'utf8'))

let fails = 0, checks = 0
const eq = (what, got, want) => {
  checks++
  if (JSON.stringify(got) !== JSON.stringify(want)) { fails++; console.error(`FAIL ${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`) }
}
const ok = (what, cond) => { checks++; if (!cond) { fails++; console.error(`FAIL ${what}`) } }

const cur = read('desktop.current.json')
const none = read('desktop.no-animated.json')
const other = read('desktop.other.json')
const down = read('desktop.unavailable.json')

// ---- the views' shape (desktop.sh desk_print) --------------------------------------------------
const KEYS = ['v', 'available', 'reason', 'omarchy_theme', 'theme', 'background', 'has_animated', 'playing', 'user_clip', 'screens', 'settings', 'stored', 'defaults']
const SETTINGS = { animated: 'boolean', pause_while_active: 'boolean', resume_after_idle: 'number', while_active: 'string' }
for (const [name, v] of [['current', cur], ['no-animated', none], ['other', other], ['unavailable', down]]) {
  eq(`${name}: keys`, Object.keys(v), KEYS)
  eq(`${name}: v`, v.v, 1)
  for (const part of ['settings', 'defaults'])
    eq(`${name}: ${part} types`, Object.fromEntries(Object.entries(v[part]).map(([k, x]) => [k, typeof x])), SETTINGS)
  ok(`${name}: stored keys are settings`, Object.keys(v.stored).every(k => k in SETTINGS))
  ok(`${name}: no real home`, !/\/home\/(?!user\/)/.test(JSON.stringify(v)))
}
eq('other: what is on screen is unknown', [other.background, other.has_animated, other.playing, other.user_clip, other.screens], [null, null, null, null, null])
// screens (additive): each connected monitor, portrait or not, its clip (null when none) and whether it plays.
for (const [name, v] of [['current', cur], ['no-animated', none], ['unavailable', down]]) {
  ok(`${name}: screens is a list`, Array.isArray(v.screens))
  for (const s of v.screens)
    eq(`${name}: screen ${s.name} shape`, [Object.keys(s), typeof s.name, typeof s.portrait, s.clip === null || typeof s.clip === 'string', typeof s.playing],
      [['name', 'portrait', 'clip', 'playing'], 'string', 'boolean', true, 'boolean'])
}
eq('current: a portrait monitor plays the portrait clip', cur.screens.filter(s => s.portrait).map(s => /\.portrait\.mp4$/.test(s.clip)), [true])
eq('unavailable: nothing known to play', down.screens.map(s => [s.clip, s.playing]), [[null, false], [null, false]])
eq('unavailable: why', [down.available, down.reason, down.playing, down.user_clip], [false, 'shell-down', null, null])
eq('available: no reason', [cur.reason, none.reason, other.reason], [null, null, null])

// ---- keys, verbs and values for `desktop set` ----------------------------------------------------
eq('keys', ['animated', 'pause', 'pause_while_active', 'resume', 'resume_after_idle', 'while', 'while_active', 'colour', '', null].map(F.desktopKey),
   ['animated', 'pause_while_active', 'pause_while_active', 'resume_after_idle', 'resume_after_idle', 'while_active', 'while_active', '', '', ''])
eq('verbs', ['animated', 'pause_while_active', 'resume_after_idle', 'while_active', 'pause', 'x'].map(F.desktopVerb),
   ['animated', 'pause', 'resume', 'while', 'pause', ''])
eq('switch values', [true, false, 'true', 'off', 'toggle', 1, null].map(v => F.desktopValue('pause', v)), [true, false, true, false, null, null, null])
eq('seconds', [1, 5, 600, '7', 0, 601, 2.5, true, '', null, 'x'].map(v => F.desktopValue('resume', v)), [1, 5, 600, 7, null, null, null, null, null, null, null])
eq('while values', ['freeze', 'still', 'Still', '', null].map(v => F.desktopValue('while', v)), ['freeze', 'still', null, null, null])
eq('no such setting', F.desktopValue('colour', 'red'), null)
eq('args', [true, false, 10, 'still'].map(F.desktopArg), ['true', 'false', '10', 'still'])

// ---- the main page's row -------------------------------------------------------------------------
const with_ = (v, s) => Object.assign({}, v, { settings: Object.assign({}, v.settings, s) })
eq('row: animated, pauses', F.desktopSummary(cur), 'Animated · pauses while you work')
eq('row: animated', F.desktopSummary(with_(cur, { pause_while_active: false })), 'Animated')
eq('row: still', F.desktopSummary(with_(cur, { animated: false })), 'Still')
eq('row: no animated version first', [F.desktopSummary(none), F.desktopSummary(with_(none, { animated: false }))], ['No animated version', 'No animated version'])
eq('row: nothing yet', F.desktopSummary(null), '')
// status --json `desktop` stands in until the view is read.
const st = { available: true, theme: 'sakura', settings: cur.settings, playing: true, at: 1790231170 }
const stub = F.desktopStub(st, 'x')
eq('stub', [stub.theme, stub.available, stub.has_animated, stub.playing, stub.stored, F.desktopSummary(stub)], ['sakura', true, null, true, null, 'Animated · pauses while you work'])
eq('stub without a theme', F.desktopStub({ available: null, settings: {} }, 'hellfire').theme, 'hellfire')
eq('stub of nothing', F.desktopStub(null, 'x'), null)
// Changes on their way lie over the view (and count as the theme's own).
const over = F.desktopWith(cur, { animated: false })
eq('local change', [over.settings.animated, over.stored.animated, cur.settings.animated, F.desktopSummary(over)], [false, false, true, 'Still'])
eq('nothing local', F.desktopWith(cur, {}) === cur && F.desktopWith(cur, undefined) === cur, true)

// ---- the page ----------------------------------------------------------------------------------------
eq('line: animated version', F.desktopAnimatedLine(cur, true), 'This wallpaper has an animated version')
eq('line: none', F.desktopAnimatedLine(none, true), 'No animated version for this wallpaper')
eq('line: another theme', F.desktopAnimatedLine(other, false), 'Applies when Hellfire is on')
eq('line: an auto-theme', F.desktopAnimatedLine(Object.assign({}, other, { theme: 'omarchy-oxblood-parchment' }), false), 'Applies when Oxblood Parchment is on')
eq('line: the desktop\'s theme, not read yet', F.desktopAnimatedLine(stub, true), '')
eq('line: a video the user picked', [F.desktopAnimatedLine(Object.assign({}, cur, { user_clip: true }), true),
   F.desktopAnimatedLine(Object.assign({}, none, { user_clip: true }), true)], ['Playing a video you picked', 'Playing a video you picked'])
eq('unavailable', [F.desktopUnavailable('shell-down'), F.desktopUnavailable('no-plugin'), F.desktopUnavailable(null)],
   ["The desktop isn't answering right now.", 'Animated wallpapers need the Motion Wallpaper plugin.', "The wallpaper can't be changed right now."])
eq('refused', ['not-found', 'busy', 'invalid', 'usage', ''].map(F.desktopError),
   ["That theme isn't there any more.", 'The desktop is busy. Try again in a moment.', "That change didn't go through.", "That change didn't go through.", "That change didn't go through."])
eq('resume choices', F.resumeOptions(5).map(o => o.label), ['3 s', '5 s', '10 s', '30 s'])
eq('resume, set elsewhere', F.resumeOptions(45).map(o => o.value), ['3', '5', '10', '30', '45'])
eq('resume, minutes', F.resumeOptions(120).map(o => o.label), ['3 s', '5 s', '10 s', '30 s', '2 min'])
eq('resume, odd seconds', F.resumeOptions(90).map(o => o.label).pop(), '90 s')
eq('resume, not a value', F.resumeOptions(0).length, 4)
eq('resume steps', [F.resumeStep(5, 1), F.resumeStep(5, -1), F.resumeStep(3, -1), F.resumeStep(30, 1), F.resumeStep(45, -1), F.resumeStep(7, 1)], [10, 3, 3, 30, 30, 10])
eq('custom: none stored', F.desktopCustom(cur), false)
eq('custom: stored and different', F.desktopCustom(Object.assign({}, other, { stored: { pause_while_active: false } })), true)
eq('custom: stored like the defaults', F.desktopCustom(Object.assign({}, other, { stored: { pause_while_active: true, resume_after_idle: 5 } })), false)
eq('custom: no defaults known', F.desktopCustom(Object.assign({}, other, { stored: { animated: true }, defaults: null })), true)
eq('custom: nothing', F.desktopCustom(null), false)

// ---- the UI fixtures: every view they name exists, no paths on screen, no real ids ----------------
const mine = readdirSync(fixtures).filter(f => /^wallpaper-/.test(f) && f.endsWith('.json'))
ok('there are wallpaper fixtures', mine.length >= 12)
for (const f of mine) {
  const text = readFileSync(join(fixtures, f), 'utf8')
  const d = JSON.parse(text)
  for (const k of ['desktopFile', 'desktopCurrentFile']) if (d[k]) ok(`${f}: ${d[k]} is a desktop view`, /^desktop\.[a-z-]+\.json$/.test(d[k]) && mine.length > 0 && readdirSync(fixtures).includes(d[k]))
  ok(`${f}: no real home`, !/\/home\/(?!user\/)/.test(text))
}
for (const v of [cur, none, other, down])
  for (const words of [F.desktopSummary(v), F.desktopAnimatedLine(v, v.theme === 'sakura')])
    ok(`no path in "${words}"`, !/[/\\]|\.(png|jpe?g|mp4|webm|mkv)\b/.test(words))

console.log(`desktop: ${checks} checks, ${fails} failed`)
process.exit(fails ? 1 : 0)
