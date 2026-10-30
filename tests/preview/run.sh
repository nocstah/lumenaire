#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# run.sh — the theme preview's engine tests (editor plan §4, "B checks"):
# the session lifecycle, the SetRgbEffect requests per device type (TL
# regions and scopes, Strimers, rings), diffing and re-sends, OpenRGB only on
# change and never with a listing, blocked on the lock, the heat alert, a
# daemon restart mid-batch, the hooks (pick, on, off, apply-openrgb yield;
# the schedule defers; clips skip), the reaper (ui-gone, idle), SIGTERM, the
# rgbconfig method, the unmeasured refusal and contract v1.2.
#
#   tests/preview/run.sh [engine]   (default: the repo's bin/lumenaire)
#
# Everything runs against a fixture $HOME with tests/preview/stubs.sh:
# nothing reaches the lights, the real daemon socket or OpenRGB (checks.sh).
# KEEP_FIXTURE=1 keeps the fixture.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
engine=$(readlink -f "${1:-$here/../../bin/lumenaire}")
[[ -x $engine ]] || { echo "run.sh: no engine at $engine" >&2; exit 2; }
root=$(mktemp -d)
trap '[[ -n ${KEEP_FIXTURE:-} ]] || rm -rf "$root"' EXIT
passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [[ -z ${2:-} ]] || printf '     %s\n' "$2" | head -c 800; }
jcheck() {
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then ok "$1"; else bad "$1" "$(jq -c "$2" 2>&1 <<<"$3" | head -c 300)"; fi
}
# shellcheck source=checks.sh
source "$here/checks.sh"
echo "engine: $engine"
preview_suite "$engine" "$root"
echo
echo "passed $passed, failed $failed"
(( failed == 0 ))
