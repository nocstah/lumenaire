pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Format.js" as Format
import "Palette.js" as Palette

// The New theme page (DESIGN.md "New theme"): two short steps inside the
// panel, never a dialog.
//
//   1 of 2  Start from: A colour (one main colour; the other two follow it,
//           Palette.fromMain), Match my desktop (the Omarchy theme's
//           colours, made LED-friendly), Copy a theme (a duplicate), or
//           Surprise me (a random palette, again and again). The choice
//           opens its detail under the four cards, with the palette it gives.
//   2 of 2  Name it: one field, filled with a suggestion ("Neon Cyan",
//           "Sakura copy"); the engine gets the slug. Create (or Enter).
//
// Create hands (slug, from, palette) to LightsContent, which starts the
// draft (theme new / theme duplicate: nothing is applied until Save) and
// opens the editor with the live preview on. Esc and ← go back a step.
// Keys: j/k or the arrows walk the rows, h/l move across the cards, the
// colours and the themes, Enter chooses; the picker takes the keys while open.
FocusScope {
    id: root
    required property var service
    property var initial: null
    property var themes: []
    property string activeTheme: ""
    property var names: []
    property string desktopName: ""
    property string desktopColors: ""
    signal backRequested()
    signal createRequested(string slug, string fromName, var palette)
    signal showRequested(var item)

    property int step: 1
    property string start: ""                // colour | desktop | copy | surprise
    property string colour: "00e5ff"
    property string copyFrom: ""
    // A different surprise each time (fixtures pin it).
    property int seed: 1 + Math.floor(Math.random() * 2147483646)
    property bool pickerOpen: false
    property bool nameEdited: false
    property string cursorKey: ""
    property bool keyNav: false
    property int presetIndex: 0
    property int copyIndex: 0
    property Item pickerItem: null
    property var items: ({})

    implicitWidth: Style.space(468)
    implicitHeight: body.implicitHeight

    readonly property var desktopPalette: Palette.fromDesktop(desktopColors)
    readonly property string desktopTitle: desktopName ? Format.themeName(desktopName) : "your desktop"
    readonly property var chosen: start === "colour" ? Palette.fromMain(colour)
        : start === "desktop" ? desktopPalette
        : start === "surprise" ? Palette.surprise(seed)
        : null
    readonly property var copyTheme: themes.find(t => t.name === copyFrom) || null
    readonly property bool ready: start === "copy" ? !!copyTheme : start !== "" && !!chosen
    readonly property string suggestion: start === "colour" ? Palette.colourName(colour)
        : start === "desktop" ? (desktopName ? Format.themeName(desktopName) : "My desktop")
        : start === "copy" ? (copyTheme ? Format.themeName(copyTheme.name) + " copy" : "Copy")
        : start === "surprise" && chosen ? Palette.colourName(chosen.primary)
        : "My theme"
    readonly property var starts: [
        { key: "colour", glyph: "󰏘", title: "A colour", sub: "Pick one colour" },
        { key: "desktop", glyph: "󱄄", title: "Match my desktop", sub: "Use " + desktopTitle + "’s colours", off: !desktopPalette },
        { key: "copy", glyph: "󰆏", title: "Copy a theme", sub: "Start from one you have", off: themes.length === 0 },
        { key: "surprise", glyph: "󰙴", title: "Surprise me", sub: "A random palette" }
    ]

    function register(k, item) { const m = items; m[k] = item; items = m }
    function choose(k) {
        const s = starts.find(x => x.key === k)
        if (!s || s.off) return
        if (start !== k) { start = k; if (!nameEdited) nameField.text = "" }
        if (k === "copy" && !copyTheme) copyFrom = activeTheme && themes.some(t => t.name === activeTheme) ? activeTheme : (themes[0] ? themes[0].name : "")
        if (k !== "colour") pickerOpen = false
        cursorKey = k === "colour" ? "swatches" : k === "copy" ? "copy" : k === "surprise" ? "reroll" : "next"
        Qt.callLater(() => showRequested(items[cursorKey] || null))
    }
    function next() {
        if (!ready) return
        pickerOpen = false
        step = 2
        if (!nameEdited || nameField.text.trim() === "") nameField.text = Format.freeDisplay(suggestion, names)
        cursorKey = "name"
        Qt.callLater(() => { nameField.focusField(); showRequested(nameField) })
    }
    function create() {
        if (!ready || !nameField.ok) return
        if (start === "copy") createRequested(nameField.slug, copyFrom, null)
        else createRequested(nameField.slug, "", { primary: chosen.primary, secondary: chosen.secondary, accent: chosen.accent })
    }
    function back() {
        if (pickerOpen) { pickerOpen = false; root.forceActiveFocus(); return }
        if (step === 2 && !fromMenu) { step = 1; cursorKey = "next"; root.forceActiveFocus(); return }
        backRequested()
    }
    // Duplicate from a card menu opens straight on "Name it"; back leaves.
    property bool fromMenu: false

    Component.onCompleted: {
        const i = initial || {}
        if (i.start) start = String(i.start)
        if (i.colour) colour = String(i.colour)
        if (i.copyFrom) copyFrom = String(i.copyFrom)
        if (i.seed !== undefined) seed = Number(i.seed)
        if (i.picker) pickerOpen = true
        fromMenu = i.step === 2 && i.start === "copy" && i.fromMenu !== false
        if (i.step === 2) {
            step = 2
            nameField.text = i.name !== undefined ? String(i.name) : Format.freeDisplay(suggestion, names)
            nameEdited = i.name !== undefined
            cursorKey = "name"
            Qt.callLater(() => nameField.focusField())
        } else if (start === "colour") {
            presetIndex = Math.max(0, Palette.PRESETS.indexOf(colour))
        }
        if (start === "copy") copyIndex = Math.max(0, themes.findIndex(t => t.name === copyFrom))
        if (i.cursor !== undefined) { keyNav = true; cursorKey = String(i.cursor) }
        if (Array.isArray(i.keys)) Qt.callLater(() => { for (const k of i.keys) handleKey({ key: Number(k.key || 0), text: String(k.text || ""), modifiers: Number(k.modifiers || 0), accepted: false }) })
    }
    onSeedChanged: if (!nameEdited && step === 1) nameField.text = ""

    // ---- keys -----------------------------------------------------------------
    readonly property var rows: step === 2 ? ["name", "create"]
        : ["colour", "desktop", "copy", "surprise"].concat(start === "colour" ? ["swatches", "more"] : start === "copy" ? ["copy"] : start === "surprise" ? ["reroll"] : []).concat(["next"])
    function moveRow(d) {
        keyNav = true
        let i = rows.indexOf(cursorKey)
        if (i < 0) i = d > 0 ? -1 : rows.length
        // Two across, the four cards are a 2×2 grid: up and down skip a column.
        const grid = ["colour", "desktop", "copy", "surprise"]
        const g = grid.indexOf(cursorKey)
        if (startGrid.columns === 2 && g >= 0) {
            if ((d > 0 && g < 2) || (d < 0 && g >= 2)) { cursorKey = grid[g + d * 2]; return }
            if (d < 0) return
            i = grid.length - 1
        }
        cursorKey = rows[Math.max(0, Math.min(rows.length - 1, i + d))]
        Qt.callLater(() => showRequested(items[cursorKey] || null))
    }
    function sideways(d) {
        keyNav = true
        const grid = ["colour", "desktop", "copy", "surprise"]
        const g = grid.indexOf(cursorKey)
        if (g >= 0) {
            const n = g + d
            if (startGrid.columns === 2 && n >= 0 && n < 4 && Math.floor(n / 2) === Math.floor(g / 2)) cursorKey = grid[n]
            return true
        }
        if (cursorKey === "swatches") { presetIndex = Math.max(0, Math.min(Palette.PRESETS.length - 1, presetIndex + d)); colour = Palette.PRESETS[presetIndex]; return true }
        if (cursorKey === "copy") { copyIndex = Math.max(0, Math.min(themes.length - 1, copyIndex + d)); copyFrom = themes[copyIndex].name; return true }
        return false
    }
    function activateRow() {
        const k = cursorKey
        if (["colour", "desktop", "copy", "surprise"].indexOf(k) >= 0) { choose(k); return }
        if (k === "swatches") { colour = Palette.PRESETS[presetIndex]; return }
        if (k === "more") { pickerOpen = !pickerOpen; return }
        if (k === "copy") { if (themes[copyIndex]) copyFrom = themes[copyIndex].name; next(); return }
        if (k === "reroll") { seed = seed + 1; return }
        if (k === "next") { next(); return }
        if (k === "name") { nameField.focusField(); return }
        if (k === "create") create()
    }
    function textFocused() {
        const f = root.Window.activeFocusItem
        return !!f && f !== root && f.echoMode !== undefined && f.selectByMouse !== undefined
    }
    Keys.onPressed: function(event) { handleKey(event) }
    function handleKey(event) {
        if (textFocused()) {
            if (event.key === Qt.Key_Escape) { back(); event.accepted = true }
            return
        }
        if (pickerOpen && pickerItem && event.key !== Qt.Key_Escape && pickerItem.handleKey(event)) { event.accepted = true; return }
        if (event.key === Qt.Key_Escape) { back(); event.accepted = true; return }
        if (event.key === Qt.Key_Down || event.text === "j") { moveRow(1); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.text === "k") { moveRow(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { if (sideways(1)) event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { if (sideways(-1)) event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (!keyNav && step === 1 && start === "") { keyNav = true; cursorKey = "colour" }
            else activateRow()
            event.accepted = true
        }
    }

    // ---- the page ---------------------------------------------------------------
    // A palette as three captioned swatches (not clickable here).
    component PalettePreview: Row {
        id: preview
        property var colours: null
        spacing: Style.space(16)
        Repeater {
            model: [["primary", "Main"], ["secondary", "Second"], ["accent", "Accent"]]
            Swatch {
                required property var modelData
                size: Style.space(36)
                interactive: false
                hex: preview.colours ? String(preview.colours[modelData[0]] || "") : ""
                label: modelData[1]
            }
        }
    }

    ColumnLayout {
        id: body
        width: root.width
        spacing: 0

        // header
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            IconButton {
                glyph: "󰁍"   // nf-md-arrow_left
                tooltipText: root.step === 2 && !root.fromMenu ? "Back" : "Back to themes"
                Layout.leftMargin: -Style.space(6)
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.back()
            }
            Label {
                text: "New theme"
                font.pixelSize: Style.font.heading
                font.bold: true
                wrapMode: Text.NoWrap
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
            }
            Label {
                text: root.fromMenu ? "" : root.step + " of 2"
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                Layout.alignment: Qt.AlignVCenter
            }
        }

        // ---- step 1: start from
        SectionHeader {
            Layout.topMargin: Style.space(16)
            visible: root.step === 1
            text: "Start from"
        }
        GridLayout {
            id: startGrid
            Layout.fillWidth: true
            Layout.topMargin: Style.space(12)
            visible: root.step === 1
            // Two across; one under the other when the panel is narrow.
            columns: body.width < Style.space(400) ? 1 : 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(8)
            readonly property real cell: Math.floor((body.width - columnSpacing * (columns - 1)) / columns)
            Repeater {
                model: root.starts
                Ui.BorderSurface {
                    id: card
                    required property var modelData
                    readonly property bool chosen: root.start === modelData.key
                    readonly property bool cur: root.keyNav && root.cursorKey === modelData.key
                    readonly property bool hot: !modelData.off && (cardMouse.containsMouse || cur)
                    Layout.preferredWidth: startGrid.cell
                    Layout.fillHeight: true
                    implicitHeight: cardRow.implicitHeight + Style.space(12) * 2
                    radius: Style.cornerRadius
                    opacity: modelData.off ? 0.45 : 1
                    color: chosen ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.1)
                        : hot ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent) : Style.normalFillFor(Commons.Color.popups.text, Commons.Color.accent)
                    borderSpec: Border.flat(chosen ? Commons.Color.accent : cur ? Style.focusBorderFor(Commons.Color.popups.text, Commons.Color.accent)
                                            : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.14), chosen ? Math.max(1, Style.space(2)) : 1)
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.title + ", " + modelData.sub + (chosen ? ", chosen" : "")
                    Accessible.onPressAction: root.choose(modelData.key)
                    Component.onCompleted: root.register(modelData.key, card)
                    RowLayout {
                        id: cardRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(12)
                        spacing: Style.space(8)
                        Label {
                            text: card.modelData.glyph
                            tone: card.chosen ? "accent" : "muted"
                            font.pixelSize: Style.font.iconLarge
                            wrapMode: Text.NoWrap
                            Layout.alignment: Qt.AlignTop
                            Accessible.ignored: true
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(2)
                            Label {
                                Layout.fillWidth: true
                                text: card.modelData.title
                                font.bold: card.chosen
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Accessible.ignored: true
                            }
                            Label {
                                Layout.fillWidth: true
                                text: card.modelData.sub
                                tone: "muted"
                                font.pixelSize: Style.font.bodySmall
                                Accessible.ignored: true
                            }
                        }
                    }
                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: card.modelData.off ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: { root.keyNav = false; root.cursorKey = card.modelData.key; root.choose(card.modelData.key) }
                    }
                }
            }
        }

        // A colour: the LED presets, More colours, and the palette they make.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.step === 1 && root.start === "colour"
            spacing: Style.space(12)
            Label {
                text: "Main colour"
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                MouseArea { id: presetTipArea; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                Ui.PanelToolTip { visible: presetTipArea.containsMouse; text: "Colours that look true on your LEDs" }
            }
            Grid {
                id: presetFlow
                Layout.fillWidth: true
                columns: perRow
                spacing: Style.space(4)
                // One row of twelve, or two of six when narrow.
                readonly property int perRow: body.width < Style.space(400) ? 6 : 12
                readonly property int chip: Math.min(Style.space(30), Math.floor((body.width - spacing * (perRow - 1)) / perRow) - Style.space(6))
                Component.onCompleted: root.register("swatches", presetFlow)
                Repeater {
                    model: Palette.PRESETS
                    Swatch {
                        required property string modelData
                        required property int index
                        size: presetFlow.chip
                        hex: modelData
                        label: ""
                        tooltipText: Palette.colourName(modelData)
                        selected: root.colour === modelData
                        hasCursor: root.keyNav && root.cursorKey === "swatches" && root.presetIndex === index
                        onClicked: { root.presetIndex = index; root.colour = modelData }
                    }
                }
            }
            Action {
                id: moreAction
                text: root.pickerOpen ? "Hide colour picker" : "More colours…"
                iconText: "󰈊"   // nf-md-eyedropper
                iconSize: Style.font.body
                hasCursor: root.keyNav && root.cursorKey === "more"
                onClicked: root.pickerOpen = !root.pickerOpen
                Component.onCompleted: root.register("more", moreAction)
            }
            Loader {
                Layout.fillWidth: true
                active: root.pickerOpen
                visible: active
                sourceComponent: ColorPicker {
                    id: picker
                    hex: root.colour
                    original: ""
                    swatches: []
                    recent: []
                    compact: true
                    onPicked: function(h) { root.colour = h }
                    onDoneRequested: { root.pickerOpen = false; root.forceActiveFocus() }
                    Component.onCompleted: root.pickerItem = picker
                }
            }
        }

        // Copy a theme: small previews of every theme.
        GridLayout {
            id: copyGrid
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.step === 1 && root.start === "copy"
            columns: 3
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(12)
            readonly property real cell: Math.floor((body.width - columnSpacing * 2) / 3)
            Component.onCompleted: root.register("copy", copyGrid)
            Repeater {
                model: root.start === "copy" ? root.themes : []
                Item {
                    id: mini
                    required property var modelData
                    required property int index
                    readonly property bool chosen: root.copyFrom === modelData.name
                    readonly property bool cur: root.keyNav && root.cursorKey === "copy" && root.copyIndex === index
                    Layout.preferredWidth: copyGrid.cell
                    implicitHeight: miniArt.height + Style.space(4) + miniName.implicitHeight
                    ThemeArt {
                        id: miniArt
                        width: copyGrid.cell
                        height: Math.round(copyGrid.cell * 267 / 684)
                        theme: mini.modelData
                        ring: mini.chosen ? "active" : ""
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -Style.space(3)
                            visible: miniMouse.containsMouse || mini.cur
                            radius: miniArt.radius > 0 ? miniArt.radius + Style.space(3) : 0
                            color: "transparent"
                            border.width: mini.cur ? Math.max(1, Style.space(2)) : 1
                            border.color: mini.cur ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.55) : Style.focusBorderFor(Commons.Color.popups.text, Commons.Color.accent)
                        }
                    }
                    Label {
                        id: miniName
                        y: miniArt.height + Style.space(4)
                        width: parent.width
                        text: Format.themeName(mini.modelData.name)
                        tone: mini.chosen ? "text" : "muted"
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: miniMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.copyIndex = mini.index; root.copyFrom = mini.modelData.name }
                        onDoubleClicked: { root.copyFrom = mini.modelData.name; root.next() }
                    }
                }
            }
        }

        // The palette a colour, the desktop or chance gives.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.step === 1 && root.chosen !== null && root.start !== "copy"
            spacing: Style.space(12)
            Label {
                text: root.start === "desktop" ? "From " + root.desktopTitle : "Your palette"
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(16)
                PalettePreview { colours: root.chosen }
                Item { Layout.fillWidth: true }
                Action {
                    id: rerollAction
                    visible: root.start === "surprise"
                    text: "Another"
                    iconText: "󱅖"   // nf-md-dice_multiple
                    iconSize: Style.font.body
                    tooltipText: "Roll a new palette"
                    hasCursor: root.keyNav && root.cursorKey === "reroll"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.seed = root.seed + 1
                    Component.onCompleted: root.register("reroll", rerollAction)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(24)
            visible: root.step === 1
            Item { Layout.fillWidth: true }
            Action {
                id: nextAction
                kind: "primary"
                text: "Next"
                enabled: root.ready
                tooltipText: root.ready ? "Name your theme" : "Choose how to start"
                hasCursor: root.keyNav && root.cursorKey === "next"
                onClicked: root.next()
                Component.onCompleted: root.register("next", nextAction)
            }
        }

        // ---- step 2: name it
        SectionHeader {
            Layout.topMargin: Style.space(16)
            visible: root.step === 2
            text: "Name it"
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(12)
            visible: root.step === 2
            spacing: Style.space(12)
            PalettePreview {
                visible: root.start !== "copy"
                colours: root.chosen
            }
            ThemeArt {
                visible: root.start === "copy" && !!root.copyTheme
                Layout.preferredWidth: Style.space(140)
                Layout.preferredHeight: Math.round(Style.space(140) * 267 / 684)
                theme: root.copyTheme || ({})
            }
            Label {
                Layout.fillWidth: true
                visible: root.start === "copy" && !!root.copyTheme
                text: root.copyTheme ? "A copy of " + Format.themeName(root.copyTheme.name) : ""
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
            }
        }
        NameField {
            id: nameField
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.step === 2
            names: root.names
            hasCursor: root.keyNav && root.cursorKey === "name" && !activeFocus
            onAccepted: root.create()
            Component.onCompleted: root.register("name", nameField)
            onTextChanged: if (root.step === 2 && text !== Format.freeDisplay(root.suggestion, root.names)) root.nameEdited = true
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(24)
            visible: root.step === 2
            Item { Layout.fillWidth: true }
            Action {
                id: createAction
                kind: "primary"
                text: "Create"
                enabled: nameField.ok && root.ready
                tooltipText: !nameField.ok ? "Give it a name first" : "Make the theme and open it in the editor"
                hasCursor: root.keyNav && root.cursorKey === "create"
                onClicked: root.create()
                Component.onCompleted: root.register("create", createAction)
            }
        }
        // Room for the keyboard ring outside Next and Create.
        Item { Layout.preferredHeight: Style.space(4) }
    }
}
