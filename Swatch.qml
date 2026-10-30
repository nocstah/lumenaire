import QtQuick
import qs.Commons
import qs.Ui as Ui

// A colour you can click (DESIGN.md "Swatches"): a chip of the colour itself
// (data, outlined so near-black and near-white still read), with an
// optional caption under it. It opens the picker; `selected` (the picker is
// open on it) draws an accent ring, hover and the keyboard cursor the host
// hover ring. `warn` adds a small dot in the corner when an LED hint applies.
// No hex text: the tooltip carries the name and the value.
Item {
    id: root
    property string hex: ""
    property string label: ""
    property int size: Style.space(28)
    property bool selected: false
    property bool hasCursor: false
    property bool warn: false
    property bool interactive: true
    property string tooltipText: label !== "" ? label + (hasValue ? " · #" + hex : "") : (hasValue ? "#" + hex : "")
    signal clicked()

    readonly property bool hasValue: /^[0-9a-f]{6}$/.test(hex)
    readonly property int ring: Style.space(3)
    readonly property bool hot: interactive && (mouse.containsMouse || hasCursor || activeFocus)

    implicitWidth: Math.max(size + ring * 2, caption.visible ? caption.implicitWidth : 0)
    implicitHeight: size + ring * 2 + (caption.visible ? caption.implicitHeight + Style.space(4) : 0)
    activeFocusOnTab: interactive
    Accessible.role: Accessible.Button
    Accessible.name: (label || "Colour") + " " + (hasValue ? hex : "not set")
    Accessible.onPressAction: if (interactive && enabled) root.clicked()
    Keys.onReturnPressed: if (interactive) root.clicked()
    Keys.onSpacePressed: if (interactive) root.clicked()

    Rectangle {
        id: chip
        x: Math.round((root.width - root.size) / 2)
        y: root.ring
        width: root.size
        height: root.size
        radius: Math.min(Style.cornerRadius, root.size / 4)
        color: root.hasValue ? "#" + root.hex : "transparent"
        border.width: 1
        border.color: Style.normalBorderColor
        // Unset: a diagonal hairline, the usual "no colour" mark.
        Rectangle {
            visible: !root.hasValue
            anchors.centerIn: parent
            width: parent.width * 1.2
            height: 1
            rotation: -45
            color: Style.normalBorderColor
        }
        // The ring: accent while its picker is open, the hover ring otherwise.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -root.ring
            visible: root.selected || root.hot
            radius: parent.radius > 0 ? parent.radius + root.ring : 0
            color: "transparent"
            border.width: root.selected ? Math.max(1, Style.space(2)) : 1
            border.color: root.selected ? Color.accent : Style.focusBorderFor(Color.popups.text, Color.accent)
        }
        Rectangle {
            visible: root.warn
            width: Style.space(8)
            height: width
            radius: width / 2
            x: parent.width - width / 2 - Style.space(1)
            y: -height / 2 + Style.space(1)
            color: Color.urgent
            border.width: 1
            border.color: Color.background
        }
    }
    Label {
        id: caption
        visible: root.label !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.size + root.ring * 2 + Style.space(4)
        text: root.label
        tone: root.selected ? "text" : "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Accessible.ignored: true
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    Ui.PanelToolTip {
        visible: mouse.containsMouse && root.tooltipText !== ""
        text: root.tooltipText
    }
}
