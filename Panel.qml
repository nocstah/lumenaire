import QtQuick
import qs.Ui as Ui
import qs.Commons

// The bar-anchored popup. BarWidget.qml loads one per monitor and injects
// bar, anchorItem, hostWidget and service. The Service counts open panels
// (panelOpened/panelClosed), so instances on several monitors never fight
// over a single "open" flag; a panel destroyed while open still gives its
// count back.
Ui.Panel {
    id: root
    moduleName: "io.github.nocstah.lumenaire"
    manageIpc: false
    property var anchorItem: null
    property var hostWidget: null
    property var service: null
    property bool counted: false
    readonly property Item contentView: content

    function syncCount() {
        if (!service) return
        if (opened && !counted) { counted = true; service.panelOpened(); service.ackFailure() }
        else if (!opened && counted) { counted = false; service.panelClosed() }
    }
    onOpenedChanged: { syncCount(); if (!opened) content.reset() }
    // A hot reload hands us a fresh Service whose counter starts at zero.
    onServiceChanged: { counted = false; syncCount() }
    Component.onDestruction: if (counted && service) service.panelClosed()

    Ui.KeyboardPanel {
        id: popup
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: content
        contentWidth: popup.fittedContentWidth(Style.space(468))
        contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(720))
        LightsContent {
            id: content
            anchors.fill: parent
            service: root.service
            shown: root.opened
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }
        }
    }
}
