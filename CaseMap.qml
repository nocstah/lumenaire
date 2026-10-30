pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import "Format.js" as Format

// The case as a small map of its screens (DESIGN.md "Screens"): the fans on
// top in a row, the side columns (the right 3-fan column, a front column on
// the left), the pump in the middle and the wide main screen under it, each
// a ScreenTile at its own shape. Where a screen goes comes from the view's
// place hints (theme screens --json: `place`, its group's `place`); a PC
// with other screens (fans along the bottom, a round pump, no 8.8") gets
// its own map from the same rules. Square tiles scale with the width, from
// 40 px at 360 to 56 at 468; the pump is two squares tall; the main screen
// spans the middle, and a side column spans the middle's height.
Item {
    id: root
    property var view: null                // theme screens --json
    property string cursorRole: ""         // the keyboard cursor
    property var jobFor: null              // role -> the newest job, or null
    property var failedFor: null           // role -> bool (a job or the preview failed)
    property var lineFor: null             // role -> its state line, for the tooltip
    signal activated(string role)
    signal register(string role, Item item)

    readonly property var screens: view && Array.isArray(view.screens) ? view.screens : []
    readonly property var groupPlace: {
        const m = {}
        const gs = view && view.map && Array.isArray(view.map.groups) ? view.map.groups : []
        for (const g of gs) if (g && g.group) m[g.group] = String(g.place || "")
        return m
    }
    function placeOf(s) {
        const k = String(s.kind || "")
        if (k === "main" || s.wide === true || s.shape === "strip") return "main"
        const p = String(s.place || groupPlace[s.group] || "")
        if (p === "top" || p === "left" || p === "right" || p === "bottom") return p
        if (p === "centre" || p === "center") return "centre"
        return k === "fan" ? "bottom" : "centre"
    }
    readonly property var layout: {
        const W = Math.max(0, Math.floor(width))
        const g = Style.space(8)
        const sq = Math.round(Math.max(Style.space(40), Math.min(Style.space(56), W * 0.12)))
        const at = { top: [], left: [], right: [], centre: [], bottom: [], main: [] }
        for (const s of screens) if (s && s.role) at[placeOf(s)].push(s)
        const byIndex = (a, b) => (Number(a.index) || 0) - (Number(b.index) || 0)
        for (const k of Object.keys(at)) at[k].sort(byIndex)
        const hasL = at.left.length > 0, hasR = at.right.length > 0
        const x0 = hasL ? sq + g : 0
        const cw = W - x0 - (hasR ? sq + g : 0)
        const tiles = []
        const put = (s, x, y, w, h) => tiles.push({ role: String(s.role), screen: s, x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) })
        const row = (list, y) => {
            const rw = list.length * sq + (list.length - 1) * g
            let x = x0 + (cw - rw) / 2
            for (const s of list) { put(s, x, y, sq, sq); x += sq + g }
        }
        let y = 0
        if (at.top.length) { row(at.top, 0); y = sq + g }
        const band = y
        // The middle: the pump (and any other centre screen), fans placed at
        // the bottom, then the main screen across the middle's width.
        let cy = band
        for (const s of at.centre) {
            const a = Format.screenAspect(s)
            let h = 2 * sq + g, w = h * a
            if (w > cw) { w = cw; h = w / a }
            put(s, x0 + (cw - w) / 2, cy, w, h)
            cy += Math.round(h) + g
        }
        if (at.bottom.length) { row(at.bottom, cy); cy += sq + g }
        for (const s of at.main) {
            const a = Format.screenAspect(s)
            const h = cw / a
            put(s, x0, cy, cw, h)
            cy += Math.round(h) + g
        }
        const stack = Math.max(0, cy - g - band)
        const col = n => n > 0 ? n * sq + (n - 1) * g : 0
        const bandH = Math.max(stack, col(at.left.length), col(at.right.length))
        // A side column spans the middle: its first tile level with the
        // pump's top, its last with the main screen's bottom.
        const side = (list, x) => {
            const n = list.length
            const step = n > 1 ? (bandH - sq) / (n - 1) : 0
            list.forEach((s, i) => put(s, x, n > 1 ? band + i * step : band + (bandH - sq) / 2, sq, sq))
        }
        side(at.left, 0)
        side(at.right, W - sq)
        return { tiles: tiles, height: band + bandH }
    }

    implicitHeight: layout.height
    Accessible.role: Accessible.Grouping
    Accessible.name: "Screens"

    Repeater {
        model: root.layout.tiles
        ScreenTile {
            id: tile
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h
            screen: modelData.screen
            job: root.jobFor ? root.jobFor(modelData.role) : null
            failed: root.failedFor ? root.failedFor(modelData.role) === true : false
            line: root.lineFor ? root.lineFor(modelData.role) : ""
            current: root.cursorRole === modelData.role
            onActivated: root.activated(modelData.role)
            Component.onCompleted: root.register(modelData.role, tile)
        }
    }
}
