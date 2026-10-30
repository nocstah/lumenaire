#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# run.sh — the desktop wallpaper tests (lib/pc-lights/desktop.sh, "lumenaire
# desktop"): the theme mapping (checked against what omarchy_pair queues),
# the defaults and the exact --json view, set with its validation and exit
# codes, applying only for the desktop's theme, sync (play and stop,
# ownership: a clip the user picked is never touched, "animated" off acts
# like no animated version, no wallpaper leaves the playback alone), the
# pause setters sent only on a change, toggle both ways with its OSD, the
# migration from the standalone script's state, the shell down or the plugin
# missing (exit 0, available false), the lock, status --json v1.4 (the
# desktop block, no IPC, the 40 ms median), portrait monitors (a theme's
# <still>.portrait clip per monitor, the user's per-screen clips left alone,
# overrides cleared on a switch and when still), the monitor watcher, the
# motion-wallpaper-theme shim and install --desktop.
#
#   tests/desktop/run.sh [engine]   (default: the repo's bin/lumenaire)
#
# Everything runs against a fixture $HOME with fakes first in PATH:
# fake-omarchy-shell (the plugin's IPC against a status.json it changes; -q
# prints nothing, like the real one), fake-omarchy (records the OSD),
# fake-hyprctl (the monitors, from $HOME/monitors.json), fake-socat (the
# event socket, from $HOME/socat-script) and a logger that writes a file. OMARCHY_PATH points into the fixture, so even
# the real omarchy-shell would stop before reaching the shell. Nothing here
# reaches the real plugin, the shell, the journal or the user's units.
# KEEP_FIXTURE=1 keeps the fixture.
# shellcheck disable=SC2016  # jq filters and the stand-in scripts are single-quoted on purpose
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
engine=$(readlink -f "${1:-$repo/bin/lumenaire}")
[[ -x $engine ]] || { echo "run.sh: no engine at $engine" >&2; exit 2; }
root=$(mktemp -d)
trap '[[ -n ${KEEP_FIXTURE:-} ]] || rm -rf "$root"' EXIT
passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || printf '     %s\n' "$2" | head -c 900; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
jcheck() {   # jcheck <name> <jq filter> <json> [jq args...]
  local n=$1 f=$2 j=$3; shift 3
  if jq -e "$@" "$f" >/dev/null 2>&1 <<<"$j"; then ok "$n"; else bad "$n" "$(jq -c . 2>&1 <<<"$j" | head -c 700)"; fi
}

H=$root/home FB=$root/bin STOCK=$root/omarchy
C=$H/.config/pc-lights K=$H/.cache/pc-lights CUR=$H/.local/state/omarchy/current OT=$H/.config/omarchy/themes
OLD=$H/.local/state/motion-wallpaper-theme
mkdir -p "$FB"
ln -s "$here/fake-omarchy-shell" "$FB/omarchy-shell"
ln -s "$here/fake-omarchy" "$FB/omarchy"
ln -s "$here/fake-hyprctl" "$FB/hyprctl"
ln -s "$here/fake-socat" "$FB/socat"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$HOME/logger.log"\n' >"$FB/logger"
chmod +x "$FB/logger"

# The plugin's status before a test changes it (the fake starts from this).
MW_DEFAULT='{"enabled": false, "videoPath": "", "videoFileExists": false, "output": "all",
  "pauseWhileActive": true, "resumeAfterIdle": 5, "whileActive": "freeze", "userActive": false, "screenVideos": {}}'
mw_status() { jq -n --argjson d "$MW_DEFAULT" "\$d + ($1)" >"$H/mw/status.json"; }
mw() { jq -c "${1:-.}" "$H/mw/status.json"; }
mw_mode() { echo "$1" >"$H/mw/mode"; }
# The status as the plugin reports it (screens, activeScreens), not recorded.
mwv() { HOME=$H FAKE_NOLOG=1 "$FB/omarchy-shell" motion-wallpaper status; }

# omarchy_at <slug> <wallpaper>: the Omarchy theme and wallpaper now, as
# Omarchy leaves them: theme.name, and background -> the working copy.
omarchy_at() {
  echo "$1" >"$CUR/theme.name"
  ln -sfn "$CUR/theme/backgrounds/$2" "$CUR/background"
}

# A fresh fixture: three case themes, a map where sakura and sakura-light
# both pair with sakura, wallpapers with animated versions in the theme's own
# folder (sakura-light: mp4, sakura: webm), a stock theme (gruvbox: mkv under
# OMARCHY_PATH), one only in Omarchy's working copy (4-glow), none for
# 2-dune, and the plugin stopped with no clip.
fresh() {
  if [[ -f $H/mw/calls.log ]]; then cat "$H/mw/calls.log" >>"$root/all-calls.log"; fi
  rm -rf "$H"
  mkdir -p "$C/themes" "$K" "$CUR/theme/backgrounds/.animated" "$H/mw" "$H/Videos"
  for t in sakura hellfire arctic; do
    mkdir -p "$C/themes/$t"; echo '{"_about": "desktop test"}' >"$C/themes/$t/theme.json"
  done
  echo sakura >"$C/scheme"; echo sakura >"$C/day-scheme"; echo on >"$C/lights"; echo on >"$C/screens"
  echo '{"_default": "auto", "sakura": "sakura", "sakura-light": "sakura", "nord": "arctic", "ghost": "nosuch"}' >"$C/omarchy-map.json"
  for b in 1-moon.jpg 2-dune.jpg 3-reef.png 4-glow.jpg; do : >"$CUR/theme/backgrounds/$b"; done
  mkdir -p "$OT/sakura-light/backgrounds/.animated" "$OT/sakura/backgrounds/.animated" "$STOCK/themes/gruvbox/backgrounds/.animated"
  : >"$OT/sakura-light/backgrounds/.animated/1-moon.mp4"
  : >"$OT/sakura-light/backgrounds/.animated/1-moon.portrait.mp4"
  : >"$OT/sakura/backgrounds/.animated/1-moon.webm"
  : >"$STOCK/themes/gruvbox/backgrounds/.animated/3-reef.mkv"
  : >"$CUR/theme/backgrounds/.animated/4-glow.mp4"
  : >"$CUR/theme/backgrounds/.animated/1-moon.mp4"   # the working copy's: the theme's own folder wins
  : >"$H/Videos/mine.mp4"
  omarchy_at sakura-light 1-moon.jpg
  mw_status '{}'
  : >"$H/mw/calls.log"
}
CLIP_SL=$OT/sakura-light/backgrounds/.animated/1-moon.mp4
CLIP_SLP=$OT/sakura-light/backgrounds/.animated/1-moon.portrait.mp4
CLIP_S=$OT/sakura/backgrounds/.animated/1-moon.webm
CLIP_G=$STOCK/themes/gruvbox/backgrounds/.animated/3-reef.mkv
CLIP_W=$CUR/theme/backgrounds/.animated/4-glow.mp4
MINE=$H/Videos/mine.mp4

lum() { HOME=$H PATH=$FB:$PATH OMARCHY_PATH=$STOCK "$engine" "$@" 2>>"$root/stderr.log"; }
# Every call of the run also lands in all-calls.log, for the -q check at the end.
reset_calls() { cat "$H/mw/calls.log" >>"$root/all-calls.log" 2>/dev/null || true; : >"$H/mw/calls.log"; }
ncalls() { grep -c . "$H/mw/calls.log" || true; }
S=$'-\tmotion-wallpaper\tstatus'
Q() { local IFS=$'\t'; printf 'q\tmotion-wallpaper\t%s' "$*"; }
# calls_are <name> <line...>: the IPC calls since reset_calls, exactly.
calls_are() {
  local n=$1 want got; shift
  want=$(printf '%s\n' "$@"); got=$(cat "$H/mw/calls.log")
  if [[ $got == "$want" ]]; then ok "$n"; else bad "$n" "got: $(tr '\t' ' ' <<<"$got" | paste -sd'|')"; fi
}
setters() { grep -cE $'\tset(PauseWhileActive|ResumeAfterIdle|WhileActive)\t' "$H/mw/calls.log" || true; }
owned() { cat "$K/desktop/owned" 2>/dev/null || true; }
osd_last() { tail -n1 "$H/osd.log" 2>/dev/null | tr '\t' ' '; }
dj() { jq -c "${1:-.}" "$C/desktop.json" 2>/dev/null || echo null; }

echo "engine: $engine"
echo "fixture: $root"

# ---- 0. the fakes are live (abort before anything could reach the shell) -----
fresh
lum desktop --json >/dev/null || true
if [[ $(cat "$H/mw/calls.log") != "$S" ]]; then
  echo "ABORT: the fake omarchy-shell did not see exactly one status read without -q; refusing to run anything that could reach the shell" >&2
  exit 1
fi
ok "the fake omarchy-shell answers (status without -q)"

# ---- 1. mapping ------------------------------------------------------------------
fresh
for c in sakura-light:sakura sakura:sakura nord:arctic gruvbox:omarchy-gruvbox ghost:omarchy-ghost; do
  slug=${c%%:*} want=${c#*:}
  omarchy_at "$slug" 1-moon.jpg
  jcheck "mapping: Omarchy $slug -> $want" '.theme == $w and .omarchy_theme == $s' "$(lum desktop --json)" --arg w "$want" --arg s "$slug"
  jcheck "mapping: status --json agrees ($slug -> $want)" '.desktop.theme == $w' "$(lum status --json)" --arg w "$want"
done
jq '._default = "hellfire"' "$C/omarchy-map.json" >"$C/map.tmp" && mv "$C/map.tmp" "$C/omarchy-map.json"
omarchy_at gruvbox 3-reef.png
jcheck "mapping: an unmapped slug takes an existing _default" '.theme == "hellfire"' "$(lum desktop --json)"
rm -f "$C/omarchy-map.json"
omarchy_at sakura-light 1-moon.jpg
jcheck "mapping: no omarchy-map.json -> omarchy-<slug>" '.theme == "omarchy-sakura-light"' "$(lum desktop --json)"
rm -f "$CUR/theme.name"
echo hellfire >"$C/scheme"
v=$(lum desktop --json)
jcheck "mapping: no Omarchy theme -> the active case theme, omarchy_theme null" '.theme == "hellfire" and .omarchy_theme == null' "$v"
jcheck "mapping: status --json agrees without Omarchy" '.desktop.theme == "hellfire"' "$(lum status --json)"

# omarchy_pair queues the very theme omarchy_theme_for names (its mapping is
# factored out, not changed): a local auto-theme stand-in builds omarchy-*,
# systemd-run and systemctl are stubs.
fresh
mkdir -p "$C/tools"
printf '#!/bin/sh\nmkdir -p "$HOME/.config/pc-lights/themes/omarchy-$1"\necho %s >"$HOME/.config/pc-lights/themes/omarchy-$1/theme.json"\necho "$1" >>"$HOME/auto-theme.log"\n' \
  "'{\"_about\": \"auto\"}'" >"$C/tools/auto-theme"
chmod +x "$C/tools/auto-theme"
cat >"$root/pair-overrides.sh" <<'EOF'
systemd-run() { printf '%s\n' "$*" >>"$HOME/systemd-run.log"; }
systemctl() { printf '%s\n' "$*" >>"$HOME/systemctl.log"; }
EOF
for c in sakura-light:sakura sakura:sakura nord:arctic gruvbox:omarchy-gruvbox ghost:omarchy-ghost; do
  slug=${c%%:*} want=${c#*:}
  rc=0; PCL_TEST_OVERRIDES=$root/pair-overrides.sh lum omarchy "$slug" >/dev/null || rc=$?
  got=$(tail -n1 "$H/systemd-run.log" 2>/dev/null | awk '{print $NF}')
  omarchy_at "$slug" 1-moon.jpg
  if (( rc == 0 )) && [[ $got == "$want" && $(lum desktop --json | jq -r .theme) == "$want" ]]; then
    ok "omarchy_pair queues $want for $slug, the desktop's theme too"
  else bad "omarchy_pair for $slug: exit $rc, queued '$got', want $want"; fi
done
check "omarchy_pair: auto-theme ran for the unmapped slugs only" diff <(printf '%s\n' gruvbox ghost) "$H/auto-theme.log"

# ---- 2. defaults and the exact view ---------------------------------------------
fresh
v=$(lum desktop --json)
jcheck "view: exactly the contract keys" 'keys == ["available","background","defaults","has_animated","omarchy_theme","playing","reason","screens","settings","stored","theme","user_clip","v"]' "$v"
jcheck "view: no desktop.json -> the built-in defaults, nothing stored" '.v == 1 and .available == true and .reason == null
  and .defaults == {animated: true, pause_while_active: true, resume_after_idle: 5, while_active: "freeze"}
  and .settings == .defaults and .stored == {} and (.settings | keys_unsorted) == ["animated","pause_while_active","resume_after_idle","while_active"]' "$v"
jcheck "view: the desktop's theme shows the screen" '.background == $bg and .has_animated == true and .playing == false and .user_clip == false' "$v" \
  --arg bg "$CUR/theme/backgrounds/1-moon.jpg"
check "view: read-only (no desktop.json, no cache written)" test ! -e "$C/desktop.json" -a ! -e "$K/desktop/state.json"
jcheck "view --theme <another>: the screen fields are null" '.theme == "hellfire" and .background == null and .has_animated == null
  and .playing == null and .user_clip == null and .available == true and .omarchy_theme == "sakura-light"' "$(lum desktop --theme hellfire --json)"
jcheck "view --theme <the desktop's own>: the screen fields are there" '.theme == "sakura" and .has_animated == true and .playing == false' \
  "$(lum desktop --theme sakura --json)"
omarchy_at sakura-light 2-dune.jpg
jcheck "view: a wallpaper without an animated version" '.has_animated == false' "$(lum desktop --json)"
omarchy_at sakura-light 1-moon.jpg
echo '{"v": 1, "defaults": {"resume_after_idle": 30, "while_active": "blur"},
  "themes": {"sakura": {"resume_after_idle": 9000, "while_active": "still", "animated": "yes", "pause_while_active": false, "extra": 1}}}' >"$C/desktop.json"
jcheck "view: the file's defaults over the built-in ones, bad values ignored" '.defaults.resume_after_idle == 30 and .defaults.while_active == "freeze"
  and .stored == {while_active: "still", pause_while_active: false}
  and .settings == {animated: true, pause_while_active: false, resume_after_idle: 30, while_active: "still"}' "$(lum desktop --json)"
echo 'not json' >"$C/desktop.json"
jcheck "view: an unreadable desktop.json reads as the defaults" '.settings == .defaults and .stored == {}' "$(lum desktop --json)"
text=$(lum desktop)
if grep -q '^desktop wallpaper: sakura (Omarchy theme sakura-light)$' <<<"$text" && grep -q 'with an animated version' <<<"$text"; then
  ok "text view: the theme and its wallpaper"; else bad "text view" "$text"; fi

# ---- 3. set: validation and exit codes ----------------------------------------
fresh
reset_calls
for a in "pause maybe" "animated 1" "resume 0" "resume 601" "resume abc" "resume -5" "resume 5.5" "resume 1000" "while blur"; do
  read -ra argv <<<"$a"
  rc=0; out=$(lum desktop set "${argv[@]}") || rc=$?
  jcheck "set $a: exit 2, invalid (exit $rc)" '.code == "invalid" and (.error | type == "string") and $rc == 2' "$out" --argjson rc "$rc"
done
for a in "speed 3" "pause" "" "pause true extra"; do
  read -ra argv <<<"$a"
  rc=0; out=$(lum desktop set "${argv[@]}") || rc=$?
  jcheck "set ${a:-(nothing)}: exit 2, usage (exit $rc)" '.code == "usage" and $rc == 2' "$out" --argjson rc "$rc"
done
for t in nosuch ../x; do
  rc=0; out=$(lum desktop set --theme "$t" pause true) || rc=$?
  jcheck "set --theme $t: exit 2, not-found (exit $rc)" '.code == "not-found" and $rc == 2' "$out" --argjson rc "$rc"
done
rc=0; out=$(lum desktop sync --theme hellfire) || rc=$?
jcheck "sync --theme: exit 2, usage (exit $rc)" '.code == "usage" and $rc == 2' "$out" --argjson rc "$rc"
rc=0; out=$(lum desktop frobnicate) || rc=$?
jcheck "desktop <unknown verb>: exit 2, usage (exit $rc)" '.code == "usage" and $rc == 2' "$out" --argjson rc "$rc"
check "a refused set writes nothing and asks the plugin nothing" test ! -e "$C/desktop.json" -a ! -s "$H/mw/calls.log"

reset_calls
rc=0; v=$(lum desktop set --theme hellfire resume 30) || rc=$?
jcheck "set --theme hellfire resume 30: exit 0, the view of hellfire (exit $rc)" '.theme == "hellfire" and .stored == {resume_after_idle: 30}
  and .settings.resume_after_idle == 30 and .background == null and .has_animated == null and .playing == null and .user_clip == null
  and $rc == 0' "$v" --argjson rc "$rc"
calls_are "set for another theme: one status read, nothing sent" "$S"
jcheck "desktop.json: v 1, the defaults written out, the theme's partial" '. == {v: 1, defaults: {animated: true, pause_while_active: true,
  resume_after_idle: 5, while_active: "freeze"}, themes: {hellfire: {resume_after_idle: 30}}}' "$(dj)"
jcheck "set resume 007 -> 7" '.stored.resume_after_idle == 7' "$(lum desktop set --theme hellfire resume 007)"
jcheck "set while still" '.stored.while_active == "still" and .settings.while_active == "still"' "$(lum desktop set --theme hellfire while still)"
jcheck "set pause toggle: true -> false" '.stored.pause_while_active == false' "$(lum desktop set --theme hellfire pause toggle)"
jcheck "set pause toggle: false -> true" '.stored.pause_while_active == true' "$(lum desktop set --theme hellfire pause toggle)"
jcheck "set keeps the other themes and keys" '.themes.hellfire == {resume_after_idle: 7, while_active: "still", pause_while_active: true}' "$(dj)"
# reset: the theme drops its own settings and follows the defaults again.
rc=0; v=$(lum desktop reset --theme hellfire) || rc=$?
jcheck "reset --theme hellfire: exit 0, stored {}, settings are the defaults (exit $rc)" '.theme == "hellfire" and .stored == {}
  and .settings == .defaults and $rc == 0' "$v" --argjson rc "$rc"
jcheck "reset removed hellfire from desktop.json, nothing else" '(.themes | has("hellfire") | not) and .v == 1 and (.defaults | type == "object")' "$(dj)"
rc=0; v=$(lum desktop reset --theme hellfire) || rc=$?
jcheck "reset again: still exit 0 (nothing stored)" '.stored == {} and $rc == 0' "$v" --argjson rc "$rc"
rc=0; out=$(lum desktop reset --theme nope) || rc=$?
jcheck "reset --theme nope: exit 2, not-found (exit $rc)" '.code == "not-found" and $rc == 2' "$out" --argjson rc "$rc"
lum desktop set --theme hellfire resume 7 >/dev/null; lum desktop set --theme hellfire while still >/dev/null; lum desktop set --theme hellfire pause true >/dev/null
echo '[1, 2]' >"$C/desktop.json"
jcheck "set over a desktop.json that is not an object: started over" '.themes == {hellfire: {animated: false}}' \
  "$(lum desktop set --theme hellfire animated false >/dev/null; dj)"
check "... and the old one kept as desktop.json.bad" grep -qx '\[1, 2\]' "$C/desktop.json.bad"

# ---- 4. set applies at once only for the desktop's theme ------------------------
fresh
lum desktop sync >/dev/null
reset_calls
lum desktop set --theme hellfire pause false >/dev/null
lum desktop set --theme arctic animated false >/dev/null
calls_are "another theme: status reads only, no setter, no stop" "$S" "$S"
reset_calls
v=$(lum desktop set pause false)
calls_are "the desktop's theme (sakura via sakura-light): the setter at once" "$S" "$(Q setPauseWhileActive false)"
jcheck "... stored for sakura, the plugin has it" '.theme == "sakura" and .stored == {pause_while_active: false} and .settings.pause_while_active == false' "$v"
jcheck "... the plugin's status" '.pauseWhileActive == false' "$(mw)"
reset_calls
lum desktop set --theme sakura resume 12 >/dev/null
lum desktop set while still >/dev/null
calls_are "--theme <the desktop's own> applies too; one setter per change" "$S" "$(Q setResumeAfterIdle 12)" "$S" "$(Q setWhileActive still)"
reset_calls
lum desktop set pause false >/dev/null
calls_are "set to what the plugin has: nothing sent" "$S"
reset_calls
lum desktop set resume 30 >/dev/null
check "a pause setting leaves the playback alone" test "$(grep -cE $'\t(play|playAll|stop)(\t|$)' "$H/mw/calls.log")" = 0
reset_calls
v=$(lum desktop set animated false)
calls_are "set animated false: the clip this engine started stops" "$S" "$(Q stop)"
jcheck "... playing false, nothing owned" '.playing == false and .settings.animated == false' "$v"
check "... owned cleared" test -z "$(owned)"
reset_calls
v=$(lum desktop set animated true)
calls_are "set animated true: the theme's clip plays" "$S" "$(Q playAll "$CLIP_SL")"
jcheck "... playing, ours" '.playing == true and .user_clip == false' "$v"

# ---- 5. sync: play, stop, ownership -------------------------------------------
fresh
reset_calls
lum desktop sync >/dev/null
calls_are "sync: the theme's own folder first (not the working copy)" "$S" "$(Q playAll "$CLIP_SL")"
check "sync: owned is the clip it started" test "$(owned)" = "$CLIP_SL"
jcheck "sync: the plugin plays it everywhere" '.enabled and .videoPath == $c and .output == "all"' "$(mw)" --arg c "$CLIP_SL"
reset_calls
lum desktop sync >/dev/null
calls_are "sync again: one status read, nothing sent" "$S"
omarchy_at sakura-light 2-dune.jpg
reset_calls
lum desktop sync >/dev/null
calls_are "a wallpaper without an animated version: its clip stops" "$S" "$(Q stop)"
check "... nothing owned" test ! -e "$K/desktop/owned"
reset_calls
lum desktop sync >/dev/null
calls_are "... and the next sync has nothing to stop" "$S"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "sakura: its own webm" "$S" "$(Q playAll "$CLIP_S")"
omarchy_at gruvbox 3-reef.png
reset_calls; lum desktop sync >/dev/null
calls_are "gruvbox: the stock theme's mkv (OMARCHY_PATH)" "$S" "$(Q playAll "$CLIP_G")"
omarchy_at nord 4-glow.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "nord: only in Omarchy's working copy" "$S" "$(Q playAll "$CLIP_W")"
jcheck "state.json: what the sync saw" '.v == 1 and .available and .omarchy_theme == "nord" and .theme == "arctic"
  and .has_animated and .playing and .user_clip == false and (.at | type == "number")' "$(cat "$K/desktop/state.json")"

# Another theme's animated clip is a theme clip, never the user's pick
# (2026-09-25: the toggle revived sakura's night clip on sakura-light, sync
# took it for the user's and left it playing over sakura-light's own).
fresh
omarchy_at sakura-light 1-moon.jpg
mw_status "{enabled: true, videoPath: \"$CLIP_S\", videoFileExists: true}"
reset_calls; v=$(lum desktop --json)
jcheck "another theme's clip playing: not the user's" '.playing == true and .user_clip == false' "$v"
reset_calls; lum desktop sync >/dev/null
calls_are "sync: another theme's stale clip is replaced by this theme's" "$S" "$(Q playAll "$CLIP_SL")"
check "... and it is owned now" test "$(owned)" = "$CLIP_SL"
fresh
omarchy_at sakura-light 2-dune.jpg
mw_status "{enabled: true, videoPath: \"$CLIP_S\", videoFileExists: true}"
reset_calls; lum desktop sync >/dev/null
calls_are "sync on a still wallpaper: another theme's stale clip stops" "$S" "$(Q stop)"
fresh
omarchy_at sakura-light 2-dune.jpg
mw_status "{enabled: false, videoPath: \"$CLIP_S\", videoFileExists: true}"
reset_calls; lum desktop toggle >/dev/null
check "toggle with no animated version: another theme's clip is not revived" test "$(grep -cE $'\t(play|playAll)(\t|$)' "$H/mw/calls.log")" = 0
check "... the OSD says there is none" grep -q "has no animated wallpaper" "$H/osd.log"

# A clip the user picked is never replaced or stopped.
fresh
mw_status "{enabled: true, videoPath: \"$MINE\"}"
echo "$CLIP_SL" >"$K/desktop.owned.tmp"; mkdir -p "$K/desktop"; mv "$K/desktop.owned.tmp" "$K/desktop/owned"
reset_calls; lum desktop sync >/dev/null
calls_are "the user's clip plays: sync leaves it (no playAll)" "$S"
jcheck "... the view says so" '.playing and .user_clip' "$(lum desktop --json)"
omarchy_at sakura-light 2-dune.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "... and a wallpaper without animation doesn't stop it" "$S"
jcheck "... still the user's clip" '.enabled and .videoPath == $m' "$(mw)" --arg m "$MINE"
rm -f "$MINE"
omarchy_at sakura-light 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "a picked clip whose file is gone isn't on screen: the theme's clip plays" "$S" "$(Q playAll "$CLIP_SL")"
fresh
mw_status "{enabled: true, videoPath: \"$CLIP_SL\"}"
reset_calls; lum desktop sync >/dev/null
calls_are "the theme's own clip picked by hand: not played again" "$S"
check "... and now owned (it stops with the theme)" test "$(owned)" = "$CLIP_SL"
mw_status '{enabled: false, videoPath: "/nowhere/old.mp4"}'
reset_calls; lum desktop sync >/dev/null
calls_are "the plugin stopped (by hand): the next sync plays the theme's clip" "$S" "$(Q playAll "$CLIP_SL")"
fresh
lum desktop sync >/dev/null
echo '{"v": 1, "themes": {"sakura": {"animated": false}}}' >"$C/desktop.json"
reset_calls; lum desktop sync >/dev/null
calls_are "animated false: like no animated version, the owned clip stops" "$S" "$(Q stop)"
reset_calls; lum desktop sync >/dev/null
calls_are "... and nothing plays on the next sync" "$S"
fresh
lum desktop sync >/dev/null
rm -f "$CUR/background"
reset_calls; lum desktop sync >/dev/null
calls_are "no wallpaper (mid-switch): the playback stays as it is" "$S"
jcheck "... the cache: playing, no animated version known" '.playing and .has_animated == false' "$(cat "$K/desktop/state.json")"

# ---- 5b. portrait monitors -----------------------------------------------------
# Beside 1-moon.mp4, sakura-light ships 1-moon.portrait.mp4; sakura has none.
LAND='{"name": "DP-3", "transform": 0}' PORT='{"name": "HDMI-A-1", "transform": 1}' PORT2='{"name": "DP-7", "transform": 3}'
mons() { echo "$1" >"$H/monitors.json"; }
oscr() { cat "$K/desktop/owned-screens.json" 2>/dev/null || echo null; }
fresh
mons "[$LAND, $PORT]"
reset_calls; lum desktop sync >/dev/null
calls_are "portrait: the main clip everywhere, then the portrait clip on the portrait monitor" "$S" "$(Q playAll "$CLIP_SL")" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"
jcheck "... owned-screens.json holds what it set" '. == {"HDMI-A-1": $p}' "$(oscr)" --arg p "$CLIP_SLP"
jcheck "... the plugin: HDMI-A-1 its own clip, DP-3 the main one" '.screenVideos == {"HDMI-A-1": $p} and .output == "all" and .videoPath == $m
  and ([.screens[] | {(.name): .video}] | add) == {"DP-3": $m, "HDMI-A-1": $p}' "$(mwv)" --arg p "$CLIP_SLP" --arg m "$CLIP_SL"
reset_calls; lum desktop sync >/dev/null
calls_are "... sync again: one status read, nothing sent" "$S"
jcheck "view: screens, each monitor with its clip" '.screens == [{name: "DP-3", portrait: false, clip: $m, playing: true},
  {name: "HDMI-A-1", portrait: true, clip: $p, playing: true}]' "$(lum desktop --json)" --arg p "$CLIP_SLP" --arg m "$CLIP_SL"
jcheck "view --theme <another>: screens null" '.screens == null' "$(lum desktop --theme hellfire --json)"
text=$(lum desktop)
if grep -qF "monitors: DP-3: 1-moon.mp4, HDMI-A-1 (portrait): 1-moon.portrait.mp4" <<<"$text"; then ok "text view: the monitors"; else bad "text view: the monitors" "$text"; fi
jcheck "status --json (from state.json): portrait true" '.desktop.portrait == true' "$(lum status --json)"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "theme switch to one without a portrait clip: play (keeps overrides), then this engine's override cleared" "$S" "$(Q play "$CLIP_S")" "$(Q clearScreen HDMI-A-1)"
check "... owned-screens.json gone" test ! -e "$K/desktop/owned-screens.json"
jcheck "... the plugin: no override, the main clip everywhere" '.screenVideos == {} and .videoPath == $c and (.activeScreens | length) == 2' "$(mwv)" --arg c "$CLIP_S"
jcheck "... status --json: portrait false" '.desktop.portrait == false' "$(lum status --json)"
omarchy_at sakura-light 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "back on sakura-light: the portrait clip again" "$S" "$(Q playAll "$CLIP_SL")" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"
omarchy_at sakura-light 2-dune.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "a wallpaper without an animated version: stop, and the override cleared" "$S" "$(Q stop)" "$(Q clearScreen HDMI-A-1)"
check "... owned-screens.json gone" test ! -e "$K/desktop/owned-screens.json"

fresh
mons "[$LAND, $PORT]"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "no portrait clip: the main clip alone, on every monitor" "$S" "$(Q playAll "$CLIP_S")"
check "... nothing per monitor owned" test ! -e "$K/desktop/owned-screens.json"

fresh
mons "[$LAND, $PORT, $PORT2, {\"name\": \"DP-8\", \"transform\": 2}, {\"name\": \"DP-9\", \"transform\": 5, \"disabled\": true}]"
reset_calls; lum desktop sync >/dev/null
calls_are "two portrait monitors (transform 1 and 3; 2 is landscape, a disabled one isn't there): both get it" \
  "$S" "$(Q playAll "$CLIP_SL")" "$(Q playOn HDMI-A-1 "$CLIP_SLP")" "$(Q playOn DP-7 "$CLIP_SLP")"
jcheck "... both owned" '. == {"HDMI-A-1": $p, "DP-7": $p}' "$(oscr)" --arg p "$CLIP_SLP"
mons "[$LAND, $PORT2]"
reset_calls; lum desktop sync >/dev/null
calls_are "a portrait monitor unplugged: its override cleared, the other kept" "$S" "$(Q clearScreen HDMI-A-1)"
jcheck "... owned: DP-7 only" '. == {"DP-7": $p}' "$(oscr)" --arg p "$CLIP_SLP"
mons "[$LAND, {\"name\": \"DP-7\", \"transform\": 0}]"
reset_calls; lum desktop sync >/dev/null
calls_are "a portrait monitor turned landscape: its override cleared" "$S" "$(Q clearScreen DP-7)"

# animated false, from set, desktop.json or the key, clears them.
fresh
mons "[$LAND, $PORT]"
lum desktop sync >/dev/null
reset_calls; lum desktop set animated false >/dev/null
calls_are "set animated false: stop, and the override cleared" "$S" "$(Q stop)" "$(Q clearScreen HDMI-A-1)"
check "... owned-screens.json gone" test ! -e "$K/desktop/owned-screens.json"
reset_calls; lum desktop set animated true >/dev/null
calls_are "set animated true: both clips again" "$S" "$(Q playAll "$CLIP_SL")" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"
echo '{"v": 1, "themes": {"sakura": {"animated": false}}}' >"$C/desktop.json"
reset_calls; lum desktop sync >/dev/null
calls_are "sync with animated false in desktop.json: stop, and the override cleared" "$S" "$(Q stop)" "$(Q clearScreen HDMI-A-1)"
rm -f "$C/desktop.json"
lum desktop sync >/dev/null
reset_calls; lum desktop toggle >/dev/null
calls_are "toggle to still: stop, and the override cleared" "$S" "$(Q stop)" "$(Q clearScreen HDMI-A-1)"
reset_calls; lum desktop toggle >/dev/null
calls_are "toggle to moving: both clips" "$S" "$(Q playAll "$CLIP_SL")" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"
reset_calls; lum desktop reset >/dev/null
calls_are "reset (back to animated by default): nothing to change" "$S"

# The user's per-screen clips are theirs.
fresh
mons "[$LAND, $PORT]"
mw_status "{enabled: true, videoPath: \"$CLIP_SL\", screenVideos: {\"HDMI-A-1\": \"$MINE\"}}"
reset_calls; lum desktop sync >/dev/null
calls_are "the user's clip on the portrait monitor: left alone (no playOn)" "$S"
check "... not owned" test ! -e "$K/desktop/owned-screens.json"
jcheck "... the view shows it" '.screens[1] == {name: "HDMI-A-1", portrait: true, clip: $m, playing: true}' "$(lum desktop --json)" --arg m "$MINE"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "a theme switch: play, not playAll (which would drop the user's clip)" "$S" "$(Q play "$CLIP_S")"
jcheck "... the user's clip still there" '.screenVideos == {"HDMI-A-1": $m} and .videoPath == $c' "$(mw)" --arg m "$MINE" --arg c "$CLIP_S"
reset_calls; lum desktop set animated false >/dev/null
calls_are "animated false: stop, the user's clip not cleared" "$S" "$(Q stop)"
jcheck "... still in the plugin" '.screenVideos == {"HDMI-A-1": $m}' "$(mw)" --arg m "$MINE"
fresh
mons "[$LAND, $PORT]"
mw_status '{screenVideos: {"HDMI-A-1": ""}, output: "DP-3"}'
reset_calls; lum desktop sync >/dev/null
calls_are "a monitor the user blanked stays blank; a one-monitor output is widened to all" "$S" "$(Q play "$CLIP_SL")" "$(Q setOutput all)"
jcheck "... the plugin" '.screenVideos == {"HDMI-A-1": ""} and .output == "all" and .activeScreens == ["DP-3"]' "$(mwv)"
fresh
mons "[$LAND, $PORT]"
lum desktop sync >/dev/null
jq --arg m "$MINE" '.screenVideos["HDMI-A-1"] = $m' "$H/mw/status.json" >"$H/mw/s.tmp" && mv "$H/mw/s.tmp" "$H/mw/status.json"
reset_calls; lum desktop sync >/dev/null
calls_are "the user replaced this engine's override with their own: left alone" "$S"
check "... and no longer owned" test ! -e "$K/desktop/owned-screens.json"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "... nor cleared on a theme switch" "$S" "$(Q play "$CLIP_S")"

# Any theme's clip on a monitor is a theme's (the rule, per monitor).
fresh
mons "[$LAND, $PORT]"
omarchy_at sakura 1-moon.jpg
mw_status "{enabled: true, videoPath: \"$CLIP_S\", screenVideos: {\"HDMI-A-1\": \"$CLIP_SLP\"}}"
reset_calls; lum desktop sync >/dev/null
calls_are "another theme's portrait clip, never owned: cleared" "$S" "$(Q clearScreen HDMI-A-1)"
fresh
mons "[$LAND, $PORT]"
mw_status "{enabled: true, videoPath: \"$CLIP_SL\", screenVideos: {\"HDMI-A-1\": \"$CLIP_S\"}}"
reset_calls; lum desktop sync >/dev/null
calls_are "another theme's clip on the portrait monitor: replaced by this theme's portrait clip" "$S" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"

# The user's main clip: no portrait clip over it.
fresh
mons "[$LAND, $PORT]"
mw_status "{enabled: true, videoPath: \"$MINE\"}"
reset_calls; lum desktop sync >/dev/null
calls_are "the user's main clip playing: no playOn" "$S"

fresh
mons "[$LAND, $PORT]"
mw_mode noscreens
reset_calls; lum desktop sync >/dev/null
calls_are "a plugin without per-monitor clips: the main clip only" "$S" "$(Q playAll "$CLIP_SL")"
mw_mode up

# ---- 6. the pause setters: only on a change ------------------------------------
fresh
reset_calls; lum desktop sync >/dev/null
check "defaults equal to the plugin's: no setter" test "$(setters)" = 0
echo '{"v": 1, "themes": {"sakura": {"pause_while_active": false, "resume_after_idle": 30, "while_active": "still"}}}' >"$C/desktop.json"
reset_calls; lum desktop sync >/dev/null
calls_are "sakura's own values: the three setters, then nothing else" "$S" "$(Q setPauseWhileActive false)" "$(Q setResumeAfterIdle 30)" "$(Q setWhileActive still)"
jcheck "... the plugin has them" '.pauseWhileActive == false and .resumeAfterIdle == 30 and .whileActive == "still"' "$(mw)"
reset_calls; lum desktop sync >/dev/null
calls_are "... the next sync sends none" "$S"
omarchy_at nord 2-dune.jpg
reset_calls; lum desktop sync >/dev/null
calls_are "another theme (arctic, defaults): back to the defaults, the owned clip stops" "$S" "$(Q setPauseWhileActive true)" "$(Q setResumeAfterIdle 5)" "$(Q setWhileActive freeze)" "$(Q stop)"
omarchy_at sakura-light 1-moon.jpg
reset_calls; lum desktop sync >/dev/null
check "back on sakura: its three values again" test "$(setters)" = 3
fresh
mw_mode old
jq 'del(.pauseWhileActive, .resumeAfterIdle, .whileActive)' "$H/mw/status.json" >"$H/mw/s.tmp" && mv "$H/mw/s.tmp" "$H/mw/status.json"
echo '{"v": 1, "themes": {"sakura": {"pause_while_active": false}}}' >"$C/desktop.json"
reset_calls; lum desktop sync >/dev/null
calls_are "a plugin without the pause settings: no setter, the clip still plays" "$S" "$(Q playAll "$CLIP_SL")"

# ---- 7. toggle ------------------------------------------------------------------
fresh
lum desktop sync >/dev/null
reset_calls; rc=0; lum desktop toggle >/dev/null || rc=$?
calls_are "toggle while moving: stop (exit $rc)" "$S" "$(Q stop)"
check "... OSD: the still wallpaper" test "$(osd_last)" = "osd -i 󰋩 -m Sakura · still wallpaper -d 1400"
jcheck "... animated false remembered for sakura (from sakura-light)" '.themes.sakura.animated == false' "$(dj)"
check "... nothing owned" test ! -e "$K/desktop/owned"
reset_calls; lum desktop sync >/dev/null
calls_are "... the next sync keeps it still" "$S"
reset_calls; lum desktop toggle >/dev/null
calls_are "toggle while still: the theme's clip plays" "$S" "$(Q playAll "$CLIP_SL")"
check "... OSD: the animated wallpaper" test "$(osd_last)" = "osd -i 󰕧 -m Sakura · animated wallpaper -d 1400"
jcheck "... animated true remembered" '.themes.sakura.animated == true' "$(dj)"
check "... owned" test "$(owned)" = "$CLIP_SL"
jcheck "toggle --json: the view after" '.playing == false and .settings.animated == false' "$(lum desktop toggle --json)"
omarchy_at sakura 1-moon.jpg
reset_calls; lum desktop toggle >/dev/null
calls_are "sakura shares the choice: toggling there plays sakura's clip" "$S" "$(Q playAll "$CLIP_S")"
fresh
omarchy_at gruvbox 2-dune.jpg
reset_calls; lum desktop toggle >/dev/null
calls_are "no animated version, nothing ever played: nothing sent" "$S"
check "... OSD: <Theme> has no animated wallpaper (an auto-theme by its Omarchy name)" test "$(osd_last)" = "osd -i 󰋩 -m Gruvbox has no animated wallpaper -d 1400"
: >"$H/Videos/mine.mp4"
mw_status "{enabled: false, videoPath: \"$MINE\"}"
reset_calls; lum desktop toggle >/dev/null
calls_are "no animated version, a last clip: it comes back" "$S" "$(Q play "$MINE")"
check "... OSD: Animated wallpaper" test "$(osd_last)" = "osd -i 󰕧 -m Animated wallpaper -d 1400"
check "... the user's clip is not owned" test ! -e "$K/desktop/owned"
reset_calls; lum desktop toggle >/dev/null
calls_are "toggle stops the user's clip too (the key is the user's choice)" "$S" "$(Q stop)"

# ---- 8. migration from the standalone script ------------------------------------
fresh
mkdir -p "$OLD/still"
: >"$OLD/still/sakura-light"; : >"$OLD/still/gruvbox"; : >"$OLD/still/unknown"
echo "$CLIP_SL" >"$OLD/owned"
mw_status "{enabled: true, videoPath: \"$CLIP_SL\"}"
v=$(lum desktop --json)
jcheck "migration: the still files became animated false for the mapped themes" '.themes == {sakura: {animated: false}, "omarchy-gruvbox": {animated: false}}' "$(dj)"
jcheck "... the view of sakura says so" '.stored == {animated: false} and .settings.animated == false' "$v"
check "... still/ renamed still.migrated, every file kept" bash -c "[[ ! -e '$OLD/still' && -f '$OLD/still.migrated/sakura-light' && -f '$OLD/still.migrated/unknown' ]]"
check "... owned moved to the cache (the old one renamed)" bash -c "[[ \$(cat '$K/desktop/owned') == '$CLIP_SL' && ! -e '$OLD/owned' && -f '$OLD/owned.migrated' ]]"
sum=$(sha256sum "$C/desktop.json")
lum desktop --json >/dev/null
check "... once: a second run changes nothing" test "$(sha256sum "$C/desktop.json")" = "$sum"
reset_calls; lum desktop sync >/dev/null
calls_are "... and the migrated clip (still set for sakura) stops at the next sync" "$S" "$(Q stop)"
fresh
mkdir -p "$OLD/still.migrated" "$OLD/still"; : >"$OLD/still/nord"
lum desktop sync >/dev/null
check "migration by sync, with a still.migrated already there" bash -c "[[ -f \$(ls -d '$OLD'/still.migrated.*)/nord && ! -e '$OLD/still' ]]"
jcheck "... nord -> arctic animated false" '.themes.arctic == {animated: false}' "$(dj)"

# ---- 9. the shell down, the plugin missing -------------------------------------
fresh
mw_mode down
rc=0; v=$(lum desktop --json) || rc=$?
jcheck "shell down: view exit 0, available false, shell-down (exit $rc)" '.available == false and .reason == "shell-down" and .playing == null
  and .user_clip == null and .has_animated == true and (.background | type == "string") and $rc == 0' "$v" --argjson rc "$rc"
reset_calls; rc=0; lum desktop sync >/dev/null || rc=$?
calls_are "shell down: sync exit 0 ($rc), one status attempt, nothing else" "$S"
jcheck "... state.json: available false, playing null" '.available == false and .playing == null and .user_clip == null' "$(cat "$K/desktop/state.json")"
reset_calls; rc=0; v=$(lum desktop set pause false) || rc=$?
jcheck "shell down: set stores and exits 0 ($rc)" '.available == false and .stored == {pause_while_active: false} and $rc == 0' "$v" --argjson rc "$rc"
calls_are "... no setter" "$S"
rm -f "$H/osd.log"
reset_calls; rc=0; lum desktop toggle >/dev/null || rc=$?
if (( rc == 0 )) && [[ ! -e $H/osd.log && $(dj .themes.sakura) == '{"pause_while_active":false}' ]]; then
  ok "shell down: toggle exits 0, no OSD, nothing stored"; else bad "shell down: toggle exit $rc"; fi
jcheck "status --json after a sync with the shell down: available false" '.desktop.available == false and .desktop.playing == null' "$(lum status --json)"
mw_mode noplugin
jcheck "no plugin: available false, no-plugin" '.available == false and .reason == "no-plugin" and .playing == null' "$(lum desktop --json)"
rc=0; lum desktop sync >/dev/null || rc=$?
check "no plugin: sync exits 0 ($rc)" test "$rc" = 0
mw_mode up

# ---- 10. the lock ---------------------------------------------------------------
fresh
mkdir -p "$K/desktop"
( flock "$K/desktop/lock" sleep 1.5 ) &
sleep 0.3
t0=$(date +%s%N); lum desktop sync >/dev/null; t1=$(date +%s%N)
wait
if (( (t1 - t0) / 1000000 >= 900 )) && [[ $(owned) == "$CLIP_SL" ]]; then ok "sync waits for the lock, then runs ($(( (t1 - t0) / 1000000 )) ms)"
else bad "sync and the lock: $(( (t1 - t0) / 1000000 )) ms, owned '$(owned)'"; fi
fresh
reset_calls
for _ in 1 2 3 4; do lum desktop sync >/dev/null & done
wait
check "four syncs at once: one playAll" test "$(grep -c $'\tplayAll\t' "$H/mw/calls.log")" = 1

# ---- 11. status --json v1.4 -----------------------------------------------------
fresh
reset_calls
s=$(lum status --json)
jcheck "status: v_minor 4, the desktop block before any sync" '.v == 1 and .v_minor == 4 and (.desktop | keys) == ["at","available","playing","portrait","settings","theme"]
  and .desktop.portrait == false
  and .desktop.available == null and .desktop.playing == null and .desktop.at == null and .desktop.theme == "sakura"
  and .desktop.settings == {animated: true, pause_while_active: true, resume_after_idle: 5, while_active: "freeze"}' "$s"
lum desktop sync >/dev/null
lum desktop set --theme sakura resume 20 >/dev/null
reset_calls
s=$(lum status --json)
jcheck "status: after a sync, from desktop.json and the cache" '.desktop.available == true and .desktop.playing == true and (.desktop.at | type == "number")
  and .desktop.settings.resume_after_idle == 20 and .desktop.theme == "sakura"' "$s"
check "status --json asks the plugin nothing" test "$(ncalls)" = 0
omarchy_at gruvbox 3-reef.png
lum desktop set --theme omarchy-gruvbox while still >/dev/null
reset_calls
jcheck "status: an auto-theme's settings" '.desktop.theme == "omarchy-gruvbox" and .desktop.settings.while_active == "still"' "$(lum status --json)"
check "... still no IPC" test "$(ncalls)" = 0
check "status: never writes the desktop files" bash -c "! find '$K/desktop' '$C' -newer '$K/desktop/state.json' -type f | grep -q ."
mkdir -p "$OLD/still"; : >"$OLD/still/nord"
sum=$(sha256sum "$C/desktop.json")
lum status --json >/dev/null
check "status: never migrates (the old still/ stays, desktop.json as it was)" bash -c "[[ -f '$OLD/still/nord' && \$(sha256sum '$C/desktop.json') == '$sum' ]]"
# The median of 20 runs, re-measured once when over budget (as engine-contract.sh).
median_ms() {
  local t0 t1 ts=()
  for _ in {1..20}; do t0=$(date +%s%N); lum status --json >/dev/null; t1=$(date +%s%N); ts+=($(( (t1 - t0) / 1000000 ))); done
  printf '%s\n' "${ts[@]}" | sort -n | sed -n 10p
}
m=$(median_ms)
(( m <= 40 )) || { sleep 2; m=$(median_ms); }
if (( m <= 40 )); then ok "status --json with the desktop block: median $m ms (<= 40)"; else bad "status --json: median $m ms (> 40)"; fi

# ---- 12b. desktop watch (the monitor watcher) -----------------------------------
R=$root/run
watch_run() { HOME=$H PATH=$FB:$PATH OMARCHY_PATH=$STOCK "$engine" desktop watch "$@" 2>>"$root/stderr.log"; }
fresh
mkdir -p "$R/hypr/sig"; : >"$R/hypr/sig/.socket2.sock"
printf '%s\n' "echo 'activewindow>>foot,fish'" \
  "echo '[{\"name\": \"DP-3\", \"transform\": 0}, {\"name\": \"HDMI-A-1\", \"transform\": 1}]' >\"\$HOME/monitors.json\"" \
  "echo 'monitoraddedv2>>2,HDMI-A-1,Dell'" "echo 'monitoradded>>HDMI-A-1'" "echo 'workspace>>2'" >"$H/socat-script"
reset_calls
rc=0; XDG_RUNTIME_DIR=$R HYPRLAND_INSTANCE_SIGNATURE=sig watch_run >/dev/null || rc=$?
calls_are "watch: a sync at start, one after a burst of monitor events (exit $rc)" "$S" "$(Q playAll "$CLIP_SL")" "$S" "$(Q playOn HDMI-A-1 "$CLIP_SLP")"
check "... read the instance's event socket" grep -qxF -- "-U - UNIX-CONNECT:$R/hypr/sig/.socket2.sock" "$H/socat.log"
check "... exit 0 when the stream ends" test "$rc" = 0
fresh
mkdir -p "$R/hypr/old"; : >"$R/hypr/old/.socket2.sock"; touch -d '1 hour ago' "$R/hypr/old/.socket2.sock"
printf '%s\n' "echo 'activewindow>>foot,fish'" "echo 'workspace>>3'" "echo 'focusedmon>>DP-3,1'" >"$H/socat-script"
reset_calls
XDG_RUNTIME_DIR=$R HYPRLAND_INSTANCE_SIGNATURE='' watch_run >/dev/null || true
calls_are "watch: other events start no sync" "$S" "$(Q playAll "$CLIP_SL")"
check "... without the signature: the newest socket" grep -qxF -- "-U - UNIX-CONNECT:$R/hypr/sig/.socket2.sock" "$H/socat.log"
fresh
echo "echo 'configreloaded>>'" >"$H/socat-script"
reset_calls
XDG_RUNTIME_DIR=$R HYPRLAND_INSTANCE_SIGNATURE=sig watch_run >/dev/null || true
calls_are "watch: configreloaded (a monitor turned in the config) syncs" "$S" "$(Q playAll "$CLIP_SL")" "$S"
fresh
reset_calls
rc=0; XDG_RUNTIME_DIR=$root/nohypr HYPRLAND_INSTANCE_SIGNATURE='' watch_run >/dev/null || rc=$?
if (( rc == 1 )) && [[ ! -s $H/mw/calls.log && ! -e $H/socat.log ]]; then ok "watch without a Hyprland socket: exit 1, nothing asked"
else bad "watch without a socket: exit $rc"; fi
rc=0; out=$(watch_run --json) || rc=$?
jcheck "watch --json: exit 2, usage (exit $rc)" '.code == "usage" and $rc == 2' "$out" --argjson rc "$rc"

# ---- 12. the motion-wallpaper-theme shim ----------------------------------------
shim=$repo/lib/pc-lights/tools/motion-wallpaper-theme
check "the shim: executable, at most 3 lines" bash -c "[[ -x '$shim' ]] && (( \$(wc -l <'$shim') <= 3 ))"
check "the shim: bash -n" bash -n "$shim"
fresh
mkdir -p "$H/.local/bin"
ln -s "$engine" "$H/.local/bin/lumenaire"
# Without ~/.local/bin in PATH, as from the systemd path unit.
shim_run() { HOME=$H PATH=$FB:/usr/bin:/bin OMARCHY_PATH=$STOCK "$shim" "$@" >/dev/null 2>>"$root/stderr.log"; }
reset_calls; shim_run
calls_are "shim with no argument: lumenaire desktop sync" "$S" "$(Q playAll "$CLIP_SL")"
reset_calls; shim_run toggle
calls_are "shim toggle: lumenaire desktop toggle" "$S" "$(Q stop)"
check "... with its OSD" test "$(osd_last)" = "osd -i 󰋩 -m Sakura · still wallpaper -d 1400"

# ---- 13. install --desktop (a scratch HOME: no systemctl, nothing live) --------
I=$root/inst
mkdir -p "$I/.config/omarchy"
rc=0; HOME=$I PATH=$FB:$PATH "$engine" install --desktop --dry-run >"$root/inst-dry.log" 2>&1 || rc=$?
if (( rc == 0 )) && [[ -z $(find "$I" \( -type f -o -type l \) -print -quit) ]]; then ok "install --desktop --dry-run: exit 0, nothing written"
else bad "install --desktop --dry-run: exit $rc" "$(tail -5 "$root/inst-dry.log")"; fi
rc=0; HOME=$I PATH=$FB:$PATH "$engine" install --desktop >"$root/inst.log" 2>&1 || rc=$?
if (( rc == 0 )) && [[ $(readlink -f "$I/.local/bin/motion-wallpaper-theme") == "$(readlink -f "$shim")" ]] &&
   cmp -s "$repo/hooks/omarchy/theme-set.d/motion-wallpaper-theme" "$I/.config/omarchy/hooks/theme-set.d/motion-wallpaper-theme" &&
   [[ -x $I/.config/omarchy/hooks/theme-set.d/motion-wallpaper-theme ]] &&
   cmp -s "$repo/systemd/motion-wallpaper-theme.path" "$I/.config/systemd/user/motion-wallpaper-theme.path" &&
   cmp -s "$repo/systemd/motion-wallpaper-theme.service" "$I/.config/systemd/user/motion-wallpaper-theme.service" &&
   cmp -s "$repo/systemd/motion-wallpaper-monitors.service" "$I/.config/systemd/user/motion-wallpaper-monitors.service"; then
  ok "install --desktop: the shim link, the hook (755), the path unit and its service, the monitor watcher"
else bad "install --desktop: exit $rc" "$(tail -8 "$root/inst.log")"; fi
if grep -qF 'o.bind("SUPER + SHIFT + ALT + SPACE", "Toggle animated wallpaper"' "$root/inst.log" &&
   grep -q 'skip.*systemctl --user enable --now motion-wallpaper-theme.path' "$root/inst.log" &&
   grep -q 'skip.*systemctl --user enable --now .*motion-wallpaper-monitors.service' "$root/inst.log"; then
  ok "install --desktop: prints the binding, enables and starts the path unit and the watcher (skipped: scratch HOME)"
else bad "install --desktop: binding or enable line missing" "$(grep -iE 'bind|path' "$root/inst.log" | head -5)"; fi
check "install --desktop: bindings.lua untouched (none created)" test ! -e "$I/.config/hypr/bindings.lua"

# ---- -q discipline over every call above ---------------------------------------
reset_calls
n=$(grep -c . "$root/all-calls.log" || true)
check "never status with -q (it swallows the reply), over all $n calls" bash -c "! grep -qP '^q\tmotion-wallpaper\tstatus' '$root/all-calls.log'"
check "every change with -q (no reply needed), over all $n calls" bash -c "! grep -qP '^-\tmotion-wallpaper\t(?!status)' '$root/all-calls.log'"

echo
echo "passed $passed, failed $failed"
(( failed == 0 ))
