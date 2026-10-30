#!/usr/bin/env bash
# run.sh — the RAM drift (lib/pc-lights/ramdrift.py, docs/THEMES.md "RAM drift").
#
#   tests/ramdrift/run.sh [--engine PATH] [--real-openrgb]
#
# 1. check.py: the frame math, params, and the animator against
#    fake_openrgb.py (a fake SDK server with two "ENE DRAM" sticks).
#    --real-openrgb adds the real openrgb started with --nodetect (it detects
#    no hardware at all) for the SDK handshake and its idle CPU.
# 2. The engine hooks in a fixture $HOME with the unit "installed":
#    systemctl, openrgb, logger and the Lian Li half are stubbed, so nothing
#    reaches a unit, the SMBus or the daemon. An apply of a drifting theme
#    stops the unit before OpenRGB and starts it after, with its params; its
#    static colours are frame 0; a theme without drift, and the lights off,
#    leave it stopped; render never touches it; a preview's restore and a
#    detect probe start it again; a held openrgb.lock refuses OpenRGB.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
engine=$repo/bin/lumenaire real=''
while (( $# )); do
  case $1 in
    --engine) engine=$(readlink -f "$2"); shift 2 ;;
    --real-openrgb) real=--real-openrgb; shift ;;
    *) sed -n '2,/^set -uo/{/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
LIB=$(dirname "$engine")/../lib/pc-lights
passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }

# ---- 1. python --------------------------------------------------------------------------
if python3 "$here/check.py" "$LIB" $real; then ok "check.py"; else bad "check.py (see above)"; fi

# ---- 2. the engine hooks ------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home C=$H/.config/pc-lights K=$H/.cache/pc-lights
mkdir -p "$C/themes/drift" "$C/themes/still" "$K" "$H/.config/systemd/user"
cp "$repo/systemd/lumenaire-ram-drift.service" "$H/.config/systemd/user/"
# v2 themes (no profile: the legacy OpenRGB constants, 8 LEDs per stick)
cat >"$C/themes/drift/theme.json" <<'EOF'
{"gpu": "ff1a70", "board": "ff2a80", "fans": {"top": "ff5a30", "bottom": "ff1a70"}, "rings": "ff1a70",
 "strimers": {"mode": "Drizzling", "colors": ["ff5a30", "ff1a70", "ff5a30", "ff1a70", "ff5a30", "ff1a70"], "speed": 0, "direction": "Clockwise"},
 "ram": {"gradient": ["ff6a2a", "ff1a70", "9020d8", "ff4a9a"], "span": "across",
         "drift": {"period": 120, "window": 0.5, "fps": 4}}}
EOF
cat >"$C/themes/still/theme.json" <<'EOF'
{"gpu": "ff1a70", "board": "ff2a80", "fans": {"top": "ff5a30", "bottom": "ff1a70"}, "rings": "ff1a70",
 "strimers": {"mode": "Drizzling", "colors": ["ff5a30", "ff1a70", "ff5a30", "ff1a70", "ff5a30", "ff1a70"], "speed": 0, "direction": "Clockwise"},
 "ram": {"gradient": ["ff6a2a", "ff1a70"], "span": "across"}}
EOF
echo drift >"$C/scheme"; echo on >"$C/lights"; echo on >"$C/screens"
# The engine runs OpenRGB as "timeout 120 openrgb ...": timeout execs a program
# from PATH, never a shell function, so the stub MUST be an executable first on
# PATH, or the real OpenRGB would run (probe the SMBus, write the real lights).
mkdir -p "$T/bin"
cat >"$T/bin/openrgb" <<'STUB'
#!/usr/bin/env bash
echo "openrgb $*" >>"$HOME/stub.log"
if [[ $* == *--list-devices* ]]; then
  printf '0: ENE DRAM\n  Type:           DRAM\n  Location:       I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-15), address 0x71\n\n'
  printf '1: ENE DRAM\n  Type:           DRAM\n  Location:       I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-15), address 0x73\n\n'
  printf '2: X870E AORUS MASTER X3D\n  Type:           Motherboard\n'
fi
exit 0
STUB
cat >"$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl(bin) $*" >>"$HOME/stub.log"
exit 1
STUB
chmod +x "$T/bin/openrgb" "$T/bin/systemctl"
[[ $(PATH="$T/bin:$PATH" command -v openrgb) == "$T/bin/openrgb" ]] || { echo "run.sh: cannot shadow openrgb; refusing to run" >&2; exit 2; }
cat >"$T/over.sh" <<'EOF'
# Sourced by the engine (PCL_TEST_OVERRIDES): no units, no OpenRGB, no daemon.
logger() { :; }
systemctl() {
  echo "systemctl $*" >>"$HOME/stub.log"
  if [[ $* == *is-active* ]]; then [[ -f $HOME/drift-active ]]; return; fi
  return 0
}
systemd-run() { echo "blocked: systemd-run $*" >>"$HOME/stub.log"; return 1; }
# openrgb is the fake executable first on PATH (the engine runs it through
# timeout, which a shell function can't stub); refuse to go on otherwise.
[[ $(command -v openrgb) == "$PCL_FAKE_BIN/openrgb" ]] || { echo "over.sh: openrgb is not the fake" >&2; exit 97; }
daemon_call() { return 1; }
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
# The Lian Li half is out of scope here: skip it.
backend_probe() { BE_STATE[$1]='{"state":"skipped","message":"test"}'; [[ $1 == openrgb ]] && BE_STATE[$1]='{"state":"ok"}'; return 0; }
backend_skipped() { [[ $1 == lianli ]]; }
backend_state() { if [[ $1 == lianli ]]; then echo skipped; else echo ok; fi; }
preview_yield() { :; }
if [[ -n ${T_CALL:-} ]]; then eval "$T_CALL"; exit $?; fi
EOF
eng() {
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" PATH="$T/bin:$PATH" PCL_FAKE_BIN="$T/bin" \
    PCL_TEST_OVERRIDES="$T/over.sh" PCL_ORGB_WAIT=2 "$engine" "$@"
}
stub() { cat "$H/stub.log" 2>/dev/null; }
reset() { : >"$H/stub.log"; rm -f "$H/drift-active"; }

# An apply of the drifting theme.
reset
eng apply-openrgb >/dev/null 2>"$T/err" || bad "apply-openrgb failed: $(cat "$T/err")"
mapfile -t L <"$H/stub.log"
first_orgb=$(grep -n '^openrgb' "$H/stub.log" | head -1 | cut -d: -f1)
first_stop=$(grep -n 'stop lumenaire-ram-drift' "$H/stub.log" | head -1 | cut -d: -f1)
[[ -n $first_stop && -n $first_orgb && $first_stop -lt $first_orgb ]] &&
  ok "apply: the unit is stopped before the first OpenRGB call (the listing)" || bad "apply: no stop before OpenRGB: ${L[*]}"
n_orgb=$(grep -c '^openrgb' "$H/stub.log") n_stop=$(grep -c 'stop lumenaire-ram-drift' "$H/stub.log")
[[ $n_orgb == 2 && $n_stop == 2 ]] && ok "apply: a stop before each of the 2 OpenRGB calls" || bad "apply: $n_orgb openrgb, $n_stop stops"
[[ ${L[-1]} == "systemctl --user start --no-block lumenaire-ram-drift.service" ]] &&
  ok "apply: the unit is started last" || bad "apply: last call is '${L[-1]}'"
jq -e '.stops == ["ff6a2a","ff1a70","9020d8","ff4a9a"] and .count == 2 and .ids == ["0","1"] and .period == 120
       and .locations == ["I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-15), address 0x71",
                           "I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-15), address 0x73"]' "$K/ram-drift.json" >/dev/null &&
  ok "apply: ram-drift.json has the stops, the stick ids and their locations" || bad "apply: ram-drift.json: $(cat "$K/ram-drift.json" 2>&1)"
want=$(python3 -c "
import sys; sys.path.insert(0, '$LIB'); import ramdrift
f = ramdrift.frame(['ff6a2a', 'ff1a70', '9020d8', 'ff4a9a'], 16, 0.0, 0.5)
h = ['%02X%02X%02X' % c for c in f]
print('-d 0 -m direct -c ' + ','.join(h[:8]) + ' -d 1 -m direct -c ' + ','.join(h[8:]))")
grep -q -- "$want" "$H/stub.log" && ok "apply: the static RAM colours are frame 0 of the drift" || bad "apply: RAM args differ from frame 0"
[[ -f $K/openrgb.lock ]] && ok "apply: openrgb.lock is used" || bad "apply: no openrgb.lock"

# Lights off: stopped, not started, params gone.
reset; echo off >"$C/lights"
eng apply-openrgb >/dev/null 2>&1
grep -q 'start' "$H/stub.log" && bad "off: the unit was started" || ok "off: the unit is not started"
grep -q 'stop lumenaire-ram-drift' "$H/stub.log" && ok "off: the unit is stopped" || bad "off: no stop"
[[ ! -e $K/ram-drift.json ]] && ok "off: ram-drift.json removed" || bad "off: ram-drift.json left behind"
echo on >"$C/lights"

# A theme without drift: stopped, not started; its args unchanged by the feature.
reset; echo still >"$C/scheme"
eng apply-openrgb >/dev/null 2>&1
grep -q 'start' "$H/stub.log" && bad "no drift: the unit was started" || ok "no drift: the unit is not started"
[[ ! -e $K/ram-drift.json ]] && ok "no drift: no ram-drift.json" || bad "no drift: ram-drift.json exists"
grep -q -- '-d 0 -m direct -c FF6A2A,FF652F,FF5F33,FF5A38,FF553D,FF4F41,FF4A46,FF454B -d 1 -m direct -c FF3F4F' "$H/stub.log" && ok "no drift: the plain gradient, as before" ||
  bad "no drift: unexpected RAM args: $(grep -- '-d 0' "$H/stub.log")"
echo drift >"$C/scheme"

# Unit not installed (another machine, or before install --units): no systemctl at all.
reset; mv "$H/.config/systemd/user/lumenaire-ram-drift.service" "$T/unit.bak"
eng apply-openrgb >/dev/null 2>"$T/err"
grep -q systemctl "$H/stub.log" && bad "not installed: systemctl was called" || ok "not installed: no systemctl calls"
grep -q "not installed" "$T/err" && ok "not installed: says so, the RAM keeps frame 0" || bad "not installed: no note"
mv "$T/unit.bak" "$H/.config/systemd/user/lumenaire-ram-drift.service"

# render: never stops or starts anything, and prints the drift line.
reset
eng render drift >"$T/render" 2>"$T/err" || bad "render failed: $(cat "$T/err")"
grep -q systemctl "$H/stub.log" && bad "render: touched the unit" || ok "render: no systemctl"
grep -q '^openrgb' "$H/stub.log" && bad "render: ran openrgb" || ok "render: no openrgb"
grep -q '^# ram drift: ff6a2a ff1a70 9020d8 ff4a9a over 2 sticks, period 120 s' "$T/render" &&
  ok "render: the '# ram drift' line" || bad "render: no drift line: $(tail -2 "$T/render")"
eng render still >"$T/render2" 2>&1
grep -q 'ram drift' "$T/render2" && bad "render: a drift line for a still theme" || ok "render: no drift line without drift"

# Validation: a bad drift is refused before anything runs.
reset
jq '.ram.drift.period = 5' "$C/themes/drift/theme.json" >"$T/bad.json"
mkdir -p "$C/themes/bad" && cp "$T/bad.json" "$C/themes/bad/theme.json"
eng render bad >/dev/null 2>"$T/err" && bad "validation: a bad drift rendered" ||
  { grep -q 'ram.drift.period must be a number 20-3600' "$T/err" && ok "validation: a bad drift is refused, with the reason" || bad "validation: $(cat "$T/err")"; }
rm -rf "$C/themes/bad"

# The preview's restore (ram_drift_resume): starts the drift for the active theme.
reset; rm -f "$K/ram-drift.json"; echo "0 1" >"$K/ram-ids"
T_CALL='ram_drift_resume "$(scheme_file)"' eng status >/dev/null 2>&1
grep -q 'start --no-block lumenaire-ram-drift' "$H/stub.log" && [[ -s $K/ram-drift.json ]] &&
  ok "preview restore: the drift starts again" || bad "preview restore: $(stub)"
# A preview shows another theme: be_openrgb_preview stops the drift first.
reset
T_CALL='openrgb_preview_args "$(scheme_file)" >"$HOME/pv.args"; be_openrgb_preview "$(scheme_file)" "$HOME/pv.args"' eng status >/dev/null 2>&1
mapfile -t L <"$H/stub.log"
[[ ${L[0]} == *is-active* && ${L[1]} == *"stop lumenaire-ram-drift"* && ${L[2]} == openrgb* ]] &&
  ok "preview: stop, then OpenRGB" || bad "preview: ${L[*]}"

# detect's listing: stops the drift, lists, starts it again (it was running).
reset; touch "$H/drift-active"
T_CALL='detect_openrgb_list >/dev/null' eng status >/dev/null 2>&1
mapfile -t L <"$H/stub.log"
[[ ${L[1]} == *"stop lumenaire-ram-drift"* && ${L[2]} == "openrgb --list-devices" && ${L[-1]} == *"start --no-block lumenaire-ram-drift"* ]] &&
  ok "detect: stop, list, start again" || bad "detect: ${L[*]}"
reset
T_CALL='detect_openrgb_list >/dev/null' eng status >/dev/null 2>&1
grep -q start "$H/stub.log" && bad "detect: started a drift that wasn't running" || ok "detect: a drift that wasn't running stays stopped"

# A held openrgb.lock (a stray animator): OpenRGB is refused, the apply fails loudly.
reset
flock "$K/openrgb.lock" sleep 8 & holder=$!
sleep 0.3
eng apply-openrgb >/dev/null 2>"$T/err" && bad "held lock: the apply went ahead" ||
  { grep -q 'OpenRGB is busy' "$T/err" && ok "held lock: no OpenRGB, a clear error" || bad "held lock: $(cat "$T/err")"; }
grep -q '^openrgb' "$H/stub.log" && bad "held lock: openrgb ran" || ok "held lock: openrgb never ran"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# The editor keeps the key: a v3 theme with a drift, one stop edited, saved.
reset
cp "$repo/tests/fixtures/profile.example-desktop.json" "$C/profile.json"
mkdir -p "$C/themes/dusk"
jq '.roles.ram = {"gradient": ["ff6a2a", "ff1a70", "9020d8", "ff4a9a"], "span": "across", "drift": {"period": 90}}' \
  "$repo/tests/theme/sakura.v3.json" >"$C/themes/dusk/theme.json"
# its screens' media: empty stand-ins
jq -r '[.. | objects | .path? | strings] + [.templates[]? | strings] | .[]' "$C/themes/dusk/theme.json" |
  while read -r p; do mkdir -p "$C/themes/dusk/$(dirname "$p")"; : >"$C/themes/dusk/$p"; done
jq -r '[.. | objects | .clips? | arrays | .[]] | .[]' "$C/themes/dusk/theme.json" |
  while read -r p; do mkdir -p "$C/themes/dusk/$p"; : >"$C/themes/dusk/$p/1.mp4"; done
edt() { env HOME="$H" XDG_CONFIG_HOME="$H/.config" PATH="$T/bin:$PATH" PCL_FAKE_BIN="$T/bin" PCL_TEST_OVERRIDES="$T/over.sh" "$engine" theme "$@"; }
edt edit dusk --json >"$T/ed1" 2>"$T/ed.err" || bad "editor: edit failed: $(tail -2 "$T/ed.err")"
edt set dusk /roles/ram/gradient/1 ff2a80 --json >"$T/ed2" 2>>"$T/ed.err" || bad "editor: set failed: $(tail -2 "$T/ed.err")"
edt save dusk --no-apply --json >"$T/ed3" 2>>"$T/ed.err" || bad "editor: save failed: $(tail -2 "$T/ed.err")"
jq -e '.roles.ram == {"gradient": ["ff6a2a", "ff2a80", "9020d8", "ff4a9a"], "span": "across", "drift": {"period": 90}}' \
  "$C/themes/dusk/theme.json" >/dev/null && ok "editor: a stop edited and saved, the drift kept" ||
  bad "editor: ram after save: $(jq -c .roles.ram "$C/themes/dusk/theme.json")"
jq -e '[.. | objects | select(.shape?.path? == "/roles/ram" and .shape.value == "gradient" and .span.value == "across")] | length == 1' "$T/ed1" >/dev/null 2>&1 &&
  ok "editor: shows the drifting ram as a gradient" || bad "editor: the ram view: $(head -c 300 "$T/ed1")"
grep -q systemctl "$H/stub.log" 2>/dev/null && bad "editor: touched a unit" || ok "editor: no unit touched"
rm -f "$C/profile.json"

# ram-drift status
eng ram-drift status >"$T/st" 2>&1
grep -q '^unit: lumenaire-ram-drift.service' "$T/st" && ok "ram-drift status" || bad "ram-drift status: $(cat "$T/st")"

echo
echo "passed $passed, failed $failed"
(( failed == 0 ))
