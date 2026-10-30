import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// A power switch as a tile (DESIGN.md "Power"): a glyph, the name, one short
// muted status word and the host ToggleSwitch. The whole tile is the click
// target, like Ui.Toggle; the switch only shows the state. A tile that can't
// change right now dims its switch, says "Waiting…" and gives the reason in
// its tooltip; `detail` (what it switches) is the tooltip otherwise.
Ui.BorderSurface {
    id: root
    property string glyph: ""
    property string title: ""
    property bool checked: false
    property bool busy: false
    property bool allowed: true
    property string status: ""
    property string detail: ""
    property bool hasCursor: false
    signal toggled()

    readonly property bool hot: allowed && (mouse.containsMouse || hasCursor)
    implicitHeight: row.implicitHeight + Style.space(12) * 2
    radius: Style.cornerRadius
    color: hot ? Style.hoverFillFor(Color.popups.text, Color.accent) : Style.normalFillFor(Color.popups.text, Color.accent)
    borderSpec: Border.flat(hasCursor ? Style.focusBorderFor(Color.popups.text, Color.accent)
                                      : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.14), 1)
    Accessible.role: Accessible.CheckBox
    Accessible.name: title + ", " + (checked ? "on" : "off") + (allowed ? "" : ", " + detail)
    Accessible.onPressAction: if (root.allowed && !root.busy) root.toggled()

    RowLayout {
        id: row
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(8)
        Label {
            text: root.glyph
            tone: root.checked ? "text" : "muted"
            font.pixelSize: Style.font.iconLarge
            wrapMode: Text.NoWrap
            Layout.alignment: Qt.AlignVCenter
            Accessible.ignored: true
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(1)
            Label {
                Layout.fillWidth: true
                text: root.title
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Accessible.ignored: true
            }
            Label {
                Layout.fillWidth: true
                text: root.status
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Accessible.ignored: true
            }
        }
        Ui.ToggleSwitch {
            checked: root.checked
            busy: root.busy
            interactive: false
            cursorPad: Style.space(4)
            opacity: root.allowed ? 1 : 0.45
            Layout.alignment: Qt.AlignVCenter
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.allowed ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.allowed && !root.busy) root.toggled()
    }
    Ui.PanelToolTip {
        visible: mouse.containsMouse && root.detail !== ""
        text: root.detail
    }
}
