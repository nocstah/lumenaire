# stubs.sh — PCL_TEST_OVERRIDES for tests/preview (sourced by the engine after
# every function is defined). No hardware, no real daemon, no real units:
#   - the daemon socket is $HOME/fake-lianli.sock and $HOME/bin (fake-socat as
#     socat, fake-openrgb as openrgb) goes first in PATH, also inside the
#     transient units, whose PATH is systemd's;
#   - lianli_lights, lianli_screens, apply_openrgb, swap_clip and
#     be_openrgb_preview only log (be_openrgb_preview sleeps $HOME/orgb-sleep);
#     lianli_lights also marks $HOME/requests.jsonl, so a test can see a
#     revert went out before the apply;
#   - systemctl answers is-active with "active" and only logs everything else;
#   - journalctl always shows the reload line (method rgbconfig, and the
#     effect method's wait after a screens reload);
#   - usb_serial_map reads $HOME/usbmap.json (USB serial -> the daemon's
#     hid:1cbe:... form; {} without it).
# While lib/pc-lights/editor.sh doesn't define builder A's draft functions
# (PCL_EDITOR_STUBBED), or with PCL_PV_DRAFT_STUBS=1, small ones read the
# drafts straight from $STATE_DIR/drafts/<name>.json.
# shellcheck shell=bash disable=SC2034,SC2016
SOCK=$HOME/fake-lianli.sock
PATH=$HOME/bin:$PATH
pvstub() { printf '%s %s %s\n' "$EPOCHSECONDS" "${PCL_UNIT:-cli}" "$*" >>"$HOME/stub.log"; }
lianli_lights() { pvstub "lianli_lights $*"; printf '{"stub":"lianli_lights %s"}\n' "$*" >>"$HOME/requests.jsonl"; }
lianli_screens() { pvstub "lianli_screens $*"; }
apply_openrgb() { pvstub apply_openrgb; }
swap_clip() { pvstub "swap_clip $*"; }
be_openrgb_preview() {
  pvstub "be_openrgb_preview start $(tr '\n' ' ' <"${2:-/dev/null}")"
  sleep "$(cat "$HOME/orgb-sleep" 2>/dev/null || echo 0)"
  pvstub "be_openrgb_preview done"
}
systemctl() {
  case " $* " in
    *" is-active "*) case " $* " in *" -q "* | *" --quiet "*) ;; *) echo active ;; esac; return 0 ;;
    *" list-units "*) return 0 ;;
    *) echo "blocked: systemctl $*" >>"$HOME/stub.log"; return 0 ;;
  esac
}
journalctl() { echo "fake: Config reload triggered via IPC"; }
logger() { :; }
usb_serial_map() { if [[ -f $HOME/usbmap.json ]]; then cp "$HOME/usbmap.json" "$TMP/usbmap.json"; else echo '{}' >"$TMP/usbmap.json"; fi; echo "$TMP/usbmap.json"; }
usb_screens() { echo 0; }
if [[ -n ${PCL_EDITOR_STUBBED:-} || -n ${PCL_PV_DRAFT_STUBS:-} ]]; then
  editor_draft_file() { echo "$STATE_DIR/drafts/$1.json"; }
  editor_draft_rev() { jq -r '.rev' "$STATE_DIR/drafts/$1.json"; }
  editor_media_root() { jq -r '.media_root // empty' "$STATE_DIR/drafts/$1.json"; }
  editor_draft_problems() {
    theme_jq -r --arg modes "$STRIMER_MODES" --slurpfile t <(jq '.theme' "$STATE_DIR/drafts/$1.json") '$t[0] | v3_problems($modes)'
  }
  editor_draft_eff() {
    local out=$CACHE/compiled/draft-$1.test.json
    mkdir -p "$CACHE/compiled"
    theme_jq --slurpfile t <(jq '.theme' "$STATE_DIR/drafts/$1.json") 'compile($t[0]; $P; $M; $C)' >"$out.tmp" &&
      mv -f "$out.tmp" "$out" && echo "$out"
  }
fi
# PV_CALL: run one engine function (with this file's stubs) and exit.
if [[ -n ${PV_CALL:-} ]]; then eval "$PV_CALL"; exit $?; fi
