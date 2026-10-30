import QtQuick
import qs.Commons
import qs.Ui as Ui

// One live reading in the panel's top row (DESIGN.md "Readings"): a muted
// caption over a big tabular number and its unit. The tooltip carries the
// detail (each fan group, GPU load and power, a reading's age).
//
//   level "fresh"    the number in the popup text colour
//   level "hot"      the number in urgent (at or over its alert threshold)
//   level "missing"  "—", no unit (no reading, or one too old to trust)
Item {
    id: root
    property string caption: ""
    property string value: ""
    property string unit: ""
    property string level: "fresh"
    property string tooltipText: ""
    readonly property bool hasValue: level !== "missing" && value !== "" && value !== "—"

    implicitWidth: Math.max(cap.implicitWidth, line.implicitWidth)
    implicitHeight: cap.implicitHeight + Style.space(2) + line.implicitHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: caption + " " + (hasValue ? value + " " + unit : "not available")

    Label {
        id: cap
        width: parent.width
        text: root.caption
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        Accessible.ignored: true
    }
    Row {
        id: line
        y: cap.implicitHeight + Style.space(2)
        spacing: Style.space(4)
        Label {
            id: number
            text: root.hasValue ? root.value : "—"
            tone: !root.hasValue ? "muted" : root.level === "hot" ? "urgent" : "text"
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.NoWrap
            Accessible.ignored: true
        }
        Label {
            anchors.baseline: number.baseline
            visible: root.hasValue && root.unit !== ""
            text: root.unit
            tone: root.level === "hot" ? "urgent" : "muted"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            Accessible.ignored: true
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }
    Ui.PanelToolTip {
        visible: mouse.containsMouse && root.tooltipText !== ""
        text: root.tooltipText
    }
}
