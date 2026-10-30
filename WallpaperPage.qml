pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// A theme's desktop wallpaper (DESIGN.md "Wallpaper page"), a page in the
// panel opened from the main page's Wallpaper row (the theme the desktop
// follows now: the one paired with the Omarchy theme) or from a card's menu
// (any theme). The settings are the theme's own and take effect at once;
// there is no Save:
//
//   Animated wallpaper    the switch, and one muted line: whether the
//                         wallpaper on the desktop has an animated version,
//                         or (another theme) when these settings apply
//   Pause while you work  the switch: it holds still while the keyboard or
//                         mouse is in use (shown while animated)
//   Resume after          3 s · 5 s · 10 s · 30 s, and a value set elsewhere
//   While you work        Freeze · Show still image (both while it pauses)
//   Use defaults          when the theme keeps settings of its own
//
// Every change is one Service call (setDesktop): the Service shows it at
// once and the engine's view is the authority when it answers. One line
// under the header says what stands in the way: the desktop can't take the
// settings, they can't be read, a change didn't go through.
//
// Keys: j/k walk the rows, Enter or Space switches or steps, h/l step a
// choice or set a switch, r uses the defaults, Esc goes back.
FocusScope {
    id: root
    required property var service
    property string theme: ""
    property var initial: null
    signal backRequested()
    signal showRequested(var item)

    property string cursorKey: ""
    property bool keyNav: false
    property var items: ({})

    implicitWidth: Style.space(468)
    implicitHeight: body.implicitHeight

    readonly property bool hasService: service !== null && service !== undefined
    readonly property var view: hasService && service.desktop && String(service.desktop.theme || "") === theme ? service.desktop : null
    readonly property bool home: hasService && theme !== "" && theme === String(service.desktopHome || "")
    readonly property string readState: hasService ? String(service.desktopState || "closed") : "closed"
    readonly property bool available: !!view && view.available === true
    readonly property var settings: view && view.settings ? view.settings : ({})
    readonly property bool animated: settings.animated !== false
    readonly property bool pauses: animated && settings.pause_while_active === true
    readonly property int resume: Number(settings.resume_after_idle) || 5
    readonly property string whileActive: settings.while_active === "still" ? "still" : "freeze"
    readonly property bool custom: available && Format.desktopCustom(view)
    readonly property string animatedLine: Format.desktopAnimatedLine(view, home)
    readonly property string errorText: hasService ? String(service.desktopError || "") : ""
    // The one line under the header, the first that applies: {text, level, tip}.
    readonly property var line: {
        if (!view) return readState === "failed" ? { text: errorText || "Couldn't read the wallpaper settings.", level: "", tip: String(service.desktopErrorTip || "") }
            : { text: "Reading the settings…", level: "", tip: "" }
        if (!available) return { text: Format.desktopUnavailable(view.reason), level: "", tip: "" }
        if (errorText) return { text: errorText, level: "urgent", tip: String(service.desktopErrorTip || "") }
        return { text: "", level: "", tip: "" }
    }
    readonly property string themeTitle: Format.themeName(theme)
    // Back, the title and the subtitle, 8 px apart: what the subtitle has.
    readonly property real headRoom: body.width + Style.space(6) - backButton.width - titleLabel.implicitWidth - Style.space(16)

    function set(key, value) { if (hasService && available) service.setDesktop(key, value, theme) }
    function useDefaults() { if (hasService && custom) service.resetDesktop(theme) }
    function back() { backRequested() }
    function register(k, item) { const m = items; m[k] = item; items = m }

    // ---- keys
    readonly property var rows: {
        if (!available) return []
        const r = ["animated"]
        if (animated) r.push("pause")
        if (pauses) r.push("resume", "while")
        if (custom) r.push("defaults")
        return r
    }
    function moveCursor(d) {
        const r = rows
        if (r.length === 0) return
        if (!keyNav) { keyNav = true; cursorKey = r.indexOf(cursorKey) >= 0 ? cursorKey : r[0] }
        else {
            let i = r.indexOf(cursorKey)
            i = i < 0 ? (d > 0 ? 0 : r.length - 1) : Math.max(0, Math.min(r.length - 1, i + d))
            cursorKey = r[i]
        }
        Qt.callLater(() => showRequested(items[cursorKey] || null))
    }
    function stepRow(k, d) {
        if (k === "animated") { set("animated", d > 0); return true }
        if (k === "pause") { set("pause_while_active", d > 0); return true }
        if (k === "resume") { set("resume_after_idle", Format.resumeStep(resume, d)); return true }
        if (k === "while") { set("while_active", d > 0 ? "still" : "freeze"); return true }
        return false
    }
    function activateRow(k) {
        if (k === "animated") set("animated", !animated)
        else if (k === "pause") set("pause_while_active", !pauses)
        else if (k === "resume") { const c = Format.resumeOptions(resume).map(o => Number(o.value)); set("resume_after_idle", c[(c.indexOf(resume) + 1) % c.length]) }
        else if (k === "while") set("while_active", whileActive === "still" ? "freeze" : "still")
        else if (k === "defaults") useDefaults()
    }
    // The rows change under the cursor (a switch hides the rows after it).
    onRowsChanged: if (keyNav && cursorKey && rows.indexOf(cursorKey) < 0) cursorKey = rows.length ? rows[rows.length - 1] : ""
    Keys.onPressed: function(event) { handleKey(event) }
    function handleKey(event) {
        if (event.key === Qt.Key_Escape) { back(); event.accepted = true; return }
        const down = event.key === Qt.Key_Down || event.text === "j"
        const up = event.key === Qt.Key_Up || event.text === "k"
        if (down || up) { moveCursor(down ? 1 : -1); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { if (keyNav && stepRow(cursorKey, 1)) event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { if (keyNav && stepRow(cursorKey, -1)) event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (!keyNav) moveCursor(1)
            else if (cursorKey) activateRow(cursorKey)
            event.accepted = true
            return
        }
        if (event.text === "r") { useDefaults(); event.accepted = true }
    }
    function replayKeys(list) {
        for (const k of (list || [])) handleKey({ key: Number(k.key || 0), text: String(k.text || ""), modifiers: Number(k.modifiers || 0), accepted: false })
    }
    function popupBottom() { return 0 }

    Component.onCompleted: {
        const i = initial || {}
        if (i.cursor !== undefined) { keyNav = true; cursorKey = String(i.cursor) }
        if (Array.isArray(i.keys)) Qt.callLater(() => replayKeys(i.keys))
    }

    component Caption: Label {
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Layout.alignment: Qt.AlignVCenter
    }
    // A switch setting: its name, one muted line and the switch on the right.
    component Setting: RowLayout {
        id: setting
        property string key: ""
        property string title: ""
        property string sub: ""
        property string tip: ""
        property bool checked: false
        signal toggled()
        Layout.fillWidth: true
        spacing: Style.space(8)
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)
            Label { text: setting.title; Layout.fillWidth: true; wrapMode: Text.NoWrap; elide: Text.ElideRight }
            Label { text: setting.sub; visible: text !== ""; Layout.fillWidth: true; tone: "muted"; font.pixelSize: Style.font.bodySmall }
        }
        Ui.ToggleSwitch {
            id: settingSwitch
            checked: setting.checked
            hasCursor: root.keyNav && root.cursorKey === setting.key
            Layout.alignment: Qt.AlignVCenter
            Accessible.role: Accessible.CheckBox
            Accessible.name: setting.title + (checked ? ", on" : ", off")
            onToggled: { root.cursorKey = setting.key; setting.toggled() }
            Component.onCompleted: root.register(setting.key, settingSwitch)
            Ui.PanelToolTip { visible: settingSwitch.containsMouse && setting.tip !== ""; text: setting.tip }
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
                id: backButton
                glyph: "󰁍"   // nf-md-arrow_left
                tooltipText: "Back to themes"
                Layout.leftMargin: -Style.space(6)
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.back()
            }
            Label {
                id: titleLabel
                text: "Wallpaper"
                font.pixelSize: Style.font.heading
                font.bold: true
                wrapMode: Text.NoWrap
                Layout.alignment: Qt.AlignVCenter
            }
            // The theme these settings belong to.
            Label {
                id: subtitleLabel
                text: root.themeTitle
                visible: text !== ""
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.maximumWidth: Math.max(0, root.headRoom)
                Layout.alignment: Qt.AlignVCenter
                Layout.topMargin: Style.space(2)
                MouseArea { id: subMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                Ui.PanelToolTip { visible: subMouse.containsMouse && subtitleLabel.truncated; text: root.themeTitle }
            }
            Item { Layout.fillWidth: true; visible: !subtitleLabel.visible }
        }

        // What stands in the way, when something does.
        Label {
            id: lineLabel
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: text !== ""
            text: root.line.text
            tone: root.line.level === "urgent" ? "urgent" : "muted"
            MouseArea { id: lineMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            Ui.PanelToolTip { visible: lineMouse.containsMouse && root.line.tip !== ""; text: root.line.tip }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.available
            spacing: 0

            Setting {
                Layout.topMargin: Style.space(16)
                key: "animated"
                title: "Animated wallpaper"
                sub: root.animatedLine
                tip: root.home && !!root.view && root.view.user_clip === true ? "For the theme's own wallpaper; the video you picked keeps playing"
                    : root.animated ? "The wallpaper moves while " + root.themeTitle + " is on" : "The still wallpaper while " + root.themeTitle + " is on"
                checked: root.animated
                onToggled: root.set("animated", !root.animated)
            }
            Setting {
                Layout.topMargin: Style.space(16)
                visible: root.animated
                key: "pause"
                title: "Pause while you work"
                sub: "Holds still while you use the keyboard or mouse"
                tip: "It stops while you type or move the mouse, and goes on once you stop"
                checked: root.pauses
                onToggled: root.set("pause_while_active", !root.pauses)
            }
            GridLayout {
                id: choices
                Layout.fillWidth: true
                Layout.topMargin: Style.space(12)
                visible: root.pauses
                readonly property real captionW: Math.max(resumeCaption.implicitWidth, whileCaption.implicitWidth)
                columns: captionW + Style.space(8) + Math.max(resumeGroup.implicitWidth, whileGroup.implicitWidth) > body.width ? 1 : 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)
                Caption { id: resumeCaption; text: "Resume after"; Layout.preferredWidth: choices.captionW }
                Segmented {
                    id: resumeGroup
                    options: Format.resumeOptions(root.resume).map(o => Object.assign({}, o, { tooltip: "Goes on after " + o.label + " without typing or moving the mouse" }))
                    value: String(root.resume)
                    fontSize: Style.font.body
                    cursorIndex: root.keyNav && root.cursorKey === "resume" ? Math.max(0, options.findIndex(o => o.value === value)) : -1
                    onChanged: function(v) { root.cursorKey = "resume"; root.set("resume_after_idle", Number(v)) }
                    Component.onCompleted: root.register("resume", resumeGroup)
                }
                Caption { id: whileCaption; text: "While you work"; Layout.preferredWidth: choices.captionW; Layout.topMargin: choices.columns === 1 ? Style.space(4) : 0 }
                Segmented {
                    id: whileGroup
                    options: [{ value: "freeze", label: "Freeze", tooltip: "Keeps the frame it was on" },
                              { value: "still", label: "Show still image", tooltip: "Fades to the still wallpaper" }]
                    value: root.whileActive
                    fontSize: Style.font.body
                    cursorIndex: root.keyNav && root.cursorKey === "while" ? (root.whileActive === "still" ? 1 : 0) : -1
                    onChanged: function(v) { root.cursorKey = "while"; root.set("while_active", v) }
                    Component.onCompleted: root.register("while", whileGroup)
                }
            }
            TextLink {
                id: defaultsLink
                visible: root.custom
                text: "Use defaults"
                tooltipText: "Back to the settings every theme starts with"
                hasCursor: root.keyNav && root.cursorKey === "defaults"
                Layout.leftMargin: -inset
                Layout.topMargin: Style.space(16)
                onClicked: root.useDefaults()
                Component.onCompleted: root.register("defaults", defaultsLink)
            }
        }
        // Room for the rings under the last row.
        Item { Layout.preferredHeight: Style.space(4) }
    }
}
