// Lumenaire — service half. The one instance behind every bar widget and
// panel; views bind to the API below and never run anything themselves.
//
//   DaemonLink   persistent socket to lianli-daemon: pump, coolant, fans,
//                missing wireless devices, now-playing clips, alert limits
//   Sensors      CPU always, GPU while a panel is open, from the sources
//                `pc-lights sensors --json` names (k10temp/nvidia-smi on v1.0)
//   EngineState  `pc-lights status/themes --json`, the op state machines and
//                the one notice to show
//   here         the inotify watcher that re-reads the engine on change, the
//                launcher, settings from shell.json, and IPC
//
// Every change goes out through `pc-lights --detach …`, which validates,
// queues a transient systemd unit and exits within ~200 ms. A lighting apply
// takes 20 s to 3 min and must never be a child of the shell: a shell restart
// would SIGTERM it mid-apply and the engine's trap would restore and restart
// the daemon. This service never stops a unit either; the engine's own
// coalescing (the last pick wins) handles repeated clicks.
//
// Started once from onManifestChanged (the shell assigns `manifest` after
// construction); stopped in Component.onDestruction. There is no keepLoaded,
// so a hot reload builds a fresh instance that re-reads everything.
import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as Format
import "LedColor.js" as LedColor

Scope {
    id: root

    // Injected by the shell after construction (shell.qml ensureService).
    property var shell: null
    property var manifest: null
    property string omarchyPath: ""

    readonly property string pluginId: "io.github.nocstah.lumenaire"
    readonly property string home: Quickshell.env("HOME") || ""
    // The engine: ~/.local/bin/lumenaire when it exists, else the old name
    // ~/.local/bin/pc-lights (an alias the installer keeps), else the copy
    // that ships with the plugin (bin/lumenaire), resolved once at start. Tests
    // point it at a fixture script (LUMENAIRE_PCL_BIN).
    readonly property string userBin: home + "/.local/bin/lumenaire"
    readonly property string legacyBin: home + "/.local/bin/pc-lights"
    readonly property string bundledBin: String(Qt.resolvedUrl("bin/lumenaire")).replace(/^file:\/\//, "")
    property string pclBin: Quickshell.env("LUMENAIRE_PCL_BIN") || ""
    property string systemdRun: "systemd-run"
    property string configDir: home + "/.config/pc-lights"
    property string cacheDir: home + "/.cache/pc-lights"
    property string omarchyStateDir: home + "/.local/state/omarchy/current"
    property string daemonSocket: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/lianli-daemon.sock"
    property bool started: false

    // ---- public API (spec §5) ---------------------------------------------
    readonly property bool ready: engineState.ready
    readonly property string engineError: engineState.engineError
    readonly property var status: engineState.status
    readonly property var themes: engineState.themes
    readonly property var themeByName: engineState.themeByName
    readonly property string activeTheme: status && status.theme ? String(status.theme) : ""
    readonly property string dayTheme: status && status.day_theme ? String(status.day_theme) : ""
    readonly property string nightTheme: status && status.schedule && status.schedule.night_theme ? String(status.schedule.night_theme) : ""
    readonly property string screensShow: status && status.screens_show ? String(status.screens_show) : ""
    readonly property string lights: optimistic("lights", status ? status.lights : "")
    readonly property string screens: optimistic("screens", status ? status.screens : "")
    readonly property bool clipsPaused: clipsWant !== null ? clipsWant.paused
        : !!(status && status.clips && (status.clips.state === "off" || (status.clips.paused_at !== null && status.clips.paused_at !== undefined)))
    readonly property var rotation: status && Array.isArray(status.rotation) ? status.rotation : []
    readonly property var schedule: status && status.schedule ? status.schedule : null
    readonly property var omarchy: status && status.omarchy ? status.omarchy : null

    readonly property string engine: engineState.engine
    readonly property var busy: engineState.busy
    readonly property int busyElapsed: engineState.busyElapsed
    readonly property var pending: engineState.pending
    readonly property var lastRun: engineState.lastRun
    readonly property var ops: engineState.ops
    readonly property bool failureUnseen: engineState.failureUnseen
    // Words for the header and the bar tooltip, whatever kind of op it is.
    readonly property string busyLabel: engineState.busyLabel
    readonly property string queuedLabel: engineState.queuedLabel
    readonly property string failureLabel: engineState.failureLabel

    // "absent" when the profile says this PC has no Lian Li backend.
    readonly property string daemonState: !hasLianli || (lianliQuiet && daemonLink.linkState !== "online") ? "absent"
        : daemonLink.enabled ? daemonLink.linkState : "connecting"
    readonly property bool daemonOnline: daemonLink.online
    readonly property string daemonVersion: daemonLink.version
    readonly property string transport: daemonLink.transport

    readonly property var pumpRpm: daemonLink.pumpRpm
    readonly property var coolantC: daemonLink.coolantC
    readonly property var coolantAgeS: daemonLink.coolantAgeS
    readonly property bool coolantStale: daemonLink.coolantStale
    readonly property var cpuC: sensors.cpuC
    readonly property var gpuC: sensors.gpuC
    readonly property var gpuUtil: sensors.gpuUtil
    readonly property var gpuW: sensors.gpuW
    readonly property bool gpuFailed: sensors.gpuFailed
    readonly property var fans: daemonLink.fans
    readonly property var missingDevices: daemonLink.missingDevices
    readonly property var screensOnUsb: status && status.screens_on_usb ? status.screens_on_usb : daemonLink.lcdCount
    readonly property var nowPlaying: daemonLink.nowPlaying
    readonly property var alert: daemonLink.alert || (status && status.alert ? status.alert : null)

    // ---- hardware profile (contract v1.1; all optional) --------------------
    // Without a profile (v1.0, or none detected yet) these keep the panel as
    // it was: every section shown, the old Lights wording.
    readonly property var profile: engineState.profile
    readonly property string profileState: profile && profile.state ? String(profile.state) : ""
    readonly property var sensorSources: sensors.sources
    readonly property var liveSources: sensors.mode === "profile" ? sensors.sources : null
    // Before the first detect nothing says whether this PC has Lian Li gear:
    // sensors --json finding none means no, and a daemon that never answered
    // stays quiet (no "offline", no pump cells) until it does.
    readonly property bool profilePending: !!profile && !Format.profileUsable(profile)
    readonly property bool hasLianli: !Format.backendOff(profile, "lianli") && !(profilePending && Format.noLianliGear(liveSources))
    readonly property bool lianliQuiet: profilePending && !daemonLink.everOnline
    readonly property bool hasPump: hasLianli && !lianliQuiet && Format.hasPump(profile, daemonLink.devices, liveSources)
    readonly property bool hasCpuSensor: sensors.cpuAvailable
    readonly property bool hasGpuSensor: sensors.gpuAvailable
    readonly property var powerDetail: Format.powerDetail(profile, hasPump)
    readonly property var screensWant: Format.screensWant(status, daemonLink.lcdCount)

    readonly property string notice: engineState.notice.text
    readonly property string noticeLevel: engineState.notice.level
    // Which notice it is ("saved", "busy", "op:theme:…"), so a view can stand
    // in for one (the panel's "Saved … Use it now?" replaces the saved flash).
    readonly property string noticeKey: String(engineState.notice.key || "")
    readonly property var noticeActions: engineState.notice.actions

    property int panelOpenCount: 0
    readonly property int previewRev: engineState.previewRev
    property double previewsLaunchedAt: 0
    readonly property bool previewsBuilding: !!(status && status.previews_building) || engineState.now - previewsLaunchedAt < 5
    readonly property var settings: readSettings(fileConfig)

    // ---- functions (all return at once) -----------------------------------
    function pick(name) {
        name = String(name || "")
        if (!name) return false
        engineState.beginOp("theme", name)
        launch(["--detach", "pick", name], (c, o, e) => engineState.launched("theme", c, o, e))
        return true
    }
    function setLights(on) { return power("lights", !!on) }
    function setScreens(on) { return power("screens", !!on) }
    function power(kind, on) {
        engineState.beginOp(kind, on)
        launch(["--detach", on ? "on" : "off", kind], (c, o, e) => engineState.launched(kind, c, o, e))
        return true
    }
    function setSchedule(on) {
        engineState.beginOp("schedule", !!on)
        launch(["--detach", "schedule", on ? "on" : "off"], (c, o, e) => engineState.launched("schedule", c, o, e))
        return true
    }
    // Why a skip can't run now ("" = it can): the bar's middle click and the
    // IPC skip have no disabled state to show it.
    function skipRefusal() {
        if (busy !== null) return "A theme change is running; skip again when it finishes."
        if (screens !== "on") return "Nothing to skip: screens are off."
        if (clipsPaused) return "Nothing to skip: clips are paused."
        if (!engineState.canChange("clips")) return "Nothing to skip: the Lian Li daemon isn't answering."
        return ""
    }
    function skipClip() {
        const why = skipRefusal()
        if (why) {
            engineState.showFlash("skip-refused", why)
            return false
        }
        engineState.beginOp("clips", "next")
        launch(["--detach", "clips", "next", "--nowait"], (c, o, e) => {
            if (c === 75) {
                engineState.setOp("clips", null)
                engineState.showFlash("skip-busy", "A theme change is running; skip again when it finishes.")
            } else {
                engineState.launched("clips", c, o, e)
            }
        })
        return true
    }
    // Lock-free and instant in the engine, so run directly.
    function setClipsPaused(paused) {
        clipsWant = { paused: !!paused, at: Date.now() / 1000 }
        clipsWantClear.restart()
        launch(["clips", paused ? "pause" : "resume"], (c, o, e) => {
            if (c !== 0) {
                console.warn("[lumenaire] clips " + (paused ? "pause" : "resume") + " exit " + c + ": " + String(e).slice(0, 2000))
                clipsWant = null
            }
            engineState.refreshStatus()
        })
    }
    // Hardware detection (may probe the SMBus, so only ever on request).
    function detect() {
        if (!engineState.canChange("detect")) return false
        engineState.beginOp("detect", true)
        launch(["--detach", "detect"], (c, o, e) => engineState.launched("detect", c, o, e))
        return true
    }
    function copyCommand(text) { if (text) Quickshell.execDetached(["wl-copy", String(text)]) }
    function copyPreviewCheckCommand() { copyCommand(previewCheckCommand) }
    function copyInstallCommand() {
        const c = engineState.installCommand
        if (c) Quickshell.execDetached(["wl-copy", c])
    }
    function retryLast() {
        const r = engineState.retryTarget()
        if (!r) return false
        if (r.kind === "detect") return detect()
        if (r.kind === "theme") return pick(r.desired)
        if (r.kind === "lights" || r.kind === "screens") return power(r.kind, !!r.desired)
        if (r.kind === "schedule") return setSchedule(!!r.desired)
        if (r.kind === "clips") return skipClip()
        return false
    }
    function refresh() {
        engineState.refreshStatus()
        engineState.refreshThemes()
        daemonLink.requestConfig()
        daemonLink.poke()
        sensors.refreshSources()
    }
    function buildPreviews(force) {
        if (previewsBuilding) return false
        previewsLaunchedAt = Date.now() / 1000
        engineState.now = previewsLaunchedAt
        if (!pclBin) return false
        const argv = [systemdRun, "--user", "--quiet", "--collect", "--unit=pc-lights-previews", "--", pclBin, "previews"]
        if (force) argv.push("--force")
        launchArgv(argv, (c, o, e) => {
            // "Unit pc-lights-previews.service already exists": a build is running.
            if (c !== 0 && !/already exists/.test(e)) console.warn("[lumenaire] previews launch exit " + c + ": " + String(e).slice(0, 2000))
            engineState.refreshStatus()
        })
        return true
    }
    function panelOpened() {
        panelOpenCount += 1
        if (panelOpenCount !== 1) return
        engineState.now = Date.now() / 1000
        daemonLink.requestConfig()
        engineState.refreshStatus()
        // Re-read the themes first: an edit inside a theme folder (colours,
        // media) raises no event on the non-recursive watch, and
        // maybeBuildPreviews needs fresh preview_stale flags.
        previewsCheck = true
        engineState.refreshThemes()
        // The Wallpaper row: what the wallpaper on the desktop has now.
        if (desktopStatus) desktopSoon.restart()
    }
    property bool previewsCheck: false
    function panelClosed() { panelOpenCount = Math.max(0, panelOpenCount - 1) }
    function ackFailure() { engineState.ack() }
    function dismissNotice() { engineState.dismissNotice() }
    function showLog() {
        Quickshell.execDetached(["xdg-terminal-exec", "journalctl", "--user", "-t", "pc-lights", "-n", "200", "-f"])
    }
    function themeState(name) { return engineState.themeState(name) }
    function canChange(kind) { return engineState.canChange(kind) }
    function displayName(name) { return engineState.displayName(name) }

    // ---- theme editor (plan §2.4; contract v1.2) ----------------------------
    // One draft at a time. Edits land in `editorDraft` at once (optimistic),
    // go out as one `theme set --patch-json` after 250 ms of quiet, and the
    // engine's editor view (`editor`) is the authority once it answers. The
    // live preview follows 1 s after the last edit; the engine queues its own
    // worker unit, so nothing here waits on the lights.
    readonly property bool editorAvailable: !!status && (Number(status.v_minor) >= 2 || Array.isArray(status.drafts))
    property var editor: null
    property var editorDraft: null
    property string editorState: "closed"     // closed | opening | idle | syncing | saving | failed
    property string editorError: ""
    property string editorErrorCode: ""       // the engine's code: not-v3, no-profile, stale-rev, exists, ...
    property string editorName: ""            // the draft being edited
    readonly property bool editorOpen: editorState !== "closed"
    readonly property bool editPending: pendingOps.length > 0 || inflightOps.length > 0 || draftBusy || draftQueue.length > 0
    property var pendingOps: []
    property var inflightOps: []
    readonly property var drafts: status && Array.isArray(status.drafts) ? status.drafts : []

    // $CACHE/preview.json, read on change (no process).
    property var preview: null
    property bool previewEnabled: true
    property real previewCountdown: -1
    property double previewDueAt: 0
    property bool previewWanted: false
    property bool previewSent: false          // --idle goes with the first request only
    readonly property var previewStates: ["queued", "applying", "live", "blocked"]
    readonly property bool previewLive: !!preview && previewStates.indexOf(String(preview.state)) >= 0
    readonly property real previewIdleLeft: {
        const p = preview
        if (!previewLive || !p || !isFinite(Number(p.idle_ends))) return -1
        const left = Math.max(0, Number(p.idle_ends) - engineState.now)
        return left <= 60 ? left : -1
    }
    // Live preview is off until a one-time hardware check: the engine
    // refuses a preview with code "unmeasured" until the check has written
    // $STATE_DIR/preview-method (or the profile's preview.method). Editing and
    // saving work without it; the method file appearing turns it back on.
    property bool previewRefusedUnmeasured: false
    property string previewCheckFromEngine: ""
    property string previewMethod: ""
    readonly property bool previewUnmeasured: previewRefusedUnmeasured && previewMethod === ""
    readonly property string previewCheckCommand: previewCheckFromEngine || "lumenaire theme preview --measure"

    // "" when the theme can be edited, else why not: "engine" (too old),
    // "no-profile", "v2"; "auto" is a warning (saving stops auto-refresh),
    // not a block. An empty name asks about new themes.
    function canEdit(name) {
        if (!editorAvailable) return "engine"
        if (!Format.profileUsable(profile)) return "no-profile"
        const t = name ? themeByName[name] : null
        if (t && t.editable === false) return String(t.edit_block || "v2")
        if (t && t.auto) return "auto"
        return ""
    }
    // Pure (LedColor.js mirrors the engine's jq): the live hint while a
    // colour is dragged; the engine's view is the authority after each sync.
    function ledShows(hex, cls) { return LedColor.shows(hex, cls, editor ? editor.calibration : null) }
    function ledHints(hex, cls) { return LedColor.hints(hex, cls, editor ? editor.calibration : null) }

    function editTheme(name) {
        name = String(name || "")
        if (!name) return false
        openEditor(name, ["theme", "edit", name, "--json"])
        return true
    }
    function newTheme(name, fromName, palette) {
        name = String(name || "")
        if (!name) return false
        const args = ["theme", "new", name]
        if (fromName) args.push("--from", String(fromName))
        const pal = palette && typeof palette === "object" ? Object.keys(palette).filter(k => palette[k]).map(k => k + "=" + palette[k]) : []
        if (pal.length) args.push("--palette", pal.join(","))
        args.push("--json")
        openEditor(name, args)
        return true
    }
    function duplicateTheme(fromName, newName) { return newTheme(newName, fromName, null) }
    function openEditor(name, args) {
        resetEditor()
        editorName = name
        editorState = "opening"
        runEditor(args, (c, o, e) => {
            if (editorName !== name) return
            const r = reply(o)
            if (c === 0 && r && r.theme) { acceptView(r); editorState = "idle"; return }
            failEditor(c, r, e)
        })
    }
    function editSet(path, value) { editPatch([Format.setOp(String(path), value === undefined ? null : value)]) }
    function editReset(path) { editPatch([{ op: "remove", path: String(path) }]) }
    function editPatch(ops) {
        if (!editorOpen || !editorName || !Array.isArray(ops) || ops.length === 0) return false
        let q = pendingOps
        for (const op of ops) q = Format.queueOp(q, op)
        pendingOps = q
        editorDraft = Format.applyOps(editorDraft || {}, ops)
        editFlush.restart()
        armPreview()
        return true
    }
    function setPreviewEnabled(on) {
        previewEnabled = !!on
        if (!previewEnabled) {
            previewDebounce.stop(); previewCountdown = -1; previewWanted = false
            if (previewLive) endPreview("reverted")
        } else if (editorOpen) {
            previewNow()
        }
    }
    function previewNow() {
        if (!editorOpen || !previewEnabled) return false
        previewDebounce.stop()
        previewCountdown = -1
        previewWanted = true
        sendPreview()
        return true
    }
    function keepPreviewing() { runEditor(["theme", "preview", "--keepalive", "--edited"], null) }
    function endPreview(reason) {
        previewDebounce.stop(); previewCountdown = -1; previewWanted = false
        runEditor(["theme", "preview", "--end", "--reason", String(reason || "closed"), "--json"], null)
    }
    // opts: {apply: true|false|null (engine default), asName, force}
    property var saveRetry: null
    function saveTheme(opts) {
        const o = opts || {}
        if (!editorOpen || !editorName) return false
        if (editPending) { saveAfterFlush = o; flushEdits(); return true }
        const name = editorName
        const args = ["theme", "save", name]
        if (o.asName && o.asName !== name) args.push("--as", String(o.asName))
        if (o.apply === true) args.push("--apply")
        else if (o.apply === false) args.push("--no-apply")
        if (o.force) args.push("--force")
        args.push("--json")
        editorState = "saving"
        editorError = ""; editorErrorCode = ""
        runEditor(args, (c, out, e) => {
            if (editorName !== name) return
            const r = reply(out)
            if (c === 0) {
                const saved = o.asName || name
                engineState.showFlash("saved", "Saved " + Format.themeName(saved) + "."
                    + (r && r.applying ? " Applying it to the case…" : ""))
                resetEditor()
                engineState.refreshThemes()
                engineState.refreshStatus()
                return
            }
            if (c === 75) {
                // An apply holds the lock: save again once it finishes.
                saveRetry = o
                editorState = "saving"
                editorError = "Waiting for the running change to finish, then saving…"
                return
            }
            if (c === 4) {
                editorState = "idle"
                editorErrorCode = "conflict"
                editorError = Format.themeName(name) + " was changed on disk since you started editing."
                editor = Object.assign({}, editor, { conflict: true })
                return
            }
            if (c === 2 && r && r.code === "media-pending") {
                // A picture or video is still being prepared for this draft.
                editorState = "idle"
                editorErrorCode = "media-pending"
                editorError = Format.mediaEditError("media-pending").text
                jobsSoon.restart()
                return
            }
            if (c === 2 && r && Array.isArray(r.problems)) {
                editorState = "idle"
                editorErrorCode = String(r.code || "invalid")
                editorError = r.error ? String(r.error) : "Fix the problems below to save."
                editor = Object.assign({}, editor, { problems: r.problems })
                return
            }
            failEditor(c, r, e)
            editorState = "idle"
        })
        return true
    }
    property var saveAfterFlush: null
    function revertEdits() {
        if (!editorOpen || !editorName) return false
        const name = editorName
        const mode = editor ? editor.mode : "edit"
        pendingOps = []; inflightOps = []; editFlush.stop()
        if (mode !== "edit") {
            // Nothing saved to go back to: start the draft again.
            runEditor(["theme", "discard", name], () => openEditor(name, ["theme", "new", name].concat(editor && editor.from ? ["--from", editor.from] : []).concat(["--json"])))
            return true
        }
        openEditor(name, ["theme", "edit", name, "--fresh", "--json"])
        if (previewLive) endPreview("reverted")
        return true
    }
    // keep: leave the draft on disk (Keep as draft); else discard it. The
    // preview ends either way.
    function closeEditor(keep) {
        const name = editorName
        if (editPending && keep) flushEdits()
        if (previewLive || previewSent) endPreview("closed")
        if (name && !keep) runEditor(["theme", "discard", name], null)
        resetEditor()
        statusSoon.restart()
    }
    function deleteTheme(name) {
        name = String(name || "")
        if (!name) return false
        runEditor(["theme", "delete", name, "--json"], (c, o, e) => {
            const r = reply(o)
            if (c === 0) { engineState.showFlash("deleted", Format.themeName(name) + " moved to the theme trash."); if (editorName === name) resetEditor() }
            else engineState.showFlash("delete-failed", deleteRefusal(name, c, r, e))
            engineState.refreshThemes()
            engineState.refreshStatus()
        })
        return true
    }
    function renameTheme(oldName, newName) {
        oldName = String(oldName || ""); newName = String(newName || "")
        if (!oldName || !newName || oldName === newName) return false
        runEditor(["theme", "rename", oldName, newName, "--json"], (c, o, e) => {
            const r = reply(o)
            if (c === 0) {
                engineState.showFlash("renamed", Format.themeName(oldName) + " is now " + Format.themeName(newName) + ".")
                if (editorName === oldName) editTheme(newName)
            } else {
                engineState.showFlash("rename-failed", "Renaming " + Format.themeName(oldName) + " failed: "
                    + (c === 75 ? "a change is running; try again when it finishes" : clean(r && r.error ? r.error : e) || "exit " + c) + ".")
            }
            engineState.refreshThemes()
            engineState.refreshStatus()
        })
        return true
    }


    // ---- screens (plan §5.4; contract v1.3) ---------------------------------
    // The screen editor: the draft's screens as the engine sees them (`theme
    // screens --json`), the picker's lists (`media list`), frame grabs to
    // crop from (`media frame`), and the jobs that prepare media (`media
    // prepare` starts a detached, capped unit in the engine; this only reads
    // their records). `screens` already is the screens' power state, so the
    // view is `screensView`. Draft changes go out one at a time after any
    // colour edits (`theme media … --base-rev --with-screens`), and each
    // reply brings the editor view and the screens view back together.
    readonly property bool screensAvailable: !!status && Number(status.v_minor) >= 3
    readonly property bool screensEditable: screensAvailable && !!editor && !!editor.screens && editor.screens.editable === true
    property var screensView: null
    property string screensState: "closed"       // closed | loading | idle | failed
    property string screensError: ""
    property string screenRole: ""
    property var mediaList: null
    property string mediaListState: "idle"       // idle | loading | failed
    property string mediaListError: ""
    property var mediaQuery: ({ source: "", role: "", query: "", offset: 0 })
    property var mediaJobs: []                   // the open draft's job records, newest first
    property var frame: null                     // media frame --json, plus `for`: the file it came from
    property string frameState: "idle"           // idle | loading | failed
    property var mediaNote: null                 // {role, text, level}: the engine's word on the last change
    property var jobThumbs: ({})                 // job id -> the chosen file's thumbnail, for its row
    property var dismissedJobs: ({})
    property var cancelledJobs: ({})             // Cancel said so; the engine's record follows
    property double screensOpenedAt: 0
    property var draftQueue: []                  // media changes waiting for the draft
    property bool draftBusy: false
    property bool screensBusy: false
    property bool screensAgain: false
    property bool jobsBusy: false
    property int listSeq: 0
    property int frameSeq: 0
    property var frameWant: null
    property var appliedSeen: ({})

    // The newest job of the open draft for a screen that still has something
    // to say: running, or failed since the editor opened (a newer choice,
    // Cancel or Try again make it go away).
    function jobFor(role) {
        role = String(role || "")
        for (const j of (mediaJobs || [])) {
            if (!j || j.role !== role || (j.draft && j.draft !== editorName)) continue
            const st = String(j.state || "")
            const code = Format.jobErrorCode(j)
            if (dismissedJobs[j.id] || cancelledJobs[j.id] || st === "done" || st === "cancelled") return null
            if (st === "failed" && (code === "superseded" || code === "no-draft")) return null
            if (st === "failed" && Number(j.ended || j.updated || 0) > 0 && Number(j.ended || j.updated) < screensOpenedAt - 5) return null
            return j
        }
        // Before the job list is read, the view's own word on it.
        const v = screensView && Array.isArray(screensView.screens) ? screensView.screens.find(x => x && x.role === role) : null
        return v && v.pending && Format.jobRunning(v.pending) && !cancelledJobs[String(v.pending.job || "")]
            ? Object.assign({ id: String(v.pending.job || ""), role: role, draft: editorName }, v.pending) : null
    }
    // What the live preview says about a screen (preview.json screens.roles).
    function screenPreview(role) {
        const p = preview
        return previewLive && p && p.screens && p.screens.roles ? p.screens.roles[String(role)] || null : null
    }
    function jobThumb(id) { return jobThumbs[String(id)] || "" }

    function resetScreens() {
        screensSoon.stop(); listDebounce.stop(); frameDebounce.stop(); jobsSoon.stop()
        screensView = null; screensState = "closed"; screensError = ""; screenRole = ""
        mediaList = null; mediaListState = "idle"; mediaListError = ""; mediaQuery = { source: "", role: "", query: "", offset: 0 }
        mediaJobs = []; frame = null; frameState = "idle"; mediaNote = null; jobThumbs = ({}); dismissedJobs = ({}); cancelledJobs = ({})
        draftQueue = []; draftBusy = false; screensAgain = false; frameWant = null; appliedSeen = ({})
        listSeq += 1; frameSeq += 1
        screensOpenedAt = Date.now() / 1000
    }
    function loadScreens() {
        if (!editorOpen || !editorName || !screensAvailable) return false
        if (screensBusy) { screensAgain = true; return true }
        const name = editorName
        if (!screensView) screensState = "loading"
        screensBusy = true
        runEditor(["theme", "screens", name, "--json"], (c, o, e) => {
            screensBusy = false
            if (editorName !== name) return
            const r = reply(o)
            if (c === 0 && r && Array.isArray(r.screens)) { screensView = r; screensState = "idle"; screensError = "" }
            else {
                screensState = screensView ? "idle" : "failed"
                screensError = r && (r.code === "no-profile" || r.code === "not-v3") ? Format.mediaEditError(r.code).text : "Couldn't read the screens."
                if (c !== 5) console.warn("[lumenaire] theme screens exit " + c + ": " + String(e).slice(0, 2000))
            }
            if (screensAgain) { screensAgain = false; screensSoon.restart() }
        })
        return true
    }
    function openScreen(role) {
        screenRole = String(role || "")
        mediaNote = null
        if (!screensView) loadScreens()
        readJobs()
        return true
    }
    function closeScreen() {
        screenRole = ""
        mediaList = null; mediaListState = "idle"; mediaListError = ""; listSeq += 1
        frame = null; frameState = "idle"; frameWant = null; frameSeq += 1
        mediaNote = null
    }

    // ---- the picker
    // source: "theme" (the draft's own media), "library" or "files".
    function listMedia(source, role, query, offset) {
        const was = mediaQuery
        mediaQuery = { source: ["theme", "library", "files"].indexOf(String(source)) >= 0 ? String(source) : "theme",
                       role: String(role || screenRole), query: String(query || ""), offset: Math.max(0, Number(offset) || 0) }
        // Another tab or screen: nothing of the old list stays on show.
        if (was.source !== mediaQuery.source || was.role !== mediaQuery.role) { mediaList = null; listSeq += 1 }
        if (mediaQuery.offset === 0) { mediaListState = "loading"; listDebounce.restart() }
        else runList(true)
        return true
    }
    function moreMedia() {
        if (!mediaList || mediaListState === "loading") return false
        const have = Array.isArray(mediaList.items) ? mediaList.items.length : 0
        if (have >= Number(mediaList.total)) return false
        mediaQuery = Object.assign({}, mediaQuery, { offset: have })
        runList(true)
        return true
    }
    // limit: the index watch re-reads what is on screen in one go.
    function runList(append, limit) {
        const q = mediaQuery
        if (!editorName || !q.role) return
        const args = ["media", "list", "--for", q.role, "--source", q.source === "theme" ? "theme:" + editorName : q.source, "--draft", editorName]
        if (q.query.trim() !== "") args.push("--query", q.query.trim())
        if (append && q.offset > 0) args.push("--offset", String(q.offset))
        args.push("--limit", String(limit || 60), "--json")
        const seq = ++listSeq
        mediaListState = "loading"
        runEditor(args, (c, o, e) => {
            if (seq !== listSeq) return
            const r = reply(o)
            if (c === 0 && r && Array.isArray(r.items)) {
                if (append && q.offset > 0 && mediaList && Array.isArray(mediaList.items)) r.items = mediaList.items.concat(r.items)
                mediaList = r
                mediaListState = "idle"
                mediaListError = ""
                return
            }
            mediaListState = "failed"
            mediaListError = r && r.code === "missing-tool" ? "Screen editing needs ffmpeg and ImageMagick."
                : r && r.code === "no-profile" ? "Screen editing needs a hardware profile."
                : "This folder can't be read"
            console.warn("[lumenaire] media list exit " + c + ": " + String(e).slice(0, 2000))
        })
    }
    // A frame grab to crop on; the latest request wins. time < 0: the
    // engine's own pick (a third of the way in).
    function frameAt(path, t) {
        frameWant = { path: String(path || ""), time: Number(t) }
        frameDebounce.restart()
        return true
    }
    function runFrame() {
        const w = frameWant
        if (!w || !w.path) return
        const args = ["media", "frame", w.path]
        if (isFinite(w.time) && w.time >= 0) args.push("--time", String(Math.round(w.time * 10) / 10))
        args.push("--max", "960", "--json")
        const seq = ++frameSeq
        frameState = "loading"
        runEditor(args, (c, o, e) => {
            if (seq !== frameSeq) return
            const r = reply(o)
            if (c === 0 && r && r.path) { frame = Object.assign({}, r, { for: w.path }); frameState = "idle"; return }
            frameState = "failed"
            console.warn("[lumenaire] media frame exit " + c + ": " + String(e).slice(0, 2000))
        })
    }

    // ---- jobs
    // opts: {then: set | clip-add, at, crop: [x, y, w, h], time, thumb}
    function prepareMedia(role, path, opts) {
        const o = opts || {}
        role = String(role || ""); path = String(path || "")
        if (!editorOpen || !editorName || !role || !path) return false
        const then = o.then === "clip-add" ? "clip-add" : "set"
        const args = ["media", "prepare", path, "--for", role, "--draft", editorName, "--then", then]
        if (then === "clip-add" && o.at !== null && o.at !== undefined && isFinite(Number(o.at))) args.push("--at", String(Math.round(Number(o.at))))
        if (Array.isArray(o.crop) && o.crop.length === 4) args.push("--crop", o.crop.map(n => Math.max(0, Math.round(Number(n)))).join(","))
        if (isFinite(Number(o.time)) && Number(o.time) > 0) args.push("--time", String(Math.round(Number(o.time) * 10) / 10))
        args.push("--json")
        const name = editorName
        mediaNote = null
        runEditor(args, (c, out, e) => {
            if (editorName !== name) return
            const r = reply(out)
            if (c === 0 && r && r.job && r.job.id) {
                if (o.thumb) { const m = Object.assign({}, jobThumbs); m[r.job.id] = String(o.thumb); jobThumbs = m }
                noteJob(r.job)
                jobsSoon.restart()
                return
            }
            // Refused at once (it doesn't fit, it has no picture, the disk is
            // full, …): a failed job the page can speak for and retry.
            const t = Date.now() / 1000
            noteJob({ v: 1, id: "local-" + Math.round(t * 1000), draft: name, role: role, state: "failed", then: then, at: o.at === undefined ? null : o.at,
                      source: { path: path }, recipe: { crop: Array.isArray(o.crop) ? o.crop : null, time: o.time || null },
                      error: { code: r && r.code ? String(r.code) : c === 127 || c === 126 ? "missing-tool" : "broken", text: r && r.error ? String(r.error) : clean(e) },
                      started: t, updated: t, ended: t })
            console.warn("[lumenaire] media prepare exit " + c + ": " + String(e).slice(0, 2000))
        })
        return true
    }
    function cancelMedia(id) {
        id = String(id || "")
        if (!id) return false
        const c = Object.assign({}, cancelledJobs); c[id] = true; cancelledJobs = c
        if (id.indexOf("local-") === 0 || !editorName) return true
        runEditor(["media", "cancel", id, "--json"], (c, o, e) => {
            if (c !== 0) console.warn("[lumenaire] media cancel exit " + c + ": " + String(e).slice(0, 2000))
            jobsSoon.restart()
            screensSoon.restart()
        })
        return true
    }
    // Try a failed job again: the same file, framing and destination.
    function retryMedia(id) {
        const j = (mediaJobs || []).find(x => x && x.id === String(id))
        if (!j || !j.source || !j.source.path) return false
        const d = Object.assign({}, dismissedJobs); d[j.id] = true; dismissedJobs = d
        return prepareMedia(j.role, j.source.path, { then: j.then, at: j.at, crop: j.recipe ? j.recipe.crop : null,
                                                     time: j.recipe ? j.recipe.time : null, thumb: jobThumbs[j.id] || "" })
    }
    function noteJob(job) {
        if (!job || !job.id) return
        const list = (mediaJobs || []).filter(j => j && j.id !== job.id).concat([job])
        list.sort((a, b) => Number(b.started || 0) - Number(a.started || 0))
        mediaJobs = list
    }
    function readJobs() {
        if (!editorOpen || !editorName || !screensAvailable) return
        if (jobsBusy) { jobsSoon.restart(); return }
        const name = editorName
        jobsBusy = true
        runEditor(["media", "jobs", "--draft", name, "--json"], (c, o, e) => {
            jobsBusy = false
            if (editorName !== name) return
            const r = reply(o)
            const list = Array.isArray(r) ? r : r && Array.isArray(r.jobs) ? r.jobs : null
            if (c !== 0 || !list) { if (c !== 0) console.warn("[lumenaire] media jobs exit " + c + ": " + String(e).slice(0, 2000)); return }
            // Keep the refusals made here; the engine's records win for the rest.
            const local = (mediaJobs || []).filter(j => j && String(j.id).indexOf("local-") === 0)
            const merged = list.filter(j => j && j.id).concat(local)
            merged.sort((a, b) => Number(b.started || 0) - Number(a.started || 0))
            const was = {}
            for (const j of (mediaJobs || [])) if (j && j.id) was[j.id] = String(j.state || "")
            mediaJobs = merged
            // A job put its result in the draft: read the draft again, then
            // the screens, then show it on the case.
            let applied = false, ended = false
            const seen = Object.assign({}, appliedSeen)
            for (const j of merged) {
                if (j.applied && !seen[j.id]) { seen[j.id] = true; if (editor && Number(j.applied.rev) > Number(editor.rev)) applied = true }
                if (was[j.id] && Format.jobRunning({ state: was[j.id] }) && !Format.jobRunning(j)) ended = true
                // "Uses the first 1:56.": said once, for a job of this session.
                if (j.warnings && j.warnings.length && j.applied && !appliedSeen[j.id] && Number(j.ended || 0) >= screensOpenedAt - 5)
                    mediaNote = { role: j.role, text: String(j.warnings[0].text || ""), level: "" }
            }
            appliedSeen = seen
            if (applied) reloadDraft()
            else if (ended) screensSoon.restart()
        })
    }
    function reloadDraft() {
        const name = editorName
        if (!name || editPending) { screensSoon.restart(); return }
        runEditor(["theme", "show", name, "--json"], (c, o, e) => {
            if (editorName !== name) return
            const v = reply(o)
            if (c === 0 && v && v.theme) { acceptView(v); armPreview() }
            loadScreens()
        })
    }

    // ---- draft changes, one at a time
    // role, then the verb's words: set <src> [--all-fans] | clips add <src>
    // [--at N] | clips remove <i> | clips move <from> <to> | rotate <s>|off
    // --shuffle on|off | mode template|media.
    function setScreenMedia(role, src, allFans) {
        const words = ["set", String(src || "none")]
        if (allFans) words.push("--all-fans")
        return mediaEdit(role, words)
    }
    function clipAdd(role, src, at) {
        const words = ["clips", "add", String(src || "")]
        if (at !== null && at !== undefined && isFinite(Number(at))) words.push("--at", String(Math.round(Number(at))))
        return mediaEdit(role, words)
    }
    function clipRemove(role, i) { return mediaEdit(role, ["clips", "remove", String(Math.round(Number(i) || 0))]) }
    function clipMove(role, from, to) { return mediaEdit(role, ["clips", "move", String(Math.round(Number(from) || 0)), String(Math.round(Number(to) || 0))]) }
    function setRotation(role, seconds, shuffle) {
        const n = Math.round(Number(seconds) || 0)
        return mediaEdit(role, ["rotate", n > 0 ? String(n) : "off", "--shuffle", shuffle ? "on" : "off"])
    }
    function setScreenMode(role, mode) { return mediaEdit(role, ["mode", mode === "media" ? "media" : "template"]) }
    // The engine resolves the role pointer against the draft as it stands
    // (a fan dealt from a shared list gets its own entry first).
    function setScreenBrightness(role, v) {
        const n = v === null || v === undefined ? null : Math.max(0, Math.min(100, Math.round(Number(v))))
        return editSet("/screens/@" + String(role) + "/brightness", n)
    }
    function mediaEdit(role, words) {
        if (!editorOpen || !editorName || !role) return false
        draftQueue = draftQueue.concat([{ role: String(role), words: words }])
        mediaNote = null
        if (!flushBusy && !draftBusy && pendingOps.length === 0) pumpDraft()
        else if (pendingOps.length && !flushBusy) { editFlush.stop(); flushEdits() }
        return true
    }
    function pumpDraft() {
        if (draftBusy || flushBusy || draftQueue.length === 0 || !editorName) return
        if (pendingOps.length) { flushEdits(); return }
        const op = draftQueue[0]
        draftQueue = draftQueue.slice(1)
        draftBusy = true
        const name = editorName
        const args = ["theme", "media", op.words[0], name, op.role].concat(op.words.slice(1))
        if (editor && isFinite(Number(editor.rev))) args.push("--base-rev", String(editor.rev))
        args.push("--with-screens", "--json")
        if (editorState === "idle") editorState = "syncing"
        runEditor(args, (c, o, e) => {
            draftBusy = false
            if (editorName !== name) return
            const r = reply(o)
            if (c === 0 && r && r.theme) {
                acceptView(r)
                const notes = Array.isArray(r.notes) ? r.notes.filter(n => n) : []
                if (notes.length) mediaNote = { role: op.role, text: String(notes[0].text || notes[0]), level: "" }
                if (editorState === "syncing") editorState = "idle"
                armPreview()
            } else if (c === 2 && r && r.code === "stale-rev") {
                // Another panel wrote the draft: reload it, then do this again.
                draftQueue = [op].concat(draftQueue)
                draftBusy = true
                runEditor(["theme", "show", name, "--json"], (c2, o2, e2) => {
                    draftBusy = false
                    const v = reply(o2)
                    if (editorName === name && c2 === 0 && v && v.theme) acceptView(v)
                    pumpDraft()
                })
                return
            } else {
                if (editorState === "syncing") editorState = "idle"
                const w = Format.mediaEditError(r && r.code ? r.code : "")
                mediaNote = { role: op.role, text: w.text, level: w.level, tip: r && r.error ? clean(r.error) : clean(e) }
                console.warn("[lumenaire] theme media exit " + c + ": " + String(e).slice(0, 2000))
                screensSoon.restart()
            }
            if (pendingOps.length) editFlush.restart()
            else if (draftQueue.length) pumpDraft()
            else afterFlush()
        })
    }
    Timer { id: screensSoon; interval: 300; onTriggered: root.loadScreens() }
    Timer { id: listDebounce; interval: 200; onTriggered: root.runList(false) }
    Timer { id: frameDebounce; interval: 150; onTriggered: root.runFrame() }
    Timer { id: jobsSoon; interval: 250; onTriggered: root.readJobs() }
    // The indexer read more files: the picker's page and pending thumbnails.
    Timer {
        id: indexSoon
        interval: 1000
        onTriggered: {
            if (root.screenRole && root.mediaQuery.role && root.mediaList)
                root.runList(false, Math.max(60, Array.isArray(root.mediaList.items) ? root.mediaList.items.length : 60))
            const v = root.screensView
            if (v && Array.isArray(v.screens) && v.screens.some(x => x && x.media && x.media.thumb_state !== "ready")) root.loadScreens()
        }
    }

    // -- editor internals
    function reply(out) {
        const t = String(out || "").trim()
        if (!t) return null
        try { return JSON.parse(t.split("\n").pop()) } catch (e) { try { return JSON.parse(t) } catch (e2) { return null } }
    }
    function clean(s) { return String(s || "").trim().replace(/[.\s]+$/, "") }
    function deleteRefusal(name, c, r, e) {
        if (c === 75) return "A change is running; delete " + Format.themeName(name) + " when it finishes."
        if (r && r.code === "in-use") return Format.themeName(name) + " is in use (" + clean(r.error) + "). Pick another theme first."
        return "Deleting " + Format.themeName(name) + " failed: " + (clean(r && r.error ? r.error : e) || "exit " + c) + "."
    }
    function resetEditor() {
        editFlush.stop(); previewDebounce.stop(); previewTick.stop()
        editor = null; editorDraft = null; editorName = ""; editorState = "closed"
        editorError = ""; editorErrorCode = ""
        pendingOps = []; inflightOps = []; saveAfterFlush = null; saveRetry = null
        previewCountdown = -1; previewWanted = false; previewSent = false
        resetScreens()
    }
    function acceptView(v) {
        const first = !editor
        editor = v
        editorDraft = Format.applyOps(v.theme || {}, pendingOps)
        if (v.screens_view && typeof v.screens_view === "object" && Array.isArray(v.screens_view.screens)) {
            screensView = v.screens_view
            screensState = "idle"
        } else if (first && screensEditable) {
            loadScreens()
            readJobs()
        }
    }
    function failEditor(c, r, e) {
        const code = r && r.code ? String(r.code) : ""
        editorErrorCode = code
        if (c === 5) editorError = Format.editBlockText(code === "not-v3" ? "v2" : code === "no-profile" ? "no-profile" : "v2")
        else if (c === 127 || c === 126) editorError = "The Lumenaire engine isn't installed."
        else if (c === 2 && code === "exists") editorError = "That name is taken."
        else if (c === 1 && /usage:|unknown/.test(String(e))) { editorError = Format.editBlockText("engine"); editorErrorCode = "engine" }
        else editorError = (r && r.error ? clean(r.error) : clean(e) || "the engine exited " + c) + "."
        if (!editor) editorState = "failed"
        console.warn("[lumenaire] editor exit " + c + ": " + String(e).slice(0, 2000))
    }
    function flushEdits() {
        // A media change is writing the draft: this follows when it's done.
        if (draftBusy) return
        if (flushBusy || pendingOps.length === 0 || !editorName) {
            if (!flushBusy && pendingOps.length === 0) afterFlush()
            return
        }
        const name = editorName
        const ops = pendingOps
        pendingOps = []
        inflightOps = ops
        flushBusy = true
        if (editorState === "idle") editorState = "syncing"
        const args = ["theme", "set", name, "--patch-json", JSON.stringify(ops)]
        if (editor && isFinite(Number(editor.rev))) args.push("--base-rev", String(editor.rev))
        if (ops.some(o => Format.isAliasPtr(o.path))) args.push("--with-screens")
        args.push("--json")
        runEditor(args, (c, o, e) => {
            flushBusy = false
            if (editorName !== name) return
            const r = reply(o)
            inflightOps = []
            if (c === 0 && r && r.theme) {
                acceptView(r)
                if (editorState === "syncing") editorState = "idle"
            } else if (c === 2 && r && r.code === "stale-rev") {
                // Another panel wrote the draft: reload, then replay ours on top.
                pendingOps = ops.concat(pendingOps)
                runEditor(["theme", "show", name, "--json"], (c2, o2, e2) => {
                    const v = reply(o2)
                    if (c2 === 0 && v && v.theme) acceptView(v)
                    editFlush.restart()
                })
                return
            } else {
                failEditor(c, r, e)
                if (editorState === "syncing") editorState = "idle"
            }
            if (pendingOps.length) editFlush.restart()
            else afterFlush()
        })
    }
    property bool flushBusy: false
    function afterFlush() {
        if (draftQueue.length) { pumpDraft(); return }
        if (saveAfterFlush) { const o = saveAfterFlush; saveAfterFlush = null; saveTheme(o); return }
        if (previewWanted && previewCountdown < 0) sendPreview()
    }
    function armPreview() {
        if (!previewEnabled || previewUnmeasured || lights !== "on") return
        previewWanted = true
        previewDueAt = Date.now() / 1000 + 1
        previewCountdown = 1
        previewDebounce.restart()
        previewTick.restart()
    }
    function sendPreview() {
        if (!previewWanted || !editorOpen || !editorName) return
        if (editPending) return            // afterFlush sends it with the new rev
        if (!editor || lights !== "on" || previewUnmeasured) return
        if ((editor.problems || []).some(p => p && p.level !== "warn")) return
        previewWanted = false
        const args = ["theme", "preview", editorName, "--rev", String(editor.rev)]
        if (!previewSent) args.push("--idle", String(Math.round(settings.previewIdleMinutes * 60)))
        args.push("--json")
        previewSent = true
        runEditor(args, (c, o, e) => {
            if (c !== 0) {
                const r = reply(o)
                if (r && r.code === "lights-off") return
                if (r && r.code === "unmeasured") {
                    const m = String(r.error || "").match(/run (lumenaire .+?)\.?$/)
                    previewCheckFromEngine = m ? m[1] : ""
                    previewRefusedUnmeasured = true
                    previewSent = false
                    return
                }
                console.warn("[lumenaire] preview exit " + c + ": " + String(e).slice(0, 2000))
            }
            previewFile.reload()
        })
    }
    // Editor commands are short and lock-free: run them directly.
    function runEditor(args, done) {
        if (!pclBin) { if (done) done(127, "", "no engine"); return }
        launchArgv(engineState.cmd(args), done, true)
    }
    Timer { id: editFlush; interval: 250; onTriggered: root.flushEdits() }
    // A save that met a running apply (exit 75): look again every 2 s;
    // onSnapshot saves once nothing holds the lock.
    Timer { interval: 2000; repeat: true; running: root.saveRetry !== null; onTriggered: engineState.refreshStatus() }
    Timer {
        id: previewDebounce
        interval: 1000
        onTriggered: { root.previewCountdown = -1; previewTick.stop(); if (root.flushBusy || root.pendingOps.length) return; root.sendPreview() }
    }
    Timer {
        id: previewTick
        interval: 100
        repeat: true
        onTriggered: root.previewCountdown = Math.max(0, root.previewDueAt - Date.now() / 1000)
    }
    // Heartbeat: the engine's reaper ends a preview whose UI went quiet (90 s).
    Timer {
        interval: 30000
        repeat: true
        running: root.editorOpen && root.previewLive
        onTriggered: root.runEditor(["theme", "preview", "--keepalive"], null)
    }
    // The panel closed with a preview on the case: end it after a short
    // grace, unless it reopens (a popout switch closes and reopens it).
    Timer {
        id: panelCloseGrace
        interval: 3000
        onTriggered: if (root.panelOpenCount === 0 && root.previewLive) root.endPreview("panel-closed")
    }
    onPanelOpenCountChanged: {
        if (panelOpenCount === 0 && previewLive) panelCloseGrace.restart()
        else if (panelOpenCount > 0) panelCloseGrace.stop()
    }
    FileView {
        id: previewMethodFile
        path: root.configDir + "/preview-method"
        watchChanges: true
        printErrors: false
        onLoaded: {
            const m = String(text() || "").trim()
            root.previewMethod = /^(effect|rgbconfig)$/.test(m) ? m : ""
            // Measured since the last refusal: preview what's being edited.
            if (root.previewMethod && root.previewRefusedUnmeasured) { root.previewRefusedUnmeasured = false; if (root.editorOpen) root.previewNow() }
        }
        onLoadFailed: root.previewMethod = ""
        onFileChanged: reload()
    }
    FileView {
        id: previewFile
        path: root.cacheDir + "/preview.json"
        watchChanges: true
        printErrors: false
        onLoaded: {
            let p = null
            try { p = JSON.parse(text()) } catch (e) { p = null }
            root.preview = p && typeof p === "object" && !Array.isArray(p) ? p : null
        }
        onLoadFailed: root.preview = null
        onFileChanged: reload()
    }

    // ---- the desktop wallpaper (contract v1.4) ---------------------------------
    // The animated wallpaper (the Motion Wallpaper plugin) keeps settings for
    // each theme: animated or still, pause while the keyboard or mouse is in
    // use, when to resume, and freeze or show the still image meanwhile.
    // status --json `desktop` (the engine's cache of the desktop, rewritten in
    // $CACHE/desktop/state.json) says whether the desktop takes them and what
    // the theme it follows has (the one paired with the Omarchy theme, which
    // can be another than the case's at night); `desktop --json` is one
    // theme's view (does this wallpaper have an animated version, what the
    // theme keeps of its own, the defaults). Both are lock-free and run
    // directly. A change is one `desktop set`, one at a time: it shows at once
    // (laid over the views until its answer) and the view it prints is the
    // authority. An engine without `desktop` hides all of it.
    readonly property var desktopStatus: status && status.desktop && typeof status.desktop === "object" ? status.desktop : null
    // The theme whose settings the desktop follows now.
    readonly property string desktopHome: desktopStatus && desktopStatus.theme ? String(desktopStatus.theme) : activeTheme
    // The cache says so, or (before the engine's first sync, when it says
    // null) the view read when the panel opened.
    readonly property bool desktopAvailable: !!desktopStatus && (desktopStatus.available === true
        || (!!desktopHomeRead && desktopHomeRead.theme === desktopHome && desktopHomeRead.available === true))
    property string desktopTheme: ""             // the theme the wallpaper page shows ("" while it's closed)
    property string desktopState: "closed"       // closed | loading | idle | failed
    property string desktopError: ""             // one calm line: a read or a change that didn't go through
    property string desktopErrorTip: ""          // the engine's own words, for its tooltip
    property var desktopRead: null               // the last desktop --json of the page's theme
    property var desktopHomeRead: null           // … and of the theme the desktop follows
    property var desktopLocal: ({})              // theme -> {key: value} on its way to the engine
    property var desktopQueue: []
    property bool desktopBusy: false
    property int desktopRev: 0                   // answers to changes so far: an older read is dropped
    property string desktopSig: ""
    // The page's view and the main page's (the theme the desktop follows),
    // the changes on their way laid over them.
    readonly property var desktop: {
        const t = desktopTheme
        if (!t) return null
        const base = desktopRead && desktopRead.theme === t ? desktopRead : desktopHomeRead && desktopHomeRead.theme === t ? desktopHomeRead : null
        return Format.desktopWith(base, desktopLocal[t])
    }
    readonly property var desktopCurrent: {
        const st = desktopStatus
        if (!st) return null
        const t = desktopHome
        const base = desktopHomeRead && desktopHomeRead.theme === t ? desktopHomeRead : Format.desktopStub(st, t)
        return Format.desktopWith(base, desktopLocal[t])
    }

    // theme "" is the one the desktop follows.
    function loadDesktop(theme) {
        theme = String(theme || desktopHome || "")
        if (!theme || !desktopStatus) return false
        if (theme !== desktopTheme) { desktopRead = null; desktopError = ""; desktopErrorTip = "" }
        desktopTheme = theme
        desktopState = desktop ? "idle" : "loading"
        readDesktop(theme)
        return true
    }
    function closeDesktop() {
        desktopTheme = ""
        desktopRead = null
        desktopState = "closed"
        desktopError = ""; desktopErrorTip = ""
    }
    // key: animated | pause_while_active | resume_after_idle | while_active
    // (or the verbs animated | pause | resume | while); value: true, false or
    // "toggle", seconds 1-600, "freeze" or "still".
    function setDesktop(key, value, theme) {
        const k = Format.desktopKey(key)
        theme = String(theme || desktopTheme || desktopHome || "")
        if (!k || !theme || !pclBin) return false
        const was = theme === desktopTheme && desktop ? desktop : theme === desktopHome ? desktopCurrent : null
        const v = Format.desktopValue(k, value === "toggle" ? !(was && was.settings && was.settings[k] === true) : value)
        if (v === null) return false
        const loc = Object.assign({}, desktopLocal)
        loc[theme] = Object.assign({}, loc[theme] || {})
        loc[theme][k] = v
        desktopLocal = loc
        desktopError = ""; desktopErrorTip = ""
        desktopQueue = desktopQueue.concat([{ theme: theme, key: k, value: v }])
        pumpDesktop()
        return true
    }
    // "Use defaults": the theme drops its own settings (desktop reset), so it
    // follows the defaults again; shown at once, settled by the engine's view.
    function resetDesktop(theme) {
        theme = String(theme || desktopTheme || desktopHome || "")
        const v = theme === desktopTheme && desktop ? desktop : theme === desktopHome ? desktopCurrent : null
        if (!v || !v.defaults || !v.stored || !pclBin) return false
        const keys = Object.keys(v.stored).filter(k => Format.desktopKey(k) && v.defaults[k] !== undefined)
        if (!keys.length) return false
        const loc = Object.assign({}, desktopLocal)
        loc[theme] = Object.assign({}, loc[theme] || {})
        for (const k of keys) loc[theme][k] = v.defaults[k]
        desktopLocal = loc
        desktopError = ""; desktopErrorTip = ""
        desktopQueue = desktopQueue.concat([{ theme: theme, reset: true, keys: keys }])
        pumpDesktop()
        return true
    }
    function pumpDesktop() {
        if (desktopBusy || desktopQueue.length === 0) return
        const op = desktopQueue[0]
        desktopQueue = desktopQueue.slice(1)
        desktopBusy = true
        const args = op.reset ? ["desktop", "reset", "--theme", op.theme]
                              : ["desktop", "set", "--theme", op.theme, Format.desktopVerb(op.key), Format.desktopArg(op.value)]
        const opKeys = op.reset ? op.keys : [op.key]
        runEditor(args, (c, o, e) => {
            desktopBusy = false
            desktopRev += 1
            const r = reply(o)
            // Shown over the views until the last change of that key has its answer.
            const pending = k => desktopQueue.some(q => q.theme === op.theme && (q.reset ? q.keys.indexOf(k) >= 0 : q.key === k))
            if (opKeys.some(k => !pending(k))) {
                const loc = Object.assign({}, desktopLocal)
                const mine = Object.assign({}, loc[op.theme] || {})
                for (const k of opKeys) if (!pending(k)) delete mine[k]
                if (Object.keys(mine).length) loc[op.theme] = mine
                else delete loc[op.theme]
                desktopLocal = loc
            }
            if (c === 0 && r && r.settings && typeof r.settings === "object") acceptDesktop(r)
            else {
                desktopError = Format.desktopError(r && r.code ? r.code : "")
                desktopErrorTip = clean(r && r.error ? r.error : e)
                // From the main page's row: its switch goes back, and a notice says why.
                if (op.theme !== desktopTheme) engineState.showFlash("desktop-failed", "Couldn't change the wallpaper.")
                console.warn("[lumenaire] desktop set exit " + c + ": " + String(e).slice(0, 2000))
                readDesktop(op.theme)
            }
            statusSoon.restart()
            pumpDesktop()
        })
    }
    function readDesktop(theme) {
        const want = String(theme || "")
        const rev = desktopRev
        runEditor(want ? ["desktop", "--theme", want, "--json"] : ["desktop", "--json"], (c, o, e) => {
            const r = reply(o)
            if (c === 0 && r && typeof r === "object" && r.theme !== undefined) {
                // A change answered since this read began: its view is newer.
                if (rev === desktopRev) acceptDesktop(r)
                else if (desktopTheme === want && desktopState === "loading") readDesktop(want)
                return
            }
            if (want && want === desktopTheme && !desktop) {
                desktopState = "failed"
                desktopError = r && (r.code === "not-found" || r.code === "busy") ? Format.desktopError(r.code) : "Couldn't read the wallpaper settings."
                desktopErrorTip = clean(r && r.error ? r.error : e)
            }
            console.warn("[lumenaire] desktop exit " + c + ": " + String(e).slice(0, 2000))
        })
    }
    function acceptDesktop(r) {
        const t = String(r.theme || "")
        if (!t) return
        if (t === desktopTheme) { desktopRead = r; desktopState = "idle" }
        if (t === desktopHome) desktopHomeRead = r
    }
    // Read again what is on show: the page's theme, and the one the desktop
    // follows while a panel is open (the main page's row).
    function refreshDesktop() {
        if (!desktopStatus) return
        if (desktopTheme) readDesktop(desktopTheme)
        if (desktopHome && desktopHome !== desktopTheme && panelOpenCount > 0) readDesktop(desktopHome)
    }
    Timer { id: desktopSoon; interval: 300; onTriggered: root.refreshDesktop() }

    // ---- internals --------------------------------------------------------
    function optimistic(kind, fallback) {
        const op = engineState.ops[kind]
        if (op && ["launching", "queued", "applying"].indexOf(op.phase) >= 0) return op.desired ? "on" : "off"
        return fallback ? String(fallback) : ""
    }
    property var clipsWant: null
    Timer { id: clipsWantClear; interval: 5000; onTriggered: root.clipsWant = null }
    Connections {
        target: engineState
        function onSnapshot() {
            const s = engineState.status
            // A save that met a running apply (exit 75) goes again once it ends.
            if (root.saveRetry && s && !s.busy) { const o = root.saveRetry; root.saveRetry = null; root.saveTheme(o) }
            if (root.clipsWant && s && s.clips) {
                const paused = s.clips.state === "off"
                if (paused === root.clipsWant.paused) root.clipsWant = null
            }
            if (s && s.daemon_unit !== root.lastDaemonUnit) {
                if (s.daemon_unit === "active" && root.lastDaemonUnit !== "") daemonLink.poke()
                root.lastDaemonUnit = s.daemon_unit || ""
            }
            // A clip change (the timer's rotation, a skip) or a finished run
            // re-reads GetConfig, whose lcds[].path names what really plays.
            // A clip tick never claims a run, so runEnded alone misses it.
            const sig = s ? JSON.stringify((Array.isArray(s.rotation) ? s.rotation : []).map(r => [r.serial, r.index, r.clip, r.since]))
                            + "|" + (s.last_run ? String(s.last_run.unit) + "@" + String(s.last_run.ended) : "") : ""
            if (sig !== root.clipSig) {
                if (root.clipSig !== "") daemonLink.requestConfig()
                root.clipSig = sig
            }
            // Another theme for the desktop, another Omarchy theme, new
            // settings: the wallpaper views are read again.
            const d = s && s.desktop && typeof s.desktop === "object" ? s.desktop : null
            const dsig = d ? JSON.stringify([d.available, d.theme, d.settings, s.omarchy ? s.omarchy.current : null]) : ""
            if (dsig !== root.desktopSig) {
                if (root.desktopSig !== "" && dsig !== "") desktopSoon.restart()
                root.desktopSig = dsig
            }
            if (!watcher.running && !root.watcherMissing && !watcherRestart.running && root.started) watcher.running = true
        }
        function onRunEnded() {
            daemonLink.requestConfig()
            themesSoon.restart()
        }
        function onThemesRead() {
            if (!root.previewsCheck) return
            root.previewsCheck = false
            root.maybeBuildPreviews()
        }
    }
    property string lastDaemonUnit: ""
    property string clipSig: ""
    property double lastAutoPreviews: 0
    function maybeBuildPreviews() {
        const t = Date.now() / 1000
        if (previewsBuilding || t - lastAutoPreviews < 60) return
        if (!(themes || []).some(x => x && x.preview_stale)) return
        lastAutoPreviews = t
        buildPreviews(false)
    }

    // One short Process per action; it exits once the unit is queued.
    Component {
        id: launcherComp
        Process {
            id: lp
            property var done: null
            stdout: StdioCollector { id: lpOut; waitForEnd: true }
            stderr: StdioCollector { id: lpErr; waitForEnd: true }
            onExited: (code, st) => {
                const cb = lp.done, o = lpOut.text, e = lpErr.text
                lp.done = null
                lp.destroy()
                if (cb) cb(code, o, e)
            }
        }
    }
    function launch(args, done) { launchArgv(engineState.cmd(args), done) }
    // quiet: no status re-read afterwards (the editor's lock-free calls).
    function launchArgv(argv, done, quiet) {
        const p = launcherComp.createObject(root, { command: argv })
        if (!p) { console.warn("[lumenaire] could not create a launcher"); if (done) done(-1, "", "launcher unavailable"); return }
        p.done = done
        p.running = true
        if (!quiet) statusSoon.restart()
    }

    // ---- engine watcher ---------------------------------------------------
    readonly property var statusNames: ["scheme", "day-scheme", "lights", "screens", "clips", "schedule.json",
        "omarchy-map.json", "busy.json", "last-run.json", "clips.json", "ui-requested", "schedule-boundary",
        "omarchy-requested", "theme.name"]
    // Also change a theme's active/day/night/omarchy flags.
    readonly property var themeLinkedNames: ["scheme", "day-scheme", "schedule.json", "omarchy-map.json"]
    property bool watcherMissing: false
    function onWatch(line) {
        const path = String(line || "").trim()
        const cut = path.lastIndexOf("/")
        if (cut < 0) return
        const dir = path.slice(0, cut).replace(/\/+$/, "")
        const base = path.slice(cut + 1)
        if (!base || /\.tmp$/.test(base) || base.indexOf(".tmp.") >= 0) return
        if (base === "lock" || /\.lock$/.test(base) || base === "feeds") return
        if (dir === cacheDir + "/pending") { statusSoon.restart(); return }
        if (dir === cacheDir && base === "preview.json") { previewFile.reload(); statusSoon.restart(); return }
        // Media (v1.3): job records change as they run; the index stamp
        // moves as the indexer reads files. A folder made after the watch
        // started needs a new watch.
        if (dir === cacheDir && base === "media") { restartWatch(); return }
        if (dir === cacheDir + "/media" && (base === "jobs" || base === "index")) { restartWatch(); return }
        if (dir === cacheDir + "/media/jobs") {
            if (/\.json$/.test(base)) {
                if (editorOpen && !jobsSoon.running) jobsSoon.start()
                if (!statusSoon.running) statusSoon.start()
            }
            return
        }
        if ((dir === cacheDir + "/media" || dir === cacheDir + "/media/index") && base === "index.stamp") {
            if (editorOpen && !indexSoon.running) indexSoon.start()
            return
        }
        // The desktop wallpaper (v1.4): the engine's cache of the desktop.
        if (dir === cacheDir && base === "desktop") { restartWatch(); return }
        if (dir === cacheDir + "/desktop") {
            if (base === "state.json") { statusSoon.restart(); desktopSoon.restart() }
            return
        }
        if (dir === configDir && base === "preview-method") { previewMethodFile.reload(); return }
        if (dir === cacheDir + "/previews") {
            if (/\.webp$/.test(base)) { themesSoon.restart(); statusSoon.restart() }
            return
        }
        // A new theme folder: its theme.json may land after the 300 ms read,
        // so read once more a little later.
        if (dir === configDir + "/themes") { themesSoon.restart(); themesLate.restart(); return }
        // A new profile (detect, profile set, migrate): the sections, the
        // labels, the coverage chips and the sensor sources all follow it.
        if (dir === configDir && base === "profile.json") {
            statusSoon.restart(); themesSoon.restart(); sensorsSoon.restart()
            return
        }
        if (statusNames.indexOf(base) >= 0) {
            statusSoon.restart()
            if (themeLinkedNames.indexOf(base) >= 0) themesSoon.restart()
        }
    }
    Process {
        id: watcher
        command: ["bash", "-c",
            "command -v inotifywait >/dev/null || exit 127\n"
            + "dirs=(); for d in \"$@\"; do [ -d \"$d\" ] && dirs+=(\"$d\"); done\n"
            + "[ ${#dirs[@]} -gt 0 ] || exit 1\n"
            // setpriv: the watch dies with the shell even when the shell is
            // killed (an orphaned inotifywait -m lives until its next event).
            + "exec setpriv --pdeathsig TERM inotifywait -m -q -e close_write,moved_to,create,delete --format '%w%f' \"${dirs[@]}\"",
            "lumenaire-watch", root.configDir, root.configDir + "/themes", root.cacheDir, root.cacheDir + "/pending",
            root.cacheDir + "/previews", root.omarchyStateDir, root.cacheDir + "/media", root.cacheDir + "/media/jobs", root.cacheDir + "/media/index",
            root.cacheDir + "/desktop"]
        stdout: SplitParser { onRead: data => root.onWatch(data) }
        onExited: (code, st) => {
            if (!root.started) return
            if (code === 127) {
                console.warn("[lumenaire] inotifywait missing; polling the engine status every 5 s")
                root.watcherMissing = true
                return
            }
            watcherRestart.restart()
        }
    }
    Timer { id: watcherRestart; interval: 2000; onTriggered: if (root.started && !watcher.running) watcher.running = true }
    // Watch again (new folders to include): the exit handler restarts it.
    function restartWatch() { if (watcher.running) watcher.signal(15) }
    Timer { id: statusSoon; interval: 250; onTriggered: engineState.refreshStatus() }
    Timer { id: themesSoon; interval: 300; onTriggered: engineState.refreshThemes() }
    Timer { id: themesLate; interval: 2000; onTriggered: engineState.refreshThemes() }
    Timer { id: sensorsSoon; interval: 300; onTriggered: sensors.refreshSources() }

    // Safety polls: the watcher does the real work; these cover countdowns,
    // the schedule boundary and anything a watch can miss.
    readonly property bool inFlight: busy !== null || pending.length > 0 || engineState.opsInFlight
    Timer {
        interval: root.watcherMissing ? 5000 : root.inFlight ? 15000 : root.panelOpenCount > 0 ? 60000 : 300000
        repeat: true
        running: root.started
        onTriggered: engineState.refreshStatus()
    }
    // The local clock for busyElapsed, ages and countdowns; idle otherwise.
    Timer {
        interval: 1000
        repeat: true
        running: root.started && (root.panelOpenCount > 0 || root.inFlight || engineState.opsSettling
                                  || engineState.resultFresh || engineState.flash !== null)
        onTriggered: engineState.tick()
    }

    // ---- settings (shell.json) --------------------------------------------
    // A service gets no `settings`, and the shell's barConfig snapshot does not
    // follow `omarchy bar set`; the file is the one current source.
    property var fileConfig: null
    FileView {
        path: root.home + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        onLoaded: {
            let parsed = null
            try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
            root.fileConfig = parsed
        }
        onLoadFailed: root.fileConfig = null
        onFileChanged: reload()
    }
    function entryIn(config) {
        const bar = config && config.bar && typeof config.bar === "object" ? config.bar : null
        const layout = bar && bar.layout ? bar.layout : {}
        for (const section of ["left", "center", "right"]) {
            const list = layout[section]
            if (!Array.isArray(list)) continue
            for (const e of list) if (e && (e === pluginId || e.id === pluginId)) return typeof e === "object" ? e : {}
        }
        return null
    }
    // `omarchy bar set` without --json stores "false" and "45" as strings.
    function asBool(v, fb) {
        if (v === undefined || v === null) return fb
        if (typeof v === "boolean") return v
        const t = String(v).trim().toLowerCase()
        if (["true", "1", "on", "yes"].indexOf(t) >= 0) return true
        if (["false", "0", "off", "no", ""].indexOf(t) >= 0) return false
        return fb
    }
    function asNum(v, fb) { const n = Number(v); return v !== null && v !== "" && isFinite(n) ? n : fb }
    function readSettings(config) {
        const d = manifest && manifest.barWidget && manifest.barWidget.defaults ? manifest.barWidget.defaults : {}
        const e = entryIn(config) || {}
        const pickv = (k, fb) => e[k] !== undefined && e[k] !== null ? e[k] : (d[k] !== undefined ? d[k] : fb)
        const show = String(pickv("show", "auto"))
        const right = String(pickv("rightClick", "panel"))
        return {
            show: ["auto", "coolant", "pump", "both", "cpu", "none"].indexOf(show) >= 0 ? show : "auto",
            coolantWarn: asNum(pickv("coolantWarn", 40), 40),
            showGpu: asBool(pickv("showGpu", true), true),
            rightClick: right === "lights" ? "lights" : "panel",
            showDot: asBool(pickv("showDot", true), true),
            previewIdleMinutes: Math.max(2, Math.min(30, Math.round(asNum(pickv("previewIdleMinutes", 10), 10))))
        }
    }

    // ---- parts ------------------------------------------------------------
    EngineState {
        id: engineState
        pclBin: root.pclBin
        bundledBin: root.bundledBin
        link: daemonLink
        lianliQuiet: root.lianliQuiet || !root.hasLianli
        panelOpen: root.panelOpenCount > 0
        preview: root.previewLive ? root.preview : null
        editorOpen: root.editorOpen
        editorName: root.editorName
    }
    DaemonLink {
        id: daemonLink
        socketPath: root.daemonSocket
        fast: root.panelOpenCount > 0
        daemonUnit: root.status && root.status.daemon_unit ? String(root.status.daemon_unit) : ""
        labels: root.status && root.status.labels && typeof root.status.labels === "object" ? root.status.labels : ({})
        // profile.pump_device, else sensors --json's coolant device; empty
        // = the first has_pump device (the old rule).
        pumpDevice: root.profile && root.profile.pump_device ? String(root.profile.pump_device)
            : sensors.sources && sensors.sources.coolant && sensors.sources.coolant.device_id ? String(sensors.sources.coolant.device_id) : ""
    }
    Sensors {
        id: sensors
        gpuWanted: root.panelOpenCount > 0 && root.settings.showGpu
        pclBin: root.pclBin
    }
    // No Lian Li backend on this PC: stop polling a socket that will never
    // answer (and never say "daemon offline"); one appearing starts it.
    onHasLianliChanged: {
        if (!started) return
        if (!hasLianli) daemonLink.stop()
        else if (!daemonLink.enabled) { daemonLink.enabled = true; daemonLink.start() }
    }

    function start() {
        if (started) return
        started = true
        daemonLink.enabled = true
        daemonLink.start()
        sensors.enabled = true
        if (pclBin) engineReady()
        else resolveProc.running = true
        // The watcher starts after the first status run (onSnapshot), which
        // creates the cache directories; this covers an engine too old to
        // produce a snapshot.
        watcherKick.start()
    }
    Timer { id: watcherKick; interval: 3000; onTriggered: if (root.started && !watcher.running && !root.watcherMissing) watcher.running = true }
    function engineReady() {
        engineState.refreshStatus()
        engineState.refreshThemes()
        sensors.start()
    }
    Process {
        id: resolveProc
        command: ["bash", "-c", "for p; do [ -x \"$p\" ] && { printf '%s' \"$p\"; exit; }; done; printf '%s' \"$1\"",
                  "lumenaire-engine", root.userBin, root.legacyBin, root.bundledBin]
        stdout: StdioCollector { id: resolveOut; waitForEnd: true }
        onExited: (code, st) => {
            root.pclBin = String(resolveOut.text || "").trim() || root.userBin
            if (root.pclBin === root.bundledBin) console.info("[lumenaire] using the bundled engine " + root.pclBin)
            if (root.started) root.engineReady()
        }
    }
    onManifestChanged: if (manifest) start()

    // ---- IPC: omarchy-shell lumenaire <method> ------------------------------
    IpcHandler {
        target: "lumenaire"
        function status(): string {
            return JSON.stringify({
                theme: root.activeTheme || null, lights: root.lights || null, screens: root.screens || null,
                engine: root.engine, busy_theme: root.busy ? (root.busy.theme || null) : null,
                daemon: root.daemonState, pump_rpm: root.pumpRpm, coolant_c: root.coolantC,
                coolant_age_s: root.coolantAgeS, cpu_c: root.cpuC, gpu_c: root.gpuC,
                schedule_period: root.schedule ? (root.schedule.period || null) : null,
                override: root.schedule && root.schedule.override !== undefined ? !!root.schedule.override : null,
                panel_open_count: root.panelOpenCount, gpu_polling: sensors.gpuShouldRun || sensors.gpuPollRun,
                engine_bin: root.pclBin, profile: root.profileState || null, sensors: sensors.mode
            })
        }
        function refresh(): void { root.refresh() }
        function pick(name: string): string {
            if (!name) return "error: no theme name"
            if (root.ready && root.themes.length && !root.themeByName[name]) return "error: no theme named " + name
            root.pick(name)
            return "queued"
        }
        function lights(state: string): string { return root.ipcPower("lights", state) }
        function screens(state: string): string { return root.ipcPower("screens", state) }
        function skip(): string {
            const why = root.skipRefusal()
            if (why) return root.busy !== null ? "busy" : "error: " + why
            return root.skipClip() ? "queued" : "busy"
        }
        function pause(): void { root.setClipsPaused(true) }
        function resume(): void { root.setClipsPaused(false) }
        function open(): void { if (root.shell) root.shell.summon(root.pluginId, "{}") }
        function close(): void { if (root.shell) root.shell.hide(root.pluginId) }
    }
    function ipcPower(kind, state) {
        const s = String(state || "").trim().toLowerCase()
        const cur = kind === "lights" ? lights : screens
        let on = null
        if (s === "on") on = true
        else if (s === "off") on = false
        else if (s === "toggle") {
            // A change of this kind still on its way counts as done: toggling
            // again flips what was asked for, not the state it will replace.
            const op = engineState.ops[kind]
            const inFlight = !!op && (op.phase === "launching" || op.phase === "queued" || op.phase === "applying")
            on = inFlight ? !op.desired : cur !== "on"
        }
        else return "error: use on, off or toggle"
        if (!canChange(kind)) return "error: a change is running; try again when it finishes"
        power(kind, on)
        return "queued"
    }

    Component.onDestruction: {
        started = false
        watcherKick.stop(); watcherRestart.stop(); themesLate.stop()
        editFlush.stop(); previewDebounce.stop(); previewTick.stop(); panelCloseGrace.stop()
        screensSoon.stop(); listDebounce.stop(); frameDebounce.stop(); jobsSoon.stop(); indexSoon.stop(); desktopSoon.stop()
        if (watcher.running) watcher.signal(15)
        engineState.stop()
        daemonLink.stop()
        sensors.stop()
    }
}
