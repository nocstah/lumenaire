pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Format.js" as Format
import "LedColor.js" as LedColor

// The theme editor page (plan §2, DESIGN.md "Editor"). LightsContent swaps
// its column for this when `page` is "editor"; it binds only to the Service
// API (§2.4): the engine's editor view (`service.editor`) plus the optimistic
// draft (`service.editorDraft`), and every change is one Service call.
//
//   header        ← back, the name, "● Unsaved"; Save (primary) and ⋯ (Save
//                 as copy…, Discard changes, Duplicate, Rename…, Delete…)
//   notices       the draft this reopened, what stops a save, a file changed
//                 on disk, a theme made from Omarchy, the engine's own line
//   Show on case  the live preview switch and one status line (PreviewStatus)
//   Colours       Main, Second, Accent as big swatches; the picker opens under
//   Parts         one row per part of the case (RoleRow); a part with several
//                 devices lists them under "Customise each…"
//   Screens       the case map (ScreensSection): every LCD at its place with
//                 its media as a picture; a tile opens that screen's page
//   Advanced      collapsed: keep colours vivid on LEDs, this PC's colour
//                 correction, the heat warning colour
//
// Drafts are the engine's: leaving never loses work and never asks. Save on
// the theme that is on the case saves and applies it; any other theme is
// saved and the main page offers "Use it now?".
//
// Keys (plan §2.3): j/k or ↑/↓ walk a flat list of rows, Enter/Space opens
// the picker, expands or activates, h/l step a speed or a choice and fold a
// row, r resets a field, p switches the preview, Ctrl+S saves, the menu key
// opens ⋯, Esc goes picker → popup → back. Inside the picker, keys go to
// ColorPicker.handleKey.
FocusScope {
    id: root
    required property var service
    signal backRequested()
    signal showRequested(var item)
    signal saveRequested(string name, bool apply)
    signal copyRequested(string name, bool keep)
    // A screen's page: step "" (the screen), "pick" or "crop".
    signal screenRequested(string role, string step)

    // The harness (and a reopened panel) restore view state from this.
    property var initial: null

    readonly property bool hasService: service !== null && service !== undefined
    readonly property var view: hasService ? service.editor : null
    readonly property var draft: hasService && service.editorDraft ? service.editorDraft : (view && view.theme ? view.theme : ({}))
    readonly property bool pending: hasService && service.editPending === true
    readonly property string edState: hasService ? String(service.editorState || "closed") : "closed"
    readonly property string name: view ? String(view.name || "") : hasService ? String(service.editorName || "") : ""
    readonly property string mode: view && view.mode ? String(view.mode) : "edit"
    readonly property var cal: view && view.calibration ? view.calibration : null
    readonly property var limits: view && view.limits ? view.limits : ({})
    readonly property bool lightsOn: hasService && service.lights === "on"
    readonly property var classes: view && view.palette && view.palette.primary && view.palette.primary.shows
        ? Object.keys(view.palette.primary.shows) : []
    readonly property var saved: view && view.saved ? view.saved : ({})
    readonly property bool dirty: pending || (!!view && view.dirty === true)
    readonly property bool unsaved: dirty || mode !== "edit"
    readonly property string block: {
        if (!hasService) return "engine"
        const code = String(service.editorErrorCode || "")
        if (code === "not-v3") return "v2"
        if (code === "no-profile" || code === "engine") return code
        const b = service.canEdit(mode === "edit" ? name : "")
        return b === "auto" ? "" : b
    }
    readonly property var errors: (view && Array.isArray(view.problems) ? view.problems : []).filter(p => p && p.level !== "warn")

    // View state.
    property var expanded: ({})
    property var more: ({})
    property bool advanced: false
    property string cursorKey: ""
    property bool keyNav: false
    property string pickerKey: ""
    property string pickerOriginal: ""
    property var recent: []
    property string targetName: ""       // new themes and copies: the name to save under
    property bool resumed: false         // opened on a draft with changes: say so once
    property bool previewOnOpen: false   // just created: show it on the case at once
    property var items: ({})
    property var strimers: ({})
    property Item pickerItem: null

    implicitWidth: Style.space(468)
    implicitHeight: body.implicitHeight

    // ---- units: groups first, then their roles, in the view's order ------
    readonly property var units: {
        const out = []
        if (!view || !Array.isArray(view.roles)) return out
        const groups = {}
        for (const g of (view.groups || [])) if (g && Array.isArray(g.roles) && g.roles.length > 1) groups[g.group] = g
        const done = {}
        const formFor = k => k === "fan" ? "fan" : k === "strimer" ? "strimer" : "colour"
        for (const r of view.roles) {
            if (!r || !r.role) continue
            const g = r.group ? groups[r.group] : null
            if (g && !done[g.group]) {
                done[g.group] = true
                const kind = g.kind || r.kind
                const fields = kind === "fan" ? { inner: { path: g.path + "/inner" }, outer: { path: g.path + "/outer" } }
                    : kind === "strimer" ? { mode: { path: g.path + "/mode" }, speed: { path: g.path + "/speed" },
                                             direction: { path: g.path + "/direction" }, colors: { path: g.path + "/colors" } }
                    : { colour: { path: g.path } }
                out.push({ id: "@" + g.group, isGroup: true, group: g.group, kind: kind, form: formFor(kind), cls: r.class || "",
                           label: Format.groupLabel(g.group), members: g.roles.length, set: g.set === true, fields: fields, depth: 0 })
            }
            out.push({ id: r.role, isGroup: false, role: r.role, group: r.group || "", kind: r.kind, form: r.form || "colour",
                       cls: r.class || "", label: r.label || Format.roleName(r.role), present: r.present !== false,
                       readonly_reason: r.readonly_reason || null, fields: r.fields || {},
                       // Under its group, or under the role it follows (board.argb under board).
                       depth: g || (r.group && view.roles.some(x => x && x.role === r.group)) ? 1 : 0 })
        }
        return out
    }
    readonly property var unitById: {
        const m = {}
        for (const u of units) m[u.id] = u
        m["palette"] = paletteUnit
        return m
    }
    readonly property var paletteUnit: ({ id: "palette", isPalette: true, cls: "", kind: "palette", fields: view && view.palette ? view.palette : {} })
    // The parts list: top-level units, each with the devices under it.
    function parentOf(id) {
        const u = unitById[id]
        if (!u || u.depth === 0) return ""
        if (unitById["@" + u.group]) return "@" + u.group
        return unitById[u.group] ? u.group : ""
    }
    function childrenOf(id) { return units.filter(u => u.depth === 1 && parentOf(u.id) === id) }
    readonly property var partRows: {
        const out = []
        for (const u of units) {
            if (u.depth !== 0) continue
            out.push({ id: u.id, depth: 0 })
            if (!isMore(u.id)) continue
            for (const c of childrenOf(u.id)) out.push({ id: c.id, depth: 1 })
        }
        return out
    }
    // A part in plain words: its kind (Fans, GPU, Motherboard), a device its
    // own name; two top-level parts of one kind keep their labels.
    function partTitle(u) {
        u = canon(u)
        if (!u) return ""
        if (u.depth > 0) return String(u.label || "")
        const same = units.filter(x => x.depth === 0 && x.kind === u.kind).length
        return same > 1 ? String(u.label || Format.partName(u.kind)) : Format.partName(u.kind, u.label)
    }
    function resetLabel(u) {
        u = canon(u)
        const p = u ? unitById[parentOf(u.id)] : null
        if (!p) return "Use theme colours"
        return ({ fan: "Same as all fans", strimer: "Same as all Strimers", ring: "Same as all rings", board: "Same as the motherboard" })[p.kind]
            || "Same as " + partTitle(p)
    }
    // Whether a unit sets its own colours here (a group: or any of its devices).
    function ownColours(u) {
        u = canon(u)
        if (!u) return false
        if (u.form === "readonly") return true
        for (const n of Object.keys(u.fields || {})) {
            const f = fieldView(u, n)
            if (f && (f.source === "role" || (u.isGroup && f.source === "group"))) return true
        }
        return false
    }
    function partState(u) {
        u = canon(u)
        if (!u) return { text: "", tone: "muted", tip: "", custom: false }
        const own = ownColours(u)
        if (u.present === false) return { text: "Not found", tone: "muted", tip: String(u.label || "") + " isn't connected; it keeps its colours for when it's back.", custom: own }
        if (u.depth > 0) return { text: own ? "Custom" : "", tone: "accent", tip: own ? "This device has its own colours" : "", custom: own }
        const custom = own || childrenOf(u.id).some(k => ownColours(k))
        const single = !u.isGroup && units.filter(x => x.depth === 0 && x.kind === u.kind).length === 1 && u.label && u.label !== Format.partName(u.kind)
        return { text: custom ? "Custom" : "Theme colours", tone: custom ? "accent" : "muted",
                 tip: (single ? String(u.label) + ". " : "") + (custom ? "This theme sets its own colours here" : "Follows Main, Second and Accent"), custom: custom }
    }
    function resetPart(id) {
        const u = unitById[id]
        if (!u || !hasService) return
        const path = x => x.isGroup ? "/roles/" + x.group : "/roles/" + Format.ptrEscape(x.role)
        const ops = [{ op: "remove", path: path(u) }]
        if (u.depth === 0) for (const c of childrenOf(id)) ops.push({ op: "remove", path: path(c) })
        if (pickerKey && (pickerKey.indexOf("field:" + id + ":") === 0 || childrenOf(id).some(c => pickerKey.indexOf("field:" + c.id + ":") === 0))) closePicker()
        service.editPatch(ops)
    }

    // ---- the optimistic value of a field ---------------------------------
    function dpal() {
        const p = draft.palette || {}
        const pr = LedColor.norm(p.primary) || "ffffff"
        const se = LedColor.norm(p.secondary) || pr
        const ac = LedColor.norm(p.accent) || LedColor.mix(pr, se, 0.5)
        if (p.led_safe === false) return { primary: pr, secondary: se, accent: ac }
        return { primary: LedColor.ledSafe(pr), secondary: LedColor.ledSafe(se), accent: LedColor.ledSafe(ac) }
    }
    // th_derive, for one field of a kind.
    function derived(kind, name) {
        const d = dpal()
        const mo = draft.motion || {}
        if (kind === "fan") return name === "inner" ? d.primary : d.secondary
        if (kind === "strimer") return name === "mode" ? (mo.mode || "Drizzling") : name === "speed" ? (mo.speed === undefined ? 2 : mo.speed)
            : name === "direction" ? (mo.direction || "Clockwise") : [d.primary, d.secondary, d.accent, d.primary, d.secondary, d.accent]
        if (kind === "gpu") return name === "stops" ? [d.primary, d.secondary] : null
        if (kind === "ram") return name === "stops" ? [d.primary, d.accent, d.secondary] : name === "span" ? "across" : null
        return d.accent
    }
    function localHints(value, cls) {
        if (Array.isArray(value)) return value.map(v => LedColor.hints(String(v), cls, cal))
        return typeof value === "string" ? LedColor.hints(value, cls, cal) : []
    }
    function localShows(value, cls) {
        if (Array.isArray(value)) return value.map(v => LedColor.shows(String(v), cls, cal))
        return typeof value === "string" ? LedColor.shows(value, cls, cal) : ""
    }
    // {value, source, path, shows, hints}; source: role | group | palette
    // (palette fields: set | derived).
    // A unit handed through a Repeater's modelData comes back converted
    // (lists as sequences): always read the editor's own JS copy.
    function canon(unit) { return unit && unit.id !== undefined && unitById[unit.id] ? unitById[unit.id] : unit }
    function fieldView(unit, fname) {
        unit = canon(unit)
        if (!unit || !unit.fields) return null
        if (unit.isPalette) {
            const pv = unit.fields[fname] || {}
            const own = Format.ptrGet(draft, "/palette/" + fname)
            const set = own !== undefined && own !== null
            const raw = dpalRaw()
            const value = set ? LedColor.norm(own) : !pending || fname === "alert" ? String(pv.value || "") : raw[fname]
            const fresh = !pending && value === pv.value
            const safeOn = (draft.palette || {}).led_safe !== false
            const use = fname === "alert" ? value : safeOn ? LedColor.ledSafe(value) : value
            return { value: value, source: set ? "set" : "derived", path: "/palette/" + fname, from: pv.from || "",
                     hints: fname === "alert" ? [] : fresh && pv.hints ? pv.hints : LedColor.paletteHints(value, use, classes, cal),
                     shows: fresh && pv.shows && classes.length ? pv.shows[classes[0]] || "" : classes.length ? LedColor.shows(use, classes[0], cal) : "" }
        }
        const f = unit.fields[fname]
        if (!f) return null
        if (!unit.isGroup && !pending && f.value !== undefined)
            return { value: f.value, source: f.source || "", path: f.path, shows: f.shows, hints: f.hints || [] }
        let value, source
        const own = Format.ptrGet(draft, f.path)
        if (unit.isGroup) {
            const gv = Format.ptrGet(draft, "/roles/" + unit.group)
            if (unit.kind === "fan" && typeof gv === "string") { value = gv; source = "group" }
            else if (own !== undefined && own !== null) { value = own; source = "group" }
            else { value = derived(unit.kind, fname); source = "palette" }
        } else if (own !== undefined && own !== null && !(typeof own === "object" && !Array.isArray(own) && fname === "colour")) {
            value = own; source = "role"
        } else {
            const whole = Format.ptrGet(draft, "/roles/" + unit.role)
            const gv = unit.group ? Format.ptrGet(draft, "/roles/" + unit.group) : undefined
            const tail = String(f.path).slice(("/roles/" + Format.ptrEscape(unit.role)).length)
            const g = unit.group ? Format.ptrGet(draft, "/roles/" + Format.ptrEscape(unit.group) + tail) : undefined
            if (unit.kind === "fan" && typeof whole === "string") { value = whole; source = "role" }
            else if (g !== undefined && g !== null) { value = g; source = "group" }
            else if (unit.kind === "fan" && typeof gv === "string") { value = gv; source = "group" }
            else { value = derived(unit.kind, fname === "stops" || fname === "span" ? fname : fname); source = "palette" }
        }
        return { value: value, source: source, path: f.path, shows: localShows(value, unit.cls), hints: localHints(value, unit.cls) }
    }
    function dpalRaw() {
        const p = draft.palette || {}
        const pr = LedColor.norm(p.primary) || "ffffff"
        const se = LedColor.norm(p.secondary) || pr
        return { primary: pr, secondary: se, accent: LedColor.norm(p.accent) || LedColor.mix(pr, se, 0.5) }
    }
    function unitShape(unit) {
        unit = canon(unit)
        if (!unit || unit.form !== "gradient") return ""
        const own = Format.ptrGet(draft, "/roles/" + Format.ptrEscape(unit.role))
        if (typeof own === "string") return "solid"
        if (own && typeof own === "object") return "gradient"
        const s = unit.fields && unit.fields.shape ? unit.fields.shape.value : ""
        return pending ? "gradient" : (s === "solid" || s === "colour" ? "solid" : "gradient")
    }
    function unitColours(unit) {
        unit = canon(unit)
        const out = []
        const add = v => { if (Array.isArray(v)) v.forEach(add); else if (LedColor.isHex(v)) out.push(LedColor.norm(v))
                           else if (v && typeof v === "object") Object.keys(v).filter(k => k.charAt(0) !== "_").forEach(k => add(v[k])) }
        if (!unit) return out
        // Read-only values (per-fan lists, OpenRGB modes): their colours as written.
        if (unit.form === "readonly") { add(Format.ptrGet(draft, unit.isGroup ? "/roles/" + unit.group : "/roles/" + Format.ptrEscape(unit.role))); return out }
        if (unit.form === "gradient") {
            if (unitShape(unit) === "solid") { const c = fieldView(unit, "colour"); add(c ? c.value : null) }
            else { const s = fieldView(unit, "stops"); add(s ? s.value : null) }
            if (out.length === 0) { const c = fieldView(unit, "colour"); add(c ? c.value : null) }
            return out
        }
        for (const n of ["inner", "outer", "colour", "colors"]) if (unit.fields && unit.fields[n]) { const v = fieldView(unit, n); add(v ? v.value : null) }
        return out
    }
    function warnCount(hints) { return Array.isArray(hints) ? hints.filter(h => h && h.level === "warn").length : 0 }

    // ---- writes --------------------------------------------------------------
    function fieldPath(unit, fname) {
        if (unit.isPalette) return "/palette/" + fname
        if (fname === "colour" && unit.form === "gradient") return "/roles/" + Format.ptrEscape(unit.role)
        const f = unit.fields ? unit.fields[fname] : null
        return f && f.path ? String(f.path) : ""
    }
    // A whole field, or one element of a list field (a Strimer colour, a
    // gradient stop): the first edit of a list that isn't set on this role
    // writes the whole list, so it never lands sparse.
    function setField(unit, fname, value, index) {
        unit = canon(unit)
        if (!hasService || !unit) return
        const path = fieldPath(unit, fname)
        if (!path) return
        if (index !== undefined && index >= 0) {
            const cur = fieldView(unit, fname)
            const list = cur && Array.isArray(cur.value) ? cur.value.slice() : []
            list[index] = value
            const own = Format.ptrGet(draft, path)
            if (Array.isArray(own) && own.length === list.length) service.editSet(path + "/" + index, value)
            else if (fname === "stops") setStops(unit, list)
            else service.editSet(path, list)
            return
        }
        service.editSet(path, value)
    }
    function setStops(unit, list) {
        unit = canon(unit)
        const base = "/roles/" + Format.ptrEscape(unit.role)
        const own = Format.ptrGet(draft, base)
        if (own && typeof own === "object" && !Array.isArray(own)) service.editSet(base + "/gradient", list)
        else {
            const v = { gradient: list }
            if (unit.kind === "ram") { const sp = fieldView(unit, "span"); v.span = sp && sp.value ? sp.value : "across" }
            service.editSet(base, v)
        }
    }
    function setShape(unit, shape) {
        unit = canon(unit)
        if (unitShape(unit) === shape) return
        const base = "/roles/" + Format.ptrEscape(unit.role)
        const stops = fieldView(unit, "stops")
        const colour = fieldView(unit, "colour")
        if (pickerKey.indexOf("field:" + unit.id + ":") === 0) closePicker()
        if (shape === "solid") service.editSet(base, stops && Array.isArray(stops.value) && stops.value.length ? stops.value[0] : (colour ? colour.value : dpal().accent))
        else {
            const c = colour && LedColor.isHex(colour.value) ? LedColor.norm(colour.value) : dpal().primary
            const list = [c, LedColor.mix(c, "000000", 0.35)]
            const v = { gradient: list }
            if (unit.kind === "ram") v.span = "across"
            service.editSet(base, v)
        }
    }
    function addStop(unit) {
        unit = canon(unit)
        const s = fieldView(unit, "stops")
        const list = s && Array.isArray(s.value) ? s.value.slice() : []
        const last = list.length ? list[list.length - 1] : dpal().primary
        list.push(last)
        setStops(unit, list)
    }
    function removeStop(unit, index) {
        unit = canon(unit)
        const s = fieldView(unit, "stops")
        const list = s && Array.isArray(s.value) ? s.value.slice() : []
        list.splice(index, 1)
        if (pickerKey.indexOf("field:" + unit.id + ":stops/") === 0) closePicker()
        setStops(unit, list)
    }
    function replaceWithOne(unit) {
        unit = canon(unit)
        const base = unit.isGroup ? "/roles/" + unit.group : "/roles/" + Format.ptrEscape(unit.role)
        const cur = Format.ptrGet(draft, base)
        let first = null
        const find = v => { if (first) return; if (LedColor.isHex(v)) first = LedColor.norm(v); else if (Array.isArray(v)) v.forEach(find); else if (v && typeof v === "object") Object.keys(v).forEach(k => find(v[k])) }
        find(cur)
        const c = first || dpal().accent
        service.editSet(base, unit.kind === "fan" ? { inner: c, outer: c } : c)
    }
    function resetKey(k) {
        const p = parseKey(k)
        if (!p) return
        if (p.kind === "reset") { resetPart(p.id); return }
        if (p.unit && p.unit.isPalette) { service.editReset("/palette/" + p.field); return }
        if (p.kind === "unit" && p.unit) { resetPart(p.unit.id); return }
        if (p.kind === "field" && p.unit) {
            const path = fieldPath(p.unit, p.field)
            if (path) service.editReset(path)
        }
    }

    // ---- keys ------------------------------------------------------------------
    // "pal:<k>", "unit:<id>", "field:<id>:<field>[/<i>]", "reset:<id>",
    // "more:<id>", and action keys.
    function parseKey(k) {
        k = String(k || "")
        if (k.indexOf("pal:") === 0) return { kind: "field", unit: paletteUnit, field: k.slice(4), index: -1 }
        if (k.indexOf("unit:") === 0) return { kind: "unit", unit: unitById[k.slice(5)] || null }
        if (k.indexOf("reset:") === 0) return { kind: "reset", id: k.slice(6) }
        if (k.indexOf("more:") === 0) return { kind: "more", id: k.slice(5) }
        if (k.indexOf("field:") === 0) {
            const rest = k.slice(6)
            const cut = rest.lastIndexOf(":")
            const id = rest.slice(0, cut)
            const f = rest.slice(cut + 1).split("/")
            return { kind: "field", unit: unitById[id] || null, field: f[0], index: f.length > 1 ? Number(f[1]) : -1 }
        }
        return { kind: "action", key: k }
    }
    function fieldRows(u) {
        const b = "field:" + u.id + ":"
        const r = []
        if (u.form === "fan") r.push(b + "inner", b + "outer")
        else if (u.form === "colour") r.push(b + "colour")
        else if (u.form === "strimer") { r.push(b + "mode", b + "speed", b + "direction"); for (let i = 0; i < 6; i++) r.push(b + "colors/" + i) }
        else if (u.form === "gradient") {
            r.push(b + "shape")
            if (unitShape(u) === "solid") r.push(b + "colour")
            else {
                const s = fieldView(u, "stops")
                const n = s && Array.isArray(s.value) ? s.value.length : 0
                for (let i = 0; i < n; i++) r.push(b + "stops/" + i)
                r.push(b + "add")
                if (u.kind === "ram") r.push(b + "span")
            }
        } else if (u.form === "readonly") r.push(b + "replace")
        return r
    }
    readonly property var rows: {
        const r = ["preview"]
        for (const k of ["primary", "secondary", "accent"]) r.push("pal:" + k)
        const addUnit = u => {
            r.push("unit:" + u.id)
            if (!expanded[u.id]) return
            for (const f of fieldRows(u)) r.push(f)
            if (partState(u).custom && u.form !== "readonly") r.push("reset:" + u.id)
            if (u.depth === 0 && childrenOf(u.id).length) {
                r.push("more:" + u.id)
                if (isMore(u.id)) for (const c of childrenOf(u.id)) addUnit(c)
            }
        }
        for (const u of units) if (u.depth === 0) addUnit(u)
        if (screensShown) {
            for (const role of screenOrder) r.push("scr:" + role)
            if (screensLine.action !== "") r.push("scr-action")
        }
        r.push("advanced")
        if (advanced) {
            r.push("ledsafe")
            if (cal && cal.enabled) r.push("calib")
            r.push("pal:alert")
        }
        return r
    }
    function register(k, item) {
        const m = items
        m[k] = item
        items = m
    }
    function registerStrimer(id, item) { const m = strimers; m[id] = item; strimers = m }
    function isExpanded(id) { return expanded[id] === true }
    function isMore(id) { return more[id] === true }
    function toggleExpand(id) {
        const e = Object.assign({}, expanded)
        if (e[id]) delete e[id]
        else e[id] = true
        if (!e[id] && String(pickerKey).indexOf("field:" + id + ":") === 0) closePicker()
        expanded = e
    }
    function toggleMore(id) {
        const m = Object.assign({}, more)
        if (m[id]) delete m[id]
        else m[id] = true
        if (!m[id] && childrenOf(id).some(c => String(pickerKey).indexOf("field:" + c.id + ":") === 0)) closePicker()
        more = m
    }
    function moveCursor(d) {
        keyNav = true
        const r = rows
        let i = r.indexOf(cursorKey)
        i = i < 0 ? (d > 0 ? 0 : r.length - 1) : Math.max(0, Math.min(r.length - 1, i + d))
        cursorKey = r[i] || ""
        Qt.callLater(() => showRequested(items[cursorKey] || null))
    }

    // ---- the picker --------------------------------------------------------------
    readonly property var pickerRef: pickerKey ? parseKey(pickerKey) : null
    readonly property var pickerView: pickerRef && pickerRef.unit ? fieldView(pickerRef.unit, pickerRef.field) : null
    readonly property string pickerValue: {
        if (!pickerView) return ""
        const v = pickerRef.index >= 0 && Array.isArray(pickerView.value) ? pickerView.value[pickerRef.index] : pickerView.value
        return LedColor.norm(v) || ""
    }
    readonly property var pickerHints: {
        if (!pickerView || !pickerValue) return []
        const h = pickerView.hints
        const one = pickerRef.index >= 0 ? (Array.isArray(h) ? h[pickerRef.index] : []) : h
        return Array.isArray(one) ? one : []
    }
    readonly property string pickerShows: {
        if (!pickerView || !pickerValue) return ""
        const s = pickerView.shows
        const one = pickerRef.index >= 0 ? (Array.isArray(s) ? s[pickerRef.index] : "") : s
        return LedColor.norm(one) || ""
    }
    readonly property var paletteSwatches: {
        const out = []
        for (const k of ["primary", "secondary", "accent"]) {
            const f = fieldView(paletteUnit, k)
            if (f && LedColor.isHex(f.value)) out.push({ hex: LedColor.norm(f.value), label: Format.colourRole(k) })
        }
        return out
    }
    function togglePicker(k) {
        if (pickerKey === k) { closePicker(); return }
        closePicker()
        pickerKey = k
        pickerOriginal = pickerValue
        cursorKey = k
    }
    function closePicker() {
        if (pickerKey && pickerValue && pickerValue !== pickerOriginal) {
            const r = [pickerValue].concat(recent.filter(c => c !== pickerValue))
            recent = r.slice(0, 6)
        }
        pickerKey = ""
        pickerOriginal = ""
        pickerItem = null
        root.forceActiveFocus()
    }
    function pickColour(hex) {
        if (!pickerRef || !pickerRef.unit) return
        setField(pickerRef.unit, pickerRef.field, hex, pickerRef.index)
    }
    readonly property Component pickerComponent: Component {
        ColorPicker {
            id: picker
            hex: root.pickerValue
            original: root.pickerOriginal
            swatches: root.paletteSwatches
            recent: root.recent
            shows: root.pickerShows
            hints: root.pickerHints
            onPicked: function(h) { root.pickColour(h) }
            onDoneRequested: root.closePicker()
            Component.onCompleted: root.pickerItem = picker
        }
    }

    // ---- activation -------------------------------------------------------------
    function activate(k) {
        const p = parseKey(k)
        if (k === "preview") { service.setPreviewEnabled(!service.previewEnabled); return }
        if (k === "advanced") { advanced = !advanced; return }
        if (k === "ledsafe") { toggleLedSafe(); return }
        if (k === "calib") { toggleCalibrated(); return }
        if (k.indexOf("scr:") === 0) { openScreen(k.slice(4), ""); return }
        if (k === "scr-action") { screensAct(); return }
        if (!p) return
        if (p.kind === "reset") { resetPart(p.id); return }
        if (p.kind === "more") { toggleMore(p.id); return }
        if (p.kind === "unit" && p.unit) { toggleExpand(p.unit.id); return }
        if (p.kind === "field" && p.unit) {
            const f = p.field
            if (p.unit.isPalette || f === "inner" || f === "outer" || f === "colour" || ((f === "colors" || f === "stops") && p.index >= 0)) { togglePicker(k); return }
            if (f === "mode") { const s = strimers[p.unit.id]; if (s) s.openMode(); return }
            if (f === "add") { addStop(p.unit); return }
            if (f === "replace") { replaceWithOne(p.unit); return }
            if (f === "direction" || f === "shape" || f === "span") { step(k, 1); return }
        }
    }
    // h/l on a value row: speed ±1, cycle a choice; on a unit row, fold.
    function step(k, d) {
        if (k === "advanced") { if ((d > 0) !== advanced) advanced = d > 0; return true }
        const p = parseKey(k)
        if (p && p.kind === "more") { if ((d > 0) !== isMore(p.id)) toggleMore(p.id); return true }
        if (!p || !p.unit) return false
        if (p.kind === "unit") {
            if ((d > 0) !== isExpanded(p.unit.id)) toggleExpand(p.unit.id)
            return true
        }
        const u = p.unit
        if (p.field === "speed") {
            const v = fieldView(u, "speed")
            const lim = limits.speed || [0, 4]
            const n = Math.max(lim[0], Math.min(lim[1], Number(v ? v.value : 2) + d))
            setField(u, "speed", n)
            return true
        }
        const cycle = (list, cur) => list[(Math.max(0, list.indexOf(cur)) + d + list.length) % list.length]
        if (p.field === "direction") { const v = fieldView(u, "direction"); setField(u, "direction", cycle(limits.directions || ["Clockwise", "CounterClockwise"], v ? v.value : "")); return true }
        if (p.field === "span") { const v = fieldView(u, "span"); setField(u, "span", cycle(limits.ram_spans || ["across", "stick"], v ? v.value : "across")); return true }
        if (p.field === "shape") { setShape(u, unitShape(u) === "solid" ? "gradient" : "solid"); return true }
        return false
    }
    function toggleLedSafe() {
        const on = (draft.palette || {}).led_safe !== false
        service.editSet("/palette/led_safe", on ? false : null)
    }
    readonly property bool calibratedHere: !!cal && !!view && (draft.led || {}).calibrated_for === (cal.machine || view.machine)
    function toggleCalibrated() {
        if (!cal) return
        service.editSet(cal.path || "/led/calibrated_for", calibratedHere ? null : String(cal.machine || view.machine || ""))
    }

    // ---- screens (contract v1.3) ------------------------------------------------
    // The editor view says whether this draft's screens can be edited here
    // (a v3 theme on a PC whose profile has screen roles); the Service reads
    // `theme screens` for the map once it can.
    readonly property var screensView: hasService && service.screensView !== undefined ? service.screensView : null
    readonly property bool screensShown: !!view && !!view.screens && view.screens.editable === true
        && !!screensView && Array.isArray(screensView.screens) && screensView.screens.length > 0
    readonly property var screenOrder: {
        if (!screensShown) return []
        const all = screensView.screens.filter(s => s && s.role && s.managed !== false).map(s => String(s.role))
        const order = screensView.map && Array.isArray(screensView.map.order) ? screensView.map.order.filter(r => all.indexOf(r) >= 0) : []
        return order.concat(all.filter(r => order.indexOf(r) < 0))
    }
    // The screens part of a live preview (preview.json `screens`); an engine
    // without it previews the lights only.
    readonly property bool screensLive: hasService && service.previewLive === true && !!service.preview && !!service.preview.screens
    function jobFor(role) { return hasService && typeof service.jobFor === "function" ? service.jobFor(role) : null }
    function screenPreviewOf(role) { return hasService && typeof service.screenPreview === "function" ? service.screenPreview(role) : null }
    readonly property var screensLine: screensShown ? Format.mapLine(screensView.screens, r => root.jobFor(r), r => root.screenPreviewOf(r),
                                                                      { previewLive: screensLive, screensOn: !hasService || service.screens !== "off" })
                                                    : ({ text: "", level: "", action: "", role: "", tip: "" })
    function openScreen(role, step) {
        if (!role) return
        closePicker()
        menu.close(); ask.close()
        screenRequested(String(role), String(step || ""))
    }
    function screensAct() {
        const l = screensLine
        if (l.action === "retry") { const j = jobFor(l.role); if (j && hasService) service.retryMedia(j.id) }
        else if (l.action === "choose") openScreen(l.role, "pick")
    }
    // Media still preparing for this draft: Save waits for it.
    readonly property var runningJobs: hasService && Array.isArray(service.mediaJobs) ? service.mediaJobs.filter(j => Format.jobRunning(j)) : []
    readonly property string jobsBlock: {
        if (runningJobs.length === 0) return ""
        const j = runningJobs[0]
        const s = screensView && Array.isArray(screensView.screens) ? screensView.screens.find(x => x && x.role === j.role) : null
        return "Waiting for the " + Format.screenMediaNoun(j.role, j.source ? j.source.kind : "", s ? s.short : "") + " to finish preparing"
    }

    // ---- saving and leaving ------------------------------------------------------
    readonly property var allNames: {
        const n = (hasService && service.themes ? service.themes : []).map(t => t.name)
        for (const d of (hasService && service.drafts ? service.drafts : [])) if (d && d.name && d.name !== name) n.push(d.name)
        return n
    }
    readonly property string saveName: mode === "edit" ? name : (targetName || name)
    readonly property string targetProblem: mode === "edit" ? "" : Format.nameProblem(saveName, allNames.filter(x => x !== name))
    readonly property string saveBlock: targetProblem !== "" ? "Rename it first: " + targetProblem.toLowerCase()
        : errors.length ? "Fix what stops a save first" : jobsBlock
    readonly property bool applies: mode === "edit" && saved.active === true && lightsOn
    readonly property bool canSave: unsaved && saveBlock === "" && edState !== "saving" && !!view
    function requestSave() {
        if (!canSave) return
        saveRequested(saveName, applies)
        service.saveTheme({ apply: null, asName: mode !== "edit" && saveName !== name ? saveName : null, force: false })
    }
    function saveCopy(slug) {
        if (!slug) return
        saveRequested(slug, false)
        service.saveTheme({ apply: false, asName: slug, force: false })
    }
    function overwrite() {
        saveRequested(name, applies)
        service.saveTheme({ apply: null, asName: null, force: true })
    }
    function discard() {
        closePicker()
        if (mode === "edit") { resumed = false; service.revertEdits() }
        else { service.closeEditor(false); backRequested() }
    }
    // LightsContent closes the editor (keeping the draft when there is one)
    // and opens the New theme page on a copy.
    function duplicate() { copyRequested(name, unsaved) }
    // Closing the editor clears `name`: take it first.
    function deleteTheme() {
        const n = name
        service.closeEditor(false)
        service.deleteTheme(n)
        backRequested()
    }
    // Esc and ←: the picker, then a popup, then leave. The engine keeps the
    // draft, so leaving never asks; an untouched draft is dropped.
    function back() {
        if (pickerKey) { closePicker(); return }
        if (menu.opened || ask.opened) { menu.close(); ask.close(); return }
        service.closeEditor(block !== "" || !view || unsaved)
        backRequested()
    }
    function jumpTo(path) {
        path = String(path || "")
        if (path.indexOf("/palette/") === 0) {
            const k = path.split("/")[2]
            if (k === "alert" || k === "led_safe") advanced = true
            cursorKey = "pal:" + k; keyNav = true
            Qt.callLater(() => showRequested(items[cursorKey] || null))
            return
        }
        for (const u of units) {
            for (const n of Object.keys(u.fields || {})) {
                const fp = String((u.fields[n] || {}).path || "")
                if (fp && (path === fp || path.indexOf(fp + "/") === 0 || fp.indexOf(path + "/") === 0)) {
                    const up = parentOf(u.id)
                    if (up) { if (!isExpanded(up)) toggleExpand(up); if (!isMore(up)) toggleMore(up) }
                    if (!isExpanded(u.id)) toggleExpand(u.id)
                    cursorKey = "field:" + u.id + ":" + n
                    keyNav = true
                    Qt.callLater(() => showRequested(items[cursorKey] || items["unit:" + u.id] || null))
                    return
                }
            }
        }
    }
    // A problem in words: the part it belongs to, then what the engine says
    // without its dotted path ("Strimers: must be exactly 6 colours").
    function problemText(p) {
        const msg = String(p && p.message || "").replace(/^[a-z0-9_.@-]*\.[a-z0-9_.@-]+\s+/i, "").replace(/[.\s]+$/, "")
            .replace(/\bhex colours\b/g, "colours").replace(/\bmust be 6 hex digits\b/, "isn't a colour")
        const path = String(p && p.path || "")
        let where = ""
        if (path.indexOf("/palette/") === 0) where = Format.colourRole(path.split("/")[2])
        else for (const u of units) {
            if (Object.keys(u.fields || {}).some(n => { const fp = String((u.fields[n] || {}).path || ""); return fp && (path === fp || path.indexOf(fp + "/") === 0) })) {
                where = partTitle(u)
                break
            }
        }
        return (where ? where + ": " : "") + msg
    }

    // ---- popups (⋯ and its confirms) ---------------------------------------------
    function openMenu() {
        const auto = !!view && view.auto === true
        const conflict = !!view && view.conflict === true
        const list = []
        if (mode === "edit") {
            if (conflict) list.push({ key: "overwrite", label: "Overwrite the saved theme", glyph: "󰠘" })
            list.push({ key: "saveas", label: "Save as copy…", glyph: "󰆏", enabled: !!view && edState !== "saving" })
            list.push({ key: "discard", label: "Discard changes", glyph: "󰕌", enabled: dirty, tip: dirty ? "" : "Nothing to discard" })
            list.push({ key: "duplicate", label: "Duplicate", glyph: "󰆑" })
            list.push({ key: "rename", label: "Rename…", glyph: "󰑕", enabled: !auto, tip: auto ? "Themes made from Omarchy keep their name; duplicate it instead." : "" })
            list.push({ key: "delete", label: "Delete…", glyph: "󰧧", danger: true })
        } else {
            list.push({ key: "rename", label: "Rename…", glyph: "󰑕" })
            list.push({ key: "discard", label: "Discard this theme…", glyph: "󰧧", danger: true })
        }
        menu.items = list
        menu.openAt(menuButton)
    }
    readonly property string inUse: saved.active ? "your active theme" : saved.day ? "your day theme"
        : saved.night ? "the night theme" : (saved.mapped_slugs || []).length ? "matched to Omarchy's " + saved.mapped_slugs.join(", ") : ""
    function openAsk(kind, typed) {
        const n = Format.themeName(saveName)
        ask.kind = kind
        ask.askName = kind === "rename" || kind === "saveas"
        ask.names = allNames
        ask.current = kind === "rename" ? saveName : ""
        ask.cancelText = "Cancel"
        ask.confirmKind = "primary"
        if (kind === "rename") { ask.question = "Rename " + n; ask.nameText = typed || n; ask.confirmText = "Rename" }
        else if (kind === "saveas") { ask.question = "Save your changes as a new theme. " + n + " stays as it was."; ask.nameText = typed || Format.freeDisplay(n + " copy", allNames); ask.confirmText = "Save copy" }
        else if (kind === "discard") {
            ask.question = mode === "edit" ? "Discard your changes to " + n + "? It goes back to how it was saved." : "Discard " + n + "? It was never saved."
            ask.confirmText = "Discard"; ask.confirmKind = "danger"
        } else if (kind === "delete") {
            ask.question = inUse ? n + " is " + inUse + ". Pick or match another theme first." : "Delete " + n + "? It moves to the theme trash."
            ask.confirmText = inUse ? "" : "Delete"; ask.confirmKind = "danger"; ask.cancelText = inUse ? "OK" : "Cancel"
        }
        Qt.callLater(() => ask.openAt(menuButton))
    }
    function menuChosen(key) {
        if (key === "overwrite") overwrite()
        else if (key === "duplicate") duplicate()
        else openAsk(key)
    }
    function answered(kind, slug) {
        if (kind === "rename") {
            if (!slug || slug === saveName) return
            if (mode === "edit") service.renameTheme(name, slug)
            else targetName = slug
        } else if (kind === "saveas") saveCopy(slug)
        else if (kind === "discard") discard()
        else if (kind === "delete") deleteTheme()
    }
    function popupBottom() {
        let b = 0
        for (const p of [menu, ask]) if (p.opened && p.contentItem) b = Math.max(b, p.contentItem.mapToItem(null, 0, p.contentItem.height).y + p.bottomPadding)
        return b
    }

    Component.onCompleted: {
        const i = initial || {}
        if (Array.isArray(i.expanded)) { const e = {}; for (const id of i.expanded) e[id] = true; expanded = e }
        if (Array.isArray(i.more)) { const m = {}; for (const id of i.more) m[id] = true; more = m }
        if (i.advanced) advanced = true
        targetName = i.name !== undefined ? String(i.name) : ""
        resumed = i.resumed === true
        previewOnOpen = i.previewOnOpen === true
        if (Array.isArray(i.recent)) recent = i.recent
        if (i.picker) { pickerKey = String(i.picker); pickerOriginal = i.pickerOriginal ? String(i.pickerOriginal) : pickerValue }
        if (i.cursor !== undefined) { keyNav = true; cursorKey = typeof i.cursor === "number" ? rows[i.cursor] || "" : String(i.cursor) }
        if (Array.isArray(i.keys)) Qt.callLater(() => replayKeys(i.keys))
        if (i.keyFocus) Qt.callLater(() => { if (pickerItem) { pickerItem.keyFocus = true; pickerItem.part = Number(i.pickerPart || 0) } })
        if (i.menu) Qt.callLater(openMenu)
        if (i.confirm) openAsk(String(i.confirm.kind || i.confirm), i.confirm.name ? String(i.confirm.name) : "")
        if (view && previewOnOpen) Qt.callLater(showOnCase)
    }
    // A theme just made: show it on the case as soon as its view is there.
    function showOnCase() {
        if (!previewOnOpen || !hasService) return
        previewOnOpen = false
        if (service.previewEnabled && lightsOn && !service.previewUnmeasured) service.previewNow()
    }
    onViewChanged: if (view && previewOnOpen) Qt.callLater(showOnCase)
    onPendingChanged: if (pending) resumed = false

    // ---- keyboard ---------------------------------------------------------------
    function textFocused() {
        const f = root.Window.activeFocusItem
        return !!f && f !== root && f.echoMode !== undefined && f.selectByMouse !== undefined
    }
    function dropdownOpen() {
        for (const id of Object.keys(strimers)) if (strimers[id] && strimers[id].dropdownOpen) return true
        return false
    }
    Keys.onPressed: function(event) { handleKey(event) }
    // Also driven by the render harness (ui.editor.keys) with plain objects.
    function handleKey(event) {
        if (dropdownOpen()) return
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (ctrl && event.key === Qt.Key_S) { requestSave(); event.accepted = true; return }
        if (textFocused()) {
            if (event.key === Qt.Key_Escape) { root.forceActiveFocus(); event.accepted = true }
            return
        }
        if (pickerKey && pickerItem && event.key !== Qt.Key_Escape && pickerItem.handleKey(event)) { event.accepted = true; return }
        if (event.key === Qt.Key_Escape) { back(); event.accepted = true; return }
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) { openMenu(); event.accepted = true; return }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) { event.accepted = true; return }
        if (event.key === Qt.Key_Down || event.text === "j") { moveCursor(1); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.text === "k") { moveCursor(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { if (step(cursorKey, 1)) event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { if (step(cursorKey, -1)) event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (cursorKey) activate(cursorKey)
            event.accepted = true
            return
        }
        if (event.text === "r") { resetKey(cursorKey); event.accepted = true; return }
        if (event.text === "p") { service.setPreviewEnabled(!service.previewEnabled); event.accepted = true; return }
    }
    // Replays [{key, text, modifiers}] (the harness's keyboard walk).
    function replayKeys(list) {
        for (const k of (list || [])) {
            const e = { key: Number(k.key || 0), text: String(k.text || ""), modifiers: Number(k.modifiers || 0), accepted: false }
            handleKey(e)
        }
    }

    // ---- the page -----------------------------------------------------------------
    readonly property string title: block !== "" ? "Theme editor" : Format.themeName(saveName) || "New theme"
    // The engine's own line (a save that waits, a failure), when it isn't a
    // conflict (that has its own notice) or a block (the page says why).
    readonly property string engineLine: block === "" && hasService && service.editorError && service.editorErrorCode !== "conflict" && view !== null
        ? String(service.editorError) : ""

    ColumnLayout {
        id: body
        width: root.width
        spacing: 0

        // header
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            IconButton {
                id: backButton
                glyph: "󰁍"   // nf-md-arrow_left
                tooltipText: "Back to themes"
                Layout.leftMargin: -Style.space(6)
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.back()
            }
            Label {
                id: titleLabel
                text: root.title
                font.pixelSize: Style.font.heading
                font.bold: true
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                // As wide as the name, up to what the header's controls leave.
                Layout.preferredWidth: Math.min(implicitWidth, Math.max(Style.space(60), body.width - backButton.width + Style.space(6)
                    - (unsavedMark.visible ? unsavedMark.implicitWidth : 0) - (saveButton.visible ? saveButton.implicitWidth : 0)
                    - (menuButton.visible ? menuButton.width : 0) - Style.space(8) * 5))
                Layout.alignment: Qt.AlignVCenter
                MouseArea { id: titleMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                Ui.PanelToolTip { visible: titleMouse.containsMouse && titleLabel.truncated; text: titleLabel.text }
            }
            Row {
                id: unsavedMark
                visible: root.block === "" && !!root.view && root.unsaved
                spacing: Style.space(4)
                Layout.alignment: Qt.AlignVCenter
                Layout.topMargin: Style.space(2)
                Rectangle {
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: Commons.Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                }
                Label {
                    text: root.edState === "saving" ? "Saving…" : "Unsaved"
                    tone: "muted"
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.NoWrap
                }
            }
            Item { Layout.fillWidth: true }
            Action {
                id: saveButton
                visible: root.block === ""
                kind: "primary"
                text: root.edState === "saving" ? "Saving…" : "Save"
                enabled: root.canSave
                tooltipText: root.saveBlock !== "" ? root.saveBlock : !root.unsaved ? "Nothing changed yet"
                    : root.applies ? "Save and put it on the case (about 20 s)" : "Save " + Format.themeName(root.saveName)
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.requestSave()
            }
            IconButton {
                id: menuButton
                visible: root.block === "" && !!root.view
                glyph: "󰇘"   // nf-md-dots_horizontal
                tooltipText: "More"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.openMenu()
            }
        }

        // Not editable here (before the cut-over, an old engine, a v2 theme).
        Notice {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.block !== ""
            text: root.block === "no-profile" ? "Editing needs a hardware profile. Detect your hardware, then update your themes once."
                : root.block === "v2" ? (root.name ? Format.themeName(root.name) + " uses the old theme format. " : "") + "Update your themes once to edit them here."
                : Format.editBlockText(root.block)
            actions: root.block === "no-profile" ? [{ key: "detect", label: "Detect hardware", kind: "primary", enabled: root.hasService && root.service.canChange("detect") },
                                                   { key: "copy", label: "Copy update command", tip: "lumenaire migrate: run it once in a terminal" }]
                : root.block === "v2" ? [{ key: "copy", label: "Copy update command", tip: "lumenaire migrate: run it once in a terminal" }] : []
            onAction: function(k) {
                if (k === "detect") root.service.detect()
                else if (k === "copy") root.service.copyCommand("lumenaire migrate")
            }
        }

        ColumnLayout {
            id: editorBody
            Layout.fillWidth: true
            visible: root.block === "" && root.view !== null
            spacing: 0

            // notices: one line each, one action
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                spacing: Style.space(8)
                visible: (root.resumed && root.unsaved) || root.errors.length > 0 || (!!root.view && root.view.conflict === true)
                    || (!!root.view && root.view.auto === true && root.mode === "edit") || root.engineLine !== ""
                Notice {
                    Layout.fillWidth: true
                    visible: root.resumed && root.unsaved
                    glyph: "󰏫"   // nf-md-pencil
                    text: "You have unsaved changes"
                    actions: [{ key: "keep", label: "Keep editing" }, { key: "discard", label: "Discard…" }]
                    onAction: function(k) { if (k === "keep") root.resumed = false; else root.openAsk("discard") }
                }
                Notice {
                    Layout.fillWidth: true
                    visible: root.errors.length > 0
                    level: "urgent"
                    text: "Can't save yet. " + (root.errors.length ? root.problemText(root.errors[0]) : "")
                        + (root.errors.length > 1 ? " (and " + (root.errors.length - 1) + " more)" : "")
                    actions: [{ key: "show", label: "Show" }]
                    onAction: function(k) { root.jumpTo(root.errors[0].path) }
                }
                Notice {
                    Layout.fillWidth: true
                    visible: !!root.view && root.view.conflict === true
                    level: "urgent"
                    text: Format.themeName(root.name) + " was changed outside the editor."
                    actions: [{ key: "saveas", label: "Save as copy…" }]
                    onAction: function(k) { root.openAsk("saveas") }
                }
                Notice {
                    Layout.fillWidth: true
                    visible: !!root.view && root.view.auto === true && root.mode === "edit"
                    text: "Made from your Omarchy theme. Saving stops it following Omarchy."
                    actions: [{ key: "duplicate", label: "Duplicate instead" }]
                    onAction: function(k) { root.duplicate() }
                }
                Notice {
                    Layout.fillWidth: true
                    visible: root.engineLine !== ""
                    level: root.edState === "failed" ? "urgent" : "info"
                    text: root.engineLine
                }
            }

            PreviewStatus {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                service: root.service
                themeName: root.saveName
                cursorKey: root.keyNav ? root.cursorKey : ""
                onRegister: function(k, item) { root.register(k, item) }
            }

            // Colours
            SectionHeader {
                Layout.topMargin: Style.space(24)
                text: "Colours"
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(12)
                spacing: Style.space(16)
                Repeater {
                    model: ["primary", "secondary", "accent"]
                    Swatch {
                        id: palSwatch
                        required property string modelData
                        readonly property string fkey: "pal:" + modelData
                        readonly property var fv: root.fieldView(root.paletteUnit, modelData)
                        size: Style.space(44)
                        hex: fv ? String(fv.value || "") : ""
                        label: Format.colourRole(modelData)
                        tooltipText: Format.colourRole(modelData) + (hex ? " · #" + hex : "")
                            + (modelData === "accent" && fv && fv.source !== "set" ? "\nMade from Main and Second until you pick one" : "")
                        warn: fv ? root.warnCount(fv.hints) > 0 : false
                        selected: root.pickerKey === fkey
                        hasCursor: root.keyNav && root.cursorKey === fkey
                        onClicked: { root.cursorKey = fkey; root.togglePicker(fkey) }
                        Component.onCompleted: root.register(fkey, palSwatch)
                    }
                }
                Item { Layout.fillWidth: true }
            }
            Loader {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(12)
                active: ["pal:primary", "pal:secondary", "pal:accent"].indexOf(root.pickerKey) >= 0
                visible: active
                sourceComponent: root.pickerComponent
            }

            // Parts
            SectionHeader {
                Layout.topMargin: Style.space(24)
                visible: root.units.length > 0
                text: "Parts"
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(8)
                visible: root.units.length > 0
                spacing: Style.space(2)
                Repeater {
                    model: root.partRows
                    RoleRow {
                        required property var modelData
                        Layout.fillWidth: true
                        unit: root.unitById[modelData.id] || ({ id: String(modelData.id), fields: {}, kind: "", form: "colour", depth: modelData.depth })
                        editor: root
                        depth: modelData.depth
                    }
                }
            }

            // Screens: the case map, once the engine has read it.
            Loader {
                Layout.fillWidth: true
                active: root.screensShown
                visible: active
                sourceComponent: ScreensSection { editor: root }
            }

            // Advanced
            Ui.CursorSurface {
                id: advancedRow
                Layout.fillWidth: true
                Layout.topMargin: Style.space(24)
                Layout.leftMargin: -Style.space(8)
                Layout.rightMargin: -Style.space(8)
                implicitHeight: advLine.implicitHeight + Style.space(8)
                hasCursor: advMouse.containsMouse || (root.keyNav && root.cursorKey === "advanced")
                Accessible.role: Accessible.Button
                Accessible.name: "Advanced" + (root.advanced ? ", open" : ", closed")
                Component.onCompleted: root.register("advanced", advancedRow)
                RowLayout {
                    id: advLine
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)
                    Label {
                        text: "Advanced"
                        font.bold: true
                        font.pixelSize: Style.font.subtitle
                        wrapMode: Text.NoWrap
                        Layout.fillWidth: true
                    }
                    Label {
                        text: root.advanced ? "󰅀" : "󰅂"   // nf-md-chevron_down / right
                        tone: "muted"
                        wrapMode: Text.NoWrap
                    }
                }
                MouseArea {
                    id: advMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.cursorKey = "advanced"; root.advanced = !root.advanced }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(12)
                visible: root.advanced
                spacing: Style.space(16)

                Setting {
                    key: "ledsafe"
                    title: "Keep colours vivid on LEDs"
                    sub: "Pale theme colours light the parts at full strength."
                    tip: checked ? "On: parts that follow Main, Second and Accent get them fully saturated, so pastels don't wash out to white"
                                 : "Off: parts that follow the theme colours get them exactly as picked"
                    checked: (root.draft.palette || {}).led_safe !== false
                    onToggled: root.toggleLedSafe()
                }
                Setting {
                    visible: !!root.cal && root.cal.enabled === true
                    key: "calib"
                    title: "Colour correction for this PC"
                    sub: "Evens out how this PC's LEDs show warm colours and pinks."
                    tip: checked ? "On: colours are corrected for this PC's LEDs" : "Off: this theme was tuned on this PC by photo, so colours go out as picked"
                    checked: !root.calibratedHere
                    onToggled: root.toggleCalibrated()
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(2)
                        Label { text: "Heat warning colour"; Layout.fillWidth: true; wrapMode: Text.NoWrap }
                        Label { text: "The fans and pump turn this colour when the PC runs hot."; Layout.fillWidth: true; tone: "muted"; font.pixelSize: Style.font.bodySmall }
                    }
                    Swatch {
                        id: alertSwatch
                        readonly property var fv: root.fieldView(root.paletteUnit, "alert")
                        size: Style.space(26)
                        hex: fv ? String(fv.value || "") : ""
                        tooltipText: "Heat warning" + (hex ? " · #" + hex : " · from the daemon until you pick one")
                        selected: root.pickerKey === "pal:alert"
                        hasCursor: root.keyNav && root.cursorKey === "pal:alert"
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: Style.space(6)
                        onClicked: { root.cursorKey = "pal:alert"; root.togglePicker("pal:alert") }
                        Component.onCompleted: root.register("pal:alert", alertSwatch)
                    }
                }
                Loader {
                    Layout.fillWidth: true
                    active: root.pickerKey === "pal:alert"
                    visible: active
                    sourceComponent: root.pickerComponent
                }
            }
            Item { Layout.preferredHeight: Style.space(4) }
        }

        // Opening: nothing to show but the line.
        Label {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.block === "" && root.view === null
            tone: "muted"
            text: root.edState === "failed" ? String(root.hasService ? root.service.editorError || "" : "") : "Opening…"
        }
    }

    // An Advanced setting: a title, one muted line and the switch.
    component Setting: RowLayout {
        id: setting
        property string title: ""
        property string sub: ""
        property bool checked: false
        property string key: ""
        property string tip: ""
        signal toggled()
        Layout.fillWidth: true
        spacing: Style.space(8)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)
            Label { text: setting.title; Layout.fillWidth: true; wrapMode: Text.NoWrap; elide: Text.ElideRight }
            Label { text: setting.sub; Layout.fillWidth: true; tone: "muted"; font.pixelSize: Style.font.bodySmall }
        }
        Ui.ToggleSwitch {
            id: settingSwitch
            checked: setting.checked
            hasCursor: root.keyNav && root.cursorKey === setting.key
            Layout.alignment: Qt.AlignVCenter
            Accessible.role: Accessible.CheckBox
            Accessible.name: setting.title + (checked ? ", on" : ", off")
            onToggled: setting.toggled()
            Component.onCompleted: root.register(setting.key, settingSwitch)
            Ui.PanelToolTip { visible: settingSwitch.containsMouse && setting.tip !== ""; text: setting.tip }
        }
    }

    MenuPopup {
        id: menu
        onChosen: function(key) { root.menuChosen(key) }
        onClosed: if (!ask.opened) root.forceActiveFocus()
    }
    MenuPopup {
        id: ask
        property string kind: ""
        onConfirmed: function(slug) { root.answered(kind, slug) }
        onClosed: root.forceActiveFocus()
    }
}
