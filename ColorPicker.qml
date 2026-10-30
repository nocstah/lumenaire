pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "LedColor.js" as LedColor
import "Palette.js" as Palette

// The colour picker, drawn inline under the swatch being edited (one at a
// time). Plain QML, no shaders, so it renders under the software backend and
// keeps keyboard focus inside the panel:
//
//   SV square   a Rectangle in the pure hue, a white→transparent horizontal
//               gradient over it and a transparent→black vertical one on top
//   hue strip   a 7-stop horizontal gradient
//   hex field   Ui.TextField; Enter commits, Esc restores what was there;
//               beside it the colour it had, to go back
//   presets     three groups, apart: this theme's colours, colours that look
//               true on LEDs, recent picks (each swatch's tooltip names it)
//   LED line    CalibrationHint: what the LEDs show and one short warning
//
// `compact` (the New theme page) keeps the square, the strip and the field.
// Every change emits picked(hex) at once (the Service batches the writes).
// Keys (plan §2.3): Tab/Shift+Tab cycle square → hue → hex → presets; the
// arrows move S/V by 2 % (Shift 10 %) on the square and the hue by 2°
// (Shift 10°); h/l walk the presets and Enter picks one. The editor forwards
// keys here while the picker is open (handleKey) and closes it on Esc.
ColumnLayout {
    id: root
    property string hex: "ff0000"
    property string original: ""       // the value when the picker opened
    property var swatches: []          // the theme palette: [{hex, label}]
    property var recent: []            // ["ff4a9a", …]
    property string shows: ""
    property var hints: []
    property bool compact: false
    signal picked(string hex)
    signal doneRequested()

    // h 0-360, s and v 0-1. The hue survives greys and black.
    property real h: 0
    property real s: 1
    property real v: 1
    property string emitted: ""
    property int part: 0               // 0 square, 1 hue, 2 hex, 3 presets
    property int presetIndex: 0
    property bool keyFocus: false      // draw the part ring (keyboard in use)
    readonly property var presetList: {
        const out = []
        if (compact) return out
        for (const p of (swatches || [])) if (p && LedColor.isHex(p.hex)) out.push({ hex: LedColor.norm(p.hex), group: "theme", tip: "This theme: " + p.label })
        for (const c of Palette.PRESETS) out.push({ hex: c, group: "led", tip: "Looks true on LEDs: " + Palette.colourName(c) })
        for (const c of (recent || [])) if (LedColor.isHex(c)) out.push({ hex: LedColor.norm(c), group: "recent", tip: "Recent: " + Palette.colourName(c) })
        return out
    }
    readonly property bool changed: original !== "" && original !== LedColor.norm(hex)

    spacing: Style.space(12)

    function syncFromHex() {
        const n = LedColor.norm(hex)
        if (!n || n === emitted) return
        const c = LedColor.hexToHsv(n)
        if (c[1] > 0 && c[2] > 0) h = c[0]
        s = c[1]
        v = c[2]
        emitted = n
        if (!hexField.activeFocus) hexField.text = n
    }
    onHexChanged: syncFromHex()
    Component.onCompleted: { emitted = ""; syncFromHex() }

    function emit() {
        const n = LedColor.hsvToHex(h, s, v)
        emitted = n
        if (!hexField.activeFocus) hexField.text = n
        if (n !== LedColor.norm(hex)) picked(n)
    }
    function setSV(ns, nv) { s = Math.max(0, Math.min(1, ns)); v = Math.max(0, Math.min(1, nv)); emit() }
    function setHue(nh) { h = Math.max(0, Math.min(359.9, nh)); emit() }
    function pickHex(n) {
        n = LedColor.norm(n)
        if (!n) return
        const c = LedColor.hexToHsv(n)
        if (c[1] > 0 && c[2] > 0) h = c[0]
        s = c[1]
        v = c[2]
        emitted = n
        if (!hexField.activeFocus) hexField.text = n
        if (n !== LedColor.norm(hex)) picked(n)
    }
    function focusPart(p) {
        const parts = compact ? 3 : 4
        part = (p + parts) % parts
        keyFocus = true
        if (part === 2) { hexField.forceActiveFocus(); hexField.selectAll() }
        else if (hexField.activeFocus) root.forceActiveFocus()
    }
    // Keys from the editor; true when used.
    function handleKey(event) {
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            focusPart(part + ((shift || event.key === Qt.Key_Backtab) ? -1 : 1))
            return true
        }
        const left = event.key === Qt.Key_Left || event.text === "h"
        const right = event.key === Qt.Key_Right || event.text === "l"
        const up = event.key === Qt.Key_Up || event.text === "k"
        const down = event.key === Qt.Key_Down || event.text === "j"
        keyFocus = true
        if (part === 0) {
            const d = shift ? 0.1 : 0.02
            if (left) { setSV(s - d, v); return true }
            if (right) { setSV(s + d, v); return true }
            if (up) { setSV(s, v + d); return true }
            if (down) { setSV(s, v - d); return true }
        } else if (part === 1) {
            const d = shift ? 10 : 2
            if (left || down) { setHue(h - d); return true }
            if (right || up) { setHue(h + d); return true }
        } else if (part === 3) {
            if (left) { presetIndex = Math.max(0, presetIndex - 1); return true }
            if (right) { presetIndex = Math.min(presetList.length - 1, presetIndex + 1); return true }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                if (presetList[presetIndex]) pickHex(presetList[presetIndex].hex)
                return true
            }
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { doneRequested(); return true }
        return false
    }

    // The keyboard ring around the part Tab is on, `gap` outside it; it only
    // rounds when the part does (`inner`, the part's corner).
    component PartRing: Ui.BorderSurface {
        property bool on: false
        property int gap: Style.space(3)
        property real inner: 0
        anchors.fill: parent
        anchors.margins: -gap
        visible: on
        color: "transparent"
        radius: inner > 0 ? inner + gap : 0
        borderSpec: Border.controlSpec("focus", Color.foreground, Color.accent)
    }

    // ---- SV square
    Item {
        id: square
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(root.compact ? 110 : 124)
        Accessible.role: Accessible.Slider
        Accessible.name: "Saturation " + Math.round(root.s * 100) + " %, brightness " + Math.round(root.v * 100) + " %"
        // The host's corner, at most 10 px like a theme's picture: the
        // corners are white, the pure hue and black.
        Rectangle {
            id: sv
            anchors.fill: parent
            radius: Math.min(Style.cornerRadius, Style.space(10))
            color: "#" + LedColor.hsvToHex(root.h, 1, 1)
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#ffffffff" }
                    GradientStop { position: 1; color: "#00ffffff" }
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0; color: "#00000000" }
                    GradientStop { position: 1; color: "#ff000000" }
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "transparent"
                border.width: 1
                border.color: Style.normalBorderColor
            }
        }
        // Knob: a white ring inside a dark one reads on any colour.
        Rectangle {
            readonly property int d: Style.space(14)
            x: Math.round(root.s * (square.width - 1) - d / 2)
            y: Math.round((1 - root.v) * (square.height - 1) - d / 2)
            width: d
            height: d
            radius: d / 2
            color: "transparent"
            border.width: Math.max(1, Style.space(2))
            border.color: "#ffffff"
            Rectangle {
                anchors.fill: parent
                anchors.margins: -1
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: "#000000"
            }
        }
        PartRing { inner: sv.radius; on: root.keyFocus && root.part === 0 }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.CrossCursor
            function at(mx, my) { root.part = 0; root.setSV(mx / Math.max(1, width - 1), 1 - my / Math.max(1, height - 1)) }
            onPressed: function(mouse) { root.keyFocus = false; at(mouse.x, mouse.y) }
            onPositionChanged: function(mouse) { if (pressed) at(mouse.x, mouse.y) }
        }
    }

    // ---- hue strip
    Item {
        id: hue
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(14)
        Accessible.role: Accessible.Slider
        Accessible.name: "Hue " + Math.round(root.h) + " degrees"
        // The host's corner, at most a pill; the knob stays round either way.
        Rectangle {
            id: hueTrack
            anchors.fill: parent
            radius: Math.min(Style.cornerRadius, height / 2)
            border.width: 1
            border.color: Style.normalBorderColor
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0 / 6; color: "#ff0000" }
                GradientStop { position: 1 / 6; color: "#ffff00" }
                GradientStop { position: 2 / 6; color: "#00ff00" }
                GradientStop { position: 3 / 6; color: "#00ffff" }
                GradientStop { position: 4 / 6; color: "#0000ff" }
                GradientStop { position: 5 / 6; color: "#ff00ff" }
                GradientStop { position: 6 / 6; color: "#ff0000" }
            }
        }
        Rectangle {
            readonly property int d: Style.space(16)
            x: Math.round(root.h / 360 * (hue.width - 1) - d / 2)
            y: Math.round((hue.height - d) / 2)
            width: d
            height: d
            radius: d / 2
            color: "#" + LedColor.hsvToHex(root.h, 1, 1)
            border.width: Math.max(1, Style.space(2))
            border.color: "#ffffff"
            Rectangle {
                anchors.fill: parent
                anchors.margins: -1
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: "#000000"
            }
        }
        PartRing { gap: Style.space(4); inner: hueTrack.radius; on: root.keyFocus && root.part === 1 }
        MouseArea {
            anchors.fill: parent
            anchors.topMargin: -Style.space(4)
            anchors.bottomMargin: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            function at(mx) { root.part = 1; root.setHue(mx / Math.max(1, width - 1) * 360) }
            onPressed: function(mouse) { root.keyFocus = false; at(mouse.x) }
            onPositionChanged: function(mouse) { if (pressed) at(mouse.x) }
        }
    }

    // ---- hex, and the colour it had
    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Label { text: "#"; tone: "muted"; wrapMode: Text.NoWrap; Layout.alignment: Qt.AlignVCenter }
        Ui.TextField {
            id: hexField
            Layout.preferredWidth: Style.space(96)
            Layout.alignment: Qt.AlignVCenter
            hasCursor: root.keyFocus && root.part === 2
            maximumLength: 7
            inputMethodHints: Qt.ImhNoPredictiveText
            validator: RegularExpressionValidator { regularExpression: /^#?[0-9a-fA-F]{0,6}$/ }
            Accessible.name: "Hex colour"
            onActiveFocusChanged: if (activeFocus) root.part = 2
            onAccepted: {
                const n = LedColor.norm(text)
                if (n) { root.pickHex(n); root.forceActiveFocus() }
            }
            Keys.onEscapePressed: function(event) { text = LedColor.norm(root.hex); root.forceActiveFocus(); event.accepted = true }
            Keys.onTabPressed: function(event) { root.focusPart(3); event.accepted = true }
            Keys.onBacktabPressed: function(event) { root.focusPart(1); event.accepted = true }
        }
        Item { Layout.fillWidth: true }
        Label {
            visible: root.changed
            text: "Was"
            tone: "muted"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            Layout.alignment: Qt.AlignVCenter
        }
        Swatch {
            visible: root.changed
            size: Style.space(22)
            hex: root.original
            tooltipText: "Back to the colour it had"
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.pickHex(root.original)
        }
    }

    // ---- presets, in groups
    Flow {
        id: presetFlow
        Layout.fillWidth: true
        visible: root.presetList.length > 0
        spacing: Style.space(4)
        Repeater {
            model: root.presetList
            Item {
                id: slot
                required property var modelData
                required property int index
                // A little room before a new group.
                readonly property bool groupStart: index > 0 && root.presetList[index - 1].group !== modelData.group
                width: chip.width + (groupStart ? Style.space(12) : 0)
                height: chip.height
                Swatch {
                    id: chip
                    x: slot.groupStart ? Style.space(12) : 0
                    size: Style.space(22)
                    hex: slot.modelData.hex
                    tooltipText: slot.modelData.tip
                    selected: LedColor.norm(root.hex) === slot.modelData.hex
                    hasCursor: root.keyFocus && root.part === 3 && root.presetIndex === slot.index
                    onClicked: { root.part = 3; root.presetIndex = slot.index; root.pickHex(slot.modelData.hex) }
                }
            }
        }
    }

    CalibrationHint {
        Layout.fillWidth: true
        visible: !root.compact && shown
        hex: LedColor.norm(root.hex)
        shows: root.shows
        hints: root.hints
        onUseColour: function(c) { root.pickHex(c) }
    }
}
