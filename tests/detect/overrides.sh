# overrides.sh — pins "pc-lights detect" to a set of frozen inputs.
#
# Sourced by the engine through its PCL_TEST_OVERRIDES hook, after every
# function is defined:
#
#   HOME=<fixture home> PCL_DETECT_FX=<inputs dir> PCL_TEST_OVERRIDES=tests/detect/overrides.sh pc-lights detect
#
# <inputs dir> has the layout of a golden capture's inputs/ (tests/golden/
# capture.sh): daemon/<Method>.json (no daemon/ = daemon not answering),
# sysfs-usb.tsv, hwmon.tsv, nvidia-information, cmdline, OpenRGB.json,
# openrgb-list.txt, sizes.ors, pacman-q.txt, systemd/lianli-daemon.service.d/, and two
# files only fixtures have: "have" (the commands installed, one per line;
# default: lianli-daemon openrgb nvidia-smi) and "hostname" (default
# example-desktop). Nothing here reaches the hardware: the daemon socket, guarded
# writes, units and OpenRGB are replaced, and HOME is a fixture.
# shellcheck shell=bash disable=SC2034

: "${PCL_DETECT_FX:?overrides.sh needs PCL_DETECT_FX=<inputs dir>}"
FX=$PCL_DETECT_FX
[[ $HOME != "${PCL_REAL_HOME:-/nonexistent}" ]] || { echo "overrides.sh: refusing to run against the real HOME" >&2; exit 97; }

CFG_LIVE=$FX/lianli/config.json CFG=$FX/lianli/config.json
ORGB_JSON=$FX/OpenRGB.json
LIANLI_DROPINS=$FX/systemd/lianli-daemon.service.d
ORGB_SIZES=$FX/sizes.ors

daemon_call() {
  local m
  m=$(jq -r .method <<<"$1")
  [[ -f $FX/daemon/$m.json ]] || return 1
  cat "$FX/daemon/$m.json"
}
daemon_guarded() { LIVE_ERR=blocked-in-test; return 1; }
systemctl() {
  case " $* " in
    *" is-active "*) [[ -f $FX/daemon/GetDaemonInfo.json ]] ;;
    *) echo "blocked: systemctl $*" >&2; return 1 ;;
  esac
}
systemd-run() { echo "blocked: systemd-run $*" >&2; return 1; }
logger() { :; }
pkill() { return 1; }
openrgb() { echo "overrides.sh: blocked: openrgb $*" >&2; return 1; }
# A probe: the listing, and a line in the fixture HOME so a test can count
# probes and check the lock was held (flock -n on it must fail). run.sh also
# puts a refusing "openrgb" first in PATH, so the real one can never run.
detect_openrgb_list() {
  if flock -n "$LOCK" true 2>/dev/null; then echo "unlocked" >>"$HOME/openrgb-probes.log"; else echo "locked" >>"$HOME/openrgb-probes.log"; fi
  cat "$FX/openrgb-list.txt" 2>/dev/null
}

detect_usb_tsv() { cat "$FX/sysfs-usb.tsv" 2>/dev/null || true; }
detect_hwmon_tsv() { cat "$FX/hwmon.tsv" 2>/dev/null || true; }
detect_nvidia_info() { cat "$FX/nvidia-information" 2>/dev/null || true; }
detect_cmdline() { cat "$FX/cmdline" 2>/dev/null || true; }
detect_have() {
  if [[ -f $FX/have ]]; then grep -qx -- "$1" "$FX/have"
  else [[ " lianli-daemon openrgb nvidia-smi " == *" $1 "* ]]; fi
}
detect_pkg_version() { awk -v p="$1" '$1 == p { print $2 }' "$FX/pacman-q.txt" 2>/dev/null || true; }
detect_unit_exists() { return 1; }
detect_hostname() { cat "$FX/hostname" 2>/dev/null || echo example-desktop; }
detect_now() { echo "${PCL_DETECT_NOW:-2026-09-24T16:00:00+02:00}"; }
