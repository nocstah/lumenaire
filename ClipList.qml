pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// The pump's clips (DESIGN.md "Screen page"): one row per clip in the order
// they take turns, each its number, its picture and its length, with ↑ ↓ ✕
// on hover or the keyboard cursor. A clip being prepared waits in the list
// where it will land ("Preparing… 42 %", Cancel). Rows move by dragging, by
// ↑ ↓, or from the keyboard (Enter picks a row up, j/k carry it, Enter puts
// it down; Shift+J/K or Alt+↑/↓ move it at once; x or Delete removes it).
// The order shown changes at once; the engine's view confirms it.
ColumnLayout {
    id: root
    required property var page                // ScreenPage: keys, register, service calls
    property var items: []                    // clips.items: [{i, rel, thumb, duration, from}]
    property var job: null                    // a clip-add job still running
    property real aspect: 2288 / 1080
    property var dragState: null              // {from, to} (the harness can pin one)
    spacing: Style.space(2)

    // The order as the user last left it, until the view catches up.
    property var localOrder: null
    readonly property var viewSig: items.map(it => String(it.rel || "")).join("|")
    onViewSigChanged: localOrder = null
    readonly property var shown: {
        const base = items.map((it, k) => ({ item: it, index: k }))
        const order = localOrder && localOrder.length === base.length ? localOrder.map(k => base[k]) : base
        const rows = order.map((r, k) => ({ kind: "clip", item: r.item, index: k, from: r.index }))
        if (Format.jobRunning(job)) {
            const at = job.at !== null && job.at !== undefined && isFinite(Number(job.at)) ? Math.max(0, Math.min(rows.length, Number(job.at))) : rows.length
            rows.splice(at, 0, { kind: "job", item: null, index: at, from: -1 })
        }
        return rows
    }
    readonly property int count: items.length
    readonly property int thumbW: Math.round(Style.space(width < Style.space(400) ? 64 : 80))
    readonly property int thumbH: Math.round(thumbW / aspect)
    readonly property int pitch: Math.max(Style.space(36), thumbH + Style.space(8)) + spacing

    function move(from, to) {
        if (from === to || from < 0 || to < 0 || from >= count || to >= count) return
        const order = localOrder && localOrder.length === count ? localOrder.slice() : items.map((it, k) => k)
        const [x] = order.splice(from, 1)
        order.splice(to, 0, x)
        localOrder = order
        page.moveClip(from, to)
    }

    Repeater {
        model: root.shown
        Ui.CursorSurface {
            id: row
            required property var modelData
            readonly property bool isJob: modelData.kind === "job"
            readonly property int n: modelData.index
            readonly property string key: isJob ? "job" : "clip:" + n
            readonly property bool cur: root.page.keyNav && root.page.cursorKey === key
            readonly property bool grabbed: !isJob && root.page.grabbed === n
            readonly property bool dragging: !!root.dragState && root.dragState.from === n
            readonly property bool hot: rowMouse.containsMouse || cur || grabbed || tools.over
            Layout.fillWidth: true
            Layout.leftMargin: -Style.space(8)
            Layout.rightMargin: -Style.space(8)
            implicitHeight: Math.max(Style.space(36), root.thumbH + Style.space(8))
            hasCursor: hot && !isJob
            current: grabbed || dragging
            // Lifted while dragged: opaque, so the row under it doesn't show through.
            color: dragging ? Qt.tint(Color.background, Style.hoverFillFor(Color.popups.text, Color.accent))
                : hasCursor ? fill : current ? currentFill : "transparent"
            z: dragging ? 2 : 0
            transform: Translate { y: row.dragging && root.dragState.dy !== undefined ? root.dragState.dy : 0 }
            Accessible.role: Accessible.ListItem
            Accessible.name: isJob ? Format.jobText(root.job) : "Clip " + (n + 1) + " of " + root.count
                + (modelData.item && modelData.item.duration ? ", " + Math.round(Number(modelData.item.duration)) + " seconds" : "")
            Component.onCompleted: root.page.register(key, row)

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(12)
                Label {
                    text: String(row.n + 1)
                    tone: "muted"
                    font.pixelSize: Style.font.bodySmall
                    horizontalAlignment: Text.AlignRight
                    wrapMode: Text.NoWrap
                    Layout.preferredWidth: Style.space(12)
                    Layout.alignment: Qt.AlignVCenter
                    Accessible.ignored: true
                }
                MediaThumb {
                    Layout.preferredWidth: root.thumbW
                    Layout.preferredHeight: root.thumbH
                    Layout.alignment: Qt.AlignVCenter
                    source: row.isJob ? root.page.jobThumb(root.job) : String(row.modelData.item.thumb || "")
                    thumbState: row.isJob ? "" : String(row.modelData.item.thumb_state || "")
                    glyph: Format.screenGlyph("pump")
                    dim: row.isJob ? 0.6 : 0
                }
                Label {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    readonly property bool gone: !row.isJob && row.modelData.item.where === "missing"
                    text: row.isJob ? Format.jobText(root.job) : gone ? "Its file is missing" : Format.mediaLine({ kind: "video", duration: row.modelData.item.duration })
                    tone: row.isJob ? "muted" : gone ? "urgent" : "text"
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    Accessible.ignored: true
                }
                Row {
                    id: tools
                    property bool over: up.hot || down.hot || del.hot
                    visible: !row.isJob && (row.hot || root.count <= 1)
                    spacing: Style.space(2)
                    Layout.alignment: Qt.AlignVCenter
                    IconButton {
                        id: up
                        visible: root.count > 1
                        glyph: "󰁝"   // nf-md-arrow_up
                        tooltipText: "Move up"
                        enabled: row.n > 0
                        onClicked: root.move(row.n, row.n - 1)
                    }
                    IconButton {
                        id: down
                        visible: root.count > 1
                        glyph: "󰁅"   // nf-md-arrow_down
                        tooltipText: "Move down"
                        enabled: row.n < root.count - 1
                        onClicked: root.move(row.n, row.n + 1)
                    }
                    IconButton {
                        id: del
                        glyph: "󰅖"   // nf-md-close
                        tooltipText: root.count > 1 ? "Remove this clip" : "Remove the video"
                        onClicked: root.page.removeClip(row.n)
                    }
                }
                Action {
                    id: cancelJob
                    visible: row.isJob
                    text: "Cancel"
                    hasCursor: root.page.keyNav && root.page.cursorKey === "job"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.page.cancelJob()
                }
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                // Under the buttons: they keep their clicks.
                z: -1
                enabled: !row.isJob
                cursorShape: pressed && root.dragState ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property real startY: 0
                onPressed: function(m) { startY = m.y; root.page.cursorKey = row.key }
                onPositionChanged: function(m) {
                    if (!pressed) return
                    const dy = m.y - startY
                    if (!root.dragState && Math.abs(dy) < Style.space(6)) return
                    const to = Math.max(0, Math.min(root.count - 1, row.n + Math.round(dy / root.pitch)))
                    root.dragState = { from: row.n, to: to, dy: dy }
                }
                onReleased: {
                    const d = root.dragState
                    root.dragState = null
                    if (d && d.from !== d.to) root.move(d.from, d.to)
                }
                onCanceled: root.dragState = null
            }
            Ui.PanelToolTip {
                visible: rowMouse.containsMouse && !root.dragState
                text: row.isJob ? "Being prepared for the pump" : [String(row.modelData.item.title || ""), row.modelData.item.from === "folder" ? "From the theme's clip folder" : ""].filter(x => x).join("\n")
            }
            // Where a dragged row lands.
            Rectangle {
                visible: !!root.dragState && root.dragState.to === row.n && root.dragState.from !== row.n
                width: parent.width
                height: Math.max(1, Style.space(2))
                color: Color.accent
                y: root.dragState && root.dragState.to > root.dragState.from ? parent.height + root.spacing / 2 - height / 2 : -root.spacing / 2 - height / 2
            }
        }
    }
}
