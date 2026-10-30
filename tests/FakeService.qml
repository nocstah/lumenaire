import QtQuick
// render.py stages this file next to the plugin's, so Format.js is a sibling.
import "Format.js" as Format
import "LedColor.js" as LedColor

// Offscreen stand-in for Service.qml: the whole spec §5 API, filled from a
// tests/fixtures/<state>.json file. `load(fixture, themes, dir)` takes the
// parsed fixture, the parsed themes.json and the fixtures directory (theme
// previews in the fixture are relative to it). Actions only record the call
// in `calls`, so the harness can check that the views stay on the API.
QtObject {
    id: root

    // Identity and engine status
    property string pluginId: "io.github.nocstah.lumenaire"
    property bool ready: false
    property string engineError: ""

    // State from the engine
    property var status: null
    property var themes: []
    property var themeByName: ({})
    property string activeTheme: ""
    property string dayTheme: ""
    property string nightTheme: ""
    property string screensShow: ""
    property string lights: "on"
    property string screens: "on"
    property bool clipsPaused: false
    property var rotation: []
    property var schedule: null
    property var omarchy: null

    // Engine state machine
    property string engine: "idle"
    property var busy: null
    property int busyElapsed: 0
    property var pending: []
    property var lastRun: null
    property var ops: ({ theme: null, lights: null, screens: null, clips: null, schedule: null })
    property bool failureUnseen: false
    // Labels, worded the way EngineState words them (Format's op phrases).
    property string busyLabel: busy ? Format.opPhrase(busy.op, busy.target, busy.theme, true) : ""
    property string queuedLabel: {
        const args = { theme: d => ["pick", "", d], lights: d => [d ? "on" : "off", "lights", ""],
                       screens: d => [d ? "on" : "off", "screens", ""], clips: d => ["clips-next", "", ""],
                       schedule: d => ["schedule-set", d ? "on" : "off", ""] }
        for (const kind of ["theme", "lights", "screens", "clips", "schedule"]) {
            const op = ops ? ops[kind] : null
            if (op && (op.phase === "launching" || op.phase === "queued")) {
                const a = args[kind](op.desired)
                return Format.opShort(a[0], a[1], a[2])
            }
        }
        const p = pending && pending.length ? pending[0] : null
        return p ? Format.opShort(p.op, p.target, p.theme) : ""
    }
    property string failureLabel: "The last change failed"

    // Daemon link
    property string daemonState: "connecting"
    property bool daemonOnline: daemonState === "online"
    property string daemonVersion: ""
    property string transport: "socket"

    // Telemetry
    property var pumpRpm: null
    property var coolantC: null
    property var coolantAgeS: null
    property bool coolantStale: false
    property var cpuC: null
    property var gpuC: null
    property var gpuUtil: null
    property var gpuW: null
    property var fans: []
    property var missingDevices: []
    property var screensOnUsb: ({ have: 0, want: 0 })
    property var nowPlaying: ({})
    property var alert: null

    // Hardware profile (contract v1.1), derived with the same Format helpers
    // the real Service uses; a v1.0 fixture (no status.profile) gets the old
    // answers. `sensors` in a fixture is a `pc-lights sensors --json` reply.
    property var profile: null
    property string profileState: ""
    property var sensorSources: null
    property var daemonDevices: []
    property bool hasLianli: true
    property bool hasPump: true
    property bool hasCpuSensor: true
    property bool hasGpuSensor: true
    property var powerDetail: Format.legacyGroups()
    property var screensWant: null

    // Notice
    property string notice: ""
    property string noticeLevel: ""
    property var noticeActions: []
    property string noticeKey: ""

    // UI support
    property int panelOpenCount: 0
    property int previewRev: 0
    property bool previewsBuilding: false
    property var settings: ({ show: "coolant", coolantWarn: 40, showGpu: true, rightClick: "panel", showDot: true })

    // Theme editor (plan §2.4). A fixture brings `editor` (an editor view,
    // render.py resolves editorFile + editorPatch), `preview` (preview.json),
    // `editorLocal` (ops not yet synced: applied to editorDraft, and
    // editPending true) and service overrides for the rest.
    property bool editorAvailable: false
    property var editor: null
    property var editorDraft: null
    property string editorState: "closed"
    property string editorError: ""
    property string editorErrorCode: ""
    property string editorName: ""
    readonly property bool editorOpen: editorState !== "closed"
    property bool editPending: false
    property var drafts: []
    property var preview: null
    property bool previewEnabled: true
    property real previewCountdown: -1
    property real previewIdleLeft: -1
    readonly property bool previewLive: !!preview && ["queued", "applying", "live", "blocked"].indexOf(String(preview.state)) >= 0
    // The engine refused a preview with code "unmeasured" (fixture override).
    property bool previewUnmeasured: false
    property string previewCheckCommand: "lumenaire theme preview --measure"

    // Screens (plan §5.4): the engine's views a fixture brings (render.py
    // inlines screensFile, mediaListFile, jobs and frameFile, patched), and
    // `mediaNote` ({role, text}). File paths in them that aren't absolute
    // are relative to the fixtures directory, like theme previews.
    property var screensView: null
    property string screensState: "closed"
    property string screensError: ""
    property string screenRole: ""
    property var mediaList: null
    property string mediaListState: "idle"
    property string mediaListError: ""
    property var mediaQuery: ({ source: "", role: "", query: "", offset: 0 })
    property var mediaJobs: []
    property var frame: null
    property string frameState: "idle"
    property var mediaNote: null
    property var jobThumbs: ({})
    property var dismissedJobs: ({})

    // The desktop wallpaper (contract v1.4): status.desktop from the fixture,
    // `desktop` (desktop --json of the page's theme; render.py inlines
    // desktopFile + desktopPatch) and `desktopCurrent` (the theme the
    // desktop follows, for the main page's row: desktopCurrentFile, else
    // `desktop` when it is that theme's, else the status as a view). Changes
    // land in desktopLocal, as the Service shows them.
    readonly property var desktopStatus: status && status.desktop && typeof status.desktop === "object" ? status.desktop : null
    readonly property string desktopHome: desktopStatus && desktopStatus.theme ? String(desktopStatus.theme) : activeTheme
    readonly property bool desktopAvailable: !!desktopStatus && (desktopStatus.available === true
        || (!!desktopHomeRead && desktopHomeRead.theme === desktopHome && desktopHomeRead.available === true))
    property string desktopTheme: ""
    property string desktopState: "closed"
    property string desktopError: ""
    property string desktopErrorTip: ""
    property var desktopRead: null
    property var desktopHomeRead: null
    property var desktopLocal: ({})
    readonly property var desktop: desktopTheme && desktopRead && desktopRead.theme === desktopTheme ? Format.desktopWith(desktopRead, desktopLocal[desktopTheme]) : null
    readonly property var desktopCurrent: !desktopStatus ? null
        : Format.desktopWith(desktopHomeRead && desktopHomeRead.theme === desktopHome ? desktopHomeRead : Format.desktopStub(desktopStatus, desktopHome), desktopLocal[desktopHome])

    // Fixture-only: the op kinds whose changes wait for a running apply.
    property var blockedKinds: []
    property var calls: []

    function record(name, arg) { calls = calls.concat([arg === undefined ? name : name + "(" + JSON.stringify(arg) + ")"]) }

    function load(fixture, themeList, dir) {
        const st = fixture.status && fixture.status.v ? fixture.status : null
        const sv = fixture.service || {}
        const opts = fixture.themes || {}
        // A fixture may bring its own theme list (render.py inlines themesFile).
        const source = Array.isArray(fixture.themeList) ? fixture.themeList : themeList
        const list = opts.empty ? [] : (source || []).map(function(t) {
            const c = JSON.parse(JSON.stringify(t))
            if (opts.noPreviews) { c.preview = null; c.preview_mtime = null; c.preview_stale = true }
            if (opts.noCoverage) delete c.coverage
            else if (c.preview && c.preview.charAt(0) !== "/") c.preview = dir + "/" + c.preview
            if (st) { c.active = c.name === st.theme; c.day = c.name === st.day_theme; c.night = !!st.schedule && c.name === st.schedule.night_theme }
            return c
        })
        const byName = {}
        list.forEach(t => byName[t.name] = t)
        const stat = sv.engineError ? null : st
        status = stat
        themes = list
        themeByName = byName
        activeTheme = stat && stat.theme ? stat.theme : ""
        dayTheme = stat && stat.day_theme ? stat.day_theme : ""
        nightTheme = stat && stat.schedule && stat.schedule.night_theme ? stat.schedule.night_theme : ""
        screensShow = stat && stat.screens_show ? stat.screens_show : ""
        lights = stat ? stat.lights : "on"
        screens = stat ? stat.screens : "on"
        clipsPaused = !!stat && !!stat.clips && stat.clips.state === "off"
        rotation = stat && stat.rotation ? stat.rotation : []
        schedule = stat ? stat.schedule : null
        omarchy = stat ? stat.omarchy : null
        busy = stat ? stat.busy : null
        pending = stat && stat.pending ? stat.pending : []
        lastRun = stat ? stat.last_run : null
        screensOnUsb = stat && stat.screens_on_usb ? stat.screens_on_usb : { have: 0, want: 0 }
        alert = stat ? stat.alert : null
        previewsBuilding = !!stat && stat.previews_building === true
        // v1.1: what this PC has.
        profile = Format.profileOf(stat)
        profileState = profile && profile.state ? String(profile.state) : ""
        sensorSources = fixture.sensors && typeof fixture.sensors === "object" ? fixture.sensors : null
        daemonDevices = Format.list(sv.daemonDevices) || []
        const pendingProfile = !!profile && !Format.profileUsable(profile)
        hasLianli = !Format.backendOff(profile, "lianli") && !(pendingProfile && Format.noLianliGear(sensorSources))
        hasPump = hasLianli && Format.hasPump(profile, daemonDevices, sensorSources)
        const src = sensorSources && Number(sensorSources.v) === 1 ? sensorSources : null
        hasCpuSensor = !src || (!!src.cpu && src.cpu.available !== false)
        hasGpuSensor = !src || (!!src.gpu && src.gpu.available !== false)
        powerDetail = Format.powerDetail(profile, hasPump)
        screensWant = Format.screensWant(stat, null)
        const pn = Format.profileNotice(profile)
        notice = pn ? pn.text : ""
        noticeLevel = pn ? pn.level : ""
        noticeActions = pn ? pn.actions : []
        noticeKey = pn ? pn.key : ""
        // Straight §5 overrides from the fixture (engine, telemetry, notice, …).
        const keys = ["ready", "engineError", "engine", "busyElapsed", "ops", "failureUnseen", "failureLabel", "daemonState", "daemonVersion",
                      "transport", "pumpRpm", "coolantC", "coolantAgeS", "coolantStale", "cpuC", "gpuC", "gpuUtil", "gpuW",
                      "fans", "missingDevices", "screensOnUsb", "nowPlaying", "notice", "noticeLevel", "noticeActions", "noticeKey",
                      "previewRev", "settings", "blockedKinds"]
        for (const k of keys) if (sv[k] !== undefined) root[k] = sv[k]
        if (!hasLianli && sv.daemonState === undefined) daemonState = "absent"
        // v1.2: the editor.
        editorAvailable = !!stat && (Number(stat.v_minor) >= 2 || Array.isArray(stat.drafts))
        drafts = stat && Array.isArray(stat.drafts) ? stat.drafts : []
        editor = fixture.editor && typeof fixture.editor === "object" ? fixture.editor : null
        const local = Array.isArray(fixture.editorLocal) ? fixture.editorLocal : []
        editorDraft = editor ? Format.applyOps(editor.theme || {}, local) : null
        editPending = local.length > 0
        editorName = editor ? String(editor.name || "") : ""
        editorState = editor ? "idle" : "closed"
        editorError = ""
        editorErrorCode = ""
        preview = fixture.preview && typeof fixture.preview === "object" ? fixture.preview : null
        previewEnabled = true
        previewCountdown = -1
        previewIdleLeft = -1
        previewUnmeasured = false
        previewCheckCommand = "lumenaire theme preview --measure"
        for (const k of ["editorState", "editorError", "editorErrorCode", "editorName", "previewEnabled", "previewCountdown", "previewIdleLeft", "editPending",
                         "previewUnmeasured", "previewCheckCommand"])
            if (sv[k] !== undefined) root[k] = sv[k]
        if (sv.lights !== undefined) lights = sv.lights
        if (sv.screens !== undefined) screens = sv.screens
        // v1.3: the screen editor.
        const here = p => typeof p === "string" && p !== "" && p.charAt(0) !== "/" ? dir + "/" + p : p
        const fix = (o, keys) => { if (o && typeof o === "object") for (const k of keys) if (o[k]) o[k] = here(o[k]); return o }
        const view = fixture.screens && typeof fixture.screens === "object" ? JSON.parse(JSON.stringify(fixture.screens)) : null
        if (view && Array.isArray(view.screens)) for (const s of view.screens) {
            fix(s.media, ["thumb"]); fix(s.template, ["thumb"])
            if (s.clips && Array.isArray(s.clips.items)) for (const c of s.clips.items) fix(c, ["thumb"])
        }
        screensView = view
        screensState = view ? "idle" : "closed"
        screensError = ""
        screenRole = ""
        const ml = fixture.mediaList && typeof fixture.mediaList === "object" ? JSON.parse(JSON.stringify(fixture.mediaList)) : null
        if (ml && Array.isArray(ml.items)) for (const it of ml.items) fix(it, ["thumb"])
        mediaList = ml
        mediaListState = ml ? "idle" : "idle"
        mediaListError = ""
        mediaJobs = (Array.isArray(fixture.jobs) ? fixture.jobs : []).slice().sort((a, b) => Number(b.started || 0) - Number(a.started || 0))
        const fr = fixture.frame && typeof fixture.frame === "object" ? fix(JSON.parse(JSON.stringify(fixture.frame)), ["path"]) : null
        frame = fr
        frameState = fr ? "idle" : "idle"
        mediaNote = fixture.mediaNote || null
        const th = {}
        const jt = fixture.jobThumbs || {}
        for (const k of Object.keys(jt)) th[k] = here(jt[k])
        jobThumbs = th
        dismissedJobs = ({})
        for (const k of ["screensState", "screensError", "screenRole", "mediaListState", "mediaListError", "frameState"])
            if (sv[k] !== undefined) root[k] = sv[k]
        // v1.4: the desktop wallpaper.
        const dv = fixture.desktop && typeof fixture.desktop === "object" ? fixture.desktop : null
        const home = stat && stat.desktop && stat.desktop.theme ? String(stat.desktop.theme) : activeTheme
        desktopRead = dv
        desktopTheme = dv ? String(dv.theme || "") : ""
        desktopHomeRead = fixture.desktopCurrent && typeof fixture.desktopCurrent === "object" ? fixture.desktopCurrent
            : dv && String(dv.theme || "") === home ? dv : null
        desktopLocal = ({})
        desktopState = dv ? "idle" : "closed"
        desktopError = ""
        desktopErrorTip = ""
        for (const k of ["desktopTheme", "desktopState", "desktopError", "desktopErrorTip", "desktopLocal"])
            if (sv[k] !== undefined) root[k] = sv[k]
        calls = []
    }

    function themeState(name) {
        const op = ops ? ops.theme : null
        if (busy && busy.theme === name) return "applying"
        if (op && op.desired === name) {
            if (op.phase === "applying") return "applying"
            if (op.phase === "launching" || op.phase === "queued") return "queued"
            if (op.phase === "failed") return "failed"
        }
        if ((pending || []).some(p => p.theme === name)) return "queued"
        if (name === activeTheme) return lights === "off" ? "saved" : "active"
        if (schedule && schedule.enabled && name === nightTheme) return "night"
        return ""
    }
    function canChange(kind) { return (blockedKinds || []).indexOf(kind) < 0 }
    function detect() { record("detect") }
    function copyInstallCommand() { record("copyInstallCommand") }

    function pick(name) { record("pick", name) }
    function setLights(on) { record("setLights", on) }
    function setScreens(on) { record("setScreens", on) }
    function skipClip() { record("skipClip") }
    function setClipsPaused(paused) { record("setClipsPaused", paused) }
    function setSchedule(on) { record("setSchedule", on) }
    function retryLast() { record("retryLast") }
    function refresh() { record("refresh") }
    function buildPreviews(force) { record("buildPreviews", force) }
    function panelOpened() { panelOpenCount++; record("panelOpened") }
    function panelClosed() { panelOpenCount = Math.max(0, panelOpenCount - 1); record("panelClosed") }
    function ackFailure() { failureUnseen = false; record("ackFailure") }
    function dismissNotice() { notice = ""; noticeLevel = ""; noticeActions = []; noticeKey = ""; record("dismissNotice") }
    function showLog() { record("showLog") }
    function copyCommand(text) { record("copyCommand", text) }
    function copyPreviewCheckCommand() { record("copyPreviewCheckCommand") }

    // ---- editor (§2.4): the calls are recorded; edits land in editorDraft.
    function canEdit(name) {
        if (!editorAvailable) return "engine"
        if (!Format.profileUsable(profile)) return "no-profile"
        const t = name ? themeByName[name] : null
        if (t && t.editable === false) return String(t.edit_block || "v2")
        if (t && t.auto) return "auto"
        return ""
    }
    function ledShows(hex, cls) { return LedColor.shows(hex, cls, editor ? editor.calibration : null) }
    function ledHints(hex, cls) { return LedColor.hints(hex, cls, editor ? editor.calibration : null) }
    function editTheme(name) { record("editTheme", name); editorName = String(name || ""); editorState = "opening" }
    function newTheme(name, fromName, palette) { record("newTheme", [name, fromName, palette]); editorName = String(name || ""); editorState = "opening" }
    function duplicateTheme(fromName, newName) { record("duplicateTheme", [fromName, newName]); editorName = String(newName || ""); editorState = "opening" }
    function editSet(path, value) { editPatch([Format.setOp(String(path), value === undefined ? null : value)]) }
    function editReset(path) { editPatch([{ op: "remove", path: String(path) }]) }
    function editPatch(ops) {
        record("editPatch", ops)
        editorDraft = Format.applyOps(editorDraft || {}, ops)
        editPending = true
        return true
    }
    function setPreviewEnabled(on) { record("setPreviewEnabled", !!on); previewEnabled = !!on }
    function previewNow() { record("previewNow") }
    function keepPreviewing() { record("keepPreviewing") }
    function endPreview(reason) { record("endPreview", reason || "closed") }
    function saveTheme(opts) { record("saveTheme", opts || {}); editorState = "saving" }
    function revertEdits() { record("revertEdits") }
    function closeEditor(keep) { record("closeEditor", !!keep); editor = null; editorDraft = null; editorState = "closed" }
    function deleteTheme(name) { record("deleteTheme", name) }
    function renameTheme(oldName, newName) { record("renameTheme", [oldName, newName]) }

    // ---- screens (§5.4): the calls are recorded.
    function jobFor(role) {
        const j = (mediaJobs || []).find(x => x && x.role === role && x.draft === editorName && !dismissedJobs[x.id]
                                         && String(x.state) !== "cancelled" && !(String(x.state) === "failed" && x.error && x.error.code === "superseded"))
        if (j) return String(j.state) === "done" ? null : j
        const s = screensView && Array.isArray(screensView.screens) ? screensView.screens.find(x => x && x.role === role) : null
        return s && s.pending && Format.jobRunning(s.pending) ? Object.assign({ role: role, id: s.pending.job }, s.pending) : null
    }
    function screenPreview(role) {
        const p = preview
        return previewLive && p && p.screens && p.screens.roles ? p.screens.roles[role] || null : null
    }
    function jobThumb(id) { return jobThumbs[id] || "" }
    function loadScreens() { record("loadScreens") }
    function openScreen(role) { record("openScreen", role); screenRole = String(role || "") }
    function closeScreen() { record("closeScreen"); screenRole = "" }
    function listMedia(source, role, query, offset) { record("listMedia", [source, role, query || "", offset || 0]); mediaQuery = { source: source, role: role, query: query || "", offset: offset || 0 } }
    function moreMedia() { record("moreMedia") }
    function frameAt(path, t) { record("frameAt", [path, t]) }
    function prepareMedia(role, path, opts) { record("prepareMedia", [role, path, opts || {}]) }
    function cancelMedia(id) { record("cancelMedia", id) }
    function retryMedia(id) { record("retryMedia", id) }
    function setScreenMedia(role, src, allFans) { record("setScreenMedia", [role, src, !!allFans]) }
    function clipAdd(role, src, at) { record("clipAdd", [role, src, at]) }
    function clipRemove(role, i) { record("clipRemove", [role, i]) }
    function clipMove(role, from, to) { record("clipMove", [role, from, to]) }
    function setRotation(role, seconds, shuffle) { record("setRotation", [role, seconds, !!shuffle]) }
    function setScreenMode(role, mode) { record("setScreenMode", [role, mode]) }
    function setScreenBrightness(role, v) { record("setScreenBrightness", [role, v]) }

    // ---- desktop wallpaper (v1.4): the calls are recorded; a change shows at once.
    function loadDesktop(theme) { record("loadDesktop", theme); desktopTheme = String(theme || desktopHome) }
    function closeDesktop() { record("closeDesktop"); desktopTheme = "" }
    function setDesktop(key, value, theme) {
        record("setDesktop", [key, value, theme])
        const k = Format.desktopKey(key)
        const t = String(theme || desktopTheme || desktopHome)
        const v = Format.desktopValue(k, value)
        if (!k || v === null) return false
        const loc = Object.assign({}, desktopLocal)
        loc[t] = Object.assign({}, loc[t] || {})
        loc[t][k] = v
        desktopLocal = loc
        return true
    }
    function resetDesktop(theme) { record("resetDesktop", theme) }
}
