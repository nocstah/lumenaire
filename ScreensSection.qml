pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// The editor's "Screens" section (DESIGN.md "Screens"): the case map
// (CaseMap: every screen at its place, its media as a picture, the accent
// outline where the draft changes it) and one line under it that says the
// first thing worth saying, with at most one action:
//
//   "Fan 3 couldn't be prepared" (urgent)          Try again
//   "Fan 2: the screen couldn't play it" (urgent)  Choose another
//   "Pump: preparing… 42 %", "Updating…", "Screens are off",
//   "On the case", "Shows after you save"
//
// A tile opens that screen's page. Keys: the editor's rows "scr:<role>" in
// the view's map order, then "scr-action" (the line's button).
ColumnLayout {
    id: root
    required property var editor                // ThemeEditor
    readonly property var service: editor.service
    readonly property var view: service ? service.screensView : null
    readonly property var screens: view && Array.isArray(view.screens) ? view.screens : []
    readonly property bool live: editor.screensLive
    readonly property bool screensOn: !service || service.screens !== "off"
    readonly property var line: editor.screensLine
    spacing: 0

    function lineFor(role) {
        const s = screens.find(x => x && x.role === role)
        return s ? Format.screenLine(s, editor.jobFor(role), editor.screenPreviewOf(role), { previewLive: live, screensOn: screensOn }).text : ""
    }
    function failedFor(role) {
        const j = editor.jobFor(role)
        const p = editor.screenPreviewOf(role)
        return (!!j && String(j.state) === "failed") || (live && !!p && String(p.state) === "failed")
    }

    SectionHeader {
        Layout.topMargin: Style.space(24)
        text: "Screens"
    }
    CaseMap {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(12)
        view: root.view
        cursorRole: root.editor.keyNav && String(root.editor.cursorKey).indexOf("scr:") === 0 ? String(root.editor.cursorKey).slice(4) : ""
        jobFor: r => root.editor.jobFor(r)
        failedFor: r => root.failedFor(r)
        lineFor: r => root.lineFor(r)
        onActivated: function(role) { root.editor.cursorKey = "scr:" + role; root.editor.openScreen(role, "") }
        onRegister: function(role, item) { root.editor.register("scr:" + role, item) }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(12)
        visible: root.line.text !== ""
        spacing: Style.space(8)
        Item {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: words.implicitHeight
            Label {
                id: words
                width: parent.width
                text: root.line.text
                tone: root.line.level === "urgent" ? "urgent" : "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
            MouseArea { id: lineMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            Ui.PanelToolTip {
                readonly property string full: [words.truncated ? root.line.text : "", root.line.tip].filter(x => x !== "").join("\n")
                visible: lineMouse.containsMouse && full !== ""
                text: full
            }
        }
        Action {
            id: lineAction
            visible: root.line.action !== ""
            text: root.line.action === "retry" ? "Try again" : "Choose another"
            hasCursor: root.editor.keyNav && root.editor.cursorKey === "scr-action"
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.editor.screensAct()
            Component.onCompleted: root.editor.register("scr-action", lineAction)
        }
    }
}
