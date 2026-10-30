import QtQuick
import qs.Commons
import qs.Ui as Ui

// A Nerd Font glyph as a button (DESIGN.md "Buttons"): square, borderless at
// rest, the host hover-cursor fill and ring on hover, keyboard cursor
// (`hasCursor`) or focus, and always a tooltip that names the action.
// `backdrop` gives it an opaque plate for sitting on a picture.
Ui.Button {
    id: root
    property string glyph: ""
    property bool backdrop: false
    readonly property int side: Style.space(28)

    iconText: glyph
    iconSize: Style.font.heading
    text: ""
    focusable: true
    horizontalPadding: 0
    verticalPadding: 0
    implicitWidth: side
    implicitHeight: side
    foreground: Color.popups.text
    readonly property color plate: backdrop ? Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.88) : "transparent"
    readonly property color stateFill: _showFocusRing ? Style.focusFillFor(foreground, accent) : hot ? Style.hoverFillFor(foreground, accent) : "transparent"
    color: backdrop ? Qt.tint(plate, stateFill) : stateFill
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Button
    Accessible.name: tooltipText
    Accessible.onPressAction: if (enabled) clicked()
}
