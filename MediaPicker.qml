pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// The media picker (DESIGN.md "Picker"), a step of the screen page: three
// places to look, This theme, Library (other themes and the L-Connect
// clips) and My files (Videos and Pictures); a search field; then the files
// as MediaTiles at the screen's shape, best fits first, under their group
// ("Pump clips", "Other themes", "Pictures"), and Show more when there are
// more. The engine lists and ranks them (media list --json) and reads new
// files in the background; nothing here reads a file itself.
//
// Choosing a file that fits prepares it at once and goes back to the
// screen; one that doesn't opens the crop page. Keys: Tab or 1/2/3 switch
// the tabs, / goes to the search, the arrows or h/j/k/l move over the
// files, Enter chooses, Esc leaves the search, then goes back.
ColumnLayout {
    id: root
    required property var page                // ScreenPage
    property var screen: null
    property string tab: "theme"
    property var list: null                   // media list --json (the pages so far)
    property string listState: "idle"
    property string listError: ""
    property int cursor: -1                   // a flat file index; -2 is Show more
    property bool keyNav: false
    readonly property alias searchText: search.text
    signal tabChosen(string tab)
    signal queryEdited(string text)
    signal chosen(var item)
    signal moreRequested()
    spacing: 0

    readonly property var items: list && Array.isArray(list.items) ? list.items : []
    readonly property var groups: list && Array.isArray(list.groups) ? list.groups : []
    readonly property string shape: screen ? String(screen.shape || "square") : "square"
    readonly property real aspect: Format.screenAspect(screen)
    readonly property int columns: Format.mediaColumns(shape, width < Style.space(400))
    readonly property int gap: Style.space(8)
    readonly property int cell: Math.floor((width - gap * (columns - 1)) / Math.max(1, columns))
    readonly property bool indexing: !!list && !!list.indexing && list.indexing.state === "running"
    readonly property var toolsMissing: list && Array.isArray(list.tools_missing) ? list.tools_missing : []
    readonly property bool hasMore: !!list && Number(list.total) > items.length
    // Files in their groups, in the groups' order (one group: no captions).
    readonly property var sections: {
        const out = []
        const seen = {}
        const known = groups.map(g => String(g.id))
        for (const g of groups) {
            const its = []
            items.forEach((it, i) => { if (String(it.group || "") === String(g.id)) { its.push({ item: it, index: i }); seen[i] = true } })
            if (its.length) out.push({ id: String(g.id), label: String(g.label || ""), items: its })
        }
        const rest = []
        items.forEach((it, i) => { if (!seen[i]) rest.push({ item: it, index: i }) })
        if (rest.length) out.push({ id: "", label: out.length ? "Other files" : "", items: rest })
        if (out.length === 1) out[0].label = ""
        return out
    }
    // Where each file sits: [section, row, column], for up and down.
    readonly property var places: {
        const p = []
        sections.forEach((s, si) => s.items.forEach((x, k) => { p[x.index] = { s: si, r: Math.floor(k / columns), c: k % columns } }))
        return p
    }
    readonly property string emptyText: listState === "failed" ? (listError || "This folder can't be read")
        : toolsMissing.length && items.length === 0 ? "Screen editing needs ffmpeg and ImageMagick."
        : items.length > 0 || listState === "loading" && !list ? ""
        : search.text.trim() !== "" ? "Nothing matches"
        : indexing ? "Looking through your files…"
        : "Nothing here yet"

    function inUse(it) {
        const m = screen ? screen.media : null
        if (!m) return false
        return (!!it.rel && it.rel === m.rel) || (!!it.path && it.path === m.abs)
    }
    function focusSearch() { search.forceActiveFocus(); search.selectAll() }
    // The harness (and a tab switch) set the words without a new search.
    function presetQuery(q) { search.text = q }
    function searchFocused() { return search.activeFocus }
    // The keyboard: true when used.
    function moveCursor(dx, dy) {
        keyNav = true
        if (items.length === 0) { cursor = hasMore ? -2 : -1; return }
        if (cursor < 0) { cursor = cursor === -2 && dy < 0 ? items.length - 1 : 0; return }
        if (dx !== 0) { cursor = Math.max(0, Math.min(items.length - 1, cursor + dx)); return }
        const at = places[cursor]
        if (!at) { cursor = 0; return }
        // The file straight above or below, across a group caption too.
        const order = []
        sections.forEach((s, si) => s.items.forEach((x, k) => order.push({ i: x.index, s: si, r: Math.floor(k / columns), c: k % columns })))
        const rows = []
        for (const o of order) { const key = o.s + ":" + o.r; if (!rows.length || rows[rows.length - 1].key !== key) rows.push({ key: key, cells: [] }); rows[rows.length - 1].cells.push(o) }
        const ri = rows.findIndex(r => r.key === at.s + ":" + at.r)
        const next = ri + dy
        if (next >= rows.length) { if (hasMore) cursor = -2; return }
        if (next < 0) return
        const cells = rows[next].cells
        const best = cells.reduce((b, o) => Math.abs(o.c - at.c) < Math.abs(b.c - at.c) ? o : b, cells[0])
        cursor = best.i
    }
    function activateCursor() {
        if (cursor === -2) { root.moreRequested(); return }
        if (cursor >= 0 && items[cursor]) root.chosen(items[cursor])
    }

    Segmented {
        id: tabs
        options: [{ value: "theme", label: "This theme", tooltip: "Media already in this theme" },
                  { value: "library", label: "Library", tooltip: "Your other themes and the L-Connect clips" },
                  { value: "files", label: "My files", tooltip: "Your Videos and Pictures folders" }]
        value: root.tab
        fontSize: Style.font.body
        onChanged: function(v) { root.tabChosen(v) }
    }
    Ui.TextField {
        id: search
        Layout.fillWidth: true
        Layout.topMargin: Style.space(12)
        placeholderText: "Search"
        maximumLength: 80
        inputMethodHints: Qt.ImhNoPredictiveText
        Accessible.name: "Search media"
        onTextEdited: root.queryEdited(text)
        Keys.onDownPressed: { root.page.forceActiveFocus(); root.moveCursor(0, 1) }
        onAccepted: { root.page.forceActiveFocus(); if (root.items.length) { root.keyNav = true; root.cursor = 0 } }
    }
    Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        visible: text !== ""
        text: root.indexing && root.items.length > 0
            ? "Looking through your files… " + Number(root.list.indexing.done || 0) + " of " + Number(root.list.indexing.of || 0) : ""
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }

    Repeater {
        model: root.sections
        ColumnLayout {
            id: section
            required property var modelData
            required property int index
            Layout.fillWidth: true
            Layout.topMargin: Style.space(index === 0 ? 16 : 24)
            spacing: Style.space(8)
            Label {
                Layout.fillWidth: true
                visible: section.modelData.label !== ""
                text: section.modelData.label
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
            GridLayout {
                Layout.fillWidth: true
                columns: root.columns
                columnSpacing: root.gap
                rowSpacing: Style.space(12)
                Repeater {
                    model: section.modelData.items
                    MediaTile {
                        id: tile
                        required property var modelData
                        Layout.preferredWidth: root.cell
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: root.cell
                        cellWidth: root.cell
                        item: modelData.item
                        aspect: root.aspect
                        round: root.shape === "round"
                        screenName: root.screen ? Format.screenShort(root.screen) : ""
                        current: root.keyNav && root.cursor === modelData.index
                        inUse: root.inUse(modelData.item)
                        onChosen: { root.cursor = modelData.index; root.chosen(modelData.item) }
                        Component.onCompleted: root.page.register("media:" + modelData.index, tile)
                    }
                }
            }
        }
    }
    Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        visible: root.emptyText !== ""
        text: root.emptyText
        tone: "muted"
    }
    Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        visible: !!root.list && root.list.truncated === true && !root.hasMore
        text: "Only the first 5 000 files are listed. Search to find others."
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
    }
    Action {
        id: moreAction
        Layout.topMargin: Style.space(16)
        visible: root.hasMore
        text: root.listState === "loading" ? "Loading…" : "Show more"
        enabled: root.listState !== "loading"
        tooltipText: root.list ? root.items.length + " of " + Number(root.list.total) + " shown" : ""
        hasCursor: root.keyNav && root.cursor === -2
        onClicked: root.moreRequested()
        Component.onCompleted: root.page.register("media:more", moreAction)
    }
}
