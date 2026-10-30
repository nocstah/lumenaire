import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// A theme name as the user types it (New theme, Rename, Save as copy). The
// field shows the words as typed; `slug` is what goes to the engine
// (Format.slugify: "Neon Cyan" -> "neon-cyan"). No rules text: only when the
// name can't be used, one friendly line says why and offers a one-click fix
// ("Sakura already exists." [Use "Sakura 2"]).
ColumnLayout {
    id: root
    property alias text: field.text
    property var names: []           // engine names already taken (themes and drafts)
    property string current: ""      // the theme's own name (Rename): not a clash
    property string placeholder: "Name"
    property bool hasCursor: false
    readonly property string slug: Format.slugify(field.text)
    readonly property var issue: Format.nameIssue(field.text, names, current)
    readonly property bool ok: issue === null && slug !== "" && slug !== current
    signal accepted()

    function focusField() { field.forceActiveFocus(); field.selectAll() }
    spacing: Style.space(8)

    Ui.TextField {
        id: field
        Layout.fillWidth: true
        placeholderText: root.placeholder
        maximumLength: 64
        hasCursor: root.hasCursor
        inputMethodHints: Qt.ImhNoPredictiveText
        Accessible.name: "Theme name"
        onAccepted: if (root.ok) root.accepted()
    }
    // The words, then the fix beside them, or under them when there's no room.
    Flow {
        Layout.fillWidth: true
        visible: root.issue !== null && root.issue.text !== ""
        spacing: Style.space(8)
        Label {
            width: Math.min(implicitWidth, parent.width)
            height: Math.max(implicitHeight, fixButton.visible ? fixButton.implicitHeight : 0)
            verticalAlignment: Text.AlignVCenter
            text: root.issue ? root.issue.text : ""
            font.pixelSize: Style.font.bodySmall
        }
        Action {
            id: fixButton
            visible: !!root.issue && root.issue.fix !== ""
            text: root.issue ? "Use “" + root.issue.fix + "”" : ""
            tooltipText: "Name it " + (root.issue ? root.issue.fix : "")
            onClicked: { field.text = root.issue.fix; root.focusField() }
        }
    }
}
