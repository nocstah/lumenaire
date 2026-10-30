# lib/pc-lights/sensors.sh — the sensors contract (pc-lights sensors --json, plan §9)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP6 (JSON v1.1, sensors, previews)
# Public: sensors_json sensors_detect sensors_inventory; globals SENSORS_SYS SENSORS_PROC
# (sensors_detect is detect_sensors_json on the SENSORS_SYS/SENSORS_PROC trees)
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# Where sysfs and procfs are; a test points these at a fixture tree (read at
# call time, like every override point).
SENSORS_SYS=/sys
SENSORS_PROC=/proc

# ---- inventory ------------------------------------------------------------------
# sensors_inventory: one TSV line per temperature source this machine has,
# read with builtins only (no forks; the plugin runs "sensors --json" on
# start and on every profile change):
#   h  <hwmon dir> <driver> <abs input> <input file> <label> <integrated 0|1|"">
#   tz <zone dir>  <type>   <abs input> temp         ""      ""
#   nv <proc dir>  <model>  ""          ""           ""      "" <index>
# Only the drivers the heuristics look at are listed. A GPU hwmon counts as
# discrete when its PCI device is the boot VGA or has 4 GiB of VRAM or more
# (the Ryzen iGPU here is amdgpu with 2 GiB and boot_vga 0).
sensors_inventory() {
  local h name f in lab dev bv vram integ z typ i=0 line model
  for h in "$SENSORS_SYS"/class/hwmon/hwmon*; do
    [[ -r $h/name ]] || continue
    read -r name <"$h/name" || continue
    case $name in zenpower | k10temp | coretemp | amdgpu | xe | i915 | nouveau | spd5118 | jc42) ;; *) continue ;; esac
    integ=
    if [[ $name =~ ^(amdgpu|xe|i915|nouveau)$ ]]; then
      dev=$h/device bv='' vram=''
      [[ -r $dev/boot_vga ]] && read -r bv <"$dev/boot_vga"
      [[ -r $dev/mem_info_vram_total ]] && read -r vram <"$dev/mem_info_vram_total"
      if [[ $bv == 1 ]] || { [[ $vram =~ ^[0-9]+$ ]] && (( vram >= 4294967296 )); }; then integ=0; else integ=1; fi
    fi
    for in in "$h"/temp*_input; do
      [[ -e $in ]] || continue
      f=${in##*/} lab=
      [[ -r ${in%_input}_label ]] && read -r lab <"${in%_input}_label"
      printf 'h\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$name" "$in" "$f" "$lab" "$integ"
    done
  done
  for z in "$SENSORS_SYS"/class/thermal/thermal_zone*; do
    [[ -r $z/type ]] || continue
    read -r typ <"$z/type" || continue
    [[ $typ == x86_pkg_temp ]] && printf 'tz\t%s\t%s\t%s\ttemp\t\t\n' "$z" "$typ" "$z/temp"
  done
  # NVIDIA: the driver's per-GPU information files, in PCI bus order, which
  # is nvidia-smi's index order.
  for f in "$SENSORS_PROC"/driver/nvidia/gpus/*/information; do
    [[ -r $f ]] || continue
    model=
    while IFS= read -r line; do
      if [[ $line =~ ^Model:[[:space:]]*(.*[^[:space:]]) ]]; then model=${BASH_REMATCH[1]}; break; fi
    done <"$f"
    printf 'nv\t%s\t%s\t\t\t\t\t%s\n' "${f%/information}" "$model" "$i"
    i=$((i + 1))
  done
}

# The shared jq: inventory rows and the resolution of a profile SensorSource
# to a file. The detection heuristics (plan §6) live in one place only,
# detect_sensors_json (detect.sh).
# shellcheck disable=SC2016
SENSORS_JQ='
  def rows: split("\n") | map(select(length > 0) | split("\t")
    | {k: .[0], dir: .[1], name: .[2], input: .[3], file: .[4], label: .[5],
       integrated: (if .[6] == "1" then true elif .[6] == "0" then false else null end),
       index: ((.[7] // "") | if . == "" then null else tonumber end)});
  def first_of(f): [f] | .[0];
  def src: if .k == "h" then {kind: "hwmon", driver: .name, input: .file}
             + (if .label != "" then {label: .label} else {} end) + {scale: 0.001}
             + (if .integrated != null then {integrated: .integrated} else {} end)
           elif .k == "tz" then {kind: "thermal_zone", type: .name, scale: 0.001}
           else {kind: "nvidia-smi", index: .index, name: .name} end;
  def gpu_hw: .[] | select(.k == "h" and (.name | IN("amdgpu", "xe", "i915", "nouveau")))
    | select(.label == "" or .label == "edge" or .file == "temp1_input");
  # resolve: a profile SensorSource -> the rows it names on this boot.
  def matches($s): .[] | select(
      ($s.kind == "hwmon" and .k == "h" and .name == $s.driver
        and (if $s.label then .label == $s.label else .file == ($s.input // "temp1_input") end)
        and ($s.integrated == null or .integrated == null or .integrated == $s.integrated))
      or ($s.kind == "thermal_zone" and .k == "tz" and .name == ($s.type // "x86_pkg_temp"))
      or ($s.kind == "nvidia-smi" and .k == "nv" and .index == ($s.index // 0)));
  def file_out($s): {kind: $s.kind} + ($s | with_entries(select(.key | IN("driver", "label", "type", "integrated"))))
    + {input: .input, scale: ($s.scale // 0.001)}
    + (if .label != "" and $s.label == null then {label: .label} else {} end);
  def resolve($s; $r; $nvsmi):
    if $s == null then null
    elif $s.kind == "nvidia-smi" then
      first_of($r | matches($s)) as $m
      | {kind: "nvidia-smi", index: ($s.index // 0), name: ($m.name // $s.name // null),
         available: ($m != null and $nvsmi),
         cmd: ["nvidia-smi", "-i", "\($s.index // 0)", "--query-gpu=temperature.gpu,utilization.gpu,power.draw",
               "--format=csv,noheader,nounits", "-lms", "2000"]}
    else first_of($r | matches($s)) as $m
      | if $m then ($m | file_out($s)) + {available: true}
        else {kind: $s.kind} + ($s | with_entries(select(.key | IN("driver", "label", "type", "integrated"))))
             + {input: null, scale: ($s.scale // 0.001), available: false} end
    end;
'

# sensors_detect: the live detection result in the profile form (no
# coolant/pump: detect adds those from the Lian Li devices), from the one set
# of heuristics (detect_sensors_json in detect.sh), reading the same
# sysfs/procfs trees as sensors_inventory.
sensors_detect() {
  PCL_SYSFS=$SENSORS_SYS PCL_PROCFS=$SENSORS_PROC detect_sensors_json
}

# pc-lights sensors --json: no lock, no socket, target under 30 ms. The
# sources come from profile.sensors (or live detection without a usable
# profile) and hwmon paths are resolved now, because hwmon indices move
# between boots. Shape (contract v1, additive; see the WP6 report):
#   {v, source: "profile"|"detected", cpu, gpu, gpus[], coolant, pump, ram[]}
# cpu/gpu/coolant/pump are null when missing; a file source has an absolute
# "input" and a "scale" (value = file * scale, in degrees C), nvidia-smi a
# ready "cmd". coolant/pump name the daemon device_id whose GetTelemetry
# entry to read (null device_id: the first has_pump device, the old rule).
sensors_json() {
  local nvsmi=false pf=${PROFILE:-$STATE_DIR/profile.json} lianli=false det=null
  if command -v nvidia-smi >/dev/null 2>&1; then nvsmi=true; fi
  if [[ -e $CFG_LIVE || -S $SOCK ]]; then lianli=true; fi
  # Detect live only when the profile has no sensors (a cheap text test; a
  # profile whose "sensors" is not an object reads as no sources at all).
  if [[ ! -f $pf || $(<"$pf") != *'"sensors"'* ]]; then det=$(sensors_detect) || det=null; fi
  jq -Rn --argjson nvsmi "$nvsmi" --argjson lianli "$lianli" --rawfile inv <(sensors_inventory) \
    --rawfile prof <(cat "$pf" 2>/dev/null || true) --argjson det "${det:-null}" "$SENSORS_JQ"'
    ($inv | rows) as $r
    | (try ($prof | fromjson | objects) catch null) as $p
    | (($p.sensors | objects) // null) as $ps
    | (if $ps then "profile" else "detected" end) as $source
    | ($ps // ($det | objects) // {}) as $s
    # A Lian Li source names a profile device key; the daemon speaks device_id.
    | def lianli($x): if ($x | type) != "object" then null
        else ($p.devices[$x.device // ""] // {}) as $d
          | {kind: "lianli", device_id: ($d.seen_id // $d.match.device_id
               // (if $d.match.mac then "wireless:" + $d.match.mac else null end)),
             field: ($x.field // "coolant_temps")} end;
    # Every GPU source except the one picked as "gpu", discrete first.
    ([$r[] | select(.k == "nv") | {kind: "nvidia-smi", index, name}]
      + [$r | gpu_hw | src]) as $allg
    | {v: 1, source: $source,
       cpu: resolve($s.cpu; $r; $nvsmi),
       gpu: resolve($s.gpu; $r; $nvsmi),
       gpus: [($allg[] | select(. != $s.gpu and (.kind != "hwmon" or .driver != $s.gpu.driver
                                  or .integrated != $s.gpu.integrated))
               | resolve(.; $r; $nvsmi))] | unique_by([.kind, .index, .input]),
       coolant: (if $ps then lianli($ps.coolant)
                 elif $lianli then {kind: "lianli", device_id: null, field: "coolant_temps"} else null end),
       pump: (if $ps then lianli($ps.pump)
              elif $lianli then {kind: "lianli", device_id: null, field: "fan_rpms"} else null end),
       ram: (if $s.ram == null then []
             else [$r | matches($s.ram) | file_out($s.ram) + {available: true}] | .[:($s.ram.count // 64)] end)}'
}
