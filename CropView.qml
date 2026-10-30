pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// The crop page (DESIGN.md "Crop"), for a file that doesn't fit the screen:
// a frame grab of it (media frame --json; the file's thumbnail stands in
// until it arrives) with the screen's shape laid over it. Outside the frame
// the picture is dimmed; the frame moves by dragging, and its four round
// handles or the wheel zoom it. Under it: Zoom, Moment (which moment of a
// video to frame, "0:12 / 0:42"), one muted line on what the framing keeps
// ("Keeps 84 % of the picture", "Low resolution; it may look soft", "Uses
// the first 2:00"), Reset framing, and Use.
//
// Everything is in the file's own pixels (display orientation): the engine
// gets the frame as x,y,w,h and fixes it to the screen's exact shape.
// Keys: the arrows move the frame 1 % (Shift: 10 %), + and - zoom, [ and ]
// step the moment by a second (Shift: 5), 0 resets, Enter uses it.
ColumnLayout {
    id: root
    required property var page                  // ScreenPage
    property var item: null                     // {path, kind, w, h, duration, thumb, title}
    property var frame: null                    // media frame --json for item.path
    property string frameState: "idle"
    property var screen: null
    signal useRequested(var crop, real time)
    signal frameWanted(real time)
    spacing: 0

    readonly property bool isVideo: !!item && (item.kind === "video" || item.kind === "animation")
    // The Service marks each frame with the file it came from (`for`).
    readonly property bool frameReady: !!frame && !!frame.path && (!frame.for || String(frame.for) === String(item ? item.path : ""))
    readonly property real srcW: frameReady && Number(frame.src_w) > 0 ? Number(frame.src_w) : item && Number(item.w) > 0 ? Number(item.w) : 0
    readonly property real srcH: frameReady && Number(frame.src_h) > 0 ? Number(frame.src_h) : item && Number(item.h) > 0 ? Number(item.h) : 0
    readonly property bool known: srcW > 0 && srcH > 0
    readonly property real duration: frameReady && Number(frame.duration) > 0 ? Number(frame.duration) : item && Number(item.duration) > 0 ? Number(item.duration) : 0
    readonly property real aspect: Format.screenAspect(screen)
    readonly property real targetW: screen && Array.isArray(screen.media_size) ? Number(screen.media_size[0]) : 400
    readonly property bool round: !!screen && screen.shape === "round"
    // The longest a screen takes (models.json prep.max_s); the engine's
    // job says exactly what it used.
    readonly property real capS: !screen ? 0 : screen.kind === "main" ? 180 : 120

    // The framing: its centre in the file's pixels, and the zoom (1 = the
    // biggest frame that fits).
    property real cx: 0
    property real cy: 0
    property real zoom: 1
    property real time: 0
    property bool placed: false
    readonly property real maxW: known ? Math.min(srcW, srcH * aspect) : 0
    readonly property real zoomMax: known ? Math.max(1, Math.min(8, maxW / Math.max(1, targetW / 2))) : 1
    readonly property real cw: maxW / Math.max(1, zoom)
    readonly property real ch: cw / aspect
    readonly property real fx: known ? Math.max(0, Math.min(srcW - cw, cx - cw / 2)) : 0
    readonly property real fy: known ? Math.max(0, Math.min(srcH - ch, cy - ch / 2)) : 0
    readonly property real keep: known ? (cw * ch) / (srcW * srcH) : 1
    readonly property var line: Format.cropLine({ keep: keep, scale: targetW / Math.max(1, cw), capS: isVideo ? capS : 0, duration: duration,
                                                  screen: screen ? Format.screenShort(screen) : "" })

    function even(v) { return Math.max(0, 2 * Math.round(v / 2)) }
    function crop() { return [even(fx), even(fy), even(cw), even(ch)] }
    function reset() {
        if (!known) return
        zoom = 1
        cx = srcW / 2
        cy = srcH / 2
        placed = true
    }
    function setZoom(z) {
        const c = [fx + cw / 2, fy + ch / 2]
        zoom = Math.max(1, Math.min(zoomMax, z))
        cx = c[0]; cy = c[1]
    }
    function nudge(dx, dy) {
        cx = fx + cw / 2 + dx * srcW
        cy = fy + ch / 2 + dy * srcH
        cx = Math.max(cw / 2, Math.min(srcW - cw / 2, cx))
        cy = Math.max(ch / 2, Math.min(srcH - ch / 2, cy))
    }
    function stepTime(d) {
        if (!isVideo || duration <= 0) return
        time = Math.max(0, Math.min(Math.max(0, duration - 0.05), time + d))
        frameWanted(time)
    }
    function use() { if (known) useRequested(crop(), isVideo ? time : 0) }
    onKnownChanged: if (known && !placed) reset()
    Component.onCompleted: {
        if (known && !placed) reset()
        time = frameReady && isFinite(Number(frame.time)) ? Number(frame.time) : duration / 3
    }
    function restore(s) {
        if (!s) return
        if (s.time !== undefined) time = Number(s.time)
        if (s.zoom !== undefined) zoom = Number(s.zoom)
        if (s.cx !== undefined && s.cy !== undefined && known) { cx = Number(s.cx) * srcW; cy = Number(s.cy) * srcH; placed = true }
    }
    // Keys from the page; true when used.
    function handleKey(event) {
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        const d = shift ? 0.1 : 0.01
        if (event.key === Qt.Key_Left || event.text === "h") { nudge(-d, 0); return true }
        if (event.key === Qt.Key_Right || event.text === "l") { nudge(d, 0); return true }
        if (event.key === Qt.Key_Up || event.text === "k") { nudge(0, -d); return true }
        if (event.key === Qt.Key_Down || event.text === "j") { nudge(0, d); return true }
        if (event.text === "+" || event.text === "=" || event.key === Qt.Key_Plus) { setZoom(zoom * 1.1); return true }
        if (event.text === "-" || event.key === Qt.Key_Minus) { setZoom(zoom / 1.1); return true }
        if (event.text === "[" || event.text === "{") { stepTime(event.text === "{" || shift ? -5 : -1); return true }
        if (event.text === "]" || event.text === "}") { stepTime(event.text === "}" || shift ? 5 : 1); return true }
        if (event.text === "0") { reset(); return true }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { use(); return true }
        return false
    }

    // ---- the picture and the frame
    Item {
        id: box
        Layout.fillWidth: true
        readonly property real srcAspect: root.known ? root.srcW / root.srcH : 16 / 9
        Layout.preferredHeight: Math.round(Math.min(width / srcAspect, Style.space(300)))
        readonly property real dispH: height
        readonly property real dispW: Math.min(width, height * srcAspect)
        readonly property real ox: Math.round((width - dispW) / 2)
        readonly property real k: root.known ? dispW / root.srcW : 1
        readonly property string picture: root.frameReady ? Util.fileUrl(String(root.frame.path)) + "?t=" + Math.round(Number(root.frame.time || 0) * 1000)
            : root.item && root.item.thumb ? Util.fileUrl(String(root.item.thumb)) : ""
        readonly property real rx: ox + root.fx * k
        readonly property real ry: root.fy * k
        readonly property real rw: root.cw * k
        readonly property real rh: root.ch * k
        Accessible.role: Accessible.Graphic
        Accessible.name: "Framing: " + root.line.text

        readonly property bool loaded: picture !== "" && probe.status === Image.Ready
        onPictureChanged: if (picture !== "") art.loadImage(picture)
        onLoadedChanged: art.requestPaint()
        Image { id: probe; visible: false; source: box.picture; asynchronous: false }
        Rectangle {
            x: box.ox
            width: box.dispW
            height: box.dispH
            radius: Math.min(Style.cornerRadius, Style.space(10))
            color: Style.normalFillFor(Color.popups.text, Color.accent)
        }
        Canvas {
            id: art
            x: box.ox
            width: box.dispW
            height: box.dispH
            Component.onCompleted: if (box.picture !== "") loadImage(box.picture)
            onImageLoaded: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (width <= 0 || height <= 0 || !box.loaded || !isImageLoaded(box.picture)) return
                const r = Math.min(Style.cornerRadius, Style.space(10))
                ctx.beginPath()
                ctx.roundedRect(0, 0, width, height, r, r)
                ctx.clip()
                ctx.drawImage(box.picture, 0, 0, width, height)
            }
        }
        Label {
            anchors.centerIn: parent
            visible: !box.loaded
            text: root.frameState === "failed" ? "Couldn't read a picture from it" : "Loading…"
            tone: "muted"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
        }
        // Outside the frame, dimmed: one even-odd fill with the frame (or a
        // round screen's circle) as its hole, clipped like the picture, so
        // no seams and nothing past its corners.
        Canvas {
            id: dim
            visible: root.known
            x: box.ox
            width: box.dispW
            height: box.dispH
            readonly property var frameRect: [box.rx - box.ox, box.ry, box.rw, box.rh, root.round]
            onFrameRectChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (width <= 0 || height <= 0) return
                const r = Math.min(Style.cornerRadius, Style.space(10))
                ctx.beginPath()
                ctx.roundedRect(0, 0, width, height, r, r)
                ctx.clip()
                const f = frameRect
                ctx.fillStyle = Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.55)
                ctx.fillRule = Qt.OddEvenFill
                ctx.beginPath()
                ctx.rect(0, 0, width, height)
                if (f[4]) ctx.ellipse(f[0], f[1], f[2], f[3])
                else ctx.rect(f[0], f[1], f[2], f[3])
                ctx.fill()
            }
        }
        // The frame: a white line inside a dark one reads on any picture.
        Rectangle {
            visible: root.known
            x: box.rx - 1
            y: box.ry - 1
            width: box.rw + 2
            height: box.rh + 2
            radius: root.round ? width / 2 : 0
            color: "transparent"
            border.width: 1
            border.color: "#000000"
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: root.round ? width / 2 : 0
                color: "transparent"
                border.width: 1
                border.color: "#ffffff"
            }
        }
        MouseArea {
            id: drag
            visible: root.known
            x: box.rx
            y: box.ry
            width: box.rw
            height: box.rh
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property real sx: 0
            property real sy: 0
            property real scx: 0
            property real scy: 0
            onPressed: function(m) { sx = m.x + x; sy = m.y + y; scx = root.fx + root.cw / 2; scy = root.fy + root.ch / 2 }
            onPositionChanged: function(m) {
                if (!pressed) return
                root.cx = Math.max(root.cw / 2, Math.min(root.srcW - root.cw / 2, scx + (m.x + x - sx) / box.k))
                root.cy = Math.max(root.ch / 2, Math.min(root.srcH - root.ch / 2, scy + (m.y + y - sy) / box.k))
            }
            onWheel: function(w) { root.setZoom(root.zoom * (w.angleDelta.y > 0 ? 1.1 : 1 / 1.1)) }
        }
        // Four round handles (the picker's knobs): drag one to zoom.
        Repeater {
            model: root.known ? 4 : 0
            Rectangle {
                id: handle
                required property int index
                readonly property int d: Style.space(14)
                // On a round frame they sit on the circle, at the diagonals.
                readonly property real inset: root.round ? box.rw / 2 * (1 - Math.SQRT1_2) : 0
                readonly property real hx: index % 2 === 0 ? box.rx + inset : box.rx + box.rw - inset
                readonly property real hy: index < 2 ? box.ry + inset : box.ry + box.rh - inset
                x: Math.round(hx - d / 2)
                y: Math.round(hy - d / 2)
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
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: handle.index === 0 || handle.index === 3 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                    onPositionChanged: function(m) {
                        if (!pressed) return
                        const p = mapToItem(box, m.x, m.y)
                        const mid = box.rx + box.rw / 2
                        const half = Math.max(Style.space(12), Math.abs(p.x - mid))
                        root.setZoom(root.maxW * box.k / (2 * half))
                    }
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            z: -1
            acceptedButtons: Qt.NoButton
            onWheel: function(w) { root.setZoom(root.zoom * (w.angleDelta.y > 0 ? 1.1 : 1 / 1.1)) }
        }
    }

    // ---- zoom and moment
    component Caption: Label {
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Layout.preferredWidth: Style.space(64)
        Layout.alignment: Qt.AlignVCenter
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        spacing: Style.space(8)
        Caption { text: "Zoom" }
        Ui.CursorSurface {
            id: zoomRow
            Layout.fillWidth: true
            implicitHeight: Style.spacing.controlHeight
            hasCursor: root.page.keyNav && root.page.cursorKey === "zoom"
            Accessible.role: Accessible.Slider
            Accessible.name: "Zoom " + Math.round(root.zoom * 100) + " percent"
            Component.onCompleted: root.page.register("zoom", zoomRow)
            Ui.PanelSlider {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                enabled: root.known && root.zoomMax > 1
                opacity: enabled ? 1 : 0.45
                minimum: 1
                maximum: Math.max(1.01, root.zoomMax)
                step: 0.1
                trackColor: Style.selectedFillFor(Color.popups.text, Color.accent)
                fillColor: Color.popups.text
                knobColor: Color.popups.text
                value: root.zoom
                onMoved: function(v) { root.setZoom(v) }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        visible: root.isVideo && root.duration > 0
        spacing: Style.space(8)
        Caption { text: "Moment" }
        Ui.CursorSurface {
            id: momentRow
            Layout.fillWidth: true
            implicitHeight: Style.spacing.controlHeight
            hasCursor: root.page.keyNav && root.page.cursorKey === "moment"
            Accessible.role: Accessible.Slider
            Accessible.name: "Moment " + Format.mmss(root.time) + " of " + Format.mmss(root.duration)
            Component.onCompleted: root.page.register("moment", momentRow)
            Ui.PanelSlider {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                minimum: 0
                maximum: Math.max(0.1, root.duration)
                step: 1
                trackColor: Style.selectedFillFor(Color.popups.text, Color.accent)
                fillColor: Color.popups.text
                knobColor: Color.popups.text
                value: root.time
                onMoved: function(v) { root.time = v; root.frameWanted(v) }
            }
        }
        Label {
            text: Format.mmss(root.time) + " / " + Format.mmss(root.duration)
            tone: "muted"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            Layout.alignment: Qt.AlignVCenter
        }
    }

    // ---- what it keeps, and Use
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(12)
        spacing: Style.space(8)
        Item {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: fitLine.implicitHeight
            Label {
                id: fitLine
                width: parent.width
                text: root.known ? root.line.text : ""
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
            MouseArea { id: fitMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            Ui.PanelToolTip { visible: fitMouse.containsMouse && root.line.tip !== ""; text: root.line.tip }
        }
        TextLink {
            id: resetLink
            visible: root.known && (root.zoom > 1.001 || Math.abs(root.fx + root.cw / 2 - root.srcW / 2) > 1 || Math.abs(root.fy + root.ch / 2 - root.srcH / 2) > 1)
            text: "Reset framing"
            tooltipText: "The middle of the picture, as big as it fits"
            hasCursor: root.page.keyNav && root.page.cursorKey === "reset"
            Layout.rightMargin: -inset
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.reset()
            Component.onCompleted: root.page.register("reset", resetLink)
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        Item { Layout.fillWidth: true }
        Action {
            id: useAction
            kind: "primary"
            text: "Use"
            enabled: root.known
            tooltipText: root.known ? "Prepare it for the " + (root.screen ? Format.screenShort(root.screen).toLowerCase() : "screen") : "Waiting for the picture"
            hasCursor: root.page.keyNav && root.page.cursorKey === "use"
            onClicked: root.use()
            Component.onCompleted: root.page.register("use", useAction)
        }
    }
    // Room for the keyboard ring outside Use.
    Item { Layout.preferredHeight: Style.space(4) }
}
