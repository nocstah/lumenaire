pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// One theme in the panel grid (DESIGN.md "Theme cards"): the preview
// (ThemeArt), then the name with its state on the right. Nothing else unless
// it matters: a second small line says "Draft" (unsaved edits wait for this
// theme) and how much of the theme this PC can't show ("Skips pump media",
// with the detail in the tooltip).
//
//   active    accent outline on the picture and "󰄬 Active" in accent
//   night     "󰖔 Night", muted
//   applying  "Applying… 0:12" in accent; queued "Queued"; failed "Failed"
//             in urgent; saved while the lights are off "Applies later"
//
// A click picks the theme (the panel asks first when it has to). The pencil
// on the picture's corner, shown on hover and on the keyboard cursor, opens
// the editor; a right click (or the menu key) asks the panel for the card
// menu. `current` is the keyboard cursor: a ring around the picture.
Item {
    id: root
    property var theme: ({})
    property string themeState: ""
    property int busyElapsed: 0
    property bool selected: false          // the active theme
    property bool current: false           // the keyboard cursor
    property bool editable: false          // the pencil (the editor can open it)
    property real cardWidth: Style.space(200)
    signal activated()
    signal editRequested()
    signal menuRequested()

    readonly property string displayName: Format.themeName(theme.name)
    readonly property var fit: Format.coverageChip(theme.coverage)
    readonly property bool hasDraft: !!theme.draft && typeof theme.draft === "object"
    readonly property string stateText: themeState === "active" ? "󰄬 Active"
        : themeState === "applying" ? "Applying… " + Format.mmss(busyElapsed)
        : themeState === "queued" ? "Queued"
        : themeState === "saved" ? "Applies later"
        : themeState === "failed" ? "Failed"
        : themeState === "night" ? "󰖔 Night"
        : ""
    readonly property string stateTone: themeState === "failed" ? "urgent"
        : themeState === "active" || themeState === "applying" ? "accent" : "muted"
    readonly property string stateTip: themeState === "saved" ? "Saved: it goes on when the lights come back on."
        : themeState === "failed" ? "The last apply failed. Click to try again."
        : themeState === "night" ? "Your night theme." : ""
    readonly property string note: fit ? fit.text : ""
    readonly property bool hot: mouse.containsMouse || current
    readonly property int artHeight: Math.round(cardWidth * 267 / 684)

    implicitWidth: cardWidth
    implicitHeight: art.height + Style.space(8) + nameRow.implicitHeight + (second.visible ? Style.space(2) + second.implicitHeight : 0)
    Accessible.role: Accessible.Button
    Accessible.name: displayName + " theme" + (stateText ? ", " + stateText.replace(/^\S+ /, "").toLowerCase() : "")
        + (hasDraft ? ", draft" : "") + (fit ? ", " + fit.text.toLowerCase() : "")
    Accessible.description: fit ? fit.tip : ""
    Accessible.onPressAction: root.activated()

    ThemeArt {
        id: art
        width: root.cardWidth
        height: root.artHeight
        theme: root.theme
        ring: root.selected ? "active" : ""
        // The keyboard cursor and hover: a ring just outside the picture.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            visible: root.hot
            radius: art.radius > 0 ? art.radius + Style.space(3) : 0
            color: "transparent"
            border.width: root.current ? Math.max(1, Style.space(2)) : 1
            border.color: root.current ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.55)
                                       : Style.focusBorderFor(Color.popups.text, Color.accent)
        }
    }
    RowLayout {
        id: nameRow
        y: art.height + Style.space(8)
        width: root.cardWidth
        spacing: Style.space(8)
        Label {
            id: nameLabel
            text: root.displayName
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            Layout.fillWidth: true
            Accessible.ignored: true
        }
        Label {
            visible: text !== ""
            text: root.stateText
            tone: root.stateTone
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            Accessible.ignored: true
        }
    }
    Row {
        id: second
        y: nameRow.y + nameRow.implicitHeight + Style.space(2)
        width: root.cardWidth
        visible: root.hasDraft || root.note !== ""
        spacing: Style.space(4)
        Label {
            visible: root.hasDraft
            text: "Draft"
            tone: "accent"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            Accessible.ignored: true
        }
        Label {
            visible: root.hasDraft && root.note !== ""
            text: "·"
            tone: "muted"
            font.pixelSize: Style.font.bodySmall
            Accessible.ignored: true
        }
        Label {
            visible: root.note !== ""
            width: Math.min(implicitWidth, root.cardWidth - x)
            text: root.note
            tone: "muted"
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            Accessible.ignored: true
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(m) { if (m.button === Qt.RightButton) root.menuRequested(); else root.activated() }
    }
    IconButton {
        x: art.width - width - Style.space(8)
        y: Style.space(8)
        visible: root.editable && (root.hot || over)
        property bool over: false
        backdrop: true
        glyph: "󰏫"   // nf-md-pencil
        tooltipText: "Edit " + root.displayName
        onHovered: function(h) { over = h }
        onClicked: root.editRequested()
    }
    Ui.PanelToolTip {
        readonly property string full: [nameLabel.truncated ? root.displayName : "", root.stateTip, root.fit ? root.fit.tip : ""].filter(x => x !== "").join("\n")
        visible: mouse.containsMouse && full !== ""
        text: full
    }
}
