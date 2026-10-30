import QtQuick
import qs.Commons

// A theme's preview picture with the host's corners, at most 10 px (the
// cached image `lumenaire previews` builds: five fan screens, the pump and the
// 8.8" strip). Drawn on a Canvas with a clip: plain QPainter, so it renders
// the same on the GPU and under the software backend of the offscreen
// renders, and at the screen's scale. Until the image is there (or when it
// failed or is still being built) the theme's LED swatch fills it as
// horizontal stripes, so a new theme still reads as itself. The outline is
// drawn on top: `ring` "active" is the accent, 2 px.
Item {
    id: root
    property var theme: ({})
    property string ring: ""          // "" | "active"
    readonly property string src: theme && theme.preview ? Util.fileUrl(theme.preview) + "?v=" + (theme.preview_mtime || 0) : ""
    readonly property var swatch: theme && theme.swatch ? theme.swatch : []
    readonly property int radius: Math.min(Style.cornerRadius, Style.space(10))
    Accessible.ignored: true

    onSrcChanged: if (src !== "") canvas.loadImage(src)
    onSwatchChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        Component.onCompleted: if (root.src !== "") loadImage(root.src)
        onImageLoaded: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            if (width <= 0 || height <= 0) return
            ctx.beginPath()
            ctx.roundedRect(0, 0, width, height, root.radius, root.radius)
            ctx.clip()
            if (root.src !== "" && isImageLoaded(root.src)) {
                ctx.drawImage(root.src, 0, 0, width, height)
                return
            }
            const list = root.swatch.length ? root.swatch : [String(Color.background)]
            for (let i = 0; i < list.length; i++) {
                const y0 = Math.round(i * height / list.length), y1 = Math.round((i + 1) * height / list.length)
                ctx.fillStyle = String(list[i])
                ctx.fillRect(0, y0, width, y1 - y0)
            }
        }
    }
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: root.ring === "active" ? Math.max(1, Style.space(2)) : 1
        border.color: root.ring === "active" ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)
    }
}
