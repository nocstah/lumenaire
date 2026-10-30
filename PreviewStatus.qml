import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// "Show on case" (plan §2.2, DESIGN.md "Preview"): the live preview switch
// and one short muted line that says what the case shows ("Live",
// "Updating…", "Paused for a moment", "Lights are off", "Needs a one-time
// hardware check"), with the detail in its tooltip and, when there is one,
// the one thing to do about it as a button: Copy command, Try again, Keep
// showing, Show again. Progress is words, never an animation.
//
// Before the one-time hardware check the engine reports "unmeasured": the
// switch is off and disabled and Copy command copies the check; editing and
// saving work without the preview.
ColumnLayout {
    id: root
    required property var service
    property string themeName: ""
    property string cursorKey: ""
    signal register(string key, Item item)

    readonly property bool hasService: service !== null && service !== undefined
    readonly property bool lightsOn: hasService && service.lights === "on"
    readonly property bool unmeasured: hasService && service.previewUnmeasured === true
    readonly property bool enabledPref: hasService && service.previewEnabled === true
    readonly property var line: !hasService ? { text: "", level: "", action: "", tip: "" }
        : Format.previewStatus(service.preview, {
            enabled: enabledPref, countdown: Number(service.previewCountdown), idleLeft: Number(service.previewIdleLeft),
            lightsOn: lightsOn, theme: themeName, busyLabel: service.busyLabel || "", unmeasured: unmeasured,
            command: String(service.previewCheckCommand || ""), editing: service.editPending === true })
    readonly property bool switchOn: enabledPref && lightsOn && !unmeasured
    spacing: Style.space(8)

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Item {
            Layout.fillWidth: true
            implicitHeight: words.implicitHeight
            ColumnLayout {
                id: words
                width: parent.width
                spacing: Style.space(2)
                Label { text: "Show on case"; Layout.fillWidth: true; wrapMode: Text.NoWrap }
                Label {
                    Layout.fillWidth: true
                    text: root.line.text
                    tone: root.line.level === "urgent" ? "urgent" : "muted"
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }
            }
            MouseArea { id: lineMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            Ui.PanelToolTip { visible: lineMouse.containsMouse && root.line.tip !== ""; text: root.line.tip }
        }
        Ui.ToggleSwitch {
            id: previewSwitch
            checked: root.switchOn
            enabled: root.lightsOn && !root.unmeasured
            opacity: enabled ? 1 : 0.45
            hasCursor: root.cursorKey === "preview"
            Layout.alignment: Qt.AlignVCenter
            Accessible.role: Accessible.CheckBox
            Accessible.name: "Show on case" + (checked ? ", on" : ", off")
            onToggled: root.service.setPreviewEnabled(!root.enabledPref)
            Component.onCompleted: root.register("preview", previewSwitch)
        }
    }
    Action {
        visible: root.line.action !== ""
        text: root.line.action === "copy" ? "Copy command" : root.line.action === "keep" ? "Keep showing"
            : root.line.action === "again" ? (root.line.level === "urgent" ? "Try again" : "Show again") : ""
        enabled: root.line.action !== "again" || root.lightsOn
        tooltipText: root.line.action === "copy" ? String(root.service.previewCheckCommand || "") + "\nIt asks before each lighting step and puts your look back." : ""
        onClicked: {
            if (root.line.action === "copy") root.service.copyPreviewCheckCommand()
            else if (root.line.action === "keep") root.service.keepPreviewing()
            else if (root.line.action === "again") root.service.previewNow()
        }
    }
}
