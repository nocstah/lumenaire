#!/bin/bash
# Unit checks for backend-lianli.sh helpers that talk to the daemon after a
# live reload. The module runs nothing at source time; daemon_guarded, log and
# sleep are stubbed, so nothing reaches the socket or the hardware.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
# shellcheck source=../../lib/pc-lights/backend-lianli.sh
source "$ROOT/lib/pc-lights/backend-lianli.sh"
log() { printf '%s\n' "$*" >>"$TMP/log"; }
sleep() { printf 'sleep %s\n' "$1" >>"$TMP/sent"; }
daemon_guarded() { jq -c . "$1" >>"$TMP/sent"; [[ -z ${FAIL_GUARD:-} ]] || { LIVE_ERR=refused; return 1; }; }

cfg() { jq -n --argjson l "$1" '{lcds: $l}'; }
reset() { : >"$TMP/sent"; : >"$TMP/log"; }

# sakura-light -> cyberpunk: two fan screens go video -> image, one stays a
# video, one was already an image (new path), the 8.8" goes custom -> image.
cfg '[{"serial":"a","type":"video","path":"/v1.mp4","orientation":180},
      {"serial":"b","type":"video","path":"/v2.mp4","orientation":0},
      {"serial":"c","type":"image","path":"/old.jpg","orientation":0},
      {"serial":"d","type":"custom","template_id":"t","orientation":90}]' >"$TMP/built-from.json"
cfg '[{"serial":"a","type":"image","path":"/i1.jpg","orientation":180},
      {"serial":"b","type":"video","path":"/v3.mp4","orientation":0},
      {"serial":"c","type":"image","path":"/new.jpg","orientation":0},
      {"serial":"d","type":"image","path":"/i2.jpg","orientation":90}]' >"$TMP/work-config.json"
reset; nudge_new_image_lcds
mapfile -t media < <(grep SetLcdMedia "$TMP/sent")
[[ ${#media[@]} == 4 ]] && ok "video/custom -> image: two sends per screen (4)" || bad "expected 4 SetLcdMedia, got ${#media[@]}"
jq -e -s '[.[] | .params | {d: .device_id, o: .config.orientation}]
  == [{d:"serial:a",o:270},{d:"serial:a",o:180},{d:"serial:d",o:180},{d:"serial:d",o:90}]' <<<"${media[*]}" >/dev/null &&
  ok "turned 90°, then the real entry, in order" || bad "wrong nudge sequence: ${media[*]}"
jq -e -s 'all(.[]; .params.config.path != "/v3.mp4" and .params.config.path != "/new.jpg")' <<<"${media[*]}" >/dev/null &&
  ok "a video, and an image that was already an image, are left alone" || bad "touched a screen it shouldn't"
jq -e -s '.[1].params.config == {"serial":"a","type":"image","path":"/i1.jpg","orientation":180}' <<<"${media[*]}" >/dev/null &&
  ok "the last send is the exact new entry" || bad "last send differs from the entry"
[[ $(grep -c '^sleep' "$TMP/sent") == 2 ]] && ok "waits between the turn and the real entry" || bad "missing gap"

reset; cp "$TMP/work-config.json" "$TMP/built-from.json"; nudge_new_image_lcds
[[ ! -s $TMP/sent ]] && ok "no type change: nothing sent" || bad "sent with no change"

reset; rm -f "$TMP/built-from.json"; nudge_new_image_lcds; rc=$?
[[ $rc == 0 && ! -s $TMP/sent ]] && ok "no previous config (restart path): nothing sent, rc 0" || bad "missing old config not handled"

cfg '[{"serial":"a","type":"video","path":"/v.mp4"}]' >"$TMP/built-from.json"
cfg '[{"serial":"a","type":"image","path":"/i.jpg"}]' >"$TMP/work-config.json"
reset; FAIL_GUARD=1 nudge_new_image_lcds; rc=$?
[[ $rc == 0 && $(grep -c SetLcdMedia "$TMP/sent") == 1 ]] && grep -q "refresh failed (refused)" "$TMP/log" && ! grep -q refreshed "$TMP/log" &&
  ok "a refused send: logged, stops that screen, never fatal" || bad "refused send not handled (rc $rc)"

# A reboot renumbered the USB bus: the screens and lighting follow by model and
# port; a stale entry beside its new name goes; others are left alone.
die() { printf 'die: %s\n' "$*" >>"$TMP/log"; return 1; }
usb_serial_map() { jq -n '{s1:"hid:1cbe:a018:6-12.2.1",s2:"hid:1cbe:a068:6-7.2.2"}' >"$TMP/usbmap.json"; echo "$TMP/usbmap.json"; }
jq -n '{data:[{device_id:"hid:0416:8050:6-10.2.3"},{device_id:"hid:43a8:0102:6-12.4.4"},{device_id:"wireless:aa:bb"}]}' >"$TMP/caps.json"
jq -n '{lcds:[{serial:"hid:1cbe:a018:8-12.2.1",path:"/a"},{serial:"hid:1cbe:a068:6-7.2.2",path:"/b"},{serial:"hid:1cbe:a088:8-10.2.2",path:"/c"}],
  rgb:{devices:[{device_id:"hid:0416:8050:6-10.2.3",n:"live"},{device_id:"wireless:aa:bb",n:"w"},{device_id:"hid:0416:8050:8-10.2.3",n:"stale"},
    {device_id:"hid:43a8:0102:8-12.4.4",n:"moved"},{device_id:"wireless:gone",n:"away"}]}}' >"$TMP/built-from.json"
reset; cp "$TMP/built-from.json" "$TMP/moved.json"; CFG=$TMP/moved.json follow_usb_moves
jq -e '[.lcds[].serial] == ["hid:1cbe:a018:6-12.2.1","hid:1cbe:a068:6-7.2.2","hid:1cbe:a088:8-10.2.2"]' "$TMP/moved.json" >/dev/null &&
  ok "screens follow the bus; one not on USB keeps its name" || bad "screens: $(jq -c '[.lcds[].serial]' "$TMP/moved.json")"
jq -e '[.rgb.devices[] | [.device_id, .n]] == [["hid:0416:8050:6-10.2.3","live"],["wireless:aa:bb","w"],["hid:43a8:0102:6-12.4.4","moved"],["wireless:gone","away"]]' "$TMP/moved.json" >/dev/null &&
  ok "lighting: stale entry dropped, moved one renamed, wireless untouched" || bad "lighting: $(jq -c '[.rgb.devices[].device_id]' "$TMP/moved.json")"
grep -q "moved to another bus" "$TMP/log" && ok "says so when something moved" || bad "no log line"
reset; jq -c . "$TMP/moved.json" >"$TMP/built-from.json"; cp "$TMP/built-from.json" "$TMP/again.json"; CFG=$TMP/again.json follow_usb_moves
[[ $(jq -cS . "$TMP/moved.json") == "$(jq -cS . "$TMP/again.json")" && ! -s $TMP/log ]] && ok "nothing moved (the daemon's own layout): unchanged and silent" || bad "second run changed the config or logged"
rm -f "$TMP/caps.json"; cp "$TMP/built-from.json" "$TMP/nocaps.json"
jq '.rgb.devices += [{device_id:"hid:0416:8051:8-7.2.3"}]' "$TMP/nocaps.json" >"$TMP/nocaps2.json"; CFG=$TMP/nocaps2.json follow_usb_moves
jq -e '.rgb.devices[-1].device_id == "hid:0416:8051:8-7.2.3"' "$TMP/nocaps2.json" >/dev/null && ok "no capabilities (screens switch): lighting left alone" || bad "lighting changed without capabilities"
jq -n '{data:[{device_id:"hid:0416:8050:6-10.2.3"}]}' >"$TMP/caps.json"; jq -n '{rgb:{devices:[{device_id:"hid:0416:8050:8-10.2.3"}]},lcds:[]}' >"$TMP/c.json"
daemon_call() { cat "$TMP/caps.saved"; }; cp "$TMP/caps.json" "$TMP/caps.saved"
: >"$TMP/sent"; CFG=$TMP/c.json fetch_caps 12
[[ $(grep -c '^sleep' "$TMP/sent") == 0 ]] && ok "fetch_caps doesn't wait for a device that only moved bus" || bad "fetch_caps waited"

echo; echo "passed $passed, failed $failed"
(( failed == 0 ))
