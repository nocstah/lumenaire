pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// A small popup anchored to the control that opened it (DESIGN.md "Menus and
// confirms"), never a window: Controls.Popup lives in the panel's own window,
// the way Ui.Dropdown's list does. Two faces:
//
//   menu     `items` [{key, label, glyph, danger, enabled, tip}] under an
//            optional muted `note`; j/k or the arrows move, Enter picks.
//   confirm  `question` set: one sentence, an optional name field (NameField)
//            and two buttons, Cancel and the `confirmText` action (primary,
//            or danger for a delete); Enter confirms, Esc cancels.
//
// openAt(item) opens it under `item`, right-aligned with it (or above it when
// there is no room below); the popup keeps inside the window.
Controls.Popup {
    id: root
    property var items: []
    property string note: ""
    property string question: ""
    property bool askName: false
    property string nameText: ""
    property var names: []
    property string current: ""
    property string confirmText: ""
    property string confirmKind: "primary"
    property string cancelText: "Cancel"
    property bool confirmEnabled: true
    property int cursor: 0
    property bool keyNav: false
    property Item anchorItem: null
    signal chosen(string key)
    signal confirmed(string name)

    readonly property bool asking: question !== ""
    readonly property var enabledItems: (items || []).map((it, i) => ({ it: it, i: i })).filter(x => x.it.enabled !== false)

    function openAt(item) {
        anchorItem = item
        parent = item
        cursor = 0
        keyNav = false
        if (askName) nameField.text = nameText
        open()
    }
    function place() {
        if (!anchorItem || !anchorItem.Window.window) return
        const win = anchorItem.Window.window
        const w = implicitWidth, h = implicitHeight
        const below = anchorItem.mapToItem(null, 0, anchorItem.height).y + Style.space(4)
        const left = anchorItem.mapToItem(null, 0, 0).x
        x = left + anchorItem.width - w < Style.space(12) ? 0 : anchorItem.width - w
        y = below + h > win.height - Style.space(8) && anchorItem.mapToItem(null, 0, 0).y - h - Style.space(4) > 0
            ? -h - Style.space(4) : anchorItem.height + Style.space(4)
    }
    function move(d) {
        const list = enabledItems
        if (list.length === 0) return
        if (!keyNav) { keyNav = true; cursor = list[0].i; return }
        let k = list.findIndex(x => x.i === cursor)
        k = Math.max(0, Math.min(list.length - 1, (k < 0 ? 0 : k) + d))
        cursor = list[k].i
    }
    function pick(i) {
        const it = items[i]
        if (!it || it.enabled === false) return
        close()
        chosen(String(it.key))
    }
    function confirm() {
        if (!confirmEnabled || (askName && !nameField.ok)) return
        const n = askName ? nameField.slug : ""
        close()
        confirmed(n)
    }

    modal: false
    focus: true
    padding: Style.space(4)
    margins: Style.space(8)
    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
    // A confirm is one fixed width (its sentence and a name's hint wrap in
    // it); a menu is as wide as its longest row.
    implicitWidth: asking ? Style.space(300) : Math.min(Style.space(260), Math.max(Style.space(180), content.implicitWidth + leftPadding + rightPadding))
    onAboutToShow: place()
    // The content can grow after it opens (a name's hint line): stay in place.
    onImplicitWidthChanged: if (opened) place()
    onImplicitHeightChanged: if (opened) place()
    onOpened: {
        place()
        if (askName) nameField.focusField()
        else keys.forceActiveFocus()
    }

    // The outline is mixed into the plate, not see-through: a picture under
    // the popup would show through a translucent edge.
    background: Ui.BorderSurface {
        color: Color.background
        radius: Style.cornerRadius
        borderSpec: Border.flat(Qt.tint(Color.background, Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.18)), 1)
    }

    contentItem: FocusScope {
        id: keys
        implicitWidth: content.implicitWidth
        implicitHeight: content.implicitHeight
        Keys.onPressed: function(event) {
            if (root.asking) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.confirm(); event.accepted = true }
                return
            }
            if (event.key === Qt.Key_Down || event.text === "j" || event.key === Qt.Key_Tab) { root.move(1); event.accepted = true }
            else if (event.key === Qt.Key_Up || event.text === "k" || event.key === Qt.Key_Backtab) { root.move(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                if (root.keyNav) root.pick(root.cursor)
                else root.move(1)
                event.accepted = true
            }
        }

        ColumnLayout {
            id: content
            width: parent.width
            spacing: Style.space(2)

            // ---- menu
            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(8)
                Layout.rightMargin: Style.space(8)
                Layout.topMargin: Style.space(4)
                Layout.bottomMargin: Style.space(4)
                visible: !root.asking && root.note !== ""
                text: root.note
                tone: "muted"
                font.pixelSize: Style.font.bodySmall
            }
            Repeater {
                model: root.asking ? [] : root.items
                Ui.CursorSurface {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool on: modelData.enabled !== false
                    Layout.fillWidth: true
                    implicitWidth: rowLine.implicitWidth + Style.space(16)
                    implicitHeight: Style.spacing.controlHeight
                    hasCursor: on && (rowMouse.containsMouse || (root.keyNav && root.cursor === index))
                    opacity: on ? 1 : 0.45
                    Accessible.role: Accessible.MenuItem
                    Accessible.name: String(modelData.label || "")
                    Accessible.onPressAction: root.pick(index)
                    RowLayout {
                        id: rowLine
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        spacing: Style.space(8)
                        Label {
                            text: String(row.modelData.glyph || "")
                            visible: text !== ""
                            tone: row.modelData.danger ? "urgent" : "muted"
                            font.pixelSize: Style.font.title
                            wrapMode: Text.NoWrap
                            Layout.preferredWidth: Style.space(16)
                            Accessible.ignored: true
                        }
                        Label {
                            text: String(row.modelData.label || "")
                            tone: row.modelData.danger ? "urgent" : "text"
                            wrapMode: Text.NoWrap
                            Layout.fillWidth: true
                            Accessible.ignored: true
                        }
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: row.on ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onEntered: if (row.on) { root.keyNav = false; root.cursor = row.index }
                        onClicked: root.pick(row.index)
                    }
                    Ui.PanelToolTip {
                        visible: rowMouse.containsMouse && String(row.modelData.tip || "") !== ""
                        text: String(row.modelData.tip || "")
                    }
                }
            }

            // ---- confirm
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: Style.space(8)
                visible: root.asking
                spacing: Style.space(12)
                Label {
                    Layout.fillWidth: true
                    text: root.question
                }
                NameField {
                    id: nameField
                    Layout.fillWidth: true
                    visible: root.askName
                    names: root.names
                    current: root.current
                    onAccepted: root.confirm()
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Item { Layout.fillWidth: true }
                    Action {
                        text: root.cancelText
                        onClicked: root.close()
                    }
                    Action {
                        text: root.confirmText
                        kind: root.confirmKind
                        visible: root.confirmText !== ""
                        enabled: root.confirmEnabled && (!root.askName || nameField.ok)
                        onClicked: root.confirm()
                    }
                }
            }
        }
    }
}
