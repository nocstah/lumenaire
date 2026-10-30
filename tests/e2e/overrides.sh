# overrides.sh — pins the whole engine (not only detect) to one of the
# tests/detect/fixtures machines, for tests/e2e/run.sh.
#
#   HOME=<fixture home> PCL_DETECT_FX=<fixture dir> PCL_E2E_SYS=<fake sysfs root>
#   PCL_TEST_OVERRIDES=tests/e2e/overrides.sh pc-lights <cmd>
#
# On top of tests/detect/overrides.sh (the daemon from the fixture's daemon/,
# the fixture's hwmon/USB/NVIDIA tables, no units, no OpenRGB): the USB serial
# map and the LCD count come from the fixture's sysfs-usb.tsv, and sensors
# --json reads a fake sysfs/procfs tree run.sh builds from hwmon.tsv and
# nvidia-information. Nothing reads this machine's devices or reaches the
# hardware; HOME is a fixture (the detect overrides refuse the real one).
# shellcheck shell=bash disable=SC2034
: "${PCL_E2E_SYS:?overrides.sh needs PCL_E2E_SYS=<fake sysfs root>}"
# shellcheck source=tests/detect/overrides.sh
source "$(dirname "${BASH_SOURCE[0]}")/../detect/overrides.sh"

SENSORS_SYS=$PCL_E2E_SYS/sys SENSORS_PROC=$PCL_E2E_SYS/proc
PCL_SYSFS=$PCL_E2E_SYS/sys PCL_PROCFS=$PCL_E2E_SYS/proc

# The same shape as backend-lianli.sh's usb_serial_map (vendor 1cbe only).
usb_serial_map() {
  awk -F'\t' '$2 == "1cbe" && $4 != "" { printf "{\"serial\":\"%s\",\"path\":\"hid:1cbe:%s:%s\"}\n", $4, $3, $1 }' \
    "$FX/sysfs-usb.tsv" 2>/dev/null | jq -s 'map({(.serial): .path}) | add // {}' >"$TMP/usbmap.json"
  echo "$TMP/usbmap.json"
}
usb_screens() { awk -F'\t' '$2 == "1cbe" && $3 ~ /^(a018|a068|a088)$/ { n++ } END { print n + 0 }' "$FX/sysfs-usb.tsv" 2>/dev/null; }
lsusb() { :; }
journalctl() { return 0; }
