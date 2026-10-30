pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons

// GPU and RAM lighting (DESIGN.md "Parts"), with the Strimer's treatment: one
// colour or a blend of 2-8, chosen as Solid / Blend; the colours as swatches
// that open the picker under them, "+" to add one and, in the picker, Remove;
// a bar shows the blend as the LEDs run it. RAM also picks whether the blend
// runs across both sticks or repeats on each.
ColumnLayout {
    id: root
    required property var unit
    required property var editor
    readonly property string base: "field:" + unit.id + ":"
    readonly property var stopsView: editor.fieldView(unit, "stops")
    readonly property var colourView: editor.fieldView(unit, "colour")
    readonly property bool solid: editor.unitShape(unit) === "solid"
    readonly property var stops: solid ? [String(colourView ? colourView.value || "" : "")]
        : (stopsView && Array.isArray(stopsView.value) ? stopsView.value.map(String) : [])
    readonly property var range: {
        const g = editor.limits && editor.limits.gradient_stops ? editor.limits.gradient_stops[unit.kind] : null
        return Array.isArray(g) ? g : [2, 8]
    }
    readonly property var spanView: editor.fieldView(unit, "span")
    readonly property int labelWidth: Style.space(72)
    readonly property int openStop: {
        const k = String(editor.pickerKey)
        if (solid) return k === base + "colour" ? 0 : -1
        return k.indexOf(base + "stops/") === 0 ? Number(k.slice((base + "stops/").length)) : -1
    }
    spacing: Style.space(12)

    component Caption: Label {
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Layout.preferredWidth: root.labelWidth
        Layout.alignment: Qt.AlignVCenter
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Caption { text: "Style" }
        Segmented {
            id: shapeGroup
            options: [{ value: "solid", label: "Solid" }, { value: "gradient", label: "Blend" }]
            value: root.solid ? "solid" : "gradient"
            cursorIndex: root.editor.keyNav && root.editor.cursorKey === root.base + "shape" ? (root.solid ? 0 : 1) : -1
            onChanged: function(v) { root.editor.setShape(root.unit, v) }
            Component.onCompleted: root.editor.register(root.base + "shape", shapeGroup)
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Caption { text: "Colours"; Layout.alignment: Qt.AlignTop; Layout.topMargin: Style.space(8) }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Flow {
                Layout.fillWidth: true
                spacing: Style.space(4)
                Repeater {
                    model: root.stops.length
                    Swatch {
                        id: stopCell
                        required property int index
                        readonly property string fkey: root.solid ? root.base + "colour" : root.base + "stops/" + index
                        size: Style.space(26)
                        hex: root.stops[index] || ""
                        tooltipText: (root.solid ? "Colour" : "Colour " + (index + 1)) + (hex ? " · #" + hex : "")
                        warn: root.solid ? (root.colourView ? root.editor.warnCount(root.colourView.hints) > 0 : false)
                            : root.stopsView && Array.isArray(root.stopsView.hints) ? root.editor.warnCount(root.stopsView.hints[index]) > 0 : false
                        selected: root.editor.pickerKey === fkey
                        hasCursor: root.editor.keyNav && root.editor.cursorKey === fkey
                        onClicked: { root.editor.cursorKey = fkey; root.editor.togglePicker(fkey) }
                        Component.onCompleted: root.editor.register(fkey, stopCell)
                    }
                }
                IconButton {
                    id: addButton
                    readonly property string fkey: root.base + "add"
                    visible: !root.solid
                    glyph: "󰐕"   // nf-md-plus
                    tooltipText: enabled ? "Add a colour" : "At most " + root.range[1] + " colours"
                    enabled: root.stops.length < root.range[1]
                    hasCursor: root.editor.keyNav && root.editor.cursorKey === fkey
                    onClicked: root.editor.addStop(root.unit)
                    Component.onCompleted: root.editor.register(fkey, addButton)
                }
            }
            // The blend, as the LEDs will run it: one gradient through every
            // colour, clipped to the host's corner (at most a pill) like its outline.
            Canvas {
                id: blend
                readonly property real radius: Math.min(Style.cornerRadius, height / 2)
                readonly property string key: root.stops.join(",")
                Layout.fillWidth: true
                Layout.maximumWidth: Style.space(220)
                Layout.preferredHeight: Style.space(8)
                visible: !root.solid && root.stops.length > 1
                onKeyChanged: requestPaint()
                onRadiusChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    const n = root.stops.length
                    if (width <= 0 || height <= 0 || n < 2) return
                    const g = ctx.createLinearGradient(0, 0, width, 0)
                    for (let i = 0; i < n; i++) g.addColorStop(i / (n - 1), /^[0-9a-f]{6}$/i.test(root.stops[i]) ? "#" + root.stops[i] : "#000000")
                    ctx.fillStyle = g
                    ctx.beginPath()
                    ctx.roundedRect(0, 0, width, height, radius, radius)
                    ctx.fill()
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    radius: blend.radius
                    border.width: 1
                    border.color: Style.normalBorderColor
                }
            }
        }
    }
    Loader {
        Layout.fillWidth: true
        active: root.openStop >= 0
        visible: active
        sourceComponent: root.editor.pickerComponent
    }
    Action {
        visible: !root.solid && root.openStop >= 0
        text: "Remove this colour"
        enabled: root.stops.length > root.range[0]
        tooltipText: enabled ? "" : "A blend needs at least " + root.range[0] + " colours"
        onClicked: root.editor.removeStop(root.unit, root.openStop)
    }
    RowLayout {
        Layout.fillWidth: true
        visible: root.unit.kind === "ram" && !root.solid
        spacing: Style.space(8)
        Caption { text: "Runs" }
        Segmented {
            id: spanGroup
            options: (root.editor.limits && root.editor.limits.ram_spans ? root.editor.limits.ram_spans : ["across", "stick"])
                .map(s => ({ value: s, label: s === "across" ? "Across sticks" : s === "stick" ? "Each stick" : s }))
            value: root.spanView ? String(root.spanView.value || "across") : "across"
            cursorIndex: root.editor.keyNav && root.editor.cursorKey === root.base + "span" ? Math.max(0, options.findIndex(o => o.value === value)) : -1
            onChanged: function(v) { root.editor.setField(root.unit, "span", v) }
            Component.onCompleted: root.editor.register(root.base + "span", spanGroup)
        }
    }
}
