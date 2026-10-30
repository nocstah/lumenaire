pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Format.js" as Format

// One screen of the theme being edited (DESIGN.md "Screen page"), a page in
// the panel opened from a tile on the editor's case map. Three steps:
//
//   screen  what it shows: its picture, "Video · 0:42", Change… and Remove
//           (the pump's clips as a list when it has several: reorder, add,
//           remove, Change every, Shuffle), Brightness, and for the 8.8"
//           screen Shows: Clock and stats | Picture or video. One line under
//           the header says where it stands ("Preparing… 42 %", "On the
//           case", "Couldn't prepare it") with its one action.
//   pick    MediaPicker: This theme, Library, My files
//   crop    CropView, for a file that doesn't fit the screen's shape
//
// Every change is one Service call; the engine's view (theme screens) is
// the authority when it answers. Esc and ← go back a step: crop → pick →
// screen → the editor. Keys: j/k walk the rows, Enter opens or activates,
// h/l step Change every, Brightness (by 5) and Shows, r resets the
// brightness; on a clip Enter picks it up (j/k carry it), Shift+J/K or
// Alt+↑/↓ move it, x or Delete removes it; the menu key opens ⋯.
FocusScope {
    id: root
    required property var service
    property string role: ""
    property var initial: null
    signal backRequested()
    signal showRequested(var item)

    property string step: "screen"              // screen | pick | crop
    property var adding: ({ then: "set", at: null })
    property string tab: "theme"
    property bool tabDecided: false
    property var cropItem: null
    property string cropFrom: "pick"
    property string cursorKey: ""
    property bool keyNav: false
    property int grabbed: -1
    property var items: ({})
    property real localBrightness: -1

    implicitWidth: Style.space(468)
    implicitHeight: body.implicitHeight

    readonly property bool hasService: service !== null && service !== undefined
    readonly property var view: hasService ? service.screensView : null
    readonly property var scr: view && Array.isArray(view.screens) ? view.screens.find(s => s && s.role === role) || null : null
    readonly property var job: hasService && typeof service.jobFor === "function" ? service.jobFor(role) : null
    readonly property var pv: hasService && typeof service.screenPreview === "function" ? service.screenPreview(role) : null
    readonly property bool live: hasService && service.previewLive === true && !!service.preview && !!service.preview.screens
    readonly property bool screensOn: !hasService || service.screens !== "off"
    readonly property bool narrow: width < Style.space(400)
    readonly property string kind: scr ? String(scr.kind || "") : ""
    readonly property string shape: scr ? String(scr.shape || "square") : "square"
    readonly property real aspect: Format.screenAspect(scr)
    readonly property string short: scr ? Format.screenShort(scr) : Format.screenShort(role)
    readonly property var media: scr && scr.media ? scr.media : null
    readonly property var probe: media && media.probe ? media.probe : ({})
    readonly property string mediaKind: String(probe.kind || (media ? media.type : "") || "")
    readonly property var clips: scr && scr.clips && Array.isArray(scr.clips.items) ? scr.clips : null
    readonly property var clipItems: clips ? clips.items : []
    readonly property bool listLayout: kind === "pump" && clipItems.length > 1
    // Clips so far: a single video without a clip list is one.
    readonly property int clipCount: clipItems.length || (media ? 1 : 0)
    readonly property bool templateMode: !!scr && !!scr.modes && scr.modes.current === "template"
    readonly property bool canModes: !!scr && !!scr.modes && Array.isArray(scr.modes.can) && scr.modes.can.indexOf("template") >= 0 && scr.modes.can.indexOf("media") >= 0
    readonly property bool isEmpty: !!scr && !media && !templateMode
    readonly property bool managed: !scr || scr.managed !== false
    readonly property bool listTarget: !!scr && !!scr.target && scr.target.kind === "list"
    readonly property var clipJob: job && Format.jobRunning(job) && job.then === "clip-add" ? job : null
    readonly property var line: Format.screenLine(scr, clipJob ? null : job, pv, { previewLive: live, screensOn: screensOn })
    readonly property var note: hasService && service.mediaNote && service.mediaNote.role === role ? service.mediaNote : null
    readonly property var bright: scr && scr.brightness ? scr.brightness : null
    readonly property int brightValue: localBrightness >= 0 ? Math.round(localBrightness)
        : bright && bright.value !== null && bright.value !== undefined ? Number(bright.value)
        : bright && isFinite(Number(bright.effective)) ? Number(bright.effective) : 100
    readonly property bool brightSet: localBrightness >= 0 ? true : !!bright && bright.value !== null && bright.value !== undefined
    readonly property var limits: view && view.limits ? view.limits : ({})
    readonly property bool canAddClip: kind === "pump" && !isEmpty && !templateMode && (listLayout || mediaKind === "video" || (media && media.type === "video"))
    readonly property string subtitle: step === "pick" ? (adding.then === "clip-add" ? "Add a clip" : "Choose what it shows")
        : step === "crop" ? "Crop to fit"
        : kind === "pump" && !isEmpty && (listLayout || mediaKind === "video") ? Format.clipsSummary(clips)
        : kind === "fan" ? Format.placeWords(scr ? scr.place : "").replace(/^./, c => c.toUpperCase()) : ""
    // The slider's own value shows until the view answers with it (or the
    // edits have gone out and the view says otherwise).
    // A clip picked up from the keyboard is put down when the list changes
    // under it (removed, or another panel changed it).
    onClipItemsChanged: if (grabbed >= clipItems.length) grabbed = -1
    onBrightChanged: if (localBrightness >= 0 && (!hasService || service.editPending !== true || (bright && Number(bright.value) === Math.round(localBrightness)))) localBrightness = -1
    // The width of the captions' column, and what the header has for the name.
    readonly property int captionW: Style.space(88)
    // Back, the name, the subtitle (or a filler) and ⋯, 8 px apart: what the
    // name and the subtitle have between them.
    readonly property real headRoom: body.width + Style.space(6) - backButton.width - Style.space(16) - (menuButton.visible ? menuButton.width + Style.space(8) : 0)
    // A job preparing new media for this screen shows the file it's making.
    readonly property var setJob: job && Format.jobRunning(job) && !clipJob ? job : null
    readonly property string setJobThumb: setJob ? jobThumb(setJob) : ""
    readonly property bool misfit: !!media && ["poor", "cropped"].indexOf(Format.fitState(media.fit)) >= 0

    function register(k, item) { const m = items; m[k] = item; items = m }
    // ---- steps
    function openPick(then, at) {
        adding = { then: then || "set", at: at === undefined ? null : at }
        step = "pick"
        tabDecided = false
        cursorKey = ""
        if (hasService) service.listMedia(tab, role, "", 0)
        root.forceActiveFocus()
        showRequested(null)
    }
    function setTab(t) {
        if (t !== "theme" && t !== "library" && t !== "files") return
        tab = t
        tabDecided = true
        if (hasService) service.listMedia(t, role, pickerLoader.item ? pickerLoader.item.searchText : "", 0)
    }
    // This theme first when it has something that fits; else the Library.
    Connections {
        target: root.hasService ? root.service : null
        ignoreUnknownSignals: true
        function onMediaListChanged() {
            const l = root.service.mediaList
            if (root.step !== "pick" || root.tabDecided || !l || root.service.mediaListState === "loading") return
            root.tabDecided = true
            if (root.tab === "theme" && !(l.items || []).some(it => it && Format.fitState(it.fit) !== "poor")) root.setTab("library")
        }
    }
    function openCrop(item, from) {
        cropItem = item
        cropFrom = from || "pick"
        step = "crop"
        cursorKey = ""
        if (hasService && item && item.path) service.frameAt(String(item.path), -1)
        root.forceActiveFocus()
        showRequested(null)
    }
    function toScreen() {
        step = "screen"
        cropItem = null
        cursorKey = ""
        keyNav = false
        root.forceActiveFocus()
        showRequested(null)
    }
    function choose(item) {
        if (!item || !hasService) return
        if (!Format.fitsAsIs(item.fit)) { openCrop(item, "pick"); return }
        const then = adding.then
        if (tab === "theme" && item.rel) {
            if (then === "clip-add") service.clipAdd(role, String(item.rel), adding.at)
            else service.setScreenMedia(role, String(item.rel), false)
        } else {
            service.prepareMedia(role, String(item.path), { then: then, at: adding.at, thumb: String(item.thumb || "") })
        }
        toScreen()
    }
    function useCrop(crop, time) {
        if (!cropItem || !hasService) return
        service.prepareMedia(role, String(cropItem.path), { crop: crop, time: time, then: adding.then, at: adding.at, thumb: String(cropItem.thumb || "") })
        toScreen()
    }
    // The screen's own media, to crop to its shape.
    function cropCurrent() {
        if (!media) return
        adding = { then: "set", at: null }
        openCrop({ path: String(media.abs || ""), kind: mediaKind, w: probe.w, h: probe.h, duration: probe.duration,
                   thumb: String(media.thumb || ""), title: String(media.title || "") }, "screen")
    }
    function back() {
        if (menu.opened) { menu.close(); return }
        if (grabbed >= 0) { grabbed = -1; return }
        if (step === "crop") { if (cropFrom === "pick") { step = "pick"; cursorKey = "" } else toScreen(); return }
        if (step === "pick") { toScreen(); return }
        backRequested()
    }
    // ---- screen-step actions
    function act(a) {
        if (a === "cancel") cancelJob()
        else if (a === "retry") { if (job && hasService) service.retryMedia(job.id) }
        else if (a === "choose") openPick("set")
        else if (a === "crop") cropCurrent()
    }
    function cancelJob() { const j = clipJob || job; if (j && hasService) service.cancelMedia(j.id) }
    function removeMedia() { if (hasService && !listTarget) service.setScreenMedia(role, "none", false) }
    function moveClip(from, to) { if (hasService) service.clipMove(role, from, to) }
    function removeClip(i) {
        if (!hasService) return
        grabbed = -1
        if (clipItems.length > 1) service.clipRemove(role, i)
        else removeMedia()
    }
    function jobThumb(j) { return hasService && j && typeof service.jobThumb === "function" ? String(service.jobThumb(j.id) || "") : "" }
    function setBrightness(v) {
        if (!hasService) return
        const n = Math.max(0, Math.min(100, Math.round(v / 5) * 5))
        localBrightness = n
        service.setScreenBrightness(role, n)
    }
    function resetBrightness() {
        const was = brightSet
        localBrightness = -1
        if (hasService && was) service.setScreenBrightness(role, null)
    }
    function setEvery(seconds) { if (hasService && clips) service.setRotation(role, Number(seconds), clips.shuffle === true) }
    function setShuffle(on) { if (hasService && clips) service.setRotation(role, Number(clips.rotate) || 0, !!on) }
    function setMode(m) {
        if (!hasService || !scr) return
        if (m === (templateMode ? "template" : "media")) return
        // What it showed before its layout: kept in the draft (_prev).
        const cur = scr.target && scr.target.path ? Format.ptrGet(service.editorDraft || {}, String(scr.target.path)) : null
        const prev = cur && cur._prev ? cur._prev : scr.entry && scr.entry._prev ? scr.entry._prev : null
        if (m === "template" || (prev && prev.path)) service.setScreenMode(role, m)
        else openPick("set")
    }

    // ---- keys
    readonly property var rows: {
        if (step !== "screen" || !scr) return []
        const r = []
        if (canModes) r.push("shows")
        if (line.action !== "") r.push("action")
        if (listLayout) {
            for (let i = 0; i < clipItems.length; i++) r.push("clip:" + i)
            if (clipJob) r.push("job")
            r.push("add", "every", "shuffle")
        } else if (managed) {
            r.push("change")
            if (!isEmpty && !listTarget) r.push("remove")
            if (canAddClip) r.push("add")
        }
        if (managed && !isEmpty) r.push("brightness")
        return r
    }
    function moveCursor(d) {
        keyNav = true
        const r = rows
        let i = r.indexOf(cursorKey)
        i = i < 0 ? (d > 0 ? 0 : r.length - 1) : Math.max(0, Math.min(r.length - 1, i + d))
        cursorKey = r[i] || ""
        Qt.callLater(() => showRequested(items[cursorKey] || null))
    }
    function stepRow(k, d) {
        if (k === "brightness") { setBrightness(brightValue + d * 5); return true }
        if (k === "every" && clips) { setEvery(Format.rotateStep(clips.rotate, d, limits.rotate_choices)); return true }
        if (k === "shows") { setMode(d > 0 ? "media" : "template"); return true }
        if (k === "shuffle" && clips) { setShuffle(d > 0); return true }
        return false
    }
    function activateRow(k) {
        if (k === "shows") setMode(templateMode ? "media" : "template")
        else if (k === "action") act(line.action)
        else if (k === "change") openPick("set")
        else if (k === "remove") removeMedia()
        else if (k === "add") openPick(listLayout || canAddClip ? "clip-add" : "set", clipCount)
        else if (k === "shuffle" && clips) setShuffle(clips.shuffle !== true)
        else if (k === "job") cancelJob()
        else if (k.indexOf("clip:") === 0) { const n = Number(k.slice(5)); grabbed = grabbed === n ? -1 : n }
    }
    function textFocused() {
        const f = root.Window.activeFocusItem
        return !!f && f !== root && f.echoMode !== undefined && f.selectByMouse !== undefined
    }
    Keys.onPressed: function(event) { handleKey(event) }
    function handleKey(event) {
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        const alt = (event.modifiers & Qt.AltModifier) !== 0
        if (textFocused()) {
            if (event.key === Qt.Key_Escape) { root.forceActiveFocus(); event.accepted = true }
            return
        }
        if (event.key === Qt.Key_Escape) { back(); event.accepted = true; return }
        if (step === "crop") {
            if (cropLoader.item && cropLoader.item.handleKey(event)) event.accepted = true
            return
        }
        if (step === "pick") {
            const p = pickerLoader.item
            if (!p) return
            const tabs = ["theme", "library", "files"]
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                const d = event.key === Qt.Key_Backtab || shift ? -1 : 1
                setTab(tabs[(tabs.indexOf(tab) + d + 3) % 3]); event.accepted = true; return
            }
            if (event.text === "1" || event.text === "2" || event.text === "3") { setTab(tabs[Number(event.text) - 1]); event.accepted = true; return }
            if (event.text === "/") { p.focusSearch(); event.accepted = true; return }
            const dx = event.key === Qt.Key_Right || event.text === "l" ? 1 : event.key === Qt.Key_Left || event.text === "h" ? -1 : 0
            const dy = event.key === Qt.Key_Down || event.text === "j" ? 1 : event.key === Qt.Key_Up || event.text === "k" ? -1 : 0
            if (dx || dy) { p.moveCursor(dx, dy); Qt.callLater(() => showRequested(items[p.cursor === -2 ? "media:more" : "media:" + p.cursor] || null)); event.accepted = true; return }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { p.activateCursor(); event.accepted = true }
            return
        }
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && shift)) { if (kind === "fan") openMenu(); event.accepted = true; return }
        const down = event.key === Qt.Key_Down || event.text === "j" || event.text === "J"
        const up = event.key === Qt.Key_Up || event.text === "k" || event.text === "K"
        const onClip = cursorKey.indexOf("clip:") === 0
        const n = onClip ? Number(cursorKey.slice(5)) : -1
        // Carry a clip: picked up, or Shift+J/K and Alt+arrows.
        if (onClip && (down || up) && (grabbed === n || shift || alt || event.text === "J" || event.text === "K")) {
            const to = Math.max(0, Math.min(clipItems.length - 1, n + (down ? 1 : -1)))
            if (to !== n) {
                if (clipLoader.item) clipLoader.item.move(n, to)
                if (grabbed === n) grabbed = to
                cursorKey = "clip:" + to
            }
            event.accepted = true
            return
        }
        if (onClip && (event.text === "x" || event.key === Qt.Key_Delete)) { removeClip(n); event.accepted = true; return }
        if (down) { grabbed = -1; moveCursor(1); event.accepted = true; return }
        if (up) { grabbed = -1; moveCursor(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { if (stepRow(cursorKey, 1)) event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { if (stepRow(cursorKey, -1)) event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (!keyNav) moveCursor(1)
            else if (cursorKey) activateRow(cursorKey)
            event.accepted = true
            return
        }
        if (event.text === "r") { resetBrightness(); event.accepted = true }
    }
    function replayKeys(list) {
        for (const k of (list || [])) handleKey({ key: Number(k.key || 0), text: String(k.text || ""), modifiers: Number(k.modifiers || 0), accepted: false })
    }

    // ---- ⋯ (fan screens)
    function openMenu() {
        menu.items = [{ key: "allfans", label: "Use on every fan screen", glyph: "󰈐", enabled: !!media && !templateMode,
                        tip: media ? "Every fan screen shows this, and their own choices go" : "Choose something for this screen first" }]
        menu.openAt(menuButton)
    }
    function popupBottom() {
        return menu.opened && menu.contentItem ? menu.contentItem.mapToItem(null, 0, menu.contentItem.height).y + menu.bottomPadding : 0
    }

    Component.onCompleted: {
        const i = initial || {}
        if (i.tab) tab = String(i.tab)
        if (i.adding) adding = { then: String(i.adding.then || "set"), at: i.adding.at === undefined ? null : i.adding.at }
        if (i.step === "pick") { step = "pick"; tabDecided = true }
        if (i.step === "crop") {
            step = "crop"
            cropFrom = i.cropFrom ? String(i.cropFrom) : "pick"
            const list = hasService && service.mediaList && Array.isArray(service.mediaList.items) ? service.mediaList.items : []
            cropItem = i.cropItem && typeof i.cropItem === "object" ? i.cropItem : list[Number(i.cropIndex || 0)] || null
        }
        if (i.grabbed !== undefined) grabbed = Number(i.grabbed)
        if (i.cursor !== undefined) { keyNav = true; cursorKey = String(i.cursor) }
        if (i.brightness !== undefined) localBrightness = Number(i.brightness)
        Qt.callLater(() => {
            if (i.query !== undefined && pickerLoader.item) pickerLoader.item.presetQuery(String(i.query))
            if (i.pickCursor !== undefined && pickerLoader.item) { pickerLoader.item.keyNav = true; pickerLoader.item.cursor = Number(i.pickCursor) }
            if (i.crop && cropLoader.item) cropLoader.item.restore(i.crop)
            if (i.drag && clipLoader.item) clipLoader.item.dragState = i.drag
            if (Array.isArray(i.keys)) replayKeys(i.keys)
            if (i.menu) openMenu()
        })
    }

    component Caption: Label {
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Layout.preferredWidth: root.captionW
        Layout.alignment: Qt.AlignVCenter
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
                tooltipText: root.step !== "screen" ? "Back" : root.hasService && root.service.editorName ? "Back to " + Format.themeName(root.service.editorName) : "Back to the theme"
                Layout.leftMargin: -Style.space(6)
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.back()
            }
            Label {
                id: titleLabel
                text: root.short
                font.pixelSize: Style.font.heading
                font.bold: true
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Layout.preferredWidth: Math.min(implicitWidth, Math.max(Style.space(60), root.headRoom))
                Layout.alignment: Qt.AlignVCenter
                MouseArea { id: titleMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                Ui.PanelToolTip { visible: titleMouse.containsMouse && titleLabel.truncated; text: titleLabel.text }
            }
            // The subtitle only where it fits whole; a long name comes first.
            Label {
                id: subtitleLabel
                text: root.subtitle
                visible: text !== "" && titleLabel.implicitWidth + implicitWidth <= root.headRoom
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                Layout.topMargin: Style.space(2)
            }
            Item { Layout.fillWidth: true; visible: !subtitleLabel.visible }
            IconButton {
                id: menuButton
                visible: root.step === "screen" && root.kind === "fan" && root.managed
                glyph: "󰇘"   // nf-md-dots_horizontal
                tooltipText: "More"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.openMenu()
            }
        }

        // Not in the view (the engine is reading it, or it went away).
        Label {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: !root.scr
            tone: "muted"
            text: root.hasService && root.service.screensState === "failed" ? String(root.service.screensError || "Couldn't read the screens.") : "Reading the screens…"
        }

        // The disk is nearly full: said once, before anything new is made.
        Notice {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            visible: root.step !== "crop" && !!root.view && !!root.view.disk && !!root.view.disk.warn
            glyph: "󰋊"   // nf-md-harddisk
            text: root.view && root.view.disk && /stage/.test(String(root.view.disk.warn || ""))
                ? "Media waiting to be saved takes a lot of room. Save or discard a theme to free it."
                : "Your disk is nearly full. New media may not fit."
        }

        // ---- screen
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.step === "screen" && !!root.scr
            spacing: 0

            // Where it stands, and the one thing to do about it.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                visible: root.line.text !== "" || !!root.note
                spacing: Style.space(8)
                Item {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    implicitHeight: lineWords.implicitHeight
                    ColumnLayout {
                        id: lineWords
                        width: parent.width
                        spacing: Style.space(2)
                        Label {
                            id: lineLabel
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: root.line.text
                            tone: root.line.level === "urgent" ? "urgent" : "muted"
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                            MouseArea { id: lineMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            Ui.PanelToolTip {
                                readonly property string full: [lineLabel.truncated ? root.line.text : "", root.line.tip].filter(x => x !== "").join("\n")
                                visible: lineMouse.containsMouse && full !== ""
                                text: full
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            visible: !!root.note
                            text: root.note ? String(root.note.text) : ""
                            tone: root.note && root.note.level === "urgent" ? "urgent" : "muted"
                            font.pixelSize: Style.font.bodySmall
                            MouseArea { id: noteMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            Ui.PanelToolTip { visible: noteMouse.containsMouse && !!root.note && !!root.note.tip; text: root.note && root.note.tip ? String(root.note.tip) : "" }
                        }
                    }
                }
                Action {
                    id: lineAction
                    visible: root.line.action !== ""
                    text: ({ cancel: "Cancel", retry: "Try again", choose: "Choose another", crop: "Crop to fit" })[root.line.action] || ""
                    hasCursor: root.keyNav && root.cursorKey === "action"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.act(root.line.action)
                    Component.onCompleted: root.register("action", lineAction)
                }
            }

            // The 8.8" screen: its clock-and-stats layout, or a picture or video.
            GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                visible: root.canModes
                columns: root.captionW + Style.space(8) + showsGroup.implicitWidth > body.width ? 1 : 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)
                Caption { text: "Shows" }
                Segmented {
                    id: showsGroup
                    options: [{ value: "template", label: "Clock and stats", tooltip: "The theme's clock, date and readings layout" },
                              { value: "media", label: "Picture or video", tooltip: "A picture or video of your choosing" }]
                    value: root.templateMode ? "template" : "media"
                    fontSize: Style.font.body
                    cursorIndex: root.keyNav && root.cursorKey === "shows" ? (root.templateMode ? 0 : 1) : -1
                    onChanged: function(v) { root.setMode(v) }
                    Component.onCompleted: root.register("shows", showsGroup)
                }
            }

            // What it shows: the picture, what it is, Change… and Remove.
            GridLayout {
                id: mediaBlock
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                visible: !root.listLayout
                readonly property bool stacked: root.shape === "strip"
                columns: stacked ? 1 : 2
                columnSpacing: Style.space(16)
                rowSpacing: Style.space(12)
                readonly property int picW: stacked ? body.width
                    : root.shape === "wide-curve" || root.shape === "wide" ? Style.space(root.narrow ? 150 : 200)
                    : Style.space(root.narrow ? 104 : 120)
                MediaThumb {
                    Layout.preferredWidth: mediaBlock.picW
                    Layout.preferredHeight: Math.round(mediaBlock.picW / Math.max(0.1, root.aspect))
                    Layout.alignment: Qt.AlignTop
                    source: root.setJobThumb !== "" ? root.setJobThumb
                        : root.templateMode && root.scr && root.scr.template ? String(root.scr.template.thumb || "")
                        : root.media ? String(root.media.thumb || "") : ""
                    thumbState: root.setJobThumb === "" && root.media ? String(root.media.thumb_state || "") : ""
                    fit: root.misfit && root.setJobThumb === "" ? "contain" : "cover"
                    round: root.shape === "round"
                    glyph: Format.screenGlyph(root.kind)
                    ring: root.scr && root.scr.changed ? "changed" : ""
                    dim: root.setJob ? 0.45 : 0
                    opacity: root.managed ? 1 : 0.45
                    MouseArea { id: picMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    Ui.PanelToolTip {
                        readonly property string full: {
                            if (!root.media || root.templateMode) return ""
                            const dims = Number(root.probe.w) > 0 ? root.probe.w + "×" + root.probe.h : ""
                            return [String(root.media.title || ""), dims, root.media.fit ? Format.fitTip(root.media.fit, root.short) : ""].filter(x => x).join("\n")
                        }
                        visible: picMouse.containsMouse && full !== ""
                        text: full
                    }
                }
                // The layout of the 8.8" screen isn't edited here yet: its
                // picture says it all (Shows switches it).
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: mediaBlock.stacked ? Qt.AlignLeft : Qt.AlignVCenter
                    visible: !root.templateMode
                    spacing: Style.space(12)
                    Label {
                        Layout.fillWidth: true
                        // While a file is prepared its picture shows: so do its words.
                        readonly property var src: root.setJobThumb !== "" && root.setJob && root.setJob.source ? root.setJob.source : null
                        text: !root.managed ? "Not managed"
                            : src ? [Format.mediaKindWord(src.kind), Format.clipLength(src.duration)].filter(x => x).join(" · ")
                            : root.templateMode ? "Clock and stats"
                            : root.isEmpty ? "Unchanged"
                            : [Format.mediaKindWord(root.mediaKind), Format.clipLength(root.probe.duration)].filter(x => x).join(" · ")
                        tone: root.isEmpty || !root.managed ? "muted" : "text"
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        MouseArea { id: metaMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        Ui.PanelToolTip {
                            visible: metaMouse.containsMouse && (root.isEmpty || !root.managed)
                            text: !root.managed ? "The hardware profile leaves this screen alone" : "This theme leaves this screen as it is"
                        }
                    }
                    Flow {
                        Layout.fillWidth: true
                        visible: root.managed
                        spacing: Style.space(8)
                        Action {
                            id: changeAction
                            text: root.isEmpty ? "Choose…" : "Change…"
                            tooltipText: "Pick a picture or video for the " + root.short.toLowerCase()
                            hasCursor: root.keyNav && root.cursorKey === "change"
                            onClicked: root.openPick("set")
                            Component.onCompleted: root.register("change", changeAction)
                        }
                        // A fan dealt from the theme's shared list always shows
                        // something: no Remove there.
                        Action {
                            id: removeAction
                            visible: !root.isEmpty && !root.listTarget
                            text: "Remove"
                            tooltipText: "This theme leaves the " + root.short.toLowerCase() + " as it is"
                            hasCursor: root.keyNav && root.cursorKey === "remove"
                            onClicked: root.removeMedia()
                            Component.onCompleted: root.register("remove", removeAction)
                        }
                    }
                }
            }

            // The pump's clips, when it takes turns.
            Loader {
                id: clipLoader
                Layout.fillWidth: true
                Layout.topMargin: Style.space(12)
                active: root.listLayout
                visible: active
                sourceComponent: ClipList {
                    page: root
                    items: root.clipItems
                    job: root.clipJob
                    aspect: root.aspect
                }
            }
            Action {
                id: addAction
                Layout.topMargin: Style.space(root.listLayout ? 8 : 16)
                visible: root.canAddClip
                text: "Add clip"
                iconText: "󰐕"   // nf-md-plus
                iconSize: Style.font.body
                enabled: !root.clipJob && root.clipCount < (root.clips && root.clips.max ? Number(root.clips.max) : Number(root.limits.clips_max) || 64)
                tooltipText: root.clipJob ? "Waits for the clip being prepared" : root.listLayout ? "Add a video to take turns with these"
                    : "Add a second video: they take turns on the pump"
                hasCursor: root.keyNav && root.cursorKey === "add"
                onClicked: root.openPick("clip-add", root.clipCount)
                Component.onCompleted: root.register("add", addAction)
            }
            GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(16)
                visible: root.listLayout
                columns: root.captionW + Style.space(8) + everyGroup.implicitWidth > body.width ? 1 : 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)
                Caption { text: "Change every" }
                Segmented {
                    id: everyGroup
                    readonly property var opts: Format.rotateOptions(root.limits.rotate_choices)
                    options: opts.map(o => Object.assign({}, o, { tooltip: o.value === "0" ? "Stay on the first clip" : "Next clip every " + o.label }))
                    value: root.clips ? String(Number(root.clips.rotate) || 0) : ""
                    fontSize: Style.font.body
                    cursorIndex: root.keyNav && root.cursorKey === "every" ? Math.max(0, opts.findIndex(o => o.value === value)) : -1
                    onChanged: function(v) { root.setEvery(Number(v)) }
                    Component.onCompleted: root.register("every", everyGroup)
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(8)
                visible: root.listLayout
                spacing: Style.space(8)
                Caption { text: "Shuffle" }
                Ui.ToggleSwitch {
                    id: shuffleSwitch
                    checked: !!root.clips && root.clips.shuffle === true
                    hasCursor: root.keyNav && root.cursorKey === "shuffle"
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: -Style.space(6)
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: "Shuffle" + (checked ? ", on" : ", off")
                    onToggled: root.setShuffle(!checked)
                    Component.onCompleted: root.register("shuffle", shuffleSwitch)
                    Ui.PanelToolTip { visible: shuffleSwitch.containsMouse; text: "Take turns in a random order" }
                }
                Item { Layout.fillWidth: true }
            }

            // Brightness, 0-100 in steps of 5.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(root.listLayout ? 8 : 16)
                visible: root.managed && !root.isEmpty
                spacing: Style.space(8)
                Caption { text: "Brightness" }
                Ui.CursorSurface {
                    id: brightRow
                    Layout.fillWidth: true
                    implicitHeight: Style.spacing.controlHeight
                    hasCursor: root.keyNav && root.cursorKey === "brightness"
                    Accessible.role: Accessible.Slider
                    Accessible.name: "Brightness " + root.brightValue + " percent"
                    Component.onCompleted: root.register("brightness", brightRow)
                    Ui.PanelSlider {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        minimum: 0
                        maximum: 100
                        step: 5
                        integer: true
                        trackColor: Style.selectedFillFor(Commons.Color.popups.text, Commons.Color.accent)
                        fillColor: Commons.Color.popups.text
                        knobColor: Commons.Color.popups.text
                        value: root.brightValue
                        onMoved: function(v) { if (Math.round(v / 5) * 5 !== root.brightValue) root.setBrightness(v) }
                    }
                }
                Label {
                    text: root.brightValue + " %"
                    tone: root.brightSet ? "text" : "muted"
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.NoWrap
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Style.space(36)
                    Layout.alignment: Qt.AlignVCenter
                    MouseArea { id: brightMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    Ui.PanelToolTip { visible: brightMouse.containsMouse && !root.brightSet; text: "The screen's own brightness" }
                }
            }
            TextLink {
                id: brightReset
                visible: root.managed && !root.isEmpty && root.brightSet
                text: "Use default"
                tooltipText: "Back to the screen's own brightness"
                Layout.leftMargin: root.captionW + Style.space(16) - inset
                Layout.topMargin: Style.space(2)
                onClicked: root.resetBrightness()
            }
        }

        // ---- pick
        Loader {
            id: pickerLoader
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            active: root.step === "pick" && !!root.scr
            visible: active
            sourceComponent: MediaPicker {
                page: root
                screen: root.scr
                tab: root.tab
                list: root.hasService ? root.service.mediaList : null
                listState: root.hasService ? String(root.service.mediaListState || "idle") : "idle"
                listError: root.hasService ? String(root.service.mediaListError || "") : ""
                onTabChosen: function(t) { root.setTab(t) }
                onQueryEdited: function(q) { if (root.hasService) root.service.listMedia(root.tab, root.role, q, 0) }
                onChosen: function(it) { root.choose(it) }
                onMoreRequested: if (root.hasService) root.service.moreMedia()
            }
        }

        // ---- crop
        Loader {
            id: cropLoader
            Layout.fillWidth: true
            Layout.topMargin: Style.space(16)
            active: root.step === "crop" && !!root.scr && !!root.cropItem
            visible: active
            sourceComponent: CropView {
                page: root
                item: root.cropItem
                frame: root.hasService ? root.service.frame : null
                frameState: root.hasService ? String(root.service.frameState || "idle") : "idle"
                screen: root.scr
                onUseRequested: function(crop, time) { root.useCrop(crop, time) }
                onFrameWanted: function(t) { if (root.hasService && root.cropItem) root.service.frameAt(String(root.cropItem.path), t) }
            }
        }
        // Room for the rings under the last row.
        Item { Layout.preferredHeight: Style.space(4) }
    }

    MenuPopup {
        id: menu
        onChosen: function(key) { if (key === "allfans" && root.media && root.hasService) root.service.setScreenMedia(root.role, String(root.media.rel || ""), true) }
        onClosed: root.forceActiveFocus()
    }
}
