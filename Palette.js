.pragma library
.import "LedColor.js" as LedColor
// Palettes for the New theme page: from one main colour, from the Omarchy
// desktop's colours, or at random. Every generated colour is an LED colour: a
// saturated hue at full value, outside the two bands these LEDs render badly
// (docs/THEMES.md, the LED lessons): amber to yellow comes out lemon (too much
// green for a warm colour), and the magenta band leans violet on fan frames.
// The main colour the user picks is kept exactly as picked; the editor's LED
// hint speaks for it.
//
// The engine derives everything else from these three (theme new --palette);
// nothing here writes a theme.

// Hue bands (degrees, exclusive) a generated colour stays out of.
const WARM = [19, 75]
const MAGENTA = [292, 315]
// How far apart two generated hues stay, so the LEDs tell them apart.
const APART = 18

function wrap(h) { return ((h % 360) + 360) % 360 }
function dist(a, b) { const d = Math.abs(wrap(a) - wrap(b)); return Math.min(d, 360 - d) }
function inBand(h, b) { const x = wrap(h); return x > b[0] && x < b[1] }
function avoided(h) { return inBand(h, WARM) || inBand(h, MAGENTA) }
function led(h) { return LedColor.hsvToHex(wrap(h), 1, 1) }
// A hue off the bands: warm hues fall back to orange (the LEDs make gold
// lemon) unless they are nearly green already; magenta goes to the nearer edge.
function snap(h) {
    const x = wrap(h)
    if (inBand(x, WARM)) return x <= 62 ? WARM[0] : WARM[1]
    if (inBand(x, MAGENTA)) return x - MAGENTA[0] <= MAGENTA[1] - x ? MAGENTA[0] : MAGENTA[1]
    return x
}
// Whether stepping s degrees from h crosses the warm band (orange to lime
// is a different family, not a neighbour).
function crossesWarm(h, s) {
    if (inBand(h, WARM)) return false
    for (let k = 1; k < Math.abs(s); k++) if (inBand(h + Math.sign(s) * k, WARM)) return true
    return false
}
// The hue about `want` degrees from h (its sign is the preferred side), off
// the bands, not across the warm band, and at least APART from `taken`.
function near(h, want, taken) {
    let best = null, cost = 1e9
    for (let s = -150; s <= 150; s++) {
        if (Math.abs(s) < APART) continue
        const x = wrap(h + s)
        if (avoided(x) || crossesWarm(h, s) || !taken.every(t => dist(t, x) >= APART)) continue
        const c = Math.abs(s - want)
        if (c < cost) { cost = c; best = x }
    }
    return best === null ? snap(h + want) : best
}

// Main colours that read true on these LEDs (the colour picker's LED presets).
const PRESETS = ["ff0000", "ff4d00", "ff0059", "ff1a8c", "c000ff", "7a00ff", "0030ff", "00a0ff", "00e5ff", "00ffd0", "00ff40", "a6ff00"]

// Three hues as a palette: the accent sits between main and second when they
// are far enough apart, else on the main colour's other side.
function three(ph, sh) {
    const d = ((sh - ph + 540) % 360) - 180
    const mid = wrap(ph + d / 2)
    const ah = Math.abs(d) >= 2 * APART && !avoided(mid) ? mid : near(ph, d < 0 ? 30 : -30, [ph, sh])
    return { primary: led(ph), secondary: led(sh), accent: led(ah) }
}

// "00e5ff" -> the main colour and two neighbours on the wheel (an analogous
// palette), so the fans' inner and outer rings and the Strimer mix stay one
// family. White and greys get a cool-white family, as the Omarchy auto-themes
// do.
function fromMain(hex) {
    const n = LedColor.norm(hex)
    if (!n) return null
    const c = LedColor.hexToHsv(n)
    if (c[1] < 0.15) return { primary: n, secondary: "9fb4ff", accent: "d8e0ff" }
    const h = c[0]
    // A gold or amber main colour keeps its neighbours on the red side.
    const second = near(h, -30, [h])
    const accent = near(h, inBand(h, WARM) ? -60 : 30, [h, second])
    return { primary: n, secondary: led(second), accent: led(accent) }
}

// A colours.toml (an Omarchy theme's colours) -> {key: "rrggbb"}.
function tomlColours(text) {
    const out = {}
    for (const line of String(text || "").split("\n")) {
        const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?#?([0-9A-Fa-f]{6})\b/)
        if (m) out[m[1]] = m[2].toLowerCase()
    }
    return out
}

// The desktop's colours as an LED palette, the way auto-theme picks them: the
// accent's hue (or the most colourful one) for the main colour, the most
// colourful distinct hue within reach for the second (a light theme stays
// near its accent), each saturated to full for the LEDs. null when the text
// holds no colour at all.
function fromDesktop(text) {
    const pal = tomlColours(text)
    const light = /^\s*mode\s*=\s*["']?light/m.test(String(text || ""))
    const keys = ["accent", "red", "green", "yellow", "blue", "magenta", "cyan", "orange", "bright_red", "bright_green",
                  "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan"]
    const cands = []
    for (const k of keys) {
        if (!pal[k]) continue
        const c = LedColor.hexToHsv(pal[k])
        if (c[1] >= 0.15 && c[2] >= 0.15) cands.push({ key: k, h: c[0], score: Math.pow(c[1], 0.7) * Math.pow(c[2], 0.3) })
    }
    if (cands.length === 0) return Object.keys(pal).length ? { primary: "ffffff", secondary: "9fb4ff", accent: "d8e0ff" } : null
    const acc = cands.find(c => c.key === "accent")
    const main = acc || cands.reduce((a, b) => b.score > a.score ? b : a)
    const ph = snap(main.h)
    const reach = light ? 60 : 100
    const fits = c => { const x = snap(c.h); return c !== main && dist(x, ph) >= 20 && dist(x, ph) <= reach && !crossesWarm(ph, ((x - ph + 540) % 360) - 180) }
    const near2 = cands.filter(fits)
    const sh = near2.length ? snap(near2.reduce((a, b) => b.score > a.score ? b : a).h) : near(ph, -30, [ph])
    return three(ph, sh)
}

// A random palette from a seed (the same seed, the same palette): a good hue,
// then its neighbours (two times in three) or a split complement.
function surprise(seed) {
    let s = (Number(seed) >>> 0) || 1
    const rnd = () => { s = (s * 1103515245 + 12345) % 4294967296; return s / 4294967296 }
    let h = rnd() * 360
    for (let i = 0; i < 8 && avoided(h); i++) h = rnd() * 360
    h = snap(h)
    const want = rnd() < 2 / 3 ? [-30, 30] : [150, -150]
    const second = near(h, want[0], [h])
    const accent = near(h, want[1], [h, second])
    return { primary: led(h), secondary: led(second), accent: led(accent) }
}

// A colour in words, for a suggested theme name: "00e5ff" -> "Neon Cyan".
function colourName(hex) {
    const n = LedColor.norm(hex)
    if (!n) return "Colour"
    const c = LedColor.hexToHsv(n)
    const h = c[0], s = c[1], v = c[2]
    if (s < 0.15) return v > 0.8 ? "White" : v > 0.35 ? "Silver" : "Graphite"
    const names = [[8, "Red"], [14, "Scarlet"], [24, "Orange"], [40, "Amber"], [56, "Gold"], [70, "Yellow"], [95, "Lime"],
                   [150, "Green"], [165, "Spring"], [178, "Aqua"], [195, "Cyan"], [210, "Sky"], [232, "Cobalt"], [250, "Blue"],
                   [278, "Violet"], [295, "Purple"], [318, "Magenta"], [335, "Pink"], [345, "Rose"], [361, "Red"]]
    let base = "Red"
    for (const e of names) if (h < e[0]) { base = e[1]; break }
    const mod = v < 0.45 ? "Deep" : s < 0.5 ? "Pale" : s > 0.8 && v > 0.8 ? "Neon" : ""
    return mod ? mod + " " + base : base
}
