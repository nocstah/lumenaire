.pragma library
// Contrast arithmetic for the panel's text tones (DESIGN.md "Colors"): every
// colour comes from the Omarchy palette (Color.*), and a tone that would read
// too faintly on the popup is moved towards the text colour until it passes
// WCAG AA. Colours in and out are QML colors (r, g, b in 0-1).

function channel(u) { return u <= 0.03928 ? u / 12.92 : Math.pow((u + 0.055) / 1.055, 2.4) }
function luminance(c) { return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b) }
function contrast(a, b) {
    const x = luminance(a), y = luminance(b)
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }

// fg itself when it reaches `min` against bg, else the first step from fg
// towards `toward` that does (toward is the popup text, which always does).
function readable(fg, bg, toward, min) {
    for (let t = 0; t <= 1.0001; t += 0.1) {
        const c = mix(fg, toward, t)
        if (contrast(c, bg) >= min) return c
    }
    return toward
}
// Text on a filled surface: whichever of a and b stands out more.
function onFill(fill, a, b) { return contrast(a, fill) >= contrast(b, fill) ? a : b }
