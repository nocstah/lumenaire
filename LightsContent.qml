pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Format.js" as Format

// The Lumenaire panel body, hosted by Panel.qml (and by tests/render.qml
// offscreen). It binds only to the Service API (spec §5): every value is read
// from `service`, every change is one call that returns at once, and the
// notice text is chosen by the Service. Nothing here starts a Process or
// touches the daemon socket.
//
// Five pages (`page`): "main", "new" (NewTheme, the guided New theme flow),
// "editor" (ThemeEditor), "screen" (ScreenPage: one LCD of the theme being
// edited; the editor stays loaded under it, so back returns to it as it
// was) and "wallpaper" (WallpaperPage: a theme's desktop wallpaper). The
// main page, top to bottom (DESIGN.md): header (name, active theme, Edit,
// ⋯, ✕), notices, live readings, the Lights and Screens tiles, the pump
// video row, the night theme row and the wallpaper row, then Themes, so
// every quick control shows without scrolling. Card menus, confirms and the
// ⋯ menu are MenuPopups anchored to what opened them.
FocusScope {
    id: root
    required property var service
    signal closeRequested()
    signal tabRequested(int direction)

    // Whether the panel is open. Item.visible stays true inside a hidden
    // PanelWindow, so the 1 s clock keys off this (Panel binds `opened`; the
    // render harness leaves it true).
    property bool shown: true
    // The panel caps the content; the render harness lifts the cap to see it all.
    property int maxHeight: Style.space(720)
    // The harness pins the clock to the fixture's timestamp; 0 means live.
    property real fixedNow: 0
    property real tickNow: Date.now() / 1000
    readonly property real now: fixedNow > 0 ? fixedNow : tickNow

    // Keyboard cursor over the flat theme list; drawn only after an arrow key.
    property int cursor: 0
    property bool keyNav: false
    // A card confirm the harness opens: {kind: reapply | night | menu | rename | delete, name}.
    property var confirm: null
    property string renameTo: ""
    // "main", "new", "editor", "screen" or "wallpaper". It survives a close
    // (a popout switch reopens it where it was).
    property string page: "main"
    // View state handed in by the harness (editor rows, wizard step, …).
    property var editorUi: null
    property var wizardUi: null
    // The screen page: {role, step, …} (the harness adds its view state).
    property var screenUi: null
    // The wallpaper page: {theme} (the harness adds cursor and keys).
    property var wallpaperUi: null
    property real editorScroll: 0
    property var menuUi: null
    // "Saved Hellfire. Use it now?" after the editor saved a theme that isn't on.
    property var savedOffer: null
    property var pendingSave: null
    property string lastEditorState: "closed"
    // The Omarchy desktop, for "Match my desktop": its name and colours.toml.
    // Live they come from the current theme; the harness sets them.
    property string desktopName: omarchy && omarchy.current ? String(omarchy.current) : ""
    property string desktopColorsLive: ""
    property string desktopColors: desktopColorsLive

    readonly property bool hasService: service !== null && service !== undefined
    readonly property bool ready: hasService && service.ready === true
    readonly property string engineError: hasService ? (service.engineError || "") : ""
    readonly property bool engineUsable: ready && engineError === ""
    readonly property var status: hasService && service.status ? service.status : ({})
    readonly property var themes: hasService && service.themes ? service.themes : []
    readonly property string activeTheme: hasService ? (service.activeTheme || "") : ""
    readonly property string dayTheme: hasService ? (service.dayTheme || "") : ""
    readonly property string nightTheme: hasService ? (service.nightTheme || "") : ""
    readonly property var schedule: hasService && service.schedule ? service.schedule : null
    readonly property var omarchy: hasService && service.omarchy ? service.omarchy : null
    readonly property var busy: hasService ? service.busy : null
    readonly property bool lightsOn: hasService && service.lights === "on"
    readonly property bool screensOn: hasService && service.screens === "on"
    readonly property bool daemonOffline: hasService && service.daemonState === "offline"
    readonly property var settings: hasService && service.settings ? service.settings : ({})
    readonly property var ops: hasService && service.ops ? service.ops : ({})
    readonly property bool isNight: !!schedule && schedule.enabled === true && schedule.period === "night"
    // What this PC has (the hardware profile, contract v1.1). A Service
    // without these (an older one, or v1.0 data) shows every section.
    readonly property bool hasLianli: !hasService || service.hasLianli !== false
    readonly property bool hasPump: !hasService || service.hasPump !== false
    readonly property bool hasCpu: !hasService || service.hasCpuSensor !== false
    readonly property bool hasGpu: !hasService || service.hasGpuSensor !== false
    readonly property var screensWant: hasService && service.screensWant !== undefined ? service.screensWant : null
    readonly property bool hasScreens: screensWant === null || Number(screensWant) > 0
    readonly property var powerDetail: hasService && service.powerDetail !== undefined ? service.powerDetail : Format.legacyGroups()

    readonly property var handThemes: themes.filter(t => !t.auto).sort(function(a, b) {
        const ra = rank(a.name), rb = rank(b.name)
        return ra !== rb ? ra - rb : (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    })
    readonly property var autoThemes: themes.filter(t => t.auto).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    readonly property var flatThemes: handThemes.concat(autoThemes)
    // Two columns at every width: the previews are wide (684:267) and carry
    // small screens, so they need the room more than the grid needs rows.
    readonly property int gridColumns: 2
    readonly property int gridGap: Style.space(12)
    readonly property int overdraw: Style.space(8)
    readonly property bool narrow: column.width < Style.space(400)
    // New themes that were never saved: their drafts wait here.
    readonly property var unsavedDrafts: (hasService && service.drafts ? service.drafts : [])
        .filter(d => d && d.name && d.mode !== "edit" && !(service.themeByName && service.themeByName[d.name])).slice(0, 3)

    implicitWidth: Style.space(468)
    implicitHeight: Math.min(page === "editor" && editorLoader.item ? editorLoader.item.implicitHeight
                             : page === "new" && wizardLoader.item ? wizardLoader.item.implicitHeight
                             : page === "screen" && screenLoader.item ? screenLoader.item.implicitHeight
                             : page === "wallpaper" && wallpaperLoader.item ? wallpaperLoader.item.implicitHeight
                             : column.implicitHeight, maxHeight)

    function rank(name) { return name === activeTheme ? 0 : name === dayTheme ? 1 : name === nightTheme ? 2 : 3 }
    function title(name) { return Format.themeName(name) }
    function opBusy(kind) {
        const op = ops[kind]
        return !!op && (op.phase === "launching" || op.phase === "queued" || op.phase === "applying")
    }
    function canChange(kind) { return hasService && service.canChange(kind) }
    // What a change still on its way asks for, and whether it waits behind
    // another run (it is queued, not yet applying).
    function opWants(kind) { const op = ops[kind]; return !!op && op.desired === true }
    function opQueued(kind) { const op = ops[kind]; return !!op && (op.phase === "launching" || op.phase === "queued") && busy !== null }
    // Why a switch waits, for its tooltip.
    readonly property string waitReason: busy ? (Format.kindOf(busy.op, busy.target) === "theme" ? "Waits for the theme to finish applying."
                                                 : busy.op === "detect" ? "Waits for hardware detection." : "Waits for the running change.")
        : daemonOffline ? "Waits for the Lian Li daemon." : "Waits for the running change."

    // Escape: a popup first (it closes itself), then the page, then close.
    function back() {
        if (anyPopup()) { closePopups(); return }
        closeRequested()
    }
    function reset() {
        closePopups()
        confirm = null; keyNav = false; cursor = 0; scroller.contentY = 0
        savedOffer = null; renameTo = ""
    }
    function anyPopup() { return moreMenu.opened || cardMenu.opened || ask.opened }
    // How far down (window coordinates) an open popup reaches: the render
    // harness sizes its window to hold it.
    function popupBottom() {
        let b = 0
        for (const p of [moreMenu, cardMenu, ask])
            if (p.opened && p.contentItem) b = Math.max(b, p.contentItem.mapToItem(null, 0, p.contentItem.height).y + p.bottomPadding)
        const inner = page === "editor" ? editorLoader.item : page === "new" ? wizardLoader.item : page === "screen" ? screenLoader.item
            : page === "wallpaper" ? wallpaperLoader.item : null
        if (inner && typeof inner.popupBottom === "function") b = Math.max(b, inner.popupBottom())
        return b
    }
    function closePopups() { moreMenu.close(); cardMenu.close(); ask.close() }

    // ---- the theme editor and the New theme page (contract v1.2) -------------
    readonly property bool editorAvailable: hasService && service.editorAvailable === true
    readonly property string editBlockAll: editorAvailable ? String(service.canEdit("") || "") : "engine"
    function editBlockOf(t) {
        if (!editorAvailable || !t) return "engine"
        const b = String(service.canEdit(t.name) || "")
        return b === "auto" ? "" : b
    }
    readonly property var activeEntry: hasService && service.themeByName && activeTheme ? service.themeByName[activeTheme] || null : null
    // ---- the desktop wallpaper (contract v1.4) ------------------------------
    // Only while the desktop takes the settings (status --json `desktop`):
    // an engine without it hides the row and the card menu's Wallpaper….
    readonly property bool desktopShown: hasService && service.desktopAvailable === true
    readonly property var desktopNow: hasService && service.desktopCurrent ? service.desktopCurrent : null
    readonly property string desktopHome: hasService ? String(service.desktopHome || "") : ""
    readonly property bool desktopNone: !!desktopNow && desktopNow.has_animated === false
    readonly property string desktopText: Format.desktopSummary(desktopNow)
    readonly property bool canEditActive: !!activeEntry && editBlockOf(activeEntry) === ""
    function themeNames() {
        const n = themes.map(t => t.name)
        for (const d of (hasService && service.drafts ? service.drafts : [])) if (d && d.name) n.push(d.name)
        return n
    }
    function showEditor() {
        page = "editor"
        closePopups()
        scroller.contentY = 0
        Qt.callLater(() => { if (editorLoader.item) editorLoader.item.forceActiveFocus() })
    }
    // A theme (or a new one never saved) whose draft still waits reopens with
    // one line that says so.
    function openEditor(name) {
        if (!editorAvailable || !name) return
        savedOffer = null
        const t = hasService && service.themeByName ? service.themeByName[name] : null
        const waiting = (t && t.draft && typeof t.draft === "object") || unsavedDrafts.some(d => d.name === name)
        editorUi = waiting ? { resumed: true } : null
        service.editTheme(name)
        showEditor()
    }
    // The New theme page: from scratch, or (Duplicate) straight to naming a copy.
    function startNewTheme(copyFrom) {
        if (!editorAvailable || editBlockAll !== "") return
        closePopups()
        savedOffer = null
        wizardUi = copyFrom ? { step: 2, start: "copy", copyFrom: copyFrom } : null
        page = "new"
        scroller.contentY = 0
        Qt.callLater(() => { if (wizardLoader.item) wizardLoader.item.forceActiveFocus() })
    }
    // The wizard's Create: a draft from a palette or a copy, then the editor
    // with the live preview going out at once.
    function create(slug, fromName, palette) {
        if (fromName) service.duplicateTheme(fromName, slug)
        else service.newTheme(slug, "", palette)
        editorUi = { previewOnOpen: true }
        showEditor()
    }
    function leavePage() {
        if (page === "wallpaper" && hasService) service.closeDesktop()
        page = "main"
        editorUi = null
        wizardUi = null
        screenUi = null
        wallpaperUi = null
        scroller.contentY = 0
        keys.forceActiveFocus()
    }
    // A screen of the theme being edited, from its tile on the case map;
    // back comes to the editor where it was.
    function openScreenPage(role, step) {
        if (!role || !hasService) return
        editorScroll = scroller.contentY
        screenUi = { role: String(role) }
        service.openScreen(String(role))
        page = "screen"
        scroller.contentY = 0
        Qt.callLater(() => {
            if (!screenLoader.item) return
            screenLoader.item.forceActiveFocus()
            if (step === "pick") screenLoader.item.openPick("set")
        })
    }
    // A theme's desktop wallpaper (contract v1.4), from the Wallpaper row
    // (the theme the desktop follows) or a card's menu; back comes to the
    // main page.
    function openWallpaper(name) {
        if (!name || !hasService) return
        closePopups()
        wallpaperUi = { theme: String(name) }
        service.loadDesktop(String(name))
        page = "wallpaper"
        scroller.contentY = 0
        Qt.callLater(() => { if (wallpaperLoader.item) wallpaperLoader.item.forceActiveFocus() })
    }
    function closeScreenPage() {
        if (hasService) service.closeScreen()
        screenUi = null
        page = "editor"
        Qt.callLater(() => {
            scroller.contentY = Math.max(0, Math.min(editorScroll, scroller.contentHeight - scroller.height))
            if (editorLoader.item) editorLoader.item.forceActiveFocus()
        })
    }
    function inUse(name) {
        const t = hasService && service.themeByName ? service.themeByName[name] : null
        if (name === activeTheme) return "your active theme"
        if (name === dayTheme) return "your day theme"
        if (name === nightTheme) return "the night theme"
        if (t && Array.isArray(t.omarchy_slugs) && t.omarchy_slugs.length) return "matched to Omarchy's " + t.omarchy_slugs.join(", ")
        return ""
    }

    // ---- picking --------------------------------------------------------------
    function activate(t) {
        if (!hasService || !t) return
        if (t.name === activeTheme && service.themeState(t.name) === "active")
            askAbout(t, { kind: "reapply", name: t.name })
        else if (isNight && t.name !== nightTheme) askAbout(t, { kind: "night", name: t.name })
        else { closePopups(); savedOffer = null; service.pick(t.name) }
    }
    function cardFor(name) {
        const i = flatThemes.findIndex(t => t.name === name)
        return i < 0 ? null : cardAt(i)
    }
    function cardAt(i) {
        return i < handThemes.length ? handRepeater.itemAt(i) : autoRepeater.itemAt(i - handThemes.length)
    }
    // The card confirms, in a popup under the card.
    function askAbout(t, c) {
        const card = cardFor(c.name) || themesHeader
        showItem(card)
        const n = title(c.name)
        ask.subject = c
        ask.askName = c.kind === "rename"
        ask.nameText = c.kind === "rename" ? (renameTo ? Format.themeName(renameTo) : n) : ""
        ask.current = c.kind === "rename" ? c.name : ""
        ask.names = themeNames()
        ask.cancelText = "Cancel"
        if (c.kind === "reapply") { ask.question = "Apply " + n + " again?"; ask.confirmText = "Apply again"; ask.confirmKind = "primary" }
        else if (c.kind === "night") {
            ask.question = title(nightTheme) + " is on until " + Format.clock(schedule ? schedule.next_boundary : "") + ". Apply " + n + " now?"
            ask.confirmText = "Apply now"; ask.confirmKind = "primary"
        } else if (c.kind === "rename") { ask.question = "Rename " + n; ask.confirmText = "Rename"; ask.confirmKind = "primary" }
        else if (c.kind === "delete") {
            const use = inUse(c.name)
            ask.question = use ? n + " is " + use + ". Pick or match another theme first." : "Delete " + n + "? It moves to the theme trash."
            ask.confirmText = use ? "" : "Delete"
            ask.confirmKind = "danger"
            ask.cancelText = use ? "OK" : "Cancel"
        }
        Qt.callLater(() => ask.openAt(card))
    }
    function answered(c, slug) {
        if (!c) return
        if (c.kind === "reapply" || c.kind === "night") { savedOffer = null; service.pick(c.name) }
        else if (c.kind === "rename" && slug && slug !== c.name) service.renameTheme(c.name, slug)
        else if (c.kind === "delete") service.deleteTheme(c.name)
    }
    function openMenu(t) {
        if (!t) return
        cursor = Math.max(0, flatThemes.indexOf(t))
        const block = editBlockOf(t)
        const auto = /^omarchy-/.test(t.name) || t.auto === true
        cardMenu.subject = t.name
        cardMenu.note = ""
        cardMenu.items = [
            { key: "edit", label: "Edit", glyph: "󰏫", enabled: block === "", tip: block === "" ? "" : Format.editBlockText(block) },
            // Its desktop wallpaper, while the desktop takes the settings (v1.4).
            desktopShown ? { key: "wallpaper", label: "Wallpaper…", glyph: "󰋩" } : null,   // nf-md-image
            { key: "duplicate", label: "Duplicate", glyph: "󰆑", enabled: editBlockAll === "", tip: editBlockAll === "" ? "" : Format.editBlockText(editBlockAll) },
            { key: "rename", label: "Rename…", glyph: "󰑕", enabled: editorAvailable && !auto, tip: auto ? "Themes made from Omarchy keep their name; duplicate it instead." : "" },
            { key: "delete", label: "Delete…", glyph: "󰧧", danger: true, enabled: editorAvailable }
        ].filter(it => it !== null)
        const card = cardFor(t.name)
        showItem(card)
        Qt.callLater(() => cardMenu.openAt(card))
    }
    function menuChosen(name, key) {
        const t = hasService && service.themeByName ? service.themeByName[name] : null
        if (key === "edit") openEditor(name)
        else if (key === "wallpaper") openWallpaper(name)
        else if (key === "duplicate") startNewTheme(name)
        else if (key === "rename") askAbout(t, { kind: "rename", name: name })
        else if (key === "delete") askAbout(t, { kind: "delete", name: name })
    }
    function moveCursor(dx, dy) {
        if (flatThemes.length === 0) return
        if (!keyNav) { keyNav = true; showItem(cardAt(cursor)); return }
        const step = dy !== 0 ? dy * gridColumns : dx
        cursor = Math.max(0, Math.min(flatThemes.length - 1, cursor + step))
        showItem(cardAt(cursor))
    }
    function activateCursor() { if (keyNav && flatThemes[cursor]) activate(flatThemes[cursor]) }
    function showItem(item) {
        if (!item || !item.mapToItem) return
        const y = item.mapToItem(scroller.contentItem, 0, 0).y
        if (y < scroller.contentY) scroller.contentY = y
        else if (y + item.height > scroller.contentY + scroller.height) scroller.contentY = Math.min(y + item.height - scroller.height, Math.max(0, scroller.contentHeight - scroller.height))
    }

    // ---- words --------------------------------------------------------------------
    function lastRunText(r) {
        if (!r || !r.op) return ""
        const kind = Format.kindOf(r.op, r.target)
        const missed = r.missed_devices && r.missed_devices.length > 0
        const failed = r.rc !== 0
        let what = kind === "theme" ? title(r.theme) + (failed ? " failed" : r.skipped ? " skipped" : missed ? " partly applied" : " applied")
            : r.op === "on" || r.op === "off" ? Format.powerWhat(r.target).replace(/^./, c => c.toUpperCase()) + " " + r.op + (failed ? " failed" : "")
            : r.op === "clips-next" ? "Next video" + (failed ? " failed" : "")
            : r.op === "schedule-set" ? "Night theme " + (r.target || "") + (failed ? " failed" : "")
            : r.op === "detect" ? (failed ? "Hardware detection failed" : "Hardware detected")
            : Format.opShort(r.op, r.target, r.theme) + (failed ? " failed" : "")
        const took = r.ended && r.started ? r.ended - r.started : null
        return "Last change: " + what + " at " + Format.hhmm(r.ended) + (took !== null && !failed ? " · " + (took < 60 ? took + " s" : Format.mmss(took)) : "")
    }
    readonly property var rotationList: hasService && service.rotation ? service.rotation : []
    readonly property bool clipsPaused: hasService && service.clipsPaused === true
    readonly property var nextClip: {
        let best = null
        for (const r of rotationList) if (!best || Number(r.next_in || 0) < Number(best.next_in || 0)) best = r
        return best
    }
    readonly property string clipsTitle: rotationList.length === 1 ? Format.screenName(rotationList[0].where) + " video" : "Screen videos"
    readonly property string clipsText: {
        const r = nextClip
        if (!r) return ""
        const pos = ((r.index || 0) + 1) + " of " + (r.count || 0)
        if (!screensOn) return "Screens are off"
        if (r.paused || clipsPaused) return pos + " · paused"
        return pos
    }
    readonly property string clipsCountdown: {
        const r = nextClip
        if (!r || !screensOn || r.paused || clipsPaused) return ""
        const left = Math.max(0, (r.next_in || 0) - Math.max(0, now - (status.ts || now)))
        return "next in " + Format.mmss(left)
    }
    readonly property string clipsTip: rotationList.map(r => {
        const clip = (hasService && service.nowPlaying && service.nowPlaying[r.serial]) || r.clip || "—"
        return Format.screenName(r.where) + ": " + clip + " (" + ((r.index || 0) + 1) + " of " + (r.count || 0) + ")"
    }).join("\n")
    readonly property string nightText: {
        if (!schedule) return ""
        const range = Format.clock(schedule.night_start) + "–" + Format.clock(schedule.night_end)
        let s = title(schedule.night_theme) + " · " + range
        if (schedule.enabled && schedule.override)
            s += schedule.period === "night" ? " · skipped tonight" : " · " + title(activeTheme) + " until " + Format.clock(schedule.next_boundary)
        return s
    }
    readonly property string pairingText: {
        const o = omarchy
        if (!o || !o.current) return ""
        if (o.generating) return "Making a theme from Omarchy's " + o.current + "…"
        if (!o.maps_to || o.mapping === "none") return "Omarchy's " + o.current + " has no case theme."
        return "Omarchy's " + o.current + " goes with " + title(o.maps_to) + (o.mapping === "default-auto" ? " (made from it)" : "") + "."
    }
    readonly property string nightTip: {
        const t = []
        if (pairingText) t.push(pairingText)
        if (ops.schedule && ops.schedule.desired === true && schedule && !schedule.enabled)
            t.push("Takes effect at " + (schedule.period === "night" ? schedule.night_end : schedule.night_start) + ".")
        if (!canChange("schedule")) t.push(waitReason)
        return t.join("\n")
    }

    // The Service's notice, as actions on buttons.
    readonly property var noticeActions: {
        const a = hasService && service.noticeActions ? service.noticeActions : []
        const out = []
        const add = (k, label, kind, tip, enabled) => { if (a.indexOf(k) >= 0) out.push({ key: k, label: label, kind: kind || "secondary", tip: tip || "", enabled: enabled !== false }) }
        add("detect", "Detect hardware", "primary", "Find the fans, screens, RGB and sensors in this PC. The lights keep their look.", canChange("detect"))
        add("edit", "Edit", "primary", "Back to the theme editor")
        add("retry", "Retry")
        add("copy", "Copy command")
        add("endpreview", "End preview", "secondary", "The case goes back to the saved look; your edits stay in a draft")
        add("log", "Show log")
        return out
    }
    readonly property bool noticeShown: hasService ? !!service.notice && !(savedOffer && service.noticeKey === "saved") : true
    function noticeAction(k) {
        if (k === "detect") service.detect()
        else if (k === "edit") openEditor(service.preview ? service.preview.theme : "")
        else if (k === "retry") service.retryLast()
        else if (k === "copy") service.copyInstallCommand()
        else if (k === "endpreview") service.endPreview("closed")
        else if (k === "log") service.showLog()
    }
    readonly property string devicesText: {
        const m = hasService && service.missingDevices ? service.missingDevices : []
        if (!m.length) return ""
        const names = m.map(d => d.label)
        return (names.length === 1 ? names[0] + " is" : names.slice(0, -1).join(", ") + " and " + names[names.length - 1] + " are")
            + " out of range and keep their last look."
    }
    readonly property string usbText: {
        const u = hasService && service.screensOnUsb ? service.screensOnUsb : null
        if (!u || !(u.want > 0) || u.have >= u.want || daemonOffline || !hasLianli) return ""
        return u.have + " of " + u.want + " screens answer. Restarting the Lian Li daemon wakes the rest."
    }

    Keys.onEscapePressed: back()
    // The menu key (or Shift+F10) opens the card menu under the cursor; the
    // PanelKeyCatcher passes it on.
    Keys.onPressed: function(event) {
        if (page !== "main") return
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            if (keyNav && flatThemes[cursor]) openMenu(flatThemes[cursor])
            event.accepted = true
        }
    }
    function textKey(t) {
        if (!editorAvailable || page !== "main") return
        if (t === "e") {
            const card = keyNav ? flatThemes[cursor] : activeEntry
            if (card && editBlockOf(card) === "") openEditor(card.name)
        } else if (t === "n") startNewTheme("")
    }
    // The render harness's keyboard walk (ui.keys: [{key, text, modifiers}]):
    // the same moves the PanelKeyCatcher and the menu key make.
    function replayKeys(list) {
        for (const k of (list || [])) {
            const key = Number(k.key || 0), t = String(k.text || "")
            if (key === Qt.Key_Down || t === "j") moveCursor(0, 1)
            else if (key === Qt.Key_Up || t === "k") moveCursor(0, -1)
            else if (key === Qt.Key_Right || t === "l") moveCursor(1, 0)
            else if (key === Qt.Key_Left || t === "h") moveCursor(-1, 0)
            else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) activateCursor()
            else if (key === Qt.Key_Escape) back()
            else if (key === Qt.Key_Menu) { if (keyNav && flatThemes[cursor]) openMenu(flatThemes[cursor]) }
            else if (t) textKey(t)
        }
    }
    onShownChanged: {
        if (!shown) reset()
        else if (page === "editor") Qt.callLater(() => { if (editorLoader.item) editorLoader.item.forceActiveFocus() })
        else if (page === "new") Qt.callLater(() => { if (wizardLoader.item) wizardLoader.item.forceActiveFocus() })
        else if (page === "screen") Qt.callLater(() => { if (screenLoader.item) screenLoader.item.forceActiveFocus() })
        else if (page === "wallpaper") Qt.callLater(() => { if (wallpaperLoader.item) wallpaperLoader.item.forceActiveFocus() })
    }
    // The Service closed the editor (a save, another panel): back to the list,
    // and after a save of a theme that isn't on, offer to use it.
    Connections {
        target: root.hasService ? root.service : null
        ignoreUnknownSignals: true
        function onEditorStateChanged() {
            const st = String(root.service.editorState || "closed")
            if (st === "closed" && root.lastEditorState === "saving" && root.pendingSave) {
                const s = root.pendingSave
                if (!s.apply && s.name !== root.activeTheme) root.savedOffer = { name: s.name }
            }
            if (st !== "saving") root.pendingSave = st === "closed" || st === "idle" ? null : root.pendingSave
            root.lastEditorState = st
            if (st === "closed" && (root.page === "editor" || root.page === "screen")) root.leavePage()
        }
    }
    Connections {
        target: root.Window.window
        function onActiveFocusItemChanged() { if (root.Window.window && root.page === "main") root.showItem(root.Window.window.activeFocusItem) }
    }
    Timer {
        interval: 1000
        repeat: true
        running: root.shown && root.fixedNow === 0
        onTriggered: root.tickNow = Date.now() / 1000
    }
    // Read-only: the desktop's colours for "Match my desktop".
    FileView {
        path: Commons.Color.currentThemePath + "/colors.toml"
        printErrors: false
        watchChanges: false
        onLoaded: root.desktopColorsLive = text()
    }

    Ui.PanelKeyCatcher {
        id: keys
        anchors.fill: parent
        onCloseRequested: root.back()
        onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
        onActivateRequested: root.activateCursor()
        // Tab moves to the neighbouring bar panel; Panel.qml calls switchPanel.
        onTabRequested: function(direction) { root.tabRequested(direction) }
        // e edits the cursor card (or the active theme), n starts a new theme.
        onTextKey: function(t) { root.textKey(t) }
        // The other pages handle their own keys.
        blocked: root.page !== "main" || root.anyPopup()

        // The scroller reaches `overdraw` past the content edges, so what
        // draws outside them isn't cut off: a row's hover fill bleeds 8 px,
        // the ring around a card, a picture or the picker 3-4 px.
        Flickable {
            id: scroller
            anchors.fill: parent
            anchors.leftMargin: -root.overdraw
            anchors.rightMargin: -root.overdraw
            contentHeight: root.page === "editor" && editorLoader.item ? editorLoader.item.implicitHeight
                : root.page === "new" && wizardLoader.item ? wizardLoader.item.implicitHeight
                : root.page === "screen" && screenLoader.item ? screenLoader.item.implicitHeight
                : root.page === "wallpaper" && wallpaperLoader.item ? wallpaperLoader.item.implicitHeight : column.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: scroller.contentHeight > scroller.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff }

            Loader {
                id: editorLoader
                x: root.overdraw
                width: scroller.width - root.overdraw * 2
                active: root.page === "editor" || root.page === "screen"
                visible: root.page === "editor"
                sourceComponent: ThemeEditor {
                    width: editorLoader.width
                    service: root.service
                    initial: root.editorUi
                    onBackRequested: root.leavePage()
                    onShowRequested: function(item) { root.showItem(item) }
                    onSaveRequested: function(name, apply) { root.pendingSave = { name: name, apply: apply } }
                    onCopyRequested: function(name, keep) { root.service.closeEditor(keep); root.leavePage(); root.startNewTheme(name) }
                    onScreenRequested: function(role, step) { root.openScreenPage(role, step) }
                }
            }
            Loader {
                id: screenLoader
                x: root.overdraw
                width: scroller.width - root.overdraw * 2
                active: root.page === "screen" && !!root.screenUi
                visible: active
                sourceComponent: ScreenPage {
                    width: screenLoader.width
                    service: root.service
                    role: root.screenUi ? String(root.screenUi.role || "") : ""
                    initial: root.screenUi
                    onBackRequested: root.closeScreenPage()
                    onShowRequested: function(item) { if (item) root.showItem(item); else scroller.contentY = 0 }
                }
            }
            Loader {
                id: wallpaperLoader
                x: root.overdraw
                width: scroller.width - root.overdraw * 2
                active: root.page === "wallpaper" && !!root.wallpaperUi
                visible: active
                sourceComponent: WallpaperPage {
                    width: wallpaperLoader.width
                    service: root.service
                    theme: root.wallpaperUi ? String(root.wallpaperUi.theme || "") : ""
                    initial: root.wallpaperUi
                    onBackRequested: root.leavePage()
                    onShowRequested: function(item) { if (item) root.showItem(item); else scroller.contentY = 0 }
                }
            }
            Loader {
                id: wizardLoader
                x: root.overdraw
                width: scroller.width - root.overdraw * 2
                active: root.page === "new"
                visible: active
                sourceComponent: NewTheme {
                    width: wizardLoader.width
                    service: root.service
                    initial: root.wizardUi
                    themes: root.flatThemes
                    activeTheme: root.activeTheme
                    names: root.themeNames()
                    desktopName: root.desktopName
                    desktopColors: root.desktopColors
                    onBackRequested: root.leavePage()
                    onCreateRequested: function(slug, fromName, palette) { root.create(slug, fromName, palette) }
                    onShowRequested: function(item) { root.showItem(item) }
                }
            }

            ColumnLayout {
                id: column
                x: root.overdraw
                width: scroller.width - root.overdraw * 2
                visible: root.page === "main"
                spacing: 0

                // 1. Header
                RowLayout {
                    id: header
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Label {
                        id: brand
                        text: "Lumenaire"
                        font.pixelSize: Style.font.heading
                        font.bold: true
                        wrapMode: Text.NoWrap
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Label {
                        id: activeName
                        text: root.activeTheme ? root.title(root.activeTheme) : ""
                        visible: text !== ""
                        tone: "accent"
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        // As wide as the name, until the buttons need the room.
                        Layout.preferredWidth: Math.min(implicitWidth, Math.max(Style.space(40), header.width - brand.implicitWidth
                            - (editActive.visible ? editActive.implicitWidth : 0) - moreButton.width - closeButton.width - Style.space(8) * 5))
                        Layout.alignment: Qt.AlignVCenter
                        Layout.topMargin: Style.space(2)
                        MouseArea { id: nameMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        Ui.PanelToolTip {
                            visible: nameMouse.containsMouse
                            text: "The theme on your case now" + (activeName.truncated ? ": " + activeName.text : "")
                        }
                    }
                    Action {
                        id: editActive
                        visible: root.canEditActive && root.engineUsable
                        text: "Edit"
                        tooltipText: "Edit " + root.title(root.activeTheme)
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.openEditor(root.activeTheme)
                    }
                    Item { Layout.fillWidth: true }
                    IconButton {
                        id: moreButton
                        glyph: "󰇘"   // nf-md-dots_horizontal
                        tooltipText: "More"
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.openMore()
                    }
                    IconButton {
                        id: closeButton
                        glyph: "󰅖"   // nf-md-close
                        tooltipText: "Close"
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.closeRequested()
                    }
                }

                // 2. Notices
                ColumnLayout {
                    id: notices
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(12)
                    visible: root.noticeShown || !!root.savedOffer || root.devicesText !== "" || root.usbText !== ""
                    spacing: Style.space(8)
                    Notice {
                        id: serviceNotice
                        Layout.fillWidth: true
                        visible: root.noticeShown
                        text: root.hasService ? String(root.service.notice || "") : "Starting Lumenaire…"
                        level: root.hasService && root.service.noticeLevel === "urgent" ? "urgent" : "info"
                        actions: root.noticeActions
                        dismissable: root.hasService && (root.service.noticeActions || []).indexOf("dismiss") >= 0
                        onAction: function(k) { root.noticeAction(k) }
                        onDismissed: root.service.dismissNotice()
                    }
                    Notice {
                        id: offer
                        Layout.fillWidth: true
                        visible: !!root.savedOffer
                        glyph: "󰄬"   // nf-md-check
                        text: root.savedOffer ? "Saved " + root.title(root.savedOffer.name) + ". Use it now?" : ""
                        actions: [{ key: "use", label: "Use", kind: "primary" }]
                        dismissable: true
                        onAction: function(k) {
                            const t = root.hasService && root.service.themeByName ? root.service.themeByName[root.savedOffer.name] : null
                            root.savedOffer = null
                            if (t) root.activate(t)
                        }
                        onDismissed: root.savedOffer = null
                    }
                    Notice {
                        id: devicesNote
                        Layout.fillWidth: true
                        visible: text !== ""
                        glyph: "󰖪"   // nf-md-wifi_off
                        text: root.devicesText
                    }
                    Notice {
                        id: usbNote
                        Layout.fillWidth: true
                        visible: text !== ""
                        glyph: "󰍹"   // nf-md-monitor
                        text: root.usbText
                    }
                }

                // 3. Live readings: one row of equal cells.
                RowLayout {
                    id: readings
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(16)
                    visible: readingModel.length > 0
                    spacing: Style.space(8)
                    readonly property var sv: root.service
                    readonly property var readingModel: {
                        const sv = root.service
                        const out = []
                        if (!sv) return out
                        const warn = Number(root.settings.coolantWarn) || 40
                        const num = n => n === null || n === undefined ? "—" : root.narrow ? String(Math.round(Number(n))) : Format.group(n)
                        if (root.hasPump) {
                            const c = sv.coolantC, age = sv.coolantAgeS
                            const stale = c !== null && c !== undefined && (sv.coolantStale === true || Number(age) > 15)
                            const ok = c !== null && c !== undefined && !stale
                            out.push({ caption: "Coolant", value: ok ? Format.fixed(c, 1) : "—", unit: "°C",
                                       level: !ok ? "missing" : c >= warn ? "hot" : "fresh",
                                       tip: stale ? "No fresh reading (the last was " + Format.tempC(c, 1) + ", " + Format.ago(age) + ")"
                                           : !ok ? "No coolant reading" : c >= warn ? "At or over your " + warn + " °C warning" : "Coolant temperature" })
                            const rpm = sv.pumpRpm
                            out.push({ caption: "Pump", value: num(rpm), unit: "RPM", level: rpm === null || rpm === undefined ? "missing" : "fresh",
                                       tip: rpm === null || rpm === undefined ? "No pump reading" : "Pump speed " + Format.rpm(rpm) })
                        }
                        if (root.hasLianli) {
                            const fans = sv.fans || []
                            const avg = Format.fanAverage(fans)
                            out.push({ caption: "Fans", value: num(avg), unit: "RPM", level: avg === null ? "missing" : "fresh",
                                       tip: fans.length ? "Average of every fan\n" + fans.map(f => f.label + ": " + (f.rpms || []).map(n => Format.group(n)).join(" · ") + " RPM").join("\n")
                                                        : "No fan reading" })
                        }
                        if (root.hasCpu) {
                            const c = sv.cpuC
                            const hot = !!sv.alert && Format.overAlert(c, sv.alert.cpu)
                            out.push({ caption: "CPU", value: Format.fixed(c, 0), unit: "°C", level: c === null || c === undefined ? "missing" : hot ? "hot" : "fresh",
                                       tip: c === null || c === undefined ? "No CPU reading" : "CPU temperature" + (hot ? ", over its " + Format.tempC(sv.alert.cpu.threshold, 0) + " heat alert" : "") })
                        }
                        if (root.settings.showGpu !== false && root.hasGpu) {
                            const c = sv.gpuC
                            const hot = !!sv.alert && Format.overAlert(c, sv.alert.gpu)
                            const bits = ["GPU " + Format.tempC(c, 0)]
                            if (sv.gpuUtil !== null && sv.gpuUtil !== undefined) bits.push(Math.round(sv.gpuUtil) + " % load")
                            if (sv.gpuW !== null && sv.gpuW !== undefined) bits.push(Format.fixed(sv.gpuW, 0) + " W")
                            out.push({ caption: "GPU", value: Format.fixed(c, 0), unit: "°C", level: c === null || c === undefined ? "missing" : hot ? "hot" : "fresh",
                                       tip: c === null || c === undefined ? "No GPU reading" : bits.join(" · ") + (hot ? "\nOver its " + Format.tempC(sv.alert.gpu.threshold, 0) + " heat alert" : "") })
                        }
                        return out
                    }
                    readonly property real cell: Math.floor((column.width - spacing * Math.max(0, readingModel.length - 1)) / Math.max(1, readingModel.length))
                    Repeater {
                        model: readings.readingModel
                        Metric {
                            required property var modelData
                            Layout.preferredWidth: readings.cell
                            Layout.alignment: Qt.AlignTop
                            caption: modelData.caption
                            value: modelData.value
                            unit: modelData.unit
                            level: modelData.level
                            tooltipText: modelData.tip
                        }
                    }
                }

                // 4. Power: two tiles side by side.
                RowLayout {
                    id: power
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(16)
                    visible: root.engineUsable && (root.powerDetail !== null || root.hasScreens)
                    spacing: Style.space(8)
                    PowerTile {
                        id: lightsTile
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        visible: root.powerDetail !== null
                        glyph: root.lightsOn ? "󰌵" : "󰌶"   // nf-md-lightbulb / lightbulb_outline
                        title: "Lights"
                        checked: root.lightsOn
                        busy: root.opBusy("lights")
                        allowed: root.canChange("lights")
                        status: !allowed ? "Waiting…" : busy ? (root.opWants("lights") ? "On…" : "Off…") : checked ? "On" : "Off"
                        detail: !allowed ? root.waitReason : busy ? (root.opQueued("lights") ? (root.opWants("lights") ? "Turns the lights on after the running change." : "Turns the lights off after the running change.")
                                                               : root.opWants("lights") ? "Turning the lights on…" : "Turning the lights off…")
                            : String(root.powerDetail || "") + (!root.lightsOn && root.hasLianli ? "\nThe heat warning is off while the lights are dark." : "")
                        onToggled: root.service.setLights(!root.lightsOn)
                    }
                    PowerTile {
                        id: screensTile
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        visible: root.hasScreens
                        glyph: "󰍹"   // nf-md-monitor
                        title: "Screens"
                        checked: root.screensOn
                        busy: root.opBusy("screens")
                        allowed: root.canChange("screens")
                        status: !allowed ? "Waiting…" : busy ? (root.opWants("screens") ? "On…" : "Off…") : checked ? "On" : "Off"
                        detail: !allowed ? root.waitReason : busy ? (root.opQueued("screens") ? (root.opWants("screens") ? "Turns the screens on after the running change." : "Turns the screens off after the running change.")
                                                               : root.opWants("screens") ? "Turning the screens on…" : "Turning the screens off…")
                            : "The " + Format.lcds(root.screensWant) + " in the case"
                        onToggled: root.service.setScreens(!root.screensOn)
                    }
                }

                // 5. Pump video, under the tiles: every quick control shows
                // without scrolling past the themes.
                RowLayout {
                    id: clips
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(16)
                    visible: root.engineUsable && root.rotationList.length > 0 && root.hasScreens
                    spacing: Style.space(8)
                    Label {
                        text: root.clipsTitle
                        wrapMode: Text.NoWrap
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Label {
                        text: root.clipsText
                        tone: root.screensOn && !root.clipsPaused ? "text" : "muted"
                        wrapMode: Text.NoWrap
                        Layout.alignment: Qt.AlignVCenter
                        Layout.leftMargin: Style.space(4)
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: root.clipsCountdown
                        tone: "muted"
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        MouseArea { id: clipsMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        Ui.PanelToolTip { visible: clipsMouse.containsMouse && root.clipsTip !== ""; text: root.clipsTip }
                    }
                    IconButton {
                        glyph: "󰒭"   // nf-md-skip_next
                        tooltipText: "Next video"
                        enabled: root.screensOn && !root.clipsPaused && root.canChange("clips") && !root.opBusy("clips")
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.service.skipClip()
                    }
                    IconButton {
                        glyph: root.clipsPaused ? "󰐊" : "󰏤"   // nf-md-play / pause
                        tooltipText: root.clipsPaused ? "Resume" : "Pause"
                        enabled: root.screensOn
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root.service.setClipsPaused(!root.clipsPaused)
                    }
                }

                // 6. Night theme, a hairline apart from the pump video.
                Ui.PanelSeparator {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(12)
                    visible: clips.visible && night.visible
                    strength: 0.08
                }
                RowLayout {
                    id: night
                    Layout.fillWidth: true
                    Layout.topMargin: clips.visible ? Style.space(12) : Style.space(16)
                    visible: root.engineUsable && root.schedule !== null
                    spacing: Style.space(8)
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: nightWords.implicitHeight
                        ColumnLayout {
                            id: nightWords
                            width: parent.width
                            spacing: Style.space(2)
                            Label { text: "Night theme"; Layout.fillWidth: true; wrapMode: Text.NoWrap }
                            Label {
                                id: nightLine
                                Layout.fillWidth: true
                                text: root.nightText
                                tone: "muted"
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea { id: nightMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        Ui.PanelToolTip {
                            readonly property string full: [nightLine.truncated ? root.nightText : "", root.nightTip].filter(x => x !== "").join("\n")
                            visible: nightMouse.containsMouse && full !== ""
                            text: full
                        }
                    }
                    Ui.ToggleSwitch {
                        id: nightSwitch
                        readonly property var op: root.ops.schedule
                        checked: op && op.phase !== "failed" && op.phase !== "done" && op.phase !== "partial" ? op.desired === true : (!!root.schedule && root.schedule.enabled === true)
                        busy: root.opBusy("schedule")
                        enabled: root.canChange("schedule")
                        opacity: enabled ? 1 : 0.45
                        Layout.alignment: Qt.AlignVCenter
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: "Night theme" + (checked ? ", on" : ", off")
                        onToggled: root.service.setSchedule(!checked)
                        Ui.PanelToolTip { visible: nightSwitch.containsMouse && root.nightTip !== ""; text: root.nightTip }
                    }
                }

                // 7. Wallpaper: the desktop's animated wallpaper, as the theme
                // the desktop follows (the one paired with the Omarchy theme)
                // has it. The row opens its page (its fill bleeds past the
                // edges, like the editor's rows); the switch plays it or keeps
                // it still.
                Ui.CursorSurface {
                    id: wallpaper
                    readonly property int pad: Style.space(4)
                    Layout.fillWidth: true
                    Layout.topMargin: (night.visible ? Style.space(12) : Style.space(16)) - pad
                    Layout.leftMargin: -root.overdraw
                    Layout.rightMargin: -root.overdraw
                    visible: root.engineUsable && root.desktopShown
                    implicitHeight: wallLine.implicitHeight + pad * 2
                    hasCursor: wallMouse.containsMouse
                    Accessible.role: Accessible.Button
                    Accessible.name: "Wallpaper, " + root.desktopText
                    Accessible.onPressAction: root.openWallpaper(root.desktopHome)
                    MouseArea {
                        id: wallMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openWallpaper(root.desktopHome)
                    }
                    RowLayout {
                        id: wallLine
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: root.overdraw
                        anchors.rightMargin: root.overdraw
                        spacing: Style.space(8)
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Style.space(2)
                            Label { text: "Wallpaper"; Layout.fillWidth: true; wrapMode: Text.NoWrap; Accessible.ignored: true }
                            Label {
                                Layout.fillWidth: true
                                text: root.desktopText
                                visible: text !== ""
                                tone: "muted"
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Accessible.ignored: true
                            }
                        }
                        Item {
                            implicitWidth: wallSwitch.implicitWidth
                            implicitHeight: wallSwitch.implicitHeight
                            Layout.alignment: Qt.AlignVCenter
                            Ui.ToggleSwitch {
                                id: wallSwitch
                                anchors.fill: parent
                                // The theme's setting; dimmed while this wallpaper has no animated version.
                                checked: !!root.desktopNow && (root.desktopNow.settings || {}).animated !== false
                                enabled: !root.desktopNone
                                opacity: enabled ? 1 : 0.45
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: "Animated wallpaper" + (checked ? ", on" : ", off")
                                onToggled: root.service.setDesktop("animated", !checked, root.desktopHome)
                            }
                            // A switch that can't change anything still says why.
                            MouseArea { id: noneMouse; anchors.fill: parent; visible: root.desktopNone; hoverEnabled: true; onClicked: {} }
                            Ui.PanelToolTip {
                                visible: wallSwitch.containsMouse || noneMouse.containsMouse
                                text: root.desktopNone ? "This wallpaper has no animated version"
                                    : root.desktopNow && root.desktopNow.user_clip === true ? "For the theme's own wallpaper; the video you picked keeps playing"
                                    : wallSwitch.checked ? "Keep the wallpaper still" : "Play the animated wallpaper"
                            }
                        }
                    }
                    Ui.PanelToolTip { visible: wallMouse.containsMouse; text: "Wallpaper settings for " + root.title(root.desktopHome) }
                }

                // 8. Themes, last: the gallery is the part that scrolls.
                SectionHeader {
                    id: themesHeader
                    // The wallpaper row's fill pads it by 4.
                    Layout.topMargin: wallpaper.visible ? Style.space(24) - wallpaper.pad : Style.space(24)
                    visible: root.engineError === "" || root.themes.length > 0
                    text: "Themes"
                    Label {
                        visible: root.hasService && root.service.previewsBuilding === true
                        text: "Building previews…"
                        tone: "muted"
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.NoWrap
                    }
                    Action {
                        visible: root.editorAvailable
                        text: "New"
                        iconText: "󰐕"   // nf-md-plus
                        iconSize: Style.font.body
                        enabled: root.editBlockAll === ""
                        tooltipText: enabled ? "Make a new theme" : Format.editBlockText(root.editBlockAll)
                        onClicked: root.startNewTheme("")
                    }
                }
                Label {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(8)
                    visible: text !== ""
                    tone: "muted"
                    text: !root.hasService || (!root.ready && root.engineError === "") ? "Reading your themes…"
                        : root.engineError === "" && root.themes.length === 0 ? "No themes yet." + (root.editorAvailable && root.editBlockAll === "" ? " Make one with New." : "")
                        : ""
                }
                Repeater {
                    model: root.page === "main" ? root.unsavedDrafts : []
                    RowLayout {
                        id: draftRow
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(8)
                        spacing: Style.space(8)
                        Label {
                            text: "󰏫"   // nf-md-pencil
                            tone: "accent"
                            wrapMode: Text.NoWrap
                            Layout.alignment: Qt.AlignVCenter
                        }
                        Label {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: root.title(draftRow.modelData.name) + " isn't saved yet"
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                        Action {
                            text: "Continue"
                            tooltipText: "Carry on editing " + root.title(draftRow.modelData.name)
                            onClicked: root.openEditor(draftRow.modelData.name)
                        }
                    }
                }
                GridLayout {
                    id: handGrid
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(12)
                    visible: root.handThemes.length > 0
                    columns: root.gridColumns
                    columnSpacing: root.gridGap
                    rowSpacing: Style.space(16)
                    // Sized from the column, not the grid itself: a card's height follows
                    // its width, so reading our own width would re-enter the layout.
                    readonly property real cell: Math.floor((column.width - columnSpacing * (columns - 1)) / columns)
                    Repeater {
                        id: handRepeater
                        model: root.handThemes
                        ThemeCard {
                            required property var modelData
                            required property int index
                            Layout.preferredWidth: handGrid.cell
                            Layout.alignment: Qt.AlignTop
                            cardWidth: handGrid.cell
                            theme: modelData
                            themeState: root.hasService ? root.service.themeState(modelData.name) : ""
                            busyElapsed: root.hasService ? root.service.busyElapsed : 0
                            selected: modelData.name === root.activeTheme
                            current: root.keyNav && root.cursor === index
                            editable: root.editBlockOf(modelData) === ""
                            onActivated: { root.cursor = index; root.activate(modelData) }
                            onEditRequested: root.openEditor(modelData.name)
                            onMenuRequested: root.openMenu(modelData)
                        }
                    }
                }
                Label {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(16)
                    visible: root.autoThemes.length > 0
                    text: "From Omarchy"
                    tone: "muted"
                    font.pixelSize: Style.font.bodySmall
                    MouseArea { id: autoMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    Ui.PanelToolTip { visible: autoMouse.containsMouse; text: "Made for you from your Omarchy desktop themes" }
                }
                GridLayout {
                    id: autoGrid
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(8)
                    visible: root.autoThemes.length > 0
                    columns: root.gridColumns
                    columnSpacing: root.gridGap
                    rowSpacing: Style.space(16)
                    readonly property real cell: Math.floor((column.width - columnSpacing * (columns - 1)) / columns)
                    Repeater {
                        id: autoRepeater
                        model: root.autoThemes
                        ThemeCard {
                            required property var modelData
                            required property int index
                            Layout.preferredWidth: autoGrid.cell
                            Layout.alignment: Qt.AlignTop
                            cardWidth: autoGrid.cell
                            theme: modelData
                            themeState: root.hasService ? root.service.themeState(modelData.name) : ""
                            busyElapsed: root.hasService ? root.service.busyElapsed : 0
                            selected: modelData.name === root.activeTheme
                            current: root.keyNav && root.cursor === root.handThemes.length + index
                            editable: root.editBlockOf(modelData) === ""
                            onActivated: { root.cursor = root.handThemes.length + index; root.activate(modelData) }
                            onEditRequested: root.openEditor(modelData.name)
                            onMenuRequested: root.openMenu(modelData)
                        }
                    }
                }
                Item { Layout.preferredHeight: Style.space(4) }
            }
        }
    }

    // ---- popups -------------------------------------------------------------------
    function openMore() {
        const building = hasService && service.previewsBuilding === true
        moreMenu.note = engineUsable && hasService ? lastRunText(service.lastRun) : ""
        moreMenu.items = [
            { key: "refresh", label: "Refresh", glyph: "󰑐", enabled: hasService },
            { key: "previews", label: building ? "Building previews…" : "Rebuild previews", glyph: "󱧾", enabled: engineUsable && !building,
              tip: "Make every theme's preview picture again" },
            { key: "log", label: "Show log", glyph: "󰧭", enabled: hasService }
        ]
        moreMenu.openAt(moreButton)
    }
    MenuPopup {
        id: moreMenu
        onChosen: function(key) {
            if (key === "refresh") root.service.refresh()
            else if (key === "previews") root.service.buildPreviews(true)
            else if (key === "log") root.service.showLog()
        }
        onClosed: if (root.page === "main") keys.forceActiveFocus()
    }
    MenuPopup {
        id: cardMenu
        property string subject: ""
        onChosen: function(key) { root.menuChosen(subject, key) }
        onClosed: if (root.page === "main" && !ask.opened) keys.forceActiveFocus()
    }
    MenuPopup {
        id: ask
        property var subject: null
        onConfirmed: function(slug) { root.answered(subject, slug) }
        onClosed: if (root.page === "main") keys.forceActiveFocus()
    }
}
