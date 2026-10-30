# lib/pc-lights/theme.jq — theme v3: role resolution, palette derivation,
# calibration and screens by role/model (portability plan §4 and §5).
#
# A jq module: only defs, nothing runs at load time. Load it with
#   jq -L "$PCL_LIB" 'include "theme"; compile($T; $P; $M)' ...
# It is the single implementation shared by compile (theme.sh), themes
# --json (json.sh), validation and migrate's identity check (migrate.sh).
#
# Owner: WP3 (theme v3)
# Public entry points (everything else is th_* internals):
#   compile($T; $P; $M)             EFF: the v2-shaped superset (+_roles, _coverage, _compiled)
#   compile($T; $P; $M; $C)         the same with calibration presets ($C = calibration-presets.json)
#   coverage($T; $P; $M)            {summary, roles, counts, missing} for v2 and v3 themes
#   coverage_of($eff)               the same summary from an already compiled EFF
#   v2_projection($P)               the identity-check view of a v2 file or an EFF (migrate)
#   explain_rows($T; $P; $M; $C)    [{role, kind, source, value, raw?, device, name, label}] for explain
#   v3_problems($modes)             one message per problem in a v3 theme (validate_theme)
#   calibrate_hex($cls)             one colour through a calibration class (tests, tools)
#   led_safe_hex                    the auto-theme LED treatment (hue kept, S = V = 1)
#   role_kind  role_group  screen_roles($P)  models($M)
# $P may be null or {} (no profile): compile then emits only the legacy keys.

# ---- colours ------------------------------------------------------------------
def th_hex: type == "string" and test("^#?[0-9a-fA-F]{6}$");
def th_rgb: ltrimstr("#") | ascii_downcase | explode
  | map(if . >= 97 then . - 87 else . - 48 end) | [.[0] * 16 + .[1], .[2] * 16 + .[3], .[4] * 16 + .[5]];
def th_byte: round | if . < 0 then 0 elif . > 255 then 255 else . end;
def th_tohex: map(th_byte | "0123456789abcdef"[(. / 16 | floor):(. / 16 | floor) + 1] + "0123456789abcdef"[(. % 16):(. % 16) + 1]) | add;
# [r,g,b] 0-255 -> [hue 0-360, saturation 0-1, value 0-1]
def th_hsv: map(. / 255) as [$r, $g, $b] | ([$r, $g, $b] | max) as $mx | ([$r, $g, $b] | min) as $mn | ($mx - $mn) as $d
  | (if $d == 0 then 0 elif $mx == $r then 60 * (($g - $b) / $d)
     elif $mx == $g then 60 * (($b - $r) / $d + 2) else 60 * (($r - $g) / $d + 4) end) as $h
  | [(if $h < 0 then $h + 360 else $h end), (if $mx == 0 then 0 else $d / $mx end), $mx];
def th_fromhsv: . as [$h, $s, $v] | ($h / 60) as $x | ($x | floor) as $i | ($x - $i) as $f
  | ($v * (1 - $s)) as $p | ($v * (1 - $s * $f)) as $q | ($v * (1 - $s * (1 - $f))) as $t
  | (if $i % 6 == 0 then [$v, $t, $p] elif $i % 6 == 1 then [$q, $v, $p] elif $i % 6 == 2 then [$p, $v, $t]
     elif $i % 6 == 3 then [$p, $q, $v] elif $i % 6 == 4 then [$t, $p, $v] else [$v, $p, $q] end)
  | map(. * 255);
def th_mix($a; $b; $f): [($a | th_rgb), ($b | th_rgb)] | transpose | map(.[0] + (.[1] - .[0]) * $f) | th_tohex;
# The auto-theme treatment: keep the hue, push saturation and value to 1.
# Near-neutral colours (S < 0.15: white, greys) stay as they are; forcing
# them would turn white into red.
def led_safe_hex: if th_hex | not then . else
  (th_rgb | th_hsv) as $c | if $c[1] < 0.15 then . else [$c[0], 1, 1] | th_fromhsv | th_tohex end end;
# Apply f to every colour inside a role value (strings, gradient stops, lists);
# "_" keys and the non-colour fields are left alone.
def th_map_hex(f): if type == "string" then (if th_hex then f else . end)
  elif type == "array" then map(th_map_hex(f))
  elif type == "object" then with_entries(if (.key | startswith("_")) or (.key | IN("mode", "direction", "span", "speed", "brightness"))
                                           then . else .value |= th_map_hex(f) end)
  else . end;

# ---- calibration (plan §5; identity when the class is missing) ----------------
# For (R,G,B): 1. gain per channel; then, only when R is the largest channel,
# 2. warm cut (hue 0-70°, G/R > warm_gr_max): G' = R·max, B' = B·(max/(G/R));
# 3. pink cut (hue 290-360°, G/R > pink_gr_max): G' = R·max, B' = min(B, R·pink_br_max).
def calibrate_hex($cls): if $cls == null or (th_hex | not) then . else
  th_rgb | (if $cls.gain then [.[0] * $cls.gain[0], .[1] * $cls.gain[1], .[2] * $cls.gain[2]] | map(th_byte) else . end)
  | . as [$R, $G, $B] | (th_hsv) as [$hue, $sat]
  # Near-neutrals (whites, greys) pass unchanged, as CALIBRATION.md says and
  # led_safe_hex does: white's hue reads 0, which the warm cut took for red
  # (ffffff became ff4d4d on the fans).
  | if $R <= 0 or $R < $G or $R < $B or $sat < 0.15 then .
    elif $cls.warm_gr_max != null and $hue >= 0 and $hue <= 70 and ($G / $R) > $cls.warm_gr_max then
      ($cls.warm_gr_max / ($G / $R)) as $f | [$R, ($R * $cls.warm_gr_max | round), ($B * $f | round)]
    elif $cls.pink_gr_max != null and $hue >= 290 and $hue < 360 and ($G / $R) > $cls.pink_gr_max then
      [$R, ($R * $cls.pink_gr_max | round),
       (if $cls.pink_br_max != null then [$B, ($R * $cls.pink_br_max | round)] | min else $B end)]
    else . end
  | th_tohex end;

# ---- models (lib/pc-lights/models.json, WP2) ----------------------------------
# Normalised to {lcd: {Family: {aspect, media, orientation, ...}}, class: {Family: cls}}.
# Accepts {lcd|lcds|screens: {...}, class|classes|led|leds: {...}} or a flat
# {Family: {aspect...} | {class}} table; falls back to the plan §4 table.
def th_default_models: {
  lcd: {
    TlFlexLcd: {aspect: "square", media: [400, 400], orientation: 0},
    TlLcd: {aspect: "square", media: [400, 400], orientation: 0},
    Tlv2Lcd: {aspect: "square", media: [400, 400], orientation: 0},
    SlInfFlexLcd: {aspect: "square", media: [400, 400], orientation: 0},
    HydroShift2OledCurveLcd: {aspect: "wide-curve", media: [2288, 1080], orientation: 90, max_fps: 60, transcode_cap_mb: 256},
    UniversalScreen: {aspect: "strip", media: [1920, 480], orientation: 90, templates: true},
    HydroShiftLcd: {aspect: "round", media: [480, 480], orientation: 0},
    Galahad2Lcd: {aspect: "round", media: [480, 480], orientation: 0}
  },
  class: {
    Tlv2Led: "tl_fan", TlLed: "tl_fan", Tlv2: "tl_fan",
    WirelessStrimer: "strimer", StrimerPlus: "strimer",
    HydroShift2OledCurveLed: "ring", HydroShiftLed: "ring", UniversalScreenLighting: "ring",
    Galahad2Led: "ring", WirelessAio: "ring"
  }
};
def models($M): if ($M | type) != "object" or ($M | length) == 0 then th_default_models else
  ($M | with_entries(select(.key | startswith("_") | not))) as $m
  | {lcd: ($m.lcd // $m.lcds // $m.screens // $m.models
           // ($m | with_entries(select(.value | type == "object" and has("aspect"))))),
     class: (($m.class // $m.classes // $m.led // $m.leds
              // ($m | with_entries(select(.value | type == "object" and (.class | type) == "string"))))
             | map_values(if type == "object" then .class else . end))}
  | if (.lcd | length) == 0 then .lcd = th_default_models.lcd else . end
  | if (.class | length) == 0 then .class = th_default_models.class else . end end;

# ---- roles --------------------------------------------------------------------
# kind: fan strimer ring gpu board ram peripheral screen (null = not lighting)
def role_kind: if startswith("fans.") then "fan" elif startswith("strimer.") then "strimer"
  elif endswith(".ring") or . == "pump.logo" then "ring"
  elif . == "gpu" then "gpu" elif . == "board" or . == "board.argb" then "board" elif . == "ram" then "ram"
  elif IN("keyboard", "mouse", "mousepad", "headset") or startswith("ledstrip.") or startswith("other.") then "peripheral"
  elif test("^screen\\.(fan|aux)[0-9]+$") or IN("screen.pump", "screen.main") then "screen"
  else null end;
# The theme's group key a role falls back to (null: none).
def role_group: role_kind as $k
  | if $k == "fan" then "fans" elif $k == "strimer" then "strimers" elif $k == "ring" then "rings"
    elif . == "board.argb" then "board" elif $k == "peripheral" then "peripherals" else null end;
def th_group_kind: {fans: "fan", strimers: "strimer", rings: "ring", gpu: "gpu", board: "board", ram: "ram", peripherals: "peripheral"}[.];
# The v2 key a kind's partial lives under.
def th_v2key: {fan: "fans", strimer: "strimers", ring: "rings", gpu: "gpu", board: "board", ram: "ram", peripheral: "peripheral"}[.];
def th_role_dev($P): ($P.roles[.] // {}) as $r | ($r.device // ($r.devices // [])[0]) as $k
  | if $k then ($P.devices[$k] // {}) + {_key: $k} else null end;
# Calibration class of a role: its device's family through the model table,
# otherwise the kind (fan roles on a non-TL family calibrate as "fan").
def th_class($P; $MM): . as $R | ($R | role_kind) as $k | ($R | th_role_dev($P)) as $d
  | ($MM.class[$d.family // ""] // null) // (if $k == "fan" then "fan" else $k end);
def th_screen_rank: if test("^screen\\.fan[0-9]+$") then [0, (.[10:] | tonumber)] elif . == "screen.pump" then [1, 0]
  elif . == "screen.main" then [2, 0] elif test("^screen\\.aux[0-9]+$") then [3, (.[10:] | tonumber)] else [9, 0] end;
# Screen roles in apply order: screen.fan1..n, screen.pump, screen.main, screen.aux*.
def screen_roles($P): [($P.roles // {}) | keys_unsorted[] | select(role_kind == "screen")] | sort_by(th_screen_rank);

# ---- palette and derivation (plan §5 table) -----------------------------------
def th_palette($T): ($T.palette // {}) as $p
  | ($p.primary // "ffffff") as $pr | ($p.secondary // $pr) as $se
  | $p + {primary: $pr, secondary: $se, accent: ($p.accent // th_mix($pr; $se; 0.5))};
# The colours derivation draws from: led_safe (default on) treats derived values only.
def th_dpal($pal): if $pal.led_safe == false then $pal
  else $pal + {primary: ($pal.primary | led_safe_hex), secondary: ($pal.secondary | led_safe_hex),
               accent: ($pal.accent | led_safe_hex)} end;
def th_derive($R; $kind; $d; $mo):
  if $kind == "fan" then {inner: $d.primary, outer: $d.secondary}
  elif $kind == "strimer" then {mode: ($mo.mode // "Drizzling"), colors: [$d.primary, $d.secondary, $d.accent, $d.primary, $d.secondary, $d.accent],
                                speed: ($mo.speed // 2), direction: ($mo.direction // "Clockwise")}
  elif $kind == "ring" or $kind == "board" then $d.accent
  elif $kind == "gpu" then {gradient: [$d.primary, $d.secondary]}
  elif $kind == "ram" then {gradient: [$d.primary, $d.accent, $d.secondary], span: "across"}
  elif $kind == "peripheral" and $R == "keyboard" then $d.primary
  else null end;
def th_nounder: if type == "object" then with_entries(select(.key | startswith("_") | not)) else . end;
# A fans value in any accepted form -> {inner, outer} (a bare colour or list is both).
def th_fanval: if type == "object" then . elif . == null then {} else {inner: ., outer: .} end;

# Resolve one lighting role: {value, source} (value null = skip).
# Order: T.roles[R] // T.roles[group] // derived; fans resolve inner/outer
# separately and strimers fill missing fields, both from the next level down.
def th_resolve($R; $T; $d; $mo): ($R | role_kind) as $k | ($R | role_group) as $g
  | ($T.roles // {}) as $tr | $tr[$R] as $own | (if $g then $tr[$g] else null end) as $grp
  | (if $own != null then "theme" elif $grp != null then "group" else "palette" end) as $src
  | if $k == "fan" then
      th_derive($R; $k; $d; $mo) as $dv | ($own | th_fanval) as $o | ($grp | th_fanval) as $gv
      | {value: {inner: ($o.inner // $gv.inner // $dv.inner), outer: ($o.outer // $gv.outer // $dv.outer)}, source: $src}
    elif $k == "strimer" then
      (if $own != null and $grp != null then ($grp | th_nounder) + ($own | th_nounder) else ($own // $grp | th_nounder) end) as $o
      | {value: (if $o != null and ($o | type) == "object" and ([$o | has("mode", "colors", "speed", "direction")] | all) then $o
                 else th_derive($R; $k; $d; $mo) + ($o // {} | objects) end), source: $src}
    elif $k == "peripheral" and $own == null and $grp == null then
      {value: th_derive($R; $k; $d; $mo), source: "palette"}
    else {value: ($own // $grp // th_derive($R; $k; $d; $mo) | th_nounder), source: $src} end;
def th_partial($k): if $k == "fan" then {fans: {top: .inner, bottom: .outer}} else {($k | th_v2key): .} end;
def th_fans_legacy: with_entries(.key |= (if . == "inner" then "top" elif . == "outer" then "bottom" else . end));

# ---- screens ------------------------------------------------------------------
def th_fits($e; $fam; $MM): $e.model == null or $e.model == $fam
  or ($MM.lcd[$e.model].aspect != null and $MM.lcd[$e.model].aspect == $MM.lcd[$fam].aspect);
def th_pick($v; $i): if ($v | type) == "array" then (if ($v | length) > 0 then $v[$i % ($v | length)] else null end) else $v end;
# {entry, source} for screen role $S (entry null: nothing fits).
def th_screen_entry($S; $T; $P; $MM): ($T.screens // {}) as $ts | ($S | th_role_dev($P)) as $dev | ($dev.family // "") as $fam
  | ($S | th_screen_rank | .[1] | if . > 0 then . - 1 else 0 end) as $i
  | ($S | sub("[0-9]+$"; "")) as $base
  | [ ({e: $ts[$S], src: "theme"}),
      (if $base != $S then {e: th_pick($ts[$base]; $i), src: "theme"} else empty end),
      ({e: th_pick($ts["model:" + $fam]; $i), src: "model"}) ]
  | map(select(.e | type == "object")) as $c
  | if ($c | length) == 0 then {entry: null, source: "none"}
    elif th_fits($c[0].e; $fam; $MM) then {entry: $c[0].e, source: $c[0].src}
    else {entry: null, source: "none", unfit: $c[0].e.model} end;
def th_screen_out($S; $e; $P; $MM): ($S | th_role_dev($P)) as $dev | ($P.roles[$S] // {}) as $r
  | ($e._where // $r.label) as $where
  | ($dev.match.usb_serial // ($dev._key // "" | ltrimstr("lianli:lcd:"))) as $ser
  | (if $where != null then {_where: $where} else {} end)
  + {serial: $ser, type: $e.type}
  + (if $e | has("path") then {path: $e.path} else {} end)
  + (if $e | has("template_id") then {template_id: $e.template_id} else {} end)
  + {orientation: ($e.orientation // ((($MM.lcd[$dev.family // ""].orientation // 0) + ($r.mount // 0)) % 360))}
  + ($e | with_entries(select(.key | IN("brightness", "clips", "rotate", "shuffle"))));

# ---- compile (plan §5) ----------------------------------------------------------
def th_cal_classes($P; $C): ($P.calibration // {}) as $c
  | (if $c.preset != null then ($C[$c.preset].classes // {}) else {} end) * ($c.classes // {});
def compile($T; $P; $M; $C):
  if ($T.v // 2) != 3 then $T else
  ($P // {}) as $P | models($M) as $MM | th_palette($T) as $pal | th_dpal($pal) as $d | ($T.motion // {}) as $mo
  | (($P.calibration.enabled // false) == true and ($T.led.calibrated_for // null) != ($P.machine.name // null)) as $cal
  | th_cal_classes($P; $C) as $classes
  | def cal($cls): if $cal then th_map_hex(calibrate_hex($classes[$cls])) else . end;
  # lighting roles
  ([($P.roles // {}) | to_entries[] | .key as $R | ($R | role_kind) as $k
     | select($k != null and $k != "screen")
     | if .value.managed == false then {role: $R, cov: "unmanaged"}
       else th_resolve($R; $T; $d; $mo) as $x
         | if $x.value == null then {role: $R, cov: "none"}
           else {role: $R, cov: $x.source, partial: ($x.value | cal($R | th_class($P; $MM)) | th_partial($k))} end
       end]) as $lr
  | ($lr | map(select(.partial) | {(.role): .partial}) | add // {}) as $roles
  | def firstrole($g): [$lr[] | select(.partial and (.role | role_group // .) == $g)][0].role;
  def gclass($g): (firstrole($g) | if . then th_class($P; $MM) else null end) // ($g | th_group_kind | if . == "fan" then "fan" else . end);
  def legacy($g): ($g | th_group_kind) as $k | ($T.roles // {})[$g] as $tv
    | if $tv != null then
        (if $k == "fan" then ($tv | th_fanval) as $f | th_derive(null; "fan"; $d; $mo) as $dv
            | $f + {inner: ($f.inner // $dv.inner), outer: ($f.outer // $dv.outer)} | cal(gclass($g)) | th_fans_legacy
         elif $k == "strimer" and ($tv | type) == "object" and ([$tv | has("mode", "colors", "speed", "direction")] | all | not)
         then th_derive(null; "strimer"; $d; $mo) + $tv | cal(gclass($g))
         else $tv | cal(gclass($g)) end)
      elif firstrole($g) then $roles[firstrole($g)][$k | th_v2key]
      else th_derive(null; $k; $d; $mo) | cal(gclass($g)) | if $k == "fan" then th_fans_legacy else . end end;
  # screens
  ([screen_roles($P)[] as $S
     | if ($P.roles[$S].managed == false) then {role: $S, cov: "unmanaged"}
       else th_screen_entry($S; $T; $P; $MM) as $x
         | if $x.entry then {role: $S, cov: $x.source, out: th_screen_out($S; $x.entry; $P; $MM)}
           else {role: $S, cov: "none"} end end]) as $sr
  | ($T | with_entries(select(.key | startswith("_")))) as $under
  | $under
  + {palette: $pal,
     fans: legacy("fans"), strimers: legacy("strimers"), rings: legacy("rings"),
     gpu: legacy("gpu"), board: legacy("board"), ram: legacy("ram")}
  + (if $T.alert != null then {alert: $T.alert} elif $pal.alert != null then {alert: {color: $pal.alert}} else {} end)
  + {screens: [$sr[] | .out | select(. != null)]}
  + (if $T.templates != null then {templates: $T.templates} else {} end)
  + {_roles: $roles,
     _coverage: (($lr + $sr) | map({(.role): .cov}) | add // {}),
     _compiled: {schema: 3, machine: ($P.machine.name // null), calibrated: $cal}}
  end;
def compile($T; $P; $M): compile($T; $P; $M; {});

# ---- coverage (themes --json, plan §9) ------------------------------------------
# counts.theme includes group and model hits; unmanaged roles are not counted.
def coverage_of($eff): ($eff._coverage // {}) as $c
  | [$c | to_entries[] | select(.value != "unmanaged")] as $e
  | {theme: ([$e[] | select(.value | IN("theme", "group", "model"))] | length),
     palette: ([$e[] | select(.value == "palette")] | length),
     none: ([$e[] | select(.value == "none")] | length), total: ($e | length)} as $n
  | ([$e[] | select(.key | role_kind == "screen")]) as $scr
  | {summary: (if $n.none == 0 then "full"
              elif ($scr | length) > 0 and all($scr[]; .value == "none") and $n.none == ($scr | length) then "leds-only"
              else "partial" end),
     roles: $c, counts: $n, missing: [$e[] | select(.value == "none") | .key]};
# v2 themes: every lighting role takes its group value; a screen role is
# covered when its USB serial is in screens[]. "foreign": the theme has
# screens and none of them is on this machine.
def th_v2_cov($T; $P): ($P // {}) as $P
  | [($T.screens // [])[]? | objects | .serial] as $sers
  | [($P.roles // {}) | to_entries[] | .key as $R | ($R | role_kind) as $k | select($k != null)
     | {key: $R, value: (if .value.managed == false then "unmanaged"
                elif $k == "screen" then (($R | th_role_dev($P)) as $dv
                  | ($dv.match.usb_serial // "") as $s | if $s != "" and ($sers | index($s)) then "theme" else "none" end)
                elif $k == "peripheral" then "none"
                elif $T[$k | th_v2key] != null then "group" else "none" end)}] | from_entries;
def coverage($T; $P; $M):
  if ($T.v // 2) == 3 then coverage_of(compile($T; $P; $M))
  else th_v2_cov($T; $P) as $c | coverage_of({_coverage: $c})
    | ([($T.screens // [])[]? | objects | .serial]) as $sers
    | if ($sers | length) > 0 and ([$c | to_entries[] | select((.key | role_kind) == "screen" and .value == "theme")] | length) == 0
      then .summary = "foreign" else . end end;

# ---- identity check (migrate, plan §6 step 4) -------------------------------------
# The same view of a v2 file and of compile(v3): lighting keys, alert,
# templates, and screens as serial -> {type, path, orientation, ...}.
def v2_projection($P): {fans: (.fans | th_nounder), strimers: (.strimers | th_nounder), rings, gpu, board, ram,
    alert: (.alert // null), templates: (.templates // null),
    screens: ([(.screens // [])[] | {(.serial): {type, path, orientation, template_id, brightness, clips, rotate, shuffle, _where}}] | add // {})};

# ---- explain ---------------------------------------------------------------------
def th_show: if type == "string" then .
  elif type == "object" and has("fans") then "inner \(.fans.top | if type == "array" then join(",") else . end) outer \(.fans.bottom | if type == "array" then join(",") else . end)"
  elif type == "object" and (keys | length) == 1 and (to_entries[0].value | type) != "array" then (to_entries[0].value | th_show)
  elif type == "object" and has("mode") then "\(.mode) \((.colors // []) | join(",")) speed \(.speed // "-") \(.direction // "")"
  elif type == "object" then (to_entries | map("\(.key) \(.value | if type == "array" then join(",") else tostring end)") | join(" "))
  else tojson end;
def explain_rows($T; $P; $M; $C): ($P // {}) as $P | models($M) as $MM
  | compile($T; $P; $M; $C) as $eff
  | compile($T; ($P | .calibration.enabled = false); $M; $C) as $raw
  | [ (($eff._coverage // {}) | to_entries[] | .key as $R | ($R | th_role_dev($P)) as $dv
      | {role: $R, kind: ($R | role_kind), source: .value, device: ($dv._key // null), name: ($dv.name // null),
         label: ($P.roles[$R].label // null), present: $dv.present}
      + if (.key | role_kind) == "screen" then
          ([$eff.screens[] | select(.serial == ($dv.match.usb_serial // ""))][0]) as $s
          | th_screen_entry($R; $T; $P; $MM) as $x
          | {value: (if $s then "\($s.type) \($s.path // $s.template_id // "")"
                     + " @\($s.orientation)"
                     + (if $x.entry.orientation != null then " (explicit)"
                        else " (model \($MM.lcd[$dv.family // ""].orientation // 0) + mount \($P.roles[$R].mount // 0))" end)
                     + (if $s.clips then " clips \($s.clips | join(","))" else "" end)
                   elif $x.unfit then "made for \($x.unfit), not \($dv.family // "?")"
                   else null end)}
        else ($eff._roles[$R] | if . then th_show else null end) as $v
          | ($raw._roles[$R] | if . then th_show else null end) as $rv
          | {value: $v} + (if $rv != $v then {raw: $rv} else {} end) end ) ];

# ---- validation (v3 schema; the EFF then goes through the v2 checks) ---------------
def v3_problems($modes):
  def hex: th_hex;
  def ok(f): [try f catch false] | length > 0 and all;
  def chk(f; $msg): if ok(f) then empty else $msg end;
  def int($lo; $hi): type == "number" and . == floor and . >= $lo and . <= $hi;
  def fan_colour: hex or (type == "array" and length >= 1 and length <= 4 and all(hex));
  def colourish: hex or (type == "object" and (.colors == null or (.colors | type == "array" and all(hex)))
                         and (.mode == null or (.mode | type == "string")));
  ($modes | split(" ")) as $ml
  | def strimer($w): chk(type == "object"; "\($w) must be an object"),
      chk(.mode == null or (.mode | IN($ml[])); "\($w).mode \(.mode | tojson) is not a lian-li-linux RgbMode"),
      chk(.colors == null or (.colors | type == "array" and length == 6 and all(hex)); "\($w).colors must be exactly 6 hex colours"),
      chk(.speed == null or (.speed | int(0; 4)); "\($w).speed must be a whole number 0-4"),
      chk(.brightness == null or (.brightness | int(0; 4)); "\($w).brightness must be a whole number 0-4"),
      chk(.direction == null or (.direction | IN("Clockwise", "CounterClockwise", "Up", "Down", "Spread", "Gather"));
          "\($w).direction must be Clockwise or CounterClockwise");
    def screen($w): chk(type == "object"; "\($w) must be an object"),
      chk(.type | IN("image", "video", "gif", "custom"); "\($w).type must be image, video or custom"),
      chk((.type | IN("image", "video", "gif") | not) or (.path | type == "string"); "\($w) needs a path"),
      chk(.type != "custom" or (.template_id | type == "string"); "\($w) (custom) needs a template_id"),
      chk(.orientation == null or (.orientation | int(0; 359)); "\($w).orientation must be a whole number 0-359"),
      chk(.brightness == null or (.brightness | int(0; 100)); "\($w).brightness must be a whole number 0-100"),
      chk(.clips == null or (.clips | type == "array" and all(type == "string")); "\($w).clips must be a list of files or folders"),
      chk(.clips == null or .type == "video"; "\($w).clips only work on a video screen"),
      chk(.rotate == null or (.rotate | int(30; 86400)); "\($w).rotate must be whole seconds, 30-86400"),
      chk(.shuffle == null or (.shuffle | type == "boolean"); "\($w).shuffle must be true or false"),
      chk(.model == null or (.model | type == "string"); "\($w).model must be a device family name"),
      chk(.serial == null; "\($w).serial is not used in v3 (screens are keyed by role)");
  [ chk(.palette | type == "object"; "palette must be an object with a primary colour"),
    chk(.palette.primary | hex; "palette.primary must be 6 hex digits"),
    (("secondary", "accent", "alert") as $k | chk(.palette[$k] == null or (.palette[$k] | hex); "palette.\($k) must be 6 hex digits")),
    chk(.palette.led_safe == null or (.palette.led_safe | type == "boolean"); "palette.led_safe must be true or false"),
    chk(.led == null or (.led | type == "object"); "led must be an object"),
    chk(.led.calibrated_for == null or (.led.calibrated_for | type == "string"); "led.calibrated_for must be a machine name"),
    chk(.motion == null or (.motion | type == "object"); "motion must be an object"),
    (.motion | objects | strimer("motion")),
    chk(.roles == null or (.roles | type == "object"); "roles must be an object"),
    ((.roles // {}) | objects | to_entries[] | select(.key | startswith("_") | not) | .key as $R | .value as $v
      | "roles.\($R)" as $w | ($R | th_group_kind // role_kind) as $k
      | if $k == null or $k == "screen" then "\($w) is not a lighting role or group (fans, strimers, rings, gpu, board, ram, peripherals, fans.<pos>, ...)"
        elif $k == "fan" then ($v | chk(type == "object" or fan_colour; "\($w) must be {inner, outer} colours"),
            chk(type != "object" or ((.inner == null or (.inner | fan_colour)) and (.outer == null or (.outer | fan_colour)));
                "\($w).inner/.outer must be 6 hex digits or a list of 1-4 (one per fan)"))
        elif $k == "strimer" then ($v | strimer($w))
        elif $k == "ring" or $k == "board" or $k == "peripheral" then ($v | chk(colourish; "\($w) must be a colour or {mode, colors}"))
        else ($v | chk(type == "object" or hex; "\($w) must be a colour or an object")) end),
    chk(.screens == null or (.screens | type == "object"); "screens must be an object keyed by screen role (screen.fan, screen.pump, model:<Family>, ...)"),
    ((.screens // {}) | objects | to_entries[] | select(.key | startswith("_") | not) | .key as $S | "screens.\($S)" as $w
      | if ($S | test("^(screen\\.(fan|aux)[0-9]*|screen\\.pump|screen\\.main|model:[A-Za-z0-9_]+)$") | not) then "\($w) is not a screen role"
        elif (.value | type) == "array" then
          (chk($S | test("^(screen\\.(fan|aux)|model:.+)$"); "\($w): only screen.fan, screen.aux and model:<Family> take a list"),
           (.value | to_entries[] | .key as $i | .value | screen("\($w)[\($i)]")))
        else (.value | screen($w)) end),
    chk(.templates == null or (.templates | type == "array" and all(type == "string")); "templates must be a list of paths") ]
  | .[];
