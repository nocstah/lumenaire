import QtQuick
import qs.Commons
import qs.Ui as Ui

// An inline text link, only for one-click resets such as "Use theme colours"
// (DESIGN.md "Buttons"): accent text, underlined on hover, on the keyboard
// cursor (`hasCursor`) and with focus, where it also gets the host focus ring.
// Its words sit `inset` in from the box: pull it out by that to line them up.
Item {
    id: root
    property string text: ""
    property string tooltipText: ""
    property bool hasCursor: false
    signal clicked()

    readonly property bool hot: mouse.containsMouse || hasCursor || activeFocus
    readonly property int inset: Style.space(4)
    implicitWidth: words.implicitWidth + inset * 2
    implicitHeight: words.implicitHeight + Style.space(4)
    activeFocusOnTab: true
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Link
    Accessible.name: text
    Accessible.onPressAction: if (enabled) root.clicked()
    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()

    Rectangle {
        anchors.fill: parent
        visible: root.hasCursor || root.activeFocus
        radius: Style.cornerRadius
        color: Style.hoverFillFor(Color.popups.text, Color.accent)
        border.width: 1
        border.color: Style.focusBorderFor(Color.popups.text, Color.accent)
    }
    Label {
        id: words
        anchors.centerIn: parent
        text: root.text
        tone: "accent"
        font.underline: root.hot
        wrapMode: Text.NoWrap
        Accessible.ignored: true
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    Ui.PanelToolTip {
        visible: root.tooltipText !== "" && mouse.containsMouse
        text: root.tooltipText
    }
}
