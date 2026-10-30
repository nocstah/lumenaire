# lib/pc-lights/editor.sh — the theme editor's engine half (editor plan §1.1-§1.4):
# drafts, pointer edits, the editor view, save with history, delete to the
# trash, rename with every reference, history and restore.
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CACHE,
# STATE_DIR, THEME_DIR, LOCK, SCHED, DAY_SCHEME, PREVIEWS, TMP, ...) and
# helpers (die, log, active_name, day_scheme, lights_state, theme_jq,
# validate_theme, theme_eff, MIG_JQ, ...) live in the core and the other
# modules.
#
# Owner: editor package A; screen media (screens plan): package B2
# Public: editor_cmd (every "theme" verb except preview); for the preview
#         (package B): editor_draft_file editor_draft_rev editor_draft_eff
#         editor_draft_problems editor_media_root editor_drafts_json
#         editor_draft_abspath; for the media pipeline (package B1, media.sh):
#         editor_draft_stage editor_draft_abspath editor_media_pending
#         editor_media_apply
# Uses (package B1, when lib/pc-lights/media.sh is there): media_probe_json
#         media_thumb media_job_file media_jobs_json media_cancel_job
#         media_gc_draft, and media.jq's media_fit and media_title (stand-ins
#         in ed_mjq while it isn't)
# The jq half is lib/pc-lights/editor.jq (apply_ops, editor_view, led_hints),
# loaded with ed_jq.
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154
# (and file-wide: SC2016, the single-quoted $x are jq's, not the shell's;
# SC2030/SC2031, the draft runs the core's checks in a subshell with its own
# THEME_DIR on purpose; SC2329, the stand-ins defined in those subshells)
# shellcheck disable=SC2016,SC2030,SC2031,SC2329

# Storage (plan §1.1), all outside THEME_DIR so "themes" never lists it:
#   $STATE_DIR/drafts/<name>.json            one draft per theme name (0600)
#   $STATE_DIR/drafts/<name>.media/media/    its staged screen media (0700)
#   $STATE_DIR/theme-history/<name>/<UTCstamp>-<sha12>.json   overwritten theme.json files
#   $STATE_DIR/themes.trash/<name>-<stamp>/  deleted theme folders
# Draft: {v: 1, name, mode: edit|new|duplicate, from, rev, created, updated,
#         base_sha256, media_root, theme, pending_media?: {role: job id},
#         media_sources?: {rel: {source, recipe, model, at}}}
ED_NAME_RE='^[a-z0-9][a-z0-9._-]{0,47}$'
ED_HISTORY_KEEP=30
ED_USAGE='usage: lumenaire theme new <name> [--from <theme>] [--palette primary=HEX[,secondary=HEX][,accent=HEX][,alert=HEX]] [--json]
       lumenaire theme duplicate <from> <new> [--json]
       lumenaire theme edit <name> [--fresh] [--json]
       lumenaire theme show <name> [--json]
       lumenaire theme set <name> <pointer> <value> [<pointer> <value>...] [--unset <pointer>]... [--base-rev N] [--with-screens] [--json]
       lumenaire theme set <name> --patch <file|-> | --patch-json <ops> [--base-rev N] [--with-screens] [--json]
         (screen fields: /screens/@<role>/brightness, rotate, shuffle, orientation)
       lumenaire theme unset <name> <pointer>... [--base-rev N] [--json]
       lumenaire theme drafts --json
       lumenaire theme discard <name> [--json]
       lumenaire theme revert <name> [--json]
       lumenaire theme save <name> [--as <newname>] [--apply|--no-apply] [--force] [--json]
       lumenaire theme delete <name> [--json]
       lumenaire theme rename <old> <new> [--json]
       lumenaire theme history <name> [--json]
       lumenaire theme restore <name> <stamp> [--json]
       lumenaire theme screens <name> [--json]
       lumenaire theme media set|clips|rotate|mode <name> <role> ...   (theme media, alone, for its usage)
       lumenaire theme preview ...   (the live preview; see docs/ENGINE.md)'

# ---- errors and output ------------------------------------------------------------
# ed_fail <rc> <code> <message> [problems json]: the error object on stdout
# (plan §1.2), the message on stderr, and exit <rc>: 2 bad input, 4 conflict,
# 5 not editable, 75 busy.
ed_fail() {
  local rc=$1 code=$2 msg=$3 probs=${4:-}
  echo "pc-lights: $msg" >&2
  if [[ -n $probs ]]; then
    jq -nc --arg e "$msg" --arg c "$code" --argjson p "$probs" '{error: $e, code: $c, problems: $p}'
  else
    jq -nc --arg e "$msg" --arg c "$code" '{error: $e, code: $c}'
  fi
  exit "$rc"
}
ED_JSON=
# ed_out <json> <text>: the JSON with --json, the text line otherwise.
ed_out() { if [[ -n $ED_JSON ]]; then jq -c . <<<"$1"; else printf '%s\n' "$2"; fi; }

# ed_jq <jq args...> <filter>: jq -n with theme.jq and editor.jq loaded and
# $P, $M, $C bound like theme_jq. editor.jq is spliced in as text: jq 1.8.2
# aborts on a module that includes another module.
ed_jq() {
  local f=${*: -1} pf mf cf
  pf=$(theme_profile) mf=$(theme_models) cf=$(theme_presets)
  jq -n -L "$PCL_LIB" "${@:1:$#-1}" \
    --slurpfile pcl_p <([[ -f $pf ]] && cat "$pf" || echo null) \
    --slurpfile pcl_m <([[ -f $mf ]] && cat "$mf" || echo '{}') \
    --slurpfile pcl_c <([[ -f $cf ]] && cat "$cf" || echo '{}') \
    'include "theme"; '"$(<"$PCL_LIB/editor.jq")"'
    $pcl_p[0] as $P | $pcl_m[0] as $M | $pcl_c[0] as $C | '"$f"
}

# ---- names, references, locks ---------------------------------------------------
ed_sha() { sha256sum <"$1" | cut -c1-64; }
ed_is_auto() {
  [[ $1 == omarchy-* ]] && return 0
  [[ $(jq -r '.generator // "" | tostring' "$THEME_DIR/$1/src/source.json" 2>/dev/null) == auto-theme* ]]
}
# ed_new_name <name>: a name a new theme (or a rename) may take.
ed_new_name() {
  local name=$1
  [[ $name =~ $ED_NAME_RE ]] || ed_fail 2 bad-name "'$name' is not a theme name: use a-z, 0-9, . _ - (up to 48, starting with a letter or digit)"
  [[ $name != omarchy-* ]] || ed_fail 2 bad-name "omarchy-* names belong to auto-theme; choose another name"
  [[ ! -e $THEME_DIR/$name ]] || ed_fail 2 exists "a theme called $name already exists"
  [[ ! -f $(editor_draft_file "$name") ]] || ed_fail 2 exists "there are unsaved edits for a new theme called $name (theme discard $name drops them)"
}
# ed_refs <name>: what points at a theme, one per line: active, day, night, map:<slug>.
ed_refs() {
  local name=$1
  [[ $(active_name) != "$name" ]] || echo active
  [[ $(cat "$DAY_SCHEME" 2>/dev/null || true) != "$name" ]] || echo day
  [[ $(jq -r '.night_theme // empty' "$SCHED" 2>/dev/null || true) != "$name" ]] || echo night
  jq -r --arg n "$name" 'to_entries[] | select((.key | startswith("_") | not) or .key == "_default")
    | select(.value == $n) | "map:\(.key)"' "$STATE_DIR/omarchy-map.json" 2>/dev/null || true
}
# ed_refs_json <name> <draft?>: the view's $refs (plan §1.4 "saved" flags).
ed_refs_json() {
  local name=$1 refs auto=false pv=null
  refs=$(ed_refs "$name")
  if ed_is_auto "$name"; then auto=true; fi
  if [[ -f $CACHE/preview.json ]]; then
    pv=$(jq -c --arg n "$name" 'if type == "object" and .theme == $n then . else null end' "$CACHE/preview.json" 2>/dev/null || echo null)
  fi
  jq -nc --arg refs "$refs" --argjson draft "$2" --argjson auto "$auto" --argjson pv "${pv:-null}" '
    ($refs | split("\n") | map(select(. != ""))) as $r
    | {draft: $draft, active: ($r | index("active") != null), day: ($r | index("day") != null),
       night: ($r | index("night") != null), mapped_slugs: [$r[] | select(startswith("map:")) | ltrimstr("map:")],
       auto: $auto, preview: $pv}'
}
# ed_lock: the main lock, but only for 5 s: an apply holds it for 20 s or
# more, and the UI retries on 75 once "busy" clears.
ed_lock() {
  mkdir -p "${LOCK%/*}"
  exec 8>"$LOCK"
  flock -w 5 8 || ed_fail 75 busy "an apply is running; try again when it finishes"
}
# ed_draft_lock: serialises writers of the drafts folder (fd 6; a set is
# read-modify-write of rev).
ed_draft_lock() {
  mkdir -p "$STATE_DIR/drafts"
  exec 6>"$STATE_DIR/drafts/.lock"
  flock -w 5 6 || ed_fail 75 busy "another editor call is writing the drafts"
}
ed_draft_unlock() { exec 6>&-; }
ed_need_profile() {
  local pf; pf=$(theme_profile)
  if [[ ! -f $pf ]] || ! jq -e 'type == "object" and (.roles | type == "object")' "$pf" >/dev/null 2>&1; then
    ed_fail 5 no-profile "the theme editor needs a hardware profile; run: lumenaire detect"
  fi
}

# ---- drafts -----------------------------------------------------------------------
# editor_draft_file <name>: the draft's path (printed whether or not it exists).
editor_draft_file() { echo "$STATE_DIR/drafts/$1.json"; }
# editor_draft_rev <name>: the draft's rev; prints nothing and returns 1 without a draft.
editor_draft_rev() {
  local f; f=$(editor_draft_file "$1")
  [[ -f $f ]] || return 1
  jq -r '.rev // 0' "$f"
}
# editor_media_root <name>: where the draft's relative media paths resolve
# (empty for a new theme, or without a draft).
editor_media_root() {
  local f; f=$(editor_draft_file "$1")
  [[ -f $f ]] || return 0
  jq -r '.media_root // empty' "$f"
}
# editor_drafts_json: [{name, mode, from, rev, updated}] (status --json v1.2).
editor_drafts_json() {
  local f fs=()
  for f in "$STATE_DIR"/drafts/*.json; do [[ -f $f ]] && fs+=("$f"); done
  if (( ${#fs[@]} == 0 )); then echo '[]'; return 0; fi
  jq -sc 'map(objects | {name, mode, from: (.from // null), rev: (.rev // 0), updated: (.updated // null)}) | sort_by(.name)' \
    "${fs[@]}" 2>/dev/null || echo '[]'
}
# ed_draft_write <name>: stdin -> the draft, 0600, tmp + mv.
ed_draft_write() {
  local f; f=$(editor_draft_file "${1%.json}")
  mkdir -p "${f%/*}"
  if (umask 077 && jq . >"$f.$$.tmp") && [[ -s $f.$$.tmp ]]; then mv -f "$f.$$.tmp" "$f"
  else rm -f "$f.$$.tmp"; die "could not write the draft $f"; fi
}
# ed_draft_new <name> <mode> <from> <media_root> <base_sha|""> <theme json file>
ed_draft_new() {
  jq -n --arg name "$1" --arg mode "$2" --arg from "$3" --arg root "$4" --arg sha "$5" --slurpfile t "$6" \
    --argjson now "$EPOCHSECONDS" "$nul_jq"'
    {v: 1, name: $name, mode: $mode, from: ($from | n), rev: 1, created: $now, updated: $now,
     base_sha256: ($sha | n), media_root: ($root | n), theme: $t[0]}' | ed_draft_write "$1"
}
ed_need_draft() {
  [[ -f $(editor_draft_file "$1") ]] || ed_fail 2 not-found "no unsaved edits for $1 (open them with: theme edit $1)"
}

# ed_shadow <name>: a one-theme THEME_DIR for the draft, so the core's own
# validate_theme and theme_eff run on it unchanged: $TMP/ed-shadow/draft-<name>/
# holds the draft's theme.json and a link to every entry of its media root.
# With staged media (drafts/<name>.media/media, screens plan §1.4) media/ is
# a tree of links instead: the media root's files, then the stage's on top
# (the stage wins). Prints the shadow THEME_DIR. The compiled EFF lands in
# $CACHE/compiled/draft-<name>.<key>.json (theme_eff's naming). Nothing
# outside the engine ever sees a shadow path: the preview resolves real ones.
ed_shadow() {
  local name=$1 sd=$TMP/ed-shadow f root e st
  f=$(editor_draft_file "$name")
  rm -rf "${sd:?}/draft-$name"; mkdir -p "$sd/draft-$name"
  jq '.theme' "$f" >"$sd/draft-$name/theme.json" || die "could not read the draft $f"
  root=$(jq -r '.media_root // empty' "$f")
  st=$(editor_draft_stage "$name")/media
  [[ -d $st ]] || st=
  if [[ -n $root && -d $root ]]; then
    for e in "$root"/* "$root"/.[!.]*; do
      [[ -e $e || -L $e ]] || continue
      [[ ${e##*/} != theme.json ]] || continue
      [[ -z $st || ${e##*/} != media ]] || continue
      ln -s "$e" "$sd/draft-$name/${e##*/}"
    done
  fi
  if [[ -n $st ]]; then
    if [[ -n $root && -d $root/media ]]; then cp -rs "$root/media" "$sd/draft-$name/" || die "could not link $root/media"
    else mkdir -p "$sd/draft-$name/media"; fi
    cp -rsf "$st/." "$sd/draft-$name/media/" || die "could not link the staged media of $name"
  fi
  echo "$sd"
}
# editor_draft_eff <name>: compile the draft (the path of its EFF).
editor_draft_eff() {
  local name=$1 sd
  [[ -f $(editor_draft_file "$name") ]] || die "no draft for theme $name"
  sd=$(ed_shadow "$name") || exit 1
  ( THEME_DIR=$sd; theme_eff "draft-$name" )
}
# editor_draft_problems <name> [--fast]: every validate_theme problem of the
# draft, one per line (empty = ok). --fast skips the OpenRGB check (python,
# ~80 ms), as "set" does; save and the default run it. Media paths are
# reported under the media root.
editor_draft_problems() {
  local name=$1 fast=${2:-} sd root out line pre
  [[ -f $(editor_draft_file "$name") ]] || { echo "no draft for theme $name"; return 0; }
  sd=$(ed_shadow "$name") || exit 1
  root=$(editor_media_root "$name")
  if out=$( (
      THEME_DIR=$sd
      log() { echo "pc-lights: $*" >&2; }
      if [[ $fast == --fast ]]; then openrgb_py() { :; }; fi
      validate_theme "draft-$name"
    ) 2>&1 ); then
    return 0
  fi
  pre="pc-lights: theme draft-$name: "
  local n=0
  while IFS= read -r line; do
    if [[ $line == "$pre"* ]]; then
      line=${line#"$pre"}
      line=${line//"$sd/draft-$name/"/"${root:+$root/}"}
      printf '%s\n' "$line"; n=$((n + 1))
    fi
  done <<<"$out"
  if (( n == 0 )); then
    line=$(tail -n1 <<<"$out"); line=${line#pc-lights: }
    printf '%s\n' "${line//draft-$name/$name}"
  fi
}

# ---- screen media: the stage, paths, B1's pipeline (screens plan §1.4) -----------------
# A draft's new media waits in its stage, $STATE_DIR/drafts/<name>.media/
# (0700, the same filesystem as the themes): media/<stem>-<sha8>.<ext>, named
# by content, written by B1's job runner (tmp name, then mv). A draft-relative
# path resolves in the stage first, then in the media root. Save links the
# staged files the draft uses into the theme (ed_stage_commit); B1's GC
# (media_gc_draft) empties what nothing references any more.
ED_STAGE_CAP=${PCL_MEDIA_STAGE_CAP:-4294967296}
# editor_draft_stage <name> [--create]: the stage folder (printed whether or
# not it exists; staged rels are relative to it). --create makes <stage>/media
# (0700) and needs the draft: 1 without one.
editor_draft_stage() {
  local d=$STATE_DIR/drafts/$1.media
  if [[ ${2:-} == --create ]]; then
    [[ -f $(editor_draft_file "$1") ]] || return 1
    (umask 077 && mkdir -p "$d/media") || return 1
  fi
  echo "$d"
}
# ed_root_of <name>: where the relative paths of <name> resolve after the
# stage: the draft's media root, or the saved theme's folder without a draft.
ed_root_of() {
  local f; f=$(editor_draft_file "$1")
  if [[ -f $f ]]; then jq -r '.media_root // empty' "$f"
  elif [[ -d $THEME_DIR/$1 ]]; then echo "$THEME_DIR/$1"; fi
}
# ed_resolve <stage|""> <root|""> <rel>: "<where>\t<abs>", where = stage, root
# or missing (an absolute path that exists counts as root).
ed_resolve() {
  local st=$1 root=$2 rel=$3
  if [[ -z $rel ]]; then printf 'missing\t\n'
  elif [[ $rel == /* ]]; then if [[ -e $rel ]]; then printf 'root\t%s\n' "$rel"; else printf 'missing\t\n'; fi
  elif [[ -n $st && -e $st/$rel ]]; then printf 'stage\t%s\n' "$st/$rel"
  elif [[ -n $root && -e $root/$rel ]]; then printf 'root\t%s\n' "$root/$rel"
  else printf 'missing\t\n'; fi
}
# editor_draft_abspath <name> <rel>: the absolute path of a draft-relative
# file or folder (the stage first, then the media root; the saved theme's
# folder without a draft); 1 and nothing printed when it isn't there.
editor_draft_abspath() {
  local name=$1 rel=${2:-} st='' w abs
  if [[ -f $(editor_draft_file "$name") ]]; then st=$(editor_draft_stage "$name"); fi
  IFS=$'\t' read -r w abs < <(ed_resolve "$st" "$(ed_root_of "$name")" "$rel")
  [[ $w != missing ]] || return 1
  printf '%s\n' "$abs"
}
# ed_media_type <path>: image, video or gif by the name; 1 for anything else.
ed_media_type() {
  case ${1,,} in
    *.mp4 | *.mov | *.webm | *.mkv | *.m4v | *.avi) echo video ;;
    *.png | *.jpg | *.jpeg | *.webp | *.bmp) echo image ;;
    *.gif) echo gif ;;
    *) return 1 ;;
  esac
}
# ed_list_folder <dir>: its videos, one path a line, sorted like the clip timer
# lists them (rotating_screens).
ed_list_folder() {
  find "$1" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.mkv' \) 2>/dev/null | sort
}

# B1's pipeline (lib/pc-lights/media.sh) through these, so the editor still
# works, with less detail, while it is missing: no probes, no thumbnails, no
# jobs; a draft's stage is removed whole once nothing points into it. Every
# call runs in a subshell (or a command substitution): media.sh loads itself
# on first use, and nothing it does (a failed load, a die) may cut short the
# save, discard or apply that asked for it.
ed_job_file() { if declare -F media_job_file >/dev/null; then media_job_file "$1"; else echo "$CACHE/media/jobs/$1.json"; fi; }
ed_cancel_job() { if declare -F media_cancel_job >/dev/null; then (media_cancel_job "$1") >/dev/null 2>&1 || true; fi; }
ed_probe() { if declare -F media_probe_json >/dev/null; then media_probe_json "$1" 2>/dev/null || true; fi; }
# ed_thumb <abs>...: one thumbnail path a line (asked for, not waited for).
ed_thumb() { if declare -F media_thumb >/dev/null; then media_thumb "$@" 2>/dev/null || true; fi; }
# ed_gc_draft <name>: after save, discard, rename, delete and a preview end.
# Never touches a file the daemon config or the preview still shows.
ed_gc_draft() {
  local st
  if declare -F media_gc_draft >/dev/null; then (media_gc_draft "$1") >/dev/null 2>&1 || true; return 0; fi
  st=$(editor_draft_stage "$1")
  [[ -d $st && ! -f $(editor_draft_file "$1") ]] || return 0
  if grep -qsF -- "$st/" "$CFG_LIVE" "$CACHE/preview/applied-lcds.json" "$CACHE/preview/saved-lcds.json"; then return 0; fi
  rm -rf -- "$st"
}
# ed_draft_jobs <name>: the draft's jobs, one id a line: its pending ones and
# (with media.sh) every job media jobs lists for it.
ed_draft_jobs() {
  local f; f=$(editor_draft_file "$1")
  {
    [[ -f $f ]] && jq -r '.pending_media // {} | objects | .[] | strings' "$f" 2>/dev/null
    if declare -F media_jobs_json >/dev/null; then
      media_jobs_json --draft "$1" 2>/dev/null | jq -r '(.jobs // .)[]? | objects | .id // empty' 2>/dev/null
    fi
  } | sort -u
}

# ed_mjq <jq args...> <filter>: ed_jq with media.jq's defs (media_fit,
# media_title; package B1) spliced in front of editor.jq's, or stand-ins
# (the same defs, screens plan §1.3b) while media.jq isn't there.
ED_MEDIA_JQ_STUB='
def media_r3: if type == "number" then (. * 1000 | round) / 1000 else . end;
def media_title: split("/") | last | sub("\\.[A-Za-z0-9]{1,5}$"; "") | sub("-[0-9a-f]{8}$"; "") | gsub("[_-]+"; " ")
  | gsub("(?<a>[A-Za-z]{3})(?<d>[0-9])"; "\(.a) \(.d)") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
  | if . == "" then "untitled" else . end;
def media_fit($p; $t):
  if ($p | type) != "object" or $p.error != null or ($p.dw // 0) <= 0 or ($p.dh // 0) <= 0
     or ($t | type) != "object" or ($t.w // 0) <= 0 or ($t.h // 0) <= 0 then
    {state: "unknown", keep: null, scale: null, score: null, note: null}
  else
    ($p.dw / $p.dh) as $sa | ($t.w / $t.h) as $ta | ($sa / $ta) as $r | ([$r, 1 / $r] | min) as $keep
    | (if $sa > $ta then $p.dh * $ta else $p.dw end) as $cw | ($t.w / $cw) as $scale
    | (if $p.made_for == null then 1
       elif $p.made_for == $t.model or ($p.made_for_aspect != null and $p.made_for_aspect == $t.aspect) then 1.05
       else 0.9 end) as $mf
    | ([pow($keep; 1.5) * (if $scale > 1 then pow($scale; -0.5) else 1 end) * $mf, 1] | min) as $score
    | {state: (if $p.dw == $t.w and $p.dh == $t.h then "exact" elif $keep >= 0.98 then "scaled"
               elif $keep >= 0.6 then "cropped" else "poor" end),
       keep: ($keep | media_r3), scale: ($scale | media_r3), score: ($score | media_r3),
       note: (if $t.max_s != null and $p.kind != "image" and ($p.duration // 0) > $t.max_s then "long"
              elif $scale > 1.25 then "low-res" elif $p.hdr == true then "hdr" elif $p.alpha == true then "alpha"
              else null end)}
  end;'
ed_mjq() {
  local f=${*: -1} pf mf cf mj=$ED_MEDIA_JQ_STUB
  pf=$(theme_profile) mf=$(theme_models) cf=$(theme_presets)
  if [[ -f $PCL_LIB/media.jq ]]; then mj=$(<"$PCL_LIB/media.jq"); fi
  jq -n -L "$PCL_LIB" "${@:1:$#-1}" \
    --slurpfile pcl_p <([[ -f $pf ]] && cat "$pf" || echo null) \
    --slurpfile pcl_m <([[ -f $mf ]] && cat "$mf" || echo '{}') \
    --slurpfile pcl_c <([[ -f $cf ]] && cat "$cf" || echo '{}') \
    'include "theme"; '"$mj"' '"$(<"$PCL_LIB/editor.jq")"'
    $pcl_p[0] as $P | $pcl_m[0] as $M | $pcl_c[0] as $C | '"$f"
}

# ---- the screens view (screens plan §1.3a) ----------------------------------------------
# ed_media_refs <theme.json>: the files a theme's screens and templates name,
# "<kind>\t<rel>" a line: path (an entry's picture or video, _prev's too),
# clip (a clip file or folder), tpl (a template).
ed_media_refs() {
  jq -r '(.screens | objects // {} | [.. | objects | (.path | strings | "path\t" + .), ((.clips | arrays // [])[] | strings | "clip\t" + .)] | unique[]),
    ((.templates | arrays // [])[] | strings | "tpl\t" + .)' "$1" 2>/dev/null || true
}
# ed_screens_ctx <name> <draft or stand-in file> <has draft true|false>: what
# the view needs from the disk (ed_screens_view's $X): every referenced file
# resolved (stage, then media root), probed and thumbnailed through B1 (at
# most PCL_SCREENS_PROBES files, 24), clip folders listed, templates read,
# the jobs pending, the base theme for "changed", the stage's disk use.
ed_screens_ctx() {
  local name=$1 dj=$2 hasd=$3 st='' root kind rel w abs sub id bg tb ts pr bytes base='' mode from
  local -A files=()
  local tj=$TMP/ed-scr-theme.json ft=$TMP/ed-scr-files.tsv fo=$TMP/ed-scr-folders.tsv tt=$TMP/ed-scr-tpls.tsv
  root=$(jq -r '.media_root // empty' "$dj")
  if [[ $hasd == true && -d $(editor_draft_stage "$name") ]]; then st=$(editor_draft_stage "$name"); fi
  jq '.theme' "$dj" >"$tj"
  : >"$ft"; : >"$fo"; : >"$tt"
  while IFS=$'\t' read -r kind rel; do
    [[ -n $rel ]] || continue
    IFS=$'\t' read -r w abs < <(ed_resolve "$st" "$root" "$rel")
    case $kind in
      tpl)
        id='' bg='' tb=''
        if [[ -f $abs ]]; then IFS=$'\t' read -r id bg < <(jq -r '[(.id // "" | tostring), (.background.path // "" | tostring)] | @tsv' "$abs" 2>/dev/null || true); fi
        if [[ -n $bg ]] && [[ $(ed_media_type "$bg" || true) == image ]]; then
          IFS=$'\t' read -r _ tb < <(ed_resolve "$st" "$root" "$bg")
        fi
        printf '%s\t%s\t%s\n' "$rel" "$id" "$tb" >>"$tt" ;;
      clip)
        if [[ -d $abs ]]; then
          { [[ -n $st && -d $st/$rel ]] && ed_list_folder "$st/$rel"; [[ -n $root && -d $root/$rel ]] && ed_list_folder "$root/$rel"; } |
            while IFS= read -r sub; do printf '%s/%s\n' "${rel%/}" "${sub##*/}"; done | sort -u >"$TMP/ed-scr-dir"
          while IFS= read -r sub; do printf '%s\t%s\n' "$rel" "$sub" >>"$fo"; files[$sub]=1; done <"$TMP/ed-scr-dir"
          printf '%s\t\n' "$rel" >>"$fo"
        else files[$rel]=1; fi ;;
      *) files[$rel]=1 ;;
    esac
  done < <(ed_media_refs "$tj")
  # Every file resolved; the ones there probed (index first, B1) and their
  # thumbnails asked for, each in one batch.
  local rels=() whs=() abss=() have=() probes=() thumbs=() i
  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    IFS=$'\t' read -r w abs < <(ed_resolve "$st" "$root" "$rel")
    rels+=("$rel") whs+=("$w") abss+=("$abs")
    if [[ $w != missing && -f $abs ]] && (( ${#have[@]} < ${PCL_SCREENS_PROBES:-24} )); then have+=("$abs"); fi
  done < <(printf '%s\n' "${!files[@]}" | sort)
  if (( ${#have[@]} )); then
    if declare -F media_probe_many >/dev/null; then mapfile -t probes < <(media_probe_many "${have[@]}" 2>/dev/null || true)
    else for abs in "${have[@]}"; do probes+=("$(ed_probe "$abs" | head -n1)"); done; fi
    mapfile -t thumbs < <(ed_thumb "${have[@]}")
  fi
  local -A pmap=() tmap=()
  for i in "${!have[@]}"; do pmap[${have[i]}]=${probes[i]:-} tmap[${have[i]}]=${thumbs[i]:-}; done
  for i in "${!rels[@]}"; do
    abs=${abss[i]} bytes='' tb='' ts=none pr=null
    if [[ ${whs[i]} != missing && -f $abs ]]; then
      bytes=$(stat -L -c %s -- "$abs" 2>/dev/null || true)
      pr=$(jq -c 'objects' <<<"${pmap[$abs]:-null}" 2>/dev/null || true); pr=${pr:-null}
      tb=${tmap[$abs]:-}
      if [[ -n $tb && -s $tb ]]; then ts=ready
      elif [[ -n $tb && -e ${tb%.*}.fail ]]; then ts=failed
      elif [[ -n $tb ]]; then ts=pending; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${rels[i]}" "${whs[i]}" "$abs" "$bytes" "$tb" "$ts" "$pr" >>"$ft"
  done
  # The base "changed" compares with: the saved theme (edit), the theme a
  # duplicate came from, the theme itself (no draft); none for a new theme.
  mode=$(jq -r '.mode // empty' "$dj") from=$(jq -r '.from // empty' "$dj")
  case $mode in
    edit | saved) base=$THEME_DIR/$name/theme.json ;;
    duplicate) base=$THEME_DIR/$from/theme.json ;;
  esac
  [[ -n $base && -f $base ]] || base=/dev/null
  # The jobs pending, as their records say (one cancelled, superseded or
  # without a record any more is over).
  : >"$TMP/ed-scr-jobs.tsv"
  while IFS=$'\t' read -r kind id; do
    [[ -n $id ]] || continue
    abs=$(ed_job_file "$id")
    printf '%s\t%s\t%s\n' "$kind" "$id" "$(jq -c 'objects' "$abs" 2>/dev/null || echo null)" >>"$TMP/ed-scr-jobs.tsv"
  done < <(jq -r '.pending_media // {} | objects | to_entries[] | "\(.key)\t\(.value)"' "$dj" 2>/dev/null || true)
  local sb=0 free=null
  if [[ -n $st ]]; then sb=$(du -sb "$st" 2>/dev/null | cut -f1); [[ $sb =~ ^[0-9]+$ ]] || sb=0; fi
  free=$(df -B1 --output=avail "$STATE_DIR" 2>/dev/null | tail -n1 | tr -dc 0-9); [[ -n $free ]] || free=null
  jq -n --arg draft "$hasd" --arg st "$st" --arg root "$root" --arg name "$name" \
    --rawfile ft "$ft" --rawfile fo "$fo" --rawfile tt "$tt" --rawfile jt "$TMP/ed-scr-jobs.tsv" \
    --slurpfile base "$base" --slurpfile inst <(jq -c '[.templates[]? | .id | strings]' "$TPL_LIVE" 2>/dev/null || echo '[]') \
    --arg us88 "$([[ -n $root && -f $root/src/preview-us88.jpg ]] && echo "$root/src/preview-us88.jpg")" \
    --argjson sb "$sb" --argjson free "$free" --argjson cap "$ED_STAGE_CAP" '
    def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
    def n: if . == "" then null else . end;
    {draft: ($draft == "true"), stage: ($st | n), media_root: ($root | n),
     files: ([rows($ft)[] | {(.[0]): {where: .[1], abs: (.[2] | n), bytes: (.[3] | n | if . then tonumber else null end),
                                     thumb: (.[4] | n), thumb_state: .[5], probe: (.[6] | fromjson? // null)}}] | add // {}),
     folders: (reduce rows($fo)[] as $r ({}; .[$r[0]] = ((.[$r[0]] // []) + (if ($r[1] // "") == "" then [] else [$r[1]] end)))),
     templates: [rows($tt)[] | {rel: .[0], id: (.[1] | n), thumb: (.[2] // "" | n)}],
     installed: $inst[0], preview_us88: ($us88 | n),
     pending: ([rows($jt)[] | (.[2] | fromjson? // null) as $j | .[1] as $id
                | select($j != null and ($j.state // "") != "cancelled" and (($j.error | objects | .code) // "") != "superseded")
                | {(.[0]): {job: $id, state: ($j.state // "unknown"), progress: (($j.progress | objects | .frac) // null),
                            then: ($j.then // null), error: ($j.error // null)}}] | add // {}),
     base: ($base[0] // null),
     disk: {stage_bytes: $sb, free_bytes: $free, cap: $cap}}'
}
# ed_screens_json <name>: the "theme screens" view of the draft, or of the
# saved theme when there is none (target: under 200 ms; lock-free).
ed_screens_json() {
  local name=$1 f sf dj hasd=false ctx
  f=$(editor_draft_file "$name") sf=$THEME_DIR/$name/theme.json
  if [[ -f $f ]]; then dj=$f hasd=true
  else
    [[ -f $sf ]] || ed_fail 2 not-found "no theme and no draft called $name"
    dj=$TMP/ed-scr-saved.json
    jq -n --arg name "$name" --arg root "$THEME_DIR/$name" --slurpfile t "$sf" '
      {v: 1, name: $name, mode: "saved", from: null, rev: 0, media_root: $root, theme: $t[0]}' >"$dj" ||
      ed_fail 2 invalid "$sf is not valid JSON"
  fi
  ctx=$TMP/ed-scr-ctx.json
  ed_screens_ctx "$name" "$dj" "$hasd" >"$ctx" || die "could not read the media of $name"
  ed_mjq --slurpfile d "$dj" --slurpfile x "$ctx" --arg modes "$STRIMER_MODES" \
    'ed_screens_view($d[0]; $P; $M; $C; $x[0]; $modes)' || die "could not build the screens view of $name"
}
# theme screens <name> [--json]
ed_screens_cmd() {
  local name='' v
  while (( $# )); do
    case $1 in
      --json) ED_JSON=1 ;;
      -*) ed_fail 2 usage "usage: lumenaire theme screens <name> [--json]" ;;
      *) [[ -z $name ]] || ed_fail 2 usage "usage: lumenaire theme screens <name> [--json]"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "usage: lumenaire theme screens <name> [--json]"
  ed_need_profile
  if [[ ! -f $(editor_draft_file "$name") ]]; then
    theme_exists "$name" || ed_fail 2 not-found "no theme and no draft called $name"
    [[ $(theme_schema "$THEME_DIR/$name/theme.json") == 3 ]] || ed_fail 5 not-v3 "theme $name is a v2 theme: run migrate, or duplicate it"
  fi
  v=$(ed_screens_json "$name") || exit 1
  if [[ -n $ED_JSON ]]; then jq -c . <<<"$v"; return 0; fi
  jq -r '"\(.name): \(if .draft then "draft rev \(.rev)" else "saved theme" end), screens \(.coverage.summary // "-")",
    (.screens[] | "  \(.short) [\(.source)\(if .changed then ", changed" else "" end)]: "
      + (if .media then "\(.media.type) \(.media.rel) (\(.media.where))" elif .template then "template \(.template.id)"
         elif .managed then "nothing from this theme" else "not managed" end)
      + (if .clips then ", \(.clips.items | length) clips" + (if .clips.rotate then " every \(.clips.rotate) s" else "" end) else "" end)
      + (if .brightness.value != null then ", brightness \(.brightness.value)" else "" end)
      + (if .pending then ", preparing (\(.pending.state))" else "" end)),
    (.screens[] | .short as $s | .problems[] | "  \($s): \(.text)"),
    (.problems[] | "  problem: \(.message)")' <<<"$v"
}

# ---- B1's hooks into the draft (screens plan §8) -------------------------------------------
# editor_media_pending <name> <role> <job> [<only-if>]: the draft now waits for
# <job> on <role> (an empty job clears the wait; <only-if>: only when it is
# that job now). Prints the job it replaced, if any. 1 without a draft.
editor_media_pending() {
  local name=$1 role=$2 job=${3:-} only=${4:-} f
  f=$(editor_draft_file "$name")
  [[ -f $f ]] || return 1
  (
    ed_draft_lock >/dev/null
    old=$(jq -r --arg r "$role" '.pending_media // {} | objects | .[$r] // empty' "$f")
    if [[ -n $only && $old != "$only" ]]; then exit 0; fi
    jq --arg r "$role" --arg j "$job" '
      .pending_media = ((.pending_media | objects // {}) | if $j == "" then del(.[$r]) else . + {($r): $j} end)
      | if (.pending_media | length) == 0 then del(.pending_media) else . end' "$f" | ed_draft_write "$name" >/dev/null
    if [[ -n $old && $old != "$job" ]]; then printf '%s\n' "$old"; fi
  )
}
# editor_media_apply <name> <jobfile>: a finished job's output into the draft,
# as its "then" says (set: theme media set <role> <rel>; clip-add: clips add
# <rel> --at <at>; none: the wait ends), under the drafts lock. 0 applied (the
# draft's new rev on stdout), 1 superseded (the role waits for another job
# now) or no draft, 2 not applied (the reason on stderr).
editor_media_apply() {
  local name=$1 jf=$2 out rc=0
  [[ -f $(editor_draft_file "$name") ]] || return 1
  out=$(
    ED_JSON=
    job=$(jq -c 'objects' "$jf" 2>/dev/null) && [[ -n $job ]] || { echo "pc-lights: cannot read the job $jf" >&2; exit 2; }
    v=$(jq -c --arg name "$name" '
      (.output | objects // {}) as $o | (.then // "set") as $t
      | {verb: (if $t == "clip-add" then "clips" elif $t == "none" then "done" else "set" end), role, expect_job: .id,
         src: {kind: "job", rel: $o.rel, type: null, model: (.model // null), dims: null, job: .id,
               source: ((.source | objects | .path) // null), recipe: (.recipe // null)},
         clip: {op: "add", at: (.at // null)}, all_fans: false}' <<<"$job") || exit 2
    rel=$(jq -r '.src.rel // empty' <<<"$v")
    if [[ $(jq -r .verb <<<"$v") != "done" ]]; then
      [[ -n $rel ]] || { echo "pc-lights: job $jf has no output" >&2; exit 2; }
      editor_draft_abspath "$name" "$rel" >/dev/null || { echo "pc-lights: the output $rel of $jf is not in the draft's stage" >&2; exit 2; }
      type=$(ed_media_type "$rel") || { echo "pc-lights: $rel is not a picture or video" >&2; exit 2; }
      v=$(jq -c --arg t "$type" '.src.type = $t' <<<"$v")
    fi
    ed_media_run "$name" "$v" ""
    echo "rev=$(editor_draft_rev "$name")"
  ) || rc=$?
  case $rc in
    0) sed -n 's/^rev=//p' <<<"$out" | tail -n1; return 0 ;;
    *) if grep -q '"code":"superseded"' <<<"$out"; then return 1; fi
       [[ -f $(editor_draft_file "$name") ]] || return 1
       return 2 ;;
  esac
}

# ---- theme media (screens plan §1.2, §4.3-§4.5) ---------------------------------------------
ED_MEDIA_USAGE='usage: lumenaire theme media set <name> <role> <src> [--all-fans] [--base-rev N] [--with-screens] [--json]
       lumenaire theme media clips <name> <role> add <src> [--at N] | remove <N> | move <from> <to> | order <i,j,...> [--base-rev N] [--with-screens] [--json]
       lumenaire theme media rotate <name> <role> <seconds>|off [--shuffle on|off] [--base-rev N] [--with-screens] [--json]
       lumenaire theme media mode <name> <role> template|media [<src>] [--base-rev N] [--with-screens] [--json]
  <src>: j-<id> (a finished media prepare job), a path the draft resolves (media/x.mp4), or none'
# ed_media_src <name> <src> <role>: the source as ed_media_edit's $v.src.
ed_media_src() {
  local name=$1 src=$2 role=$3 jf state abs type model dims=null f root
  case $src in
    none) echo '{"kind":"none"}' ;;
    j-*)
      [[ $src =~ ^j-[A-Za-z0-9._-]+$ ]] || ed_fail 2 usage "'$src' is not a job id"
      jf=$(ed_job_file "$src")
      [[ -f $jf ]] || ed_fail 2 not-found "no media job $src"
      state=$(jq -r '.state // empty' "$jf" 2>/dev/null)
      [[ $state == "done" ]] || ed_fail 2 media-pending "job $src is ${state:-unreadable}, not done"
      [[ $(jq -r '.draft // empty' "$jf") == "$name" ]] || ed_fail 2 invalid "job $src was prepared for another draft"
      abs=$(jq -r '.output.rel // empty' "$jf")
      if [[ -z $abs ]] || ! editor_draft_abspath "$name" "$abs" >/dev/null; then
        ed_fail 2 not-found "the output of job $src is not in the draft's stage"
      fi
      type=$(ed_media_type "$abs") || ed_fail 2 unsupported "the output of job $src is not a picture or video"
      jq -c --arg t "$type" --arg id "$src" '{kind: "job", rel: .output.rel, type: $t, model: (.model // null), dims: null,
        job: $id, source: ((.source | objects | .path) // null), recipe: (.recipe // null)}' "$jf" ;;
    *)
      # A theme names only its own files (self-contained): a file from
      # elsewhere is prepared into the stage first (media prepare).
      if [[ $src == /* || /$src/ == */../* ]]; then
        ed_fail 2 usage "$src is not a path inside the theme (media/...); prepare a file from elsewhere first: lumenaire media prepare"
      fi
      abs=$(editor_draft_abspath "$name" "$src") || ed_fail 2 not-found "$src is not in the draft's stage or its theme folder"
      [[ -f $abs ]] || ed_fail 2 invalid "$src is a folder; clips take files"
      type=$(ed_media_type "$src") || ed_fail 2 unsupported "$src is not a picture or video this editor knows (mp4, mov, webm, mkv, png, jpg, webp, gif)"
      # What it was made for: the draft's own record, the theme's src/media.json,
      # an entry already using it; else its shape (B1's probe).
      f=$(editor_draft_file "$name") root=$(ed_root_of "$name")
      model=$(jq -r --arg r "$src" '((.media_sources // {})[$r].model // empty),
        ([.theme.screens // {} | .. | objects | select(.path == $r) | .model | strings] | first // empty)' "$f" 2>/dev/null | head -n1)
      if [[ -z $model && -n $root ]]; then model=$(jq -r --arg r "$src" '.files[$r].model // empty' "$root/src/media.json" 2>/dev/null || true); fi
      if [[ -z $model ]]; then
        dims=$(ed_probe "$abs" | jq -c 'objects | select((.dw // .w) != null and (.dh // .h) != null) | [(.dw // .w), (.dh // .h)]' 2>/dev/null || true)
        dims=${dims:-null}
      fi
      jq -nc --arg r "$src" --arg t "$type" --arg m "$model" --argjson d "$dims" \
        '{kind: "path", rel: $r, type: $t, model: (if $m == "" then null else $m end), dims: $d, job: null, source: null, recipe: null}' ;;
  esac
}
# ed_folders_json <name>: {rel: [file rels]} for every clip folder the draft names.
ed_folders_json() {
  local name=$1 f st='' root kind rel sub
  f=$(editor_draft_file "$name") root=$(ed_root_of "$name")
  if [[ -d $(editor_draft_stage "$name") ]]; then st=$(editor_draft_stage "$name"); fi
  jq '.theme' "$f" >"$TMP/ed-fold-theme.json"
  while IFS=$'\t' read -r kind rel; do
    [[ $kind == clip && -n $rel ]] || continue
    { [[ -n $st && -d $st/$rel ]] && ed_list_folder "$st/$rel"; [[ -n $root && -d $root/$rel ]] && ed_list_folder "$root/$rel"; } |
      while IFS= read -r sub; do printf '%s\t%s/%s\n' "$rel" "${rel%/}" "${sub##*/}"; done | sort -u
    if [[ -n $st && -d $st/$rel || -n $root && -d $root/$rel ]]; then printf '%s\t\n' "$rel"; fi
  done < <(ed_media_refs "$TMP/ed-fold-theme.json") >"$TMP/ed-fold.tsv"
  jq -Rn 'reduce (inputs | split("\t")) as $r ({}; .[$r[0]] = ((.[$r[0]] // []) + (if ($r[1] // "") == "" then [] else [$r[1]] end)))' <"$TMP/ed-fold.tsv"
}
# ed_media_run <name> <$v json> <base rev>: one ed_media_edit under the drafts
# lock; the draft is written when it changed. Sets ED_NOTES (a JSON list) and
# ED_CANCEL (jobs to stop, one a line).
ED_NOTES='[]' ED_CANCEL=''
ed_media_run() {
  local name=$1 vj=$2 base=$3 f cur out err code msg
  f=$(editor_draft_file "$name")
  vj=$(jq -c --argjson fo "$(ed_folders_json "$name")" --argjson tp "$(ed_templates_json "$name")" \
    '.folders = $fo | .templates = $tp' <<<"$vj") || die "could not read the draft of $name"
  ed_draft_lock
  [[ -f $f ]] || ed_fail 2 not-found "no unsaved edits for $name"
  cur=$(jq -r '.rev // 0' "$f")
  if [[ -n $base && $base != "$cur" ]]; then
    ed_fail 2 stale-rev "the draft of $name is at rev $cur, not $base; reload it"
  fi
  if ! out=$(ed_jq --slurpfile d "$f" --argjson v "$vj" --argjson now "$EPOCHSECONDS" \
      '$d[0] | ed_media_edit($v; $P; $M; $now)' 2>"$TMP/ed-media.err"); then
    err=$(sed -n 's/^jq: error ([^)]*): //p' "$TMP/ed-media.err" | head -1)
    code=${err%%: *} msg=${err#*: }
    case $code in
      usage | invalid | unfit | no-role | superseded) ;;
      *) code=invalid msg=${err:-could not apply the edit} ;;
    esac
    ed_fail 2 "$code" "$msg"
  fi
  jq -e '.draft | objects' >/dev/null 2>&1 <<<"$out" || die "the media edit of $name came out empty"
  if [[ $(jq -r .changed <<<"$out") == true ]]; then jq '.draft' <<<"$out" | ed_draft_write "$name"; fi
  ed_draft_unlock
  ED_NOTES=$(jq -c '.notes // []' <<<"$out") ED_CANCEL=$(jq -r '.cancel[]?' <<<"$out")
}
# ed_templates_json <name>: [{rel, id}] of the templates the draft lists.
ed_templates_json() {
  local name=$1 rel abs id
  {
    while IFS= read -r rel; do
      abs=$(editor_draft_abspath "$name" "$rel") || continue
      id=$(jq -r '.id // empty | tostring' "$abs" 2>/dev/null || true)
      [[ -n $id ]] && jq -nc --arg r "$rel" --arg i "$id" '{rel: $r, id: $i}'
    done < <(jq -r '.theme.templates // [] | arrays | .[] | strings' "$(editor_draft_file "$name")" 2>/dev/null || true)
  } | jq -sc .
}
# ed_with_views <name> <text line> <with-screens 1|""> [extra json]: the
# answer of a draft edit: the editor view (--json) plus notes and, with
# --with-screens, screens_view; the text line and the notes otherwise.
ed_with_views() {
  local name=$1 line=$2 ws=$3 extra=${4:-'{}'} v s=null
  if [[ -z $ED_JSON ]]; then
    printf '%s\n' "$line"
    jq -r '.notes[]? | "  note: \(.)"' <<<"$extra"
    return 0
  fi
  v=$(ed_view_json "$name" --fast) || exit 1
  if [[ -n $ws ]]; then s=$(ed_screens_json "$name") || exit 1; fi
  jq -c --argjson x "$extra" --argjson s "$s" '. + $x + (if $s == null then {} else {screens_view: $s} end)' <<<"$v"
}
# theme media set|clips|rotate|mode <name> <role> ...
ed_media() {
  local verb=${1:-} name role base='' ws='' allf=false at=null shuffle=null pos=() v src='' sj='null' clip=null rot=null mode=null n
  (( $# )) && shift
  [[ $verb =~ ^(set|clips|rotate|mode)$ ]] || ed_fail 2 usage "$ED_MEDIA_USAGE"
  while (( $# )); do
    case $1 in
      --json) ED_JSON=1 ;;
      --with-screens) ws=1 ;;
      --base-rev) [[ ${2:-} =~ ^[0-9]+$ ]] || ed_fail 2 usage "--base-rev needs a number"; base=$2; shift ;;
      --all-fans) [[ $verb == set ]] || ed_fail 2 usage "--all-fans goes with theme media set"; allf=true ;;
      --at) [[ ${2:-} =~ ^[0-9]+$ ]] || ed_fail 2 usage "--at needs a clip number"; at=$2; shift ;;
      --shuffle) [[ ${2:-} =~ ^(on|off)$ ]] || ed_fail 2 usage "--shuffle takes on or off"; shuffle=\"$2\"; shift ;;
      --) shift; pos+=("$@"); break ;;
      -*) ed_fail 2 usage "$ED_MEDIA_USAGE" ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  (( ${#pos[@]} >= 3 )) || ed_fail 2 usage "$ED_MEDIA_USAGE"
  name=${pos[0]} role=${pos[1]}
  case $verb in
    set) (( ${#pos[@]} == 3 )) || ed_fail 2 usage "$ED_MEDIA_USAGE"; src=${pos[2]} ;;
    clips)
      case ${pos[2]} in
        add) (( ${#pos[@]} == 4 )) || ed_fail 2 usage "$ED_MEDIA_USAGE"; src=${pos[3]}; clip=$(jq -nc --argjson at "$at" '{op: "add", at: $at}') ;;
        remove) [[ ${#pos[@]} == 4 && ${pos[3]} =~ ^[0-9]+$ ]] || ed_fail 2 usage "$ED_MEDIA_USAGE"; clip="{\"op\":\"remove\",\"n\":${pos[3]}}" ;;
        move) [[ ${#pos[@]} == 5 && ${pos[3]} =~ ^[0-9]+$ && ${pos[4]} =~ ^[0-9]+$ ]] || ed_fail 2 usage "$ED_MEDIA_USAGE"
          clip="{\"op\":\"move\",\"from\":${pos[3]},\"to\":${pos[4]}}" ;;
        order) [[ ${#pos[@]} == 4 && ${pos[3]} =~ ^[0-9]+(,[0-9]+)*$ ]] || ed_fail 2 usage "$ED_MEDIA_USAGE"
          clip=$(jq -nc --arg o "${pos[3]}" '{op: "order", order: ($o | split(",") | map(tonumber))}') ;;
        *) ed_fail 2 usage "$ED_MEDIA_USAGE" ;;
      esac ;;
    rotate)
      (( ${#pos[@]} == 3 )) || ed_fail 2 usage "$ED_MEDIA_USAGE"
      if [[ ${pos[2]} == off ]]; then rot='"off"'
      elif [[ ${pos[2]} =~ ^[0-9]+$ ]] && (( 10#${pos[2]} >= 30 && 10#${pos[2]} <= 86400 )); then rot=$((10#${pos[2]}))
      else ed_fail 2 usage "rotate takes whole seconds from 30 to 86400, or off"; fi ;;
    mode)
      (( ${#pos[@]} == 3 || ${#pos[@]} == 4 )) && [[ ${pos[2]} =~ ^(template|media)$ ]] || ed_fail 2 usage "$ED_MEDIA_USAGE"
      mode=\"${pos[2]}\" src=${pos[3]:-}
      [[ -z $src || ${pos[2]} == media ]] || ed_fail 2 usage "mode template takes no source" ;;
  esac
  ed_need_draft "$name"
  ed_need_profile
  if [[ -n $src ]]; then
    # (a refusal inside comes back as its JSON answer and exit code)
    sj=$(ed_media_src "$name" "$src" "$role") || { n=$?; [[ -z $sj ]] || printf '%s\n' "$sj"; exit "$n"; }
  fi
  [[ ! ($verb == clips && $src == none) ]] || ed_fail 2 usage "clips add takes a clip, not none"
  v=$(jq -nc --arg verb "$verb" --arg role "$role" --argjson src "$sj" --argjson all "$allf" --argjson clip "$clip" \
    --argjson rot "$rot" --argjson sh "$shuffle" --argjson mode "$mode" \
    '{verb: $verb, role: $role, src: $src, all_fans: $all, clip: $clip, rotate: $rot, shuffle: $sh, mode: $mode}')
  ed_media_run "$name" "$v" "$base"
  for n in $ED_CANCEL; do ed_cancel_job "$n"; done
  ed_with_views "$name" "$name: $verb $role (draft rev $(editor_draft_rev "$name"))" "$ws" "$(jq -nc --argjson n "$ED_NOTES" '{notes: $n}')"
}

# ---- save: the staged media into the theme (screens plan §1.4) -------------------------------
# ed_hash <file>: its sha256, cached in $CACHE/media/hashes.tsv (dev, inode,
# size, mtime, sha256, tab-separated: media.sh's media_sha256, the same file).
ed_hash() {
  local key h db=$CACHE/media/hashes.tsv
  if declare -F media_sha256 >/dev/null; then media_sha256 "$1"; return; fi
  key=$(stat -L -c '%d %i %s %Y' -- "$1" 2>/dev/null) || return 1
  key=${key// /$'\t'}
  h=$(awk -F'\t' -v k="$key" '($1 "\t" $2 "\t" $3 "\t" $4) == k { h = $5 } END { if (h != "") print h }' "$db" 2>/dev/null || true)
  if [[ -z $h ]]; then
    h=$(sha256sum <"$1" | cut -c1-64) || return 1
    mkdir -p "${db%/*}" && printf '%s\t%s\n' "$key" "$h" >>"$db" || true
  fi
  printf '%s\n' "$h"
}
# ed_stage_commit <name> <dest folder> <theme.json to install>: every staged
# file the theme names goes into <dest> under the same name (a hard link, a
# copy across filesystems). One identical to a file the theme folder already
# has is not linked: its references move to that file. The provenance
# (<dest>/src/media.json: {v: 1, files: {rel: {source, recipe, model,
# prepared}}}) is written first, tmp + mv, so a crash leaves only files the
# GC knows the editor made. <theme.json> is rewritten when a reference moves.
ed_stage_commit() {
  local name=$1 dest=$2 tj=$3 st f rel sha size c crel fin moves='{}' prov='{}' i
  local -a plan=()
  st=$(editor_draft_stage "$name")
  [[ -d $st/media ]] || return 0
  f=$(editor_draft_file "$name")
  while IFS=$'\t' read -r _ rel; do
    [[ -n $rel && $rel != /* && -f $st/$rel && ! -L $st/$rel ]] || continue
    sha=$(ed_hash "$st/$rel") || die "could not read the staged $rel"
    size=$(stat -c %s -- "$st/$rel")
    fin='' crel=''
    # the same bytes already in the theme folder?
    while IFS= read -r c; do
      [[ $(ed_hash "$c") == "$sha" ]] || continue
      crel=${c#"$dest"/}; break
    done < <(find "$dest/media" -type f -size "${size}c" 2>/dev/null | sort)
    if [[ -n $crel ]]; then
      [[ $crel == "$rel" ]] || moves=$(jq -c --arg a "$rel" --arg b "$crel" '. + {($a): $b}' <<<"$moves")
      continue
    fi
    fin=$rel i=2
    while [[ -e $dest/$fin ]]; do fin=${rel%.*}-$i.${rel##*.}; i=$((i + 1)); done
    [[ $fin == "$rel" ]] || moves=$(jq -c --arg a "$rel" --arg b "$fin" '. + {($a): $b}' <<<"$moves")
    plan+=("$rel"$'\t'"$fin")
    prov=$(jq -c --arg r "$rel" --arg n "$fin" --slurpfile d "$f" '
      . + {($n): (($d[0].media_sources // {})[$r] // {} | {source: (.source // null), recipe: (.recipe // null),
                                                          model: (.model // null), prepared: (.at // null)})}' <<<"$prov")
  done < <(ed_media_refs "$tj")
  (( ${#plan[@]} )) || [[ $moves != '{}' ]] || return 0
  if (( ${#plan[@]} )); then
    mkdir -p "$dest/src"
    jq -n --argjson p "$prov" --slurpfile o <(cat "$dest/src/media.json" 2>/dev/null || echo '{}') '
      ($o[0] | objects // {}) as $o | {v: 1} + ($o | del(.v)) | .files = ((.files | objects // {}) + $p)' >"$dest/src/media.json.$$.tmp" ||
      die "could not write $dest/src/media.json"
    mv -f "$dest/src/media.json.$$.tmp" "$dest/src/media.json" || die "could not write $dest/src/media.json"
    for i in "${plan[@]}"; do
      rel=${i%%$'\t'*} fin=${i#*$'\t'}
      mkdir -p "$(dirname "$dest/$fin")"
      ln "$st/$rel" "$dest/$fin" 2>/dev/null || cp --reflink=auto -p "$st/$rel" "$dest/$fin" ||
        die "could not put $rel into $dest"
    done
  fi
  if [[ $moves != '{}' ]]; then
    jq --argjson m "$moves" '
      def mv: if type == "object" then with_entries(
                if .key == "path" and (.value | type) == "string" and $m[.value] != null then .value = $m[.value]
                elif .key == "clips" and (.value | type) == "array" then .value |= map(if type == "string" and $m[.] != null then $m[.] else . end)
                else .value |= mv end)
              elif type == "array" then map(mv) else . end;
      .screens |= mv' "$tj" >"$tj.$$.tmp" || die "could not rewrite the theme's media references"
    mv -f "$tj.$$.tmp" "$tj"
  fi
}

# ed_view_json <name> [--fast]: the editor view (plan §1.4) of the draft, or
# of the saved theme when there is none.
ed_view_json() {
  local name=$1 f sf probs draft=false dj sj
  f=$(editor_draft_file "$name") sf=$THEME_DIR/$name/theme.json
  if [[ -f $sf ]]; then
    sj=$(jq -c --arg sha "$(ed_sha "$sf")" '{exists: true, sha256: $sha, theme: .}' "$sf") ||
      die "$sf is not valid JSON"
  else
    sj='{"exists": false, "sha256": null, "theme": null}'
  fi
  if [[ -f $f ]]; then
    draft=true
    probs=$(editor_draft_problems "$name" "${2:-}")
    dj=$f
  else
    # A stand-in draft for the saved theme; its problems are the saved ones.
    [[ -f $sf ]] || ed_fail 2 not-found "no theme and no draft called $name"
    dj=$TMP/ed-saved.json
    jq -n --arg name "$name" --arg root "$THEME_DIR/$name" --argjson s "$sj" --argjson m "$(stat -c %Y "$sf")" '
      {v: 1, name: $name, mode: "saved", from: null, rev: 0, created: null, updated: $m,
       base_sha256: $s.sha256, media_root: $root, theme: $s.theme}' >"$dj"
    probs=$( (log() { echo "pc-lights: $*" >&2; }; openrgb_py() { :; }; validate_theme "$name") 2>&1 |
             sed -n "s|^pc-lights: theme $name: ||p" || true)
  fi
  ed_jq --slurpfile d "$dj" --argjson s "$sj" --arg modes "$STRIMER_MODES" \
    --argjson refs "$(ed_refs_json "$name" "$draft")" --arg probs "$probs" '
    editor_view($d[0]; $s; $P; $M; $C; $modes; $refs + {problems: ($probs | split("\n") | map(select(. != "")))})' ||
    die "could not build the editor view of $name"
}
ed_show_view() {   # ed_show_view <name> <text line> [--fast]
  local v; v=$(ed_view_json "$1" "${3:-}") || exit 1
  if [[ -n $ED_JSON ]]; then jq -c . <<<"$v"; else
    printf '%s\n' "$2"
    jq -r '.problems[] | "  problem: \(.message)"' <<<"$v"
  fi
}

# ---- verbs ----------------------------------------------------------------------------
# theme new <name> [--from <theme>] [--palette k=HEX,...]
ed_new() {
  local name='' from='' pal='' mode=new root='' kv k v t=$TMP/ed-new.json palj='{}'
  while (( $# )); do
    case $1 in
      --from) [[ -n ${2:-} ]] || ed_fail 2 usage "--from needs a theme"; from=$2; shift ;;
      --palette) [[ -n ${2:-} ]] || ed_fail 2 usage "--palette needs primary=HEX[,secondary=HEX]..."; pal=$2; shift ;;
      --json) ED_JSON=1 ;;
      -*) ed_fail 2 usage "$ED_USAGE" ;;
      *) [[ -z $name ]] || ed_fail 2 usage "$ED_USAGE"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  ed_new_name "$name"
  ed_need_profile
  if [[ -n $pal ]]; then
    local IFS=,
    for kv in $pal; do
      k=${kv%%=*} v=${kv#*=}
      [[ $k =~ ^(primary|secondary|accent|alert)$ && $kv == *=* ]] || ed_fail 2 usage "--palette takes primary=, secondary=, accent= and alert="
      [[ $v =~ ^#?[0-9a-fA-F]{6}$ ]] || ed_fail 2 invalid "palette $k: '$v' is not 6 hex digits"
      v=${v#\#}
      palj=$(jq -c --arg k "$k" --arg v "${v,,}" '.[$k] = $v' <<<"$palj")
    done
    unset IFS
  fi
  if [[ -n $from ]]; then
    theme_exists "$from" || ed_fail 2 not-found "no theme $from"
    local sf=$THEME_DIR/$from/theme.json pf
    jq -e 'type == "object"' "$sf" >/dev/null 2>&1 || ed_fail 2 invalid "$sf is not valid JSON"
    mode=duplicate root=$THEME_DIR/$from
    if [[ $(theme_schema "$sf") == 3 ]]; then
      jq --argjson p "$palj" '.palette = ((.palette // {}) + $p)' "$sf" >"$t"
    else
      # A v2 theme converts with migrate's own to_v3 (stamped for this machine:
      # its colours were tuned by hand here).
      pf=$(theme_profile)
      MIG_M=$(mig_models | jq -c .)
      mjq --slurpfile p "$pf" --arg machine "$(jq -r '.machine.name // ""' "$pf")" --argjson pal "$palj" \
        "$MIG_JQ"'to_v3($p[0]; $machine) | .palette = ((.palette // {}) + $pal)' "$sf" >"$t" ||
        ed_fail 2 invalid "could not convert the v2 theme $from"
    fi
  else
    # Palette only: the lights follow the palette, the screens keep what they show.
    jq -n --argjson p "$palj" '{v: 3, palette: ({primary: "00e5ff", secondary: "7a1aff"} + $p)}' >"$t"
  fi
  ed_draft_lock
  [[ ! -f $(editor_draft_file "$name") ]] || ed_fail 2 exists "there are unsaved edits for a new theme called $name"
  ed_draft_new "$name" "$mode" "$from" "$root" "" "$t"
  ed_draft_unlock
  ed_show_view "$name" "$name: new theme${from:+ from $from} (draft rev 1)" --fast
}

# theme edit <name> [--fresh]
ed_edit() {
  local name='' fresh='' f sf t=$TMP/ed-edit.json
  while (( $# )); do
    case $1 in
      --fresh) fresh=1 ;;
      --json) ED_JSON=1 ;;
      -*) ed_fail 2 usage "$ED_USAGE" ;;
      *) [[ -z $name ]] || ed_fail 2 usage "$ED_USAGE"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  f=$(editor_draft_file "$name") sf=$THEME_DIR/$name/theme.json
  ed_need_profile
  if [[ -f $f && -z $fresh ]]; then
    ed_show_view "$name" "$name: resuming the draft (rev $(editor_draft_rev "$name"))" --fast
    return 0
  fi
  theme_exists "$name" || ed_fail 2 not-found "no theme $name"
  jq -e 'type == "object"' "$sf" >/dev/null 2>&1 || ed_fail 2 invalid "$sf is not valid JSON"
  [[ $(theme_schema "$sf") == 3 ]] || ed_fail 5 not-v3 "theme $name is a v2 theme: run migrate, or duplicate it (theme new <name> --from $name)"
  if ed_is_auto "$name"; then
    log "theme $name is generated by auto-theme: saving it stops its auto-refresh (duplicating it doesn't)"
  fi
  cp "$sf" "$t"
  # --fresh drops an old draft: its jobs stop, its staged media goes (below)
  local jobs='' j
  if [[ -f $f ]]; then jobs=$(ed_draft_jobs "$name"); fi
  ed_draft_lock
  rm -f "$f"
  ed_draft_new "$name" edit "" "$THEME_DIR/$name" "$(ed_sha "$sf")" "$t"
  ed_draft_unlock
  for j in $jobs; do ed_cancel_job "$j"; done
  if [[ -n $jobs || -d $(editor_draft_stage "$name") ]]; then ed_gc_draft "$name"; fi
  ed_show_view "$name" "$name: editing (draft rev 1)" --fast
}

ed_show() {
  local name=''
  while (( $# )); do
    case $1 in
      --json) ED_JSON=1 ;;
      -*) ed_fail 2 usage "$ED_USAGE" ;;
      *) [[ -z $name ]] || ed_fail 2 usage "$ED_USAGE"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  ed_need_profile
  if [[ ! -f $(editor_draft_file "$name") ]]; then
    theme_exists "$name" || ed_fail 2 not-found "no theme and no draft called $name"
    [[ $(theme_schema "$THEME_DIR/$name/theme.json") == 3 ]] || ed_fail 5 not-v3 "theme $name is a v2 theme: run migrate, or duplicate it"
  fi
  if [[ -n $ED_JSON ]]; then ed_show_view "$name" "" --fast; return 0; fi
  local v; v=$(ed_view_json "$name" --fast) || exit 1
  jq -r '"\(.name): \(if .draft then "draft rev \(.rev) (\(.mode)\(if .from then " from \(.from)" else "" end))\(if .dirty then ", unsaved edits" else "" end)" else "saved theme" end)\(if .conflict then ", SAVED FILE CHANGED since editing began" else "" end)",
    "calibration: \(.calibration.reason)",
    (.palette | to_entries[] | select(.value | has("value")) | "  palette.\(.key): \(.value.value // "-")\(if .value.set == false then " (\(.value.from // "default"))" else "" end)"),
    (.roles[] | "  \(.role) [\(.source)]: " + ([.fields | to_entries[] | select(.value | has("value")) | "\(.key) \(.value.value | if type == "array" then join(",") else tostring end)"] | join("  "))),
    "screens: \(.screens.summary)",
    (.problems[] | "  problem: \(.message)")' <<<"$v"
}

# ed_parse_value <text>: the JSON value of a "set" argument (plan §1.2).
ed_parse_value() {
  local v=$1
  if [[ $v =~ ^#?[0-9a-fA-F]{6}$ ]]; then v=${v#\#}; jq -nc --arg v "${v,,}" '$v'
  elif jq -nc --argjson v "$v" '$v' 2>/dev/null; then :
  else jq -nc --arg v "$v" '$v'; fi
}
# theme set / unset. /screens/@<role>/<field> (brightness, rotate, shuffle,
# orientation) is resolved against the draft as it is (screens plan §4.2);
# --with-screens adds the screens view to the answer.
ed_set() {
  local name='' ops=() base='' patch='' pj='' p v f cur out err ws='' pf mf code
  (( $# )) || ed_fail 2 usage "$ED_USAGE"
  name=$1; shift
  [[ -n $name && $name != -* ]] || ed_fail 2 usage "$ED_USAGE"
  while (( $# )); do
    case $1 in
      --json) ED_JSON=1 ;;
      --with-screens) ws=1 ;;
      --base-rev) [[ ${2:-} =~ ^[0-9]+$ ]] || ed_fail 2 usage "--base-rev needs a number"; base=$2; shift ;;
      --unset)
        [[ ${2:-} == /* ]] || ed_fail 2 usage "--unset needs a pointer (/palette/accent, /roles/fans.side/inner, ...)"
        ops+=("$(jq -nc --arg p "$2" '{op: "remove", path: $p}')"); shift ;;
      --patch)
        [[ -n ${2:-} ]] || ed_fail 2 usage "--patch needs a file or -"
        if [[ $2 == - ]]; then patch=$(cat); else patch=$(cat "$2" 2>/dev/null) || ed_fail 2 usage "cannot read $2"; fi
        shift ;;
      --patch-json) [[ -n ${2:-} ]] || ed_fail 2 usage "--patch-json needs a list of ops"; patch=$2; shift ;;
      /*)
        (( $# >= 2 )) || ed_fail 2 usage "$1 needs a value (null unsets it)"
        v=$(ed_parse_value "$2")
        if [[ $v == null ]]; then ops+=("$(jq -nc --arg p "$1" '{op: "remove", path: $p}')")
        else ops+=("$(jq -nc --arg p "$1" --argjson v "$v" '{op: "replace", path: $p, value: $v}')"); fi
        shift ;;
      *) ed_fail 2 usage "'$1' is not a pointer (they start with /: /palette/primary, /roles/fans.side/inner)" ;;
    esac
    shift
  done
  if [[ -n $patch ]]; then
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$patch" || ed_fail 2 usage "a patch is a JSON list of {op, path, value}"
    ops+=("$(jq -c '.[]' <<<"$patch")")
  fi
  (( ${#ops[@]} )) || ed_fail 2 usage "nothing to set"
  pj=$(printf '%s\n' "${ops[@]}" | jq -sc .)
  ed_need_draft "$name"
  ed_need_profile
  f=$(editor_draft_file "$name")
  ed_draft_lock
  cur=$(jq -r '.rev // 0' "$f")
  if [[ -n $base && $base != "$cur" ]]; then
    ed_fail 2 stale-rev "the draft of $name is at rev $cur, not $base; reload it"
  fi
  pf=$(theme_profile) mf=$(theme_models)
  if ! out=$(jq --argjson ops "$pj" --argjson now "$EPOCHSECONDS" -L "$PCL_LIB" \
      --slurpfile pcl_p <([[ -f $pf ]] && cat "$pf" || echo null) \
      --slurpfile pcl_m <([[ -f $mf ]] && cat "$mf" || echo '{}') \
      'include "theme"; '"$(<"$PCL_LIB/editor.jq")"'
      $pcl_p[0] as $P | $pcl_m[0] as $M
      | .theme |= apply_ops($ops; $P; $M) | .rev = ((.rev // 0) + 1) | .updated = $now' "$f" 2>"$TMP/ed-set.err"); then
    err=$(sed -n 's/^jq: error ([^)]*): //p' "$TMP/ed-set.err" | head -1)
    code=invalid
    if [[ $err == no-role:* ]]; then code=no-role err=${err#no-role: }; fi
    ed_fail 2 "$code" "${err:-could not apply the edit}"
  fi
  ed_draft_write "$name" <<<"$out"
  ed_draft_unlock
  if [[ -n $ws && -n $ED_JSON ]]; then ed_with_views "$name" "$name: draft rev $((cur + 1))" 1; return 0; fi
  ed_show_view "$name" "$name: draft rev $((cur + 1))" --fast
}

ed_drafts() {
  [[ ${1:-} == --json ]] && ED_JSON=1
  local d; d=$(editor_drafts_json)
  ed_out "{\"drafts\": $d}" "$(jq -r 'if length == 0 then "no drafts" else .[] | "\(.name)\t\(.mode)\(if .from then " from \(.from)" else "" end)\trev \(.rev)" end' <<<"$d")"
}

ed_discard() {
  local name=''
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) name=$1 ;; esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  ed_need_draft "$name"
  local jobs j
  jobs=$(ed_draft_jobs "$name")
  ed_draft_lock
  rm -f "$(editor_draft_file "$name")" "$CACHE"/compiled/draft-"$name".*.json
  ed_draft_unlock
  # Its jobs stop, its stage goes (unless the preview still shows from it).
  for j in $jobs; do ed_cancel_job "$j"; done
  ed_gc_draft "$name"
  ed_out "$(jq -nc --arg n "$name" '{discarded: true, name: $n}')" "$name: unsaved edits discarded"
}

# theme revert <name>: back to saved, as a new rev (so a live preview follows).
ed_revert() {
  local name='' f mode from t=$TMP/ed-revert.json sf
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) name=$1 ;; esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  ed_need_draft "$name"
  ed_need_profile
  f=$(editor_draft_file "$name")
  mode=$(jq -r .mode "$f") from=$(jq -r '.from // empty' "$f")
  case $mode in
    edit)
      sf=$THEME_DIR/$name/theme.json
      [[ -f $sf ]] || ed_fail 2 not-found "theme $name is gone; discard the draft or save it"
      ed_draft_lock
      jq --slurpfile t "$sf" --arg sha "$(ed_sha "$sf")" --argjson now "$EPOCHSECONDS" \
        '.theme = $t[0] | .base_sha256 = $sha | .rev = ((.rev // 0) + 1) | .updated = $now' "$f" >"$t"
      ed_draft_write "$name" <"$t"
      ed_draft_unlock ;;
    duplicate)
      if [[ -z $from ]] || ! theme_exists "$from"; then ed_fail 2 not-found "the theme it was copied from ($from) is gone"; fi
      [[ $(theme_schema "$THEME_DIR/$from/theme.json") == 3 ]] ||
        ed_fail 2 usage "$name was converted from a v2 theme; discard it and duplicate $from again"
      ed_draft_lock
      jq --slurpfile t "$THEME_DIR/$from/theme.json" --argjson now "$EPOCHSECONDS" \
        '.theme = $t[0] | .rev = ((.rev // 0) + 1) | .updated = $now' "$f" >"$t"
      ed_draft_write "$name" <"$t"
      ed_draft_unlock ;;
    *) ed_fail 2 usage "$name is a new theme: there is no saved version to go back to (theme discard $name drops it)" ;;
  esac
  ed_show_view "$name" "$name: back to saved (draft rev $(editor_draft_rev "$name"))" --fast
}

# ed_backup <name>: link the current theme.json into the history (the old
# inode: the save then puts a new one in place); prints the entry. Keeps
# ED_HISTORY_KEEP entries (so never the newest 5).
ed_backup() {
  local name=$1 f=$THEME_DIR/$1/theme.json dir sha out drop
  [[ -f $f ]] || return 0
  dir=$STATE_DIR/theme-history/$name
  mkdir -p "$dir"
  sha=$(ed_sha "$f")
  out=$dir/$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}.json
  if [[ ! -e $out ]]; then ln "$f" "$out" 2>/dev/null || cp -p "$f" "$out" || die "could not back up $f"; fi
  mapfile -t drop < <(find "$dir" -maxdepth 1 -name '*.json' -printf '%f\n' | sort -r | tail -n +$((ED_HISTORY_KEEP + 1)))
  for f in "${drop[@]}"; do rm -f "${dir:?}/$f"; done
  echo "$out"
}
# ed_install <src json> <dest theme.json>: pretty, a new inode (tmp + mv in
# the theme folder), keeping the old file's mode.
ed_install() {
  local tmp=${2%/*}/theme.json.$$.tmp
  if ! jq . "$1" >"$tmp" || [[ ! -s $tmp ]]; then rm -f "$tmp"; die "could not write $2"; fi
  if [[ -e $2 ]]; then chmod --reference="$2" "$tmp"; fi
  mv -f "$tmp" "$2"
}
# ed_queue_pick <name>: "Save and apply": the same queued pick the UI uses.
ed_queue_pick() { "$(readlink -f "$0")" --detach pick "$1"; }
# ed_preview_done <draft name> <apply>: end a live preview of this draft
# after a save (package B's preview_yield: reason "saved", no revert when
# the save applies; nothing when the preview module isn't there or the
# session shows another draft).
ed_preview_done() {
  [[ $(type -t preview_live) == function && $(type -t preview_yield) == function ]] || return 1
  preview_live || return 1
  [[ $(jq -r '.theme // empty' "$CACHE/preview.json" 2>/dev/null || true) == "$1" ]] || return 1
  if [[ -n $2 ]]; then preview_yield saved "$1" --no-revert || true; else preview_yield saved "$1" || true; fi
}

# ed_pending_running <name>: the roles whose media is still being prepared
# (a pending job queued, waiting, probing, estimating, encoding or finishing).
ed_pending_running() {
  local role id st
  while IFS=$'\t' read -r role id; do
    [[ -n $id ]] || continue
    st=$(jq -r '.state // empty' "$(ed_job_file "$id")" 2>/dev/null || true)
    case $st in queued | waiting | probing | estimating | encoding | finishing) printf '%s\n' "$role" ;; esac
  done < <(jq -r '.pending_media // {} | objects | to_entries[] | "\(.key)\t\(.value)"' "$(editor_draft_file "$1")" 2>/dev/null || true)
}

# theme save <name> [--as <new>] [--apply|--no-apply] [--force]
ed_save() {
  local name='' as='' apply=auto force='' f mode root target sf cur base probs hist='' created=false
  while (( $# )); do
    case $1 in
      --as) [[ -n ${2:-} ]] || ed_fail 2 usage "--as needs a name"; as=$2; shift ;;
      --apply) apply=1 ;;
      --no-apply) apply='' ;;
      --force) force=1 ;;
      --json) ED_JSON=1 ;;
      -*) ed_fail 2 usage "$ED_USAGE" ;;
      *) [[ -z $name ]] || ed_fail 2 usage "$ED_USAGE"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  ed_need_draft "$name"
  ed_need_profile
  f=$(editor_draft_file "$name")
  mode=$(jq -r .mode "$f") root=$(jq -r '.media_root // empty' "$f") base=$(jq -r '.base_sha256 // empty' "$f")
  target=${as:-$name}
  if [[ -n $as ]]; then ed_new_name "$as"; fi
  # 0. media still being prepared for the draft: the save waits for it
  # (--force saves without it; its jobs are stopped after the save)
  local busy
  busy=$(ed_pending_running "$name")
  if [[ -n $busy && -z $force ]]; then
    ed_fail 2 media-pending "media for $(paste -sd, <<<"$busy" | sed 's/,/, /g') is still being prepared; save when it is done (or --force)"
  fi
  # 1. the full validation (with OpenRGB) on the draft
  probs=$(editor_draft_problems "$name")
  if [[ -n $probs ]]; then
    ed_fail 2 invalid "the draft of $name has $(wc -l <<<"$probs") problem(s); nothing saved" \
      "$(ed_jq --arg p "$probs" --slurpfile d "$f" \
         '[$p | split("\n")[] | select(. != "") | {path: ed_problem_path($d[0].theme), level: "error", message: .}]')"
  fi
  sf=$THEME_DIR/$target/theme.json
  if [[ -z $as && $mode == edit ]]; then
    # 2+3. an existing theme: same bytes as when editing began, or --force
    [[ -f $sf ]] || ed_fail 2 not-found "theme $name is gone; save it under another name (--as)"
    cur=$(ed_sha "$sf")
    if [[ $cur != "$base" && -z $force ]]; then
      ed_fail 4 conflict "theme $name changed on disk since editing began; save with --force to overwrite it, or --as <new name>"
    fi
    if [[ -n $(ed_refs "$name") ]]; then ed_lock; fi
    # The drafts lock from here to the install: a job's apply or the media GC
    # waits (always the main lock first, then this one).
    ed_draft_lock
    jq '.theme' "$f" >"$TMP/ed-save.json"
    hist=$(ed_backup "$name")
    # The staged media first (screens plan §1.4): linked in under new names,
    # provenance written before the links, theme.json last.
    ed_stage_commit "$name" "$THEME_DIR/$name" "$TMP/ed-save.json"
    ed_install "$TMP/ed-save.json" "$sf"
    ed_draft_unlock
  else
    # 4. a new folder: built beside the others as .new-<name>.<pid>, the media
    # root's files linked in (never src/source.json: auto-theme must not adopt
    # it), then moved into place in one step.
    [[ ! -e $THEME_DIR/$target ]] || ed_fail 2 exists "a theme called $target already exists"
    local nd=$THEME_DIR/.new-$target.$$ e
    ed_draft_lock
    jq '.theme' "$f" >"$TMP/ed-save.json"
    mkdir -p "$THEME_DIR"; rm -rf "$nd"; mkdir "$nd"
    if [[ -n $root && -d $root ]]; then
      for e in "$root"/* "$root"/.[!.]*; do
        [[ -e $e || -L $e ]] || continue
        case ${e##*/} in theme.json | theme.json.*.tmp) continue ;; esac
        cp -al "$e" "$nd/" 2>/dev/null || cp -a --reflink=auto "$e" "$nd/" || { rm -rf "$nd"; die "could not copy $e"; }
      done
      rm -f "$nd/src/source.json"
    fi
    # The staged media into the new folder (its src/media.json is a new file,
    # never the source theme's through a hard link).
    ed_stage_commit "$name" "$nd" "$TMP/ed-save.json" || { rm -rf "$nd"; exit 1; }
    ed_install "$TMP/ed-save.json" "$nd/theme.json"
    if ! mv -T "$nd" "$THEME_DIR/$target" 2>/dev/null; then
      rm -rf "$nd"; ed_fail 2 exists "a theme called $target appeared meanwhile; nothing saved"
    fi
    ed_draft_unlock
    created=true
  fi
  drop_lock
  # 6. the preview: "Save and apply" persists the look with a queued pick
  # (default when the saved theme is the active one and the lights are on).
  if [[ $apply == auto ]]; then
    apply=''
    if [[ $target == "$(active_name)" && $(lights_state) == on ]]; then apply=1; fi
  fi
  local ended=false queued=null
  if ed_preview_done "$name" "$apply"; then ended=true; fi
  if [[ -n $apply ]]; then
    queued=$(ed_queue_pick "$target" 2>/dev/null | tail -n1) || true
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$queued" || queued='{"queued": false}'
  fi
  # 7. the draft is done: its jobs (a forced save) stop, its stage goes
  local jobs j
  jobs=$(ed_draft_jobs "$name")
  ed_draft_lock
  rm -f "$f" "$CACHE"/compiled/draft-"$name".*.json
  ed_draft_unlock
  for j in $jobs; do ed_cancel_job "$j"; done
  ed_gc_draft "$name"
  ed_out "$(jq -nc --arg n "$target" --arg sha "$(ed_sha "$sf")" --arg h "$hist" --argjson c "$created" \
      --argjson q "$queued" --argjson e "$ended" "$nul_jq"'
      {saved: true, name: $n, sha256: $sha, created: $c, history: ($h | n), preview_ended: $e, apply: $q}')" \
    "$target: saved${hist:+ (the old file is in $hist)}$([[ $queued != null ]] && echo "; applying")"
}

ed_trash_stamp() { date +%Y%m%d-%H%M%S; }
# theme delete <name>: to the trash, unless something points at it.
ed_delete() {
  local name='' refs dest
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) name=$1 ;; esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  [[ $name =~ ^[A-Za-z0-9._-]+$ && -d $THEME_DIR/$name ]] || ed_fail 2 not-found "no theme $name"
  refs=$(ed_refs "$name")
  if [[ -n $refs ]]; then
    ed_fail 2 in-use "$name is in use ($(paste -sd, <<<"$refs" | sed 's/,/, /g')); pick another theme there first" \
      "$(jq -Rn '[inputs | select(. != "") | {path: null, level: "error", message: .}]' <<<"$refs")"
  fi
  ed_lock
  local jobs j
  jobs=$(ed_draft_jobs "$name")
  dest=$STATE_DIR/themes.trash/$name-$(ed_trash_stamp)
  mkdir -p "${dest%/*}"
  [[ ! -e $dest ]] || dest=$dest-$$
  mv -T "$THEME_DIR/$name" "$dest" || die "could not move $THEME_DIR/$name to the trash"
  rm -f "$(editor_draft_file "$name")" "$PREVIEWS/$name".* "$CACHE"/compiled/"$name".*.json
  drop_lock
  # Its draft's jobs stop and its stage goes.
  for j in $jobs; do ed_cancel_job "$j"; done
  ed_gc_draft "$name"
  ed_out "$(jq -nc --arg n "$name" --arg d "$dest" '{deleted: true, name: $n, trash: $d}')" "$name: moved to $dest"
}

# ed_rewrite <file> <old> <new> <jq filter>: the file with the old name
# swapped for the new one only where the filter says, byte for byte
# elsewhere (a text swap of the value, checked against the jq result; jq's
# own output when the text swap doesn't match). tmp + mv. Prints the file
# when it changed.
ed_rewrite() {
  local file=$1 o=$2 n=$3 filter=$4 want tmp=$1.$$.tmp re
  [[ -f $file ]] || return 0
  want=$(jq -c --arg o "$o" --arg n "$n" "$filter" "$file" 2>/dev/null) || return 0
  [[ $want != "$(jq -c . "$file")" ]] || return 0
  re=${o//./\\.}
  sed -E "s/(:[[:space:]]*)\"$re\"/\\1\"$n\"/g" "$file" >"$tmp"
  if [[ $(jq -c . "$tmp" 2>/dev/null) != "$want" ]]; then jq --arg o "$o" --arg n "$n" "$filter" "$file" >"$tmp"; fi
  chmod --reference="$file" "$tmp"
  mv -f "$tmp" "$file"
  echo "$file"
}
# ed_rename_jobs <old> <new>: the media job records of draft <old> name
# draft <new> and its stage (tmp + mv each).
ed_rename_jobs() {
  local o=$1 n=$2 j os ns
  os=$STATE_DIR/drafts/$o.media/ ns=$STATE_DIR/drafts/$n.media/
  for j in "$CACHE"/media/jobs/*.json; do
    [[ -f $j ]] || continue
    jq -e --arg o "$o" '.draft == $o' "$j" >/dev/null 2>&1 || continue
    jq --arg n "$n" --arg os "$os" --arg ns "$ns" '.draft = $n
      | if (.output | objects | .abs | strings | startswith($os)) then .output.abs = $ns + (.output.abs | ltrimstr($os)) else . end' \
      "$j" >"$j.$$.tmp" || { rm -f "$j.$$.tmp"; continue; }
    mv -f "$j.$$.tmp" "$j"
  done
}
# theme rename <old> <new>: the folder and every reference to it.
ed_rename() {
  local old='' new='' args=() f e changed=() d
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) args+=("$1") ;; esac
    shift
  done
  (( ${#args[@]} == 2 )) || ed_fail 2 usage "$ED_USAGE"
  old=${args[0]} new=${args[1]}
  theme_exists "$old" || ed_fail 2 not-found "no theme $old"
  if ed_is_auto "$old"; then ed_fail 2 bad-name "$old is generated by auto-theme and can't be renamed; duplicate it instead"; fi
  ed_new_name "$new"
  ed_lock
  mv -T "$THEME_DIR/$old" "$THEME_DIR/$new" || die "could not rename $THEME_DIR/$old"
  for f in "$STATE_DIR/scheme" "$DAY_SCHEME"; do
    if [[ -f $f && $(<"$f") == "$old" ]]; then
      printf '%s\n' "$new" >"$f.$$.tmp" && chmod --reference="$f" "$f.$$.tmp" && mv -f "$f.$$.tmp" "$f"
      changed+=("$f")
    fi
  done
  mapfile -t -O "${#changed[@]}" changed < <(
    ed_rewrite "$SCHED" "$old" "$new" 'if .night_theme == $o then .night_theme = $n else . end'
    ed_rewrite "$STATE_DIR/omarchy-map.json" "$old" "$new" 'with_entries(if .value == $o then .value = $n else . end)'
    ed_rewrite "$CACHE/clips.json" "$old" "$new" 'if .theme == $o then .theme = $n else . end')
  # Drafts: its own, and the media root of any copy of it.
  ed_draft_lock
  for f in "$STATE_DIR"/drafts/*.json; do
    [[ -f $f ]] || continue
    jq --arg o "$old" --arg n "$new" --arg or "$THEME_DIR/$old" --arg nr "$THEME_DIR/$new" '
      (if .name == $o then .name = $n else . end)
      | (if .from == $o then .from = $n else . end)
      | (if .media_root == $or then .media_root = $nr else . end)' "$f" >"$TMP/ed-rn.json" || continue
    if [[ ${f##*/} == "$old.json" ]]; then
      ed_draft_write "$new" <"$TMP/ed-rn.json"; rm -f "$f"; changed+=("$(editor_draft_file "$new")")
      # Its staged media and its jobs follow (screens plan §6.11).
      if [[ -d $STATE_DIR/drafts/$old.media && ! -e $STATE_DIR/drafts/$new.media ]]; then
        mv -T "$STATE_DIR/drafts/$old.media" "$STATE_DIR/drafts/$new.media" && changed+=("$STATE_DIR/drafts/$new.media")
        if declare -F media_rename_draft >/dev/null; then (media_rename_draft "$old" "$new") >/dev/null 2>&1 || true
        else ed_rename_jobs "$old" "$new"; fi
      fi
    elif ! cmp -s <(jq -c . "$f") <(jq -c . "$TMP/ed-rn.json"); then
      ed_draft_write "${f##*/}" <"$TMP/ed-rn.json"; changed+=("$f")
    fi
  done
  ed_draft_unlock
  # The history, the preview images, the compiled copies.
  d=$STATE_DIR/theme-history
  if [[ -d $d/$old ]]; then
    if [[ -e $d/$new ]]; then mv -n "$d/$old"/* "$d/$new/" 2>/dev/null || true; rmdir "$d/$old" 2>/dev/null || true
    else mv -T "$d/$old" "$d/$new"; fi
    changed+=("$d/$new")
  fi
  for e in "$PREVIEWS/$old".*; do
    [[ -f $e ]] || continue
    mv -f "$e" "$PREVIEWS/$new.${e##*/"$old".}"; changed+=("$PREVIEWS/$new.${e##*/"$old".}")
  done
  rm -f "$CACHE"/compiled/"$old".*.json
  drop_lock
  ed_out "$(jq -nc --arg o "$old" --arg n "$new" '{renamed: true, from: $o, to: $n, updated: $ARGS.positional}' --args "${changed[@]}")" \
    "$old: renamed to $new${changed[*]:+ (updated ${#changed[@]} reference(s))}"
}

ed_history() {
  local name='' dir
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) name=$1 ;; esac
    shift
  done
  [[ -n $name ]] || ed_fail 2 usage "$ED_USAGE"
  dir=$STATE_DIR/theme-history/$name
  local list
  list=$(find "$dir" -maxdepth 1 -name '*.json' -printf '%f\t%s\t%T@\n' 2>/dev/null | sort -r |
    jq -Rsc --arg d "$dir" --arg n "$name" '{name: $n, entries: [split("\n")[] | select(. != "") | split("\t")
      | {stamp: (.[0] | split("-")[0]), sha12: (.[0] | rtrimstr(".json") | split("-")[1]), file: "\($d)/\(.[0])",
         bytes: (.[1] | tonumber), mtime: (.[2] | tonumber | floor)}]}')
  ed_out "$list" "$(jq -r 'if (.entries | length) == 0 then "no history for \(.name)" else .entries[] | "\(.stamp)  \(.sha12)  \(.bytes) bytes" end' <<<"$list")"
}

# theme restore <name> <stamp>: a history entry back as the theme, through
# a save (the current file goes to the history first).
ed_restore() {
  local args=() name stamp dir m sf hist
  while (( $# )); do
    case $1 in --json) ED_JSON=1 ;; -*) ed_fail 2 usage "$ED_USAGE" ;; *) args+=("$1") ;; esac
    shift
  done
  (( ${#args[@]} == 2 )) || ed_fail 2 usage "$ED_USAGE"
  name=${args[0]} stamp=${args[1]}
  theme_exists "$name" || ed_fail 2 not-found "no theme $name"
  [[ $stamp =~ ^[0-9]{8}T[0-9]{6}Z(-[0-9a-f]{12})?$ ]] || ed_fail 2 usage "a stamp looks like 20260924T120000Z (see theme history $name)"
  dir=$STATE_DIR/theme-history/$name
  mapfile -t m < <(find "$dir" -maxdepth 1 -name "$stamp*.json" 2>/dev/null | sort)
  (( ${#m[@]} == 1 )) || ed_fail 2 not-found "$(( ${#m[@]} )) history entries of $name match $stamp"
  jq -e 'type == "object"' "${m[0]}" >/dev/null 2>&1 || ed_fail 2 invalid "${m[0]} is not valid JSON"
  sf=$THEME_DIR/$name/theme.json
  if [[ -n $(ed_refs "$name") ]]; then ed_lock; fi
  hist=$(ed_backup "$name")
  ed_install "${m[0]}" "$sf"
  drop_lock
  ed_out "$(jq -nc --arg n "$name" --arg f "${m[0]}" --arg h "$hist" '{restored: true, name: $n, from: $f, history: $h}')" \
    "$name: restored from ${m[0]##*/} (the replaced file is in $hist)"
}

# ---- the "theme" command (the core routes every verb but preview here) ------------------
editor_cmd() {
  local verb=${1:-}
  (( $# )) && shift
  ED_JSON=
  case $verb in
    new) ed_new "$@" ;;
    duplicate)
      (( $# >= 2 )) && [[ $1 != -* && $2 != -* ]] || ed_fail 2 usage "$ED_USAGE"
      local from=$1 to=$2; shift 2
      ed_new "$to" --from "$from" "$@" ;;
    edit) ed_edit "$@" ;;
    show) ed_show "$@" ;;
    set) ed_set "$@" ;;
    unset)
      (( $# >= 2 )) || ed_fail 2 usage "$ED_USAGE"
      local n=$1 a=(); shift
      while (( $# )); do if [[ $1 == /* ]]; then a+=(--unset "$1"); else a+=("$1"); fi; shift; done
      ed_set "$n" "${a[@]}" ;;
    drafts) ed_drafts "$@" ;;
    discard) ed_discard "$@" ;;
    revert) ed_revert "$@" ;;
    save) ed_save "$@" ;;
    delete) ed_delete "$@" ;;
    rename) ed_rename "$@" ;;
    history) ed_history "$@" ;;
    restore) ed_restore "$@" ;;
    screens) ed_screens_cmd "$@" ;;
    media) ed_media "$@" ;;
    *) ed_fail 2 usage "$ED_USAGE" ;;
  esac
}
