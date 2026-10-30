#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# run.sh — compare an engine with the pc-lights goldens (portability plan §7).
#
#   tests/golden/run.sh [--engine PATH] [--golden DIR] [--profile none|real|nocal]
#                       [--themes DIR] [--off auto|render|function] [--live [--ref-themes DIR]] [-v]
#
# For every captured theme it runs "<engine> render <theme>" through frozen.sh
# (the capture's frozen inputs) and requires stdout and the exit code to be
# byte-identical to the live golden; a stderr difference is only a warning.
# Then the probes: the off state, themes --json colours, the rotation in
# status --json, clips status and the status text.
#
# After the cut-over (README.md) nothing here reads the live theme dir: a
# capture's capture.conf names its frozen theme snapshot and its profile.
#   golden/current  the post-cut-over capture: v3 themes (themes-v3/), profile
#                   real (<capture>/profile.json): plain "run.sh" checks it
#   golden/v2       the migration-era capture: v2 themes (themes-v2/),
#                   profile none: "run.sh --golden ~/.cache/pc-lights/golden/v2"
#
#   --engine   the engine to test (default ~/.local/bin/pc-lights)
#   --golden   the capture (default ~/.cache/pc-lights/golden/current)
#   --profile  none (stage a/c, no profile.json), real (stage b/d:
#              $PCL_GOLDEN_PROFILE_FILE, default <capture>/profile.json), or
#              nocal (the real profile with calibration.enabled = false);
#              default: the capture's capture.conf "profile", else none
#   --themes   a shadow theme dir (migrate --out, or a frozen snapshot):
#              THEME_DIR points there and its prefix is mapped back to the
#              real one before diffing (the only place such a rewrite is
#              allowed); default: the capture's capture.conf "themes"
#              (a dir inside the capture), else the real theme dir (a capture
#              from before capture.conf existed)
#   --off      how the off probe runs: "render" = render --state off,
#              "function" = frozen.sh calls write_lianli_rgb/openrgb_args off,
#              "auto" (default) = render --state off, else function
#   --live     also render against the real $HOME: against the goldens while
#              the live render inputs still hash as captured, otherwise side
#              by side with the capture's reference engine (see below)
#   --ref-themes  the v2 theme dir the reference engine reads in that
#              side-by-side check (themes.pre-v3-<date> after migrate)
#   -v         show the diffs
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

engine=$HOME/.local/bin/pc-lights g=$GOLDEN_ROOT/current profile='' themes_dir='' off=auto live='' verbose='' ref_themes=''
while (( $# )); do
  case $1 in
    --engine) engine=$2; shift 2 ;;
    --golden) g=$2; shift 2 ;;
    --profile) profile=$2; shift 2 ;;
    --themes) themes_dir=$(readlink -f "$2"); shift 2 ;;
    --off) off=$2; shift 2 ;;
    --live) live=1; shift ;;
    --ref-themes) ref_themes=$(readlink -f "$2"); shift 2 ;;
    -v) verbose=1; shift ;;
    *) sed -n '2,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0" >&2; exit 2 ;;
  esac
done
engine=$(readlink -f "$engine")
g=$(readlink -f "$g")
[[ -x $engine ]] || { echo "run.sh: no engine at $engine" >&2; exit 2; }
[[ -f $g/themes.txt && -d $g/live ]] || { echo "run.sh: no golden capture at $g (run capture.sh)" >&2; exit 2; }
profile=${profile:-$(golden_conf "$g" profile none)}
if [[ -z $themes_dir ]]; then
  t=$(golden_conf "$g" themes)
  if [[ -n $t ]]; then
    themes_dir=$(readlink -f "$g/$t")
    [[ -d $themes_dir ]] || { echo "run.sh: $g/capture.conf names themes=$t, which is missing" >&2; exit 2; }
    golden_check_themes "$themes_dir" || { echo "run.sh: the frozen themes in $themes_dir changed since the capture" >&2; exit 2; }
  fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
real_themes=$HOME/.config/pc-lights/themes

case $profile in
  none) export PCL_GOLDEN_PROFILE=$g/inputs/state/no-profile.json ;;
  real | nocal)
    pf=${PCL_GOLDEN_PROFILE_FILE:-$g/profile.json}
    [[ -f $pf ]] || { echo "run.sh: --profile $profile needs $pf (set PCL_GOLDEN_PROFILE_FILE)" >&2; exit 2; }
    if [[ $profile == nocal ]]; then
      jq '.calibration.enabled = false' "$pf" >"$work/profile.nocal.json"; pf=$work/profile.nocal.json
    fi
    export PCL_GOLDEN_PROFILE=$pf ;;
  *) echo "run.sh: --profile none|real|nocal" >&2; exit 2 ;;
esac
if [[ -n $themes_dir ]]; then export PCL_GOLDEN_THEME_DIR=$themes_dir; fi
unshadow() { if [[ -n $themes_dir ]]; then sed "s#$themes_dir#$real_themes#g"; else cat; fi; }

echo "engine:  $engine ($(sha256sum <"$engine" | cut -c1-16))"
echo "golden:  $g"
echo "profile: $profile${themes_dir:+, themes $themes_dir}"

mapfile -t themes <"$g/themes.txt"
pass=0 fail=0 warn=0
# compare <label> <got> <want>: byte comparison, with a diff under -v.
compare() {
  if cmp -s "$2" "$3"; then return 0; fi
  if [[ -n $verbose ]]; then diff -u "$3" "$2" | head -40 | sed 's/^/      /'; fi
  return 1
}

# ---- renders --------------------------------------------------------------------
for t in "${themes[@]}"; do
  rc=0
  frozen_run "$g" "$engine" render "$t" >"$work/$t.raw" 2>"$work/$t.err" || rc=$?
  unshadow <"$work/$t.raw" >"$work/$t.out"
  want_rc=$(cat "$g/live/$t.rc")
  if compare "$t" "$work/$t.out" "$g/live/$t.out" && [[ $rc == "$want_rc" ]]; then
    pass=$((pass + 1)); printf 'ok   render %-28s %s\n' "$t" "$(sha256sum <"$work/$t.out" | cut -c1-16)"
  else
    fail=$((fail + 1)); printf 'FAIL render %-28s rc %s (want %s)\n' "$t" "$rc" "$want_rc"
  fi
  if ! unshadow <"$work/$t.err" | cmp -s - "$g/live/$t.err"; then
    warn=$((warn + 1)); printf 'warn render %-28s stderr differs\n' "$t"
  fi
done
renders="$pass/${#themes[@]}"

# ---- probes ---------------------------------------------------------------------
how=$off
if [[ $off == auto ]]; then
  rc=0; frozen_run "$g" "$engine" render --state off >/dev/null 2>&1 || rc=$?
  if (( rc == 0 )); then how=render; else how=function; fi
fi
golden_probes "$g" "$engine" "$how" "$work/probes"
ppass=0
for p in "${GOLDEN_PROBES[@]}"; do
  label=$p; [[ $p != off ]] || label="off ($how)"
  if compare "$p" "$work/probes/probe-$p.out" "$g/probes/probe-$p.out" &&
     { [[ $p != off ]] || cmp -s "$work/probes/probe-off.rc" "$g/probes/probe-off.rc"; }; then
    ppass=$((ppass + 1)); printf 'ok   probe  %s\n' "$label"
  else
    fail=$((fail + 1)); printf 'FAIL probe  %s\n' "$label"
  fi
done

# ---- live -----------------------------------------------------------------------
# While the live render inputs still hash as captured, the live renders must
# equal the goldens. They rarely do for long: the clip timer rewrites the
# rotating screen's path in config.json every few minutes. Then each theme is
# rendered live by the reference engine and by this one back to back, and
# compared, as long as the inputs did not move in between (--ref-themes points
# the reference engine at a v2 copy of the themes once they are migrated).
if [[ -n $live ]]; then
  golden_render_inputs "$work/now"
  lpass=0
  if diff -q <(golden_hash_dir "$g/before") <(golden_hash_dir "$work/now") >/dev/null; then
    for t in "${themes[@]}"; do
      rc=0
      PCL_TEST_OVERRIDES=$g/live-overrides.sh "$engine" render "$t" >"$work/$t.live" 2>/dev/null || rc=$?
      if compare "$t" "$work/$t.live" "$g/live/$t.out" && [[ $rc == "$(cat "$g/live/$t.rc")" ]]; then
        lpass=$((lpass + 1))
      else
        fail=$((fail + 1)); printf 'FAIL live   %-28s rc %s\n' "$t" "$rc"
      fi
    done
    echo "live: $lpass/${#themes[@]} identical to the goldens"
  else
    echo "live: live state moved since capture; frozen result is authoritative; comparing with the reference engine live"
    ref=$g/$(golden_conf "$g" reference pc-lights.pre-portable)
    { cat "$g/live-overrides.sh"; if [[ -n $ref_themes ]]; then echo "THEME_DIR=$ref_themes"; fi; } >"$work/ref-overrides.sh"
    for t in "${themes[@]}"; do
      for _ in 1 2 3; do
        rm -rf "$work/pre"; golden_render_inputs "$work/pre"
        rc=0 rrc=0
        PCL_TEST_OVERRIDES=$work/ref-overrides.sh "$ref" render "$t" 2>/dev/null >"$work/$t.ref" || rrc=$?
        PCL_TEST_OVERRIDES=$g/live-overrides.sh "$engine" render "$t" >"$work/$t.live" 2>/dev/null || rc=$?
        rm -rf "$work/post"; golden_render_inputs "$work/post"
        diff -q <(golden_hash_dir "$work/pre") <(golden_hash_dir "$work/post") >/dev/null && break
      done
      if [[ -n $ref_themes ]]; then sed -i "s#$ref_themes#$real_themes#g" "$work/$t.ref"; fi
      if compare "$t" "$work/$t.live" "$work/$t.ref" && [[ $rc == "$rrc" ]]; then
        lpass=$((lpass + 1))
      else
        fail=$((fail + 1)); printf 'FAIL live   %-28s rc %s (reference %s)\n' "$t" "$rc" "$rrc"
      fi
    done
    echo "live: $lpass/${#themes[@]} identical to the reference engine"
  fi
fi

echo "renders $renders identical, probes $ppass/${#GOLDEN_PROBES[@]} identical, stderr warnings $warn"
(( fail == 0 ))
