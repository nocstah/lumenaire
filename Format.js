.pragma library
// Number and time formats shared by the bar widget and the panel. Every
// function takes a missing value (null/undefined/NaN) and returns "—", so a
// view never prints "0" for a reading it does not have.
//
// Thousands are grouped with a space, "2 548 RPM", so four-digit RPMs read
// at a glance without a comma that could pass for a decimal separator. The
// spec asked for a thin space (U+2009), but JetBrainsMono Nerd Font (the
// host's monospace alias) has no U+2009 or U+202F glyph and the offscreen
// renders showed "2548". A no-break space (U+00A0, covered) is one cell wide
// in a monospace face and never wraps.

const THIN = "\u00a0"
const DASH = "—"

function missing(v) { return v === null || v === undefined || (typeof v === "number" && isNaN(v)) || v === "" }

// 2548 -> "2 548"
function group(n) {
    if (missing(n)) return DASH
    const s = String(Math.round(Math.abs(Number(n))))
    let out = ""
    for (let i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 === 0) out += THIN
        out += s[i]
    }
    return (Number(n) < 0 ? "-" : "") + out
}

// 2548 -> "2 548 RPM"
function rpm(n) { return missing(n) ? DASH : group(n) + " RPM" }

// 2548 -> "2.5k", 980 -> "980"
function rpmShort(n) {
    if (missing(n)) return DASH
    const v = Number(n)
    return v >= 1000 ? (Math.round(v / 100) / 10).toFixed(1) + "k" : String(Math.round(v))
}

// A bare number with fixed decimals: fixed(33, 1) -> "33.0"
function fixed(v, decimals) {
    if (missing(v)) return DASH
    return Number(v).toFixed(decimals === undefined ? 0 : decimals)
}

// 33 -> "33.0 °C" with decimals 1, "33 °C" with 0
function tempC(v, decimals) { return missing(v) ? DASH : fixed(v, decimals) + " °C" }

// 244 -> "4:04"
function mmss(s) {
    if (missing(s)) return DASH
    const t = Math.max(0, Math.round(Number(s)))
    const m = Math.floor(t / 60), r = t % 60
    return m + ":" + (r < 10 ? "0" : "") + r
}

// 8 -> "8 s ago", 190 -> "3 min ago", 7300 -> "2 h ago"
function ago(s) {
    if (missing(s)) return DASH
    const t = Math.max(0, Math.round(Number(s)))
    if (t < 60) return t + " s ago"
    if (t < 3600) return Math.round(t / 60) + " min ago"
    return Math.round(t / 3600) + " h ago"
}

// "2026-09-25T00:00" or "00:00" -> "00:00"
function clock(v) {
    if (missing(v)) return DASH
    const m = String(v).match(/(\d{1,2}:\d{2})(?::\d{2})?$/)
    return m ? m[1] : String(v)
}

// Epoch seconds -> local "14:02"
function hhmm(epoch) {
    if (missing(epoch)) return DASH
    const d = new Date(Number(epoch) * 1000)
    const h = d.getHours(), m = d.getMinutes()
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// Theme folder name -> display name. "gilded-noir" -> "Gilded Noir";
// generated "omarchy-oxblood-parchment" -> "Oxblood Parchment" (the
// "Generated from Omarchy" header already says where it came from).
function themeName(name) {
    if (missing(name)) return ""
    return String(name).replace(/^omarchy-/, "").split(/[-_]/).filter(w => w.length > 0)
        .map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ")
}

// Engine step -> display words: "openrgb" -> "OpenRGB".
function step(s) {
    const names = { "openrgb": "OpenRGB", "lian li": "Lian Li", "waiting": "waiting",
                    "retrying wireless": "retrying wireless", "restarting daemon": "restarting the daemon",
                    "screens": "screens" }
    return missing(s) ? "" : (names[s] || String(s))
}

// "HydroShift II OLED Curve pump" -> "Pump"; other screens keep their name.
function screenName(where) {
    if (missing(where)) return "Screen"
    return /pump/i.test(where) ? "Pump" : String(where)
}

// ---- engine ops -----------------------------------------------------------
// Shared by EngineState (notices) and the views' fixtures, so the header, the
// bar tooltip and the notice line name an op the same way.

// Engine op -> the control it belongs to: theme | lights | screens |
// schedule | clips | detect | "".
function kindOf(op, target) {
    if (["pick", "switch", "scheme", "schedule-tick"].indexOf(op) >= 0) return "theme"
    if (op === "on" || op === "off") return target === "screens" ? "screens" : "lights"
    if (op === "schedule" || op === "schedule-set") return "schedule"
    if (op === "clips" || op === "clips-next") return "clips"
    if (op === "apply-openrgb") return "lights"
    if (op === "detect") return "detect"
    return ""
}

function powerWhat(target) { return target === "all" ? "lights and screens" : target === "screens" ? "screens" : "lights" }

// A running op as a phrase: "Applying Hellfire", "Turning lights off",
// "Skipping to the next clip" (ing), or "Apply Hellfire", "Turn lights off".
function opPhrase(op, target, theme, ing) {
    const kind = kindOf(op, target)
    if (kind === "theme") return (ing ? "Applying " : "Apply ") + themeName(theme)
    if (op === "on" || op === "off") return (ing ? "Turning " : "Turn ") + powerWhat(target) + " " + op
    if (op === "schedule" || op === "schedule-set") return (ing ? "Turning " : "Turn ") + "the night schedule " + (target || "")
    if (op === "clips" || op === "clips-next") return ing ? "Skipping to the next clip" : "Skip the clip"
    if (op === "apply-openrgb") return ing ? "Applying OpenRGB" : "Apply OpenRGB"
    if (op === "detect") return ing ? "Detecting hardware" : "Detect hardware"
    return (ing ? "Running " : "Run ") + String(op || "a change")
}

// A waiting op as a short noun phrase for "Queued · …": "Hellfire",
// "Lights off", "Next clip", "Night schedule on".
function opShort(op, target, theme) {
    const kind = kindOf(op, target)
    if (kind === "theme") return themeName(theme)
    if (op === "on" || op === "off") { const w = powerWhat(target); return w.charAt(0).toUpperCase() + w.slice(1) + " " + op }
    if (op === "schedule" || op === "schedule-set") return "Night schedule " + (target || "")
    if (op === "clips" || op === "clips-next") return "Next clip"
    if (op === "apply-openrgb") return "OpenRGB"
    if (op === "detect") return "Hardware detect"
    return String(op || "")
}

// A reading at or over a daemon thermal alert ({enabled, threshold}); a
// disabled alert or one without a numeric threshold never fires.
function overAlert(v, a) {
    if (missing(v) || !a || a.enabled === false) return false
    if (a.threshold === null || a.threshold === undefined || a.threshold === "" || !isFinite(Number(a.threshold))) return false
    return Number(v) >= Number(a.threshold)
}

// ---- hardware profile (status --json v1.1) --------------------------------
// Contract v1.0 has no `profile`: every helper below then answers the way the
// plugin behaved before profiles (this machine's hardware), so an old engine
// keeps the old panel. Shared by Service and tests/FakeService.qml.

// A JSON array, or a list QML handed over as a sequence (a Repeater's
// modelData converts nested arrays): a plain array, or null.
function list(x) {
    if (Array.isArray(x)) return x
    if (x && typeof x === "object" && typeof x.length === "number") return Array.prototype.slice.call(x)
    return null
}

function profileOf(status) {
    return status && status.profile && typeof status.profile === "object" && !Array.isArray(status.profile) ? status.profile : null
}
// A profile whose facts can be trusted (not missing or unreadable).
function profileUsable(p) { return !!p && p.state !== "missing" && p.state !== "invalid" }

// Is a backend known to be off on this PC? {state, enabled, devices} (a bare
// state string also works). "down" (installed, not running) is not off: the
// panel still says the daemon is offline. A missing or invalid profile has
// backends {}, so nothing is off.
function backendOff(p, name) {
    const b = p && p.backends && typeof p.backends === "object" ? p.backends[name] : null
    if (!b) return false
    if (typeof b === "object" && b.enabled === false) return true
    const st = typeof b === "object" ? b.state : b
    return ["absent", "disabled", "no-devices"].indexOf(String(st)) >= 0
}

// sensors --json found no Lian Li gear at all (coolant and pump both null).
function noLianliGear(sources) {
    return !!sources && Number(sources.v) === 1 && sources.pump === null && sources.coolant === null
}

// Pump and coolant readings exist. sensors --json says none (coolant and
// pump both null: no Lian Li gear) -> no; a usable profile knows its pump
// device (null = none); else a daemon device with has_pump; else (nothing
// known yet, contract v1.0) yes.
function hasPump(p, devices, sources) {
    if (noLianliGear(sources)) return false
    if (profileUsable(p) && p.pump_device !== undefined) return !!p.pump_device
    if (backendOff(p, "lianli")) return false
    const devs = list(devices)
    if (devs && devs.length > 0) return devs.some(d => d && d.has_pump)
    return true
}

// The Lights row detail, from profile.groups: "Fans, Strimers, pump ring,
// GPU, board, RAM". null = nothing to light (the row hides).
function legacyGroups() { return "Fans, Strimers, pump ring, GPU, board, RAM" }
function powerDetail(p, pump) {
    if (!p) return legacyGroups()
    // No profile yet: the engine drives whatever it finds, name nothing.
    if (!profileUsable(p)) return "Case and PC lighting"
    const groups = list(p.groups)
    if (!groups) return "Case and PC lighting"
    if (groups.length === 0) return null
    const names = { fans: "fans", strimers: "Strimers", rings: pump ? "pump ring" : "rings", gpu: "GPU", board: "board",
                    ram: "RAM", peripherals: "peripherals", keyboard: "keyboard", mouse: "mouse", mousepad: "mousepad",
                    headset: "headset", ledstrips: "LED strips" }
    const words = groups.map(g => names[g] || String(g).replace(/[._-]+/g, " "))
    const text = words.join(", ")
    return text.charAt(0).toUpperCase() + text.slice(1)
}

// How many LCDs this PC expects: status.screens_on_usb.want (the engine
// takes it from the profile, else config.lcds, else 7), else
// profile.screens, else the daemon's count. null = unknown. Without a usable
// profile the daemon's own count (GetConfig lcds) wins over the engine's
// guess, whose last resort is this author's 7.
function screensWant(status, lcdCount) {
    const pr = profileOf(status)
    const known = x => x && x.want !== null && x.want !== undefined && isFinite(Number(x.want))
    if (pr && !profileUsable(pr) && known(lcdCount)) return Number(lcdCount.want)
    const u = status && status.screens_on_usb ? status.screens_on_usb : null
    if (u && u.want !== null && u.want !== undefined && isFinite(Number(u.want))) return Number(u.want)
    const p = profileOf(status)
    if (p && p.screens !== null && p.screens !== undefined && isFinite(Number(p.screens))) return Number(p.screens)
    if (lcdCount && lcdCount.want !== null && lcdCount.want !== undefined && isFinite(Number(lcdCount.want))) return Number(lcdCount.want)
    return null
}
// 7 -> "7 LCDs", 1 -> "1 LCD", unknown -> "LCD screens"
function lcds(n) { return missing(n) ? "LCD screens" : n + (Number(n) === 1 ? " LCD" : " LCDs") }

// The one notice a profile asks for, or null: {key, text, level, actions}.
function profileNotice(p) {
    if (!p) return null
    if (p.state === "missing")
        return { key: "profile-missing", text: "No hardware profile yet. Detect your devices (about 20 s).", level: "info", actions: ["detect"] }
    if (p.state === "invalid")
        return { key: "profile-invalid", text: "The hardware profile can't be read. Detect again to rebuild it.", level: "urgent", actions: ["detect", "log"] }
    if (p.state === "stale") {
        const nd = list(p.new_devices)
        const n = nd ? nd.length : 0
        return { key: "profile-stale:" + n, level: "info", actions: ["detect", "dismiss"],
                 text: n === 1 ? "1 new device. Detect again to use it." : n > 1 ? n + " new devices. Detect again to use them."
                     : "The hardware changed. Detect again." }
    }
    return null
}

// A profile role in words: "screen.pump" -> "Pump screen".
function roleName(role) {
    const r = String(role || "")
    const fixed = { "screen.pump": "Pump screen", "screen.main": "Main screen", "pump.ring": "Pump ring",
                    "pump.logo": "Pump logo", "screen.main.ring": "Screen ring", "strimer.atx24": "24-pin Strimer",
                    "strimer.gpu": "GPU Strimer", gpu: "GPU", board: "Board", "board.argb": "Board ARGB headers", ram: "RAM" }
    if (fixed[r]) return fixed[r]
    let m = r.match(/^screen\.fan(\d+)$/)
    if (m) return "Fan screen " + m[1]
    m = r.match(/^screen\.aux(\d+)$/)
    if (m) return "Screen " + m[1]
    m = r.match(/^fans\.(.+)$/)
    if (m) return /^\d+$/.test(m[1]) ? "Fan group " + m[1] : m[1].charAt(0).toUpperCase() + m[1].slice(1) + " fans"
    m = r.match(/^strimer\.(.+)$/)
    if (m) return "Strimer " + m[1]
    return r.charAt(0).toUpperCase() + r.slice(1).replace(/[._]/g, " ")
}
function listWords(items) {
    if (items.length <= 1) return items.join("")
    return items.slice(0, -1).join(", ") + " and " + items[items.length - 1]
}

// A theme card's compatibility chip from themes --json `coverage`, or null
// when the theme fits (or the engine predates coverage): {text, tip}.
function coverageChip(cov) {
    if (!cov || typeof cov !== "object" || !cov.summary || cov.summary === "full") return null
    const roles = cov.roles && typeof cov.roles === "object" ? cov.roles : {}
    const none = Object.keys(roles).filter(r => roles[r] === "none")
    const screens = none.filter(r => /^screen\./.test(r))
    const missingRoles = (list(cov.missing) || []).map(String)
    const c = cov.counts || {}
    const total = Number(c.total)
    const unfit = isFinite(Number(c.none)) ? Number(c.none) : none.length
    let tip = []
    if (none.length) tip.push(listWords(none.map(roleName)) + (none.length === 1 ? " keeps" : " keep") + " what " + (none.length === 1 ? "it shows" : "they show") + " now.")
    if (missingRoles.length) tip.push("Made for " + listWords(missingRoles.map(roleName)) + ", not on this PC.")
    let text = ""
    if (cov.summary === "foreign") {
        text = "For another PC"
        tip.unshift("Its screen media is tied to another PC's screens; the LED colours still apply.")
    } else if (cov.summary === "leds-only") {
        text = "LEDs only"
        tip.unshift("No screen media fits this PC; only the LED colours change.")
    } else if (none.length === 1 && screens.length === 1) {
        // One line in a 3-column grid holds about 16 characters.
        text = screens[0] === "screen.pump" ? "Skips pump media" : screens[0] === "screen.main" ? "Skips main screen"
             : isFinite(total) && total > 0 ? "Fits " + Math.max(0, total - unfit) + "/" + total + " roles" : "Skips " + roleName(screens[0]).toLowerCase()
    } else if (isFinite(total) && total > 0) {
        text = "Fits " + Math.max(0, total - unfit) + "/" + total + " roles"
    } else {
        text = "Partial fit"
    }
    return { text: text, tip: tip.join(" ") }
}

// ---- theme editor (contract v1.2) --------------------------------------------
// Labels for the editor page; the engine's editor view (theme show --json)
// supplies the values, these only put words to its codes.

// Field source -> chip text: "Palette", "Group" or "Custom".
function sourceLabel(src) {
    return src === "role" || src === "theme" || src === "custom" ? "Custom" : src === "group" ? "Group" : src === "palette" ? "Palette" : ""
}

// Palette keys in words.
function paletteLabel(k) {
    return ({ primary: "Primary", secondary: "Secondary", accent: "Accent", alert: "Alert" })[k] || String(k || "")
}

// Palette keys as the editor names them: the three theme colours and the
// heat warning.
function colourRole(k) {
    return ({ primary: "Main", secondary: "Second", accent: "Accent", alert: "Heat warning" })[k] || String(k || "")
}

// A role group in words: "fans" -> "All fans".
function groupLabel(g) {
    return ({ fans: "All fans", strimers: "All Strimers", rings: "All rings" })[g] || "All " + String(g || "")
}

// An editor field in words: fan "inner"/"outer", a Strimer's parts.
function fieldLabel(f) {
    return ({ inner: "Inner", outer: "Outer", colour: "Colour", mode: "Effect", speed: "Speed", direction: "Direction",
              colors: "Colours", stops: "Stops", span: "Span" })[f] || String(f || "")
}

// Calibration class -> where the LEDs sit, for "LEDs show … (fan frames)".
function classPlace(cls) {
    return ({ tl_fan: "fan frames", fan: "fans", strimer: "Strimers", ring: "rings", gpu: "GPU", board: "board",
              ram: "RAM", peripheral: "peripherals" })[cls] || ""
}

// Why a theme can't be edited (themes --json edit_block, or canEdit()).
function editBlockText(block) {
    if (block === "v2") return "This theme uses the old format. Migrate your themes to edit it."
    if (block === "no-profile") return "Editing needs a hardware profile. Detect your hardware, then migrate the themes."
    if (block === "engine") return "This engine can't edit themes yet. Update Lumenaire."
    return ""
}
// The short chip on a blocked card in edit mode.
function editBlockChip(block) {
    return block === "v2" ? "Migrate to edit" : block === "no-profile" ? "Needs a profile" : block === "engine" ? "Can't edit" : ""
}

// A new theme name, checked the way the engine checks it. "" = fine.
// names: every existing theme and draft name.
function nameProblem(name, names) {
    const n = String(name || "")
    if (n === "") return "Give it a name"
    if (/^omarchy-/.test(n)) return "omarchy- is kept for generated themes"
    if (!/^[a-z0-9][a-z0-9._-]{0,47}$/.test(n)) return n.length > 48 ? "48 characters at most" : "Use a-z, 0-9, . _ -"
    if ((names || []).indexOf(n) >= 0) return "Taken"
    return ""
}
// The first free "<base>-2", "<base>-3", ... (keepBase: "<base>" itself first).
function freeName(base, names, keepBase) {
    const b = String(base || "theme").replace(/^omarchy-/, "").replace(/-\d+$/, "") || "theme"
    if (keepBase && (names || []).indexOf(b) < 0) return b
    for (let i = 2; i < 1000; i++) if ((names || []).indexOf(b + "-" + i) < 0) return b + "-" + i
    return b + "-" + Date.now()
}

// The editor's "Show on case" status (plan §2.2), from preview.json plus the
// Service's local countdowns: one short line, its level, the one action it
// offers ("" | "keep" | "again" | "copy") and a tooltip with the detail.
function previewStatus(p, o) {
    // o: {enabled, countdown, idleLeft, lightsOn, theme, busyLabel, unmeasured, command, editing}
    const out = (text, level, action, tip) => ({ text: text, level: level || "", action: action || "", tip: tip || "" })
    if (!o.lightsOn) return out("Lights are off", "", "", "Turn the lights on to see your changes on the case.")
    if (o.unmeasured) return out("Needs a one-time hardware check", "", "copy",
        "Run this once in a terminal, then your changes show on the case as you make them:\n" + (o.command || ""))
    if (!o.enabled) return out("Off", "", "", "Your changes show on the case after you save.")
    const st = p && p.state ? String(p.state) : ""
    if (st === "ended" || st === "failed" || st === "cancelled") {
        const e = p.ended || {}
        const by = e.by && e.by.op ? e.by : null
        if (st === "failed") return out("Couldn't show it", "urgent", "again", p.error ? String(p.error).replace(/[.\s]+$/, "") + "." : "")
        if (e.reason === "saved") return out("Saved")
        if (e.reason === "reverted") return out("Showing the saved look", "", "again")
        const tip = "Your changes are kept."
        if (e.reason === "cancelled" && by) {
            const why = by.op === "schedule-tick" ? "Stopped by the night theme"
                : by.op === "switch" ? "Stopped by an Omarchy theme change"
                : kindOf(by.op, "") === "theme" ? "Stopped: " + themeName(by.theme) + " was applied" : "Stopped by another change"
            return out(why, "", "again", tip)
        }
        if (e.reason === "idle") return out("Stopped after a quiet spell", "", "again", tip)
        if (e.reason === "lights-off") return out("Stopped: the lights went off", "", "again", tip)
        if (e.reason === "screens-off") return out("Stopped: the screens went off", "", "again", tip)
        if (e.reason === "ui-gone" || e.reason === "panel-closed") return out("Stopped when the panel closed", "", "again", tip)
        return out("Stopped", "", "again", tip)
    }
    if (o.countdown >= 0) return out("Updating…")
    if (st === "blocked") {
        const b = p.blocked_by
        if (b === "heat-alert") return out("Paused: heat warning is on", "", "", "It carries on when the heat warning ends.")
        if (b === "rgb-sync") return out("Paused: RGB sync is on", "", "", "Turn off RGB sync in the Lian Li daemon to preview.")
        if (b === "invalid") return out("Paused: fix the problems first")
        const what = b && typeof b === "object" && b.op ? opPhrase(b.op, b.target || "", b.theme, true) : (o.busyLabel || "another change")
        const theme = b && typeof b === "object" && b.theme && kindOf(b.op, b.target || "") === "theme" ? themeName(b.theme) : ""
        return out(theme ? "Paused while " + theme + " applies" : "Paused for a moment", "", "", "Waiting: " + what + "…")
    }
    if (st === "queued" || st === "applying") return out("Updating…")
    if (st === "live") {
        if (o.idleLeft >= 0 && o.idleLeft <= 60) return out("Stops in " + mmss(o.idleLeft), "", "keep", "No changes for a while: the case goes back to the saved look.")
        const failed = p.lianli && Array.isArray(p.lianli.failed) ? p.lianli.failed.length : 0
        const orgb = p.openrgb && (p.openrgb.state === "pending" || p.openrgb.state === "applying")
        const tips = ["Your changes show on the case; nothing is saved yet."]
        if (orgb) tips.push("GPU, motherboard and RAM catch up in a few seconds.")
        if (failed) tips.push(failed + (failed === 1 ? " device missed it." : " devices missed it."))
        return out("Live", "", "", tips.join(" "))
    }
    return out(o.editing ? "Updating…" : "On", "", "", "Your changes show on the case as you make them.")
}

// ---- editor drafts: RFC 6901 pointers and the §1.2 patch subset -----------
// The Service applies edits to its optimistic copy of the draft the way the
// engine will (theme set), so the view never waits for a round trip.
function ptrTokens(path) {
    if (!path || path === "/") return []
    return String(path).replace(/^\//, "").split("/").map(t => t.replace(/~1/g, "/").replace(/~0/g, "~"))
}
function ptrEscape(token) { return String(token).replace(/~/g, "~0").replace(/\//g, "~1") }
// The value at a pointer, or undefined.
function ptrGet(obj, path) {
    let cur = obj
    for (const t of ptrTokens(path)) {
        if (cur === null || cur === undefined || typeof cur !== "object") return undefined
        cur = Array.isArray(cur) ? cur[Number(t)] : cur[t]
    }
    return cur
}
function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)) }
// Drop empty objects (and empty "roles") after an edit, as theme set does.
function prune(obj) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return obj
    for (const k of Object.keys(obj)) {
        const v = obj[k]
        if (v && typeof v === "object" && !Array.isArray(v)) {
            prune(v)
            if (Object.keys(v).length === 0) delete obj[k]
        }
    }
    return obj
}
// A role-alias pointer ("/screens/@screen.fan3/brightness", plan §4.2): the
// engine resolves it against the draft when it applies it (list targets are
// dealt out first), so the optimistic copy leaves it alone.
function isAliasPtr(path) { return ptrTokens(path).some(t => t.charAt(0) === "@") }
// Apply [{op: add|replace|remove, path, value}] to a copy of obj.
function applyOps(obj, ops) {
    const root = clone(obj) || {}
    for (const o of ops || []) {
        const toks = ptrTokens(o.path)
        if (toks.length === 0 || isAliasPtr(o.path)) continue
        let cur = root
        for (let i = 0; i < toks.length - 1; i++) {
            const t = toks[i]
            const key = Array.isArray(cur) ? Number(t) : t
            if (cur[key] === null || cur[key] === undefined || typeof cur[key] !== "object") {
                if (o.op === "remove") { cur = null; break }
                cur[key] = /^\d+$/.test(toks[i + 1]) ? [] : {}
            }
            cur = cur[key]
        }
        if (cur === null) continue
        const last = toks[toks.length - 1]
        if (o.op === "remove") {
            if (Array.isArray(cur)) cur.splice(Number(last), 1)
            else delete cur[last]
        } else if (Array.isArray(cur)) {
            if (last === "-") cur.push(clone(o.value))
            else if (o.op === "add") cur.splice(Number(last), 0, clone(o.value))
            else cur[Number(last)] = clone(o.value)
        } else {
            cur[last] = clone(o.value)
        }
    }
    return prune(root)
}
// The op theme set expects for "set this value" (null = remove): "replace"
// on an array element, else "add" (creates or overwrites a member).
function setOp(path, value) {
    if (value === null || value === undefined) return { op: "remove", path: path }
    const toks = ptrTokens(path)
    return { op: /^\d+$/.test(toks[toks.length - 1] || "") ? "replace" : "add", path: path, value: value }
}
// Queue an op, dropping earlier ops it overwrites (the same path or below).
function queueOp(queue, op) {
    const p = String(op.path)
    return (queue || []).filter(q => q.path !== p && String(q.path).indexOf(p + "/") !== 0).concat([op])
}
// A lian-li-linux RgbMode in words: "ColorCycle" -> "Color cycle".
function modeLabel(m) {
    const s = String(m || "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/([A-Z])([A-Z][a-z])/g, "$1 $2")
    return s.charAt(0) + s.slice(1).toLowerCase()
}

// ---- names you type (New theme, Rename, Save as copy) ----------------------
// A name as typed -> the engine's name: lower case, accents dropped, spaces to
// "-", anything else outside a-z 0-9 . _ - dropped, repeated dashes folded,
// no separator at either end, 48 characters at most. "Neon Cyan" -> "neon-cyan".
function slugify(text) {
    let s = String(text || "").toLowerCase()
    if (typeof s.normalize === "function") s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    s = s.replace(/\s+/g, "-").replace(/[^a-z0-9._-]/g, "").replace(/-{2,}/g, "-").replace(/^[^a-z0-9]+/, "")
    return s.slice(0, 48).replace(/[-._]+$/, "")
}
// The first "<name> 2", "<name> 3", ... (as typed) whose engine name is free.
function nextFree(display, names) {
    const base = String(display || "").trim().replace(/\s+\d+$/, "") || "Theme"
    for (let i = 2; i < 1000; i++) {
        const d = base + " " + i
        if ((names || []).indexOf(slugify(d)) < 0) return d
    }
    return base + " " + Date.now()
}
// A name as typed that is free, else the next free variant.
function freeDisplay(display, names) {
    const d = String(display || "").trim()
    return d && (names || []).indexOf(slugify(d)) < 0 ? d : nextFree(d, names)
}
// What's wrong with a typed name, in words, with a fix to offer: null when it
// is fine (or unchanged: `current` is the theme's own name), {text: ""} when
// it is empty (no hint, the action just waits).
function nameIssue(display, names, current) {
    const shown = String(display || "").trim()
    if (shown === "") return { text: "", fix: "" }
    const slug = slugify(shown)
    if (slug === "") return { text: "Use letters or numbers.", fix: "" }
    if (current && slug === current) return null
    if (/^omarchy(-|$)/.test(slug)) {
        const rest = shown.replace(/^omarchy[\s._-]*/i, "")
        return { text: "Omarchy names are kept for generated themes.", fix: rest ? freeDisplay(rest, names) : "" }
    }
    if ((names || []).indexOf(slug) >= 0) return { text: themeName(slug) + " already exists.", fix: nextFree(shown, names) }
    return null
}

// ---- the editor's parts ---------------------------------------------------------
// A light's kind -> the part it belongs to, in plain words, and its glyph.
function partName(kind, fallback) {
    return ({ fan: "Fans", strimer: "Strimers", ring: "Rings", gpu: "GPU", board: "Motherboard", ram: "RAM" })[kind] || String(fallback || kind || "")
}
function partGlyph(kind) {
    // nf-md-fan, led_strip, circle_double, expansion_card, developer_board, memory, lightbulb
    return ({ fan: "󰈐", strimer: "󰟖", ring: "󰺕", gpu: "󰢮", board: "󰚗", ram: "󰍛" })[kind] || "󰌵"
}
// An LED hint code (led_hints) in a few words.
function ledHintShort(code) {
    return ({ near_white: "Near-white looks plain white on LEDs", pastel: "Pale colours look white on LEDs",
              warm_green: "This shade looks yellow on LEDs", pink_green: "This pink looks white on LEDs",
              violet_magenta: "Magenta looks violet on the fans", dark: "Dark colours look muddy on LEDs" })[code] || ""
}
// The mean RPM over every fan of every group; null without a reading.
function fanAverage(fans) {
    const all = []
    for (const f of (list(fans) || [])) for (const n of (list(f && f.rpms) || [])) if (!missing(n) && isFinite(Number(n))) all.push(Number(n))
    return all.length ? Math.round(all.reduce((a, b) => a + b, 0) / all.length) : null
}

// ---- screens (contract v1.3, plan §5) --------------------------------------------
// Words for the screen editor. The engine's views (theme screens --json, media
// list --json, the job records, preview.json's `screens`) carry the facts;
// these only put plain words to them. File names, paths and sizes stay in
// tooltips.

// A screen's short name: the view's `short`, else from its role
// ("screen.fan3" -> "Fan 3", "screen.pump" -> "Pump").
function screenShort(s) {
    if (s && typeof s === "object") {
        if (s.short) return String(s.short)
        s = s.role
    }
    const r = String(s || "")
    if (r === "screen.pump") return "Pump"
    if (r === "screen.main") return "Main screen"
    let m = r.match(/^screen\.fan(\d+)$/)
    if (m) return "Fan " + m[1]
    m = r.match(/^screen\.aux(\d+)$/)
    if (m) return "Screen " + m[1]
    return roleName(r)
}
// Where a screen sits in the case: "right column", "top row".
function placeWords(place) {
    return ({ right: "right column", left: "left column", top: "top row", bottom: "bottom row" })[String(place || "")] || ""
}
// A screen's shape as a width/height ratio: its media size, else its shape.
function screenAspect(s) {
    const m = s && list(s.media_size)
    if (m && Number(m[0]) > 0 && Number(m[1]) > 0) return Number(m[0]) / Number(m[1])
    const shape = s ? String(s.shape || "") : ""
    return shape === "strip" ? 4 : shape === "wide-curve" ? 2288 / 1080 : shape === "wide" ? 1472 / 720 : 1
}
// The picker's columns for a screen's shape, at 468 px and when narrow.
function mediaColumns(shape, narrow) {
    if (shape === "strip") return narrow ? 1 : 2
    if (shape === "wide-curve" || shape === "wide") return 2
    return narrow ? 3 : 4
}
// A glyph for a screen with nothing to show yet (nf-md-fan, water_pump,
// monitor, television).
function screenGlyph(kind) {
    return ({ fan: "󰈐", pump: "󰖏", main: "󰍹", aux: "󰔂" })[String(kind || "")] || "󰍹"
}
// A glyph for a file whose picture isn't there yet (nf-md-video, image).
function mediaGlyph(kind) { return String(kind || "") === "image" ? "󰋩" : "󰕧" }

// A media kind in a word.
function mediaKindWord(kind) {
    return ({ video: "Video", image: "Picture", still: "Picture", animation: "Animation", gif: "Animation" })[String(kind || "")] || ""
}
// A clip's length: 12 -> "0:12"; nothing for a picture or an unknown length.
function clipLength(s) { return missing(s) || !(Number(s) > 0) ? "" : mmss(s) }
// What a file is, in one short word or its length: "0:12" for a video,
// "Picture", "Animation"; a file not read yet says "Checking…".
function mediaLine(item) {
    if (!item) return ""
    if (item.probe_state === "pending" || item.probe_state === "running") return "Checking…"
    const kind = String(item.kind || (item.probe && item.probe.kind) || "")
    if (kind === "video") {
        const len = clipLength(item.duration !== undefined ? item.duration : item.probe ? item.probe.duration : null)
        return len || "Video"
    }
    return mediaKindWord(kind)
}
// A fit (media_fit): {state, keep, scale, score, note}. "exact" and "scaled"
// fit as they are; "cropped" keeps most of the picture; "poor" doesn't fit.
function fitState(fit) { return fit && fit.state ? String(fit.state) : "unknown" }
function fitsAsIs(fit) { const s = fitState(fit); return s === "exact" || s === "scaled" }
function keepPercent(fit) { return fit && isFinite(Number(fit.keep)) ? Math.round(Number(fit.keep) * 100) : null }
// A picker tile's line: what it is and, when it isn't a clean fit, that.
function tileLine(item) {
    const what = mediaLine(item)
    const st = fitState(item ? item.fit : null)
    if (st === "poor") return "Doesn't fit"
    if (st === "cropped") return what ? what + " · cropped" : "Cropped"
    return what
}
// The same, short enough for a narrow tile: a cropped picture is "Cropped".
function tileLineShort(item) {
    const st = fitState(item ? item.fit : null)
    const what = mediaLine(item)
    if (st === "cropped" && !/^\d/.test(what)) return "Cropped"
    return tileLine(item)
}
// The detail of a fit, for tooltips.
function fitTip(fit, screenName) {
    const st = fitState(fit)
    const pct = keepPercent(fit)
    const where = screenName ? String(screenName).replace(/^./, c => c.toLowerCase()) : "this screen"
    let t = st === "exact" || st === "scaled" ? "Fits " + where + " as it is"
        : st === "cropped" ? "Cropped to fit: keeps " + pct + " % of the picture"
        : st === "poor" ? "Doesn't fit " + where + ": choose it to crop it to fit" + (pct !== null ? " (keeps " + pct + " %)" : "")
        : "Not checked yet"
    const note = fit && fit.note ? String(fit.note) : ""
    if (note === "low-res") t += "\nLow resolution; it may look soft"
    else if (note === "long") t += "\nLonger than this screen takes; it uses the first part"
    else if (note === "alpha") t += "\nSee-through parts show black"
    else if (note === "hdr") t += "\nColours may look flat"
    return t
}
// The crop page's one line, for the framing as it stands:
// {text, tip}. keep and scale are the frame's; capS the screen's length cap.
function cropLine(o) {
    if (o.capS > 0 && o.duration > o.capS + 0.5)
        return { text: "Uses the first " + mmss(o.capS), tip: "The " + String(o.screen || "screen").toLowerCase() + " can take about " + (o.capS >= 120 ? Math.round(o.capS / 60) + " minutes" : o.capS + " seconds") + " at a time" }
    if (o.scale > 1.5) return { text: "Low resolution; it may look soft", tip: "The part you keep has fewer pixels than the screen" }
    if (o.keep >= 0.98) return { text: "Fits as it is", tip: "" }
    return { text: "Keeps " + Math.round(o.keep * 100) + " % of the picture", tip: "The rest is cropped away" }
}

// ---- media jobs (media prepare) ----
const JOB_LIVE = ["queued", "waiting", "probing", "estimating", "encoding", "finishing"]
function jobRunning(job) { return !!job && JOB_LIVE.indexOf(String(job.state || "")) >= 0 }
function jobPercent(job) {
    const p = job && job.progress && typeof job.progress === "object" ? Number(job.progress.frac) : Number(job ? job.progress : NaN)
    return isFinite(p) ? Math.max(0, Math.min(99, Math.floor(p * 100))) : 0
}
// "Preparing… 42 %"; "Waiting…" while other heavy work holds the slots.
function jobText(job) {
    const st = job ? String(job.state || "") : ""
    if (st === "waiting") return "Waiting…"
    if (st === "queued") return "Preparing…"
    if (JOB_LIVE.indexOf(st) >= 0) return "Preparing… " + jobPercent(job) + " %"
    if (st === "failed") return "Couldn't prepare it"
    return ""
}
function jobErrorCode(job) {
    const e = job ? job.error : null
    return e && typeof e === "object" ? String(e.code || "") : String(e || "")
}
// Why a job failed, in words (its tooltip).
function jobErrorTip(job) {
    const code = jobErrorCode(job)
    const known = { unsupported: "It isn't a picture or video this PC can read", "no-picture": "It isn't a picture or video this PC can read",
                    broken: "It isn't a picture or video this PC can read", "disk-full": "Not enough disk space",
                    "stage-full": "Too much new media waits to be saved; save or discard a theme first", stopped: "Stopped",
                    busy: "Other media kept the PC busy for too long", "no-draft": "The theme's draft was closed",
                    "missing-tool": "Screen editing needs ffmpeg and ImageMagick", "too-large": "It's too large to read (over 16 384 px on a side)",
                    "not-applied": "It was made, but the theme didn't take it",
                    "not-found": "The file isn't there any more", unfit: "It doesn't fit this screen", "no-role": "This screen isn't in the hardware profile",
                    "no-profile": "Screen editing needs a hardware profile" }
    if (known[code]) return known[code]
    const e = job ? job.error : null
    return e && typeof e === "object" && e.text ? String(e.text).replace(/[.\s]+$/, "") : ""
}
// The one fix a failed job offers: another file ("choose") or again ("retry").
function jobFix(job) {
    return ["unsupported", "no-picture", "broken", "too-large", "unfit", "not-found"].indexOf(jobErrorCode(job)) >= 0 ? "choose" : "retry"
}
// A refused change to the draft's screens (theme media …, exit 2 or 5), in
// one calm line: {text, level}. The engine's own words go in the tooltip.
function mediaEditError(code) {
    const c = String(code || "")
    if (c === "media-pending") return { text: "Still preparing… Save when it's done.", level: "" }
    const words = { unfit: "It doesn't fit this screen; crop it first.", unsupported: "It isn't a picture or video this PC can read.",
                    "not-found": "That file isn't there any more.", "no-role": "This screen isn't in the hardware profile.",
                    invalid: "That change doesn't work for this screen.", "not-v3": "This theme uses the old format; update your themes once to edit its screens.",
                    "no-profile": "Screen editing needs a hardware profile." }
    return { text: words[c] || "That change didn't go through.", level: "urgent" }
}
// "pump video", "fan 3 picture", "8.8" screen video" for sentences.
function screenMediaNoun(role, kind, short) {
    const r = String(role || "")
    const where = r === "screen.pump" ? "pump" : short ? String(short).replace(/^Fan /, "fan ") : screenShort(r).replace(/^Fan /, "fan ").replace(/^Main screen$/, "main screen")
    return where + " " + (kind === "image" ? "picture" : kind === "animation" ? "animation" : "video")
}

// ---- the lines under the case map and on a screen's page ----
// o: {previewLive, screensOn}; pv: preview.json's screens.roles[role].
// Job first, then the preview, then what the view warns about:
// {text, level, action, tip}; action: "" | cancel | retry | choose | crop.
function screenLine(scr, job, pv, o) {
    const out = (text, level, action, tip) => ({ text: text, level: level || "", action: action || "", tip: tip || "" })
    o = o || {}
    if (!scr) return out("")
    if (job && jobRunning(job)) return out(jobText(job), "", "cancel", String(job.state) === "waiting" ? "It waits for other media to finish preparing" : "")
    if (job && String(job.state) === "failed") return out("Couldn't prepare it", "urgent", jobFix(job), jobErrorTip(job))
    const pst = pv && pv.state ? String(pv.state) : ""
    if (o.previewLive && pst === "failed") return out("Couldn't show it", "urgent", "choose", pv.error ? String(pv.error).replace(/[.\s]+$/, "") : "")
    const m = scr.media || null
    if (m && m.where === "missing") return out("Its file is missing", "urgent", "choose", m.rel ? String(m.rel) : "")
    if (m && (fitState(m.fit) === "poor" || fitState(m.fit) === "cropped")) return out("Doesn't fit this screen", "", "crop", "It shows squeezed to fit; crop it to keep its shape")
    if (o.screensOn === false) return out("Screens are off", "", "", "Turn the screens on to see it on the case")
    if (o.previewLive && pst === "off-usb") return out("Not connected", "", "", "The screen isn't answering on USB")
    if (o.previewLive && (pst === "sent" || pst === "preparing")) return out("Updating…")
    if (scr.template && scr.template.installed === false && scr.modes && scr.modes.current === "template")
        return out("Shows after you save", "", "", "Its clock and stats layout goes in when you save")
    if (o.previewLive && pst === "ready") return out("On the case")
    if (scr.changed && o.previewLive && pst === "skipped") return out("Shows after you save", "", "", pv && pv.reason ? String(pv.reason) : "")
    if (scr.changed && !o.previewLive) return out("Shows after you save", "", "", "Turn on Show on case to see it now")
    if (scr.changed && o.previewLive) return out("Updating…")
    // What the view warns about, in its own words (theme screens problems).
    const warn = code => (list(scr.problems) || []).find(p => p && p.code === code)
    if (warn("long")) return out(String(warn("long").text || "Longer than this screen takes"), "", "", "The screen may not play all of it")
    if (warn("missing")) return out("A clip's file is missing", "urgent", "", String(warn("missing").text || ""))
    if (m && m.fit && m.fit.note === "low-res") return out("Low resolution; it may look soft")
    return out("")
}
// The one line under the case map: the first thing that needs saying.
// {text, level, action, role, tip}.
function mapLine(screens, jobFor, pvFor, o) {
    const out = (text, level, action, role, tip) => ({ text: text, level: level || "", action: action || "", role: role || "", tip: tip || "" })
    const list0 = list(screens) || []
    o = o || {}
    for (const s of list0) {
        const j = jobFor(s.role)
        if (j && String(j.state) === "failed") return out(screenShort(s) + " couldn't be prepared", "urgent", jobFix(j), s.role, jobErrorTip(j))
    }
    if (o.previewLive) for (const s of list0) {
        const p = pvFor(s.role)
        if (p && String(p.state) === "failed") return out(screenShort(s) + " couldn't show it", "urgent", "choose", s.role, p.error ? String(p.error) : "")
    }
    for (const s of list0) {
        const j = jobFor(s.role)
        if (j && jobRunning(j)) return out(screenShort(s) + ": " + jobText(j).replace(/^P/, "p").replace(/^W/, "w"), "", "", s.role, "")
    }
    const changed = list0.filter(s => s.changed)
    if (o.previewLive && list0.some(s => { const p = pvFor(s.role); return p && (p.state === "sent" || p.state === "preparing") })) return out("Updating…")
    if (o.screensOn === false) return out("Screens are off", "", "", "", "Turn the screens on to see them on the case")
    if (changed.length && o.previewLive) return out("On the case")
    if (changed.length) return out("Shows after you save", "", "", "", "Turn on Show on case to see it now")
    return out("")
}
// A map tile's tooltip: where it is, then what it shows.
function tileTip(s, line) {
    if (!s) return ""
    const head = screenShort(s)
    const place = s.kind === "fan" ? placeWords(s.place) : ""
    const clips = s.clips && list(s.clips.items) ? list(s.clips.items).length : 0
    const first = head + (place ? " · " + place : clips > 1 ? " · " + clips + " clips" : "")
    let what = ""
    if (s.managed === false) what = "Not managed"
    else if (s.modes && s.modes.current === "template") what = "Clock and stats"
    else if (s.media) what = [String(s.media.title || ""), clipLength(s.media.probe ? s.media.probe.duration : null)].filter(x => x).join(" · ")
    else what = "Unchanged: this theme leaves it as it is"
    return [first, what, line || ""].filter(x => x).join("\n")
}
// "One clip", "Takes turns · 5 clips", "3 clips" (not taking turns).
function clipsSummary(clips) {
    const items = clips ? list(clips.items) || [] : []
    if (items.length <= 1) return "One clip"
    return (Number(clips.rotate) > 0 ? "Takes turns · " : "") + items.length + " clips"
}
// Change every: the choices, and a step from any value to the next one.
function rotateOptions(choices) {
    const c = (list(choices) || [60, 300, 900, 3600]).map(Number).filter(n => n > 0)
    const word = s => s % 3600 === 0 ? (s / 3600) + " h" : s % 60 === 0 ? (s / 60) + " min" : s + " s"
    return c.map(s => ({ value: String(s), label: word(s) })).concat([{ value: "0", label: "Off" }])
}
function rotateStep(seconds, d, choices) {
    const c = (list(choices) || [60, 300, 900, 3600]).map(Number).filter(n => n > 0).sort((a, b) => a - b).concat([0])
    const cur = Number(seconds) || 0
    let i = c.indexOf(cur)
    if (i < 0) {
        // Off-grid: the nearest choice in that direction.
        const up = c.filter(x => x > 0 && x > cur), down = c.filter(x => x > 0 && x < cur)
        return d > 0 ? (up.length ? up[0] : 0) : (down.length ? down[down.length - 1] : c[0])
    }
    return c[Math.max(0, Math.min(c.length - 1, i + d))]
}
// The main page's notice about media being prepared for a theme no open
// editor shows (status --json v1.3 `media`): a failure first (urgent, it can
// be dismissed), else the one running; null when there's nothing to say.
// {key, text, level, actions}. `now` in epoch seconds keeps old failures out.
function mediaNotice(media, editorName, dismissed, now) {
    const jobs = (list(media && media.jobs) || []).filter(j => j && j.draft && j.draft !== editorName)
    const quiet = ["superseded", "stopped", "no-draft"]
    const failed = jobs.find(j => String(j.state) === "failed" && quiet.indexOf(jobErrorCode(j)) < 0 && !(dismissed && dismissed["media:" + j.id])
                                  && !(now > 0 && Number(j.ended || j.updated || 0) > 0 && now - Number(j.ended || j.updated) > 3600))
    // A job's own "kind" is its type ("prepare"); the file's kind is media_kind.
    const noun = j => screenMediaNoun(j.role, j.media_kind || (j.source ? j.source.kind : ""), "")
    if (failed) return { key: "media:" + failed.id, level: "urgent", actions: ["dismiss"],
                         text: "Couldn’t prepare " + themeName(failed.draft) + "’s " + noun(failed) + "." }
    const run = jobs.find(j => jobRunning(j))
    if (run) return { key: "media-run", level: "info", actions: [],
                      text: String(run.state) === "waiting" || String(run.state) === "queued" ? "Preparing " + themeName(run.draft) + "’s " + noun(run) + "…"
                          : "Preparing " + themeName(run.draft) + "’s " + noun(run) + "… " + jobPercent(run) + " %" }
    return null
}

// ---- the desktop wallpaper (contract v1.4) ----------------------------------
// The animated wallpaper's settings, one set per theme: `desktop --json`
// views, and status --json `desktop` (the engine's cache of the desktop).
// Settings keys as the views name them; `desktop set` takes the short verbs.
const DESKTOP_KEYS = { animated: "animated", pause: "pause_while_active", pause_while_active: "pause_while_active",
                       resume: "resume_after_idle", resume_after_idle: "resume_after_idle", while: "while_active", while_active: "while_active" }
const DESKTOP_VERBS = { animated: "animated", pause_while_active: "pause", resume_after_idle: "resume", while_active: "while" }
function desktopKey(k) { return DESKTOP_KEYS[String(k === undefined || k === null ? "" : k)] || "" }
function desktopVerb(k) { return DESKTOP_VERBS[desktopKey(k)] || "" }
// A value as the engine takes it, or null when it can't be one: true or
// false for the switches, whole seconds 1-600, "freeze" or "still".
function desktopValue(k, v) {
    const key = desktopKey(k)
    if (key === "animated" || key === "pause_while_active") {
        if (typeof v === "boolean") return v
        const t = String(v).trim().toLowerCase()
        return t === "true" || t === "on" ? true : t === "false" || t === "off" ? false : null
    }
    if (key === "resume_after_idle") {
        if (typeof v === "boolean" || v === null || v === undefined || String(v).trim() === "") return null
        const n = Number(v)
        return isFinite(n) && Math.round(n) === n && n >= 1 && n <= 600 ? n : null
    }
    if (key === "while_active") return v === "freeze" || v === "still" ? v : null
    return null
}
function desktopArg(v) { return typeof v === "boolean" ? (v ? "true" : "false") : String(v) }
// status --json `desktop` as a view, until the theme's own has been read:
// what this wallpaper has stays unknown (null).
function desktopStub(st, theme) {
    if (!st || typeof st !== "object") return null
    return { v: 1, available: st.available === true, reason: null, omarchy_theme: null, theme: String(st.theme || theme || ""),
             background: null, has_animated: null, playing: st.playing === undefined ? null : st.playing, user_clip: null,
             settings: Object.assign({}, st.settings || {}), stored: null, defaults: null }
}
// A view with the changes still on their way laid over it.
function desktopWith(view, local) {
    if (!view || !local || Object.keys(local).length === 0) return view || null
    return Object.assign({}, view, { settings: Object.assign({}, view.settings || {}, local),
                                     stored: Object.assign({}, view.stored || {}, local) })
}
// The main page's row, in one short state. A wallpaper without an animated
// version says so first: the switch can't change anything then.
function desktopSummary(view) {
    if (!view) return ""
    const s = view.settings || {}
    if (view.has_animated === false) return "No animated version"
    if (s.animated === false) return "Still"
    return s.pause_while_active === true ? "Animated · pauses while you work" : "Animated"
}
// The line under the page's Animated wallpaper switch: what the wallpaper on
// the desktop has, or (another theme's page) when these settings apply. A
// video the user picked in Motion Wallpaper plays whatever the theme says.
function desktopAnimatedLine(view, home) {
    if (!view) return ""
    if (home && view.user_clip === true) return "Playing a video you picked"
    if (view.has_animated === true) return "This wallpaper has an animated version"
    if (view.has_animated === false) return "No animated version for this wallpaper"
    const t = themeName(view.theme)
    return home || !t ? "" : "Applies when " + t + " is on"
}
// Why the page can't show the settings (view.available false).
function desktopUnavailable(reason) {
    const r = String(reason || "")
    if (r === "no-plugin") return "Animated wallpapers need the Motion Wallpaper plugin."
    if (r === "shell-down") return "The desktop isn't answering right now."
    return "The wallpaper can't be changed right now."
}
// A refused desktop command ({error, code}: exit 2 usage, invalid or
// not-found, exit 75 busy) in one calm line; the engine's own words go in
// the tooltip.
function desktopError(code) {
    const words = { "not-found": "That theme isn't there any more.", busy: "The desktop is busy. Try again in a moment." }
    return words[String(code || "")] || "That change didn't go through."
}
// Resume after: 3 s · 5 s · 10 s · 30 s, and a value set elsewhere in its place.
function secondsWords(s) { const n = Number(s); return n >= 60 && n % 60 === 0 ? (n / 60) + " min" : n + " s" }
function resumeOptions(current) {
    const c = [3, 5, 10, 30]
    const n = Number(current)
    if (isFinite(n) && Math.round(n) === n && n >= 1 && n <= 600 && c.indexOf(n) < 0) c.push(n)
    return c.sort((a, b) => a - b).map(s => ({ value: String(s), label: secondsWords(s) }))
}
function resumeStep(current, d) {
    const c = resumeOptions(current).map(o => Number(o.value))
    const i = c.indexOf(Number(current))
    return i < 0 ? (d > 0 ? c[0] : c[c.length - 1]) : c[Math.max(0, Math.min(c.length - 1, i + d))]
}
// Whether the theme keeps settings of its own that differ from the defaults
// ("Use defaults" shows).
function desktopCustom(view) {
    const st = view && view.stored && typeof view.stored === "object" ? view.stored : {}
    const d = view && view.defaults && typeof view.defaults === "object" ? view.defaults : null
    return Object.keys(st).some(k => desktopKey(k) !== "" && (!d || d[k] === undefined || st[k] !== d[k]))
}
