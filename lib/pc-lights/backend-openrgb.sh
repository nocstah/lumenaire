# lib/pc-lights/backend-openrgb.sh — the OpenRGB backend (GPU, motherboard and RAM through the OpenRGB CLI)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP4 (backends)
# Public: be_openrgb_{probe,detect,validate,build,render,apply,kinds} apply_openrgb openrgb_args
#         openrgb_params openrgb_py ram_ids openrgb_preview_args be_openrgb_preview
#         orgb_begin orgb_end ram_drift_{installed,params,sync,resume}; constants GPU BOARD RAM_CACHE
#         ORGB_LIST ORGB_LOCK RAM_DRIFT_UNIT RAM_DRIFT_JSON; state RAM_IDS RAM_IDS_DONE ORGB_DRIFT_WAS
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# The legacy constants: this machine's devices, used when there is no profile
# (and, through openrgb_py's defaults, by callers that pass no parameters).
GPU="ASUS ROG ASTRAL GeForce RTX 5090 OC"
BOARD="X870E AORUS MASTER X3D"

# RAM sticks all share one name ("ENE DRAM" here; -d by name would hit only
# the first), so address them by index. They exist only with the SMBus open
# (acpi_enforce_resources=lax on the kernel cmdline). Listing re-detects every
# device, so it runs once per invocation, and only in a real apply: the whole
# listing is kept in ORGB_LIST (tmp + mv) for detect, so detect never has to
# probe the SMBus itself.
RAM_IDS=
RAM_IDS_DONE=
RAM_CACHE=$CACHE/ram-ids
ORGB_LIST=$CACHE/openrgb-list.txt

# ---- one OpenRGB at a time, and the RAM drift ------------------------------------
# A theme's ram can drift (ramdrift.py): lumenaire-ram-drift.service runs a
# private DRAM-only OpenRGB server and slides the gradient along the sticks.
# A second OpenRGB beside it could glitch the ENE RAM controllers, so every
# OpenRGB process the engine starts (the listing, an apply, a preview, detect)
# goes between orgb_begin and orgb_end: stop the unit (synchronous), then hold
# openrgb.lock, which the animator holds for its whole life. After an apply,
# ram_drift_sync starts the unit again only when the lights are on and the
# theme drifts. Nothing here runs when the unit isn't installed (tests, other
# machines): then only the lock is taken.
RAM_DRIFT_UNIT=lumenaire-ram-drift.service
RAM_DRIFT_JSON=$CACHE/ram-drift.json
ORGB_LOCK=$CACHE/openrgb.lock
ORGB_DRIFT_WAS=

# Where install --units puts it (install.sh inst_units).
ram_drift_installed() { [[ -f $HOME/.config/systemd/user/$RAM_DRIFT_UNIT ]]; }

# orgb_begin: stop the drift (remembering whether it ran) and take openrgb.lock
# on fd 5. Fails (after 60 s) only if something else still holds the lock.
orgb_begin() {
  ORGB_DRIFT_WAS=
  if ram_drift_installed; then
    if systemctl --user is-active --quiet "$RAM_DRIFT_UNIT" 2>/dev/null; then ORGB_DRIFT_WAS=1; fi
    systemctl --user stop "$RAM_DRIFT_UNIT" 2>/dev/null || log "ram drift: could not stop $RAM_DRIFT_UNIT"
  fi
  exec 5>"$ORGB_LOCK"
  if ! flock -w "${PCL_ORGB_WAIT:-60}" 5; then
    exec 5>&-
    log "openrgb.lock is still held after 60 s (a ram-drift run outside its unit?); not starting a second OpenRGB"
    return 1
  fi
}

# orgb_end [--resume]: drop the lock; --resume starts the drift again if it
# ran before orgb_begin (detect --probe; an apply decides with ram_drift_sync).
orgb_end() {
  exec 5>&-
  if [[ ${1:-} == --resume && -n $ORGB_DRIFT_WAS && -s $RAM_DRIFT_JSON && $(lights_state) == on ]]; then
    systemctl --user start --no-block "$RAM_DRIFT_UNIT" 2>/dev/null || log "ram drift: could not start $RAM_DRIFT_UNIT"
  fi
  ORGB_DRIFT_WAS=
}

# ram_drift_params <eff>: the animator's parameters (JSON) for <eff> with the
# current RAM_IDS, or nothing when its ram doesn't drift.
ram_drift_params() {
  local eff=$1 op
  jq -e '.ram | objects | has("drift")' "$eff" >/dev/null 2>&1 || return 0
  op=$(openrgb_params)
  python3 "$PCL_LIB/ramdrift.py" params "$eff" "$RAM_IDS" "$op" "$ORGB_LIST"
}

# ram_drift_sync: after OpenRGB showed a theme (the params in $TMP/orgb.drift):
# lights on and a drifting ram = save the params and start the unit; anything
# else = no params (the unit stays stopped: orgb_begin stopped it).
ram_drift_sync() {
  if [[ $(lights_state) == on && -s $TMP/orgb.drift ]] && jq -e '.count > 0' "$TMP/orgb.drift" >/dev/null 2>&1; then
    put_json "$RAM_DRIFT_JSON" <"$TMP/orgb.drift"
    if ram_drift_installed; then
      systemctl --user start --no-block "$RAM_DRIFT_UNIT" 2>/dev/null || log "ram drift: could not start $RAM_DRIFT_UNIT"
    else
      log "ram drift: $RAM_DRIFT_UNIT is not installed (pc-lights install --units); the RAM keeps the first frame"
    fi
  else
    rm -f "$RAM_DRIFT_JSON"
  fi
}

# ram_drift_resume <eff>: after a preview put the active theme <eff> back.
ram_drift_resume() {
  local ids
  ids=$(cat "$RAM_CACHE" 2>/dev/null || true)
  [[ -n $(jq -r '.ram.match_name // empty' "$(openrgb_params)") ]] || ids=
  ( RAM_IDS=$ids; ram_drift_params "$1" ) >"$TMP/orgb.drift" 2>/dev/null || : >"$TMP/orgb.drift"
  ram_drift_sync
}

# ram_ids [name] [picks]: the listing indices of the devices called <name>
# (default "ENE DRAM"), or only the <picks>-th ones among them (0-based, in
# listing order: the "#i" of the profile's openrgb:<name>#<i> keys).
ram_ids() {
  local name=${1:-ENE DRAM} picks=${2:-} tmp=$ORGB_LIST.$$.tmp
  if [[ -z $RAM_IDS_DONE ]]; then
    orgb_begin || die "OpenRGB is busy (openrgb.lock); nothing sent to it"
    timeout 120 openrgb --list-devices >"$tmp" 2>/dev/null || true
    orgb_end
    RAM_IDS=$(awk -v n="$name" -v picks=" $picks " '
      match($0, /^[0-9]+: /) && substr($0, RLENGTH + 1) == n {
        if (picks ~ /^ +$/ || index(picks, " " (seen + 0) " ")) print substr($0, 1, RLENGTH - 2)
        seen++
      }' "$tmp" | tr '\n' ' ')
    # Keep the listing only when it lists something (a failed run keeps the last good one).
    if grep -qE '^[0-9]+: ' "$tmp" 2>/dev/null; then mv -f "$tmp" "$ORGB_LIST" || true; fi
    rm -f "$tmp"
    RAM_IDS_DONE=1
    # For render, which must never run OpenRGB (a listing probes the SMBus).
    if [[ -n ${RAM_IDS// /} ]]; then echo "$RAM_IDS" >"$RAM_CACHE"; fi
  fi
}

# The device names and parameters openrgb_py drives, as $TMP/orgb.json (path on
# stdout): {gpu: {name, leds, layout}, board: {name}, argb: {name, zones, size},
# ram: {match_name, leds_per_device, picks}, peripherals: [{role, name}]}; a
# null part is not driven. From
# the profile's roles (managed:false roles are left alone), or with no profile
# the legacy constants, which give exactly the arguments of the old engine.
openrgb_params() {
  local pf out=$TMP/orgb.json
  if pf=$(be_profile); then
    jq '. as $P
      | def dev($k): $P.devices[$k] // {};
        def dname($k): dev($k).match.name // dev($k).name;
        def role($r): $P.roles[$r] | objects | select(.managed != false);
      { gpu: (first(role("gpu") | {name: dname(.device), leds: (.leds // dev(.device).leds // 30),
                                   layout: (.layout // "linear")} | select(.name != null)) // null),
        board: (first(role("board") | {name: dname(.device)} | select(.name != null)) // null),
        argb: (first(role("board.argb") | select(.argb != null)
                 | {name: dname(.device), zones: (.argb.zones // []), size: .argb.size} | select(.name != null)) // null),
        ram: (first(role("ram") | ((.devices // [.device]) | map(strings)) as $ks
                | {match_name: (.match_name // dname($ks[0] // "")),
                   leds_per_device: (.leds_per_device // dev($ks[0] // "").leds // 8),
                   picks: ([$ks[] | (capture("#(?<i>[0-9]+)$").i | tonumber)? // empty])}
                | select(.match_name != null)) // null),
        # keyboard/mouse/mousepad/headset/ledstrip.<n>/other.<n>: only managed ones
        # (detect makes them managed:false), only OpenRGB-owned devices.
        peripherals: [$P.roles // {} | to_entries[]
          | select(.key | IN("keyboard", "mouse", "mousepad", "headset") or startswith("ledstrip.") or startswith("other."))
          | .key as $r | .value | objects | select(.managed != false)
          | ((.devices // [.device]) | map(strings))[] | select(dev(.).backend == "openrgb")
          | {role: $r, name: dname(.)} | select(.name != null)] }' "$pf" >"$out" ||
      die "could not read the OpenRGB devices from $pf"
  else
    jq -n --arg gpu "$GPU" --arg board "$BOARD" '
      {gpu: {name: $gpu, leds: 30, layout: "aura"}, board: {name: $board},
       argb: {name: $board, zones: [0, 1, 2, 3], size: 120},
       ram: {match_name: "ENE DRAM", leds_per_device: 8, picks: []}}' >"$out"
  fi
  echo "$out"
}

# Build the OpenRGB argument list (one per line) for $state and the theme
# ($2, default the active EFF). OpenRGB profiles don't keep ARGB zone sizes,
# and a zone of size 0 is left alone (the case strips on the 4 ARGB headers
# then run the board's built-in rainbow), so every apply resizes the headers
# and sets modes explicitly. The resize is -sz (OpenRGB 1.0rc's -s is speed:
# until 2026-09-24 this passed "-s 120" and never resized anything); OpenRGB
# also saves it to sizes.ors.
openrgb_args() {
  local state=$1 sf='' op name
  [[ $state == on ]] && sf=${2:-$(scheme_file)}
  op=$(openrgb_params)
  name=$(jq -r '.ram.match_name // empty' "$op")
  ram_ids "$name" "$(jq -r '.ram.picks // [] | map(tostring) | join(" ")' "$op")"
  # No RAM role: the listing above still refreshes the cache, but no stick is driven.
  [[ -n $name ]] || RAM_IDS=
  openrgb_py "$state" "$sf" "$RAM_IDS" "$op"
}

# openrgb_py <state> <theme.json|EFF> "<ram ids>" [orgb.json]: pure, touches
# nothing. Without orgb.json it drives the legacy constants (validate_theme
# calls it that way, with stand-in RAM ids). The float expressions (the Aura
# layout, the gradients, round()) are the pre-portability ones with only the
# constants swapped for parameters: at 30 GPU LEDs and 8 per stick they give
# byte-identical arguments.
openrgb_py() {
  python3 - "$1" "$2" "$3" "$BOARD" "$GPU" "${4:-}" "$PCL_LIB" <<'PY'
import json, re, sys
state, sf, ram_ids, board_name, gpu_name, op, pcl_lib = sys.argv[1:8]
ram_ids = ram_ids.split()
th = json.load(open(sf)) if state == 'on' else {}
if op:
    orgb = json.load(open(op))
else:
    orgb = {'gpu': {'name': gpu_name, 'leds': 30, 'layout': 'aura'}, 'board': {'name': board_name},
            'argb': {'name': board_name, 'zones': [0, 1, 2, 3], 'size': 120},
            'ram': {'match_name': 'ENE DRAM', 'leds_per_device': 8}}
gpu_p, board_p, argb_p, ram_p = (orgb.get(k) for k in ('gpu', 'board', 'argb', 'ram'))
gl = int(gpu_p.get('leds') or 30) if gpu_p else 30
aura = bool(gpu_p) and gpu_p.get('layout') == 'aura'
lpd = int(ram_p.get('leds_per_device') or 8) if ram_p else 8
if not ram_p:
    ram_ids = []
roles = th.get('_roles') or {}

def hx(s):
    s = str(s).strip().lstrip('#')
    if not re.fullmatch(r'[0-9a-fA-F]{6}', s):
        sys.exit('pc-lights: bad colour %r in theme' % s)
    return s.upper()

def rgb(s):
    s = hx(s)
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))

def fmt(c):
    return '%02X%02X%02X' % tuple(c)

def gradient(stops, n):
    # Evenly spaced linear stops, first at LED 0, last at LED n-1.
    cs = [rgb(h) for h in stops]
    if len(cs) == 1:
        return [cs[0]] * n
    out = []
    for i in range(n):
        t = i / (n - 1) * (len(cs) - 1)
        k = min(int(t), len(cs) - 2)
        f = t - k
        a, b = cs[k], cs[k + 1]
        out.append(tuple(round(a[j] + (b[j] - a[j]) * f) for j in range(3)))
    return out

def mode_args(o):
    a = ['-m', str(o['mode'])]
    if o.get('colors'):
        a += ['-c', ','.join(hx(c) for c in o['colors'])]
    if o.get('speed') is not None:
        a += ['-s', str(o['speed'])]
    if o.get('brightness') is not None:
        a += ['-b', str(o['brightness'])]
    return a

def static(h):
    return ['-m', 'static', '-c', hx(h)]

def direct(colors):
    return ['-m', 'direct', '-c', ','.join(fmt(c) for c in colors)]

if state == 'on':
    g = th.get('gpu', '000000')
    if isinstance(g, str):
        gpu = static(g)
    elif 'gradient' in g and len(g['gradient']) == 2 and aura:
        # Laid out like Aura's "Cyberpunk" script: first colour up to x=80,
        # second from x=240, blend between (320 wide, gl LEDs: 30 on the Astral).
        a, m = rgb(g['gradient'][0]), rgb(g['gradient'][1])
        gpu = ['-m', 'direct', '-c', ','.join('%02X%02X%02X' % tuple(round(a[k] + (m[k]-a[k]) * min(1, max(0, ((i+.5)*320/gl - 80)/160))) for k in range(3)) for i in range(gl))]
    elif 'gradient' in g:
        gpu = direct(gradient(g['gradient'], gl))
    else:
        gpu = mode_args(g)
    b = th.get('board', '000000')
    board = static(b) if isinstance(b, str) else mode_args(b)
    # The ARGB headers take the board.argb role's value when the EFF has one.
    ab = (roles.get('board.argb') or {}).get('board', b)
    argb = static(ab) if isinstance(ab, str) else mode_args(ab)
    r = th.get('ram', '000000')
    n = len(ram_ids)
    if isinstance(r, dict) and 'drift' in r:
        # A drifting gradient (ramdrift.py): its frame 0, which the
        # animator (lumenaire-ram-drift.service) moves on from.
        sys.path.insert(0, pcl_lib)
        import ramdrift
        errs = ramdrift.check(r)
        if errs:
            sys.exit('\n'.join('pc-lights: ' + e for e in errs))
        for h in r['gradient']:
            hx(h)
        d = ramdrift.settings(r)
        ram = [direct(cs) for cs in ramdrift.stick_frames(r['gradient'], r.get('span', 'across'), n, lpd, 0.0,
                                                          d['window'], d['reverse'])]
    elif isinstance(r, str):
        ram = [static(r)] * n
    elif 'gradient' in r:
        if r.get('span', 'across') == 'stick':
            ram = [direct(gradient(r['gradient'], lpd))] * n
        else:
            cs = gradient(r['gradient'], lpd * n) if n else []
            ram = [direct(cs[lpd * i:lpd * i + lpd]) for i in range(n)]
    elif 'leds' in r:
        cs = [rgb(h) for h in r['leds']]
        if len(cs) != 2 * lpd:
            sys.exit('pc-lights: ram.leds needs %d colours' % (2 * lpd))
        ram = [direct(cs[lpd * i:lpd * i + lpd]) for i in range(min(n, 2))]
    else:
        ram = [mode_args(r)] * n
else:
    gpu = ['-m', 'off']
    board = ['-m', 'static', '-c', '000000']
    argb = board
    ram = [['-m', 'off']] * len(ram_ids)

# A device group with only -sz is rejected ("neither mode nor color given"),
# so each header resize carries the headers' own mode and colour. A size of
# null never resizes (another machine's headers stay as the user set them).
args = []
if argb_p and argb_p.get('size') is not None:
    for z in argb_p.get('zones') or []:
        args += ['-d', argb_p['name'], '-z', str(z), '-sz', str(argb_p['size'])] + argb
for i, a in zip(ram_ids, ram):
    args += ['-d', i] + a
if board_p:
    args += ['-d', board_p['name']] + board
if gpu_p:
    args += ['-d', gpu_p['name']] + gpu
# Managed peripherals take their role's value from the EFF (_roles[R].peripheral:
# a colour or {mode, colors, ...}); a role with no value there is left alone.
for p in orgb.get('peripherals') or []:
    v = (roles.get(p['role']) or {}).get('peripheral')
    if state != 'on':
        args += ['-d', p['name'], '-m', 'static', '-c', '000000']
    elif v is not None:
        args += ['-d', p['name']] + (static(v) if isinstance(v, str) else mode_args(v))
print('\n'.join(args))
PY
}

# ---- the §8 interface -----------------------------------------------------------
be_openrgb_kinds() { echo "gpu board ram peripheral"; }

# Cheap: never runs OpenRGB (a listing probes the SMBus).
be_openrgb_probe() {
  local pf
  if ! command -v openrgb >/dev/null 2>&1; then
    echo '{"state":"absent","message":"OpenRGB is not installed"}'; return 0
  fi
  if pf=$(be_profile) && ! jq -e '[.devices // {} | .[] | select(.backend == "openrgb")] | length > 0' "$pf" >/dev/null 2>&1; then
    echo '{"state":"no-devices","message":"no OpenRGB devices in the profile"}'; return 0
  fi
  echo '{"state":"ok"}'
}

# be_openrgb_detect <outdir> [--probe]: <outdir>/openrgb.json in the §8 shape
# {backend, state, version, devices: {key: Device}} (plus message, listing and
# scanned), from the listing the last apply cached. A thin wrapper over
# detect.sh's detect_openrgb, the one scanner and listing parser
# (detect_openrgb_parse): --probe (or no cache) lists afresh, which probes the
# SMBus, so the caller must hold the pc-lights lock (never beside an apply).
be_openrgb_detect() {
  local out=$1 mode=cache
  [[ ${2:-} == --probe ]] && mode=probe
  mkdir -p "$out"
  detect_openrgb "$out" "$mode"
}

# be_openrgb_validate <eff>: the OpenRGB half of the theme against this
# machine's parameters (stand-in RAM ids), one problem per line.
be_openrgb_validate() {
  local op
  op=$(openrgb_params)
  openrgb_py on "$1" "ram0 ram1" "$op" 2>&1 >/dev/null | sed 's/^pc-lights: //' || true
}

# be_openrgb_build <state> [eff]: $TMP/orgb.args, one argument per line. It
# lists the devices for the RAM ids unless RAM_IDS_DONE (render sets it).
be_openrgb_build() {
  local eff=${2:-}
  [[ $1 == on && -z $eff ]] && eff=$(scheme_file)
  openrgb_args "$1" "$eff" >"$TMP/orgb.args" || die "could not build the OpenRGB command"
  : >"$TMP/orgb.drift"
  if [[ $1 == on ]]; then
    ram_drift_params "$eff" >"$TMP/orgb.drift" || die "could not build the RAM drift"
  fi
}

be_openrgb_render() {
  local args=()
  mapfile -t args <"$TMP/orgb.args"
  echo "# openrgb (RAM ids: $RAM_IDS)"
  printf '%q ' timeout 120 openrgb "${args[@]}"; echo
  if [[ -s $TMP/orgb.drift ]]; then python3 "$PCL_LIB/ramdrift.py" describe "$TMP/orgb.drift"; fi
}

be_openrgb_apply() {
  local state=$1 args=()
  mapfile -t args <"$TMP/orgb.args"
  if [[ -z ${args[*]} ]]; then log "openrgb: no managed device to drive"; return 0; fi
  orgb_begin || die "OpenRGB is busy (openrgb.lock); the $state state was not applied"
  if ! timeout 120 openrgb "${args[@]}" >/dev/null 2>&1; then
    orgb_end
    die "OpenRGB failed to apply the $state state"
  fi
  orgb_end
}

# The login unit's and every apply's entry point (a thin wrapper: the contract
# test stubs it by this name).
apply_openrgb() {
  local state
  if backend_skipped openrgb; then
    log "openrgb: skipped ($(jq -r '.message // .state' <<<"${BE_STATE[openrgb]}"))"
    return 0
  fi
  state=$(lights_state)
  be_openrgb_build "$state"
  be_openrgb_apply "$state"
  ram_drift_sync
}

# ---- the theme preview (plan §1.5) ---------------------------------------------
# openrgb_preview_args <eff>: the "on" arguments for <eff>, one a line, with
# the RAM ids the last real apply cached: never a device listing (it probes
# the SMBus, and a probe beside a write can glitch the ENE RAM controllers).
# No cached ids = the sticks are left out. Pure.
openrgb_preview_args() {
  local op
  op=$(openrgb_params)
  RAM_IDS=$(cat "$RAM_CACHE" 2>/dev/null || true)
  RAM_IDS_DONE=1
  [[ -n $(jq -r '.ram.match_name // empty' "$op") ]] || RAM_IDS=
  openrgb_py on "$1" "$RAM_IDS" "$op"
}

# be_openrgb_preview <eff> [args-file]: show <eff>'s GPU, board and RAM
# (arguments from openrgb_preview_args, or the file already built from
# them). The caller holds the lock; it is never killed (timeout 120 is the
# only limit), and it fails without dying.
be_openrgb_preview() {
  local eff=$1 af=${2:-} args=()
  if [[ -z $af ]]; then
    af=$TMP/orgb-preview.args
    openrgb_preview_args "$eff" >"$af" || return 1
  fi
  mapfile -t args <"$af"
  if [[ -z ${args[*]} ]]; then return 0; fi
  orgb_begin || return 1
  local rc=0
  timeout 120 openrgb "${args[@]}" >/dev/null 2>&1 || rc=$?
  orgb_end
  return "$rc"
}
