import QtQuick
import qs.Commons

// A picture of a screen's media (DESIGN.md "Screens"): the thumbnail the
// engine keeps (a webp, 256 px on its long side, or a template's preview),
// drawn on a Canvas like ThemeArt so it renders the same on the GPU and in
// the software renders.
//
//   fit "cover"    fills the box at the screen's shape and crops what spills
//                  over: how the screen will show it
//   fit "contain"  the whole picture on the plate: a file that doesn't fit
//
// With no picture (none chosen, not made yet, unreadable) the plate shows
// the screen's glyph. A round screen is drawn round (the shape is the
// meaning); everything else takes the host's corners, capped at 10 px like
// theme previews. `dim` lays a plate over the picture (a job running on it).
// The outline is drawn on top: 1 px hairline, or `ring` "changed", 2 px in
// the accent (the draft changes this screen).
Item {
    id: root
    property string source: ""          // a file path or URL
    property string fit: "cover"        // cover | contain
    property bool round: false
    property string glyph: "󰍹"          // nf-md-monitor
    property string ring: ""            // "" | "changed"
    property real dim: 0
    // The engine's thumb_state: nothing is read while it is "pending" or
    // "failed", and "ready" re-reads a file that appeared at the same path
    // (the Canvas cache keys on the URL).
    property string thumbState: ""
    readonly property bool usable: thumbState !== "pending" && thumbState !== "running" && thumbState !== "failed"
    readonly property string src: source === "" || !usable ? "" : (source.charAt(0) === "/" ? Util.fileUrl(source) : source) + (thumbState !== "" ? "?v=" + thumbState : "")
    readonly property int radius: round ? Math.floor(Math.min(width, height) / 2) : Math.min(Style.cornerRadius, Style.space(10))
    readonly property bool shown: src !== "" && natural.status === Image.Ready && natural.implicitWidth > 0
    Accessible.ignored: true

    onSrcChanged: if (src !== "") canvas.loadImage(src)
    onFitChanged: canvas.requestPaint()
    onShownChanged: canvas.requestPaint()

    // The picture's own size, for the cover and contain arithmetic.
    Image {
        id: natural
        visible: false
        source: root.src
        asynchronous: false
        cache: true
    }
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Style.normalFillFor(Color.popups.text, Color.accent)
    }
    Label {
        anchors.centerIn: parent
        visible: !root.shown && root.glyph !== ""
        text: root.glyph
        tone: "muted"
        font.pixelSize: Math.max(Style.font.body, Math.min(Style.font.iconLarge * 1.5, Math.round(Math.min(root.width, root.height) * 0.36)))
        wrapMode: Text.NoWrap
        Accessible.ignored: true
    }
    Canvas {
        id: canvas
        anchors.fill: parent
        visible: root.shown
        Component.onCompleted: if (root.src !== "") loadImage(root.src)
        onImageLoaded: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            if (width <= 0 || height <= 0 || !root.shown || !isImageLoaded(root.src)) return
            ctx.beginPath()
            if (root.round) ctx.ellipse(0, 0, width, height)
            else ctx.roundedRect(0, 0, width, height, root.radius, root.radius)
            ctx.clip()
            const ia = natural.implicitWidth / Math.max(1, natural.implicitHeight)
            const ba = width / Math.max(1, height)
            const cover = root.fit !== "contain"
            // The drawn rect: covering the box (cropped by the clip) or
            // inside it (the plate shows around it).
            let dw = width, dh = height
            if ((ia > ba) === cover) { dh = height; dw = height * ia }
            else { dw = width; dh = width / ia }
            ctx.drawImage(root.src, (width - dw) / 2, (height - dh) / 2, dw, dh)
        }
    }
    Rectangle {
        anchors.fill: parent
        visible: root.dim > 0
        radius: root.radius
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, root.dim)
    }
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: root.ring === "changed" ? Math.max(1, Style.space(2)) : 1
        border.color: root.ring === "changed" ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)
    }
}
