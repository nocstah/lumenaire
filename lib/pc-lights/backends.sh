# lib/pc-lights/backends.sh — what spans the backends: the §8 backend interface, the profile lookup, render
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP4 (backends)
# Public: render be_profile backend_enabled backend_probe backend_state backend_skip_note
#         backend_skipped; constants BACKENDS; state BE_STATE
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# ---- backends -----------------------------------------------------------------
# A backend is a set of functions be_<name>_<verb> (docs/BACKENDS.md). BACKENDS
# is the apply order; render prints the sections in the same order. Only
# *_apply and *_screens touch hardware.
#   be_<b>_probe                  one line of JSON {"state":"ok|absent|down|no-devices|error","message"}:
#                                 cheap, no socket writes, no device probes
#   be_<b>_detect <outdir>        writes <outdir>/<b>.json {"backend","state","version","devices":{key: Device}}
#   be_<b>_validate <eff>         one problem per line on stdout (nothing = fine)
#   be_<b>_build <state> <eff>    builds the plan in $TMP (pure: $TMP only, read-only daemon calls)
#   be_<b>_render                 prints the built plan in render's format
#   be_<b>_apply <state>          applies it
#   be_<b>_screens <state> <eff>  optional (lianli): screen media/brightness
#   be_<b>_kinds                  the device kinds it can drive
BACKENDS=(lianli openrgb)
declare -A BE_STATE=()

# The hardware profile, if there is a usable one: prints its path. PROFILE is
# an override point (tests/golden/frozen.sh), read at call time. No profile, or
# one that isn't a v1 object, means the legacy constants: exactly the engine
# before the portability work.
be_profile() {
  local pf=${PROFILE:-$STATE_DIR/profile.json}
  [[ -f $pf ]] && jq -e 'type == "object" and .v == 1' "$pf" >/dev/null 2>&1 || return 1
  echo "$pf"
}

# The user switched a backend off in the profile (backends.<b>.enabled = false).
backend_enabled() {
  local pf
  pf=$(be_profile) || return 0
  [[ $(jq -r --arg b "$1" '.backends[$b].enabled' "$pf" 2>/dev/null) != false ]]
}

# Probe once per run and cache the answer in BE_STATE (call it outside $(...),
# or the cache stays in the subshell). A probe that prints garbage is "error".
backend_probe() {
  local b=$1 r
  [[ -z ${BE_STATE[$b]:-} ]] || return 0
  if backend_enabled "$b"; then
    r=$("be_${b}_probe" 2>/dev/null) || true
    jq -e '.state | type == "string"' <<<"$r" >/dev/null 2>&1 || r='{"state":"error","message":"probe failed"}'
  else
    r='{"state":"disabled","message":"disabled in the profile"}'
  fi
  BE_STATE[$b]=$r
}
backend_state() { backend_probe "$1"; jq -r .state <<<"${BE_STATE[$1]}"; }
backend_skip_note() { backend_probe "$1"; echo "# $1: skipped ($(jq -r '.message // .state' <<<"${BE_STATE[$1]}"))"; }
# True when the backend sits this run out: absent, no-devices, disabled or error.
# "down" is not a skip: the caller dies with its own message, as before.
backend_skipped() {
  backend_probe "$1"
  [[ $(jq -r .state <<<"${BE_STATE[$1]}") =~ ^(absent|no-devices|disabled|error)$ ]]
}

# Dry run: build what "on" (or "off": --state off) would write, against
# scratch copies of the config. Takes no lock and never runs OpenRGB (listing
# devices probes the SMBus and HID devices, and a second OpenRGB beside an
# apply can glitch the ENE RAM controllers): the RAM ids come from the last
# real apply, or stand-ins. It changes nothing: the clip rotation restarts only
# on a real apply (lianli_lights).
#   render [--state on|off] [name]     (off with no name: the active theme's header)
render() {
  local state=on name=
  while (( $# )); do
    case $1 in
      --state)
        [[ ${2:-} =~ ^(on|off)$ ]] || die "usage: pc-lights render [--state on|off] [name]"
        state=$2; shift 2 ;;
      *) name=$1; shift ;;
    esac
  done
  name=${name:-$(active_name)}
  if [[ $state == on ]]; then
    theme_exists "$name" || die "no theme $THEME_DIR/$name/theme.json"
    THEME=$name
    validate_theme "$name"
  else
    THEME=$name
  fi
  # lianli-daemon down while there are Lian Li devices to drive (or no profile
  # to say there are none) is an error, worded as before the backends.
  backend_probe lianli; backend_probe openrgb
  [[ $(backend_state lianli) != down ]] || die "lianli-daemon must be running to read RGB capabilities"
  if backend_skipped lianli; then
    echo "# theme: $name (screens state: $(screens_state))"
    backend_skip_note lianli
  else
    be_lianli_build "$state"
    echo "# theme: $name (screens state: $(screens_state))"
    be_lianli_render
  fi
  if backend_skipped openrgb; then
    backend_skip_note openrgb
  else
    RAM_IDS=$(cat "$RAM_CACHE" 2>/dev/null || true)
    [[ -n ${RAM_IDS// /} ]] || RAM_IDS='RAM0 RAM1'
    RAM_IDS_DONE=1
    be_openrgb_build "$state"
    be_openrgb_render
  fi
}
