# lib/pc-lights/detect.sh — hardware detection into the profile (plan §6)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP2 (profile + detect)
# Public: detect_cmd; the one hardware scanner of the engine: detect_lianli and
#         detect_openrgb (be_lianli_detect / be_openrgb_detect wrap them),
#         detect_openrgb_parse (the OpenRGB listing parser) and
#         detect_sensors_json (the sensor heuristics; sensors.sh calls it)
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# Detect reads, never writes, the hardware: the Lian Li daemon's read-only
# calls (ListDevices, GetRgbCapabilities, GetConfig, GetDaemonInfo), sysfs,
# /proc, and the OpenRGB listing the last real apply cached. Only --probe (or
# no cache yet) runs "openrgb --list-devices", and only under the pc-lights
# lock, because a second OpenRGB beside an apply can glitch the ENE RAM
# controllers. The result is merged into profile.json by profile_merge
# (profile.sh), which keeps the user's edits.
DETECT_VERSION=1
MODELS=${PCL_MODELS:-$PCL_LIB/models.json}
# ORGB_LIST (the listing cache every real apply refreshes) is backend-openrgb.sh's.
ORGB_JSON=$HOME/.config/OpenRGB/OpenRGB.json
# OpenRGB's saved zone sizes (the GUI's "Resize" writes it; OpenRGB applies it
# at start): where detect reads an addressable header's LED count from.
ORGB_SIZES=$HOME/.config/OpenRGB/sizes.ors
LIANLI_DROPINS=$HOME/.config/systemd/user/lianli-daemon.service.d
PCL_SYSFS=/sys
PCL_PROCFS=/proc

# ---- raw inputs (the test override points) -----------------------------------------
# Each prints the same format tests/golden/capture.sh freezes, so a test can
# replace any of them with a cat of the captured file.

# USB devices: path vid pid serial manufacturer product (tab separated).
detect_usb_tsv() {
  local d
  for d in "$PCL_SYSFS"/bus/usb/devices/*; do
    [[ -f $d/idVendor ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${d##*/}" "$(cat "$d/idVendor")" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$(cat "$d/serial" 2>/dev/null || true)" "$(cat "$d/manufacturer" 2>/dev/null || true)" "$(cat "$d/product" 2>/dev/null || true)"
  done
}

# hwmon: "hwmonN <attribute> <value>" rows (name, device link, temp labels and
# inputs, and the GPU hints boot_vga / mem_info_vram_total behind the link),
# plus "thermal_zoneN type x86_pkg_temp" for the Intel package zone (the CPU
# fallback). Builtins only (sensors --json runs this when there is no
# profile, and has a 30 ms budget); the device link is resolved for GPUs only.
detect_hwmon_tsv() {
  local h f n v
  for h in "$PCL_SYSFS"/class/hwmon/hwmon*; do
    [[ -e $h ]] || continue
    n=${h##*/} v=
    [[ -r $h/name ]] && { read -r v <"$h/name" || true; }
    printf '%s\tname\t%s\n' "$n" "$v"
    if [[ $v =~ ^(amdgpu|xe|i915|nouveau)$ ]]; then
      printf '%s\tdevice\t%s\n' "$n" "$(readlink -f "$h/device" 2>/dev/null || true)"
    else
      printf '%s\tdevice\t\n' "$n"
    fi
    # An input's value is never read: only that it exists (reading one can
    # take a slow bus transfer, e.g. spd5118 over SMBus).
    for f in "$h"/temp*_input; do
      if [[ -r $f ]]; then printf '%s\t%s\t\n' "$n" "${f#"$h"/}"; fi
    done
    for f in "$h"/temp*_label "$h"/device/boot_vga "$h"/device/mem_info_vram_total; do
      if [[ -r $f ]]; then v=; read -r v <"$f" || true; printf '%s\t%s\t%s\n' "$n" "${f#"$h"/}" "$v"; fi
    done
  done
  for h in "$PCL_SYSFS"/class/thermal/thermal_zone*; do
    [[ -r $h/type ]] || continue
    v=; read -r v <"$h/type" || true
    if [[ $v == x86_pkg_temp ]]; then printf '%s\ttype\t%s\n' "${h##*/}" "$v"; fi
  done
}

# The NVIDIA driver's per-GPU information files, concatenated.
detect_nvidia_info() { cat "$PCL_PROCFS"/driver/nvidia/gpus/*/information 2>/dev/null || true; }
detect_cmdline() { cat "$PCL_PROCFS/cmdline" 2>/dev/null || true; }
detect_have() { command -v "$1" >/dev/null 2>&1; }
# The installed package version (pacman only; anything else prints nothing).
detect_pkg_version() { pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true; }
# A user or system unit file exists (whether or not it runs).
detect_unit_exists() {
  local d
  for d in "$HOME/.config/systemd/user" /etc/systemd/user /usr/lib/systemd/user; do
    [[ -e $d/$1 ]] && return 0
  done
  return 1
}
detect_hostname() { cat /etc/hostname 2>/dev/null || uname -n; }
# The one place detect runs OpenRGB (it probes the SMBus and HID devices):
# only from detect_openrgb, with the pc-lights lock held.
# The listing probes the SMBus: never beside the RAM drift's OpenRGB (orgb_begin).
detect_openrgb_list() {
  local rc=0
  orgb_begin || return 1
  timeout 120 openrgb --list-devices 2>/dev/null || rc=$?
  orgb_end --resume
  return "$rc"
}
detect_now() { date -Iseconds; }

# ---- OpenRGB listing ------------------------------------------------------------------
# detect_openrgb_parse <listing>: one JSON array, a device per "N: name" block:
# {index, name, type, location, zones: [...], leds: <count>}. It copes with
# what the real listing does: junk before the first device ("Connection
# attempt failed", an HTML I2C warning), values that wrap onto a second line
# (the GPU's Version/Location), trailing spaces (the Razer serial) and quoted
# zone/LED names with spaces ('I/O Cover').
detect_openrgb_parse() {
  jq -Rs --arg q "'" '
    def toks: [scan("\($q)[^\($q)]*\($q)|[^ \($q)]+") | ltrimstr($q) | rtrimstr($q)];
    def trimr: sub("\\s+$"; "");
    split("\n")
    | reduce .[] as $l ({d: [], k: null};
        (.d | length) as $n
        | if ($l | test("^[0-9]+: ")) then
            ($l | capture("^(?<i>[0-9]+): (?<n>.*)$")) as $h
            | .d += [{index: ($h.i | tonumber), name: ($h.n | trimr)}] | .k = null
          elif $n == 0 then .
          elif ($l | test("^  [A-Za-z][A-Za-z ]*:")) then
            ($l | capture("^  (?<k>[A-Za-z][A-Za-z ]*?):\\s*(?<v>.*)$")) as $f
            | .d[$n - 1][$f.k] = ($f.v | trimr) | .k = $f.k
          elif ($l | test("^\\s*$")) then .k = null
          elif .k != null then .d[$n - 1][.k] += " " + ($l | sub("^\\s+"; "") | trimr)
          else . end)
    | .d | map({index, name, type: (.Type // null), location: (.Location // null),
                zones: ((.Zones // "") | toks), leds: ((.LEDs // "") | toks | length)})' "$1"
}

# detect_openrgb_sizes <sizes.ors>: the zone sizes OpenRGB saved, as one JSON
# array [{name, location, zones: [{name, min, max, count}]}]; [] when the
# file is missing or unreadable. The file is an OpenRGB profile
# ("OPENRGB_PROFILE\0", u32 version, then one controller description per
# device in the SDK's wire format: u32 size, type, six u16-length strings,
# modes, zones, ...). Only the zones are read; each controller is skipped by
# its size, and a parse error drops the whole file (null size, never a guess).
detect_openrgb_sizes() {
  [[ -s $1 ]] || { echo '[]'; return 0; }
  python3 - "$1" <<'PY' 2>/dev/null || echo '[]'
import json, struct, sys
d = open(sys.argv[1], 'rb').read()
out = []
try:
    if d[:16] != b'OPENRGB_PROFILE\0':
        raise ValueError('not an OpenRGB profile')
    ver = struct.unpack_from('<I', d, 16)[0]
    i = 20

    def u16(o):
        return struct.unpack_from('<H', d, o)[0]

    def s(o):
        n = u16(o)
        return d[o + 2:o + 2 + n].rstrip(b'\0').decode('utf-8', 'replace'), o + 2 + n
    while i + 4 <= len(d):
        end = i + struct.unpack_from('<I', d, i)[0]
        if end <= i + 4 or end > len(d):
            raise ValueError('bad controller size')
        o = i + 8                      # size, device type
        f = {}
        for k in ('name', 'vendor', 'description', 'version', 'serial', 'location'):
            f[k], o = s(o)
        nm = u16(o)
        o += 2 + 4                     # mode count, active mode
        for _ in range(nm):            # name, value, flags, then 10 (v3+) or 7 u32 fields
            _, o = s(o)
            o += 8 + 4 * (10 if ver >= 3 else 7)
            o += 2 + 4 * u16(o)        # the mode's colours
        nz = u16(o)
        o += 2
        zones = []
        for _ in range(nz):
            zn, o = s(o)
            _, mn, mx, cnt = struct.unpack_from('<iIII', d, o)
            o += 16
            o += 2 + u16(o)            # matrix map
            if ver >= 4:               # segments
                ns = u16(o)
                o += 2
                for _ in range(ns):
                    _, o = s(o)
                    o += 12
            if ver >= 5:               # zone flags
                o += 4
            if o > end:
                raise ValueError('zone past the controller')
            zones.append({'name': zn, 'min': mn, 'max': mx, 'count': cnt})
        out.append({'name': f['name'], 'location': f['location'], 'zones': zones})
        i = end
except Exception:
    out = []
print(json.dumps(out))
PY
}

# detect_openrgb <outdir> <mode: cache|probe|skip>: <outdir>/openrgb.json =
# {backend, state, version, message, scanned, devices: {key: Device}}.
# Keys are "openrgb:<name>#<i>", i counting same-name devices in listing order.
detect_openrgb() {
  local out=$1 mode=$2 st=ok msg='' how=cache src=$ORGB_LIST ver rc=0
  ver=$(detect_pkg_version openrgb); ver=${ver%-*}
  if [[ $mode == skip ]]; then
    jq -n '{backend: "openrgb", state: "unknown", message: "not scanned (--no-openrgb)", scanned: false, devices: {}}' >"$out/openrgb.json"
    return 0
  fi
  if ! detect_have openrgb; then
    jq -n '{backend: "openrgb", state: "absent", message: "openrgb is not installed", scanned: true, devices: {}}' >"$out/openrgb.json"
    return 0
  fi
  if [[ $mode == probe || ! -s $ORGB_LIST ]]; then
    # The caller holds the lock (detect_cmd), so no apply runs beside this.
    progress "openrgb probe"
    detect_openrgb_list >"$out/openrgb-list.txt" || rc=$?
    if grep -Eq '^[0-9]+: ' "$out/openrgb-list.txt"; then
      mkdir -p "${ORGB_LIST%/*}"
      cp "$out/openrgb-list.txt" "$ORGB_LIST.$$.tmp" && mv -f "$ORGB_LIST.$$.tmp" "$ORGB_LIST"
      how=probe
    elif (( rc != 0 )); then
      st=error msg="openrgb --list-devices failed (exit $rc)"
    fi
    src=$out/openrgb-list.txt
  fi
  if [[ -s $src ]]; then detect_openrgb_parse "$src" >"$out/orgb-parsed.json"; else echo '[]' >"$out/orgb-parsed.json"; fi
  # "listing" (cache|probe) is for detect's summary only: a message in the
  # profile would change it after every apply that refreshes the cache.
  jq -n --slurpfile p "$out/orgb-parsed.json" --arg st "$st" --arg msg "$msg" --arg ver "$ver" --arg how "$how" "$nul_jq"'
    def kindof: {DRAM: "ram", GPU: "gpu", Motherboard: "board"}[.type // ""] // "peripheral";
    $p[0] as $l
    | ($l | map(.name) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $cnt
    | [foreach $l[] as $d ({}; .[$d.name] += 1; {d: $d, i: (.[$d.name] - 1)})]
    | map(.d as $d | (if ($d.name | test("^Lian ?Li"; "i")) then "duplicate" else ($d | kindof) end) as $k
        | {key: "openrgb:\($d.name)#\(.i)",
           value: ({backend: "openrgb", present: true, name: $d.name, type: $d.type, kind: $k, leds: $d.leds,
                    zones: (if $k == "board" or $k == "peripheral" or $k == "duplicate" then $d.zones else null end),
                    note: (if $k == "duplicate" then "a Lian Li device seen by OpenRGB: turn its detector off, lian-li-linux drives it" else null end),
                    match: ({name: $d.name, location: (if $cnt[$d.name] > 1 then $d.location else null end)}
                            | with_entries(select(.value != null)))}
                   | with_entries(select(.value != null)))})
    | from_entries as $devs
    | {backend: "openrgb",
       state: (if $st != "ok" then $st elif ($devs | length) == 0 then "no-devices" else "ok" end),
       version: ($ver | n), message: ($msg | n), listing: $how, scanned: ($st == "ok" or ($devs | length) > 0), devices: $devs}
    | with_entries(select(.value != null))' >"$out/openrgb.json"
}

# ---- Lian Li -------------------------------------------------------------------------
# detect_lianli <outdir>: <outdir>/lianli.json = {backend, state, version,
# message, scanned, devices: {key: Device}, config_lcds: [{serial, orientation}]}.
# One ListDevices entry gives a lighting device (fan group, Strimer, ring,
# pump, duplicate) and/or an LCD. Rule 1 of §6 first: a device with a
# wireless_group_mac, or named "TL Flex LCD Controller", is the wired side of
# a wireless group (kind duplicate, bound to "ignore"); the union of both
# tests is today's regex. LCDs group under the fan group whose receiver sits
# on the same USB parent (the device path minus its last ".n").
detect_lianli() {
  local out=$1 info
  detect_usb_tsv | jq -Rn '[inputs | split("\t") | {path: .[0], vid: .[1], pid: .[2], serial: (.[3] // ""), product: (.[5] // "")}]' >"$out/usb.json"
  if ! info=$(daemon_call '{"method":"GetDaemonInfo"}' 2>/dev/null) || ! jq -e '.status == "ok"' <<<"$info" >/dev/null 2>&1; then
    local st=absent msg="lian-li-linux is not installed"
    if systemctl --user is-active -q lianli-daemon 2>/dev/null; then
      st=error msg="lianli-daemon is running but does not answer on $SOCK"
    elif detect_have lianli-daemon || detect_unit_exists lianli-daemon.service; then
      st=down msg="lianli-daemon is not running; devices kept from the last detect"
    fi
    jq -n --arg st "$st" --arg msg "$msg" '{backend: "lianli", state: $st, message: $msg, scanned: ($st == "absent"),
      devices: {}, config_lcds: []}' >"$out/lianli.json"
    return 0
  fi
  local m
  for m in ListDevices GetRgbCapabilities GetConfig; do
    daemon_call "{\"method\":\"$m\"}" >"$out/$m.json" 2>/dev/null || echo '{}' >"$out/$m.json"
    jq -e . "$out/$m.json" >/dev/null 2>&1 || echo '{}' >"$out/$m.json"
  done
  # GetConfig can fail on an older daemon; the live file has the same .lcds.
  if ! jq -e '.data.lcds' "$out/GetConfig.json" >/dev/null 2>&1; then
    jq '{data: {lcds: (.lcds // [])}}' "$CFG_LIVE" >"$out/GetConfig.json" 2>/dev/null || echo '{"data":{"lcds":[]}}' >"$out/GetConfig.json"
  fi
  jq -n --argjson info "$info" --slurpfile list "$out/ListDevices.json" --slurpfile caps "$out/GetRgbCapabilities.json" \
    --slurpfile cfg "$out/GetConfig.json" --slurpfile usb "$out/usb.json" --slurpfile M "$MODELS" '
    def nonempty: if . == null or . == "" then null else . end;
    def clean: with_entries(select(.value != null));
    def usbpath: (.device_id // "") | (capture("^hid:[0-9a-fA-F]{4}:[0-9a-fA-F]{4}:(?<p>.+)$").p // null);
    def vidpid: (.device_id // "") | (capture("^hid:(?<v>[0-9a-fA-F]{4}):(?<p>[0-9a-fA-F]{4}):") | "\(.v):\(.p)") // null;
    def parentpath: sub("\\.[0-9]+$"; "");
    $M[0] as $M
    | ((($list[0].data // $list[0]) | if type == "array" then . else [] end) | map(select(.device_id != null))) as $all
    | ((($caps[0].data // $caps[0]) | if type == "array" then . else [] end) | map({key: .device_id, value: .}) | from_entries) as $cap
    | ($usb[0] | map(select(.serial != "")) | map({key: .serial, value: .}) | from_entries) as $byser
    | ($all | map(select(.wireless_group_mac != null and usbpath != null) | {key: (usbpath | parentpath), value: .wireless_group_mac})
       | from_entries) as $recv
    # Serial-less HID devices are keyed by family, numbered by device_id when
    # a family repeats (the two wired receivers: #1 = the lower USB path).
    | ($all | map(select((.device_id | startswith("wireless:") | not) and (.serial | nonempty) == null)) | group_by(.family)
       | map(sort_by(.device_id) | if length > 1 then to_entries | map({key: .value.device_id, value: "lianli:family:\(.value.family)#\(.key + 1)"})
             else map({key: .device_id, value: "lianli:family:\(.family)"}) end)
       | add // [] | from_entries) as $famkey
    | [$all[] | . as $d | ($M[.family // ""] // {}) as $m | ($cap[.device_id] // {}) as $c
        | (.device_id | startswith("wireless:")) as $wl
        | (if $wl then ((.serial | nonempty) // (.device_id | ltrimstr("wireless:"))) else null end) as $mac
        | (.serial | nonempty) as $ser
        | (if $wl then "lianli:mac:\($mac)" elif $ser != null then "lianli:serial:\($ser)" else $famkey[.device_id] end) as $lkey
        | (.wireless_group_mac != null or ((.name // "") | test("TL Flex LCD Controller"))) as $dup
        | ($c.render_profile.led_count // $c.total_led_count // null) as $leds
        | (if .has_rgb == true or .has_pump == true or .has_lcd != true then
            (if $dup then "duplicate"
             elif $m.kind == "strimer" then "strimer"
             elif .has_fan == true and .has_rgb == true and (($m.kind // "fan_group") == "fan_group") then "fan_group"
             elif .has_rgb == true and ($m.ring != null or $m.kind == "ring") then "ring"
             elif .has_pump == true then "pump"
             else "other" end) as $kind
            | [{key: $lkey, value: ({
                backend: "lianli", present: true, name: .name, family: .family, kind: $kind,
                fans: (if $kind == "fan_group" then .fan_count else null end),
                leds: (if $kind == "duplicate" or $kind == "pump" then null else $leds end),
                regions: (if $kind == "fan_group" then
                            (if (($c.effect_regions // []) | index("Top")) != null then ["inner", "outer"] else ["outer"] end)
                          else null end),
                has_pump: (if .has_pump == true then true else null end),
                duplicate_of: (if $dup and .wireless_group_mac != null then "lianli:mac:\(.wireless_group_mac)" else null end),
                seen_id: (if $wl then null else .device_id end),
                match: ({mac: $mac, serial: (if $wl then null else $ser end), family: (if $wl then null else .family end),
                         device_id: (if $wl or ($lkey | test("#")) then .device_id else null end)} | clean)} | clean)}]
           else [] end)
          + (if .has_lcd == true then
              (($ser // .device_id)) as $ls
              | ($byser[$ls] // null) as $u
              | (usbpath) as $p
              | [{key: "lianli:lcd:\($ls)", value: ({
                  backend: "lianli", present: true, name: .name, family: .family, kind: "lcd",
                  panel: (if .screen_width != null then [.screen_width, .screen_height] else null end),
                  usb: (if $u != null then "\($u.vid):\($u.pid)" else vidpid end),
                  lcd_group: (if $wl then $lkey
                              elif $p != null and $recv[$p | parentpath] != null then "lianli:mac:\($recv[$p | parentpath])"
                              else null end),
                  seen_id: (if $wl then null else .device_id end),
                  match: (if $u != null then {usb_serial: $ls} else {serial: $ls} end)} | clean)}]
             else [] end)
        | .[]] as $devs
    | {backend: "lianli", state: (if ($devs | length) == 0 then "no-devices" else "ok" end),
       version: ($info.data.version // null), scanned: true, devices: ($devs | from_entries),
       config_lcds: [(($cfg[0].data.lcds // []) | .[] | {serial: (.serial // null), orientation: (.orientation // 0)})]}
    | with_entries(select(.value != null))' >"$out/lianli.json"
}

# ---- sensors ---------------------------------------------------------------------------
# detect_sensors_json [devices.json]: the profile.sensors object, from hwmon,
# the NVIDIA driver and (with a devices file) the Lian Li pump. Read-only and
# fast. The engine's only sensor heuristics: sensors_detect and sensors --json
# (sensors.sh, with no profile) call it too.
#   cpu:  zenpower (Tdie) > k10temp (Tctl) > coretemp ("Package id 0") > the
#         x86_pkg_temp thermal zone
#   gpu:  NVIDIA (driver info + nvidia-smi) > amdgpu with boot_vga=1 or >= 4 GiB
#         VRAM > xe/i915 > the integrated amdgpu; that one is also gpu_integrated
#   coolant/pump: the Lian Li device with has_pump; ram: spd5118 or jc42
# hwmon indices move between boots, so a source names its driver (and, for a
# GPU, its PCI address in "pci"); sensors --json resolves the path at call time.
detect_sensors_json() {
  local devs=${1:-} tmp smi=false
  tmp=$(mktemp -d "$TMP/sensors.XXXXXX")
  detect_hwmon_tsv >"$tmp/hwmon.tsv"
  detect_nvidia_info >"$tmp/nvidia.txt"
  if detect_have nvidia-smi; then smi=true; fi
  if [[ -z $devs || ! -f $devs ]]; then echo '{}' >"$tmp/devs.json"; devs=$tmp/devs.json; fi
  jq -Rn --slurpfile dv "$devs" --argjson smi "$smi" --rawfile nv "$tmp/nvidia.txt" '
    def clean: with_entries(select(.value != null));
    [inputs | select(length > 0) | split("\t") | {h: .[0], k: .[1], v: (.[2:] | join("\t"))}]
    | group_by(.h)
    | map((map({key: .k, value: .v}) | from_entries) as $a
        | {hwmon: .[0].h, name: $a.name, dev: (($a.device // "") | split("/") | last),
           labels: ($a | to_entries | map(select(.key | test("^temp[0-9]+_label$")) | {key: (.key | rtrimstr("_label")), value})
                    | from_entries),
           inputs: ($a | keys | map(select(test("^temp[0-9]+_input$")))),
           boot_vga: $a["device/boot_vga"], vram: $a["device/mem_info_vram_total"], type: $a.type})
    | sort_by(.hwmon | ltrimstr("hwmon") | tonumber? // 0) as $hw
    # the temp input whose label matches $re, else the lowest-numbered input
    | def pick($h; $re):
        ([$h.labels | to_entries[] | select(.value | test($re))] | first) as $l
        | if $l != null then {input: "\($l.key)_input", label: $l.value}
          else {input: ($h.inputs | sort_by(ltrimstr("temp") | rtrimstr("_input") | tonumber) | first), label: null} end;
      def src($h; $re): pick($h; $re) as $p
        | {kind: "hwmon", driver: $h.name, input: $p.input, label: $p.label, scale: 0.001} | clean;
      def pci($h): if ($h.dev | test("^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-9]$")) then $h.dev else null end;
      ([$hw[] | select(.name == "zenpower")] | first) as $zp
    | ([$hw[] | select(.name == "k10temp")] | first) as $k10
    | ([$hw[] | select(.name == "coretemp")] | first) as $core
    | ([$hw[] | select(.type == "x86_pkg_temp")] | first) as $tz
    | (if $zp then src($zp; "^Tdie$|^Tctl$") elif $k10 then src($k10; "^Tctl$")
       elif $core then src($core; "^Package id 0$")
       elif $tz then {kind: "thermal_zone", type: "x86_pkg_temp", scale: 0.001} else null end) as $cpu
    # NVIDIA: one Model line per information file; nvidia-smi numbers GPUs by PCI bus.
    | ([$nv | split("\n")[] | select(test("^Model:")) | sub("^Model:\\s*"; "")] ) as $nvm
    | ([$nv | split("\n")[] | select(test("^Bus Location:")) | sub("^Bus Location:\\s*"; "")]) as $nvb
    | ([range(0; $nvm | length) | {model: $nvm[.], bus: ($nvb[.] // "")}] | sort_by(.bus)) as $nvs
    | (if ($nvs | length) > 0 and $smi then {kind: "nvidia-smi", index: 0, name: $nvs[0].model} else null end) as $nvidia
    | ([$hw[] | select(.name == "amdgpu")
        | . + {dgpu: (.boot_vga == "1" or ((.vram // "0") | tonumber? // 0) >= 4294967296)}]) as $amd
    | ([$amd[] | select(.dgpu)] | first) as $amdd
    | ([$amd[] | select(.dgpu | not)] | first) as $amdi
    | ([$hw[] | select(.name == "xe" or .name == "i915") | select((.inputs | length) > 0)] | first) as $intel
    | (if $amdd then src($amdd; "^edge$") + {pci: pci($amdd), integrated: false} | clean else null end) as $amdsrc
    | (if $intel then src($intel; "^pkg$") + {pci: pci($intel), integrated: false} | clean else null end) as $intelsrc
    | (if $amdi then src($amdi; "^edge$") + {integrated: true, pci: pci($amdi)} | clean else null end) as $igpu
    | ([$hw[] | select(.name == "spd5118")]) as $spd
    | ([$hw[] | select(.name == "jc42")]) as $jc
    | (if ($spd | length) > 0 then $spd elif ($jc | length) > 0 then $jc else [] end) as $ram
    | ($dv[0] | to_entries | map(select(.value.backend == "lianli" and .value.has_pump == true))
       | (map(select(.value.present != false)) + map(select(.value.present == false))) | first | .key // null) as $pump
    | {cpu: $cpu,
       gpu: ($nvidia // $amdsrc // $intelsrc // $igpu),
       gpu_integrated: $igpu,
       coolant: (if $pump then {kind: "lianli", device: $pump, field: "coolant_temps"} else null end),
       pump: (if $pump then {kind: "lianli", device: $pump, field: "fan_rpms"} else null end),
       ram: (if ($ram | length) > 0 then {kind: "hwmon", driver: $ram[0].name, input: "temp1_input", scale: 0.001, count: ($ram | length)}
             else null end)}
    | clean' <"$tmp/hwmon.tsv"
  rm -rf "$tmp"
}

# ---- workarounds -------------------------------------------------------------------------
# detect_workarounds <outdir> <devices.json>: <outdir>/workarounds.json, facts
# only: is each known workaround installed, and does this machine need it.
# Nothing here installs or removes one.
detect_workarounds() {
  local out=$1 devs=$2 f
  {
    for f in "$LIANLI_DROPINS"/*.conf; do
      [[ -f $f ]] || continue
      jq -Rn --arg file "${f##*/}" '[inputs | select(test("^ExecStart=")) | sub("^ExecStart="; "")] as $e
        | {file: $file, exec: ([$e[] | select(length > 0)] | last)}' <"$f"
    done
  } | jq -s . >"$out/dropins.json"
  detect_cmdline >"$out/cmdline.txt"
  if [[ -f $ORGB_JSON ]] && jq -e . "$ORGB_JSON" >/dev/null 2>&1; then cp "$ORGB_JSON" "$out/orgbcfg.json"; else echo null >"$out/orgbcfg.json"; fi
  jq -n --slurpfile drop "$out/dropins.json" --rawfile cmdline "$out/cmdline.txt" --slurpfile oc "$out/orgbcfg.json" \
    --slurpfile dv "$devs" --slurpfile ll "$out/lianli.json" --slurpfile og "$out/openrgb.json" --slurpfile sn "$out/sensors.json" \
    --arg llpkg "$(detect_pkg_version lianli-linux-git)" '
    def clean: with_entries(select(.value != null));
    $dv[0] as $dv | $ll[0] as $ll | $og[0] as $og
    | ([$drop[0][] | select(.exec != null)] | last) as $fixed
    | ([$drop[0][] | select(.file == "wake-fan-lcds.conf")] | length > 0) as $wake
    | ([($oc[0].Detectors.detectors // {}) | to_entries[] | select(.key | test("^Lian Li"))]) as $lld
    | ($ll.version // null) as $dver
    | ($llpkg | sub("\\.r[0-9]+.*$"; "") | sub("-[0-9]+$"; "")) as $pbase
    | ([$dv[] | select(.backend == "openrgb" and .kind == "ram")]) as $ram
    | (($sn[0].cpu.driver // "") | test("^(k10temp|zenpower)$")) as $amdcpu
    | ([$dv[] | select(.family == "TlFlexLcd")] | length > 0) as $tlflex
    | {}
    | if $ll.state != "absent" then
        .["lianli.fixed_binary"] = ({present: ($fixed != null), needed: null, exec: $fixed.exec, dropin: $fixed.file,
            daemon_version: $dver, package_version: ($llpkg | if . == "" then null else . end),
            note: (if $fixed == null then null
                   elif $dver != null and $pbase != "" and $pbase != $dver then "version mismatch: package \($pbase), daemon \($dver)"
                   else "remove when lianli-linux-git is upgraded (guard version mismatch)" end)} | clean
            | {present, needed: null} + .)
        | .["lianli.wake_fan_lcds"] = ({present: $wake, needed: $tlflex, dropin: (if $wake then "wake-fan-lcds.conf" else null end),
            note: (if $tlflex then "TlFlexLcd present: receivers keep the LCDs off USB after shutdown" else null end)} | clean)
      else . end
    | if $og.state != "absent" then
        .["openrgb.lianli_detectors_off"] = {present: (($lld | length) > 0 and all($lld[]; .value == false)),
                                              needed: ($ll.state != "absent")}
        | .["openrgb.smbus_lax"] = ({present: ($cmdline | test("(^|\\s)acpi_enforce_resources=lax(\\s|$)")),
            needed: (($ram | length) > 0 and $amdcpu),
            note: (if ($ram | length) > 0 and $amdcpu then "\($ram[0].name) on AMD needs acpi_enforce_resources=lax" else null end)} | clean)
      else . end' >"$out/workarounds.json"
}

# ---- building the detected profile ----------------------------------------------------------
# detect_devices <outdir> <old profile>: <outdir>/devices.json, the new
# devices merged with the old ones. A device a scanned backend no longer
# reports stays with present:false (its roles survive, e.g. fan LCDs off USB);
# the devices of a backend that wasn't scanned (--no-openrgb, daemon down)
# are kept as they were.
detect_devices() {
  local out=$1 old=$2
  jq -n --slurpfile ll "$out/lianli.json" --slurpfile og "$out/openrgb.json" --slurpfile old "$old" '
    ($old[0].devices // {}) as $od
    | [$ll[0], $og[0]] as $bes
    | reduce $bes[] as $b ({};
        . + $b.devices
        + ($od | with_entries(select(.value.backend == $b.backend and ($b.devices[.key] == null))
                              | if $b.scanned then .value.present = false else . end)))
    # other backends a later version may add: keep their devices as they are
    + ($od | with_entries(select(.value.backend as $x | ["lianli", "openrgb"] | index($x) | not)))' >"$out/devices.json"
}

# detect_roles <outdir> <old profile>: <outdir>/roles.json, the role guesses
# of §6 over every known device (present or not, so a missing device keeps
# its role and the screen numbering holds while fan LCDs are off USB).
#   fans:     groups by fans desc, then MAC; the first with LCDs -> fans.side,
#             the first without -> fans.bottom, the next with LCDs -> fans.top,
#             the rest fans.1..n (all guesses)
#   strimers: >= 160 LEDs -> strimer.atx24, 100-159 -> strimer.gpu, else strimer.<n>
#   rings:    pump rings -> pump.ring, the 8.8" ring -> screen.main.ring
#   screens:  fan LCDs -> screen.fan<n> in group order, then port; pump LCDs ->
#             screen.pump; the largest main screen -> screen.main; the rest
#             screen.aux<n>. mount = the rotation the daemon config shows now
#             minus the model's default (so compile reproduces today's
#             orientations), kept from the old profile once a role has one.
#   openrgb:  board (+ board.argb for addressable headers, with the size
#             OpenRGB saved in sizes.ors: source "openrgb", sure; without
#             one, size null: never resized unless the user sets one), gpu, ram, peripherals
#             (managed:false), Lian Li devices -> ignore.
detect_roles() {
  local out=$1 old=$2
  [[ -f $out/orgb-sizes.json ]] || echo '[]' >"$out/orgb-sizes.json"
  jq -n --slurpfile dv "$out/devices.json" --slurpfile ll "$out/lianli.json" --slurpfile old "$old" --slurpfile M "$MODELS" \
    --slurpfile sz "$out/orgb-sizes.json" '
    def clean: with_entries(select(.value != null));
    def lastport: (capture("\\.(?<n>[0-9]+)$").n | tonumber) // 0;
    def mod360: ((. % 360) + 360) % 360;
    $M[0] as $M | $dv[0] as $dv | ($old[0].roles // {}) as $or | ($ll[0].config_lcds // []) as $cfg
    | ($dv | to_entries) as $E
    | def fam($f): $M[$f // ""] // {};
      def orient($d): [$cfg[] | select(.serial != null and (.serial == $d.match.usb_serial or .serial == $d.match.serial
                                   or .serial == $d.seen_id or .serial == ("serial:" + ($d.match.usb_serial // "")))) | .orientation]
                      | first;
      def mount($role; $key; $d):
        if ($or[$role].device // null) == $key and ($or[$role].mount != null) then $or[$role].mount
        else orient($d) as $o | if $o == null then 0 else (($o | floor) - (fam($d.family).orientation // 0)) | mod360 end end;
      def r($role; $v): {key: $role, value: ($v | clean)};
    # ---- fan groups
      ([$E[] | select(.value.kind == "fan_group") | . + {f: (.value.fans // 0), mac: (.value.match.mac // .key)}]
       | sort_by(-.f, .mac)) as $groups
    | ([$E[] | select(.value.kind == "lcd") | .value.lcd_group | select(. != null)]) as $lg
    | ($groups | map(select(.key as $k | $lg | index($k)))) as $withlcd
    | ($groups | map(select(.key as $k | $lg | index($k) | not))) as $nolcd
    | ([($withlcd[0] // empty | {key, role: "fans.side"}), ($nolcd[0] // empty | {key, role: "fans.bottom"}),
        ($withlcd[1] // empty | {key, role: "fans.top"})]) as $named
    | ($groups | map(select(.key as $k | $named | map(.key) | index($k) | not))) as $rest
    | ($named + ($rest | to_entries | map({key: .value.key, role: "fans.\(.key + 1)"}))) as $fr
    | ($fr | map({key: .key, value: .role}) | from_entries) as $roleof
    | ($groups | map({key: .key, value: "\(.f)-fan \(if .key as $k | $lg | index($k) then "LCD " else "" end)group"}) | from_entries) as $glabel
    | [$fr[] | r(.role; {device: .key, label: $glabel[.key], source: "detect", confidence: "guess"})] as $fanroles
    # ---- strimers
    | ([$E[] | select(.value.kind == "strimer")] | sort_by(-(.value.leds // 0), .key)
       | reduce .[] as $s ({out: [], atx: false, gpu: false, n: 0};
           ($s.value.leds // 0) as $l
           | if $l >= 160 and (.atx | not) then .atx = true | .out += [r("strimer.atx24"; {device: $s.key, label: "24-pin Strimer", source: "detect", confidence: "guess"})]
             elif $l >= 100 and $l < 160 and (.gpu | not) then .gpu = true | .out += [r("strimer.gpu"; {device: $s.key, label: "GPU Strimer", source: "detect", confidence: "guess"})]
             else .n += 1 | .out += [r("strimer.\(.n)"; {device: $s.key, label: "Strimer \(.n)", source: "detect", confidence: "guess"})] end)
       | .out) as $strroles
    # ---- rings
    | ([$E[] | select(.value.kind == "ring" and fam(.value.family).ring == "pump")] | sort_by(.key) | first) as $pring
    | ([$E[] | select(.value.kind == "ring" and fam(.value.family).ring == "main")] | sort_by(.key) | first) as $mring
    | ([if $pring then r("pump.ring"; {device: $pring.key, label: (fam($pring.value.family) | .ring_label // .label // "\($pring.value.name) ring"), source: "detect", confidence: "sure"}) else empty end,
        if $mring then r("screen.main.ring"; {device: $mring.key, label: (fam($mring.value.family).label // "\($mring.value.name)"), source: "detect", confidence: "sure"}) else empty end]) as $ringroles
    # ---- screens
    | ($groups | map(.key)) as $gorder
    | ([$E[] | select(.value.kind == "lcd" and fam(.value.family).screen == "fan")
        | . + {g: (.value.lcd_group as $g | ($gorder | index($g)) // 999), p: ((.value.seen_id // "") | lastport)}]
       | sort_by(.g, .p, .key)) as $fl
    | ([$fl | to_entries[] | .key as $i | .value as $s
        | ([$fl[0:$i][] | select(.g == $s.g)] | length + 1) as $k
        | r("screen.fan\($i + 1)"; {device: $s.key, group: $roleof[$s.value.lcd_group // ""],
            mount: mount("screen.fan\($i + 1)"; $s.key; $s.value),
            label: (if $s.value.lcd_group != null and $glabel[$s.value.lcd_group] != null then "\($glabel[$s.value.lcd_group]), screen \($k)"
                    else "\($s.value.name) \($i + 1)" end),
            source: "detect", confidence: "guess"})]) as $fanscreens
    | ([$E[] | select(.value.kind == "lcd" and fam(.value.family).screen == "pump")] | sort_by(.key)) as $pumps
    | ([$E[] | select(.value.kind == "lcd" and fam(.value.family).screen == "main")]
       | sort_by(-((.value.panel // [0, 0]) | .[0] * .[1]), .key)) as $mains
    | ([$E[] | select(.value.kind == "lcd" and ((fam(.value.family).screen // "aux") | IN("fan", "pump", "main") | not))] | sort_by(.key)) as $aux
    | def scr($role; $s): r($role; {device: $s.key, mount: mount($role; $s.key; $s.value),
                                    label: (fam($s.value.family).label // $s.value.name), source: "detect", confidence: "sure"});
      ([if ($pumps | length) > 0 then scr("screen.pump"; $pumps[0]) else empty end,
        if ($mains | length) > 0 then scr("screen.main"; $mains[0]) else empty end]
       + ([$pumps[1:][], $mains[1:][], $aux[]] | to_entries | map(scr("screen.aux\(.key + 1)"; .value)))) as $otherscreens
    # ---- openrgb
    | ([$E[] | select(.value.backend == "openrgb")]) as $O
    | ([$O[] | select(.value.kind == "board")] | first) as $board
    | ([$O[] | select(.value.kind == "gpu")]) as $gpus
    | ([$O[] | select(.value.kind == "ram")]) as $rams
    | (if $board then [$board.value.zones // [] | to_entries[] | select(.value | test("ARGB|D_LED|ADD|JRAINBOW|Addressable"; "i")) | .key]
       else [] end) as $argb
    # The header size, when OpenRGB saved one (sizes.ors): the same count
    # on every addressable zone, each resizable (min != max) and non-zero.
    | def normloc: gsub("\\s+"; " ");
      (if $board then
         ([$sz[0][] | select(.name == $board.value.name)]
          | if $board.value.match.location != null then map(select((.location | normloc) == ($board.value.match.location | normloc))) else . end
          | first) as $sd
         | if $sd == null then null
           else [$argb[] as $i | ($board.value.zones[$i]) as $zn
                 | (([$sd.zones[] | select(.name == $zn)] | first) // $sd.zones[$i])
                 | select(. != null and .min != .max and .count > 0) | .count]
                | if length == ($argb | length) and length > 0 and (unique | length) == 1 then .[0] else null end
           end
       else null end) as $argbsize
    | ([if $board then r("board"; {device: $board.key, source: "detect", confidence: "sure"}) else empty end,
        if $board and ($argb | length) > 0 then
          r("board.argb"; {device: $board.key, argb: {zones: $argb, size: $argbsize},
                           source: (if $argbsize != null then "openrgb" else "detect" end),
                           confidence: (if $argbsize != null then "sure" else "guess" end)})
        else empty end]) as $boardroles
    | ([if ($gpus | length) > 0 then
          r("gpu"; {device: $gpus[0].key, leds: $gpus[0].value.leds,
                    layout: (if ($gpus[0].value.name | test("ASUS"; "i")) and $gpus[0].value.leds == 30 then "aura" else "linear" end),
                    source: "detect", confidence: "sure"})
        else empty end]) as $gpuroles
    | ([if ($rams | length) > 0 then
          r("ram"; {devices: [$rams[].key], match_name: $rams[0].value.name,
                    leds_per_device: (([$rams[].value.leds // 0] | add) / ($rams | length) | floor),
                    source: "detect", confidence: "sure"})
        else empty end]) as $ramroles
    | ([$O[] | select(.value.kind == "peripheral")]
       | reduce .[] as $p ({out: [], used: {}, strip: 0, other: 0};
           ({Keyboard: "keyboard", Mouse: "mouse", Mousemat: "mousepad", Headset: "headset"}[$p.value.type // ""]) as $base
           | if $base != null and (.used[$base] | not) then .used[$base] = true | .out += [{key: $base, dev: $p.key}]
             elif (($p.value.type // "") | test("^LED ?Strip$")) then .strip += 1 | .out += [{key: "ledstrip.\(.strip)", dev: $p.key}]
             else .other += 1 | .out += [{key: "other.\(.other)", dev: $p.key}] end)
       | .out | sort_by(.key as $k | ["keyboard", "mouse", "mousepad", "headset"] | index($k) // 9)
       | map(r(.key; {device: .dev, managed: false, source: "detect", confidence: "sure"}))) as $periph
    # ---- ignore: wired duplicates, and Lian Li devices OpenRGB sees
    | ([$E[] | select(.value.kind == "duplicate") | .key] | sort) as $ign
    | ([if ($ign | length) > 0 then r("ignore"; {devices: $ign, source: "detect", confidence: "sure"}) else empty end]) as $ignroles
    | ($fanroles + $strroles + $ringroles + $fanscreens + $otherscreens + $gpuroles + $boardroles + $ramroles + $periph + $ignroles)
    | from_entries' >"$out/roles.json"
}

# detect_assemble <outdir> <old profile>: <outdir>/detected.json, the pure
# detection (plan §6) in profile shape, without calibration. Devices are
# ordered for reading: Lian Li by kind in role order, then OpenRGB in
# listing order.
detect_assemble() {
  local out=$1 old=$2
  jq -n --slurpfile dv "$out/devices.json" --slurpfile roles "$out/roles.json" --slurpfile ll "$out/lianli.json" \
    --slurpfile og "$out/openrgb.json" --slurpfile sn "$out/sensors.json" --slurpfile wk "$out/workarounds.json" \
    --slurpfile old "$old" --arg host "$(detect_hostname)" --arg now "$(detect_now)" --argjson dver "$DETECT_VERSION" '
    def clean: with_entries(select(.value != null));
    $roles[0] as $R | $old[0] as $old
    | ([$R | to_entries[] | .value | (.device // empty), (.devices // [])[]]) as $rorder
    | ({fan_group: 0, strimer: 1, ring: 2, pump: 3, other: 4, duplicate: 5, lcd: 6}) as $krank
    | ($dv[0] | to_entries) as $E
    | ([$E[] | select(.value.backend == "lianli")]
       | sort_by($krank[.value.kind] // 9, (.key as $k | $rorder | index($k)) // 999, .key)) as $lld
    | ([$E[] | select(.value.backend != "lianli")]) as $rest
    # backend state: a backend not scanned keeps what the last detect said
    | def be($b; $n): if $b.state == "unknown" or $b.state == "down" or $b.state == "error" then
          (($old.backends[$b.backend] // {}) | del(.enabled)) + {state: $b.state, message: $b.message}
        else {state: $b.state, version: $b.version, message: $b.message} end
        | {enabled: true} + . | clean;
      ([$R | to_entries[] | select(.key | test("^screen\\.(fan[0-9]+|pump|main|aux[0-9]+)$"))] | length) as $nscreens
    | {v: 1,
       machine: {name: $host, hostname: $host, detected_at: $now, detect_version: $dver},
       backends: {lianli: be($ll[0]; "lianli"), openrgb: be($og[0]; "openrgb")},
       devices: (($lld + $rest) | from_entries),
       roles: $R,
       screens: {expected: ([$nscreens, ($ll[0].config_lcds // [] | length)] | max)},
       sensors: $sn[0],
       workarounds: $wk[0]}' >"$out/detected.json"
}

# ---- pc-lights detect [--probe|--no-openrgb] [--dry-run] [--json] ---------------------------
detect_cmd() {
  local a mode=cache dry='' json='' d old cur
  for a in "$@"; do
    case $a in
      --probe) mode=probe ;;
      --no-openrgb) mode=skip ;;
      --dry-run) dry=1 ;;
      --json) json=1 ;;
      *) die "usage: pc-lights detect [--probe|--no-openrgb] [--dry-run] [--json]" ;;
    esac
  done
  [[ -f $MODELS ]] || die "missing $MODELS"
  mkdir -p "${PROFILE%/*}"
  take_lock
  claim_run detect
  d=$TMP/detect; mkdir -p "$d"
  old=$d/old.json
  if [[ -f $PROFILE ]] && jq -e '.v == 1' "$PROFILE" >/dev/null 2>&1; then cp "$PROFILE" "$old"; else echo null >"$old"; fi
  progress "lian li"
  detect_lianli "$d"
  progress openrgb
  detect_openrgb "$d" "$mode"
  progress profile
  detect_devices "$d" "$old"
  # a file read, not a probe: done with --no-openrgb too, so the role holds
  detect_openrgb_sizes "$ORGB_SIZES" >"$d/orgb-sizes.json"
  detect_roles "$d" "$old"
  detect_sensors_json "$d/devices.json" >"$d/sensors.json"
  detect_workarounds "$d" "$d/devices.json"
  detect_assemble "$d" "$old"
  profile_merge "$old" "$(profile_detected_path)" "$d/detected.json" >"$d/merged.json"
  jq '.profile' "$d/merged.json" >"$d/new.json"
  cur=$d/cur.json
  if [[ -f $PROFILE ]]; then cp "$PROFILE" "$cur"; else : >"$cur"; fi
  local changed=true written=false
  if [[ -s $cur ]] && jq -e --slurpfile n "$d/new.json" '. == $n[0]' "$cur" >/dev/null 2>&1; then changed=false; fi
  if [[ -z $dry ]]; then
    if [[ $changed == true ]]; then profile_write "$d/new.json"; written=true; fi
    # The pure detection, the "last detection" the next merge compares to.
    jq . "$d/detected.json" >"$(profile_detected_path).$$.tmp" && mv -f "$(profile_detected_path).$$.tmp" "$(profile_detected_path)"
  fi
  if [[ -n $json ]]; then
    jq --slurpfile og "$d/openrgb.json" --argjson changed "$changed" --argjson written "$written" --arg path "$PROFILE" --argjson dry "$([[ -n $dry ]] && echo true || echo false)" '
      .profile as $p
      | {v: 1, path: $path, dry_run: $dry, changed: $changed, written: $written, openrgb_listing: ($og[0].listing // null),
         backends: ($p.backends | map_values({state, version, message} | with_entries(select(.value != null)))),
         devices: ($p.devices | length), missing_devices: [$p.devices | to_entries[] | select(.value.present == false) | .key],
         roles: ($p.roles | keys_unsorted), screens: $p.screens.expected,
         sensors: ($p.sensors | map_values(.driver // .kind)), conflicts: .conflicts, warnings: .warnings, profile: $p}' "$d/merged.json"
  else
    jq -r --slurpfile og "$d/openrgb.json" '.profile as $p
      | "detect: " + ([$p.backends | to_entries[] | "\(.key) \(.value.state)\(if .value.version then " \(.value.version)" else "" end)"
                        + " (\(.key as $b | [$p.devices[] | select(.backend == $b and .present != false)] | length) devices)"
                        + (if .value.message then ", \(.value.message)" else "" end)] | join("; ")),
        (if $og[0].listing then "openrgb listing: \(if $og[0].listing == "probe" then "probed now" else "cached by the last apply" end)" else empty end),
        "roles: \($p.roles | length) (\($p.roles | keys_unsorted | join(" ")))",
        "screens expected: \($p.screens.expected)",
        "sensors: " + ([$p.sensors | to_entries[] | "\(.key) \(.value.driver // .value.kind)"] | join(", ") | if . == "" then "none" else . end),
        (if ([$p.devices | to_entries[] | select(.value.present == false)] | length) > 0 then
           "missing (kept with present:false): " + ([$p.devices | to_entries[] | select(.value.present == false) | .key] | join(", "))
         else empty end),
        (.conflicts[] | "kept your \(.unit) (detect now suggests \(.detected | tojson))"),
        (.warnings[] | "warning: \(.)")' "$d/merged.json"
    if [[ -n $dry ]]; then
      if [[ $changed == true ]]; then
        diff -u --label "$PROFILE" --label "$PROFILE (detected)" <(if [[ -s $cur ]]; then jq . "$cur"; fi) <(jq . "$d/new.json") || true
      else
        echo "dry run: no change"
      fi
    elif [[ $written == true ]]; then
      echo "wrote $PROFILE"
    else
      echo "profile unchanged"
    fi
  fi
}
