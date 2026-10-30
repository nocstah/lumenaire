pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui as Ui

// Pick one of a few (DESIGN.md "Parts"): the host Ui.ButtonGroup's chips, with
// the host's corners. options: [{value, label, icon, tooltip}]; an icon-only
// option still names itself in its tooltip. The chosen chip takes the host
// selected fill; `cursorIndex` is the panel's keyboard cursor.
Row {
    id: root
    property var options: []
    property string value: ""
    property int cursorIndex: -1
    property real fontSize: Style.font.bodySmall
    signal changed(string value)
    spacing: Style.space(4)

    Repeater {
        model: root.options
        Ui.Button {
            id: chip
            required property var modelData
            required property int index
            text: String(modelData.label || "")
            iconText: String(modelData.icon || "")
            iconSize: Style.font.title
            fontSize: root.fontSize
            tooltipText: String(modelData.tooltip || "")
            selected: String(modelData.value) === root.value
            hasCursor: root.cursorIndex === index
            bordered: true
            focusable: false
            foreground: Color.popups.text
            horizontalPadding: Style.space(text === "" ? 8 : 10)
            verticalPadding: Style.space(4)
            Accessible.role: Accessible.RadioButton
            Accessible.name: text || tooltipText
            Accessible.onPressAction: root.changed(String(modelData.value))
            onClicked: root.changed(String(modelData.value))
        }
    }
}
