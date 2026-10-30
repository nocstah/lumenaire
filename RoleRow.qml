pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// One part of the case in the editor's "Parts" list (DESIGN.md "Parts"): a
// glyph, the part's name (Fans, Strimers, Rings, GPU, Motherboard, RAM; a
// device's own name one level in), its colours as small chips (data) and a
// muted state word on the right: "Theme colours", or "Custom" in the accent
// when this theme sets its own. The whole row expands to its controls:
//
//   fan       Inner and Outer swatches
//   strimer   StrimerEditor (effect, speed, direction, six colours)
//   colour    one swatch
//   gradient  GradientEditor (solid or a blend; RAM's span)
//   readonly  why it can't be edited here, and "Replace with one colour"
//
// then "Use theme colours" (a device: "Same as all fans") when it is custom,
// and "Customise each…" when the part has several devices; those follow as
// rows of their own (ThemeEditor lists them). Values come from
// editor.fieldView(), the optimistic draft over the engine's view; every
// write goes back through the editor.
ColumnLayout {
    id: root
    required property var unit          // {id, isGroup, role, group, kind, form, label, cls, fields, present, readonly_reason}
    required property var editor        // ThemeEditor
    property int depth: 0

    readonly property string key: "unit:" + unit.id
    readonly property bool expanded: editor.isExpanded(unit.id)
    readonly property var look: editor.partState(unit)
    readonly property var colours: editor.unitColours(unit)
    readonly property string name: editor.partTitle(unit)
    readonly property int indent: depth * Style.space(24)
    readonly property int textX: indent + Style.space(28)
    readonly property int bleed: Style.space(8)
    readonly property var kids: editor.childrenOf(unit.id)

    spacing: Style.space(8)

    Ui.CursorSurface {
        id: header
        Layout.fillWidth: true
        Layout.leftMargin: -root.bleed
        Layout.rightMargin: -root.bleed
        implicitHeight: Math.max(Style.space(36), headRow.implicitHeight + Style.space(8))
        hasCursor: headMouse.containsMouse || (root.editor.keyNav && root.editor.cursorKey === root.key)
        activeFocusOnTab: false
        Accessible.role: Accessible.Button
        Accessible.name: root.name + ", " + root.look.text + (root.expanded ? ", expanded" : ", collapsed")
        Accessible.onPressAction: root.editor.toggleExpand(root.unit.id)
        Component.onCompleted: root.editor.register(root.key, header)

        RowLayout {
            id: headRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: root.bleed + root.indent
            anchors.rightMargin: root.bleed
            spacing: Style.space(8)
            Label {
                text: Format.partGlyph(root.unit.kind)
                tone: "muted"
                font.pixelSize: Style.font.title
                wrapMode: Text.NoWrap
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: Style.space(18)
                Layout.alignment: Qt.AlignVCenter
                Accessible.ignored: true
            }
            Label {
                id: nameLabel
                text: root.name
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
            }
            Row {
                spacing: Style.space(4)
                Layout.alignment: Qt.AlignVCenter
                Repeater {
                    model: root.colours.slice(0, 6)
                    Rectangle {
                        required property var modelData
                        width: Style.space(12)
                        height: Style.space(12)
                        radius: Math.min(Style.cornerRadius, width / 4)
                        color: "#" + modelData
                        border.width: 1
                        border.color: Style.normalBorderColor
                    }
                }
            }
            Label {
                text: root.look.text
                visible: text !== ""
                tone: root.look.tone
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: Style.space(root.depth === 0 ? 92 : 0)
                Layout.alignment: Qt.AlignVCenter
            }
        }
        MouseArea {
            id: headMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.editor.cursorKey = root.key; root.editor.toggleExpand(root.unit.id) }
        }
        Ui.PanelToolTip {
            readonly property string full: [nameLabel.truncated ? root.name : "", root.look.tip].filter(x => x !== "").join("\n")
            visible: headMouse.containsMouse && full !== ""
            text: full
        }
    }

    // The controls, under the name.
    Loader {
        Layout.fillWidth: true
        Layout.leftMargin: root.textX
        Layout.bottomMargin: Style.space(4)
        active: root.expanded
        visible: active
        sourceComponent: root.unit.form === "fan" ? fanForm
            : root.unit.form === "strimer" ? strimerForm
            : root.unit.form === "gradient" ? gradientForm
            : root.unit.form === "readonly" ? readonlyForm
            : colourForm
    }
    // Back to the theme's colours (a device: back to its part's).
    TextLink {
        id: resetLink
        readonly property string rkey: "reset:" + root.unit.id
        visible: root.expanded && root.look.custom && root.unit.form !== "readonly"
        Layout.leftMargin: root.textX - inset
        text: root.editor.resetLabel(root.unit)
        tooltipText: root.depth > 0 ? "Drop this device's own colours" : "Drop the colours set here and follow Main, Second and Accent"
        hasCursor: root.editor.keyNav && root.editor.cursorKey === rkey
        onClicked: root.editor.resetPart(root.unit.id)
        Component.onCompleted: root.editor.register(rkey, resetLink)
    }
    // Several devices: one row each, on request.
    Ui.CursorSurface {
        id: moreRow
        readonly property string mkey: "more:" + root.unit.id
        readonly property bool open: root.editor.isMore(root.unit.id)
        visible: root.expanded && root.kids.length > 0
        Layout.leftMargin: root.textX - Style.space(8)
        implicitWidth: moreLine.implicitWidth + Style.space(16)
        implicitHeight: moreLine.implicitHeight + Style.space(8)
        hasCursor: moreMouse.containsMouse || (root.editor.keyNav && root.editor.cursorKey === mkey)
        Accessible.role: Accessible.Button
        Accessible.name: "Customise each " + (open ? ", open" : "")
        Component.onCompleted: root.editor.register(mkey, moreRow)
        Row {
            id: moreLine
            anchors.centerIn: parent
            spacing: Style.space(4)
            Label {
                text: moreRow.open ? "󰅀" : "󰅂"   // nf-md-chevron_down / right
                tone: "muted"
                wrapMode: Text.NoWrap
                anchors.verticalCenter: parent.verticalCenter
            }
            Label {
                text: "Customise each…"
                wrapMode: Text.NoWrap
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: moreMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.editor.cursorKey = moreRow.mkey; root.editor.toggleMore(root.unit.id) }
        }
    }

    // A colour of this part, with the picker under its row of swatches.
    component Swatches: ColumnLayout {
        id: sw
        required property var names          // [[field name, caption]]
        spacing: Style.space(12)
        RowLayout {
            spacing: Style.space(16)
            Repeater {
                model: sw.names
                Swatch {
                    id: cell
                    required property var modelData
                    readonly property string fname: modelData[0]
                    readonly property var view: root.editor.fieldView(root.unit, fname)
                    readonly property string fkey: "field:" + root.unit.id + ":" + fname
                    size: Style.space(30)
                    hex: view ? String(view.value || "") : ""
                    label: modelData[1]
                    warn: view ? root.editor.warnCount(view.hints) > 0 : false
                    selected: root.editor.pickerKey === fkey
                    hasCursor: root.editor.keyNav && root.editor.cursorKey === fkey
                    onClicked: { root.editor.cursorKey = fkey; root.editor.togglePicker(fkey) }
                    Component.onCompleted: root.editor.register(fkey, cell)
                }
            }
        }
        Loader {
            Layout.fillWidth: true
            active: sw.names.some(n => root.editor.pickerKey === "field:" + root.unit.id + ":" + n[0])
            visible: active
            sourceComponent: root.editor.pickerComponent
        }
    }

    Component {
        id: fanForm
        Swatches { names: [["inner", "Inner"], ["outer", "Outer"]] }
    }
    Component {
        id: colourForm
        Swatches { names: [["colour", "Colour"]] }
    }
    Component {
        id: strimerForm
        StrimerEditor { unit: root.unit; editor: root.editor }
    }
    Component {
        id: gradientForm
        GradientEditor { unit: root.unit; editor: root.editor }
    }
    Component {
        id: readonlyForm
        ColumnLayout {
            spacing: Style.space(8)
            Label {
                Layout.fillWidth: true
                readonly property string why: String(root.unit.readonly_reason || "")
                text: /per-fan/i.test(why) ? "Each fan has its own colour here, so they can't be edited as one."
                    : /mode/i.test(why) ? "This part runs a lighting mode the editor can't change."
                    : "The editor can't change this part's colours."
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
            }
            Action {
                id: replaceAction
                readonly property string rkey: "field:" + root.unit.id + ":replace"
                text: "Replace with one colour"
                hasCursor: root.editor.keyNav && root.editor.cursorKey === rkey
                onClicked: root.editor.replaceWithOne(root.unit)
                Component.onCompleted: root.editor.register(rkey, replaceAction)
            }
        }
    }
}
