// Lumenaire — host temperatures the Lian Li daemon doesn't publish.
//
// Where to read comes from the engine: `pc-lights sensors --json` (contract
// v1.1, about 8 ms) names the CPU and GPU sources this PC has, resolved to
// full sysfs paths at call time (hwmon indices move between boots). It runs
// at start and again when the profile changes (refreshSources). Any source
// with a non-null `input` is a file read as value × scale (hwmon or
// thermal_zone); kind "nvidia-smi" carries the full argv in `cmd`.
//
//   CPU  a temp*_input (k10temp, zenpower, coretemp, a thermal zone, …),
//        read with FileView.reload() on every tick, times its `scale`.
//        Should the read come back empty or stop changing for 30 s, one
//        `cat` Process answers instead.
//   GPU  kind "nvidia-smi": one long-running `nvidia-smi … -lms 2000` (the
//        engine's `cmd`), only while `gpuWanted` (a panel is open and
//        showGpu is set). It is restarted 5 s after it exits; three exits
//        within 20 s of starting and it stays stopped (`gpuFailed`, the view
//        shows "n/a"). Its values go back to null the moment it stops, so
//        nothing downstream acts on an old reading.
//        a file source (amdgpu, xe, … hwmon): polled like the CPU while
//        gpuWanted; no utilisation or power.
//   A source the engine reports as null (or available:false) leaves its
//   reading null and cpuAvailable/gpuAvailable false: the view hides it.
//
// An engine without `sensors --json` (contract v1.0, a usage error, or any
// answer that isn't a v1 object) keeps the old fixed sources: k10temp found
// by its hwmon `name`, and plain nvidia-smi.
//
// Never ListSensors: the daemon runs nvidia-smi synchronously for it (67 ms).
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool enabled: false
    property bool gpuWanted: false
    property int interval: 2000
    property string pclBin: ""

    property var cpuC: null
    property var gpuC: null
    property var gpuUtil: null
    property var gpuW: null
    property bool gpuFailed: false

    // "pending" (not asked yet) | "profile" (sensors --json) | "legacy"
    property string mode: "pending"
    property var sources: null           // the parsed sensors --json object
    readonly property var cpuSource: mode === "profile" && sources && sources.cpu && sources.cpu.available !== false ? sources.cpu : null
    readonly property var gpuSource: mode === "profile" && sources && sources.gpu && sources.gpu.available !== false ? sources.gpu : null
    // Legacy and pending say yes, so an old engine keeps both cells.
    readonly property bool cpuAvailable: mode !== "profile" || (cpuSource !== null && !!cpuSource.input)
    readonly property bool gpuAvailable: mode !== "profile" || gpuKind !== ""
    readonly property string cpuDriver: mode === "legacy" ? "k10temp" : cpuSource && cpuSource.driver ? String(cpuSource.driver) : ""
    readonly property string gpuKind: mode === "legacy" ? "nvidia-smi"
        : gpuSource && gpuSource.kind === "nvidia-smi" ? "nvidia-smi"
        : gpuSource && gpuSource.input ? "file"
        : ""

    property string hwmonDir: ""         // legacy: the k10temp directory
    readonly property string cpuPath: mode === "legacy" ? (hwmonDir ? hwmonDir + "/temp1_input" : "")
        : cpuAvailable && cpuSource ? String(cpuSource.input) : ""
    readonly property real cpuScale: mode === "profile" && cpuSource && isFinite(Number(cpuSource.scale)) && Number(cpuSource.scale) > 0 ? Number(cpuSource.scale) : 0.001
    readonly property string gpuPath: gpuKind === "file" ? String(gpuSource.input) : ""
    readonly property real gpuScale: gpuSource && isFinite(Number(gpuSource.scale)) && Number(gpuSource.scale) > 0 ? Number(gpuSource.scale) : 0.001
    readonly property var gpuCmd: {
        if (gpuKind !== "nvidia-smi") return []
        if (mode === "profile" && Array.isArray(gpuSource.cmd) && gpuSource.cmd.length > 0) return gpuSource.cmd.map(String)
        const base = ["nvidia-smi"]
        if (mode === "profile" && isFinite(Number(gpuSource.index))) base.push("-i", String(Number(gpuSource.index)))
        return base.concat(["--query-gpu=temperature.gpu,utilization.gpu,power.draw", "--format=csv,noheader,nounits", "-lms", "2000"])
    }

    property double cpuReadAt: 0         // ms epoch of the last good read
    property int gpuQuickFails: 0
    property double gpuStartedAt: 0
    property double sourcesAskedAt: 0

    function start() {
        if (!enabled) return
        if (mode === "pending") refreshSources()
        else if (mode === "legacy" && !hwmonDir && !findProc.running) findProc.running = true
    }
    function stop() {
        enabled = false
        if (sourcesProc.running) sourcesProc.signal(15)
        if (findProc.running) findProc.signal(15)
        if (catProc.running) catProc.signal(15)
        if (gpuProc.running) gpuProc.running = false
    }
    // Ask the engine again (a profile change, or a source that stopped
    // answering). One at a time; a request meanwhile runs once more after.
    property bool sourcesAgain: false
    function refreshSources() {
        if (!enabled) return
        if (!pclBin) { useLegacy(); return }
        if (sourcesProc.running) { sourcesAgain = true; return }
        sourcesAskedAt = Date.now()
        sourcesProc.running = true
        sourcesKill.restart()
    }
    function acceptSources(code, out) {
        let s = null
        if (code === 0) { try { s = JSON.parse(String(out || "")) } catch (e) { s = null } }
        if (!s || typeof s !== "object" || Array.isArray(s) || Number(s.v) !== 1) {
            if (mode !== "legacy") console.info("[lumenaire] the engine has no sensors --json (exit " + code + "); using k10temp and nvidia-smi")
            useLegacy()
            return
        }
        const before = JSON.stringify(sources)
        mode = "profile"
        if (JSON.stringify(s) !== before) {
            sources = s
            cpuReadAt = 0
            cpuC = null
            gpuC = null; gpuUtil = null; gpuW = null
            gpuFailed = false
        }
        tick()
    }
    function useLegacy() {
        mode = "legacy"
        sources = null
        if (!hwmonDir && !findProc.running) findProc.running = true
    }

    function takeCpu(text) {
        const t = String(text || "").trim()
        const n = Number(t)
        if (t === "" || !isFinite(n)) return false
        cpuC = Math.round(n * cpuScale * 10) / 10
        cpuReadAt = Date.now()
        return true
    }
    function takeGpuFile(text) {
        const t = String(text || "").trim()
        const n = Number(t)
        if (t === "" || !isFinite(n)) { gpuC = null; return }
        gpuC = Math.round(n * gpuScale * 10) / 10
    }
    function tick() {
        if (!enabled) return
        if (gpuPollRun) gpuFile.reload()
        if (!cpuPath) return
        // The sysfs value changes nearly every read; 30 s without one means
        // the FileView stopped delivering.
        if (cpuReadAt > 0 && Date.now() - cpuReadAt > 30000) {
            if (!catProc.running) catProc.running = true
        } else {
            cpuFile.reload()
        }
    }
    // A profile path that stopped reading (hwmon renumbered): ask the
    // engine for fresh paths, at most once a minute.
    function sourceLost() {
        if (mode === "profile" && Date.now() - sourcesAskedAt > 60000) refreshSources()
    }

    Process {
        id: sourcesProc
        // `exec "$0"` turns a missing binary into bash's 127.
        command: ["bash", "-c", "exec \"$0\" sensors --json", root.pclBin]
        stdout: StdioCollector { id: sourcesOut; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: (code, st) => {
            sourcesKill.stop()
            root.acceptSources(code, sourcesOut.text)
            if (root.sourcesAgain) { root.sourcesAgain = false; Qt.callLater(root.refreshSources) }
        }
    }
    Timer { id: sourcesKill; interval: 5000; onTriggered: if (sourcesProc.running) sourcesProc.signal(9) }

    Process {
        id: findProc
        command: ["bash", "-c", "grep -lx k10temp /sys/class/hwmon/hwmon*/name 2>/dev/null | head -n1"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const f = String(text || "").trim()
                if (f) {
                    root.hwmonDir = f.replace(/\/name$/, "")
                    root.tick()
                } else {
                    console.warn("[lumenaire] no k10temp hwmon; CPU temperature unavailable")
                }
            }
        }
    }
    FileView {
        id: cpuFile
        path: root.cpuPath
        printErrors: false
        onLoaded: if (!root.takeCpu(text()) && !catProc.running) catProc.running = true
        onLoadFailed: if (!catProc.running) catProc.running = true
    }
    Process {
        id: catProc
        command: ["cat", root.cpuPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: if (!root.takeCpu(text)) { root.cpuC = null; root.sourceLost() }
        }
    }
    Timer {
        interval: root.interval
        repeat: true
        running: root.enabled && (root.cpuPath !== "" || root.gpuPollRun)
        onTriggered: root.tick()
    }

    // ---- GPU --------------------------------------------------------------
    readonly property bool gpuShouldRun: enabled && gpuWanted && !gpuFailed && gpuKind === "nvidia-smi"
    readonly property bool gpuPollRun: enabled && gpuWanted && gpuKind === "file"
    // Each panel open gives nvidia-smi a fresh chance.
    onGpuWantedChanged: if (gpuWanted) gpuFailed = false
    onGpuShouldRunChanged: {
        if (gpuShouldRun) {
            gpuQuickFails = 0
            gpuRestart.stop()
            gpuStartedAt = Date.now()
            gpuProc.running = true
        } else {
            gpuRestart.stop()
            if (gpuProc.running) gpuProc.running = false
            if (!gpuPollRun) { gpuC = null; gpuUtil = null; gpuW = null }
        }
    }
    onGpuPollRunChanged: {
        if (gpuPollRun) { gpuUtil = null; gpuW = null; gpuFile.reload() }
        else if (!gpuShouldRun) { gpuC = null; gpuUtil = null; gpuW = null }
    }
    // A new command (the profile changed): restart without counting a failure.
    property bool gpuSwitching: false
    onGpuCmdChanged: if (gpuProc.running) { gpuSwitching = true; gpuProc.running = false }
    function num(s) { const n = Number(String(s).trim()); return String(s).trim() !== "" && isFinite(n) ? n : null }
    Process {
        id: gpuProc
        // setpriv: it dies with the shell even when the shell is killed.
        command: ["setpriv", "--pdeathsig", "TERM"].concat(root.gpuCmd)
        stdout: SplitParser {
            onRead: data => {
                const f = String(data).split(",")
                if (f.length < 3) return
                root.gpuC = root.num(f[0]); root.gpuUtil = root.num(f[1]); root.gpuW = root.num(f[2])
            }
        }
        onExited: (code, status) => {
            root.gpuC = null; root.gpuUtil = null; root.gpuW = null
            if (root.gpuSwitching) {
                root.gpuSwitching = false
                if (root.gpuShouldRun) { root.gpuStartedAt = Date.now(); gpuProc.running = true }
                return
            }
            if (!root.gpuShouldRun) return
            if (Date.now() - root.gpuStartedAt < 20000) root.gpuQuickFails += 1
            else root.gpuQuickFails = 0
            if (root.gpuQuickFails >= 3) {
                console.warn("[lumenaire] nvidia-smi keeps exiting (" + code + "); GPU readings off until the plugin reloads")
                root.gpuFailed = true
                return
            }
            gpuRestart.restart()
        }
    }
    Timer {
        id: gpuRestart
        interval: 5000
        onTriggered: if (root.gpuShouldRun && !gpuProc.running) { root.gpuStartedAt = Date.now(); gpuProc.running = true }
    }
    FileView {
        id: gpuFile
        path: root.gpuPath
        printErrors: false
        onLoaded: if (root.gpuPollRun) root.takeGpuFile(text())
        onLoadFailed: if (root.gpuPollRun) { root.gpuC = null; root.sourceLost() }
    }

    Component.onDestruction: stop()
}
