pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons

// One calm notice (DESIGN.md "Notices"): a glyph, one sentence in the popup
// text colour, at most two actions as buttons and, when it can go away, an
// icon button to dismiss it. `level` "urgent" tints the plate and the glyph
// with Color.urgent; the words stay in the text colour so they read on light
// themes too. actions: [{key, label, kind}], the first two are shown.
Rectangle {
    id: root
    property string text: ""
    property string level: "info"            // info | urgent
    property string glyph: ""
    property var actions: []
    property bool dismissable: false
    signal action(string key)
    signal dismissed()

    readonly property bool urgent: level === "urgent"
    readonly property var shown: (actions || []).slice(0, 2)
    readonly property int pad: Style.space(12)

    implicitHeight: body.implicitHeight + Style.space(12) * 2
    radius: Style.cornerRadius
    color: urgent ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.1) : Style.normalFillFor(Color.popups.text, Color.accent)
    border.width: 1
    border.color: urgent ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.35) : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.1)
    Accessible.role: Accessible.AlertMessage
    Accessible.name: text

    RowLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: root.pad
        anchors.rightMargin: root.dismissable ? Style.space(4) : root.pad
        anchors.topMargin: Style.space(12)
        spacing: Style.space(8)

        Label {
            text: root.glyph !== "" ? root.glyph : root.urgent ? "󰀪" : "󰋽"   // nf-md-alert_outline / information_outline
            tone: root.urgent ? "urgent" : "muted"
            font.pixelSize: Style.font.title
            wrapMode: Text.NoWrap
            Layout.alignment: Qt.AlignTop
            Accessible.ignored: true
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(8)
            Label {
                Layout.fillWidth: true
                text: root.text
            }
            Flow {
                Layout.fillWidth: true
                visible: root.shown.length > 0
                spacing: Style.space(8)
                Repeater {
                    model: root.shown
                    Action {
                        required property var modelData
                        text: String(modelData.label || "")
                        kind: String(modelData.kind || "secondary")
                        enabled: modelData.enabled !== false
                        tooltipText: String(modelData.tip || "")
                        onClicked: root.action(String(modelData.key))
                    }
                }
            }
        }
        IconButton {
            visible: root.dismissable
            glyph: "󰅖"   // nf-md-close
            tooltipText: "Dismiss"
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: -Style.space(4)
            onClicked: root.dismissed()
        }
    }
}
