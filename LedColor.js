.pragma library
// LED colour maths for the theme editor: hex <-> RGB <-> HSV, the LED-safe
// treatment, calibration and the LED hints. It mirrors the engine's jq
// byte for byte (lib/pc-lights/theme.jq: th_rgb, th_byte, th_tohex, th_hsv,
// th_fromhsv, led_safe_hex, calibrate_hex; lib/pc-lights/editor.jq:
// led_hints), so the picker can show what the LEDs will do while a colour is
// still being dragged. The engine's editor view stays the authority after
// every sync; tests/editor/parity.mjs fails on any byte difference.
//
// Rounding is jq's `round` (C round(): half away from zero), the same
// operations in the same order, on the same doubles.

// ---- jq primitives -----------------------------------------------------------
function jqRound(x) { return x < 0 ? -Math.round(-x) : Math.round(x) }

// th_hex: a 6-digit hex string, "#" optional, any case.
function isHex(v) { return typeof v === "string" && /^#?[0-9a-fA-F]{6}$/.test(v) }

// th_rgb: "#FF4A9A" -> [255, 74, 154]
function rgb(hex) {
    const s = String(hex).replace(/^#/, "").toLowerCase()
    return [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)]
}

// th_byte: round, then clamp to 0-255.
function byte(v) {
    const r = jqRound(v)
    return r < 0 ? 0 : r > 255 ? 255 : r
}

// th_tohex: [r, g, b] (any reals) -> "ff4a9a"
function toHex(c) {
    const d = "0123456789abcdef"
    let out = ""
    for (let i = 0; i < 3; i++) {
        const b = byte(c[i])
        out += d.charAt(Math.floor(b / 16)) + d.charAt(b % 16)
    }
    return out
}

// th_hsv: [r, g, b] 0-255 -> [hue 0-360, saturation 0-1, value 0-1]
function hsv(c) {
    const r = c[0] / 255, g = c[1] / 255, b = c[2] / 255
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
    let h = d === 0 ? 0 : mx === r ? 60 * ((g - b) / d) : mx === g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4)
    if (h < 0) h = h + 360
    return [h, mx === 0 ? 0 : d / mx, mx]
}

// th_fromhsv: [h, s, v] -> [r, g, b] as reals 0-255 (toHex rounds them).
function fromHsv(h, s, v) {
    const x = h / 60, i = Math.floor(x), f = x - i
    const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    const k = i % 6
    const c = k === 0 ? [v, t, p] : k === 1 ? [q, v, p] : k === 2 ? [p, v, t]
        : k === 3 ? [p, q, v] : k === 4 ? [t, p, v] : [v, p, q]
    return [c[0] * 255, c[1] * 255, c[2] * 255]
}

function hexToHsv(hex) { return isHex(hex) ? hsv(rgb(hex)) : [0, 0, 0] }
function hsvToHex(h, s, v) {
    const hh = Math.max(0, Math.min(359.999, Number(h) || 0))
    return toHex(fromHsv(hh, Math.max(0, Math.min(1, Number(s) || 0)), Math.max(0, Math.min(1, Number(v) || 0))))
}

// Lower-case, no "#": what the engine stores. "" for anything else.
function norm(v) { return isHex(v) ? String(v).replace(/^#/, "").toLowerCase() : "" }

// th_mix: the colour a fraction f of the way from a to b.
function mix(a, b, f) {
    const x = rgb(a), y = rgb(b)
    return toHex([x[0] + (y[0] - x[0]) * f, x[1] + (y[1] - x[1]) * f, x[2] + (y[2] - x[2]) * f])
}

// ---- led_safe_hex --------------------------------------------------------------
// Keep the hue, push saturation and value to 1. Near-neutral colours
// (S < 0.15) and anything that isn't a colour come back unchanged.
function ledSafe(hex) {
    if (!isHex(hex)) return hex
    const c = hsv(rgb(hex))
    if (c[1] < 0.15) return hex
    return toHex(fromHsv(c[0], 1, 1))
}

// ---- calibrate_hex -----------------------------------------------------------------
// cls: one calibration class ({warm_gr_max, pink_gr_max, pink_br_max, gain})
// or null (identity). A colour comes back normalised whenever cls is given.
function has(o, k) { return o[k] !== null && o[k] !== undefined }
function calibrate(hex, cls) {
    if (cls === null || cls === undefined || !isHex(hex)) return hex
    let c = rgb(hex)
    if (cls.gain !== null && cls.gain !== undefined && cls.gain !== false)
        c = [byte(c[0] * cls.gain[0]), byte(c[1] * cls.gain[1]), byte(c[2] * cls.gain[2])]
    const R = c[0], G = c[1], B = c[2]
    const hs = hsv(c), hue = hs[0]
    // Near-neutrals pass unchanged, as in theme.jq's calibrate_hex.
    if (R <= 0 || R < G || R < B || hs[1] < 0.15) return toHex(c)
    if (has(cls, "warm_gr_max") && hue >= 0 && hue <= 70 && (G / R) > cls.warm_gr_max) {
        const f = cls.warm_gr_max / (G / R)
        return toHex([R, jqRound(R * cls.warm_gr_max), jqRound(B * f)])
    }
    if (has(cls, "pink_gr_max") && hue >= 290 && hue < 360 && (G / R) > cls.pink_gr_max) {
        const b2 = has(cls, "pink_br_max") ? Math.min(B, jqRound(R * cls.pink_br_max)) : B
        return toHex([R, jqRound(R * cls.pink_gr_max), b2])
    }
    return toHex(c)
}

// ---- led_hints (editor.jq) -------------------------------------------------------
// The user's LED lessons as codes (ed_hint_codes): the green checks need red
// to be the largest channel and skip near-neutrals, as calibration does.
function hintCodes(h, cls) {
    const c = rgb(h)
    const r = c[0], g = c[1], b = c[2]
    const x = hsv(c)
    const hu = x[0], s = x[1], v = x[2]
    const gr = r > 0 ? g / r : 0
    const redmax = r > 0 && r >= g && r >= b && s >= 0.15
    const out = []
    if (s < 0.15 && v > 0.8) out.push("near_white")
    else if (s < 0.45 && v > 0.8) out.push("pastel")
    if (redmax && hu <= 70 && gr > (cls === "tl_fan" ? 0.3 : 0.6)) out.push("warm_green")
    if (redmax && hu >= 290 && gr > 0.4) out.push("pink_green")
    if ((cls === "tl_fan" || cls === "fan") && hu >= 295 && hu <= 320 && b >= 0.8 * r) out.push("violet_magenta")
    if (v < 0.25) out.push("dark")
    return out
}
const HINT_TEXT = {
    near_white: "Near-white reads as plain white on LEDs.",
    pastel: "Pastels wash out towards white on LEDs.",
    warm_green: "Too much green for a warm colour: it comes out lemon-yellow on LEDs.",
    pink_green: "Too much green for a pink: it turns white on LEDs.",
    violet_magenta: "Magenta leans violet on fans; for hot pink add red and drop blue (ff1a8c).",
    dark: "Dark colours read muddy or off on LEDs."
}
function classIn(table, cls) {
    const t = table || {}
    const c = t[cls]
    return c === undefined || c === null ? null : c
}
// led_hints($hex; $cls; $cal): [{code, level, text, fix}] for one colour on
// class cls. cal is the view's calibration object {applies, classes,
// fix_classes}: fix is the lianli-photo preset's correction (pastel and dark
// made LED-safe first, violet_magenta ff1a8c, near_white none), and when
// calibration applies and changes the colour, a hint it cures is "info".
function hints(hex, cls, cal) {
    if (!isHex(hex)) return []
    const c = cal || {}
    const h = String(hex).replace(/^#/, "").toLowerCase()
    const fc = classIn(c.fix_classes, cls)
    const x = c.applies === true ? calibrate(h, classIn(c.classes, cls)) : h
    const after = hintCodes(x, cls)
    return hintCodes(h, cls).map(function(code) {
        const o = { code: code }
        // warm_green and pink_green are what calibration's green cut cures
        // (rounding can leave G/R a hair over); others when they're gone.
        if (x !== h && (code === "warm_green" || code === "pink_green" || after.indexOf(code) < 0)) { o.level = "info"; o.text = "Calibration corrects this on this PC: the LEDs get " + x + "." }
        else { o.level = "warn"; o.text = HINT_TEXT[code] }
        let fix = code === "near_white" ? null : code === "violet_magenta" ? "ff1a8c"
            : code === "pastel" || code === "dark" ? calibrate(ledSafe(h), fc) : calibrate(h, fc)
        o.fix = fix === h ? null : fix
        return o
    })
}

// What the LEDs show for a colour on a class: calibrated when calibration
// applies, otherwise as written.
// ed_palette's hints for one palette colour: val as written, use what
// derivation draws from (LED-safe or not), classes the classes this PC's
// roles use (the view's palette.primary.shows keys, in the engine's order).
function paletteHints(val, use, classes, cal) {
    const out = use !== val && isHex(use) ? [{ code: "led_safe", level: "info", text: "Derived lights use " + use + " (made LED-safe).", fix: null }] : []
    for (const c of (classes || []))
        for (const h of hints(use, c, cal))
            if (!out.some(function(o) { return o.code === h.code })) out.push(h)
    return out
}

// ed_show for one colour: cal is the view's calibration object.
function shows(hex, cls, cal) {
    return cal && cal.applies === true ? calibrate(hex, classIn(cal.classes, cls)) : hex
}

// Relative luminance (0-1), for choosing a readable mark over a swatch.
function luminance(hex) {
    if (!isHex(hex)) return 0
    const c = rgb(hex).map(function(u) { const s = u / 255; return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4) })
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}
