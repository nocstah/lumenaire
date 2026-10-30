#!/usr/bin/env node
// Unit checks for the screen editor's pure helpers (Format.js), against the
// engine's frozen contract views (plan §7):
//
//   tests/fixtures/screens.sakura.json      theme screens --json
//   tests/fixtures/media.list.*.json        media list --json
//   tests/fixtures/media.job.*.json         job records
//   tests/fixtures/preview.screens.json     preview.json with its screens part
//
// It checks that role-alias pointers ("/screens/@screen.fan3/brightness")
// never touch the optimistic draft, and that every label the views put on
// screen comes out as DESIGN.md words it: plain, short, no file names.
//
//   node tests/ui/screens-parity.mjs
//
// Format.js is a .pragma library script: it is read as a function body, the
// way tests/ui/names.mjs reads it. Any failed check prints and exits 1.
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
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

const view = read('screens.sakura.json')
const byRole = Object.fromEntries(view.screens.map(s => [s.role, s]))
const pv = read('preview.screens.json')
const lib_ = read('media.list.library.json')
const theme = read('media.list.theme.json')
const running = read('media.job.running.json')
const done = read('media.job.done.json')
const failed = read('media.job.failed.json')

// ---- role-alias pointers: the engine resolves them, the draft copy doesn't -----
const draft = { v: 3, palette: { primary: 'ff4a9a' }, screens: { 'screen.fan': [{ type: 'video', path: 'media/fan-a.mp4' }] } }
eq('isAliasPtr', ['/screens/@screen.fan3/brightness', '/screens/screen.fan/0/path', '/roles/fans/inner'].map(F.isAliasPtr), [true, false, false])
eq('applyOps ignores an alias pointer', F.applyOps(draft, [F.setOp('/screens/@screen.fan3/brightness', 80)]), draft)
eq('applyOps ignores an alias remove', F.applyOps(draft, [{ op: 'remove', path: '/screens/@screen.pump/brightness' }]), draft)
eq('applyOps still applies the rest', F.applyOps(draft, [F.setOp('/screens/@screen.fan3/brightness', 80), F.setOp('/palette/primary', '00e5ff')]).palette.primary, '00e5ff')
eq('queueOp keeps alias pointers apart', F.queueOp([F.setOp('/screens/@screen.fan1/brightness', 50)], F.setOp('/screens/@screen.fan2/brightness', 60)).length, 2)
eq('the view names the pointer the Service writes', byRole['screen.fan3'].brightness.path, '/screens/@screen.fan3/brightness')

// ---- the case map --------------------------------------------------------------------
for (const s of view.screens) {
  eq(`screenShort(${s.role}) is the view's`, F.screenShort(s), s.short)
  ok(`screenShort(${s.role}) from the role alone is plain`, /^(Fan \d+|Pump|Main screen)$/.test(F.screenShort(s.role)))
  ok(`screenAspect(${s.role})`, Math.abs(F.screenAspect(s) - s.media_size[0] / s.media_size[1]) < 1e-9)
  const tip = F.tileTip(s, '')
  ok(`tileTip(${s.role}) names it first`, tip.split('\n')[0].indexOf(s.short) === 0)
  ok(`tileTip(${s.role}) has no path`, !/[/\\]|\.(mp4|webp|jpg|png|json)\b/i.test(tip))
}
eq('placeWords', ['right', 'left', 'top', 'bottom', 'centre'].map(F.placeWords), ['right column', 'left column', 'top row', 'bottom row', ''])
eq('screen glyphs differ', new Set(['fan', 'pump', 'main', 'aux'].map(F.screenGlyph)).size, 4)
eq('pump clips summary', F.clipsSummary(byRole['screen.pump'].clips), 'Takes turns · 2 clips')
eq('one clip', F.clipsSummary({ items: [{}] }), 'One clip')
eq('clips without turns', F.clipsSummary({ rotate: null, items: [{}, {}, {}] }), '3 clips')
eq('map order covers every screen', [...view.map.order].sort(), view.screens.map(s => s.role).sort())

// ---- the picker's words ----------------------------------------------------------------
const lines = Object.fromEntries(lib_.items.map(it => [it.id, F.tileLine(it)]))
eq('an exact clip is its length', lines['m-3fa9c2d1e0'], '0:05')
eq('a portrait clip on the pump', lines['m-81c07d5b22'], "Doesn't fit")
eq('a file not read yet', lines['m-5d0e6a91f4'], 'Checking…')
eq('a scaled upload fits', lines['m-0b9f3e7c65'], '0:30')
eq('a 16:9 clip on the pump', lines['m-9a4410e2d8'], '0:42 · cropped')
eq('a fan clip on the pump', lines['m-6e3d95ab10'], "Doesn't fit")
for (const it of lib_.items.concat(theme.items)) {
  const l = F.tileLine(it)
  ok(`tileLine(${it.id}) is short`, l.length <= 17)
  ok(`tileLine(${it.id}) has no file name`, it.title === '' || l.toLowerCase().indexOf(String(it.title).toLowerCase()) < 0)
  ok(`tileLineShort(${it.id}) fits a narrow tile`, F.tileLineShort(it).length <= 15)
}
eq('a cropped picture, narrow', F.tileLineShort({ kind: 'image', fit: { state: 'cropped', keep: 0.75 } }), 'Cropped')
eq('a cropped picture, wide', F.tileLine({ kind: 'image', fit: { state: 'cropped', keep: 0.75 } }), 'Picture · cropped')
eq('fitsAsIs', ['exact', 'scaled', 'cropped', 'poor', 'unknown'].map(st => F.fitsAsIs({ state: st })), [true, true, false, false, false])
eq('fitTip cropped', F.fitTip({ state: 'cropped', keep: 0.839 }, 'Pump'), 'Cropped to fit: keeps 84 % of the picture')
eq('fitTip poor with a note', F.fitTip({ state: 'poor', keep: 0.366, note: 'low-res' }, 'Pump'), "Doesn't fit pump: choose it to crop it to fit (keeps 37 %)\nLow resolution; it may look soft")
eq('mediaColumns', [['square', false], ['square', true], ['wide-curve', false], ['wide-curve', true], ['strip', false], ['strip', true], ['round', true]].map(a => F.mediaColumns(...a)), [4, 3, 2, 2, 2, 1, 3])
eq('This theme sorts fits first', theme.items.map(it => F.fitsAsIs(it.fit)).indexOf(false) >= theme.items.filter(it => F.fitsAsIs(it.fit)).length, true)

// ---- jobs ------------------------------------------------------------------------------
eq('running', [F.jobRunning(running), F.jobText(running)], [true, 'Preparing… 42 %'])
eq('waiting', F.jobText({ state: 'waiting' }), 'Waiting…')
eq('queued', F.jobText({ state: 'queued' }), 'Preparing…')
eq('the view\'s pending job', F.jobText(byRole['screen.pump'].pending), 'Preparing… 42 %')
eq('done', [F.jobRunning(done), F.jobText(done)], [false, ''])
eq('failed', [F.jobText(failed), F.jobErrorTip(failed), F.jobFix(failed)], ["Couldn't prepare it", "It isn't a picture or video this PC can read", 'choose'])
eq('disk full', [F.jobErrorTip({ error: { code: 'disk-full' } }), F.jobFix({ error: { code: 'disk-full' } })], ['Not enough disk space', 'retry'])
eq('stopped', [F.jobErrorTip({ error: { code: 'stopped' } }), F.jobFix({ error: { code: 'stopped' } })], ['Stopped', 'retry'])
// Every job error code (docs/MEDIA.md): one calm sentence and one fix; a
// cancel (superseded) and a draft that went away say nothing.
for (const code of ['broken', 'no-picture', 'unsupported', 'too-large', 'disk-full', 'stage-full', 'missing-tool', 'not-applied', 'stopped', 'busy']) {
  const j = { state: 'failed', error: { code: code, text: 'engine words' } }
  const tip = F.jobErrorTip(j)
  ok(`jobErrorTip(${code}) is a plain sentence`, tip !== '' && tip !== 'engine words' && /^[A-Z]/.test(tip) && !/[.]$/.test(tip))
  ok(`jobFix(${code})`, ['retry', 'choose'].indexOf(F.jobFix(j)) >= 0)
  const l = F.screenLine(byRole['screen.fan1'], j, null, { previewLive: true, screensOn: true })
  eq(`screenLine for ${code}`, [l.text, l.tip], ["Couldn't prepare it", tip])
}
eq('an unreadable file offers another', ['broken', 'no-picture', 'unsupported', 'too-large'].map(c => F.jobFix({ error: { code: c } })), ['choose', 'choose', 'choose', 'choose'])
eq('the rest try again', ['disk-full', 'stage-full', 'stopped', 'busy', 'not-applied', 'missing-tool'].map(c => F.jobFix({ error: { code: c } })), ['retry', 'retry', 'retry', 'retry', 'retry', 'retry'])
for (const code of ['superseded', 'no-draft'])
  eq(`${code} is quiet on the main page`, F.mediaNotice({ running: 0, jobs: [{ id: 'j-9', draft: 'x', role: 'screen.fan1', state: 'failed', progress: 0, error: { code: code }, then: 'set', applied: null }] }, '', {}, 0), null)
eq('media nouns', [F.screenMediaNoun('screen.pump', 'video'), F.screenMediaNoun('screen.fan3', 'image'), F.screenMediaNoun('screen.main', 'video', '8.8" screen')],
   ['pump video', 'fan 3 picture', '8.8" screen video'])

// ---- the lines: a screen's page and under the map ------------------------------------
const roles = pv.screens.roles
const live = { previewLive: true, screensOn: true }
const line = (role, job, o) => F.screenLine(byRole[role], job || null, roles[role] || null, o || live)
eq('fan 1 on the case', line('screen.fan1').text, 'On the case')
eq('fan 2 couldn\'t show it', [line('screen.fan2').text, line('screen.fan2').level, line('screen.fan2').action], ["Couldn't show it", 'urgent', 'choose'])
eq('fan 2: the daemon\'s error is the tooltip', line('screen.fan2').tip, 'Media preparation failed: could not decode the video')
eq('the pump preparing on the case', line('screen.pump').text, 'Updating…')
eq('a job first', [line('screen.fan3', running).text, line('screen.fan3', running).action], ['Preparing… 42 %', 'cancel'])
eq('a failed job before the preview', line('screen.fan2', failed).action, 'choose')
eq('screens off', line('screen.fan1', null, { previewLive: true, screensOn: false }).text, 'Screens are off')
eq('off USB', F.screenLine(byRole['screen.fan1'], null, { state: 'off-usb' }, live).text, 'Not connected')
eq('no preview, changed', F.screenLine(byRole['screen.fan3'], null, null, { previewLive: false, screensOn: true }).text, 'Shows after you save')
eq('no preview, unchanged', F.screenLine(byRole['screen.fan1'], null, null, { previewLive: false, screensOn: true }).text, '')
const noLayout = JSON.parse(JSON.stringify(byRole['screen.main']))
noLayout.template.installed = false
eq('a layout not installed yet', F.screenLine(noLayout, null, roles['screen.main'], live).text, 'Shows after you save')
const unfit = JSON.parse(JSON.stringify(byRole['screen.fan1']))
unfit.media.fit = { state: 'poor', keep: 0.5625 }
eq('media that doesn\'t fit', [F.screenLine(unfit, null, null, live).text, F.screenLine(unfit, null, null, live).action], ["Doesn't fit this screen", 'crop'])
const gone = JSON.parse(JSON.stringify(byRole['screen.fan1']))
gone.media.where = 'missing'
eq('a missing file', F.screenLine(gone, null, null, live).text, 'Its file is missing')
const jobs = { 'screen.fan3': running }
const map = (js, o) => F.mapLine(view.screens, r => (js || {})[r] || null, r => roles[r] || null, o || live)
eq('map: a failed job first', [map({ 'screen.fan2': failed }).text, map({ 'screen.fan2': failed }).action], ["Fan 2 couldn't be prepared", 'choose'])
eq('map: then a screen that couldn\'t show it', [map().text, map().role], ["Fan 2 couldn't show it", 'screen.fan2'])
const calm = r => r === 'screen.fan2' ? { state: 'ready' } : roles[r] || null
eq('map: then a job running', F.mapLine(view.screens, r => jobs[r] || null, calm, live).text, 'Fan 3: preparing… 42 %')
eq('map: sending', F.mapLine(view.screens, () => null, calm, live).text, 'Updating…')
eq('map: screens off', F.mapLine(view.screens, () => null, () => null, { previewLive: false, screensOn: false }).text, 'Screens are off')
eq('map: changed, no preview', F.mapLine(view.screens, () => null, () => null, { previewLive: false, screensOn: true }).text, 'Shows after you save')
eq('map: nothing changed', F.mapLine(view.screens.map(s => Object.assign({}, s, { changed: false })), () => null, () => null, { previewLive: false, screensOn: true }).text, '')
for (const s of view.screens) for (const o of [live, { previewLive: false, screensOn: true }])
  ok(`screenLine(${s.role}) is one short line`, F.screenLine(s, null, roles[s.role], o).text.length <= 26)

// ---- Change every -------------------------------------------------------------------------
eq('choices', F.rotateOptions(view.limits.rotate_choices).map(o => o.label), ['1 min', '5 min', '15 min', '1 h', 'Off'])
eq('h/l from 5 min', [F.rotateStep(300, 1), F.rotateStep(300, -1)], [900, 60])
eq('h/l at the ends', [F.rotateStep(60, -1), F.rotateStep(3600, 1), F.rotateStep(0, 1), F.rotateStep(0, -1)], [60, 0, 0, 3600])
eq('a value off the grid snaps', [F.rotateStep(120, 1), F.rotateStep(120, -1), F.rotateStep(5000, -1)], [300, 60, 3600])

// ---- the crop line --------------------------------------------------------------------------
eq('fits', F.cropLine({ keep: 1, scale: 1, capS: 0, duration: 0 }).text, 'Fits as it is')
eq('keeps', F.cropLine({ keep: 0.839, scale: 1.19, capS: 120, duration: 42 }).text, 'Keeps 84 % of the picture')
eq('soft', F.cropLine({ keep: 1, scale: 6.25, capS: 0, duration: 0 }).text, 'Low resolution; it may look soft')
eq('long first', F.cropLine({ keep: 0.84, scale: 1.19, capS: 120, duration: 200, screen: 'Pump' }), { text: 'Uses the first 2:00', tip: 'The pump can take about 2 minutes at a time' })

// ---- refused changes and the preview's screens ending -------------------------------------------
for (const code of ['usage', 'invalid', 'not-found', 'no-role', 'unfit', 'unsupported', 'media-pending', 'not-v3', 'no-profile']) {
  const w = F.mediaEditError(code)
  ok(`mediaEditError(${code}) is one calm sentence`, /^[A-Z][^\n]*[.…]$/.test(w.text) && w.text.length <= 80 && !/[-_]/.test(w.text.replace(/\b(isn't|doesn't|didn't)\b/g, '')))
}
eq('media-pending is not an error', F.mediaEditError('media-pending'), { text: "Still preparing… Save when it's done.", level: '' })
eq('the preview ended by the screens going off', F.previewStatus({ state: 'ended', ended: { reason: 'screens-off' } }, { enabled: true, lightsOn: true, countdown: -1, idleLeft: -1 }).text,
   'Stopped: the screens went off')

// ---- the main page's notice ---------------------------------------------------------------------
const st = (job) => ({ running: 1, jobs: [job] })
eq('running, no editor', F.mediaNotice(st({ id: 'j-1', draft: 'sakura-2', role: 'screen.pump', state: 'encoding', progress: 0.42 }), '', {}, 0).text, 'Preparing Sakura 2’s pump video… 42 %')
eq('running in the open editor: quiet', F.mediaNotice(st({ id: 'j-1', draft: 'sakura-2', role: 'screen.pump', state: 'encoding', progress: 0.42 }), 'sakura-2', {}, 0), null)
const bad = { id: 'j-2', draft: 'sakura-2', role: 'screen.fan2', state: 'failed', error: { code: 'unsupported' }, ended: 1790000407 }
eq('failed', F.mediaNotice(st(bad), '', {}, 1790000500), { key: 'media:j-2', level: 'urgent', actions: ['dismiss'], text: 'Couldn’t prepare Sakura 2’s fan 2 video.' })
eq('failed, dismissed', F.mediaNotice(st(bad), '', { 'media:j-2': true }, 1790000500), null)
eq('failed long ago', F.mediaNotice(st(bad), '', {}, 1790009000), null)
// status --json v1.3 media.jobs as json.sh writes them: progress a number, no times.
eq('status shape, failed', F.mediaNotice({ running: 0, jobs: [{ id: 'j-3', draft: 'hellfire-2', role: 'screen.main', state: 'failed', progress: 0.1, error: { code: 'disk-full', text: 'x' }, then: 'set', applied: null }] }, '', {}, 1790000500).text,
   'Couldn’t prepare Hellfire 2’s main screen video.')
eq('status shape, running', F.mediaNotice({ running: 1, jobs: [{ id: 'j-4', draft: 'hellfire-2', role: 'screen.fan1', state: 'waiting', progress: null, error: null, then: 'set', applied: null }] }, '', {}, 0).text,
   'Preparing Hellfire 2’s fan 1 video…')
eq('superseded is quiet', F.mediaNotice(st(Object.assign({}, bad, { error: { code: 'superseded' } })), '', {}, 1790000500), null)

// ---- the UI fixtures: every picture they point at exists, no real ids -------------------------------
const mine = readdirSync(fixtures).filter(f => /^(editor-screens|screen-|picker-|crop-|notice-prepar)/.test(f) && f.endsWith('.json'))
ok('there are screen fixtures', mine.length >= 30)
for (const f of mine) {
  const text = readFileSync(join(fixtures, f), 'utf8')
  const pics = [...text.matchAll(/"(\.\.\/ui\/thumbs\/[^"]+)"/g), ...text.matchAll(/"thumb": "(media\/[^"]+)"/g)].map(m => m[1])
  for (const p of pics) ok(`${f}: ${p} exists`, existsSync(resolve(fixtures, p)))
}

console.log(`screens: ${checks} checks, ${fails} failed`)
process.exit(fails ? 1 : 0)
