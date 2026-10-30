# lib/pc-lights/editor.jq — the theme editor's jq half (editor plan §1.3, §1.4;
# screens plan §1.3a, §4): JSON Pointer edits of a v3 theme, the editor view
# with per-field sources, what the LEDs show after calibration, the LED
# colour hints, and the screens: where an edit of a screen role goes, the
# @role pointers, clip lists, media and mode edits, and the screens view.
#
# Only defs, nothing runs at load time. It is not a jq module: jq 1.8.2
# aborts (compile.c assertion) on any module that includes another one, so
# the defs are spliced in after theme.jq's (editor.sh's ed_jq does this):
#   jq -L "$PCL_LIB" 'include "theme"; '"$(cat editor.jq)"' editor_view(...)' ...
# The screens view also needs media.jq's media_fit and media_title (package
# B1): editor.sh's ed_mjq splices media.jq (or stand-ins) in front of it.
# It uses theme.jq's defs and never redefines any: resolution,
# derivation and calibration are theme.jq's own (th_resolve, th_palette,
# th_dpal, th_class, calibrate_hex, th_cal_classes, compile, th_screen_entry,
# th_screen_out, th_fits), so the views show exactly what compile would send.
#
# Owner: editor package A (lib/pc-lights/editor.sh); screens: package B2
# Public entry points:
#   apply_ops($ops; $P; $M)  the theme with RFC 6902 ops applied (add/replace/remove,
#                         RFC 6901 pointers, /screens/@<role>/<field> aliases), then
#                         normalised (ed_normalise); apply_ops($ops) without a profile
#   editor_view($D; $S; $P; $M; $C; $modes; $refs)   the §1.4 view object
#   led_hints($hex; $cls; $cal)   [{code, level, text, fix}] for one colour
#   ed_show($cls; $cal)   a colour (or list) as the LEDs of class $cls get it
#   ed_problem_path($T)   a validation message -> the pointer it is about (or null)
#   ed_screen_target($S; $T; $P)   where an edit of screen role $S goes (plan §4.1)
#   ed_media_edit($v; $P; $M; $now)   a "theme media" verb on a draft (plan §4.3-§4.5)
#   ed_screens_view($D; $P; $M; $C; $X; $modes)   the "theme screens" view (plan §1.3a)
#   ed_screens_sig($T)    the signature of a theme's screens and templates
# $cal is the view's "calibration" object: {applies, classes, fix_classes}.

# ---- JSON Pointers (RFC 6901) -------------------------------------------------
def ed_esc: tostring | gsub("~"; "~0") | gsub("/"; "~1");
# A jq path (array of keys and indices) -> its pointer.
def ed_ptr: if length == 0 then "" else "/" + (map(ed_esc) | join("/")) end;
# A pointer -> its reference tokens (strings, unescaped: ~1 first, then ~0).
def ed_tokens: if type != "string" then error("a path must be a string, not \(tojson)")
  elif . == "" then []
  elif startswith("/") | not then error("path \(tojson) must start with /")
  else .[1:] | split("/") | map(gsub("~1"; "/") | gsub("~0"; "~")) end;
# Tokens -> a jq path into the input: a number where the container is a list
# (or missing and the token is an index; "-" = the end), a key otherwise.
def ed_jqpath($toks): . as $doc | reduce $toks[] as $t ({p: [], v: $doc};
    (.v | type) as $ty
    | (if $ty == "array" then
         (if $t == "-" then (.v | length) elif ($t | test("^(0|[1-9][0-9]*)$")) then ($t | tonumber)
          else error("\(.p | ed_ptr) is a list: \($t | tojson) is not an index") end)
       elif $ty == "null" and ($t | test("^(0|[1-9][0-9]*)$")) then ($t | tonumber)
       elif $ty == "null" and $t == "-" then 0
       elif $ty == "object" or $ty == "null" then $t
       else error("\(.p | ed_ptr) is a \($ty), there is nothing inside it") end) as $k
    | .p += [$k]
    | .v = (if (.v | type) == "array" or (.v | type) == "object" then .v[$k] else null end))
  | .p;

# ---- screens: roles, where an entry comes from, where an edit goes -----------
# (screens plan §4.1; mirrors theme.jq's th_screen_entry, which compile uses)
# A short signature of what the screens show, [screens, templates] hashed:
# two polynomial hashes, 16 hex digits (jq has no sha; this only tells a
# changed screens section from an unchanged one).
def ed_hex8: [range(7; -1; -1) as $i | ((. / pow(16; $i)) | floor) % 16] | map("0123456789abcdef"[.:.+1]) | add;
def ed_sig: tojson | explode
  | reduce .[] as $c ([5381, 7]; [(.[0] * 33 + $c) % 4294967291, (.[1] * 131 + $c) % 2147483629]) | map(ed_hex8) | add;
def ed_screens_sig($T): [($T.screens // null), ($T.templates // null)] | ed_sig;
# The list index th_pick uses for a role (screen.fan3 -> 2; pump, main -> 0).
def ed_scr_index: th_screen_rank | .[1] | if . > 0 then . - 1 else 0 end;
def ed_scr_base: sub("[0-9]+$"; "");
def ed_scr_kind: if startswith("screen.fan") then "fan" elif . == "screen.pump" then "pump"
  elif . == "screen.main" then "main" else "aux" end;
def ed_scr_fam($P): ((th_role_dev($P) // {}).family // "");
def ed_is_screen_role($P): (role_kind == "screen") and (($P.roles // {})[.] | type) == "object";
# Where the entry of screen role $S comes from, in th_screen_entry's order:
# {key, index, shape: object|list|none, level: role|base|model|none}.
def ed_screen_src($S; $T; $P):
  ($T.screens | objects // {}) as $ts | ($S | ed_scr_fam($P)) as $fam
  | ($S | ed_scr_index) as $i | ($S | ed_scr_base) as $base
  | def at($k; $lvl):
      if ($ts[$k] | type) == "array" and ($ts[$k] | length) > 0 and ($ts[$k][$i % ($ts[$k] | length)] | type) == "object"
      then {key: $k, index: ($i % ($ts[$k] | length)), shape: "list", level: $lvl}
      elif ($ts[$k] | type) == "object" then {key: $k, index: null, shape: "object", level: $lvl}
      else empty end;
  first((if ($ts[$S] | type) == "object" then {key: $S, index: null, shape: "object", level: "role"} else empty end),
        (if $base != $S then at($base; "base") else empty end),
        at("model:" + $fam; "model"),
        {key: null, index: null, shape: "none", level: "none"});
# The raw entry at that source (it may not fit the screen; null: none).
def ed_src_entry($src; $T): ($T.screens | objects // {}) as $ts
  | if $src.shape == "list" then $ts[$src.key][$src.index] elif $src.shape == "object" then $ts[$src.key] else null end;
# The screen roles that may read a list or object key: every screen.fanN for
# "screen.fan", every screen role whose device family is Fam for "model:Fam".
def ed_key_readers($key; $P): [screen_roles($P)[] | . as $R
  | select(if ($key | startswith("model:")) then ($R | ed_scr_fam($P)) == ($key | ltrimstr("model:"))
           else ($R | ed_scr_base) == $key and $R != $key end)];
# Where an edit of screen role $S goes (plan §4.1): {kind: role|list|create,
# key, index, path, expand: [ops to run first], from: <shared key>|null}.
#   role    the role has its own entry: /screens/<role>
#   list    a base or model list: /screens/<key>/<i>; a list shorter than the
#           roles reading it is first dealt out to one entry each (same look,
#           no sharing)
#   create  an object shared by every role of its base or model (copied to
#           /screens/<role> first), or nothing yet
def ed_screen_target($S; $T; $P):
  ($T.screens | objects // {}) as $ts | ed_screen_src($S; $T; $P) as $src | ($S | ed_scr_index) as $i
  | ("/screens/" + ($S | ed_esc)) as $own
  | if $src.level == "role" then {kind: "role", key: $S, index: null, path: $own, expand: [], from: null}
    elif $src.shape == "list" then
      $ts[$src.key] as $l | ($l | length) as $L
      | (([ed_key_readers($src.key; $P)[] | ed_scr_index] + [$i] | max) + 1) as $n
      | ("/screens/" + ($src.key | ed_esc)) as $lp
      | {kind: "list", key: $src.key, index: $i, path: "\($lp)/\($i)",
         expand: (if $L < $n then [{op: "replace", path: $lp, value: [range(0; $n) as $k | $l[$k % $L]]}] else [] end),
         from: null}
    elif $src.shape == "object" then
      {kind: "create", key: $S, index: null, path: $own, expand: [{op: "add", path: $own, value: $ts[$src.key]}], from: $src.key}
    else {kind: "create", key: $S, index: null, path: $own, expand: [], from: null} end;
# The other roles that read the same entry now (before any expansion).
def ed_shared_with($S; $T; $P): ed_screen_src($S; $T; $P) as $s
  | if $s.shape == "none" or $s.level == "role" then []
    else [screen_roles($P)[] | select(. != $S) | . as $R
          | select(ed_screen_src($R; $T; $P) | .key == $s.key and .index == $s.index)] end;
# /screens/@<role>/<field> (plan §4.2): the ops that do it on the role's real
# target, resolved against the theme as it is now (the input): the expansion
# first, then the field. Fields: brightness, rotate, shuffle, orientation.
def ed_alias_leaves: ["brightness", "rotate", "shuffle", "orientation"];
def ed_alias_ops($o; $P): ($o.path | ed_tokens) as $t | . as $T
  | ($t[1] // "" | ltrimstr("@")) as $R
  | if ($t | length) != 3 or $R == "" then error("\($o.path): a screen alias is /screens/@<role>/<field>")
    elif ($P | type) != "object" then error("\($o.path): screen aliases need the hardware profile")
    elif ($R | ed_is_screen_role($P) | not) then error("no-role: \($R) is not a screen role in the hardware profile")
    elif ($t[2] | IN(ed_alias_leaves[]) | not) then error("\($o.path): only brightness, rotate, shuffle and orientation have a screen alias")
    else ed_screen_target($R; $T; $P) as $tg
      | ($o.op == "remove" or $o.value == null) as $rm
      | (ed_src_entry(ed_screen_src($R; $T; $P); $T) // {}) as $cur
      | if $rm and $cur[$t[2]] == null then []
        elif $tg.kind == "create" and $tg.from == null then
          error("\($R) shows nothing from this theme yet: choose a picture or video for it first")
        else $tg.expand + [$o + {path: ($tg.path + "/" + $t[2])}] end end;

# ---- patch ops (an RFC 6902 subset) and normalising ---------------------------
def ed_fan_key: (th_group_kind // role_kind) == "fan";
# A fan role or group written as one colour (or a per-fan list) becomes
# {inner, outer} before one of the two is set.
def ed_prep($t): if ($t | length) >= 3 and $t[0] == "roles" and ($t[2] | IN("inner", "outer")) and ($t[1] | ed_fan_key)
    and (.roles | type) == "object" and ((.roles[$t[1]] | type) | IN("string", "array"))
  then .roles[$t[1]] |= {inner: ., outer: .} else . end;
def ed_op($o):
  if ($o | type) != "object" then error("each op must be an object, not \($o | tojson)") else . end
  | ($o.path | ed_tokens) as $t
  | if $t == [] then error("the whole theme can't be replaced; name a path")
    elif $t[0] == "v" then error("/v stays 3") else . end
  | if $o.op == "remove" or (($o.op | IN("add", "replace")) and $o.value == null) then
      ((try ed_jqpath($t) catch null) as $p | if $p == null then . else delpaths([$p]) end)
    elif ($o.op | IN("add", "replace")) then
      ed_prep($t) | ed_jqpath($t) as $p
      | if $o.op == "add" and ($p[-1] | type) == "number" and (getpath($p[:-1]) | type) == "array"
        then getpath($p[:-1]) as $a | setpath($p[:-1]; $a[:$p[-1]] + [$o.value] + $a[$p[-1]:])
        else setpath($p; $o.value) end
    else error("op must be add, replace or remove, not \($o.op | tojson)") end;
# Hex lower-cased without "#", null members dropped, empty objects pruned
# (a role left with no fields goes, and so does an empty "roles"); "_" keys
# are notes and stay as they are.
def ed_clean: if type == "object" then
    with_entries(select(.value != null)
      | if (.key | startswith("_")) then . else .value |= ed_clean end
      | select(.value != {}))
  elif type == "array" then map(ed_clean)
  elif th_hex then ltrimstr("#") | ascii_downcase
  else . end;
def ed_normalise: ed_clean | if type == "object" then {v: 3} + del(.v) else . end;
# A /screens/@<role>/... op is resolved against the theme as the ops before
# it left it; $P is the hardware profile ($M, the model table, is for the
# screens edits that need it). Without a profile an alias is an error.
def apply_ops($ops; $P; $M): if ($ops | type) != "array" then error("ops must be a list of {op, path, value}")
  else reduce $ops[] as $o (.;
      if ($o | type) == "object" and ($o.path | type) == "string" and ($o.path | startswith("/screens/@"))
      then reduce ed_alias_ops($o; $P)[] as $x (.; ed_op($x))
      else ed_op($o) end)
    | ed_normalise end;
def apply_ops($ops): apply_ops($ops; null; null);

# ---- what the LEDs show, and the LED hints ------------------------------------
# The calibration state of a theme on this profile (the same test compile makes).
def ed_calibration($T; $P; $C): ($P.calibration | objects // {}) as $c | (($c.enabled // false) == true) as $en
  | (($T.led | objects | .calibrated_for) // null) as $cf | ($P.machine.name // null) as $m
  | {enabled: $en, applies: ($en and $cf != $m),
     reason: (if ($en | not) then "off-in-profile" elif $cf == $m then "stamped" else "on" end),
     calibrated_for: $cf, machine: $m, path: "/led/calibrated_for",
     classes: th_cal_classes($P; $C), fix_classes: (($C["lianli-photo"] | objects | .classes) // {})};
def ed_show($cls; $cal): if $cal.applies == true then th_map_hex(calibrate_hex($cal.classes[$cls])) else . end;
# The hint codes of one lower-case hex colour on class $cls, from the photo
# lessons (docs/THEMES.md "Colours that work on LEDs"). The green checks need
# red to be the largest channel (as calibration does) and skip near-neutrals.
def ed_hint_codes($cls): . as $h | th_rgb as [$r, $g, $b] | (th_rgb | th_hsv) as [$hu, $s, $v]
  | (if $r > 0 then $g / $r else 0 end) as $gr
  | ($r > 0 and $r >= $g and $r >= $b and $s >= 0.15) as $redmax
  | [ (if $s < 0.15 and $v > 0.8 then "near_white" elif $s < 0.45 and $v > 0.8 then "pastel" else empty end),
      (if $redmax and $hu <= 70 and $gr > (if $cls == "tl_fan" then 0.3 else 0.6 end) then "warm_green" else empty end),
      (if $redmax and $hu >= 290 and $gr > 0.4 then "pink_green" else empty end),
      (if ($cls | IN("tl_fan", "fan")) and $hu >= 295 and $hu <= 320 and $b >= 0.8 * $r then "violet_magenta" else empty end),
      (if $v < 0.25 then "dark" else empty end) ];
def ed_hint_text: {near_white: "Near-white reads as plain white on LEDs.",
  pastel: "Pastels wash out towards white on LEDs.",
  warm_green: "Too much green for a warm colour: it comes out lemon-yellow on LEDs.",
  pink_green: "Too much green for a pink: it turns white on LEDs.",
  violet_magenta: "Magenta leans violet on fans; for hot pink add red and drop blue (ff1a8c).",
  dark: "Dark colours read muddy or off on LEDs."}[.];
# [{code, level, text, fix}]. fix: the lianli-photo preset's correction for
# the class (pastel and dark: made LED-safe first; violet_magenta: ff1a8c;
# near_white: null; null too when it would not change the colour). When
# calibration applies here and changes the colour, a hint it cures is "info"
# and says what the LEDs get instead: warm_green and pink_green always (the
# green cut is that cure; rounding can leave G/R a hair over the limit), any
# other hint when the calibrated colour no longer has it.
def led_hints($hex; $cls; $cal):
  if ($hex | th_hex | not) then [] else
  ($hex | ltrimstr("#") | ascii_downcase) as $h
  | (($cal.fix_classes // {})[$cls] // null) as $fc
  | (if $cal.applies == true then $h | calibrate_hex(($cal.classes // {})[$cls] // null) else $h end) as $x
  | ($x | ed_hint_codes($cls)) as $after
  | [ ($h | ed_hint_codes($cls))[] as $c
      | {code: $c}
      + (if $x != $h and (($c | IN("warm_green", "pink_green")) or (any($after[]; . == $c) | not))
         then {level: "info", text: "Calibration corrects this on this PC: the LEDs get \($x)."}
         else {level: "warn", text: ($c | ed_hint_text)} end)
      + {fix: (if $c == "near_white" then null elif $c == "violet_magenta" then "ff1a8c"
               elif $c == "pastel" or $c == "dark" then ($h | led_safe_hex | calibrate_hex($fc))
               else ($h | calibrate_hex($fc)) end | if . == $h then null else . end)} ]
  end;

# ---- validation messages -> pointers ------------------------------------------
# v3_problems and validate_theme speak in dotted names ("roles.fans.side.inner",
# "screens.screen.fan[0]", "strimers.colors"); role names contain dots, so
# the longest theme key that fits wins.
def ed_dots: gsub("\\[(?<i>[0-9]+)\\]"; ".\(.i)") | ltrimstr(".") | split(".") | map(ed_esc) | join("/");
def ed_problem_path($T): (split(" ")[0] | split("/")[0] | rtrimstr(":")) as $w
  | def keyed($top; $obj): ($w | ltrimstr($top + ".")) as $r
      | ([($obj | objects // {}) | keys[] | . as $k | select($r == $k or ($r | startswith($k + ".")) or ($r | startswith($k + "[")))]
         | max_by(length)) as $k
      | if $k then "/\($top)/" + ($k | ed_esc) + ($r[($k | length):] | if . == "" then "" else "/" + ed_dots end)
        else "/\($top)/" + ($r | ed_dots) end;
  if $w == "roles" or $w == "screens" or $w == "palette" or $w == "motion" or $w == "led" or $w == "templates" or $w == "alert" then "/" + $w
  elif $w | startswith("roles.") then keyed("roles"; $T.roles)
  elif $w | startswith("screens.") then keyed("screens"; $T.screens)
  elif $w | test("^(palette|motion|led|alert)\\.") then "/" + ($w | ed_dots)
  elif $w | test("^fans\\.(top|bottom)$") then "/roles/fans/" + ({"fans.top": "inner", "fans.bottom": "outer"}[$w])
  elif $w | test("^(strimers|rings|gpu|board|ram)(\\.|$)") then "/roles/" + ($w | ed_dots)
  else null end;

# ---- the editor view (plan §1.4) ----------------------------------------------
def ed_kind_rank: {fan: 0, strimer: 1, ring: 2, gpu: 3, board: 4, ram: 5, peripheral: 6}[.] // 9;
def ed_class_rank: {tl_fan: 0, fan: 1, strimer: 2, ring: 3, gpu: 4, board: 5, ram: 6, peripheral: 7}[.] // 9;
# The lighting roles the editor lists: managed, not screens, not ignore;
# peripherals only when the profile manages them explicitly.
def ed_view_roles($P): [($P.roles // {}) | to_entries[] | .key as $R | ($R | role_kind) as $k
    | select($k != null and $k != "screen" and (.value | type) == "object")
    | select(if $k == "peripheral" then .value.managed == true else .value.managed != false end)
    | {role: $R, rank: ($k | ed_kind_rank)}] | sort_by(.rank) | map(.role);
def ed_src($a; $b): if $a then "role" elif $b then "group" else "palette" end;
def ed_colour_field($path; $value; $source; $spath; $cls; $cal):
  ($value | ed_show($cls; $cal)) as $shows
  | {path: $path, value: $value, source: $source, source_path: $spath, shows: $shows, changed: ($shows != $value),
     hints: (if ($value | type) == "string" then led_hints($value; $cls; $cal) else [] end)};
def ed_list_field($path; $value; $source; $spath; $cls; $cal):
  ($value | ed_show($cls; $cal)) as $shows
  | {path: $path, value: $value, source: $source, source_path: $spath, shows: $shows, changed: ($shows != $value),
     hints: ($value | if type == "array" then map(led_hints(.; $cls; $cal)) else [] end)};

def ed_role($R; $T; $P; $MM; $d; $mo; $cal):
  ($R | role_kind) as $k | ($R | role_group) as $g | ($R | th_role_dev($P)) as $dv
  | ($R | th_class($P; $MM)) as $cls
  | ($T.roles | objects // {}) as $tr | $tr[$R] as $own | (if $g then $tr[$g] else null end) as $grp
  | ("/roles/" + ($R | ed_esc)) as $rp | (if $g then "/roles/" + $g else null end) as $gp
  | {role: $R, kind: $k, group: $g, label: ($P.roles[$R].label // null), device: ($dv._key // null),
     name: ($dv.name // null), present: (if $dv then $dv.present != false else false end),
     managed: ($P.roles[$R].managed != false), backend: ($dv.backend // null), class: $cls,
     source: ed_src($own != null; $grp != null)} as $base
  | def ro($why; $f): $base + {form: "readonly", editable: false, readonly_reason: $why, fields: $f};
    def ok($form; $f): $base + {form: $form, editable: true, readonly_reason: null, fields: $f};
  try (
    if $k == "fan" then
      ($own | th_fanval) as $o | ($grp | th_fanval) as $gv | th_derive($R; "fan"; $d; $mo) as $dv2
      | def ff($f; $pal): ($o[$f] != null) as $a | ($gv[$f] != null) as $b
          | ed_colour_field("\($rp)/\($f)"; ($o[$f] // $gv[$f] // $dv2[$f]); ed_src($a; $b);
              (if $a then (if ($own | type) == "object" then "\($rp)/\($f)" else $rp end)
               elif $b then (if ($grp | type) == "object" then "\($gp)/\($f)" else $gp end)
               else "/palette/\($pal)" end); $cls; $cal);
        {inner: ff("inner"; "primary"), outer: ff("outer"; "secondary")} as $f
      | if ([$f[].value | arrays] | length) > 0 then
          ro("Per-fan list (\([$f[].value | arrays | length] | max) colours). Edit theme.json, or replace it with one colour"; $f)
        else ok("fan"; $f) end
    elif $k == "strimer" then
      if ($own != null and ($own | type) != "object") or ($grp != null and ($grp | type) != "object") then
        ro("Not a Strimer setting ({mode, colors, speed, direction}); see problems"; {})
      else
        ($own | th_nounder // {}) as $o | ($grp | th_nounder // {}) as $gv | th_derive($R; "strimer"; $d; $mo) as $dv2
        | def sf($f): ($o[$f] != null) as $a | ($gv[$f] != null) as $b
            | {path: "\($rp)/\($f)", value: ($o[$f] // $gv[$f] // $dv2[$f]), source: ed_src($a; $b),
               source_path: (if $a then "\($rp)/\($f)" elif $b then "\($gp)/\($f)"
                             elif $f != "colors" and $mo[$f] != null then "/motion/\($f)" else null end)};
          sf("colors") as $c
        | ok("strimer"; {mode: sf("mode"), speed: sf("speed"), direction: sf("direction"),
                         colors: ($c + ed_list_field($c.path; $c.value; $c.source; $c.source_path; $cls; $cal))})
      end
    else
      th_resolve($R; $T; $d; $mo).value as $v
      | (if $own != null then $rp elif $grp != null then $gp
         elif $k == "gpu" or $k == "ram" then null
         elif $R == "keyboard" then "/palette/primary" else "/palette/accent" end) as $sp
      | if $k == "gpu" or $k == "ram" then
          if ($v | type) == "string" then
            ok("gradient"; {shape: {path: $rp, value: "solid"}, colour: ed_colour_field($rp; $v; $base.source; $sp; $cls; $cal)})
          elif ($v | type) == "object" and ($v.gradient | type) == "array" then
            ok("gradient"; {shape: {path: $rp, value: "gradient"},
                            stops: ed_list_field("\($rp)/gradient"; $v.gradient; $base.source;
                                                 (if $sp then "\($sp)/gradient" else null end); $cls; $cal)}
                           + (if $k == "ram" then {span: {path: "\($rp)/span", value: ($v.span // "across"), source: $base.source,
                                                 source_path: (if $sp then "\($sp)/span" else null end)}} else {} end))
          elif ($v | type) == "object" and $v.leds != null then
            ro("Per-LED list (\($v.leds | length) colours). Edit theme.json, or replace it with one colour"; {})
          else ro("OpenRGB mode \($v.mode // "?" | tostring) with its own colours. Edit theme.json, or replace it with one colour"; {}) end
        elif ($v | type) == "string" then
          ok("colour"; {colour: ed_colour_field($rp; $v; $base.source; $sp; $cls; $cal)})
        elif $v == null then ro("Nothing to show on this device"; {})
        else ro("Mode \($v.mode // "?" | tostring) with its own colours. Edit theme.json, or replace it with one colour"; {}) end
    end
  ) catch ro("This value doesn't fit the theme schema; see problems"; {});

def ed_palette($T; $cal; $classes):
  ($T.palette | objects // {}) as $p | th_palette($T) as $pal | th_dpal($pal) as $dp
  | def entry($k; $from): ($p[$k] != null) as $set | $pal[$k] as $val | $dp[$k] as $use
      | {path: "/palette/\($k)", value: $val, set: $set, from: (if $set then null else $from end), derived_use: $use,
         shows: ([$classes[] as $c | {($c): ($use | ed_show($c; $cal))}] | add // {}),
         hints: ((if $use != $val and ($use | th_hex) then
                    [{code: "led_safe", level: "info", text: "Derived lights use \($use) (made LED-safe).", fix: null}] else [] end)
                 + (reduce ($classes[] as $c | led_hints($use; $c; $cal)[]) as $h ([];
                      if any(.[]; .code == $h.code) then . else . + [$h] end)))};
  (($T.alert | objects | .color) // null) as $ac
  | {primary: entry("primary"; "default (white)"), secondary: entry("secondary"; "primary"),
     accent: entry("accent"; "mix of primary and secondary"),
     alert: {path: "/palette/alert", value: ($p.alert // $ac), set: ($p.alert != null),
             from: (if $p.alert != null then null elif $ac != null then "alert.color" else "alerts.json" end), hints: []},
     led_safe: {path: "/palette/led_safe", value: ($p.led_safe != false), set: ($p | has("led_safe"))}};

# editable: a v3 theme on a profile with managed screen roles ("theme screens"
# and "theme media" edit it); sig: ed_screens_sig, so the UI can tell whether
# its screens view is still current.
def ed_screens($T; $eff; $from; $P):
  def short: ltrimstr("screen.") | ltrimstr("model:");
  def what: if . == "custom" then "template" elif . == null then "screen" else . end;
  ($T.screens | objects // {}) as $s
  | [$s | to_entries[] | select(.key | startswith("_") | not)
     | if (.value | type) == "array" then "\(.value | length) \(.key | short) \(.value[0].type | what)s"
       else "\(.key | short) \(.value.type | what)" end] as $parts
  | {editable: (($T.v // 2) == 3 and ([screen_roles($P)[] | select(($P.roles[.] | objects | .managed) != false)] | length) > 0),
     sig: ed_screens_sig($T),
     coverage: ((try coverage_of($eff).summary catch null) // null),
     entries: ($parts | length), templates: (($T.templates | arrays // []) | length),
     summary: (if ($parts | length) == 0 then "No screen media: the screens keep what they show."
               else ($parts | join(", ")) + (if $from then " (from \($from))" else "" end) end)};

# $D  the draft (§1.1), or a stand-in for the saved theme {mode: "saved", rev: 0, ...}
# $S  {exists, sha256, theme}: the saved theme.json now
# $refs {draft: bool, active, day, night, mapped_slugs, auto, problems: [messages], preview}
def editor_view($D; $S; $P; $M; $C; $modes; $refs):
  ($P // {}) as $P | ($D.theme | objects // {}) as $T | models($M) as $MM
  | ed_calibration($T; $P; $C) as $cal
  | (try th_dpal(th_palette($T)) catch {primary: "ffffff", secondary: "ffffff", accent: "ffffff"}) as $d
  | ($T.motion | objects // {}) as $mo
  | (try compile($T; $P; $M; $C) catch null) as $eff
  | ed_view_roles($P) as $rl
  | [$rl[] | ed_role(.; $T; $P; $MM; $d; $mo; $cal)] as $roles
  | ([$roles[].class] | unique | sort_by(ed_class_rank)) as $classes
  | ($D.mode == "edit") as $edit
  | {v: 1, name: $D.name, mode: $D.mode, from: ($D.from // null), rev: ($D.rev // 0),
     draft: ($refs.draft == true),
     dirty: (if $refs.draft != true then false elif $edit then ($T != $S.theme) else true end),
     created: ($D.created // null), updated: ($D.updated // null),
     saved: {exists: ($S.exists == true), sha256: ($S.sha256 // null), active: ($refs.active == true),
             day: ($refs.day == true), night: ($refs.night == true), auto: ($refs.auto == true),
             mapped_slugs: ($refs.mapped_slugs // [])},
     base_sha256: ($D.base_sha256 // null),
     conflict: ($refs.draft == true and $edit and ($S.sha256 // null) != ($D.base_sha256 // null)),
     auto: ($refs.auto == true), machine: ($P.machine.name // null), media_root: ($D.media_root // null),
     calibration: $cal,
     about: {path: "/_about", value: ($T._about // null)},
     theme: $T,
     palette: ((try ed_palette($T; $cal; $classes) catch null) // null),
     groups: [("fans", "strimers", "rings", "peripherals") as $g
              | [$roles[] | select(.group == $g) | .role] as $rs | select(($rs | length) > 0)
              | {group: $g, kind: ($g | th_group_kind), roles: $rs, set: (($T.roles | objects // {})[$g] != null),
                 path: "/roles/\($g)", value: (($T.roles | objects // {})[$g] // null)}],
     roles: $roles,
     screens: ed_screens($T; $eff; (if $D.mode == "duplicate" then $D.from else null end); $P),
     problems: [($refs.problems // [])[] | {path: ed_problem_path($T), level: "error", message: .}],
     limits: {strimer_modes: ($modes | split(" ")), directions: ["Clockwise", "CounterClockwise"], speed: [0, 4],
              gradient_stops: {gpu: [2, 8], ram: [2, 8]}, ram_spans: ["across", "stick"], fan_list_max: 4,
              name_pattern: "^[a-z0-9][a-z0-9._-]{0,47}$"},
     preview: ($refs.preview // null)};

# ---- screens: clip lists, media and mode edits (screens plan §4.3-§4.5) --------
def ed_clip_max: 64;
# The rotation list of entry $e: [path] + clips, the folders expanded through
# $folders ({rel: [file rels]}: editor.sh lists a folder like the clip timer,
# videos only, sorted by name), repeats dropped, order kept: [{rel, from}]
# (from: path, file or folder).
def ed_clip_items($e; $folders):
  [ ($e | objects | .path | strings | {rel: ., from: "path"}),
    (($e | objects | .clips | arrays // [])[] | strings | . as $c
      | if (($folders // {}) | has($c)) then ($folders[$c][] | {rel: ., from: "folder"}) else {rel: $c, from: "file"} end) ]
  | reduce .[] as $x ([]; if any(.[]; .rel == $x.rel) then . else . + [$x] end);
# The entry with rotation list $L written back in the canonical form (plan
# §4.4): path = L[0], clips = L[1:] as files (a folder form is never written
# back); one clip left: no clips and no rotate, shuffle kept only when true.
def ed_clip_write($e; $L):
  if ($L | length) <= 1 then $e | .path = $L[0] | del(.clips, .rotate) | (if .shuffle == true then . else del(.shuffle) end)
  else $e | .path = $L[0] | .clips = $L[1:] end;
# A structural edit of rotation list $L (rels); $c: {op: add, rel, at?} |
# {op: remove, n} | {op: move, from, to} | {op: order, order: [every index once]}.
def ed_clip_edit($L; $c): ($L | length) as $n
  | def num($x; $what; $hi): if ($x | type) == "number" and $x == ($x | floor) and $x >= 0 and $x <= $hi then $x
      else error("usage: \($what) must be a clip number from 0 to \($hi)") end;
  if $c.op == "add" then
    if ($L | index($c.rel)) != null then $L
    elif $n >= ed_clip_max then error("invalid: a screen takes at most \(ed_clip_max) clips")
    else (if $c.at == null then $n else num($c.at; "--at"; $n) end) as $at | $L[:$at] + [$c.rel] + $L[$at:] end
  elif $c.op == "remove" then
    num($c.n; "the clip to remove"; $n - 1) as $i
    | if $n <= 1 then error("invalid: that is the only clip; choose other media for the screen instead") else $L[:$i] + $L[$i + 1:] end
  elif $c.op == "move" then
    num($c.from; "the clip to move"; $n - 1) as $f | num($c.to; "its new place"; $n - 1) as $t
    | ($L[:$f] + $L[$f + 1:]) as $r | $r[:$t] + [$L[$f]] + $r[$t:]
  elif $c.op == "order" then
    if ($c.order | type) != "array" or ($c.order | sort) != [range(0; $n)]
    then error("usage: order lists every clip number from 0 to \($n - 1) once") else [$c.order[] | $L[.]] end
  else error("usage: clips add|remove|move|order") end;
# theme media set's merge (plan §4.3): {type, path, model} over the current
# entry (brightness and the rest kept), template_id dropped (kept in _prev so
# the 8.8" can go back to its template); a picture ends a rotation.
def ed_media_merge($cur; $new):
  ($cur | objects // {}) as $c
  | ($c + $new | del(.template_id)
     | if $c.type == "custom" and ($c.template_id | type) == "string"
       then ._prev = ((($c._prev | objects) // {} | del(.type, .path, .clips, .rotate, .shuffle)) + {template_id: $c.template_id})
       else . end) as $e
  | if $new.type != "video" and ($e | has("clips") or has("rotate") or has("shuffle"))
    then {entry: ($e | del(.clips, .rotate, .shuffle)), notes: ["Rotation turned off: pictures can't take turns."]}
    else {entry: $e, notes: []} end;
# theme media mode (plan §4.5), on a screen with templates (the 8.8"):
# template: {type: custom, template_id} from _prev.template_id or the theme's
# only template, the media kept in _prev; media: $new, or the media kept in
# _prev, the template id kept in _prev. templates[] is never touched.
def ed_media_fields: with_entries(select(.key | IN("type", "path", "clips", "rotate", "shuffle")));
def ed_mode_entry($cur; $to; $new; $tpls):
  ($cur | objects // {}) as $c
  | if $to == "template" then
      if $c.type == "custom" then {entry: $cur, notes: ["It shows its template already."]}
      else (($c._prev | objects | .template_id) // (if ($tpls | length) == 1 then $tpls[0].id else null end)) as $tid
        | if $tid == null then error("invalid: this theme has no template for the screen (templates in theme.json)")
          else {entry: ($c | del(.path, .clips, .rotate, .shuffle) | . + {type: "custom", template_id: $tid}
                        | ._prev = ((($c._prev | objects) // {} | del(.template_id)) + ($c | ed_media_fields))
                        | if (._prev | length) == 0 then del(._prev) else . end),
                notes: []} end end
    elif $to == "media" then
      if $c.type != null and $c.type != "custom" then {entry: $cur, notes: ["It shows a picture or video already."]}
      elif $new != null then ed_media_merge($c; $new)
      elif ((($c._prev | objects | .path) // null) | type) == "string" then
        ($c._prev | ed_media_fields) as $back
        | ed_media_merge($c; {type: ($back.type // "video"), path: $back.path})
        | .entry += ($back | with_entries(select(.key | IN("clips", "rotate", "shuffle"))))
      else error("invalid: choose a picture or video for the screen first") end
    else error("usage: mode is template or media") end;
# One "theme media" verb on the draft (the input, plan §1.1 + pending_media,
# media_sources). $v (built by editor.sh): {verb: set|clips|rotate|mode|done
# (done: a job with nothing to apply ends its wait), role, expect_job (the
# job must still be the role's pending one, else "superseded"),
# src: null | {kind: none} | {kind: job|path, rel, type, model, dims, job,
# source, recipe}, all_fans, clip: {op, at, n, from, to, order}, rotate:
# <seconds>|"off"|null, shuffle: "on"|"off"|null, mode: template|media,
# folders: {rel: [rels]}, templates: [{rel, id}]}.
# -> {draft, notes, changed, cancel: [job ids to stop]}; errors start with
# their code: "usage: ", "invalid: ", "unfit: ", "no-role: ", "superseded: ".
def ed_media_edit($v; $P; $M; $now):
  . as $D | ($D.theme | objects // {v: 3}) as $T0 | models($M) as $MM | $v.role as $R
  | if ($R | type) != "string" or ($R | ed_is_screen_role($P) | not)
    then error("no-role: \($R) is not a screen role in the hardware profile") else . end
  | ($R | th_role_dev($P) // {}) as $dev | ($dev.family // null) as $fam | ($MM.lcd[$fam // ""] // {}) as $mdl
  | if $v.expect_job != null and (($D.pending_media | objects // {})[$R] // null) != $v.expect_job
    then error("superseded: \($R) waits for another job now") else . end
  | ed_screen_target($R; $T0; $P) as $tg
  | ed_src_entry(ed_screen_src($R; $T0; $P); $T0) as $cur
  | ($v.src // {kind: "none"}) as $s
  | def put($e): reduce ($tg.expand[]) as $x (.; ed_op($x)) | ed_op({op: "replace", path: $tg.path, value: $e});
    def fit_ok:
      if $s.model != null and $fam != null and (th_fits({model: $s.model}; $fam; $MM) | not) then
        error("unfit: \($s.rel) was made for \($s.model) (\($MM.lcd[$s.model].aspect // "another shape")), not for this \($mdl.aspect // "") screen")
      elif $s.model == null and ($s.dims | type) == "array" and ($mdl.media | type) == "array" and $s.dims[1] > 0
           and ((($s.dims[0] / $s.dims[1]) / ($mdl.media[0] / $mdl.media[1])) as $r | $r < 0.98 or $r > 1.02) then
        error("unfit: \($s.rel) is \($s.dims[0])x\($s.dims[1]); this screen needs the \($mdl.media[0])x\($mdl.media[1]) shape (prepare it first)")
      else . end;
    def new_media: {type: $s.type, path: $s.rel} + (if $fam then {model: $fam} else {} end);
    def fanlist($e): (.screens | objects // {}) as $sc
      | .screens = (($sc | with_entries(select(.key | test("^screen\\.fan[0-9]+$") | not)))
                    + (if $e == null then {} else {"screen.fan": [$e]} end))
      | if $e == null then del(.screens["screen.fan"]) else . end;
    def res($t; $notes): {theme: $t, notes: $notes, changed: ($t != $T0)};
  (if $v.verb == "set" then
     if $v.all_fans == true and ($R | ed_scr_kind) != "fan" then error("usage: --all-fans is for fan screens")
     elif $s.kind == "none" then
       if $v.all_fans == true then res($T0 | fanlist(null); ["No fan screen shows media from this theme now."])
       elif $tg.kind == "role" then
         ($T0 | ed_op({op: "remove", path: $tg.path})) as $t
         | res($t; (if (th_screen_entry($R; $t; $P; $MM).entry) != null then ["\($R) shows the media its screens share now."] else [] end))
       elif $tg.kind == "list" then error("invalid: \($R) takes its media from a shared list: choose media for it, or use one for every fan screen")
       elif $tg.from != null then error("invalid: \($R) shares its media with other screens: choose media for it instead")
       else res($T0; ["\($R) shows nothing from this theme already."]) end
     else fit_ok | ed_media_merge($cur; new_media) as $m
       | if $v.all_fans == true then res($T0 | fanlist($m.entry); $m.notes + ["Every fan screen shows it now."])
         else res($T0 | put($m.entry); $m.notes) end end
   elif $v.verb == "clips" then
     if $v.clip.op == "add" and ($s.type // null) != "video" then error("invalid: clips are videos; \($s.rel // "that") isn't one")
     elif $cur == null and $v.clip.op == "add" then fit_ok | res($T0 | put(ed_media_merge(null; new_media).entry); [])
     elif ($cur.type // null) != "video" then error("invalid: only a screen showing a video takes clips")
     else ([ed_clip_items($cur; $v.folders)[] | .rel]) as $L0
       | (if $v.clip.op == "add" then fit_ok else . end)
       | ed_clip_edit($L0; $v.clip + {rel: $s.rel}) as $L
       | if $L == $L0 then res($T0; (if $v.clip.op == "add" then ["That clip is in the list already."] else [] end))
         else res($T0 | put(ed_clip_write($cur; $L));
                  (if ($L | length) == 1 and ($L0 | length) > 1 then ["One clip left: it plays on its own."] else [] end)) end end
   elif $v.verb == "rotate" then
     if $cur == null then error("invalid: \($R) shows nothing from this theme yet")
     elif ($cur.type // null) != "video" then error("invalid: pictures can't take turns")
     else ($cur | (if $v.rotate == "off" then del(.rotate) elif $v.rotate != null then .rotate = $v.rotate else . end)
                | (if $v.shuffle == "on" then .shuffle = true elif $v.shuffle == "off" then del(.shuffle) else . end)) as $e
       | res(if $e == $cur then $T0 else $T0 | put($e) end;
             (if ($e.rotate != null) and ([ed_clip_items($e; $v.folders)[]] | length) < 2 then ["Add another clip to take turns."] else [] end)) end
   elif $v.verb == "mode" then
     if $mdl.templates != true then error("invalid: only a screen that takes templates (the 8.8\") has modes")
     else ed_mode_entry($cur; $v.mode; (if ($s.kind // "none") == "none" then null else (fit_ok | new_media) end); $v.templates) as $m
       | res(if $m.entry == $cur then $T0 else $T0 | put($m.entry) end; $m.notes) end
   elif $v.verb == "done" then res($T0; [])
   else error("usage: theme media set|clips|rotate|mode") end) as $r
  | ($D.pending_media | objects // {}) as $pm | ($pm[$R] // null) as $pj
  # set (and a mode switch to new media) takes the role's media over: its
  # pending job is done with, a different one is stopped; an applied job's
  # clip ends its own wait.
  | (($v.verb == "set") or ($v.verb == "done") or ($v.verb == "mode" and ($s.kind // "none") != "none")
     or ($v.verb == "clips" and $s.kind == "job" and $pj == $s.job)) as $clear
  | ($D | .theme = ($r.theme | ed_normalise)
        | (if $r.changed then .rev = ((.rev // 0) + 1) | .updated = $now else . end)
        | (if $clear and $pj != null then .pending_media = ($pm | del(.[$R])) else . end)
        | (if $s.kind == "job" and $r.changed then
             .media_sources = ((.media_sources | objects // {})
                               + {($s.rel): {source: ($s.source // null), recipe: ($s.recipe // null), model: ($s.model // null), at: $now}})
           else . end)
        | if (.pending_media | objects // {} | length) == 0 then del(.pending_media) else . end) as $nd
  | {draft: $nd, notes: $r.notes, changed: ($r.changed or ($nd.pending_media != $D.pending_media)),
     cancel: (if $clear and $pj != null and $pj != ($s.job // null) then [$pj] else [] end)};

# ---- the screens view (screens plan §1.3a) --------------------------------------
# Placement on the case map: fans.side right; fans.front and fans.rear left;
# fans.top and fans.radiator top; fans.bottom, numbered groups and fan screens
# without a group bottom; the pump and aux screens in the centre; the main
# screen at the bottom, full width. A profile role's "place" wins (detect
# never writes it).
def ed_place_rank: {top: 0, left: 1, centre: 2, right: 3, bottom: 4}[.] // 4;
def ed_group_place($g; $P): ($P.roles[$g] | objects | .place) // (
    if $g == "fans.side" then "right" elif $g == "fans.front" or $g == "fans.rear" then "left"
    elif $g == "fans.top" or $g == "fans.radiator" then "top" else "bottom" end);
# A fan screen's group: the profile's "group", else the fan role driving the
# LCD group its device belongs to.
def ed_scr_group($P): . as $R | (($P.roles[$R] | objects | .group) // null) as $g
  | if $g != null then $g
    else ((th_role_dev($P) // {}).lcd_group // null) as $lg
      | if $lg == null then null
        else first(($P.roles // {}) | to_entries[] | select((.value | objects | .device) == $lg and (.key | role_kind) == "fan") | .key) // null end end;
def ed_scr_place($P): . as $R | ed_scr_kind as $k
  | if $k == "fan" then (ed_scr_group($P) as $g | if $g then ed_group_place($g; $P) else "bottom" end)
    else (($P.roles[$R] | objects | .place) // (if $k == "main" then "bottom" else "centre" end)) end;
# {groups: [{group, label, place, axis, roles}], order: [roles in map order],
#  info: {role: {group, place, index, of}}}: top row, then the middle band
# (left column, centre, right column), then the bottom (fan rows, then the
# main screen).
def ed_screen_map($P):
  [screen_roles($P)[] | {role: ., kind: ed_scr_kind, group: (if ed_scr_kind == "fan" then ed_scr_group($P) else null end), place: ed_scr_place($P)}] as $x
  | ([$x[] | .group | strings] | reduce .[] as $g ([]; if index($g) then . else . + [$g] end)) as $gs
  | [$gs[] as $g | ed_group_place($g; $P) as $pl
     | {group: $g, label: (($P.roles[$g] | objects | .label) // null), place: $pl,
        axis: (if $pl | IN("left", "right") then "column" else "row" end), roles: [$x[] | select(.group == $g) | .role]}] as $groups
  | {groups: ($groups | sort_by([(.place | ed_place_rank), (.group as $g | $gs | index($g))])),
     order: ([$x | to_entries[] | .key as $i | .value | .group as $g
              | {role, rank: [(if .place == "top" then 0 elif (.place | IN("left", "centre", "right")) then 1 else 2 end),
                              (.place | ed_place_rank), (if .kind == "main" then 1 else 0 end),
                              (if $g then ($gs | index($g)) else 99 end), $i]}]
             | sort_by(.rank) | map(.role)),
     info: ([$x[] | .role as $R | .group as $g | ([$groups[] | select(.group == $g) | .roles][0] // null) as $in
             | {($R): {group: $g, place, index: (if $in then ($in | index($R)) else null end), of: (if $in then ($in | length) else null end)}}]
            | add // {})};
def ed_scr_short($P; $MM): . as $R | ed_scr_kind as $k
  | if $k == "fan" then "Fan \($R | ltrimstr("screen.fan"))" elif $k == "pump" then "Pump"
    elif $k == "main" then
      (((($MM.lcd[$R | ed_scr_fam($P)] // {}).label) // ($P.roles[$R] | objects | .label) // "")
       | [match("[0-9]+(\\.[0-9]+)?\""; "g").string] | first // null) as $d
      | if $d then "\($d) screen" else "Main screen" end
    else "Screen \($R | ltrimstr("screen.aux"))" end;
def ed_mmss: floor as $s | "\($s / 60 | floor):\($s % 60 | tostring | if length < 2 then "0" + . else . end)";
def ed_file($rel; $X): (($X.files // {})[$rel // ""] // {where: "missing", abs: null});
def ed_probe_view: if type != "object" or (.error // null) != null then null
  else {kind: (.kind // null), w: (.dw // .w // null), h: (.dh // .h // null), duration: (.duration // null),
        fps: (.fps // null), bytes: (.size // .bytes // null)} end;
def ed_media_view($type; $rel; $X; $tgt):
  ed_file($rel; $X) as $f | ($f.probe // null) as $pr
  | {type: $type, rel: $rel, where: $f.where, abs: ($f.abs // null), title: ($rel | media_title),
     thumb: ($f.thumb // null), thumb_state: ($f.thumb_state // "none"),
     probe: ($pr | ed_probe_view),
     fit: (if ($pr | ed_probe_view) == null then {state: "unknown", keep: null, scale: null, score: null, note: null}
           else media_fit($pr; $tgt) end)};
def ed_media_problems($m; $tgt; $f):
  [ (if $m.where == "missing" then {code: "missing", level: "error", text: "The file is missing: \($m.rel)"} else empty end),
    (if (($f.probe | objects | .error) // null) != null then {code: "broken", level: "warn", text: "It isn't a picture or video this PC can read"} else empty end),
    (if ($m.fit.state | IN("cropped", "poor")) then {code: "unfit-media", level: "warn", text: "Made for another shape: the screen stretches it"} else empty end),
    (if ($m.probe.duration // 0) > ($tgt.max_s // 1e9) then {code: "long", level: "warn", text: "Longer than this screen takes (\($tgt.max_s | ed_mmss))"} else empty end),
    (if $m.fit.note == "low-res" then {code: "low-res", level: "warn", text: "Low resolution; it may look soft"} else empty end),
    (($m.probe.bytes // $f.bytes // 0) as $b | if $b > 500000000 then {code: "huge", level: "warn", text: "A very large file (\($b / 1000000 | floor) MB)"} else empty end) ];
def ed_template_view($e; $mdl; $X):
  ((($e | objects | .template_id) // null) // (($e | objects | ._prev | objects | .template_id) // null)
   // (if $mdl.templates == true and (($X.templates // []) | length) == 1 then $X.templates[0].id else null end)) as $tid
  | if $tid == null or ((($e | objects | .type) // null) != "custom" and $mdl.templates != true) then null
    else (first(($X.templates // [])[] | select(.id == $tid)) // null) as $tf
      | {id: $tid, rel: ($tf.rel // null), installed: ((($X.installed // []) | index($tid)) != null),
         thumb: ($X.preview_us88 // ($tf.thumb // null))} end;
def ed_scr_cmp: with_entries(select(.key | IN("type", "path", "template_id", "orientation", "brightness", "clips", "rotate", "shuffle")) | select(.value != null));
def ed_scr_out($R; $T; $P; $MM): th_screen_entry($R; $T; $P; $MM).entry | if . then th_screen_out($R; .; $P; $MM) | ed_scr_cmp else null end;
# Whether what compile sends for $R differs from the base theme's (the saved
# theme, the one a duplicate came from; a v2 base: its entry for the serial).
def ed_scr_changed($R; $T; $B; $P; $MM):
  ed_scr_out($R; $T; $P; $MM) as $a
  | (if ($B | type) != "object" then null
     elif ($B.v // 2) == 3 then ed_scr_out($R; $B; $P; $MM)
     else (($R | th_role_dev($P)) // {}) as $dv | ($dv.match.usb_serial // ($dv._key // "" | ltrimstr("lianli:lcd:"))) as $ser
       | (first(($B.screens | arrays // [])[] | objects | select(.serial == $ser)) // null) | if . then ed_scr_cmp else null end end) as $b
  | $a != $b;
def ed_scr_row($R; $T; $P; $MM; $X; $info):
  ($R | th_role_dev($P)) as $dev | ($dev.family // null) as $fam | ($MM.lcd[$fam // ""] // {}) as $mdl
  | ($P.roles[$R] | objects // {}) as $pr | ($pr.managed != false) as $mg | ($R | ed_scr_kind) as $k
  | ($info[$R] // {group: null, place: null, index: null, of: null}) as $mi
  | (if $mg then th_screen_entry($R; $T; $P; $MM) else {entry: null, source: "unmanaged"} end) as $x
  | $x.entry as $e
  # the target media_fit takes (media.jq's media_target shape)
  | {role: $R, model: $fam, aspect: ($mdl.aspect // null), w: (($mdl.media // [])[0] // null), h: (($mdl.media // [])[1] // null),
     max_s: (($mdl.prep | objects | .max_s) // (if $k == "main" or $k == "aux" then 180 else 120 end))} as $tgt
  | (if (($e | objects | .type) // null) | IN("image", "video", "gif") then ed_media_view($e.type; $e.path; $X; $tgt) else null end) as $media
  | ed_template_view($e; $mdl; $X) as $tv
  | (if (($e | objects | .type) // null) == "video" and ($e | has("clips")) then
       {rotate: ($e.rotate // null), shuffle: ($e.shuffle == true),
        folder_form: any(($e.clips | arrays // [])[] | strings; . as $c | ($X.folders // {}) | has($c)),
        max: ed_clip_max,
        items: [ed_clip_items($e; $X.folders) | to_entries[] | .key as $i | .value as $c | ed_file($c.rel; $X) as $f
                | {i: $i, rel: $c.rel, from: $c.from, where: $f.where, title: ($c.rel | media_title),
                   thumb: ($f.thumb // null), thumb_state: ($f.thumb_state // "none"),
                   duration: (($f.probe | objects | .duration) // null)}]}
     else null end) as $clips
  | {role: $R, short: ($R | ed_scr_short($P; $MM)), label: ($pr.label // null), kind: $k,
     group: $mi.group, place: $mi.place, wide: ($k == "main"), index: $mi.index, of: $mi.of,
     device: ($dev._key // null), present: (if $dev then $dev.present != false else false end), managed: $mg,
     model: $fam, shape: ($mdl.aspect // null), media_size: ($mdl.media // null),
     orientation: ((($e | objects | .orientation) // null) // ((($mdl.orientation // 0) + ($pr.mount // 0)) % 360)),
     source: $x.source, unfit: ($x.unfit // null),
     target: (if $mg then ed_screen_target($R; $T; $P) | del(.from) else null end),
     shared_with: (if $mg then ed_shared_with($R; $T; $P) else [] end),
     changed: (if $mg then ed_scr_changed($R; $T; $X.base; $P; $MM) else false end),
     entry: $e, media: $media,
     brightness: (if $e then {path: "/screens/@\($R)/brightness", value: ($e.brightness // null), effective: ($e.brightness // 100)} else null end),
     clips: $clips, template: $tv,
     modes: (if $mdl.templates == true then
               {current: (if $e == null then null elif $e.type == "custom" then "template" else "media" end),
                can: ((if $tv != null then ["template"] else [] end) + ["media"])}
             else null end),
     pending: (($X.pending // {})[$R] // null),
     problems: [ (if $media then ed_media_problems($media; $tgt; ed_file($e.path; $X))[] else empty end),
                 (($clips // {}).items // [] | .[1:][] | select(.where == "missing")
                  | {code: "missing", level: "error", text: "The clip is missing: \(.rel)"}),
                 (if (($e | objects | .type) // null) == "custom" and ($tv == null or ($tv.rel == null and ($tv.installed | not))) then
                    {code: "template-missing", level: "warn", text: "The theme has no template \($e.template_id // "")"} else empty end),
                 (if $x.unfit then {code: "unfit", level: "warn", text: "Its media was made for \($x.unfit): this screen keeps what it shows"} else empty end) ]};
# $D: the draft (or a stand-in for the saved theme); $X: what editor.sh read
# from the disk: {draft, stage, files: {rel: {where, abs, bytes, probe, thumb,
# thumb_state}}, folders: {rel: [rels]}, templates: [{rel, id, thumb}],
# installed: [template ids], preview_us88, pending: {role: {job, state,
# progress, then, error}}, base: <theme>|null, disk: {stage_bytes,
# free_bytes, cap}}.
def ed_screens_view($D; $P; $M; $C; $X; $modes):
  ($P // {}) as $P | ($D.theme | objects // {}) as $T | models($M) as $MM
  | ed_screen_map($P) as $map
  | (try coverage_of(compile($T; $P; $M; $C)) catch null) as $cov
  | ($X.disk // {}) as $dk
  | {v: 1, name: $D.name, rev: ($D.rev // 0), draft: ($X.draft == true), mode: ($D.mode // null), sig: ed_screens_sig($T),
     editable: (($T.v // 2) == 3 and ([screen_roles($P)[] | select(($P.roles[.] | objects | .managed) != false)] | length) > 0),
     media_root: ($D.media_root // null), stage: ($X.stage // null),
     map: {groups: $map.groups, order: $map.order},
     screens: [screen_roles($P)[] as $R | ed_scr_row($R; $T; $P; $MM; $X; $map.info)],
     coverage: {summary: ($cov.summary // null), missing: ($cov.missing // [])},
     disk: {stage_bytes: ($dk.stage_bytes // 0), free_bytes: ($dk.free_bytes // null),
            warn: (if ($dk.free_bytes // 1e18) < 1073741824 then "low-space"
                   elif ($dk.stage_bytes // 0) >= ($dk.cap // 4294967296) then "stage-full"
                   elif ($dk.stage_bytes // 0) >= 0.8 * ($dk.cap // 4294967296) then "stage-near-full"
                   else null end)},
     limits: {brightness: [0, 100], rotate: [30, 86400], rotate_choices: [60, 300, 900, 3600], clips_max: ed_clip_max},
     problems: [($T | try v3_problems($modes) catch "the theme can't be read") | select(test("^(screens|templates)"))
                | {path: ed_problem_path($T), level: "error", message: .}]};
