import QtQuick
import qs.Commons
import "Look.js" as Look

// All of the panel's own text. `tone` picks the colour from the Omarchy
// palette (DESIGN.md "Colors"): "text" (the popup text), "muted" (captions,
// states, details), "accent" (active and custom states), "urgent" (failures,
// hot values). A tone that reads too faintly on this theme's popup is moved
// towards the popup text until it passes WCAG AA, so a light theme's red or
// grey never goes pale. Numbers are tabular by default.
Text {
    property string tone: "text"
    readonly property color toneColor: tone === "muted" ? Look.readable(Color.muted, Color.background, Color.popups.text, 4.5)
        : tone === "accent" ? Look.readable(Color.accent, Color.background, Color.popups.text, 4.5)
        : tone === "urgent" ? Look.readable(Color.urgent, Color.background, Color.popups.text, 4.5)
        : Color.popups.text
    textFormat: Text.PlainText
    color: toneColor
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    font.features: { "tnum": 1 }
    wrapMode: Text.Wrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
