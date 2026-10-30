import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// One screen on the case map (DESIGN.md "Screens"): its media as a picture
// at the screen's own shape (MediaThumb, cover), with the accent outline
// when the draft changes it. Nothing else is written on it: where it is,
// what it shows and its state are the tooltip, and the line under the map
// says what needs saying. A job running on it dims the picture and shows
// its percentage; a failure puts the small urgent dot on its corner (the
// swatch's warning mark). Hover and the keyboard cursor draw the ring the
// theme cards use; a click opens the screen's page.
Item {
    id: root
    property var screen: ({})
    property var job: null
    property bool failed: false
    property bool current: false         // the keyboard cursor
    property string line: ""             // its state line, for the tooltip
    signal activated()

    readonly property bool running: Format.jobRunning(job)
    readonly property bool hot: mouse.containsMouse || current
    readonly property bool managed: screen.managed !== false
    readonly property var media: screen.media || null
    readonly property string thumb: screen.modes && screen.modes.current === "template" && screen.template ? String(screen.template.thumb || "")
        : media ? String(media.thumb || "") : ""
    Accessible.role: Accessible.Button
    Accessible.name: Format.screenShort(screen) + " screen" + (screen.changed ? ", changed" : "") + (failed ? ", failed" : "")
        + (running ? ", " + Format.jobText(job).toLowerCase() : "")
    Accessible.onPressAction: root.activated()

    MediaThumb {
        id: pic
        anchors.fill: parent
        source: root.thumb
        thumbState: root.media ? String(root.media.thumb_state || "") : ""
        round: root.screen.shape === "round"
        glyph: Format.screenGlyph(root.screen.kind)
        ring: root.screen.changed ? "changed" : ""
        fit: root.media && ["poor", "cropped"].indexOf(Format.fitState(root.media.fit)) >= 0 ? "contain" : "cover"
        dim: root.running ? 0.6 : 0
        opacity: root.managed ? 1 : 0.45
    }
    // Hover and the keyboard cursor: a ring just outside the picture.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        visible: root.hot && root.managed
        radius: pic.round ? width / 2 : pic.radius > 0 ? pic.radius + Style.space(3) : 0
        color: "transparent"
        border.width: root.current ? Math.max(1, Style.space(2)) : 1
        border.color: root.current ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.55)
                                   : Style.focusBorderFor(Color.popups.text, Color.accent)
    }
    Label {
        anchors.centerIn: parent
        visible: root.running
        text: root.job && ["probing", "estimating", "encoding", "finishing"].indexOf(String(root.job.state)) >= 0 ? Format.jobPercent(root.job) + " %" : "…"
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.NoWrap
        Accessible.ignored: true
    }
    Rectangle {
        visible: root.failed
        width: Style.space(8)
        height: width
        radius: width / 2
        x: pic.round ? parent.width * 0.85 - width / 2 : parent.width - width / 2 - Style.space(1)
        y: pic.round ? parent.height * 0.15 - height / 2 : -height / 2 + Style.space(1)
        color: Color.urgent
        border.width: 1
        border.color: Color.background
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.managed
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
    MouseArea {
        id: tipArea
        anchors.fill: parent
        visible: !root.managed
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }
    Ui.PanelToolTip {
        visible: mouse.containsMouse || tipArea.containsMouse
        text: Format.tileTip(root.screen, root.line)
    }
}
