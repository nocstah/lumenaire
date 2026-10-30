pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// A Strimer's (or all Strimers') look (DESIGN.md "Parts"): the effect in a
// searchable dropdown, the speed on a slider from Slow to Fast, the
// direction as two icon choices (↻ ↺), and six colours as swatches that open
// the picker under them. No hex text and no per-field source chips: the
// part's row says whether it is custom, and its "Use theme colours" resets it.
// Keys (plan §2.3): the dropdown owns them while open (the editor's catcher is
// blocked), ←/→ step the speed, h/l the direction.
ColumnLayout {
    id: root
    required property var unit
    required property var editor
    readonly property string base: "field:" + unit.id + ":"
    readonly property var modeView: editor.fieldView(unit, "mode")
    readonly property var speedView: editor.fieldView(unit, "speed")
    readonly property var dirView: editor.fieldView(unit, "direction")
    readonly property var colorsView: editor.fieldView(unit, "colors")
    readonly property var colours: colorsView && Array.isArray(colorsView.value) ? colorsView.value : []
    readonly property var limits: editor.limits
    readonly property int labelWidth: Style.space(72)
    readonly property bool dropdownOpen: modeBox.popupOpen
    spacing: Style.space(12)

    function openMode() { modeBox.open() }
    Component.onCompleted: editor.registerStrimer(unit.id, root)

    component Caption: Label {
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Layout.preferredWidth: root.labelWidth
        Layout.alignment: Qt.AlignVCenter
    }

    // effect
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Caption { text: "Effect" }
        Ui.SearchableDropdown {
            id: modeBox
            Layout.fillWidth: true
            Layout.maximumWidth: Style.space(220)
            showLabel: false
            placeholderText: "Search effects…"
            value: root.modeView ? String(root.modeView.value || "") : ""
            options: (root.limits && root.limits.strimer_modes ? root.limits.strimer_modes : ["Static", "Drizzling"]).map(m => ({ value: m, label: Format.modeLabel(m) }))
            hasCursor: root.editor.keyNav && root.editor.cursorKey === root.base + "mode"
            Accessible.name: "Strimer effect " + value
            onChanged: function(v) { root.editor.setField(root.unit, "mode", v) }
            Component.onCompleted: root.editor.register(root.base + "mode", modeBox)
        }
    }
    // speed
    RowLayout {
        id: speedRow
        Layout.fillWidth: true
        spacing: Style.space(8)
        readonly property var range: root.limits && root.limits.speed ? root.limits.speed : [0, 4]
        readonly property int value: root.speedView && isFinite(Number(root.speedView.value)) ? Number(root.speedView.value) : 2
        Caption { text: "Speed" }
        Label { text: "Slow"; tone: "muted"; font.pixelSize: Style.font.bodySmall; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
        Ui.CursorSurface {
            id: speedSurface
            Layout.fillWidth: true
            Layout.maximumWidth: Style.space(150)
            implicitHeight: Style.spacing.controlHeight
            hasCursor: root.editor.keyNav && root.editor.cursorKey === root.base + "speed"
            Accessible.role: Accessible.Slider
            Accessible.name: "Speed " + speedRow.value + " of " + speedRow.range[1]
            Component.onCompleted: root.editor.register(root.base + "speed", speedSurface)
            Ui.PanelSlider {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                minimum: speedRow.range[0]
                maximum: speedRow.range[1]
                step: 1
                integer: true
                tickCount: speedRow.range[1] - speedRow.range[0] + 1
                tickColor: Color.background
                trackColor: Style.selectedFillFor(Color.popups.text, Color.accent)
                fillColor: Color.popups.text
                knobColor: Color.popups.text
                value: speedRow.value
                onMoved: function(v) { if (Math.round(v) !== speedRow.value) root.editor.setField(root.unit, "speed", Math.round(v)) }
            }
        }
        Label { text: "Fast"; tone: "muted"; font.pixelSize: Style.font.bodySmall; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
        Item { Layout.fillWidth: true }
    }
    // direction
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Caption { text: "Direction" }
        Segmented {
            id: dirGroup
            options: (root.limits && root.limits.directions ? root.limits.directions : ["Clockwise", "CounterClockwise"])
                .map(d => ({ value: d, label: "", icon: d === "CounterClockwise" ? "󰑥" : "󰑧",   // nf-md-rotate_left / rotate_right
                             tooltip: d === "CounterClockwise" ? "Anticlockwise" : d }))
            value: root.dirView ? String(root.dirView.value || "") : ""
            cursorIndex: root.editor.keyNav && root.editor.cursorKey === root.base + "direction" ? Math.max(0, options.findIndex(o => o.value === value)) : -1
            onChanged: function(v) { root.editor.setField(root.unit, "direction", v) }
            Component.onCompleted: root.editor.register(root.base + "direction", dirGroup)
        }
    }
    // colours
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Caption { text: "Colours"; Layout.alignment: Qt.AlignTop; Layout.topMargin: Style.space(8) }
        Flow {
            Layout.fillWidth: true
            spacing: Style.space(4)
            Repeater {
                model: 6
                Swatch {
                    id: cell
                    required property int index
                    readonly property string fkey: root.base + "colors/" + index
                    size: Style.space(26)
                    hex: String(root.colours[index] || "")
                    tooltipText: "Colour " + (index + 1) + (hex ? " · #" + hex : "")
                    warn: root.colorsView && Array.isArray(root.colorsView.hints) ? root.editor.warnCount(root.colorsView.hints[index]) > 0 : false
                    selected: root.editor.pickerKey === fkey
                    hasCursor: root.editor.keyNav && root.editor.cursorKey === fkey
                    onClicked: { root.editor.cursorKey = fkey; root.editor.togglePicker(fkey) }
                    Component.onCompleted: root.editor.register(fkey, cell)
                }
            }
        }
    }
    Loader {
        Layout.fillWidth: true
        active: String(root.editor.pickerKey).indexOf(root.base + "colors/") === 0
        visible: active
        sourceComponent: root.editor.pickerComponent
    }
}
