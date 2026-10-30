#!/bin/bash
# Lights and screens switches queue behind a running change instead of
# being refused (turning both off in a row). EngineState alone, offscreen.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
command -v quickshell >/dev/null || { echo "queue-power: quickshell not found; skipped"; exit 0; }
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
mkdir -p "$w/root/Lights"
for n in Ui Commons; do ln -s "/usr/share/omarchy/shell/$n" "$w/root/$n"; done
cp "$repo"/*.qml "$repo"/*.js "$w/root/Lights/"
cat >"$w/root/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "Lights" as Lights
ShellRoot {
    Lights.EngineState { id: e }
    function log(m) { console.log("QP " + m) }
    Component.onCompleted: {
        e.status = { busy: { op: "pick", theme: "sakura", since: 0 }, pending: [], daemon_unit: "active" }
        log("busy lights=" + e.canChange("lights") + " screens=" + e.canChange("screens")
            + " clips=" + e.canChange("clips") + " schedule=" + e.canChange("schedule") + " theme=" + e.canChange("theme"))
        e.status = { busy: null, pending: [], daemon_unit: "active" }
        log("idle lights=" + e.canChange("lights") + " schedule=" + e.canChange("schedule"))
        Qt.quit()
    }
}
QML
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_BACKEND=software \
  timeout 60 quickshell -p "$w/root" --no-color >"$w/out.log" 2>&1 || true
fails=0
ck() { if grep -q "QP $1" "$w/out.log"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
ck "busy lights=true screens=true clips=false schedule=false theme=true" "a running change: lights and screens queue, clips and schedule wait"
ck "idle lights=true schedule=true" "idle: everything can change"
if (( fails )); then grep -v 'Socket error\|IPC server' "$w/out.log" | tail -20; fi
echo "queue-power: $((2 - fails)) of 2 passed"
(( fails == 0 ))
