import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// One file in the media picker (DESIGN.md "Picker"): its picture at the
// screen's shape and one muted line under it, "0:12", "Picture",
// "Animation", "0:12 · cropped". A file that doesn't fit the screen shows
// whole on the plate ("Doesn't fit"); choosing it opens the crop page. Its
// name, size and where else it's used are the tooltip. `inUse` (on this
// screen now) draws the accent outline; hover and the keyboard cursor the
// ring the theme cards use.
Item {
    id: root
    property var item: ({})
    property real cellWidth: Style.space(104)   // the grid's column (not the laid-out width: no loop)
    property real aspect: 1
    property bool round: false
    property bool current: false          // the keyboard cursor
    property bool inUse: false
    property string screenName: ""
    signal chosen()

    readonly property bool hot: mouse.containsMouse || current
    readonly property string fit: Format.fitState(item.fit)
    // A narrow tile says "Cropped" for a cropped picture.
    readonly property string fullText: Format.tileLine(item)
    readonly property string line: metrics.advanceWidth(fullText) <= cellWidth ? fullText : Format.tileLineShort(item)
    readonly property string tip: {
        const bits = []
        if (item.title) bits.push(String(item.title))
        const dims = Number(item.w) > 0 && Number(item.h) > 0 ? item.w + "×" + item.h : ""
        const what = [Format.mediaKindWord(item.kind), Format.clipLength(item.duration), dims].filter(x => x).join(" · ")
        if (what) bits.push(what)
        if (fit !== "unknown") bits.push(Format.fitTip(item.fit, screenName))
        const used = Format.list(item.in_use) || []
        if (used.length) bits.push("In " + used.map(n => Format.themeName(n)).join(", "))
        if (inUse) bits.push("On this screen now")
        return bits.join("\n")
    }
    implicitHeight: pic.height + Style.space(4) + words.implicitHeight
    Accessible.role: Accessible.Button
    Accessible.name: (item.title ? String(item.title) + ", " : "") + line + (inUse ? ", on this screen now" : "")
    Accessible.onPressAction: root.chosen()

    MediaThumb {
        id: pic
        width: root.cellWidth
        height: Math.round(root.cellWidth / Math.max(0.1, root.aspect))
        source: String(root.item.thumb || "")
        thumbState: String(root.item.thumb_state || "")
        fit: root.fit === "poor" ? "contain" : "cover"
        round: root.round
        glyph: Format.mediaGlyph(root.item.kind)
        ring: root.inUse ? "changed" : ""
        Rectangle {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            visible: root.hot
            radius: pic.round ? width / 2 : pic.radius > 0 ? pic.radius + Style.space(3) : 0
            color: "transparent"
            border.width: root.current ? Math.max(1, Style.space(2)) : 1
            border.color: root.current ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.55)
                                       : Style.focusBorderFor(Color.popups.text, Color.accent)
        }
    }
    FontMetrics {
        id: metrics
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
    }
    Label {
        id: words
        y: pic.height + Style.space(4)
        width: root.cellWidth
        text: root.line
        tone: "muted"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        Accessible.ignored: true
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.chosen()
    }
    Ui.PanelToolTip {
        visible: mouse.containsMouse && root.tip !== ""
        text: root.tip
    }
}
