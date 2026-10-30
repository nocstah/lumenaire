//@ pragma OmarchyLoadPatch
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Lights" as Lights

// Offscreen harness (driven by tests/render.py). For every palette it draws
// each fixture's panel at every width, then one strip with the bar widget in
// every fixture state. The plan (palettes, fixtures, themes) arrives as one
// JSON file so nothing here reads the live system.
ShellRoot {
    id: harness
    property var plan: null
    property var shots: []
    property int step: -1
    property var barStates: []

    function applyPalette(p) {
        Commons.Color.shellValues = ({})
        Commons.Color.loadColors(p.colors)
        Commons.Color.loadShell(p.shell)
        Style.cornerRadius = plan.radius
    }
    function configure(shot) {
        applyPalette(shot.palette)
        if (shot.kind === "panel") {
            service.load(shot.fixture.data, plan.themes, plan.fixturesDir)
            content.fixedNow = shot.fixture.data.status && shot.fixture.data.status.ts ? shot.fixture.data.status.ts : 0
            content.page = "main"
            content.reset()
            const ui = shot.fixture.data.ui || {}
            // The desktop is the palette the shot draws with ("Match my desktop").
            content.desktopName = shot.palette.name
            content.desktopColors = shot.palette.colors
            if (ui.keyNav) { content.keyNav = true; content.cursor = ui.cursor || 0 }
            if (ui.renameTo !== undefined) content.renameTo = ui.renameTo
            // The editor page: ui.editor = {expanded: [unit ids], more: [part ids],
            // advanced, picker, cursor, keys, confirm, menu, …}; the New theme
            // page: ui.wizard = {step, start, colour, copyFrom, seed, name, picker,
            // cursor, keys}; ui.savedOffer = {name}: "Saved … Use it now?".
            content.editorUi = ui.editor || null
            content.wizardUi = ui.wizard || null
            // The screen page: ui.screen = {role, step, tab, query, cursor,
            // keys, crop: {cx, cy, zoom, time}, cropIndex, adding, drag, …}.
            const scrUi = ui.screen ? JSON.parse(JSON.stringify(ui.screen)) : null
            if (scrUi && scrUi.cropItem && scrUi.cropItem.thumb && String(scrUi.cropItem.thumb).charAt(0) !== "/")
                scrUi.cropItem.thumb = plan.fixturesDir + "/" + scrUi.cropItem.thumb
            content.screenUi = scrUi
            // The wallpaper page: ui.wallpaper = {theme, cursor, keys}.
            content.wallpaperUi = ui.wallpaper || null
            content.savedOffer = ui.savedOffer || null
            if (ui.page) content.page = ui.page
            window.width = shot.width
            window.height = 900
            barBox.visible = false
            area.visible = true
        } else {
            area.visible = false
            barBox.visible = true
            window.width = 468
        }
    }
    // After the first layout: open what the fixture has open (a card menu or
    // confirm, the ⋯ menu), with the window tall enough to hold it.
    function openPopups(shot) {
        if (shot.kind !== "panel") return
        const ui = shot.fixture.data.ui || {}
        window.height = Math.ceil(content.implicitHeight) + 420
        if (ui.confirm) {
            const t = service.themeByName[ui.confirm.name] || null
            if (ui.confirm.kind === "menu") content.openMenu(t)
            else content.askAbout(t, ui.confirm)
        }
        if (ui.menu === "more") content.openMore()
        if (Array.isArray(ui.keys)) content.replayKeys(ui.keys)
    }
    function sizeWindow(shot) {
        if (shot.kind !== "panel") { window.height = Math.ceil(barColumn.implicitHeight) + 24; return }
        window.height = Math.max(Math.ceil(content.implicitHeight) + 28, Math.ceil(content.popupBottom()) + 24)
    }

    FileView {
        path: Quickshell.env("LUMENAIRE_PLAN")
        onLoaded: {
            const p = JSON.parse(text())
            const list = []
            for (const pal of p.palettes) {
                for (const f of p.fixtures) for (const w of p.widths) list.push({ kind: "panel", palette: pal, fixture: f, width: w, name: pal.name + "-" + f.name + "-" + w })
                list.push({ kind: "bar", palette: pal, name: pal.name + "-bar" })
            }
            harness.plan = p
            harness.shots = list
            harness.barStates = p.fixtures
            // Give Color's own startup reads of the live theme time to land
            // before the harness palette replaces them.
            startDelay.start()
        }
    }
    Timer { id: startDelay; interval: 800; onTriggered: { harness.step = 0; harness.configure(harness.shots[0]); capture.start() } }

    Lights.FakeService { id: service }

    Window {
        id: window
        visible: true
        width: 468
        height: 900
        color: Commons.Color.background

        // Opaque desktop stand-in under the popup: glass themes give popups a
        // translucent background, which grabToImage would keep as alpha.
        Rectangle {
            id: area
            anchors.fill: parent
            color: Commons.Color.background
            Ui.BorderSurface {
                id: popupSurface
                anchors.fill: parent
                color: Commons.Color.popups.background
                radius: Style.cornerRadius
                borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
                Lights.LightsContent {
                    id: content
                    anchors.fill: parent
                    anchors.margins: 14
                    maxHeight: 100000
                    service: service
                }
            }
        }

        // Bar strip: one bar per fixture state, each on its own FakeService.
        Rectangle {
            id: barBox
            visible: false
            anchors.fill: parent
            color: Commons.Color.background
            Column {
                id: barColumn
                x: 12
                y: 12
                spacing: 6
                Repeater {
                    model: harness.barStates
                    Row {
                        id: barRow
                        required property var modelData
                        spacing: 12
                        property Lights.FakeService svc: Lights.FakeService {}
                        property QtObject fakeBar: QtObject {
                            property color foreground: Commons.Color.bar.text
                            property color barForeground: Commons.Color.bar.text
                            property color background: Commons.Color.bar.background
                            property color urgent: Commons.Color.bar.active
                            property string fontFamily: Style.fontFamily
                            property string position: "top"
                            property bool vertical: false
                            property int barSize: Style.bar.sizeHorizontal
                            property bool foregroundAnimationEnabled: false
                            property var shell: ({ serviceFor: function(id) { return barRow.svc } })
                            function showTooltip(target, text) {}
                            function hideTooltip(target) {}
                            function registerClickTarget(target) {}
                            function unregisterClickTarget(target) {}
                            function requestPopout(owner) {}
                            function releasePopout(owner) {}
                            function switchPanelFrom(owner, direction) { return false }
                            function moduleWidgets(id) { return [] }
                            function run(cmd) {}
                        }
                        Component.onCompleted: svc.load(modelData.data, harness.plan.themes, harness.plan.fixturesDir)
                        Text {
                            width: 150
                            anchors.verticalCenter: parent.verticalCenter
                            text: barRow.modelData.name
                            color: Commons.Color.foreground
                            font.family: Style.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }
                        Rectangle {
                            width: 120
                            height: Style.bar.sizeHorizontal
                            color: Commons.Color.bar.background
                            border.width: 1
                            border.color: Style.normalBorderColor
                            Lights.BarWidget {
                                id: widget
                                anchors.centerIn: parent
                                height: parent.height
                                bar: barRow.fakeBar
                                Component.onCompleted: Qt.callLater(function() { console.log("BAR " + barRow.modelData.name + " | " + widget.readout + " | " + widget.tooltip) })
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: capture
        interval: 350
        repeat: true
        property int phase: 0
        onTriggered: {
            try { tick() } catch (e) { console.error("ERROR harness: " + e); Qt.quit() }
        }
        // Phase 0 opens the fixture's popups on the laid-out page, phase 1
        // sizes the window to the content (and any popup), phase 2 grabs the
        // whole window, popups included.
        function tick() {
            const shot = harness.shots[harness.step]
            if (phase === 0) { harness.openPopups(shot); phase = 1; return }
            if (phase === 1) { harness.sizeWindow(shot); phase = 2; return }
            phase = 0
            capture.stop()
            window.contentItem.grabToImage(function(result) {
                if (!result.saveToFile(harness.plan.captureDir + "/" + shot.name + ".png")) throw new Error("Capture failed " + shot.name)
                if (shot.kind === "panel") console.log("SHOT " + shot.name + " " + window.width + "x" + window.height + " calls=" + JSON.stringify(service.calls))
                harness.step++
                if (harness.step === harness.shots.length) { console.log("LUMENAIRE_UI_CAPTURE_OK"); Qt.quit(); return }
                harness.configure(harness.shots[harness.step])
                capture.start()
            })
        }
    }
}
