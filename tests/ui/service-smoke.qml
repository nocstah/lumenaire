import QtQuick
import Quickshell
import "Lights" as Lights
import "Lights/Format.js" as Format

// tests/ui/service-smoke.sh: the real Service.qml, its screen-editor API
// (plan §5.4) and its desktop wallpaper API (contract v1.4) driven step by
// step against tests/ui/fake-engine. Each step logs one "SMOKE" line the
// script checks.
ShellRoot {
    id: t
    property int stage: 0
    property int waited: 0
    property var s: svc
    property var before: null
    property int watchTicks: 0
    Lights.Service { id: svc }
    function log(m) { console.log("SMOKE " + m) }
    Component.onCompleted: { svc.manifest = ({ barWidget: { defaults: {} } }); tick.start() }
    Timer {
        id: tick
        interval: 200
        repeat: true
        onTriggered: {
            t.waited += 1
            if (t.waited > 150) { t.log("TIMEOUT at stage " + t.stage); Qt.quit(); return }
            const s = svc
            switch (t.stage) {
            case 0: if (s.ready && s.editorAvailable) { t.log("ready v_minor=" + s.status.v_minor); s.editTheme("sakura-2"); t.stage = 1 } break
            case 1: if (s.editor && s.screensView) { t.log("view roles=" + s.screensView.screens.length + " editable=" + s.screensEditable + " state=" + s.screensState + " jobs=" + s.mediaJobs.length); s.openScreen("screen.fan3"); s.listMedia("library", "screen.fan3", "", 0); t.stage = 2 } break
            case 2: if (s.mediaList && s.mediaListState === "idle") { t.log("list items=" + s.mediaList.items.length + " query=" + JSON.stringify(s.mediaQuery)); s.frameAt("/x/planet37.mp4", 12.4); t.stage = 3 } break
            case 3: if (s.frame) { t.log("frame for=" + s.frame.for + " src=" + s.frame.src_w + "x" + s.frame.src_h); s.prepareMedia("screen.fan3", "/x/planet37.mp4", { crop: [656, 236, 608, 608], time: 12.4, then: "set", thumb: "/t.webp" }); t.stage = 4 } break
            case 4: { const j = s.jobFor("screen.fan3"); if (j) { t.log("job " + j.id + " state=" + j.state + " thumb=" + s.jobThumb(j.id)); s.setScreenMedia("screen.fan3", "media/fan-a.mp4", false); s.clipMove("screen.pump", 0, 1); s.setRotation("screen.pump", 900, true); s.setScreenMode("screen.main", "template"); s.clipAdd("screen.pump", "media/x.mp4", 2); s.clipRemove("screen.pump", 1); s.setScreenBrightness("screen.fan3", 60); t.stage = 5 } } break
            case 5: if (!s.editPending && s.draftQueue.length === 0) { t.log("drained note=" + JSON.stringify(s.mediaNote) + " state=" + s.editorState); s.cancelMedia("j-1790000400123-4821"); s.setScreenBrightness("screen.fan3", null); t.stage = 6 } break
            case 6: if (!s.editPending) { t.log("cancelled jobFor=" + JSON.stringify(s.jobFor("screen.fan3"))); s.closeScreen(); s.closeEditor(true); t.stage = 7 } break
            case 7: {
                t.log("closed screensView=" + s.screensView + " state=" + s.screensState)
                // The desktop wallpaper: the status as the row's view, then another theme's page.
                t.log("desktop available=" + s.desktopAvailable + " home=" + s.desktopHome + " stub=" + JSON.stringify(s.desktopCurrent ? s.desktopCurrent.has_animated : "none"))
                s.loadDesktop("hellfire")
                t.stage = 8
            } break
            case 8: if (s.desktop && s.desktopState === "idle") {
                t.log("desktop view theme=" + s.desktop.theme + " has_animated=" + s.desktop.has_animated + " pause=" + s.desktop.settings.pause_while_active
                      + " line=" + Format.desktopAnimatedLine(s.desktop, s.desktop.theme === s.desktopHome))
                s.setDesktop("pause", false, "hellfire")
                t.log("desktop optimistic pause=" + s.desktop.settings.pause_while_active)
                s.setDesktop("resume_after_idle", 10, "hellfire")
                s.setDesktop("while", "still", "hellfire")
                t.log("desktop invalid=" + s.setDesktop("resume", 999, "hellfire") + "," + s.setDesktop("colour", "red", "hellfire"))
                t.stage = 9
            } break
            case 9: if (!s.desktopBusy && s.desktopQueue.length === 0 && Object.keys(s.desktopLocal).length === 0) {
                t.log("desktop settled settings=" + JSON.stringify(s.desktop.settings) + " custom=" + Format.desktopCustom(s.desktop))
                s.setDesktop("animated", false, "nope")
                t.stage = 10
            } break
            case 10: if (!s.desktopBusy && s.desktopError !== "") {
                t.log("desktop error=" + s.desktopError + " local=" + JSON.stringify(s.desktopLocal))
                s.resetDesktop("hellfire")
                t.stage = 11
            } break
            case 11: if (!s.desktopBusy && s.desktopQueue.length === 0 && Object.keys(s.desktopLocal).length === 0) {
                t.log("desktop reset settings=" + JSON.stringify(s.desktop.settings) + " custom=" + Format.desktopCustom(s.desktop) + " error=" + JSON.stringify(s.desktopError))
                // The engine rewrites its cache of the desktop: the watcher reads the page's view again.
                t.before = s.desktopRead
                Quickshell.execDetached(["sh", "-c", "echo '{}' > \"$0\"", s.cacheDir + "/desktop/state.json"])
                t.stage = 12
            } break
            case 12: {
                t.watchTicks += 1
                if (s.desktopRead !== t.before || t.watchTicks > 25) {
                    t.log("desktop watch reread=" + (s.desktopRead !== t.before))
                    s.closeDesktop()
                    t.log("desktop closed state=" + s.desktopState + " view=" + s.desktop)
                    t.log("DONE")
                    Qt.quit()
                }
            } break
            }
        }
    }
}
