pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// Under the picker, one compact line about what the LEDs will really do
// (DESIGN.md "LED hint"): "On the LEDs ■ → ■" when calibration or the vivid
// palette changes the colour, then at most one short warning ("Pale colours
// look white on LEDs") with its fix as a small button, "■ Use". Hints are
// advice in the text colour; only a problem that stops a save is urgent.
ColumnLayout {
    id: root
    property string hex: ""
    property string shows: ""          // what the LEDs show; "" or == hex: no line
    property var hints: []
    signal useColour(string hex)

    readonly property bool corrected: shows !== "" && shows !== hex
    readonly property var warn: (hints || []).find(h => h && h.level === "warn") || null
    readonly property string warnText: warn ? (Format.ledHintShort(warn.code) || String(warn.text || "")) : ""
    readonly property string fix: warn && warn.fix && warn.fix !== hex ? String(warn.fix) : ""
    readonly property bool shown: corrected || warn !== null
    spacing: Style.space(8)

    component Chip: Rectangle {
        property string hex: ""
        implicitWidth: Style.space(14)
        implicitHeight: Style.space(14)
        radius: Math.min(Style.cornerRadius, width / 4)
        color: "#" + (hex || "000000")
        border.width: 1
        border.color: Style.normalBorderColor
    }

    RowLayout {
        Layout.fillWidth: true
        visible: root.corrected
        spacing: Style.space(4)
        Label { text: "On the LEDs"; tone: "muted"; font.pixelSize: Style.font.bodySmall; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
        Chip { hex: root.hex; Layout.alignment: Qt.AlignVCenter; Layout.leftMargin: Style.space(2) }
        Label { text: "→"; tone: "muted"; font.pixelSize: Style.font.bodySmall; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
        Chip { hex: root.shows; Layout.alignment: Qt.AlignVCenter }
        Item { Layout.fillWidth: true }
    }
    RowLayout {
        Layout.fillWidth: true
        visible: root.warn !== null
        spacing: Style.space(8)
        Label {
            text: "󰀪"   // nf-md-alert_outline
            tone: "accent"
            font.pixelSize: Style.font.body
            wrapMode: Text.NoWrap
            Layout.alignment: Qt.AlignVCenter
            Accessible.ignored: true
        }
        Label {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.warnText
            font.pixelSize: Style.font.bodySmall
        }
        // The fix: a small outlined button with the colour it picks.
        Ui.BorderSurface {
            id: fixButton
            visible: root.fix !== ""
            readonly property bool hot: fixMouse.containsMouse
            implicitWidth: fixRow.implicitWidth + Style.space(8) * 2
            implicitHeight: fixRow.implicitHeight + Style.space(4) * 2
            radius: Style.cornerRadius
            color: hot ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
            borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", Color.popups.text, Color.accent)
            Layout.alignment: Qt.AlignVCenter
            Accessible.role: Accessible.Button
            Accessible.name: "Use " + root.fix
            Accessible.onPressAction: root.useColour(root.fix)
            RowLayout {
                id: fixRow
                anchors.centerIn: parent
                spacing: Style.space(4)
                Chip { hex: root.fix; Layout.alignment: Qt.AlignVCenter }
                Label { text: "Use"; font.pixelSize: Style.font.bodySmall; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
            }
            MouseArea { id: fixMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.useColour(root.fix) }
            Ui.PanelToolTip { visible: fixMouse.containsMouse; text: "Use #" + root.fix + ", the nearest colour that looks right on LEDs" }
        }
    }
}
