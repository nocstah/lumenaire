# lib/pc-lights/migrate.sh — v2 -> v3 theme migration (plan §6)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP5 (migrate)
# Public: migrate_cmd; jq defs MIG_JQ (v2 -> v3, the identity projection)
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154
# (and SC2016 file-wide: the single-quoted $x are jq's, not the shell's)
# shellcheck disable=SC2016

# pc-lights migrate [--dry-run] [--only name...] [--rollback] [--verify-render] [--out DIR]
#
# Turns every v2 theme (fans.top/bottom, screens[] by USB serial with a
# per-screen orientation) into v3 (palette, roles, screens by role; plan §4),
# after seeding the profile with what the v2 themes know about this case:
# each screen's mount rotation and label, and the board's ARGB header
# layout. A theme is only written when compile(v3) gives back exactly the v2
# theme (the identity check below); the rest are reported and left alone.
#
#   --dry-run        check everything and print the diffs; write nothing
#   --only a b ...   just these themes (names up to the next --option)
#   --rollback       put theme.json and src/source.json back from the backup
#   --verify-render  run tests/golden/run.sh on the result (a repo checkout)
#   --out DIR        migrate a copy: THEME_DIR is copied to DIR (reflinked
#                    where the filesystem can) and migrated there; the seeded
#                    profile goes to DIR/profile.json, the real one and the
#                    real themes are not touched (golden stage c, plan §7)
#
# Writes (never in place: tmp + mv, so a hard-linked backup keeps the old
# bytes): the profile (only when seeding changed it), each theme.json, and
# src/source.json's theme_json_sha256 where it matched the old file (so
# auto-theme still recognises its own output, plan risk 7). The backup is
# $STATE_DIR/themes.pre-v3-<date>/ beside THEME_DIR (cp -al once a day,
# outside THEME_DIR so "themes" never lists it), with .migrate.json listing
# each theme's v2/v3 sha256; --rollback restores from the newest record of
# each theme, byte-exact, and only when the file is still what migrate wrote.
# A second run finds only v3 themes and does nothing.

# The screen models migrate needs (a fallback until lib/pc-lights/models.json
# from detect is there): the orientation that a model's own media needs on
# its panel. mount = v2 orientation - this, mod 360.
MIG_MODELS_BUILTIN='{
  "TlFlexLcd": {"aspect": "square", "media": [400, 400], "orientation": 0},
  "TlLcd": {"aspect": "square", "media": [400, 400], "orientation": 0},
  "Tlv2Lcd": {"aspect": "square", "media": [400, 400], "orientation": 0},
  "SlInfFlexLcd": {"aspect": "square", "media": [400, 400], "orientation": 0},
  "HydroShift2OledCurveLcd": {"aspect": "wide-curve", "media": [2288, 1080], "orientation": 90},
  "UniversalScreen": {"aspect": "strip", "media": [1920, 480], "orientation": 90},
  "HydroShiftLcd": {"aspect": "round", "media": [480, 480], "orientation": 0},
  "Galahad2Lcd": {"aspect": "round", "media": [480, 480], "orientation": 0}
}'

# The jq defs every step shares. $P = profile, $M = models (models.json as
# detect writes it, or MIG_MODELS_BUILTIN), $B = the builtin table.
MIG_JQ='
  def model($f): ($M[$f]? // $M.lcd[$f]? // $M.models[$f]? // $B[$f] // {orientation: 0});
  def mod360: ((. % 360) + 360) % 360;
  # The profile screen roles in compile order: screen.fan1..n, screen.pump,
  # screen.main, screen.aux1..n. Each: {role, key, serial, family, mount,
  # label, present, fan (0-based index among the fan screens, or null)}.
  def screen_roles($P):
    [ ($P.roles // {}) | to_entries[]
      | select(.key | test("^screen\\.(fan[0-9]+|pump|main|aux[0-9]+)$"))
      | .key as $r | .value as $b | ($P.devices[$b.device // ""] // {}) as $d
      | {role: $r, key: ($b.device // null),
         serial: ($d.match.usb_serial // (($b.device // "") | if startswith("lianli:lcd:") then ltrimstr("lianli:lcd:") else null end)),
         family: ($d.family // null), mount: ($b.mount // 0), label: ($b.label // null),
         present: ($d.present != false), source: ($b.source // null),
         sort: ($r | if startswith("screen.fan") then [0, (ltrimstr("screen.fan") | tonumber)]
                     elif . == "screen.pump" then [1, 0] elif . == "screen.main" then [2, 0]
                     else [3, (ltrimstr("screen.aux") | tonumber)] end)} ]
    | sort_by(.sort)
    | (map(select(.role | startswith("screen.fan"))) | map(.role)) as $fans
    | map(. + {fan: (.role as $r | $fans | index($r))} | del(.sort));
  def serial_map($P): screen_roles($P) | map(select(.serial != null) | {(.serial): .}) | add // {};
  # What compile derives for a screen with no explicit orientation.
  def derived_orientation: (model(.family).orientation + (.mount // 0)) | mod360;
  def first_hex: if type == "array" then .[0] else . end;
  def mode: map(select(. != null)) | if length == 0 then null else group_by(tojson) | max_by(length) | .[0] end;
  def v2_keys: ["fans", "strimers", "rings", "gpu", "board", "ram", "alert", "screens", "templates", "v"];

  # ---- the identity projection (plan §6 step 4) ----
  # The keys the builders read: lighting (minus "_" notes), alert,
  # templates, and the screens as serial -> the fields that reach .lcds.
  def lit: if type == "object" then with_entries(select(.key | startswith("_") | not) | .value |= lit)
           elif type == "array" then map(lit) else . end;
  def proj:
    { fans: (.fans | lit), strimers: (.strimers | lit), rings: (.rings | lit), gpu: (.gpu | lit),
      board: (.board | lit), ram: (.ram | lit), alert: .alert, templates: .templates,
      screens: ((.screens // []) | map({key: .serial, value: ({type, path, orientation, template_id, brightness,
                  clips, rotate, shuffle, _where} | with_entries(select(.value != null)))}) | from_entries) };

  # ---- v2 -> v3 (plan §4, §6 step 3) ----
  def to_v3($P; $machine):
    . as $t | serial_map($P) as $sm | screen_roles($P) as $sr
    | def conv($s): del(.serial)
        | if $s.label != null and ._where == $s.label then del(._where) else . end
        | if .orientation != null and .orientation == ($s | derived_orientation) then del(.orientation) else . end
        | . + (if $s.family then {model: $s.family} else {} end);
      ($t.screens // [] | map(select(type == "object")) | map({key: .serial, value: .}) | from_entries) as $by
    | ($sr | map(select(.fan != null))) as $fr
    | (($fr | length) > 0 and all($fr[]; .serial as $x | $by[$x] != null)) as $list
    | {v: 3}
      + ($t | with_entries(select(.key | startswith("_"))))
      + {led: (($t.led // {}) + {calibrated_for: $machine})}
      + {palette: ({primary: ($t.fans.top | first_hex), secondary: ($t.fans.bottom | first_hex),
                    accent: $t.rings, alert: ($t.alert.color? // null)} | with_entries(select(.value != null)))}
      + {roles: ($t | with_entries(select(.key | IN("fans", "strimers", "rings", "gpu", "board", "ram")))
                 | if (.fans | type) == "object"
                   then .fans |= with_entries(.key |= ({top: "inner", bottom: "outer"}[.] // .)) else . end)}
      + (if $t | has("alert") then {alert: $t.alert} else {} end)
      + (if $t | has("screens") then
          {screens: (
            (if $list then {"screen.fan": [$fr[] | . as $s | $by[$s.serial] | conv($s)]} else {} end)
            + ([ $sr[] | select(($list | not) or .fan == null) | . as $s | select($s.serial != null and $by[$s.serial] != null)
                 | {($s.role): ($by[$s.serial] | conv($s))} ] | add // {}))}
        else {} end)
      + (if $t | has("templates") then {templates: $t.templates} else {} end)
      + ($t | with_entries(select((.key | startswith("_") | not) and (.key | IN(v2_keys[]) | not)))) ;

  # ---- stand-in compile (until theme.jq compile() is there) ----
  # Enough of plan §5 for a migrated theme: the roles back to the v2 group
  # keys, and the screens resolved in profile role order. No palette
  # derivation and no calibration: migrate writes every key and stamps
  # calibrated_for.
  def stub_compile($P):
    if (.v // 2) != 3 then . else
      . as $t | ($t.roles // {}) as $r | ($t.screens // {}) as $sc
      | ($r | with_entries(select(.key | IN("fans", "strimers", "rings", "gpu", "board", "ram")))
         | if (.fans | type) == "object" then .fans |= with_entries(.key |= ({inner: "top", outer: "bottom"}[.] // .)) else . end)
      + (if $t.alert then {alert: $t.alert} elif $t.palette.alert then {alert: {color: $t.palette.alert}} else {} end)
      + (if $t | has("screens") then
          {screens: [ screen_roles($P)[] | . as $s
            | ($sc[$s.role] // (if $s.fan != null then ($sc["screen.fan"] | arrays | select(length > 0) | .[$s.fan % length]) else null end)
               // $sc["model:" + ($s.family // "")]) as $e
            | select($e != null and ($e.model == null or model($e.model).aspect == model($s.family).aspect))
            | {serial: $s.serial, _where: ($e._where // $s.label), type: $e.type} + ($e | {path} | with_entries(select(.value != null)))
              + {orientation: ($e.orientation // ($s | derived_orientation))}
              + ($e | {template_id, brightness, clips, rotate, shuffle} | with_entries(select(.value != null))) ]}
        else {} end)
      + (if $t | has("templates") then {templates: $t.templates} else {} end)
      + ($t | with_entries(select(.key | startswith("_"))))
    end;
'

mig_profile() { echo "${PROFILE:-$STATE_DIR/profile.json}"; }

# The models table: models.json from detect (WP2) when it is there.
mig_models() {
  local m=${PCL_MODELS:-$PCL_LIB/models.json}
  if [[ -f $m ]] && jq -e 'type == "object"' "$m" >/dev/null 2>&1; then cat "$m"; else echo "$MIG_MODELS_BUILTIN"; fi
}

# jq with the shared defs' globals: $M the models table (mig_models, read
# once per run into MIG_M), $B the builtin one.
MIG_M=
mjq() { jq --argjson M "${MIG_M:-"{}"}" --argjson B "$MIG_MODELS_BUILTIN" "$@"; }

# The compile the identity check runs: the engine's own (theme.sh's
# theme_jq with theme.jq's compile($T; $P; $M; $C), the call theme_eff
# makes) against the seeded profile, when theme.jq is there and loads;
# otherwise the stand-in above. MIG_COMPILER says which, for the report.
MIG_COMPILER=
mig_pick_compiler() {
  [[ -z $MIG_COMPILER ]] || return 0
  MIG_COMPILER=stand-in
  if [[ -f $PCL_LIB/theme.jq ]] && [[ $(type -t theme_jq) == function ]] &&
    PROFILE=/dev/null theme_jq 'compile({v: 2}; {}; $M; $C) | true' >/dev/null 2>&1; then
    MIG_COMPILER=theme.jq
  fi
}

# mig_compile <theme.json> <profile> -> the compiled theme (EFF) on stdout
mig_compile() {
  if [[ $MIG_COMPILER == theme.jq ]]; then
    PROFILE=$2 theme_jq --slurpfile t "$1" 'compile($t[0]; $P; $M; $C)'
  else
    mjq --slurpfile p "$2" "$MIG_JQ"'stub_compile($p[0])' "$1"
  fi
}

# The newest backup record per theme: "<name>\t<backup dir>\t<record json>".
mig_records() {
  local bk
  for bk in "$(dirname "$THEME_DIR")"/themes.pre-v3-*/; do
    bk=${bk%/}
    [[ -f $bk/.migrate.json ]] || continue
    jq -r --arg bk "$bk" '.themes // {} | to_entries[] | [.key, $bk, (.value | tojson)] | @tsv' "$bk/.migrate.json" 2>/dev/null || true
  done | sort -t$'\t' -k1,1 -k2,2r | sort -s -u -t$'\t' -k1,1
}

# mig_install <src> <dest>: dest gets src's bytes as a new inode (tmp + mv),
# keeping dest's mode (or src's when dest is new).
mig_install() {
  local tmp=$2.migrate.$$.tmp
  cp -p "$1" "$tmp"
  if [[ -e $2 ]]; then chmod --reference="$2" "$tmp"; fi
  mv -f "$tmp" "$2"
}

migrate_rollback() {
  local only=("$@") name bk rec cur want f back n=0 kept=0
  local -A sel=()
  for name in "${only[@]}"; do sel[$name]=1; done
  take_lock
  while IFS=$'\t' read -r name bk rec; do
    [[ -n $name ]] || continue
    if (( ${#only[@]} )) && [[ -z ${sel[$name]:-} ]]; then continue; fi
    f=$THEME_DIR/$name/theme.json back=$bk/$name/theme.json
    [[ -f $back ]] || { log "rollback $name: no $back"; kept=$((kept + 1)); continue; }
    cur=$(sha256sum <"$f" 2>/dev/null | cut -d' ' -f1 || true)
    want=$(jq -r .v3 <<<"$rec")
    if [[ $cur == "$(jq -r .v2 <<<"$rec")" ]]; then
      echo "$name: already v2"
    elif [[ $cur == "$want" ]]; then
      mig_install "$back" "$f"
      echo "$name: theme.json restored from $bk"
      n=$((n + 1))
    else
      log "rollback $name: theme.json changed since migrate; left alone (the v2 file is $back)"
      kept=$((kept + 1)); continue
    fi
    # source.json, only while it is still the one migrate wrote.
    if [[ $(jq -r '.source // empty' <<<"$rec") != "" ]]; then
      f=$THEME_DIR/$name/src/source.json back=$bk/$name/src/source.json
      cur=$(sha256sum <"$f" 2>/dev/null | cut -d' ' -f1 || true)
      if [[ $cur == "$(jq -r .source.v3 <<<"$rec")" && -f $back ]]; then
        mig_install "$back" "$f"; echo "$name: src/source.json restored"
      elif [[ $cur != "$(jq -r .source.v2 <<<"$rec")" ]]; then
        log "rollback $name: src/source.json changed since migrate; left alone"
      fi
    fi
  done < <(mig_records)
  (( n + kept )) || echo "nothing to roll back"
  echo "rolled back $n theme(s); the profile keeps its seeded screen roles (the v2 engine ignores them)"
  (( kept == 0 )) || die "$kept theme(s) not rolled back (see above)"
}

migrate_cmd() {
  local dry='' rollback='' verify='' out='' only=() names=() v2=() name f pf models w
  while (( $# )); do
    case $1 in
      --dry-run) dry=1 ;;
      --rollback) rollback=1 ;;
      --verify-render) verify=1 ;;
      --out) [[ -n ${2:-} ]] || die "migrate: --out needs a directory"; out=$2; shift ;;
      --only)
        shift
        while (( $# )) && [[ $1 != --* ]]; do only+=("$1"); shift; done
        (( ${#only[@]} )) || die "migrate: --only needs theme names"
        continue ;;
      *) die "usage: pc-lights migrate [--dry-run] [--only name...] [--rollback] [--verify-render] [--out DIR]" ;;
    esac
    shift
  done
  for name in "${only[@]}"; do theme_exists "$name" || die "no theme $THEME_DIR/$name/theme.json"; done
  if [[ -n $rollback ]]; then
    [[ -z $dry$out$verify ]] || die "migrate: --rollback takes only --only"
    migrate_rollback "${only[@]}"; return
  fi

  pf=$(mig_profile)
  [[ -f $pf ]] || die "no hardware profile at $pf; run 'pc-lights detect' first"
  jq -e '(.roles | type == "object") and (.machine.name | type == "string" and length > 0)' "$pf" >/dev/null 2>&1 ||
    die "$pf is not a usable profile (no roles or machine.name); run 'pc-lights detect'"

  # --out: a reflinked copy of the whole theme dir (media paths stay inside
  # each theme folder), migrated there against a copy of the profile.
  if [[ -n $out ]]; then
    [[ ! -e $out || -z $(ls -A "$out" 2>/dev/null) ]] || die "migrate: $out is not empty"
    mkdir -p "$out"; out=$(readlink -f "$out")
    cp -a --reflink=auto "$THEME_DIR/." "$out/"
    THEME_DIR=$out
    cp "$pf" "$out/profile.json"; pf=$out/profile.json
  fi

  # Which themes: --only, or every folder with a theme.json. v3 ones are done.
  if (( ${#only[@]} )); then names=("${only[@]}"); else
    for f in "$THEME_DIR"/*/theme.json; do [[ -f $f ]] && { f=${f%/theme.json}; names+=("${f##*/}"); }; done
  fi
  local w3=0
  for name in "${names[@]}"; do
    f=$THEME_DIR/$name/theme.json
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not valid JSON; fix it first"
    if [[ $(jq -r '.v // 2' "$f") == 3 ]]; then w3=$((w3 + 1)); else v2+=("$name"); fi
  done
  if (( ${#v2[@]} == 0 )); then
    echo "nothing to migrate ($w3 theme(s) already v3)"
    if [[ -n $verify ]]; then migrate_verify "$pf"; fi
    return 0
  fi

  w=$TMP/migrate; mkdir -p "$w"
  mig_models >"$w/models.json"; models=$w/models.json
  MIG_M=$(jq -c . "$models")
  for name in "${v2[@]}"; do cat "$THEME_DIR/$name/theme.json"; done | jq -s . >"$w/v2.json"
  printf '%s\n' "${v2[@]}" | jq -R . | jq -s . >"$w/names.json"

  # ---- 1+2: refuse, then seed the profile (source "migrate") ----------------
  # Every serial in the themes must be a screen role in the profile, present
  # (fan LCDs drop off USB after a shutdown: a detect then misses them).
  # Mount and label per role come from the orientation and _where most themes
  # agree on; roles the user or an earlier migrate set are left alone.
  mjq --slurpfile p "$pf" --slurpfile n "$w/names.json" --arg board "${BOARD:-}" "$MIG_JQ"'
    $p[0] as $P | serial_map($P) as $sm
    | [ to_entries[] | .key as $i | .value.screens // [] | .[] | objects
        | select(.serial | type == "string")
        | {s: .serial, o: .orientation, w: ._where, theme: $n[0][$i]} ] as $all
    | ($all | group_by(.s) | map({s: .[0].s, o: (map(.o) | mode), w: (map(.w) | mode), themes: (map(.theme) | unique)})) as $per
    | { problems: [ $per[] | select($sm[.s] == null)
                    | "screen \(.s) (\(.w // "?")) in \(.themes | join(", ")) is not a screen role in the profile" ],
        offline: [ $per[] | select($sm[.s] != null and $sm[.s].present == false)
                   | "\($sm[.s].role) (\(.s), \($sm[.s].family // "?")) is marked absent in the profile" ],
        profile: (reduce ($per[] | select($sm[.s] != null)) as $x ($P;
                    $sm[$x.s] as $s
                    | if ($s.source | IN("user", "migrate")) then . else
                        .roles[$s.role] |= (. + (if $x.o != null then {mount: ((($x.o - model($s.family).orientation)) | mod360)} else {} end)
                                              + (if $x.w != null then {label: $x.w} else {} end)
                                              + {source: "migrate", confidence: "sure"})
                      end)
                  | (.roles.board.device // null) as $bd
                  | if $bd != null and $board != "" and ($P.devices[$bd].name // $P.devices[$bd].match.name // "") == $board
                       and ((.roles["board.argb"].source // "") | IN("user", "migrate") | not)
                    then .roles["board.argb"] = ((.roles["board.argb"] // {}) + {device: $bd, argb: {zones: [0, 1, 2, 3], size: 120},
                                                 source: "migrate", confidence: "sure"})
                    else . end) }' "$w/v2.json" >"$w/seed.json" || die "migrate: could not read the themes and the profile"
  if [[ -n $(jq -r '.problems[], .offline[]' "$w/seed.json") ]]; then
    jq -r '.problems[], .offline[] | "  " + .' "$w/seed.json" >&2
    die "migrate: the profile doesn't cover the themes' screens (fan LCDs off USB during detect?); wake the screens, run 'pc-lights detect', then migrate again. Nothing changed."
  fi
  # And they must be on USB now: the same check, against sysfs.
  local usbm missing
  usbm=$(usb_serial_map)
  missing=$(jq -r --slurpfile u "$usbm" '[.[] | .screens // [] | .[] | objects | .serial] | unique[] | select($u[0][.] == null)' "$w/v2.json")
  if [[ -n $missing ]]; then
    local m; for m in $missing; do echo "  off USB: $m" >&2; done
    die "migrate: $(wc -l <<<"$missing") screen(s) are off USB (the fan LCDs sleep after a shutdown); wake them and run migrate again. Nothing changed."
  fi
  jq '.profile' "$w/seed.json" >"$w/profile.json"
  mig_pick_compiler
  # The stand-in only proves the conversion; the engine applies v3 themes with
  # theme.jq, so writing v3 files it can't load would leave nothing applicable.
  if [[ -z $dry && $MIG_COMPILER != theme.jq ]]; then
    die "migrate: $PCL_LIB/theme.jq does not load, so the engine could not apply v3 themes; nothing changed"
  fi

  # ---- 3+4: build each v3 theme, and prove it compiles back ------------------
  local machine ok=() bad=() rc
  machine=$(jq -r .machine.name "$w/profile.json")
  for name in "${v2[@]}"; do
    f=$THEME_DIR/$name/theme.json
    mjq --slurpfile p "$w/profile.json" --arg machine "$machine" "$MIG_JQ"'to_v3($p[0]; $machine)' "$f" >"$w/$name.v3.json" ||
      die "migrate: could not convert $name"
    rc=0
    mig_compile "$w/$name.v3.json" "$w/profile.json" >"$w/$name.eff.json" 2>"$w/$name.eff.err" || rc=$?
    mjq -S "$MIG_JQ"'proj' "$f" >"$w/$name.want" || die "migrate: could not read $f"
    if (( rc == 0 )) && mjq -S "$MIG_JQ"'proj' "$w/$name.eff.json" >"$w/$name.got" 2>/dev/null &&
       cmp -s "$w/$name.want" "$w/$name.got"; then
      ok+=("$name")
    else
      bad+=("$name")
      echo "$name: identity check FAILED (compile: $MIG_COMPILER); not migrated" >&2
      if (( rc )); then sed 's/^/  /' "$w/$name.eff.err" >&2; else diff -u "$w/$name.want" "$w/$name.got" | sed -n '3,40s/^/  /p' >&2 || true; fi
    fi
  done

  # ---- dry run: diffs only ----------------------------------------------------
  if [[ -n $dry ]]; then
    if ! cmp -s <(jq -S . "$pf") <(jq -S . "$w/profile.json"); then
      echo "--- profile $pf"
      diff -u --label "$pf" --label "$pf (seeded)" <(jq . "$pf") <(jq . "$w/profile.json") || true
    fi
    for name in "${ok[@]}"; do
      diff -u --label "$name/theme.json (v2)" --label "$name/theme.json (v3)" "$THEME_DIR/$name/theme.json" "$w/$name.v3.json" || true
    done
    echo "dry run: ${#ok[@]} theme(s) would migrate, ${#bad[@]} failed the identity check, $w3 already v3 (compile: $MIG_COMPILER)"
    (( ${#bad[@]} == 0 )) || die "identity check failed for: ${bad[*]}"
    return 0
  fi
  (( ${#ok[@]} )) || die "identity check failed for every theme (${bad[*]}); nothing changed"

  # ---- 5: write ---------------------------------------------------------------
  [[ -n $out ]] || take_lock
  local bk='' old new src sold snew rec='{}'
  if [[ -z $out ]]; then
    bk=$(dirname "$THEME_DIR")/themes.pre-v3-$(date +%F)
    if [[ ! -d $bk ]]; then
      rm -rf "$bk.tmp.$$"
      cp -al "$THEME_DIR" "$bk.tmp.$$" 2>/dev/null || { rm -rf "$bk.tmp.$$"; cp -a --reflink=auto "$THEME_DIR" "$bk.tmp.$$"; }
      mv -T "$bk.tmp.$$" "$bk"
    fi
    # A backup from earlier today may predate an edit: it must hold these bytes.
    for name in "${ok[@]}"; do
      if [[ ! -d $bk/$name ]]; then
        cp -al "$THEME_DIR/$name" "$bk/$name" 2>/dev/null || cp -a --reflink=auto "$THEME_DIR/$name" "$bk/$name"
      fi
      for f in theme.json src/source.json; do
        [[ -f $THEME_DIR/$name/$f ]] || continue
        if ! cmp -s "$THEME_DIR/$name/$f" "$bk/$name/$f"; then
          mkdir -p "$(dirname "$bk/$name/$f")"; rm -f "$bk/$name/$f"; cp -p "$THEME_DIR/$name/$f" "$bk/$name/$f"
        fi
      done
    done
    if [[ -f $bk/.migrate.json ]]; then rec=$(cat "$bk/.migrate.json"); fi
  fi
  if ! cmp -s <(jq -S . "$pf") <(jq -S . "$w/profile.json"); then
    mig_install "$w/profile.json" "$pf"
    echo "profile: seeded screen mounts/labels and board.argb ($pf)"
  fi
  for name in "${ok[@]}"; do
    f=$THEME_DIR/$name/theme.json src=$THEME_DIR/$name/src/source.json
    old=$(sha256sum <"$f" | cut -d' ' -f1)
    new=$(sha256sum <"$w/$name.v3.json" | cut -d' ' -f1)
    sold='' snew=''
    # auto-theme's hash: it regenerates a theme only while theme.json is its own output.
    if [[ -f $src && $(jq -r '.theme_json_sha256 // empty' "$src" 2>/dev/null) == "$old" ]]; then
      sold=$(sha256sum <"$src" | cut -d' ' -f1)
      sed -E "s/(\"theme_json_sha256\"[[:space:]]*:[[:space:]]*\")$old\"/\1$new\"/" "$src" >"$w/$name.source.json"
      if [[ $(jq -r .theme_json_sha256 "$w/$name.source.json" 2>/dev/null) != "$new" ]]; then
        jq --arg h "$new" '.theme_json_sha256 = $h' "$src" >"$w/$name.source.json"
      fi
      snew=$(sha256sum <"$w/$name.source.json" | cut -d' ' -f1)
    fi
    mig_install "$w/$name.v3.json" "$f"
    if [[ -n $snew ]]; then mig_install "$w/$name.source.json" "$src"; fi
    rec=$(jq --arg n "$name" --arg v2 "$old" --arg v3 "$new" --arg s2 "$sold" --arg s3 "$snew" --arg at "$(date -Iseconds)" '
      .v = 1 | .themes[$n] = {v2: $v2, v3: $v3, at: $at, source: (if $s3 == "" then null else {v2: $s2, v3: $s3} end)}' <<<"$rec")
    echo "$name: migrated to v3${snew:+ (src/source.json hash updated)}"
  done
  if [[ -n $bk ]]; then jq . <<<"$rec" | put_json "$bk/.migrate.json"; fi
  echo "migrated ${#ok[@]} theme(s)${bk:+; v2 backup in $bk (pc-lights migrate --rollback)}${out:+ into $out (profile $pf)}"
  if (( ${#bad[@]} )); then die "identity check failed for: ${bad[*]} (left as v2)"; fi
  if [[ -n $verify ]]; then migrate_verify "$pf"; fi
}

# --verify-render: the golden comparison (plan §7 stage c) on the result,
# with the seeded profile. It needs the repo's tests/golden and a capture
# (PCL_GOLDEN_DIR, default ~/.cache/pc-lights/golden/current); run.sh maps
# a --out shadow back to $HOME/.config/pc-lights/themes, so it only means
# something with the real $HOME (the cut-over, or --out beside it).
migrate_verify() {
  local run=$PCL_LIB/../../tests/golden/run.sh g=${PCL_GOLDEN_DIR:-$HOME/.cache/pc-lights/golden/current} args=()
  [[ -x $run ]] || die "migrate --verify-render needs a repo checkout (no $run)"
  [[ -d $g/live ]] || die "migrate --verify-render needs a golden capture at $g (tests/golden/capture.sh, or set PCL_GOLDEN_DIR)"
  if [[ $THEME_DIR != "$HOME/.config/pc-lights/themes" ]]; then args+=(--themes "$THEME_DIR"); fi
  PCL_GOLDEN_PROFILE_FILE=$1 "$run" --golden "$g" --engine "$(readlink -f "$0")" --profile real "${args[@]}" ||
    die "verify-render: the migrated themes don't render like the goldens (see above)"
}
