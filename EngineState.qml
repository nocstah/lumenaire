// Lumenaire — what the engine (lumenaire, alias pc-lights) is doing, and what to tell the user.
//
// Two read commands feed everything here, each run as a short child with a
// 5 s kill timer, one at a time (a request while one runs sets a flag that
// onExited drains):
//
//   pc-lights status --json   contract v1: theme, lights, busy, pending,
//                             last_run, schedule, omarchy, rotation, …
//   pc-lights themes --json   the theme list with colours and previews
//
// Contract v1.1 is additive and keeps "v": 1 (v_minor 1): status gains
// `profile` (the hardware profile's state, groups, pump device, …) and
// `labels`; themes gain `coverage`. Every v1.1 field is optional here, so a
// v1.0 engine drives the same panel as before.
//
// Contract checks: exit 127/126 -> "missing"; a usage error, or the old
// text output (an engine without --json just prints its prose status) ->
// "too-old"; v > 1 -> "too-new". A snapshot that fails to parse keeps the
// last good one, is retried once after 1 s, and only becomes "unreadable"
// after three failures in a row (a fallback daemon restart copies config.json
// non-atomically, so one bad read is expected now and then).
//
// Ops: one entry per kind (theme, lights, screens, clips, schedule), each
//   launching -> queued (the launcher printed {"queued"}, unit known)
//             -> applying (busy.unit is ours)
//             -> done | partial | failed (last_run.unit is ours)
//   a pick older than ui_requested_ns was superseded: dropped
//   queued/applying with the unit gone and no last_run for 10 s -> failed
//   done/partial clear after 5 s; failed stays until dismissed or replaced.
// After a hot reload this starts empty and adopts the first snapshot's busy,
// pending and last_run, so a running apply keeps its progress line.
import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as Format

Scope {
    id: root

    // ---- inputs -----------------------------------------------------------
    property string pclBin: ""
    property var link: null               // DaemonLink, for the offline notice and labels
    property bool lianliQuiet: false      // no Lian Li gear known on this PC: never say "daemon offline"
    property bool panelOpen: false
    property var preview: null            // preview.json while a preview is on the case, else null
    property bool editorOpen: false       // the editor page shows its own preview line
    property string editorName: ""        // … and its own media jobs
    property double now: Date.now() / 1000  // epoch seconds, ticked by Service
    readonly property double startedAt: Date.now() / 1000

    // ---- engine data ------------------------------------------------------
    property bool ready: false
    property string engineError: ""       // "" | missing | too-old | too-new | unreadable
    property var status: null
    property var themes: []
    property var themeByName: ({})
    property int previewRev: 0
    property int failuresInRow: 0
    property var ops: ({ theme: null, lights: null, screens: null, clips: null, schedule: null, detect: null })
    readonly property var kinds: ["theme", "lights", "screens", "clips", "schedule", "detect"]
    // The bundled engine, for the install hint when none runs at all.
    property string bundledBin: ""
    property bool failureUnseen: false
    property string lastRunKey: ""
    property var dismissed: ({})
    property var flash: null              // {key, text, until}: a short-lived notice
    property bool adopted: false

    readonly property var busy: status && status.busy ? status.busy : null
    readonly property var pending: status && Array.isArray(status.pending) ? status.pending : []
    readonly property var lastRun: status && status.last_run ? status.last_run : null
    readonly property int vMinor: status && isFinite(Number(status.v_minor)) ? Number(status.v_minor) : 0
    readonly property var profile: Format.profileOf(status)
    readonly property int busyElapsed: busy && isFinite(Number(busy.since)) ? Math.max(0, Math.floor(now - Number(busy.since))) : 0
    readonly property bool opsInFlight: kinds.some(k => ops[k] && ["launching", "queued", "applying"].indexOf(ops[k].phase) >= 0)
    readonly property bool opsSettling: kinds.some(k => ops[k] && ["done", "partial"].indexOf(ops[k].phase) >= 0)
    readonly property bool resultFresh: lastRun !== null && isFinite(Number(lastRun.ended)) && now - Number(lastRun.ended) < 8
    readonly property string engine: busy ? "applying"
        : (pending.length > 0 || opsInFlight) ? "queued"
        : resultFresh ? runFlavour(lastRun)
        : failureUnseen ? "failed"
        : "idle"

    signal snapshot()
    signal runEnded()
    signal themesRead()

    // ---- small helpers ----------------------------------------------------
    // One spelling everywhere: the header, cards and bar use Format too.
    function displayName(n) { return Format.themeName(n) }
    function mmss(sec) {
        const s = Math.max(0, Math.floor(Number(sec) || 0))
        const r = s % 60
        return Math.floor(s / 60) + ":" + (r < 10 ? "0" : "") + r
    }
    function clean(err) { return String(err || "").trim().replace(/[.\s]+$/, "") }
    function kindOf(op, target) { return Format.kindOf(op, target) }
    function runFlavour(r) {
        if (!r) return "idle"
        if (Number(r.rc) !== 0) return "failed"
        if (r.skipped) return "skipped"
        if ((Array.isArray(r.missed_devices) && r.missed_devices.length) || r.fallback) return "partial"
        return "done"
    }
    // Nanosecond stamps overflow a double; compare them as digit strings.
    function newerNs(a, b) {
        if (!/^\d+$/.test(a) || !/^\d+$/.test(b)) return false
        return a.length !== b.length ? a.length > b.length : a > b
    }
    function nsOf(unit) { const m = String(unit || "").match(/-(\d+)$/); return m ? m[1] : "" }
    function setOp(kind, value) {
        const next = Object.assign({}, ops)
        next[kind] = value
        ops = next
    }
    function runKey(r) { return r ? String(r.unit || "") + "@" + String(r.started || "") + "-" + String(r.ended || "") : "" }

    // ---- reads ------------------------------------------------------------
    property bool statusAgain: false
    property bool themesAgain: false
    function refreshStatus() {
        if (!pclBin) return
        if (statusProc.running) { statusAgain = true; return }
        statusProc.running = true
        statusKill.restart()
    }
    function refreshThemes() {
        if (!pclBin) return
        if (themesProc.running) { themesAgain = true; return }
        themesProc.running = true
        themesKill.restart()
    }
    // `exec "$0"` turns a missing binary into bash's 127 instead of a
    // process that never starts.
    function cmd(args) { return ["bash", "-c", "exec \"$0\" \"$@\"", pclBin].concat(args) }

    function contractError(code, out, err) {
        if (code === 127 || code === 126) return "missing"
        if (code !== 0 && /usage:/.test(err)) return "too-old"
        const t = String(out || "").trim()
        if (code === 0 && t && t.charAt(0) !== "{" && t.charAt(0) !== "[") return "too-old"
        return ""
    }
    function statusFailed(why) {
        failuresInRow += 1
        console.warn("[lumenaire] status --json: " + why + " (" + failuresInRow + " in a row)")
        // Retry once after 1 s. Without any snapshot yet there is nothing to
        // show meanwhile, so give it a third try 3 s later to reach a verdict.
        if (failuresInRow === 1) { statusRetry.interval = 1000; statusRetry.restart() }
        else if (failuresInRow === 2 && !ready) { statusRetry.interval = 3000; statusRetry.restart() }
        if (failuresInRow >= 3 && engineError === "") engineError = "unreadable"
    }
    function acceptStatus(code, out, err) {
        const ce = contractError(code, out, err)
        if (ce) {
            if (engineError !== ce) console.warn("[lumenaire] engine " + ce + " (exit " + code + "): " + String(err).slice(0, 2000))
            engineError = ce
            return
        }
        if (code !== 0) { statusFailed("exit " + code + ": " + String(err).slice(0, 2000)); return }
        let s = null
        try { s = JSON.parse(out) } catch (e) { statusFailed(String(e)); return }
        if (!s || typeof s !== "object" || Array.isArray(s)) { statusFailed("not an object"); return }
        const v = Number(s.v)
        if (v > 1) { engineError = "too-new"; return }
        if (v !== 1) { statusFailed("contract v" + s.v); return }
        failuresInRow = 0
        engineError = ""
        const wasBusy = status && status.busy
        now = Date.now() / 1000
        status = s
        if (!ready) ready = true
        if (!adopted) { adopted = true; adopt(s) }
        noteLastRun(s.last_run || null)
        evaluate()
        snapshot()
        if (wasBusy && !s.busy) runEnded()
    }
    function acceptThemes(code, out, err) {
        const ce = contractError(code, out, err)
        if (ce) { if (!engineError || engineError === "unreadable") engineError = ce; return }
        if (code !== 0) { console.warn("[lumenaire] themes --json exit " + code + ": " + String(err).slice(0, 2000)); return }
        let list = null
        try { list = JSON.parse(out) } catch (e) { console.warn("[lumenaire] themes --json: " + e); return }
        if (!Array.isArray(list)) { console.warn("[lumenaire] themes --json: not an array"); return }
        let byName = {}
        let changed = false
        for (const t of list) {
            if (!t || !t.name) continue
            byName[t.name] = t
            const old = themeByName[t.name]
            if (!old || old.preview_mtime !== t.preview_mtime || old.preview !== t.preview) changed = true
        }
        if (Object.keys(themeByName).length !== Object.keys(byName).length) changed = true
        themes = list
        themeByName = byName
        if (changed) previewRev += 1
        themesRead()
    }

    Process {
        id: statusProc
        command: root.cmd(["status", "--json"])
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        stderr: StdioCollector { id: statusErr; waitForEnd: true }
        onExited: (code, st) => {
            statusKill.stop()
            root.acceptStatus(code, statusOut.text, statusErr.text)
            if (root.statusAgain) { root.statusAgain = false; Qt.callLater(root.refreshStatus) }
        }
    }
    Timer { id: statusKill; interval: 5000; onTriggered: if (statusProc.running) statusProc.signal(9) }
    Timer { id: statusRetry; interval: 1000; onTriggered: root.refreshStatus() }

    Process {
        id: themesProc
        command: root.cmd(["themes", "--json"])
        stdout: StdioCollector { id: themesOut; waitForEnd: true }
        stderr: StdioCollector { id: themesErr; waitForEnd: true }
        onExited: (code, st) => {
            themesKill.stop()
            root.acceptThemes(code, themesOut.text, themesErr.text)
            if (root.themesAgain) { root.themesAgain = false; Qt.callLater(root.refreshThemes) }
        }
    }
    Timer { id: themesKill; interval: 5000; onTriggered: if (themesProc.running) themesProc.signal(9) }

    // ---- ops --------------------------------------------------------------
    // Rebuild the in-flight UI ops a previous instance started.
    function adopt(s) {
        const own = u => String(u || "").indexOf("pc-lights-ui-") === 0
        const take = (e, phase) => {
            if (!e || !own(e.unit)) return
            const kind = kindOf(e.op, e.target)
            if (!kind) return
            let desired = null
            if (kind === "theme") desired = e.theme
            else if (kind === "lights" || kind === "screens") desired = e.op === "on"
            else if (kind === "schedule") desired = e.target === "on"
            else if (kind === "detect") desired = true
            else desired = "next"
            setOp(kind, { desired: desired, phase: phase, unit: e.unit, requestedAt: Number(e.queued || e.since || now), error: null, goneSince: 0, doneAt: 0 })
        }
        for (const p of (Array.isArray(s.pending) ? s.pending : [])) take(p, "queued")
        if (s.busy) take(s.busy, "applying")
        // The previous instance's last result is history and not re-flagged,
        // unless it failed within the last minute (a reload mid-failure).
        const r = s.last_run || null
        if (!(r && Number(r.rc) !== 0 && Number(r.ended || 0) >= startedAt - 60)) lastRunKey = runKey(r)
    }
    // A new run result, whoever started it (Omarchy, the schedule, the CLI).
    function noteLastRun(r) {
        const key = runKey(r)
        if (!r || key === lastRunKey) return
        lastRunKey = key
        if (Number(r.rc) !== 0 && Number(r.ended || 0) >= startedAt - 60) failureUnseen = true
    }
    function beginOp(kind, desired) {
        now = Date.now() / 1000
        setOp(kind, { desired: desired, phase: "launching", unit: "", requestedAt: now, error: null, goneSince: 0, doneAt: 0, launchFailed: false })
    }
    function launched(kind, code, out, err) {
        const op = ops[kind]
        if (!op || op.phase !== "launching") return
        let reply = null
        try { reply = JSON.parse(String(out || "").trim().split("\n").pop()) } catch (e) { reply = null }
        if (code === 0 && reply && reply.queued) {
            setOp(kind, Object.assign({}, op, { phase: "queued", unit: String(reply.unit || "") }))
            evaluate()
            return
        }
        let why = reply && reply.error ? reply.error : clean(err) || ("the engine exited " + code)
        if (code === 127 || code === 126) why = "the Lumenaire engine isn't installed"
        else if (code === 1 && /usage:/.test(err)) why = "this engine has no --detach; update it"
        console.warn("[lumenaire] launch " + kind + " failed (" + code + "): " + String(err).slice(0, 2000))
        setOp(kind, Object.assign({}, op, { phase: "failed", error: clean(why), launchFailed: true }))
        failureUnseen = true
    }
    function evaluate() {
        const s = status
        if (!s) return
        const lr = s.last_run || null
        const pend = Array.isArray(s.pending) ? s.pending : []
        let next = Object.assign({}, ops)
        let changed = false
        for (const kind of kinds) {
            const op = next[kind]
            if (!op) continue
            let n = op
            if (op.phase === "done" || op.phase === "partial") {
                if (now - op.doneAt >= 5) n = null
            } else if (op.phase === "queued" || op.phase === "applying") {
                const ns = nsOf(op.unit)
                if (lr && op.unit && lr.unit === op.unit) {
                    const f = runFlavour(lr)
                    if (f === "failed") {
                        n = Object.assign({}, op, { phase: "failed", error: clean(lr.error) || (Number(lr.rc) === 143 ? "it was stopped" : "exit " + lr.rc) })
                        failureUnseen = true
                    } else {
                        n = Object.assign({}, op, { phase: f === "partial" ? "partial" : "done", doneAt: now })
                    }
                } else if (s.busy && s.busy.unit === op.unit) {
                    if (op.phase !== "applying" || op.goneSince) n = Object.assign({}, op, { phase: "applying", goneSince: 0 })
                } else if (kind === "theme" && superseded(s, op, ns, pend)) {
                    n = null  // a later pick (from here, a terminal or a script)
                              // wins; the engine drops ours without a result
                } else if (pend.some(p => p && p.unit === op.unit)) {
                    if (op.goneSince) n = Object.assign({}, op, { goneSince: 0 })
                } else if (!op.goneSince) {
                    n = Object.assign({}, op, { goneSince: now })
                } else if (now - op.goneSince >= 10) {
                    if (kind === "clips") {
                        // --nowait found the lock taken inside the unit (exit 75):
                        // nothing ran, nothing failed.
                        showFlash("skip-busy", "A theme change is running; skip again when it finishes.")
                        n = null
                    } else {
                        n = Object.assign({}, op, { phase: "failed", error: "the request ended without a result, see the log", noResult: true })
                        failureUnseen = true
                    }
                }
            }
            if (n !== op) { next[kind] = n; changed = true }
        }
        if (changed) ops = next
    }
    // Is our queued pick older than the engine's latest one? ui_requested_ns
    // is that pick's stamp (a snapshot from before ours still names the
    // previous one: not newer). An engine without it: our unit is gone and
    // the latest pick names another theme.
    function superseded(s, op, ns, pend) {
        if (s.ui_requested_ns !== undefined) return newerNs(String(s.ui_requested_ns || ""), ns)
        return !!s.ui_requested && s.ui_requested !== op.desired && !pend.some(p => p && p.unit === op.unit)
    }
    // Called by Service on every local tick (ages and the 10 s gone clock).
    function tick() {
        now = Date.now() / 1000
        evaluate()
        if (flash && now >= flash.until) flash = null
    }
    function showFlash(key, text) {
        flash = { key: key, text: text, until: Date.now() / 1000 + 6 }
    }
    function ack() { failureUnseen = false }
    function dismissNotice() {
        const k = notice.key
        const d = Object.assign({}, dismissed)
        if (k) d[k] = true
        // A failed op of ours usually is the last run too: dismiss both, or
        // the same failure comes straight back as the run notice.
        if (lastRun && Number(lastRun.rc) !== 0) d["run:" + runKey(lastRun)] = true
        dismissed = d
        let next = Object.assign({}, ops)
        for (const kind of Object.keys(next)) if (next[kind] && next[kind].phase === "failed") next[kind] = null
        ops = next
        if (flash) flash = null
        failureUnseen = false
    }
    // What Retry should do: the failed op, else the last run.
    function retryTarget() {
        for (const kind of ["theme", "lights", "screens", "schedule", "clips", "detect"]) {
            const op = ops[kind]
            if (op && op.phase === "failed") return { kind: kind, desired: op.desired }
        }
        const r = lastRun
        if (!r) return null
        const kind = kindOf(r.op, r.target)
        if (kind === "theme") return { kind: "theme", desired: r.theme || (status ? status.theme : "") }
        if (kind === "lights" || kind === "screens") return { kind: kind, desired: r.op === "apply-openrgb" ? true : r.op === "on" }
        if (kind === "schedule") return { kind: "schedule", desired: r.target === "on" }
        if (kind === "clips") return { kind: "clips", desired: "next" }
        if (kind === "detect") return { kind: "detect", desired: true }
        return null
    }

    // ---- derived views ----------------------------------------------------
    function themeState(name) {
        if (!name) return ""
        const s = status || {}
        const b = busy
        if (b && kindOf(b.op, b.target) === "theme" && b.theme === name) return "applying"
        const op = ops.theme
        if (op && op.desired === name) {
            if (op.phase === "applying") return "applying"
            if (op.phase === "launching" || op.phase === "queued") return "queued"
            if (op.phase === "failed") return "failed"
        }
        if (pending.some(p => p && kindOf(p.op, p.target) === "theme" && p.theme === name)) return "queued"
        const r = lastRun
        if (r && Number(r.rc) !== 0 && r.theme === name && kindOf(r.op, r.target) === "theme"
            && !dismissed["run:" + runKey(r)] && s.theme !== name) return "failed"
        if (s.theme === name) return s.lights === "off" ? "saved" : "active"
        if (s.schedule && s.schedule.enabled && s.schedule.night_theme === name) return "night"
        return ""
    }
    // A stopped daemon makes lianli_lights, the screens and a clip swap fail
    // at once; a running one that just doesn't answer gets restarted by the
    // change itself, so only a skip (a live write, no fallback) waits.
    readonly property bool daemonDown: !!link && link.enabled && link.linkState === "offline" && !lianliQuiet
    readonly property bool daemonStopped: daemonDown && !!status && status.daemon_unit !== "active" && status.daemon_unit !== "activating"
    function canChange(kind) {
        if (kind === "theme") return true
        // Lights and screens queue like a theme pick: each runs as its own
        // unit that waits for the lock, so a click during a running change
        // (turning both off in a row) is taken, not refused.
        if ((kind === "lights" || kind === "screens") && daemonStopped) return false
        if (kind === "lights" || kind === "screens") return true
        if (busy !== null) return false
        if (kind === "clips" && daemonDown) return false
        return true
    }

    function stepLabel(step) {
        const m = { "waiting": "starting", "lian li": "Lian Li", "openrgb": "OpenRGB",
                    "retrying wireless": "retrying wireless devices", "restarting daemon": "restarting the daemon", "screens": "screens" }
        return m[step] || String(step || "starting")
    }
    function opPhrase(op, target, theme, ing) { return Format.opPhrase(op, target, theme, ing) }
    // The engine op an op entry of ours stands for.
    function opArgs(kind, desired) {
        if (kind === "theme") return { op: "pick", target: "", theme: desired }
        if (kind === "lights" || kind === "screens") return { op: desired ? "on" : "off", target: kind, theme: "" }
        if (kind === "schedule") return { op: "schedule-set", target: desired ? "on" : "off", theme: "" }
        if (kind === "clips") return { op: "clips-next", target: "", theme: "" }
        if (kind === "detect") return { op: "detect", target: "", theme: "" }
        return { op: "", target: "", theme: "" }
    }

    // ---- labels for the header and the bar tooltip ------------------------
    // What holds the lock: "Applying Hellfire", "Turning lights off", …
    readonly property string busyLabel: busy ? opPhrase(busy.op, busy.target, busy.theme, true) : ""
    // What waits: our own launching/queued op first (theme first), else the
    // oldest pending request. "Hellfire", "Lights off", "Next clip".
    readonly property string queuedLabel: {
        for (const kind of kinds) {
            const op = ops[kind]
            if (op && (op.phase === "launching" || op.phase === "queued")) {
                const a = opArgs(kind, op.desired)
                return Format.opShort(a.op, a.target, a.theme)
            }
        }
        const p = pending.length ? pending[0] : null
        return p ? Format.opShort(p.op, p.target, p.theme) : ""
    }
    // The failure the user hasn't seen, in a few words for the tooltip.
    readonly property string failureLabel: {
        for (const kind of ["theme", "lights", "screens", "schedule", "clips", "detect"]) {
            const op = ops[kind]
            if (op && op.phase === "failed") return failShort(kind, op.desired)
        }
        const r = lastRun
        if (r && Number(r.rc) !== 0) {
            const kind = kindOf(r.op, r.target)
            if (r.op === "apply-openrgb") return "Applying OpenRGB failed"
            return failShort(kind, kind === "theme" ? r.theme : kind === "schedule" ? r.target === "on" : r.op === "on", r.target)
        }
        return "The last change failed"
    }
    function failShort(kind, desired, target) {
        if (kind === "theme") return displayName(desired) + " failed to apply"
        if (kind === "lights" || kind === "screens")
            return "Turning " + (target === "all" ? "lights and screens" : kind) + " " + (desired ? "on" : "off") + " failed"
        if (kind === "schedule") return "Turning the night schedule " + (desired ? "on" : "off") + " failed"
        if (kind === "clips") return "Skipping the clip failed"
        if (kind === "detect") return "Detecting hardware failed"
        return "The last change failed"
    }
    function failText(kind, desired, err, launchFailed) {
        const e = clean(err) || "unknown error"
        const active = status ? status.theme : ""
        if (kind === "theme") {
            if (launchFailed || !active || active === desired) return displayName(desired) + " failed to apply: " + e + "."
            return displayName(desired) + " failed to apply: " + e + ". Fans may already show it; the rest kept " + displayName(active) + "."
        }
        if (kind === "lights" || kind === "screens") return "Turning " + kind + " " + (desired ? "on" : "off") + " failed: " + e + "."
        if (kind === "schedule") return "Turning the night schedule " + (desired ? "on" : "off") + " failed: " + e + "."
        if (kind === "clips") return "Skipping the clip failed: " + e + "."
        if (kind === "detect") return "Detecting hardware failed: " + e + ". The lights keep their current look."
        return "The last change failed: " + e + "."
    }
    // "~/.config/omarchy/plugins/…/bin/lumenaire install": short enough to
    // read in the notice, and a shell expands the ~ when it is pasted.
    readonly property string installCommand: {
        if (!bundledBin) return ""
        const h = Quickshell.env("HOME") || ""
        return (h && bundledBin.indexOf(h + "/") === 0 ? "~" + bundledBin.slice(h.length) : bundledBin) + " install"
    }
    function labelsFor(macs) {
        const names = (macs || []).map(m => link ? link.labelFor(m, "") : String(m))
        if (names.length <= 1) return names.join("")
        return names.slice(0, -1).join(", ") + " and " + names[names.length - 1]
    }

    // Retry only when there is something to retry.
    readonly property var notice: {
        const n = computeNotice()
        if (n.actions.indexOf("retry") < 0 || retryTarget() !== null) return n
        return Object.assign({}, n, { actions: n.actions.filter(a => a !== "retry") })
    }
    function computeNotice() {
        const none = { key: "", text: "", level: "", actions: [] }
        const s = status
        const t = now
        // 1. the engine itself
        if (engineError === "missing") return { key: "engine", level: "urgent", actions: bundledBin ? ["copy"] : [],
                                                text: bundledBin ? "The Lumenaire engine isn't installed. Install it with:\n" + installCommand : "The Lumenaire engine isn't installed at ~/.local/bin/lumenaire." }
        if (engineError === "too-old") return { key: "engine", text: "Lumenaire needs an engine with status --json (see README).", level: "urgent", actions: [] }
        if (engineError === "too-new") return { key: "engine", text: "The engine is newer than this plugin understands. Update the plugin.", level: "urgent", actions: [] }
        if (engineError === "unreadable") return { key: "engine", text: "The engine's status can't be read right now. Refresh, or check the log.", level: "urgent", actions: ["retry", "log"] }
        // 2. the daemon
        if (daemonStopped)
            return { key: "daemon", text: "Lian Li daemon isn't running. Lights, screens and clips can't change until it's back.", level: "urgent", actions: ["log"] }
        if (daemonDown)
            return { key: "daemon", text: "Lian Li daemon isn't answering. Readings are paused; a theme or power change restarts it.", level: "urgent", actions: ["log"] }
        // 3. failures: our own ops first, then any run's result
        for (const kind of ["theme", "lights", "screens", "schedule", "clips", "detect"]) {
            const op = ops[kind]
            if (op && op.phase === "failed")
                return { key: "op:" + kind + ":" + op.requestedAt, level: "urgent", actions: ["retry", "log", "dismiss"],
                         text: op.noResult ? opPhrase(kind === "theme" ? "pick" : kind === "clips" ? "clips-next" : kind === "schedule" ? "schedule" : kind === "detect" ? "detect" : (op.desired ? "on" : "off"),
                                                      kind === "schedule" ? (op.desired ? "on" : "off") : kind, op.desired, false)
                                             + ": the request ended without a result, see the log."
                                           : failText(kind, op.desired, op.error, op.launchFailed) }
        }
        const r = s ? s.last_run : null
        const rk = "run:" + runKey(r)
        const recent = r && isFinite(Number(r.ended)) && t - Number(r.ended) < 600
        if (r && Number(r.rc) !== 0 && t - Number(r.ended || 0) < 3600 && !dismissed[rk] && !(s && s.busy)) {
            const kind = kindOf(r.op, r.target)
            const txt = r.op === "apply-openrgb" ? "Applying OpenRGB failed: " + (clean(r.error) || "exit " + r.rc) + "."
                : failText(kind, kind === "theme" ? r.theme : kind === "schedule" ? r.target === "on" : r.op === "on",
                           r.error || (Number(r.rc) === 143 ? "it was stopped" : "exit " + r.rc), false)
            return { key: rk, text: txt, level: "urgent", actions: ["retry", "log", "dismiss"] }
        }
        const b = s ? s.busy : null
        const pend = s && Array.isArray(s.pending) ? s.pending : []
        const fromOmarchy = pend.find(p => p && p.source === "omarchy") || null
        const op = ops.theme
        const waiting = op && (op.phase === "queued" || op.phase === "launching") && !(b && b.unit && b.unit === op.unit)
        // 5 before 4 when it applies: our pick waits behind Omarchy's apply
        // (running, or still on its 5 s timer).
        if (waiting && (fromOmarchy || (b && /^pc-lights-(apply|omarchy)-/.test(String(b.unit || "")))))
            return { key: "queued", text: displayName(op.desired) + " is queued behind an Omarchy theme apply.", level: "info", actions: [] }
        // 4. applying; a pick made meanwhile waits, and only the last one runs
        if (b) {
            const el = Math.max(0, Math.floor(t - Number(b.since || t)))
            const tail = waiting ? " Queued, the last pick wins." : " Other changes wait until it finishes."
            if (el >= 240) return { key: "busy", text: "Still applying (" + mmss(el) + "). The daemon may be restarting." + (waiting ? tail : ""), level: "info", actions: [] }
            return { key: "busy", text: opPhrase(b.op, b.target, b.theme, true) + "… " + mmss(el) + " (" + stepLabel(b.step) + ")." + tail, level: "info", actions: [] }
        }
        // 5b. a theme preview on the case that no open editor speaks for
        // (another monitor, after a reload). A preview is not an op.
        if (preview && !editorOpen && preview.theme)
            return { key: "preview:" + String(preview.id || ""), text: "Previewing " + displayName(preview.theme) + " on the case, not saved.",
                     level: "info", actions: ["edit", "endpreview"] }
        // 5c. media being prepared for a theme no open editor shows (v1.3):
        // "Preparing Sakura's pump video… 42 %", or why it failed.
        if (s && vMinor >= 3 && s.media) {
            const mn = Format.mediaNotice(s.media, editorOpen ? editorName : "", dismissed, t)
            if (mn) return mn
        }
        // 6. Omarchy's own pending apply
        if (fromOmarchy) {
            const due = Number(fromOmarchy.due)
            const left = isFinite(due) ? Math.ceil(due - t) : -1
            const slug = fromOmarchy.slug || "a new theme"
            return { key: "omarchy", text: "Omarchy switched to " + slug + "; applying " + displayName(fromOmarchy.theme)
                     + (left > 0 ? " in " + left + " s…" : "…"), level: "info", actions: [] }
        }
        // 7-9. results worth a sentence
        if (r && recent && !dismissed[rk]) {
            const night = s && s.schedule ? s.schedule.night_end : ""
            if (r.skipped && r.op === "clips-next")
                return { key: rk, text: "Nothing to skip: " + (clean(r.error) || "the rotation isn't running") + ".", level: "info", actions: ["dismiss"] }
            if (r.skipped) return { key: rk, text: "Omarchy's " + displayName(r.theme) + " was saved for daytime; the night theme stays until " + (night || "morning") + ".", level: "info", actions: ["dismiss"] }
            if (Array.isArray(r.missed_devices) && r.missed_devices.length) {
                const many = r.missed_devices.length > 1
                const lead = kindOf(r.op, r.target) === "theme" ? "Applied " + displayName(r.theme) : "Done"
                return { key: rk, text: lead + ", but " + labelsFor(r.missed_devices) + (many ? " missed it and keep their old look." : " missed it and keeps its old look."), level: "info", actions: ["retry", "dismiss"] }
            }
            if (r.fallback) return { key: rk, text: "Applied through a daemon restart (live writes refused). Check the daemon version.", level: "info", actions: ["log", "dismiss"] }
        }
        // 9b. the hardware profile: onboarding, a stale or unreadable one.
        // Never while a detect is on its way (it answers the notice).
        const pn = Format.profileNotice(profile)
        const detecting = (ops.detect && ["launching", "queued", "applying"].indexOf(ops.detect.phase) >= 0)
                          || pend.some(p => p && p.op === "detect")
        if (pn && !detecting && !dismissed[pn.key]) return pn
        // 10. the lights-off screens gap
        if (s && s.lights === "off" && s.screens_show && s.theme && s.screens_show !== s.theme)
            return { key: "gap", text: "Lights are off. " + displayName(s.theme) + " is selected; screens still show " + displayName(s.screens_show) + ".", level: "info", actions: [] }
        // 11. short-lived
        if (flash && t < flash.until) return { key: flash.key, text: flash.text, level: "info", actions: [] }
        return none
    }

    function stop() {
        statusKill.stop(); themesKill.stop(); statusRetry.stop()
        if (statusProc.running) statusProc.signal(15)
        if (themesProc.running) themesProc.signal(15)
    }
    Component.onDestruction: stop()
}
