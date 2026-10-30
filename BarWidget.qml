pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Format.js" as Format

// Bar entry: a lightbulb tinted with the case theme's lead colour,
// and a short readout (coolant by default). One instance per monitor; all of
// them read the single Service through bar.shell.serviceFor(). The panel is
// loaded next to the button (the Omaglass/omacards pattern) and the root
// proxies opened/open/close so `omarchy-shell shell toggle` reaches it.
//
// State precedence (spec §6): no service, engine error, daemon offline,
// applying/queued, unseen failure, hot, lights off. A PC without a Lian Li
// daemon is never "offline" (the Service reports daemonState "absent").
Ui.BarWidget {
    id: root
    moduleName: "io.github.nocstah.lumenaire"
    readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // Settings: the Service coerces shell.json strings; the injected entry is
    // the fallback until it is up.
    function opt(name, fallback) {
        const s = service && service.settings ? service.settings[name] : undefined
        return s === undefined || s === null ? setting(name, fallback) : s
    }
    function asBool(v) { return v === true || v === "true" || v === 1 || v === "1" }
    readonly property string show: String(opt("show", "auto"))
    readonly property bool showDot: asBool(opt("showDot", true))
    readonly property real coolantWarn: Number(opt("coolantWarn", 40)) || 40

    readonly property bool hasService: service !== null && service !== undefined
    // A PC without a pump reads its CPU instead (show "auto", the default).
    readonly property bool hasPump: !hasService || service.hasPump !== false
    readonly property string shows: show === "auto" ? (hasPump ? "coolant" : "cpu") : show
    readonly property string engineError: hasService ? (service.engineError || "") : ""
    readonly property bool offline: hasService && service.daemonState === "offline"
    readonly property bool daemonFailed: hasService && !!service.status && service.status.daemon_unit === "failed"
    readonly property bool working: hasService && (service.engine === "applying" || service.engine === "queued")
    readonly property bool failureUnseen: hasService && service.failureUnseen === true
    readonly property bool lightsOn: !hasService || service.lights !== "off"
    readonly property var alert: hasService && service.alert ? service.alert : null
    readonly property bool coolantFresh: hasService && service.coolantC !== null && service.coolantC !== undefined && service.coolantStale !== true
    readonly property bool coolantHot: coolantFresh && service.coolantC >= coolantWarn
    readonly property bool cpuHot: hasService && !!alert && Format.overAlert(service.cpuC, alert.cpu)
    readonly property bool gpuHot: hasService && !!alert && Format.overAlert(service.gpuC, alert.gpu)
    readonly property bool hot: hasService && (coolantHot || cpuHot || gpuHot)
    readonly property string activeName: hasService ? Format.themeName(service.activeTheme) : ""
    readonly property var activeSwatch: {
        if (!hasService || !service.themeByName || !service.activeTheme) return []
        const t = service.themeByName[service.activeTheme]
        return t && t.swatch ? t.swatch : []
    }

    readonly property string readout: {
        if (!hasService || shows === "none") return ""
        if (engineError !== "") return "!"
        if (working) return "…"
        if (shows === "cpu") return service.cpuC !== null && service.cpuC !== undefined ? Math.round(service.cpuC) + "°" : "—"
        if (offline) return "—"
        const coolant = coolantFresh ? Math.round(service.coolantC) + "°" : "—"
        const pump = service.pumpRpm !== null && service.pumpRpm !== undefined ? Format.rpmShort(service.pumpRpm) : "—"
        return shows === "pump" ? pump : shows === "both" ? coolant + " " + pump : coolant
    }
    readonly property bool loading: hasService && service.ready !== true && engineError === ""
    // The Service words any kind of op: "Applying Hellfire", "Turning lights
    // off"; queued names our own waiting request, else the oldest pending one.
    readonly property string busyLabel: hasService && service.busyLabel ? service.busyLabel : "Applying"
    readonly property string queuedLabel: hasService && service.queuedLabel ? service.queuedLabel : ""
    // The readout shows coolant and pump only: say why when a CPU/GPU alert
    // turns it red.
    readonly property string heatNote: {
        if (!hasService || !alert) return ""
        const n = []
        if (cpuHot) n.push("CPU " + Format.tempC(service.cpuC, 0) + " over its " + Format.tempC(alert.cpu.threshold, 0) + " alert")
        if (gpuHot) n.push("GPU " + Format.tempC(service.gpuC, 0) + " over its " + Format.tempC(alert.gpu.threshold, 0) + " alert")
        return n.join(" · ")
    }
    readonly property string tooltip: {
        if (!hasService) return "Lumenaire · Starting…"
        if (engineError !== "") return "Lumenaire · " + String(service.notice || "the engine can't be read").replace(/\s*\n\s*/g, " ") + " · Click for details"
        if (loading) return "Lumenaire · Reading the engine…"
        if (offline) return "Lumenaire · Lian Li daemon isn't reachable · Click for details"
        if (service.engine === "applying") {
            const step = service.busy && service.busy.step ? Format.step(service.busy.step) + ", " : ""
            return "Lumenaire · " + busyLabel + "… (" + step + Format.mmss(service.busyElapsed) + ")"
        }
        if (service.engine === "queued")
            return "Lumenaire · Queued" + (queuedLabel ? " · " + queuedLabel : "") + " · Click for details"
        if (failureUnseen)
            return "Lumenaire · " + (service.failureLabel || "The last change failed") + " · Click for details"
        if (!lightsOn) return "Lumenaire · Lights off · " + (activeName ? activeName + " selected · " : "") + "Click for themes and power"
        const parts = ["Lumenaire"]
        // A live theme preview is what the case shows; no new colour state.
        const pv = service.previewLive === true && service.preview ? service.preview : null
        if (pv && pv.theme) parts.push("Previewing " + Format.themeName(pv.theme) + " (not saved)")
        else if (activeName) parts.push(activeName)
        if (service.pumpRpm !== null && service.pumpRpm !== undefined) parts.push("pump " + Format.rpm(service.pumpRpm))
        if (coolantFresh) parts.push("coolant " + Format.tempC(service.coolantC, 1))
        if (!hasPump && service.cpuC !== null && service.cpuC !== undefined) parts.push("CPU " + Format.tempC(service.cpuC, 0))
        if (heatNote) parts.push(heatNote)
        if (service.profileState === "missing") parts.push("No hardware profile yet")
        const rotating = Array.isArray(service.rotation) && service.rotation.length > 0
        parts.push(rotating || hasPump ? "Click for themes, middle-click for the next " + (hasPump ? "pump clip" : "clip") : "Click for themes and power")
        return parts.join(" · ")
    }

    function injectPanel() {
        const panel = panelLoader.item
        if (!panel) return
        panel.bar = root.bar
        panel.anchorItem = button
        panel.hostWidget = root
        panel.service = root.service
    }
    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { opened ? close() : open() }
    function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
    onBarChanged: injectPanel()
    onServiceChanged: injectPanel()

    Loader {
        id: panelLoader
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
        onStatusChanged: if (status === Loader.Error) console.warn("[lumenaire] panel failed to load")
    }

    TextMetrics {
        id: readoutMetrics
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: root.readout
    }

    Ui.BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        readonly property bool showValue: root.readout !== "" && !root.vertical
        readonly property color glyphColor: active ? activeColor : foreground
        fixedWidth: root.vertical ? -1 : slotSize + (showValue ? Style.space(4) + Math.ceil(readoutMetrics.advanceWidth) : 0)
        dimmed: !root.hasService || root.loading || root.engineError !== "" || (root.offline && !root.daemonFailed)
            || (!root.lightsOn && !root.working && !root.failureUnseen)
        active: root.working || root.failureUnseen || (root.offline && root.daemonFailed)
        activeColor: root.working ? Color.accent : (root.bar ? root.bar.urgent : Color.urgent)
        tooltipText: root.tooltip
        iconComponent: Component {
            Item {
                Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Item {
                        width: Style.bar.iconCanvas
                        height: Style.bar.iconCanvas
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: root.lightsOn ? "󰌵" : "󰌶"  // nf-md-lightbulb U+F0335 / nf-md-lightbulb_off U+F0336
                            // The bulb carries the case colour itself (showDot):
                            // a separate dot under it made the icon taller than
                            // its neighbours. Busy and alert states keep their
                            // own colour.
                            color: root.showDot && root.lightsOn && root.activeSwatch.length > 0 && !button.active
                                ? root.activeSwatch[0] : button.glyphColor
                            font.family: root.bar ? root.bar.fontFamily : Style.fontFamily
                            // The lightbulb glyph fills more of its em box than
                            // the stock bar icons; a step smaller matches them.
                            font.pixelSize: Math.round(Style.bar.iconFont * 0.9)
                            renderType: Text.NativeRendering
                        }
                    }
                    Text {
                        visible: button.showValue
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: root.readout
                        color: root.hot && !button.active ? (root.bar ? root.bar.urgent : Color.urgent) : button.glyphColor
                        font.family: Style.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        renderType: Text.NativeRendering
                    }
                }
            }
        }
        onPressed: function(b) {
            if (b === Qt.MiddleButton) { if (root.service) root.service.skipClip(); return }
            if (b === Qt.RightButton && String(root.opt("rightClick", "panel")) === "lights" && root.service) {
                root.service.setLights(!root.lightsOn)
                return
            }
            root.toggle()
        }
    }
}
