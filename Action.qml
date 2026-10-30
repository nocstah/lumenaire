import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Look.js" as Look

// The panel's text buttons (DESIGN.md "Buttons"), on the host Ui.Button:
//
//   primary    filled accent: the one main action of a view (Save, Create, Next)
//   danger     filled urgent: a destructive action the user confirmed (Delete)
//   secondary  outlined: every other action (＋ New, Retry, Use, Cancel)
//
// Icon-only buttons are IconButton; inline resets ("Use theme colours") are
// TextLink. States are never drawn as buttons. `hasCursor` is the panel's
// keyboard cursor; a filled button shows it as a ring outside its fill.
Ui.Button {
    id: root
    property string kind: "secondary"
    readonly property bool filled: kind === "primary" || kind === "danger"
    readonly property color fill: kind === "danger" ? Color.urgent : Color.accent
    readonly property color onFill: Look.onFill(fill, Color.background, Color.foreground)

    focusable: true
    bordered: !filled
    foreground: filled ? onFill : Color.popups.text
    horizontalPadding: Style.space(12)
    verticalPadding: Style.space(4)
    opacity: enabled ? 1 : 0.45
    color: filled ? (hot || _showFocusRing ? Qt.tint(fill, Qt.rgba(onFill.r, onFill.g, onFill.b, 0.16)) : fill)
        : _showFocusRing ? Style.focusFillFor(foreground, accent)
        : hot ? Style.hoverFillFor(foreground, accent)
        : "transparent"
    borderSpec: filled ? Border.none() : _borderSpec
    Accessible.role: Accessible.Button
    Accessible.name: text || tooltipText
    Accessible.onPressAction: if (enabled) clicked()

    // The keyboard ring of a filled button, outside the fill.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        visible: root.filled && (root.hasCursor || root.activeFocus)
        radius: root.radius > 0 ? root.radius + Style.space(3) : 0
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: root.fill
    }
}
