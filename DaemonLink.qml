pragma ComponentBehavior: Bound
// Lumenaire — the one connection to the Lian Li daemon.
//
// The daemon speaks JSON lines on $XDG_RUNTIME_DIR/lianli-daemon.sock: one
// request line in, one reply line out, in order, with no request id. So this
// keeps exactly one request in flight and matches each reply to the method
// that was sent (the FIFO is `current` plus `queue`). Only the four read-only
// methods below are ever sent; the daemon answers those off its main loop
// without the write guard, so polling them cannot starve an apply
// (ipc/server.rs, measured 2026-09-24).
//
//   connect  -> GetDaemonInfo, ListDevices, GetConfig, GetTelemetry
//   every 2 s (1 s while a panel is open)  GetTelemetry; this is also the
//                                          keep-alive: the daemon closes a
//                                          connection idle for 5 s
//   every 30 s                              GetDaemonInfo, ListDevices
//   on demand (requestConfig)               GetConfig
//
//   a reply that times out (3 s) or has the wrong shape -> "stale", drop the
//   connection, reconnect after 2 s, 5 s, then 10 s. A good reply resets it.
//   Every attempt gets a fresh Socket: once a connect has failed, toggling
//   `connected` on the same Socket never tries again (seen 2026-09-24).
//   Leaving "online" clears pump, fans and missing devices (a stale value
//   shows —); coolant keeps its last value and ages instead.
//   three timeouts in a row while systemd says the daemon is active -> the
//   Socket is judged broken and a persistent `socat` Process takes over for
//   the rest of this service's life (logged once).
//
// Everything the views need is parsed here into plain properties; a missing
// value is null, never 0.
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    // ---- inputs (bound by Service) ----------------------------------------
    property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/lianli-daemon.sock"
    property bool fast: false            // a panel is open: poll telemetry at 1 Hz
    property string daemonUnit: ""       // status.daemon_unit, for the socat decision
    property bool enabled: false         // Service flips it on once started

    // ---- link state -------------------------------------------------------
    // connecting | online | stale | offline
    property string linkState: "connecting"
    readonly property bool online: linkState === "online"
    property string transport: "socket"  // socket | socat
    property string version: ""
    property string instanceId: ""
    property int timeoutsInRow: 0
    property int backoffStep: 0
    property bool everOnline: false
    property bool dropping: false        // the disconnect in progress is our own

    // ---- parsed data ------------------------------------------------------
    property var devices: []             // ListDevices .data
    property var config: null           // GetConfig .data
    property var telemetry: null         // GetTelemetry .data
    property var pumpRpm: null
    property var coolantC: null
    property double coolantSeenAt: 0     // ms epoch of the last reading the daemon published
    property var coolantAgeS: null
    readonly property bool coolantStale: coolantAgeS === null || coolantAgeS > 15
    property var fans: []
    property var missingDevices: []
    property var nowPlaying: ({})
    property var alert: null             // {cpu:{enabled,threshold}, gpu:{…}} from GetConfig
    property var lcdCount: null          // {have, want} from ListDevices/GetConfig

    signal configRead()
    signal restarted()                   // instance_id changed: the daemon restarted

    readonly property var allowed: ["GetTelemetry", "ListDevices", "GetDaemonInfo", "GetConfig"]
    property string current: ""          // method whose reply is awaited
    property var queue: []
    property var sock: null              // the Socket of the current attempt

    // Where each device sits in this case, from the engine: status.labels
    // ({device_id: label}, built from the profile's role labels; contract
    // v1.1). pumpDevice is profile.pump_device. Both are empty on v1.0, and
    // labels then fall back to what the daemon itself says (a fan group reads
    // "3-fan LCD group", anything else its device name).
    property var labels: ({})
    property string pumpDevice: ""
    property var seenNames: ({})         // device_id -> fallback label, kept after a device drops out
    function labelFor(id, fallback) {
        const key = String(id || "")
        if (labels && typeof labels[key] === "string" && labels[key]) return labels[key]
        if (fallback) return fallback
        if (seenNames[key]) return seenNames[key]
        const mac = key.replace(/^wireless:/, "").toLowerCase()
        return key.indexOf("wireless:") === 0 ? "Wireless device " + mac : key
    }
    // "3-fan LCD group" from what ListDevices says about a fan group.
    function genericLabel(dev, fanCount) {
        if (!dev) return ""
        const n = Number(dev.fan_count) > 0 ? Number(dev.fan_count) : Number(fanCount) > 0 ? Number(fanCount) : 0
        if (dev.has_fan && n > 0) return n + "-fan " + (/LCD/i.test(String(dev.name || "")) ? "LCD " : "") + "group"
        return String(dev.name || "")
    }
    onLabelsChanged: { rebuildFans(); rebuildMissing() }

    // ---- connection -------------------------------------------------------
    function start() {
        if (!enabled) return
        connect()
    }
    function connect() {
        reconnectTimer.stop()
        current = ""; queue = []
        if (transport === "socat") {
            if (!socatProc.running) socatProc.running = true
            return
        }
        openSocket()
    }
    function openSocket() {
        closeSocket()
        const s = socketComp.createObject(root, { path: root.socketPath })
        if (!s) { console.warn("[lumenaire] could not create the daemon socket"); scheduleReconnect(); return }
        sock = s
        s.connected = true
    }
    // Events from a closed Socket are ignored (it is no longer `sock`).
    function closeSocket() {
        const s = sock
        if (!s) return
        sock = null
        if (s.connected) s.connected = false
        s.destroy()
    }
    function clearLive() {
        pumpRpm = null
        telemetry = null
        fans = []
        missingDevices = []
        nowPlaying = ({})
    }
    function dropConnection(nextState) {
        replyTimer.stop()
        current = ""; queue = []
        linkState = nextState
        clearLive()
        if (transport === "socat" && socatProc.running) { dropping = true; socatProc.signal(15) }
        else if (transport === "socket") closeSocket()
        scheduleReconnect()
    }
    function scheduleReconnect() {
        if (!enabled || reconnectTimer.running) return
        const steps = [2000, 5000, 10000]
        reconnectTimer.interval = steps[Math.min(backoffStep, steps.length - 1)]
        backoffStep += 1
        reconnectTimer.start()
    }
    // Service calls this when systemd reports the daemon active again or on a
    // manual refresh: skip the remaining backoff.
    function poke() {
        if (!enabled) return
        backoffStep = 0
        if (linkState === "online") return
        reconnectTimer.stop()
        connect()
    }
    function onLinkUp() {
        request("GetDaemonInfo"); request("ListDevices"); request("GetConfig"); request("GetTelemetry")
    }
    function onLinkDown() {
        replyTimer.stop()
        current = ""; queue = []
        if (dropping) dropping = false
        else linkState = "offline"
        clearLive()
        scheduleReconnect()
    }

    // ---- request FIFO -----------------------------------------------------
    function request(method) {
        if (allowed.indexOf(method) < 0) { console.warn("[lumenaire] refusing daemon method " + method); return }
        if (!linkUp()) return
        if (current === method || queue.indexOf(method) >= 0) return
        queue = queue.concat([method])
        pump()
    }
    function requestConfig() { request("GetConfig") }
    function linkUp() { return transport === "socat" ? socatProc.running : (sock !== null && sock.connected) }
    function pump() {
        if (current !== "" || queue.length === 0 || !linkUp()) return
        const method = queue[0]
        queue = queue.slice(1)
        current = method
        const line = JSON.stringify({ method: method }) + "\n"
        if (transport === "socat") {
            socatProc.write(line)
        } else {
            sock.write(line)
            sock.flush()
        }
        replyTimer.restart()
    }
    function receive(line) {
        if (!line || !String(line).trim()) return
        const method = current
        if (method === "") { console.warn("[lumenaire] unexpected daemon reply dropped"); return }
        let reply = null
        try { reply = JSON.parse(line) } catch (e) { reply = null }
        if (!reply || typeof reply !== "object") { staleReply(method, "unparsable reply"); return }
        if (reply.status === "error") {
            // A real answer, just not a useful one: keep the link.
            console.warn("[lumenaire] daemon " + method + ": " + reply.message)
            accepted()
            return
        }
        const d = reply.data
        const ok = method === "GetTelemetry" ? d && typeof d.fan_rpms === "object" && d.fan_rpms !== null
                 : method === "ListDevices" ? Array.isArray(d)
                 : method === "GetDaemonInfo" ? d && d.instance_id !== undefined
                 : method === "GetConfig" ? d && Array.isArray(d.lcds)
                 : false
        if (!ok) { staleReply(method, "reply without the expected shape"); return }
        if (method === "GetTelemetry") takeTelemetry(d)
        else if (method === "ListDevices") takeDevices(d)
        else if (method === "GetDaemonInfo") takeInfo(d)
        else if (method === "GetConfig") takeConfig(d)
        accepted()
    }
    function accepted() {
        replyTimer.stop()
        current = ""
        timeoutsInRow = 0
        backoffStep = 0
        everOnline = true
        linkState = "online"
        pump()
    }
    function staleReply(method, why) {
        console.warn("[lumenaire] daemon " + method + ": " + why + ", reconnecting")
        dropConnection("stale")
    }

    // ---- parsing ----------------------------------------------------------
    function pumpId() {
        if (pumpDevice) return pumpDevice
        const p = (devices || []).find(x => x && x.has_pump)
        return p ? p.device_id : null
    }
    function takeTelemetry(d) {
        telemetry = d
        const rpms = d.fan_rpms || {}
        const pid = pumpId()
        let pr = pid ? rpms[pid] : null
        pumpRpm = Array.isArray(pr) && pr.length ? Number(pr[pr.length - 1]) : null
        // The daemon drops the coolant key once its reading is 5 s old, which
        // is normal flapping; keep the last value and let its age speak.
        const temps = d.coolant_temps || {}
        let c = pid && temps[pid] !== undefined ? temps[pid] : null
        if (c === null && !pid) { const k = Object.keys(temps); if (k.length) c = temps[k[0]] }
        if (c !== null && c !== undefined && isFinite(Number(c))) {
            coolantC = Number(c)
            coolantSeenAt = Date.now()
        }
        coolantAgeS = coolantSeenAt > 0 ? Math.max(0, Math.floor((Date.now() - coolantSeenAt) / 1000)) : null
        rebuildFans()
    }
    function takeDevices(d) {
        devices = d
        const names = Object.assign({}, seenNames)
        for (const dev of d) if (dev && dev.device_id) names[String(dev.device_id)] = genericLabel(dev, 0)
        seenNames = names
        rebuildFans()
        rebuildMissing()
        rebuildNowPlaying()
    }
    function takeInfo(d) {
        version = d.version !== undefined && d.version !== null ? String(d.version) : ""
        const id = String(d.instance_id)
        const restartedNow = instanceId !== "" && id !== instanceId
        instanceId = id
        if (restartedNow) {
            console.warn("[lumenaire] daemon restarted (instance " + id + ")")
            request("ListDevices"); request("GetConfig")
            restarted()
        }
    }
    function takeConfig(d) {
        config = d
        const ta = d.thermal_alert
        if (ta && typeof ta === "object") {
            const one = x => x && typeof x === "object"
                ? { enabled: x.enabled !== false, threshold: isFinite(Number(x.threshold)) ? Number(x.threshold) : null } : null
            alert = { cpu: one(ta.cpu), gpu: one(ta.gpu) }
        } else {
            alert = null
        }
        rebuildMissing()
        rebuildNowPlaying()
        configRead()
    }
    function rebuildFans() {
        const rpms = telemetry && telemetry.fan_rpms ? telemetry.fan_rpms : {}
        let list = []
        if (devices && devices.length) {
            for (const dev of devices) {
                if (!dev || dev.family !== "Tlv2Led" || dev.wireless_group_mac) continue
                const id = String(dev.device_id || "")
                if (id.indexOf("wireless:") !== 0) continue
                const r = rpms[id]
                if (!Array.isArray(r) || !r.length) continue
                list.push(fanEntry(id, labelFor(id, genericLabel(dev, r.length)), r))
            }
        } else {
            for (const id of Object.keys(rpms)) {
                const r = rpms[id]
                if (id.indexOf("wireless:") !== 0 || !Array.isArray(r) || !r.length) continue
                list.push(fanEntry(id, labelFor(id, r.length + "-fan group"), r))
            }
        }
        // Two groups the daemon names alike: number the repeats.
        const seen = {}
        for (const f of list) {
            seen[f.label] = (seen[f.label] || 0) + 1
            if (seen[f.label] > 1) f.label = f.label + " " + seen[f.label]
        }
        fans = list
    }
    function fanEntry(id, label, r) {
        const nums = r.map(Number)
        return { id: id, label: label, rpms: nums, avg: Math.round(nums.reduce((a, b) => a + b, 0) / nums.length) }
    }
    function rebuildMissing() {
        const rgb = config && config.rgb && Array.isArray(config.rgb.devices) ? config.rgb.devices : []
        if (!devices || !devices.length) { missingDevices = []; return }
        const present = {}
        for (const dev of devices) if (dev && dev.device_id) present[dev.device_id] = true
        let list = []
        for (const e of rgb) {
            const id = e && typeof e === "object" ? String(e.device_id || "") : String(e || "")
            if (id.indexOf("wireless:") !== 0 || present[id]) continue
            list.push({ id: id, label: labelFor(id, "") })
        }
        missingDevices = list
        const lcds = config && Array.isArray(config.lcds) ? config.lcds.length : null
        const have = devices.filter(x => x && x.has_lcd).length
        lcdCount = lcds === null ? null : { have: have, want: lcds }
    }
    // GetConfig keys LCDs by the daemon's device id ("hid:1cbe:a068:…"); the
    // engine's rotation keys them by USB serial ("a1a1a1a100000006"). Publish
    // both keys so a view can look up either one.
    function rebuildNowPlaying() {
        const lcds = config && Array.isArray(config.lcds) ? config.lcds : []
        let map = {}
        for (const l of lcds) {
            if (!l || !l.serial || !l.path) continue
            const base = String(l.path).split("/").pop()
            map[l.serial] = base
            const dev = (devices || []).find(x => x && (x.device_id === l.serial || "serial:" + x.device_id === l.serial))
            if (dev && dev.serial) map[dev.serial] = base
        }
        nowPlaying = map
    }

    // ---- transports -------------------------------------------------------
    Component {
        id: socketComp
        Socket {
            id: s
            parser: SplitParser { onRead: data => { if (s === root.sock) root.receive(data) } }
            onConnectionStateChanged: {
                if (s !== root.sock || root.transport !== "socket") return
                if (s.connected) root.onLinkUp()
                else root.onLinkDown()
            }
            onError: err => {
                if (s !== root.sock || root.transport !== "socket") return
                // Connect failures arrive here without a state change; a peer
                // close also changes the state, which already scheduled a retry.
                if (!s.connected && !reconnectTimer.running) root.onLinkDown()
            }
        }
    }

    Process {
        id: socatProc
        command: ["socat", "-", "UNIX-CONNECT:" + root.socketPath]
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.receive(data) }
        onRunningChanged: if (running && root.transport === "socat") root.onLinkUp()
        onExited: (code, status) => { if (root.transport === "socat") root.onLinkDown() }
    }

    Timer {
        id: replyTimer
        interval: 3000
        onTriggered: {
            root.timeoutsInRow += 1
            console.warn("[lumenaire] daemon " + root.current + " timed out (" + root.timeoutsInRow + " in a row)")
            if (root.transport === "socket" && root.timeoutsInRow >= 3 && root.daemonUnit === "active") {
                // The Socket says connected yet nothing comes back while systemd
                // says the daemon is fine: stop trusting the Socket.
                console.warn("[lumenaire] socket link keeps timing out; switching to socat for this session")
                root.transport = "socat"
                root.closeSocket()
                root.timeoutsInRow = 0
                root.backoffStep = 0
                root.linkState = "stale"
                root.connect()
                return
            }
            root.dropConnection("stale")
        }
    }
    Timer {
        id: reconnectTimer
        onTriggered: root.connect()
    }
    Timer {
        interval: root.fast ? 1000 : 2000
        repeat: true
        running: root.enabled
        onTriggered: {
            // Age the last coolant reading even while no reply comes back.
            if (root.coolantSeenAt > 0) root.coolantAgeS = Math.max(0, Math.floor((Date.now() - root.coolantSeenAt) / 1000))
            root.request("GetTelemetry")
        }
    }
    Timer {
        interval: 30000
        repeat: true
        running: root.enabled
        onTriggered: { root.request("GetDaemonInfo"); root.request("ListDevices") }
    }

    function stop() {
        enabled = false
        reconnectTimer.stop()
        replyTimer.stop()
        closeSocket()
        if (socatProc.running) socatProc.signal(15)
    }
    Component.onDestruction: stop()
}
