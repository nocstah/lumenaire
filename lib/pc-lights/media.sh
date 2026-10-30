# lib/pc-lights/media.sh — screen media: list, probe, crop frames, thumbnails,
# prepare jobs and GC (screens plan §1.1-§1.4, §2; docs/MEDIA.md)
#
# Sourced by bin/lumenaire right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. A plain source reads only the
# part above "the entry points" (constants, stand-ins, thin entry points):
# the body loads on first use (md_load), so the commands that never touch
# media don't pay for parsing it. Globals it reads (CACHE,
# STATE_DIR, THEME_DIR, CFG_LIVE, TPL_LIVE, TMP, ...) and helpers (die, log,
# put_json, nul_jq, theme_profile, theme_models, ...) live in the core and the
# other modules.
#
# Owner: screens plan §8 B1 (media pipeline)
# Public: media_cmd media_probe_json media_probe_many media_thumb media_job_file
#         media_jobs_json media_cancel_job media_gc_draft media_gc media_capped
#         media_sha256 media_rename_draft; constants MEDIA_DIR MEDIA_JOBS
# Uses (B2, lib/pc-lights/editor.sh): editor_draft_stage editor_draft_abspath
#         editor_media_pending editor_media_apply, and editor_draft_file
#         editor_draft_rev editor_media_root (stand-ins that die "not
#         implemented" are defined below while editor.sh doesn't provide them).
# The jq half is lib/pc-lights/media.jq, loaded with media_jq.
# The whole engine is checked from bin/lumenaire; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154
# (file-wide: SC2016, the single-quoted $x are jq's, not the shell's)
# shellcheck disable=SC2016
#
# Storage (plan §1.1):
#   $STATE_DIR/drafts/<name>.media/media/<stem>-<sha8>.<ext>   staged outputs (B2's stage)
#   $CACHE/media/jobs/<id>.json      job records (tmp + mv), <id>.cancel while a cancel runs
#   $CACHE/media/work/<id>/          a job's scratch (removed when it ends)
#   $CACHE/media/index.jsonl         probe records (append, last line wins; compacted)
#   $CACHE/media/index.want          paths the indexer should look at first (NUL-separated)
#   $CACHE/media/thumb.want          thumbnails asked for (NUL-separated; drained)
#   $CACHE/media/index.stamp         touched whenever the index or a thumbnail changes
#   $CACHE/thumbs/<k:0:2>/<k>.webp   thumbnails, k = sha1(path \0 size \0 mtime); <k>.fail
#   $CACHE/media/frames/<k>/<ms>-<max>.jpg   crop frames
#   $CACHE/media/hashes.tsv          dev ino size mtime sha256
# Locks: media/index.lock (one indexer), media/index.write.lock (index and
# want writes), media/jobs/.lock (a record's read-modify-write), and B2's
# drafts/.lock around every deletion GC makes in a stage or a theme.

MEDIA_DIR=$CACHE/media
MEDIA_JOBS=$MEDIA_DIR/jobs
MEDIA_WORK=$MEDIA_DIR/work
MEDIA_FRAMES=$MEDIA_DIR/frames
MEDIA_INDEX=$MEDIA_DIR/index.jsonl
MEDIA_THUMBS=$CACHE/thumbs
MEDIA_UNIT=${PCL_MEDIA_UNIT:-lumenaire-media}
# Bumped when a recipe's output would change for the same inputs (recipe keys).
MEDIA_PREP_VERSION=1
# The folders a library never lists (L-Connect's caches and device streams).
MEDIA_SKIP_DIRS=(temp template modulars preview thumbnail overlay-snapshots color-analysis-cache)
MEDIA_EXTS=(mp4 m4v mov mkv webm avi gif png jpg jpeg webp bmp tif tiff heic heif avif)
# A list reads at most this many files (then "truncated"); thumbnails are
# kept to this many bytes (oldest first out). Tests lower both.
MEDIA_LIST_CAP=${PCL_MEDIA_LIST_CAP:-5000}
MEDIA_THUMB_CAP=${PCL_MEDIA_THUMB_CAP:-314572800}
MEDIA_USAGE='usage: lumenaire media list --for <role|model> [--source theme:<name>|library|files] [--draft <name>]
                            [--query <text>] [--offset N] [--limit N] --json
       lumenaire media probe <file> --json
       lumenaire media frame <file> [--time <s>] [--max <px>] --json
       lumenaire media thumb <file>... [--now] --json
       lumenaire media prepare <file> --for <role|model> (--draft <name> [--then set|clip-add|none] [--at N] | --out <file>)
                               [--crop x,y,w,h] [--time <s>] [--start <s>] [--duration <s>] [--json]
       lumenaire media jobs [--draft <name>] [--all] --json
       lumenaire media cancel <job-id> [--json]
       lumenaire media gc [--dry-run] [--json]'

# ---- B2's draft functions: stand-ins until editor.sh defines them ------------------
# (editor_draft_stage <name> [--create]: the stage folder, drafts/<name>.media;
#  editor_draft_abspath <name> <rel>: the stage's file, else the media root's;
#  editor_media_pending <name> <role> <job> [<only-if>]: pending_media[role] =
#  job ("" clears it; <only-if>: only while it is that job), prints the job it
#  replaced; editor_media_apply <name> <jobfile>: a finished job into the
#  draft as its "then" says: 0 applied (the new rev on stdout), 1 superseded
#  or no draft, 2 not applied (why on stderr).)
md_standin() { die "$1: not implemented (lib/pc-lights/editor.sh does not provide it yet)"; }
PCL_MEDIA_EDITOR_STUBBED=
if ! declare -F editor_draft_stage >/dev/null; then PCL_MEDIA_EDITOR_STUBBED=1; editor_draft_stage() { md_standin editor_draft_stage; }; fi
if ! declare -F editor_draft_abspath >/dev/null; then PCL_MEDIA_EDITOR_STUBBED=1; editor_draft_abspath() { md_standin editor_draft_abspath; }; fi
if ! declare -F editor_media_pending >/dev/null; then PCL_MEDIA_EDITOR_STUBBED=1; editor_media_pending() { md_standin editor_media_pending; }; fi
if ! declare -F editor_media_apply >/dev/null; then PCL_MEDIA_EDITOR_STUBBED=1; editor_media_apply() { md_standin editor_media_apply; }; fi
if ! declare -F editor_draft_file >/dev/null; then editor_draft_file() { echo "$STATE_DIR/drafts/$1.json"; }; fi
if ! declare -F editor_draft_rev >/dev/null; then editor_draft_rev() { jq -r '.rev // 0' "$STATE_DIR/drafts/$1.json" 2>/dev/null; }; fi
if ! declare -F editor_media_root >/dev/null; then editor_media_root() { jq -r '.media_root // empty' "$STATE_DIR/drafts/$1.json" 2>/dev/null || true; }; fi

# ---- the entry points: the body below loads on first use ---------------------------
# Every engine command sources this file; only a few need the pipeline. So a
# plain source stops at the "return" below (no side effect, nothing parsed
# after it) and leaves these entry points, which load the rest (md_load: the
# file again, to the end) and call the real function. A test hook that
# replaces a media internal calls md_load first.
# (kept as they are when md_load reads the file again)
: "${MD_LOADED:=}" "${MD_LOADING:=}"
md_load() {
  [[ -z $MD_LOADED ]] || return 0
  MD_LOADED=1 MD_LOADING=1
  # shellcheck source=/dev/null
  source "$PCL_LIB/media.sh"
  MD_LOADING=''
  # never an entry point calling itself for ever
  if [[ $(declare -f media_cmd) == *md_load* ]]; then die "media: could not load $PCL_LIB/media.sh"; fi
}
media_cmd() { md_load; media_cmd "$@"; }
media_probe_json() { md_load; media_probe_json "$@"; }
media_probe_many() { md_load; media_probe_many "$@"; }
media_thumb() { md_load; media_thumb "$@"; }
media_job_file() { md_load; media_job_file "$@"; }
media_jobs_json() { md_load; media_jobs_json "$@"; }
media_cancel_job() { md_load; media_cancel_job "$@"; }
media_gc_draft() { md_load; media_gc_draft "$@"; }
media_gc() { md_load; media_gc "$@"; }
media_capped() { md_load; media_capped "$@"; }
media_sha256() { md_load; media_sha256 "$@"; }
media_rename_draft() { md_load; media_rename_draft "$@"; }
[[ -n $MD_LOADING ]] || return 0

# ---- errors, jq, small helpers ------------------------------------------------------------
# md_fail <rc> <code> <message>: the error object on stdout ({error, code},
# plan §1.2), the message on stderr, exit <rc> (2 bad input, 3 systemd-run,
# 5 not editable).
MD_JSON=
md_fail() {
  echo "pc-lights: $3" >&2
  jq -nc --arg e "$3" --arg c "$2" '{error: $e, code: $c}'
  exit "$1"
}
# md_out <json> <text>: the JSON with --json, the text line otherwise.
md_out() { if [[ -n $MD_JSON ]]; then jq -c . <<<"$1"; else printf '%s\n' "$2"; fi; }
# media_jq <jq args...> <filter>: jq -n with theme.jq and media.jq loaded
# (media.jq spliced in as text, like editor.jq) and $P (profile), $M (models).
media_jq() {
  local f=${*: -1} pf mf
  pf=$(theme_profile) mf=$(theme_models)
  jq -n -L "$PCL_LIB" "${@:1:$#-1}" \
    --slurpfile md_p <([[ -f $pf ]] && cat "$pf" || echo null) \
    --slurpfile md_m <([[ -f $mf ]] && cat "$mf" || echo '{}') \
    'include "theme"; '"$(<"$PCL_LIB/media.jq")"'
    $md_p[0] as $P | $md_m[0] as $M | '"$f"
}
md_is_final() { [[ $1 == "done" || $1 == "failed" || $1 == "cancelled" ]]; }
# md_stat <path>: "size mtime" of a regular file (links followed); 1 otherwise.
md_stat() { local s; s=$(stat -Lc '%s %Y' -- "$1" 2>/dev/null) || return 1; [[ -f $1 ]] || return 1; echo "$s"; }
# md_key <path> <size> <mtime>: sha1(path \0 size \0 mtime), the thumbnail and frame key.
md_key() { printf '%s\0%s\0%s' "$1" "$2" "$3" | sha1sum | cut -c1-40; }
md_thumb_path() { echo "$MEDIA_THUMBS/${1:0:2}/$1.webp"; }
# md_bytes <size>: "4G", "512M" or bytes -> bytes.
md_bytes() { numfmt --from=iec "${1%[Bb]}" 2>/dev/null || echo "${1//[!0-9]/}"; }
md_num_ok() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
md_int_ok() { [[ $1 =~ ^[0-9]+$ ]]; }
# md_tools_missing: the media tools this machine lacks, one per line.
md_tools_missing() { local t; for t in ffmpeg ffprobe magick; do command -v "$t" >/dev/null 2>&1 || echo "$t"; done; }
md_need_tools() {
  local m; m=$(md_tools_missing | paste -sd' ' -)
  [[ -z $m ]] || md_fail 2 missing-tool "screen editing needs ffmpeg and ImageMagick (missing: $m)"
}
# md_job_mem: a job unit's MemoryMax: PCL_MEDIA_MEM, else a quarter of the RAM, 1-4 GiB.
md_job_mem() {
  if [[ -n ${PCL_MEDIA_MEM:-} ]]; then echo "$PCL_MEDIA_MEM"; return 0; fi
  awk '/^MemTotal:/ { m = $2 * 1024 / 4; if (m < 2^30) m = 2^30; if (m > 4 * 2^30) m = 4 * 2^30; printf "%d\n", m; f = 1 }
       END { if (!f) print 2^30 }' /proc/meminfo 2>/dev/null || echo 1073741824
}
md_threads() { local n; n=$(nproc 2>/dev/null || echo 2); n=$((n / 2)); (( n < 1 )) && n=1; (( n > 8 )) && n=8; echo "$n"; }
# md_free <path>: free bytes where <path> (or its nearest existing parent) lives.
md_free() {
  local d=$1
  if [[ -n ${PCL_MEDIA_FREE_BYTES:-} ]]; then echo "$PCL_MEDIA_FREE_BYTES"; return 0; fi
  while [[ ! -d $d && $d == */* ]]; do d=${d%/*}; done
  df -B1 --output=avail -- "${d:-/}" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0
}
# md_stage_bytes: every draft stage together.
md_stage_bytes() {
  local d ds=()
  for d in "$STATE_DIR"/drafts/*.media; do [[ -d $d ]] && ds+=("$d"); done
  (( ${#ds[@]} )) || { echo 0; return 0; }
  du -sbc -- "${ds[@]}" 2>/dev/null | tail -n1 | cut -f1 || echo 0
}
# md_stem <path>: the staged name's stem: [a-z0-9-], at most 24 characters
# (a staged copy's -<sha8> dropped).
md_stem() {
  local s=${1##*/}
  s=${s%.*} s=${s,,}
  s=$(sed -E 's/-[0-9a-f]{8}$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' <<<"$s")
  s=${s:0:24} s=${s%-}
  echo "${s:-media}"
}
# md_drafts_lock: B2's drafts/.lock (fd 5), unless this process already holds
# it on fd 6 (ed_draft_lock); 1 when it can't be had in 10 s.
MD_DLOCK=
md_drafts_lock() {
  MD_DLOCK=
  if [[ $(readlink "/proc/$BASHPID/fd/6" 2>/dev/null) == "$STATE_DIR/drafts/.lock" ]]; then return 0; fi
  mkdir -p "$STATE_DIR/drafts"
  exec 5>"$STATE_DIR/drafts/.lock"
  if ! flock -w 10 5; then exec 5>&-; return 1; fi
  MD_DLOCK=1
}
md_drafts_unlock() { if [[ -n $MD_DLOCK ]]; then exec 5>&-; MD_DLOCK=; fi; }

# ---- capped work (plan §2.5) ------------------------------------------------------------
# Nothing heavy runs in the caller's cgroup (the oomd lesson): media_capped
# puts a command in its own scope, systemd-run --user --scope with MemoryMax
# (1G, or --mem), CPUWeight=20 and nice 10; without a user systemd, nice and
# prlimit --as instead. A job or the indexer inside its own unit
# (PCL_MEDIA_IN_UNIT) runs its commands directly: the unit is the cap.
MD_SCOPE=
md_scope_ok() {
  if [[ -z $MD_SCOPE ]]; then
    MD_SCOPE=no
    if [[ -z ${PCL_MEDIA_NO_SCOPE:-} ]] && command -v systemd-run >/dev/null 2>&1 &&
       systemd-run --user --scope --quiet --collect -- true >/dev/null 2>&1; then
      MD_SCOPE=yes
    fi
  fi
  [[ $MD_SCOPE == yes ]]
}
# md_capped_argv [--mem SIZE] <cmd...>: MD_ARGV = the command, capped.
md_capped_argv() {
  local mem=1G
  if [[ ${1:-} == --mem ]]; then mem=$2; shift 2; fi
  if [[ -n ${PCL_MEDIA_IN_UNIT:-} ]]; then
    MD_ARGV=("$@")
  elif md_scope_ok; then
    MD_ARGV=(systemd-run --user --scope --quiet --collect -p MemoryMax="$mem" -p MemorySwapMax=512M -p CPUWeight=20
             -- nice -n 10 "$@")
  elif command -v prlimit >/dev/null 2>&1; then
    MD_ARGV=(nice -n 10 prlimit --as=$(( $(md_bytes "$mem") * 4 )) -- "$@")
  else
    MD_ARGV=(nice -n 10 "$@")
  fi
}
# media_capped [--mem SIZE] <cmd...>: run it capped; its exit status.
media_capped() { local MD_ARGV=(); md_capped_argv "$@"; "${MD_ARGV[@]}"; }

# ---- probe (plan §2.1) --------------------------------------------------------------------
MD_PROBE_ENTRIES='stream=index,codec_type,codec_name,width,height,pix_fmt,avg_frame_rate,r_frame_rate,nb_frames,nb_read_packets,sample_aspect_ratio,field_order,color_transfer,duration:stream_side_data=rotation:stream_tags=rotate:stream_disposition=attached_pic:format=format_name,duration,size'
# md_probe_file <abs>: one normalised record (a JSON line), probed now
# (timeout 10); never fails: an unreadable file gets error "broken", a
# missing one "missing".
md_probe_file() {
  local p=$1 st size mtime ext line raw cp=()
  if ! st=$(md_stat "$p"); then
    media_jq -c --arg p "$p" 'media_broken($p; null; null; "missing")'; return 0
  fi
  read -r size mtime <<<"$st"
  if (( size == 0 )); then
    media_jq -c --arg p "$p" --argjson s "$size" --argjson m "$mtime" 'media_broken($p; $s; $m; "broken")'; return 0
  fi
  ext=${p##*/} ext=${ext##*.} ext=${ext,,}
  if [[ $ext =~ ^(png|jpe?g|webp|bmp|tiff?|heic|heif|avif)$ ]] && command -v magick >/dev/null 2>&1; then
    line=$(timeout 10 magick identify -ping -format '%w|%h|%[orientation]|%[channels]|%n|%m\n' "${p}[0]" 2>/dev/null) || line=
    line=${line%%$'\n'*}
    if [[ $line =~ ^[0-9]+\|[0-9]+\| ]]; then
      media_jq -c --arg l "$line" --arg p "$p" --argjson s "$size" --argjson m "$mtime" 'media_norm_magick($l; $p; $s; $m)'
      return 0
    fi
  fi
  if [[ $ext == gif || $ext == png ]]; then cp=(-count_packets); fi
  raw=$(timeout 10 ffprobe -v error "${cp[@]}" -show_entries "$MD_PROBE_ENTRIES" -of json -- "$p" 2>/dev/null) || raw=
  if jq -e '.streams | type == "array"' >/dev/null 2>&1 <<<"$raw"; then
    media_jq -c --argjson j "$raw" --arg p "$p" --argjson s "$size" --argjson m "$mtime" 'media_norm_ffprobe($j; $p; $s; $m)'
  else
    media_jq -c --arg p "$p" --argjson s "$size" --argjson m "$mtime" 'media_broken($p; $s; $m; "broken")'
  fi
}
# md_index_append <file of JSON lines>: into the index (under index.write.lock).
md_index_append() {
  [[ -s $1 ]] || return 0
  mkdir -p "$MEDIA_DIR"
  ( flock -w 10 9 || exit 1; cat "$1" >>"$MEDIA_INDEX" ) 9>"$MEDIA_DIR/index.write.lock" || true
}
# md_index_lookup <abs>...: "path \0 json \0" of the fresh index records of
# these files (size and mtime still match); stale and missing ones are left out.
md_index_lookup() {
  [[ -s $MEDIA_INDEX ]] || return 0
  local p json st sm
  local -A got=() size=()
  while IFS= read -r -d '' p && IFS= read -r -d '' sm && IFS= read -r -d '' json; do got[$p]=$json size[$p]=$sm; done < <(
    jq -Rj --args '(try fromjson catch null) | objects | select(.path | type == "string")
      | select(.path as $p | $ARGS.positional | index($p))
      | .path, "\u0000", "\(.size) \(.mtime)", "\u0000", (tojson), "\u0000"' "$@" <"$MEDIA_INDEX" 2>/dev/null || true)
  for p in "$@"; do
    [[ -n ${got[$p]:-} ]] || continue
    st=$(md_stat "$p") || continue
    if [[ ${size[$p]} == "$st" ]]; then printf '%s\0%s\0' "$p" "${got[$p]}"; fi
  done
}
# media_probe_many <abs>...: one normalised record per file (JSON lines, in
# order): fresh index records as they are, the rest probed now (up to 8 at a
# time) and added to the index.
media_probe_many() {
  (( $# )) || return 0
  local p json i=0 pids=() out=$TMP/md-probe.$BASHPID
  local -A got=() slot=()
  mkdir -p "$out"
  while IFS= read -r -d '' p && IFS= read -r -d '' json; do got[$p]=$json; done < <(md_index_lookup "$@")
  for p in "$@"; do
    [[ -z ${got[$p]:-} && -z ${slot[$p]:-} ]] || continue
    slot[$p]=$i
    md_probe_file "$p" >"$out/$i" &
    pids+=($!); i=$((i + 1))
    if (( ${#pids[@]} >= 8 )); then wait "${pids[@]}" || true; pids=(); fi
  done
  if (( ${#pids[@]} )); then wait "${pids[@]}" || true; fi
  if (( i > 0 )); then
    cat "$out"/* >"$out/new" 2>/dev/null || true
    md_index_append "$out/new"
  fi
  for p in "$@"; do
    if [[ -n ${got[$p]:-} ]]; then printf '%s\n' "${got[$p]}"
    elif [[ -s $out/${slot[$p]} ]]; then head -n1 "$out/${slot[$p]}"
    else media_jq -c --arg p "$p" 'media_broken($p; null; null; "broken")'; fi
  done
  rm -rf "$out"
}
# media_probe_json <abs>: the normalised record of one file (plan §8 contract).
media_probe_json() { media_probe_many "$1"; }

# ---- thumbnails and the indexer (plan §2.2) -----------------------------------------------
MD_WEBP=
md_has_libwebp() {
  if [[ -z $MD_WEBP ]]; then
    MD_WEBP=no
    if [[ $(ffmpeg -hide_banner -encoders 2>/dev/null || true) == *" libwebp "* ]]; then MD_WEBP=yes; fi
  fi
  [[ $MD_WEBP == yes ]]
}
# md_make_thumb <abs> <record json> <key>: the 256 px webp (timeout 20),
# written tmp + mv; a <key>.fail marker when it can't be made.
md_make_thumb() {
  local p=$1 rec=$2 k=$3 out tmp kind dur alpha ss=0 vf ok=
  out=$(md_thumb_path "$k") tmp=$MEDIA_THUMBS/${k:0:2}/.$k.$BASHPID.tmp
  mkdir -p "${out%/*}"
  IFS=$'\t' read -r kind dur alpha < <(jq -r '[.kind // "video", (.duration // 0), (.alpha == true)] | @tsv' <<<"$rec") || true
  vf=scale=256:256:force_original_aspect_ratio=decrease
  if [[ $alpha == true ]]; then vf+=,format=rgba,premultiply=inplace=1,format=rgb24; fi
  if [[ $kind == image ]]; then
    if timeout 20 magick -limit memory 256MiB -limit map 512MiB -define jpeg:size=512x512 "${p}[0]" -auto-orient \
        -thumbnail 256x256 -background black -alpha remove -alpha off -quality 70 "webp:$tmp.webp" 2>/dev/null; then ok=1; fi
  fi
  if [[ -z $ok ]]; then
    ss=$(awk -v d="${dur:-0}" 'BEGIN { printf "%.3f", (d > 0 ? d / 3 : 0) }')
    if md_has_libwebp; then
      if media_capped timeout 20 ffmpeg -nostdin -v error -y -ss "$ss" -i "file:$p" -frames:v 1 -vf "$vf" \
          -c:v libwebp -quality 70 -f webp "$tmp.webp" 2>/dev/null; then ok=1; fi
    elif media_capped timeout 20 ffmpeg -nostdin -v error -y -ss "$ss" -i "file:$p" -frames:v 1 -vf "$vf" \
        -f image2 "$tmp.png" 2>/dev/null && magick "$tmp.png" -quality 70 "webp:$tmp.webp" 2>/dev/null; then
      ok=1
    fi
  fi
  rm -f "$tmp.png"
  if [[ -n $ok && -s $tmp.webp ]]; then
    mv -f "$tmp.webp" "$out"; rm -f "${out%.webp}.fail"; return 0
  fi
  rm -f "$tmp.webp"
  : >"${out%.webp}.fail"
  return 1
}
# md_want_write <file> <path>...: a want list, NUL-separated (tmp + mv, under
# index.write.lock); md_want_add appends (thumb.want).
md_want_write() {
  local f=$1; shift
  mkdir -p "$MEDIA_DIR"
  ( flock -w 10 9 || exit 1
    t=$f.$BASHPID.tmp
    if (( $# )); then printf '%s\0' "$@" >"$t"; else : >"$t"; fi
    mv -f "$t" "$f" ) 9>"$MEDIA_DIR/index.write.lock" || true
}
md_want_add() {
  local f=$1; shift
  (( $# )) || return 0
  mkdir -p "$MEDIA_DIR"
  ( flock -w 10 9 || exit 1; printf '%s\0' "$@" >>"$f" ) 9>"$MEDIA_DIR/index.write.lock" || true
}
md_indexer_running() {
  mkdir -p "$MEDIA_DIR"
  if ( flock -n 9 ) 9>"$MEDIA_DIR/index.lock"; then return 1; fi
  return 0
}
# md_start_indexer: the indexer unit (one per user: CPUQuota 25 %, capped),
# unless it runs. PCL_MEDIA_INLINE=1 runs it in this process once the answer
# is out (MD_INDEX_AFTER); PCL_MEDIA_INDEX=off never starts it (tests).
MD_INDEX_AFTER=
md_start_indexer() {
  local extra=() v
  [[ ${PCL_MEDIA_INDEX:-on} != off ]] || return 1
  command -v ffprobe >/dev/null 2>&1 || return 1
  if md_indexer_running; then return 0; fi
  if [[ -n ${PCL_MEDIA_INLINE:-} ]]; then MD_INDEX_AFTER=1; return 0; fi
  for v in PCL_TEST_OVERRIDES PCL_MEDIA_UNIT PCL_MODELS PROFILE PCL_LIB; do
    if [[ -n ${!v:-} ]]; then extra+=(--setenv="$v=${!v}"); fi
  done
  systemd-run --user --quiet --collect --unit="$MEDIA_UNIT-index" \
    -p CPUQuota=25% -p MemoryMax=1G -p MemorySwapMax=256M -p CPUWeight=20 -p Nice=10 -p IOSchedulingClass=idle \
    -p KillMode=control-group -p TimeoutStopSec=15 -p RuntimeMaxSec=3600 \
    --setenv=HOME="$HOME" --setenv=PCL_MEDIA_IN_UNIT=1 "${extra[@]}" \
    -- "$(readlink -f "$0")" media --index >/dev/null 2>&1
}
MD_KEYS_PY='
import sys, hashlib
f = sys.stdin.buffer.read().split(b"\0")
o = sys.stdout.buffer
for i in range(0, len(f) - 5, 6):
    tag, path, size, mtime, dev, ino = f[i:i + 6]
    try:
        path.decode("utf-8")
    except UnicodeDecodeError:
        continue
    k = hashlib.sha1(path + b"\0" + size + b"\0" + mtime).hexdigest()
    pid = hashlib.sha1(path).hexdigest()[:10]
    o.write(b"\0".join([tag, path, size, mtime, dev, ino, pid.encode(), k.encode()]) + b"\0")
'
# md_keys: NUL records of 6 fields (tag path size mtime dev ino) on stdin ->
# the same with the item id and the thumbnail key (8 fields).
md_keys() { python3 -c "$MD_KEYS_PY"; }
# md_index_todo: MD_TODO = the wanted files (thumb.want first, drained, then
# index.want) that still need a probe or a thumbnail; MD_TODO_REC = their
# fresh record ("" when they need a probe).
md_index_todo() {
  local w=$TMP/md-todo.$BASHPID p rec
  MD_TODO=() MD_TODO_REC=()
  mkdir -p "$w"
  ( flock -w 10 9 || exit 1
    cat "$MEDIA_DIR/thumb.want" "$MEDIA_DIR/index.want" 2>/dev/null >"$w/want" || true
    : >"$MEDIA_DIR/thumb.want" ) 9>"$MEDIA_DIR/index.write.lock" || true
  if [[ ! -s $w/want ]]; then rm -rf "$w"; return 0; fi
  # tag, path, size, mtime, dev, ino of every wanted file that exists (in order, once)
  xargs -0 -r stat -L --printf 'w\0%n\0%s\0%Y\0%d\0%i\0' -- <"$w/want" 2>/dev/null | md_keys >"$w/recs" || true
  find "$MEDIA_THUMBS" -mindepth 2 -maxdepth 2 -type f \( -name '*.webp' -o -name '*.fail' \) -printf '%f\0' \
    >"$w/thumbs" 2>/dev/null || true
  while IFS= read -r -d '' p && IFS= read -r -d '' rec; do
    MD_TODO+=("$p") MD_TODO_REC+=("$rec")
  done < <(jq -nj --rawfile raw "$w/recs" --rawfile th "$w/thumbs" --rawfile idx <(cat "$MEDIA_INDEX" 2>/dev/null || true) '
    (reduce ($idx | split("\n")[] | select(length > 0) | try fromjson catch null | objects) as $r ({}; .[$r.path] = $r)) as $im
    | ($th | split("\u0000") | map(select(length > 0) | sub("\\.(webp|fail)$"; "")) | map({(.): true}) | add // {}) as $tk
    | ($raw | split("\u0000")) as $f
    | [range(0; ($f | length) / 8 | floor) as $i | $f[$i * 8:$i * 8 + 8]]
    | reduce .[] as $x ({seen: {}, out: []}; if .seen[$x[1]] then . else .seen[$x[1]] = true | .out += [$x] end)
    | .out[] | . as [$tag, $path, $size, $mtime, $dev, $ino, $id, $k]
    | ($im[$path] // null) as $ix
    | ($ix != null and $ix.size == ($size | tonumber) and $ix.mtime == ($mtime | tonumber)) as $fresh
    | select(($fresh | not) or ($tk[$k] | not))
    | $path, "\u0000", (if $fresh then $ix | tojson else "" end), "\u0000"' 2>/dev/null || true)
  rm -rf "$w"
}
# md_index_one <abs> <fresh record or "">: probe it (the record goes to
# $MD_BATCH) and make its thumbnail when there is none.
md_index_one() {
  local p=$1 rec=$2 st k
  st=$(md_stat "$p") || return 0
  if [[ -z $rec ]]; then
    rec=$(md_probe_file "$p") || return 0
    printf '%s\n' "$rec" >>"$MD_BATCH"
  fi
  k=$(md_key "$p" "${st% *}" "${st#* }")
  [[ ! -f $(md_thumb_path "$k") && ! -f $MEDIA_THUMBS/${k:0:2}/$k.fail ]] || return 0
  if [[ $rec == *'"error":null'* ]]; then
    md_make_thumb "$p" "$rec" "$k" || true
  else
    mkdir -p "$MEDIA_THUMBS/${k:0:2}"; : >"$MEDIA_THUMBS/${k:0:2}/$k.fail"
  fi
}
# md_index_compact: the index without repeats (the last record wins) and
# without files that are gone (tmp + mv, under index.write.lock).
md_index_compact() {
  [[ -s $MEDIA_INDEX ]] || return 0
  ( flock -w 10 9 || exit 1
    t=$MEDIA_INDEX.$BASHPID.tmp
    jq -Rn '[inputs | try fromjson catch null | objects | select(.path | type == "string")]
      | reduce .[] as $r ({}; .[$r.path] = $r) | .[] | .path + "\u0000"' -j <"$MEDIA_INDEX" |
      xargs -0 -r stat -L --printf '%n\0' -- 2>/dev/null >"$t.have" || true
    jq -Rnc --rawfile have "$t.have" '($have | split("\u0000") | map({(.): true}) | add // {}) as $h
      | [inputs | try fromjson catch null | objects | select(.path | type == "string")]
      | reduce .[] as $r ({}; .[$r.path] = $r) | .[] | select($h[.path])' <"$MEDIA_INDEX" >"$t" &&
      mv -f "$t" "$MEDIA_INDEX"
    rm -f "$t" "$t.have" ) 9>"$MEDIA_DIR/index.write.lock" || true
}
# media --index: the indexer. One at a time (index.lock); probes and makes
# thumbnails in want order (thumb.want, then index.want: the page a list
# asked for first), 25 files a batch; after each batch the records join the
# index and index.stamp is touched (the plugin re-lists on it). Stops when
# nothing wanted is left; the index is compacted at the end.
media_index_run() {
  local i b n=0 lk
  local -A seen=()
  mkdir -p "$MEDIA_DIR" "$MEDIA_THUMBS"
  exec {lk}>"$MEDIA_DIR/index.lock"
  flock -n "$lk" || return 0
  MD_BATCH=$TMP/md-batch.jsonl
  : >"$MD_BATCH"
  while :; do
    md_index_todo
    # each file once a run: one whose record can't be kept is not retried for ever
    b=0
    for ((i = 0; i < ${#MD_TODO[@]} && b < 25; i++)); do
      if [[ -n ${seen[${MD_TODO[i]}]:-} ]]; then continue; fi
      seen[${MD_TODO[i]}]=1
      md_index_one "${MD_TODO[i]}" "${MD_TODO_REC[i]}" || true
      b=$((b + 1)) n=$((n + 1))
    done
    (( b > 0 )) || break
    md_index_append "$MD_BATCH"; : >"$MD_BATCH"
    touch "$MEDIA_DIR/index.stamp"
  done
  md_index_compact
  touch "$MEDIA_DIR/index.stamp"
  exec {lk}>&-
  if (( n > 0 )); then log "media: indexed $n file(s)"; fi
}

# media_thumb <abs>...: where each file's thumbnail is (one path per line,
# whether or not it exists yet); missing ones are queued for the indexer.
# (A <thumb>.fail beside the path means it can't be made.)
media_thumb() {
  local p st k t queue=()
  for p in "$@"; do
    if ! st=$(md_stat "$p"); then echo; continue; fi
    k=$(md_key "$p" "${st% *}" "${st#* }") t=$(md_thumb_path "$k")
    echo "$t"
    if [[ ! -f $t && ! -f ${t%.webp}.fail ]]; then queue+=("$p"); fi
  done
  if (( ${#queue[@]} )); then
    md_want_add "$MEDIA_DIR/thumb.want" "${queue[@]}"
    md_start_indexer || true
  fi
}

# ---- the list (plan §1.3b) ----------------------------------------------------------------
# md_find <tag> <maxdepth> <dir> [<pruned path>...]: every media file under
# dir as NUL records "tag path size mtime dev inode": no hidden files or
# folders, no L-Connect cache folders, no *.h264 device streams, links to
# folders not followed.
md_find() {
  local tag=$1 depth=$2 dir=$3 e p names=() exts=()
  shift 3
  [[ -d $dir ]] || return 0
  for e in "${MEDIA_SKIP_DIRS[@]}"; do names+=(-o -name "$e"); done
  for p in "$@"; do names+=(-o -path "$p"); done
  for e in "${MEDIA_EXTS[@]}"; do exts+=(-o -iname "*.$e"); done
  find -P "$dir" -mindepth 1 -maxdepth "$depth" \
    \( -type d \( -name '.*' "${names[@]}" \) -prune \) -o \
    \( -type f ! -name '.*' \( -false "${exts[@]}" \) -printf "$tag\\0%p\\0%s\\0%Ts\\0%D\\0%i\\0" \) 2>/dev/null || true
}
# md_roots <key> <default...>: the library or files roots, $STATE_DIR/media.json
# {"library": [...], "files": [...]} (a leading ~ is $HOME) or the defaults.
md_roots() {
  local key=$1 r; shift
  if [[ -f $STATE_DIR/media.json ]] && jq -e --arg k "$key" '.[$k] | type == "array"' "$STATE_DIR/media.json" >/dev/null 2>&1; then
    while IFS= read -r -d '' r; do
      if [[ $r == \~ || $r == \~/* ]]; then r=$HOME${r#\~}; fi
      printf '%s\0' "$r"
    done < <(jq -j --arg k "$key" '.[$k][] | strings | . + "\u0000"' "$STATE_DIR/media.json")
  else
    printf '%s\0' "$@"
  fi
}
# md_user_dir VIDEOS|PICTURES: the XDG user folder of this $HOME (its own
# user-dirs.dirs; the engine never follows XDG_CONFIG_HOME), else ~/Videos, ~/Pictures.
md_user_dir() {
  local d=''
  if command -v xdg-user-dir >/dev/null 2>&1; then d=$(XDG_CONFIG_HOME=$HOME/.config xdg-user-dir "$1" 2>/dev/null || true); fi
  if [[ -z $d || $d == "$HOME" || $d == "$HOME/" ]]; then
    case $1 in VIDEOS) d=$HOME/Videos ;; *) d=$HOME/Pictures ;; esac
  fi
  echo "${d%/}"
}
# md_target_for <role|model>: MD_TARGET (media_target), MD_ROLE ("" for a model).
md_target_for() {
  local want=$1 r
  r=$(media_jq -c --arg w "$want" '
    if media_target($w; $M) != null then {target: media_target($w; $M), role: null}
    elif ($P | type) != "object" or ($P.roles | type) != "object" then {err: "no-profile"}
    elif ($w | role_kind) == "screen" and ($w | th_role_dev($P)) != null then
      (($w | th_role_dev($P)).family // "") as $fam
      | if media_target($fam; $M) != null then {target: media_target($fam; $M), role: $w} else {err: "no-role", fam: $fam} end
    else {err: "no-role"} end') || die "could not read the models and the profile"
  case $(jq -r '.err // empty' <<<"$r") in
    no-profile) md_fail 5 no-profile "--for $want: screen roles need a hardware profile; run: lumenaire detect (or give a model)" ;;
    no-role) md_fail 2 no-role "--for $want: not a screen role in the profile, nor an LCD model" ;;
  esac
  MD_TARGET=$(jq -c .target <<<"$r") MD_ROLE=$(jq -r '.role // empty' <<<"$r")
}
# md_theme_models <theme dir>...: {name: {ref: model}} for the library's
# "other themes" (made_for), from the screen entries and src/media.json, in
# one jq for every theme.
md_theme_models() {
  local d fs=()
  for d in "$@"; do
    fs+=("$d/theme.json")
    if [[ -f $d/src/media.json ]]; then fs+=("$d/src/media.json"); fi
  done
  awk 'FNR == 1 { print "\036" FILENAME } { print }' "${fs[@]}" 2>/dev/null |
    jq -Rnc -L "$PCL_LIB" --arg td "$THEME_DIR/" 'include "theme"; '"$(<"$PCL_LIB/media.jq")"'
      (reduce inputs as $l ({f: {}, c: null};
         if $l | startswith("\u001e") then .c = ($l | ltrimstr("\u001e")) | .f[.c] = "" else .f[.c] += $l + "\n" end) | .f)
      | to_entries | map(.key |= ltrimstr($td) | .value |= (try fromjson catch null))
      | reduce .[] as $e ({};
          ($e.key | split("/")[0]) as $n
          | if ($e.key | endswith("/src/media.json")) then .[$n] = ((($e.value.files // {}) | map_values(.model // null)) + (.[$n] // {}))
            else .[$n] = ((.[$n] // {}) + ([media_theme_refs($e.value // {})[] | select(.model != null) | {(.ref): .model}] | add // {})) end)' \
    2>/dev/null || echo '{}'
}
md_list() {
  local for='' source=library draft='' q='' offset=0 limit=60 name root='' stage='' tj='{}' prov='{}' lib=() files=()
  local raw=$TMP/md-list.bin a reply want i r v p tm=() themes=() dtheme='' tf pr=()
  while (( $# )); do
    case $1 in
      --for | --source | --draft | --query | --offset | --limit)
        (( $# >= 2 )) || md_fail 2 usage "$1 needs a value"
        case $1 in
          --for) for=$2 ;; --source) source=$2 ;; --draft) draft=$2 ;; --query) q=$2 ;;
          --offset) md_int_ok "$2" || md_fail 2 usage "--offset needs a number"; offset=$2 ;;
          --limit)
            if ! md_int_ok "$2" || (( $2 < 1 || $2 > 500 )); then md_fail 2 usage "--limit needs a number 1-500"; fi
            limit=$2 ;;
        esac
        shift ;;
      --json) MD_JSON=1 ;;
      *) md_fail 2 usage "$MEDIA_USAGE" ;;
    esac
    shift
  done
  [[ -n $for ]] || md_fail 2 usage "media list needs --for <role|model>"
  md_target_for "$for"
  if [[ -n $draft ]]; then
    [[ $draft =~ ^[A-Za-z0-9._-]+$ ]] || md_fail 2 usage "bad draft name '$draft'"
    if [[ -f $(editor_draft_file "$draft") ]]; then dtheme=$(editor_media_root "$draft"); dtheme=${dtheme##*/}; fi
  fi
  mkdir -p "$MEDIA_DIR"
  case $source in
    theme:*)
      name=${source#theme:}
      [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || md_fail 2 usage "bad theme name '$name'"
      if [[ -f $(editor_draft_file "$name") ]]; then
        root=$(editor_media_root "$name") stage=$(editor_draft_stage "$name")
        tj=$(jq -c '.theme // {}' "$(editor_draft_file "$name")")
        prov=$(jq -c '(.media_sources // {}) | map_values(.model // null)' "$(editor_draft_file "$name")")
      elif theme_exists "$name"; then
        root=$THEME_DIR/$name tj=$(jq -c . "$root/theme.json")
      else
        md_fail 2 not-found "no theme and no draft called $name"
      fi
      if [[ -n $root && -f $root/src/media.json ]]; then
        prov=$(jq -c --argjson d "$prov" '((.files // {}) | map_values(.model // null)) + $d' "$root/src/media.json" 2>/dev/null || echo "$prov")
      fi
      { if [[ -n $stage ]]; then md_find stage 8 "$stage/media"; fi
        if [[ -n $root ]]; then md_find root 8 "$root/media"; md_find root 8 "$root/us88"; fi
      } | md_keys >"$raw" || true
      # a theme's files are few: probe the new ones now (plan §1.3b "probed live")
      mapfile -d '' -t pr < <(awk -v RS='\0' -v ORS='\0' 'NR % 8 == 2' "$raw" | head -z -n 100)
      if (( ${#pr[@]} )); then media_probe_many "${pr[@]}" >/dev/null; fi
      ;;
    library)
      for tf in "$THEME_DIR"/*/theme.json; do
        [[ -f $tf ]] || continue
        tf=${tf%/theme.json}
        [[ ${tf##*/} != "$dtheme" ]] || continue
        themes+=("${tf##*/}") tm+=("$tf")
      done
      mapfile -d '' -t lib < <(md_roots library "$HOME/Videos/lian-li")
      { for v in "${themes[@]}"; do md_find "theme:$v" 8 "$THEME_DIR/$v/media"; done
        for i in "${!lib[@]}"; do md_find "lib:$i" 8 "${lib[i]}"; done
      } | head -z -n $(( 6 * (MEDIA_LIST_CAP + 1) )) | md_keys >"$raw" || true
      ;;
    files)
      mapfile -d '' -t lib < <(md_roots library "$HOME/Videos/lian-li")
      v=$(md_user_dir VIDEOS) p=$(md_user_dir PICTURES)
      mapfile -d '' -t files < <(md_roots files "$v" "$p")
      { for i in "${!files[@]}"; do
          r=files:other
          if [[ ${files[i]} == "$v" ]]; then r=files:videos; elif [[ ${files[i]} == "$p" ]]; then r=files:pictures; fi
          md_find "$r" 6 "${files[i]}" "${lib[@]}" "$THEME_DIR" "$STATE_DIR" "$CACHE"
        done
      } | head -z -n $(( 6 * (MEDIA_LIST_CAP + 1) )) | md_keys >"$raw" || true
      ;;
    *) md_fail 2 usage "--source is theme:<name>, library or files" ;;
  esac
  a=$(jq -nc --arg source "$source" --argjson t "$MD_TARGET" --arg role "$MD_ROLE" --arg q "$q" \
      --argjson off "$offset" --argjson lim "$limit" --arg stage "$stage" --arg root "$root" --argjson theme "$tj" \
      --argjson prov "$prov" --argjson themes "$( ((${#tm[@]})) && md_theme_models "${tm[@]}" || echo '{}')" \
      --arg thumbdir "$MEDIA_THUMBS" --arg tdir "$THEME_DIR" \
      --argjson missing "$(md_tools_missing | jq -Rsc 'split("\n") | map(select(. != ""))')" \
      --argjson idx "$([[ ${PCL_MEDIA_INDEX:-on} != off ]] && command -v ffprobe >/dev/null 2>&1 && echo true || echo false)" \
      --args '{source: $source, target: $t, role: (if $role == "" then null else $role end), q: $q, offset: $off, limit: $lim,
       stage: $stage, root: $root, theme: $theme, prov: $prov, themes: $themes, thumbdir: $thumbdir, theme_dir: $tdir,
       tools_missing: $missing, can_index: $idx, lib_roots: $ARGS.positional}' "${lib[@]}")
  { IFS= read -r reply; IFS= read -r want; } < <(
    jq -nc -L "$PCL_LIB" --argjson a "$a" --rawfile raw "$raw" --argjson cap "${MEDIA_LIST_CAP//[!0-9]/}" \
      --rawfile idxraw <(cat "$MEDIA_INDEX" 2>/dev/null || true) \
      --rawfile thumbs <(find "$MEDIA_THUMBS" -mindepth 2 -maxdepth 2 -type f \( -name '*.webp' -o -name '*.fail' \) \
                           -printf '%f\0' 2>/dev/null || true) \
      --slurpfile md_m <(cat "$(theme_models)" 2>/dev/null || echo '{}') \
      'include "theme"; '"$(<"$PCL_LIB/media.jq")"'
      ($raw | split("\u0000") | length / 8 | floor) as $n
      | ($a + {truncated: ($n > $cap)}) as $a
      | ($raw | split("\u0000") | .[:($cap * 8)] | join("\u0000")) as $raw
      | [$idxraw | split("\n")[] | select(length > 0) | try fromjson catch null | objects] as $idx
      | media_list($a; $raw + "\u0000"; $idx; $thumbs; $md_m[0])' 2>"$TMP/md-list.err") ||
    true
  [[ -n $reply ]] || die "media list: could not build the list: $(head -c 300 "$TMP/md-list.err" 2>/dev/null)"
  printf '%s\n' "$reply"
  if [[ -n $want && $want != "[]" ]]; then
    mapfile -d '' -t pr < <(jq -j '.[] + "\u0000"' <<<"$want")
    md_want_write "$MEDIA_DIR/index.want" "${pr[@]}"
    md_start_indexer || true
    if [[ -n $MD_INDEX_AFTER ]]; then media_index_run >/dev/null 2>&1 || true; fi
  fi
}

# ---- probe, thumb and frame verbs -----------------------------------------------------------
# md_src <file>: the absolute path of a source the verbs read; refuses a
# missing file (not-found) and anything but a regular readable one (invalid).
md_src() {
  local p=$1
  [[ -n $p ]] || md_fail 2 usage "$MEDIA_USAGE"
  if [[ $p != /* ]]; then p=$PWD/$p; fi
  p=$(realpath -ms -- "$p" 2>/dev/null || echo "$p")
  [[ -e $p || -L $p ]] || md_fail 2 not-found "no file $p"
  [[ -f $p && ! -p $p && -r $p ]] || md_fail 2 invalid "$p is not a regular readable file"
  MD_SRC=$p
}
md_probe_cmd() {
  local src='' rec
  while (( $# )); do
    case $1 in --json) MD_JSON=1 ;; -*) md_fail 2 usage "$MEDIA_USAGE" ;; *) [[ -z $src ]] || md_fail 2 usage "$MEDIA_USAGE"; src=$1 ;; esac
    shift
  done
  md_src "$src"
  command -v ffprobe >/dev/null 2>&1 || md_fail 2 missing-tool "screen editing needs ffmpeg and ImageMagick (missing: ffprobe)"
  rec=$(media_probe_json "$MD_SRC")
  if [[ $(jq -r '.error // empty' <<<"$rec") != "" ]]; then
    echo "pc-lights: $MD_SRC: $(jq -r .error <<<"$rec")" >&2
    jq -c '. + {code: .error}' <<<"$rec"
    exit 2
  fi
  jq -c . <<<"$rec"
}
md_thumb_cmd() {
  local now='' srcs=() p st k t rec out=() n=0 queue=()
  while (( $# )); do
    case $1 in --now) now=1 ;; --json) MD_JSON=1 ;; -*) md_fail 2 usage "$MEDIA_USAGE" ;; *) srcs+=("$1") ;; esac
    shift
  done
  (( ${#srcs[@]} )) || md_fail 2 usage "$MEDIA_USAGE"
  md_need_tools
  for p in "${srcs[@]}"; do
    md_src "$p"; p=$MD_SRC
    st=$(md_stat "$p") k=$(md_key "$p" "${st% *}" "${st#* }") t=$(md_thumb_path "$k")
    if [[ ! -f $t && ! -f ${t%.webp}.fail ]]; then
      if [[ -n $now ]] && (( n < 8 )); then
        n=$((n + 1))
        rec=$(media_probe_json "$p")
        if [[ $rec == *'"error":null'* ]]; then md_make_thumb "$p" "$rec" "$k" || true
        else mkdir -p "${t%/*}"; : >"${t%.webp}.fail"; fi
      else
        queue+=("$p")
      fi
    fi
    if [[ -f $t ]]; then st=ready; elif [[ -f ${t%.webp}.fail ]]; then st=failed; else st=pending; fi
    out+=("$(jq -nc --arg p "$p" --arg t "$t" --arg s "$st" '{path: $p, thumb: (if $s == "ready" then $t else null end), state: $s}')")
  done
  if (( n > 0 )); then touch "$MEDIA_DIR/index.stamp" 2>/dev/null || true; fi
  printf '%s\n' "${out[@]}" | jq -sc '{thumbs: .}'
  if (( ${#queue[@]} )); then
    md_want_add "$MEDIA_DIR/thumb.want" "${queue[@]}"
    md_start_indexer || true
    if [[ -n $MD_INDEX_AFTER ]]; then media_index_run >/dev/null 2>&1 || true; fi
  fi
}
# media frame <file> [--time <s>] [--max <px>]: one frame for the crop view,
# in display orientation, the long side at most <max>; cached per (key, ms).
md_frame_cmd() {
  local src='' time='' max=960 rec kind dur dw dh t ms k out tmp st vf ok='' alpha
  while (( $# )); do
    case $1 in
      --time)
        if (( $# < 2 )) || ! md_num_ok "$2"; then md_fail 2 usage "--time needs seconds"; fi
        time=$2; shift ;;
      --max)
        if (( $# < 2 )) || ! md_int_ok "$2" || (( $2 < 16 || $2 > 4096 )); then md_fail 2 usage "--max needs 16-4096 px"; fi
        max=$2; shift ;;
      --json) MD_JSON=1 ;;
      -*) md_fail 2 usage "$MEDIA_USAGE" ;;
      *) [[ -z $src ]] || md_fail 2 usage "$MEDIA_USAGE"; src=$1 ;;
    esac
    shift
  done
  md_src "$src"; src=$MD_SRC
  md_need_tools
  rec=$(media_probe_json "$src")
  st=$(jq -r '.error // empty' <<<"$rec")
  [[ -z $st ]] || md_fail 2 "$st" "$src: $(md_error_text "$st")"
  IFS=$'\t' read -r kind dur dw dh alpha < <(jq -r '[.kind, (.duration // 0), .dw, .dh, (.alpha == true)] | @tsv' <<<"$rec")
  t=$(awk -v t="${time:-}" -v d="$dur" -v k="$kind" 'BEGIN {
        if (k == "image" || d <= 0) { print "0.000"; exit }
        x = (t == "" ? d / 3 : t + 0); m = d - 0.05; if (m < 0) m = 0; if (x > m) x = m; if (x < 0) x = 0
        printf "%.3f\n", x }')
  ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 + 0.5 }')
  st=$(md_stat "$src") k=$(md_key "$src" "${st% *}" "${st#* }")
  out=$MEDIA_FRAMES/$k/$ms-$max.jpg
  if [[ ! -s $out ]]; then
    mkdir -p "${out%/*}"
    tmp=${out%/*}/.$ms-$max.$BASHPID.jpg
    if [[ $kind == image ]]; then
      if media_capped timeout 10 magick -limit memory 256MiB -limit map 512MiB "${src}[0]" -auto-orient \
          -background black -alpha remove -alpha off -resize "${max}x${max}>" -quality 90 "jpeg:$tmp" 2>/dev/null; then ok=1; fi
    fi
    if [[ -z $ok ]]; then
      vf="scale='if(gte(iw,ih),min($max,iw),-2)':'if(gte(iw,ih),-2,min($max,ih))'"
      if [[ $alpha == true ]]; then vf="format=rgba,premultiply=inplace=1,format=rgb24,$vf"; fi
      if media_capped timeout 10 ffmpeg -nostdin -v error -y -ss "$t" -i "file:$src" -frames:v 1 -vf "$vf" -q:v 3 \
          -f image2 "$tmp" 2>/dev/null; then ok=1; fi
    fi
    if [[ -z $ok || ! -s $tmp ]]; then rm -f "$tmp"; md_fail 2 unsupported "could not read a frame of $src"; fi
    mv -f "$tmp" "$out"
  fi
  IFS=' ' read -r dw dh < <(magick identify -format '%w %h\n' "$out" 2>/dev/null || echo "0 0") || true
  jq -nc --arg p "$out" --argjson t "$t" --argjson w "$dw" --argjson h "$dh" --argjson r "$rec" \
    '{path: $p, time: (($t * 1000 | round) / 1000), w: $w, h: $h, src_w: $r.dw, src_h: $r.dh, duration: $r.duration, kind: $r.kind}'
}
md_error_text() {
  case $1 in
    broken) echo "it isn't a picture or video this PC can read" ;;
    no-picture) echo "it has no picture (sound only?)" ;;
    unsupported) echo "this PC can't decode it" ;;
    missing) echo "it is gone" ;;
    *) echo "$1" ;;
  esac
}

# ---- jobs: records (plan §1.3c) -----------------------------------------------------------
media_job_file() { echo "$MEDIA_JOBS/$1.json"; }
md_job_id_ok() { [[ $1 =~ ^j-[0-9]+-[0-9]+$ ]]; }
# md_job_get <id> <jq expr>: one raw value ("" when missing).
md_job_get() { jq -r "($2) // empty" "$(media_job_file "$1")" 2>/dev/null || true; }
# md_job_upd <id> [jq args...] <filter>: the record, rewritten under
# jobs/.lock (tmp + mv), $now bound, updated = now; 1 when there is none.
md_job_upd() {
  local id=$1 f=${*: -1} jf
  jf=$(media_job_file "$id")
  (
    t=$jf.$BASHPID.tmp
    flock -w 5 7 || exit 1
    [[ -f $jf ]] || exit 1
    jq -c --argjson now "$EPOCHSECONDS" "${@:2:$#-2}" "($f) | .updated = \$now" "$jf" >"$t" && [[ -s $t ]] && mv -f "$t" "$jf"
    rc=$?
    rm -f "$t"
    exit "$rc"
  ) 7>"$MEDIA_JOBS/.lock"
}
# md_job_lines: every job record behind a "\x1e" line (for jq --rawfile).
md_job_lines() {
  local f fs=()
  for f in "$MEDIA_JOBS"/j-*.json; do [[ -f $f ]] && fs+=("$f"); done
  (( ${#fs[@]} )) || return 0
  awk 'FNR == 1 { print "\036" } { print }' "${fs[@]}" 2>/dev/null || true
}
# md_pid_is_media <pid>: a live lumenaire "media" process (a runner), not a reused pid.
md_pid_is_media() {
  kill -0 "$1" 2>/dev/null || return 1
  [[ " $(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true)" == *" media "* ]]
}
# md_runner_alive <id>: the job's runner still runs (its unit or its process).
md_runner_alive() {
  local unit pid
  unit=$(md_job_get "$1" .unit) pid=$(md_job_get "$1" .pid)
  if [[ -n $unit ]] && systemctl --user is-active -q "$unit.service" 2>/dev/null; then return 0; fi
  if [[ -n $pid ]] && md_pid_is_media "$pid"; then return 0; fi
  return 1
}
# md_reap_jobs: a record that isn't final but whose runner is gone (killed
# hard, a reboot) ends: cancelled when a cancel was asked, else failed "stopped".
md_reap_jobs() {
  local f id st
  for f in "$MEDIA_JOBS"/j-*.json; do
    [[ -f $f ]] || continue
    id=${f##*/} id=${id%.json}
    st=$(md_job_get "$id" .state)
    if md_is_final "$st"; then continue; fi
    # a fresh record may not have its runner yet
    (( EPOCHSECONDS - $(stat -c %Y "$f" 2>/dev/null || echo 0) > 30 )) || continue
    md_runner_alive "$id" && continue
    md_job_end "$id" "$(cat "$MEDIA_JOBS/$id.cancel" 2>/dev/null || true)" stopped "It stopped before it finished"
    rm -rf "${MEDIA_WORK:?}/$id"
  done
}
# md_job_end <id> <cancel reason or ""> <code> <text>: the final state of a
# job that didn't finish: cancelled (a cancel or a supersede asked for it) or
# failed with {code, text}.
md_job_end() {
  md_job_upd "$1" --arg why "$2" --arg c "$3" --arg t "$4" '
    if .state == "done" or .state == "failed" or .state == "cancelled" then . else
      .ended = $now | .pid = null
      | if $why != "" then .state = "cancelled"
          | .error = (if $why == "superseded" then {code: "superseded", text: "A newer choice replaced it"} else null end)
        else .state = "failed" | .error = {code: $c, text: $t} end end' || true
}
# media_jobs_json [--draft <name>] [--all]: {v, running, jobs: [records,
# newest first]}: the draft's (or every) job that runs or ended in the last
# day; --all: every record kept (7 days).
media_jobs_json() {
  local draft='' all=false
  while (( $# )); do
    case $1 in --draft) draft=${2:-}; shift ;; --all) all=true ;; esac
    shift
  done
  jq -nc --rawfile raw <(md_job_lines) --arg d "$draft" --argjson all "$all" --argjson now "$EPOCHSECONDS" '
    def final: IN("done", "failed", "cancelled");
    [$raw | split("\u001e")[] | select(length > 0) | try fromjson catch null | objects | select(.id | type == "string")
     | select($d == "" or .draft == $d)
     | select($all or (.state | final | not) or ($now - (.ended // .updated // 0)) <= 86400)] as $j
    | {v: 1, running: ([$j[] | select(.state | final | not)] | length), jobs: ($j | sort_by(-(.started // 0), .id))}'
}
md_jobs_cmd() {
  local args=()
  while (( $# )); do
    case $1 in
      --draft) (( $# >= 2 )) || md_fail 2 usage "--draft needs a name"; args+=(--draft "$2"); shift ;;
      --all) args+=(--all) ;;
      --json) MD_JSON=1 ;;
      *) md_fail 2 usage "$MEDIA_USAGE" ;;
    esac
    shift
  done
  md_reap_jobs
  media_jobs_json "${args[@]}"
}

# media_cancel_job <id> [superseded] [--nowait]: stop a job; idempotent. 0: it
# is cancelled (now or before), 1: it had ended otherwise, 2: no such job.
# The runner ends it itself (its unit is stopped, or its process TERMed);
# without --nowait this waits up to 10 s and ends a runner that is gone.
# A cancelled job (not a superseded one) leaves its draft's pending_media.
media_cancel_job() {
  local id=$1 why=cancel nowait='' a jf st unit pid n=0 d r
  shift
  for a in "$@"; do case $a in superseded) why=superseded ;; --nowait) nowait=1 ;; esac; done
  md_job_id_ok "$id" || return 2
  jf=$(media_job_file "$id")
  [[ -f $jf ]] || return 2
  st=$(md_job_get "$id" .state)
  case $st in cancelled) return 0 ;; done | failed) return 1 ;; esac
  printf '%s\n' "$why" >"$MEDIA_JOBS/$id.cancel"
  unit=$(md_job_get "$id" .unit) pid=$(md_job_get "$id" .pid)
  if [[ -n $unit ]]; then
    if [[ -n $nowait ]]; then systemctl --user stop --no-block "$unit.service" >/dev/null 2>&1 || true
    else systemctl --user stop "$unit.service" >/dev/null 2>&1 || true; fi
  fi
  if [[ -n $pid ]] && md_pid_is_media "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  [[ -z $nowait ]] || return 0
  while (( n < 100 )); do
    st=$(md_job_get "$id" .state)
    if md_is_final "$st" || ! md_runner_alive "$id"; then break; fi
    sleep 0.1; n=$((n + 1))
  done
  st=$(md_job_get "$id" .state)
  if ! md_is_final "$st"; then
    md_job_end "$id" "$why" stopped "Stopped"
    rm -rf "${MEDIA_WORK:?}/$id"
  fi
  rm -f "$MEDIA_JOBS/$id.cancel"
  st=$(md_job_get "$id" .state)
  if [[ $st == cancelled && $why == cancel ]]; then
    d=$(md_job_get "$id" .draft) r=$(md_job_get "$id" .role)
    if [[ -n $d && -n $r && -f $(editor_draft_file "$d") ]]; then
      editor_media_pending "$d" "$r" "" "$id" >/dev/null 2>&1 || true
    fi
  fi
  [[ $st == cancelled ]] && return 0
  return 1
}
md_cancel_cmd() {
  local id='' rc=0 st
  while (( $# )); do
    case $1 in --json) MD_JSON=1 ;; -*) md_fail 2 usage "$MEDIA_USAGE" ;; *) [[ -z $id ]] || md_fail 2 usage "$MEDIA_USAGE"; id=$1 ;; esac
    shift
  done
  [[ -n $id ]] || md_fail 2 usage "$MEDIA_USAGE"
  media_cancel_job "$id" || rc=$?
  (( rc != 2 )) || md_fail 2 not-found "no media job $id"
  st=$(md_job_get "$id" .state)
  md_out "$(jq -nc --arg id "$id" --arg st "$st" '{cancelled: ($st == "cancelled"), id: $id, state: $st}')" \
    "$id: $([[ $st == cancelled ]] && echo cancelled || echo "already $st")"
}
# media_rename_draft <old> <new>: job records follow a renamed draft (B2's
# rename moves drafts/<old>.media itself).
media_rename_draft() {
  local f id o=$STATE_DIR/drafts/$1.media/ n=$STATE_DIR/drafts/$2.media/
  for f in "$MEDIA_JOBS"/j-*.json; do
    [[ -f $f ]] || continue
    id=${f##*/} id=${id%.json}
    [[ $(md_job_get "$id" .draft) == "$1" ]] || continue
    md_job_upd "$id" --arg d "$2" --arg o "$o" --arg n "$n" '.draft = $d
      | if (.output.abs // "" | startswith($o)) then .output.abs = $n + (.output.abs | ltrimstr($o)) else . end' || true
  done
}

# ---- prepare (plan §1.2, §2.4-§2.6) -------------------------------------------------------
# md_out_estimate <duration> <target json> <kind>: bytes the output may take.
md_out_estimate() {
  jq -rn --argjson t "$2" --arg d "$1" --arg k "$3" '
    if $k == "image" then $t.w * $t.h * 4 else (($d | tonumber? // 0) * $t.maxrate_bits / 8 * 1.1) end | floor'
}
# md_disk_check <estimate bytes> <stage: 1 for a draft's job> <dir>...:
# "disk-full <text>" or "stage-full <text>" when the output can't be
# afforded (free space for 1.2 x it and a GiB on each filesystem; every
# draft stage together under PCL_MEDIA_STAGE_CAP, 4 GiB), nothing when it can.
md_disk_check() {
  local est=$1 st=$2 d free cap used; shift 2
  for d in "$@"; do
    free=$(md_free "$d")
    if (( free < est * 12 / 10 + 1073741824 )); then
      echo "disk-full not enough free space for it ($((free / 1048576)) MB free where $d is)"; return 0
    fi
  done
  [[ $st == 1 ]] || return 0
  cap=$(md_bytes "${PCL_MEDIA_STAGE_CAP:-4G}") used=$(md_stage_bytes)
  if (( used + est > cap )); then
    echo "stage-full the unsaved media of every draft would take more than $((cap / 1048576)) MB; save or discard a draft first"
  fi
}
md_prepare() {
  local src='' for='' draft='' then=set at='' out='' crop='' time='' start='' dur='' rec err srcsum req id jf unit=''
  local est chk old rc
  while (( $# )); do
    case $1 in
      --for | --draft | --then | --at | --out | --crop | --time | --start | --duration)
        (( $# >= 2 )) || md_fail 2 usage "$1 needs a value"
        case $1 in
          --for) for=$2 ;; --draft) draft=$2 ;; --then) then=$2 ;; --at) at=$2 ;; --out) out=$2 ;;
          --crop) crop=$2 ;; --time) time=$2 ;; --start) start=$2 ;; --duration) dur=$2 ;;
        esac
        shift ;;
      --json) MD_JSON=1 ;;
      -*) md_fail 2 usage "$MEDIA_USAGE" ;;
      *) [[ -z $src ]] || md_fail 2 usage "$MEDIA_USAGE"; src=$1 ;;
    esac
    shift
  done
  [[ -n $src ]] || md_fail 2 usage "$MEDIA_USAGE"
  [[ -n $for ]] || md_fail 2 usage "media prepare needs --for <role|model>"
  [[ -n $draft || -n $out ]] && [[ -z $draft || -z $out ]] || md_fail 2 usage "media prepare needs --draft <name> or --out <file> (one of them)"
  md_src "$src"; src=$MD_SRC
  md_need_tools
  md_target_for "$for"
  [[ $then =~ ^(set|clip-add|none)$ ]] || md_fail 2 usage "--then is set, clip-add or none"
  if [[ -n $at ]]; then
    md_int_ok "$at" || md_fail 2 usage "--at needs a clip number (0 is the first)"
    [[ $then == clip-add ]] || md_fail 2 usage "--at only goes with --then clip-add"
  fi
  if [[ -n $crop ]]; then
    [[ $crop =~ ^[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?$ ]] ||
      md_fail 2 usage "--crop is x,y,w,h in source pixels"
    crop="[$crop]"
    jq -e '.[2] > 0 and .[3] > 0' >/dev/null <<<"$crop" || md_fail 2 invalid "--crop needs a width and a height"
  fi
  if [[ -n $time ]]; then md_num_ok "$time" || md_fail 2 usage "--time needs seconds"; fi
  if [[ -n $start ]]; then md_num_ok "$start" || md_fail 2 usage "--start needs seconds"; fi
  if [[ -n $dur ]]; then
    if ! md_num_ok "$dur" || ! awk -v d="$dur" 'BEGIN { exit !(d > 0) }'; then md_fail 2 usage "--duration needs seconds (more than 0)"; fi
  fi
  if [[ -n $draft ]]; then
    [[ $draft =~ ^[A-Za-z0-9._-]+$ ]] || md_fail 2 usage "bad draft name '$draft'"
    [[ -f $(editor_draft_file "$draft") ]] || md_fail 2 not-found "no unsaved edits for $draft (open them with: theme edit $draft)"
    if [[ $then != none && -z $MD_ROLE ]]; then md_fail 2 usage "--then $then needs --for <screen role>"; fi
  else
    then=none
    if [[ $out != /* ]]; then out=$PWD/$out; fi
    out=$(realpath -ms -- "$out")
    [[ ! -e $out ]] || md_fail 2 invalid "$out already exists; media prepare never overwrites a file"
    [[ -d ${out%/*} && -w ${out%/*} ]] || md_fail 2 invalid "can't write into ${out%/*}"
    [[ $out != "$src" ]] || md_fail 2 invalid "the output can't be the source"
  fi
  # the source: probed (from the index when it is fresh)
  rec=$(media_probe_json "$src")
  err=$(jq -r '.error // empty' <<<"$rec")
  if [[ -n $err ]]; then
    case $err in missing) err=not-found ;; esac
    md_fail 2 "$err" "$src: $(md_error_text "$err")"
  fi
  if jq -e '(.dw // 0) > 16384 or (.dh // 0) > 16384 or ((.dw // 0) * (.dh // 0)) > 268435456' >/dev/null <<<"$rec"; then
    md_fail 2 too-large "$src is too big to prepare (more than 16384 px a side)"
  fi
  # disk: the output (the model's bitrate over the clip it keeps) must fit twice over and a GiB
  est=$(md_out_estimate "$(jq -r --argjson t "$MD_TARGET" '[(.duration // 0), $t.max_s] | min' <<<"$rec")" "$MD_TARGET" \
        "$(jq -r '.kind' <<<"$rec")")
  chk=$(md_disk_check "$est" "$([[ -n $draft ]] && echo 1 || echo 0)" "$MEDIA_WORK" "${out:-$STATE_DIR/drafts}")
  if [[ -n $chk ]]; then md_fail 2 "${chk%% *}" "${chk#* }"; fi
  # the record
  mkdir -p "$MEDIA_JOBS" "$MEDIA_WORK"
  id=j-$(( ${EPOCHREALTIME/./} / 1000 ))-$(printf '%04d' $((RANDOM % 10000)))
  jf=$(media_job_file "$id")
  if [[ -z ${PCL_MEDIA_INLINE:-} ]]; then unit=$MEDIA_UNIT-$id; fi
  srcsum=$(jq -c '{path, size, mtime, kind, w: .dw, h: .dh, duration, fps}' <<<"$rec")
  req=$(jq -nc --argjson crop "${crop:-null}" --arg time "$time" --arg start "$start" --arg dur "$dur" '
    {crop: $crop, time: ($time | tonumber? // null), start: ($start | tonumber? // null), duration: ($dur | tonumber? // null)}')
  jq -nc --arg id "$id" --arg draft "$draft" --arg role "$MD_ROLE" --argjson t "$MD_TARGET" --arg thn "$then" \
    --argjson at "${at:-null}" --arg dest "$out" --argjson src "$srcsum" --argjson req "$req" --arg unit "$unit" \
    --argjson now "$EPOCHSECONDS" "$nul_jq"'
    {v: 1, id: $id, kind: "prepare", state: "queued", draft: ($draft | n), role: ($role | n), model: $t.model,
     then: (if $draft == "" then null else $thn end), at: $at, dest: ($dest | n),
     source: $src, request: $req, recipe: null, estimate: null,
     progress: {frac: 0, out_time: 0, speed: null, eta: null},
     unit: ($unit | n), pid: null, started: $now, updated: $now, ended: null,
     output: null, warnings: [], error: null, applied: null}' >"$jf.tmp" && mv -f "$jf.tmp" "$jf"
  # the draft waits for it (a save waits too); a newer prepare for the same
  # screen of the draft replaces an older one
  if [[ -n $draft && -n $MD_ROLE ]]; then
    old=$(editor_media_pending "$draft" "$MD_ROLE" "$id") || die "could not note the job in the draft of $draft"
    if [[ -n $old && $old != "$id" ]]; then media_cancel_job "$old" superseded --nowait || true; fi
  fi
  if [[ -n ${PCL_MEDIA_INLINE:-} ]]; then
    media_run_job "$id" || true
  elif ! md_start_job_unit "$id"; then
    md_job_end "$id" "" stopped "systemd-run could not start the job"
    md_fail 3 systemd-run "systemd-run could not start $unit"
  fi
  md_out "$(jq -c '{job: .}' "$jf")" "prepare: job $id $(md_job_get "$id" .state)"
}
# md_start_job_unit <id>: the job in its own capped unit (plan §2.5).
md_start_job_unit() {
  local id=$1 extra=() v
  for v in PCL_TEST_OVERRIDES PCL_MEDIA_UNIT PCL_HEAVY_SLOTS PCL_HEAVY_DIR PCL_MEDIA_WAIT PCL_MEDIA_STAGE_CAP \
           PCL_MEDIA_FREE_BYTES PCL_MEDIA_MEM PCL_MEDIA_READRATE PCL_MODELS PROFILE PCL_LIB; do
    if [[ -n ${!v:-} ]]; then extra+=(--setenv="$v=${!v}"); fi
  done
  systemd-run --user --quiet --collect --unit="$MEDIA_UNIT-$id" \
    -p MemoryMax="$(md_job_mem)" -p MemorySwapMax=512M -p CPUWeight=20 -p CPUQuota="$(( $(nproc 2>/dev/null || echo 2) * 50 ))%" \
    -p Nice=10 -p IOSchedulingClass=idle -p KillMode=control-group -p TimeoutStopSec=15 -p RuntimeMaxSec=1800 \
    --setenv=HOME="$HOME" --setenv=PCL_MEDIA_IN_UNIT=1 "${extra[@]}" \
    -- "$(readlink -f "$0")" media --run-job "$id" >/dev/null 2>&1
}

# ---- the job runner (plan §2.5) -------------------------------------------------------------
# media --run-job <id>: in its unit (or inline): a heavy slot, probe, recipe,
# (estimate), encode, finish. The runner ends every job it started: done,
# failed {code, text} or cancelled; its EXIT trap removes the scratch.
media_run_job() {
  local id=${1:-}
  md_job_id_ok "$id" || die "media --run-job: bad job id '$id'"
  [[ -f $(media_job_file "$id") ]] || die "media --run-job: no job $id"
  ( md_runner "$id" ) || true
}
# Progress weights: probing 2, estimating 10 (models with a transcode cap),
# encoding 85, finishing 3.
md_progress() {   # md_progress <frac of the whole> [out_time] [speed] [eta]
  md_job_upd "$MJ_ID" --argjson f "$1" --argjson o "${2:-null}" --argjson s "${3:-null}" --argjson e "${4:-null}" '
    .progress.frac = ([.progress.frac // 0, ($f * 1000 | floor) / 1000] | max)
    | if $o != null then .progress.out_time = $o else . end
    | if $s != null then .progress.speed = $s else . end
    | if $e != null then .progress.eta = $e else . end' || true
}
md_state() { md_job_upd "$MJ_ID" --arg s "$1" '.state = $s' || true; }
md_runner_term() {
  MJ_TERM=1
  if [[ -n ${MJ_CHILD:-} ]]; then kill -TERM "$MJ_CHILD" 2>/dev/null || true; fi
}
md_runner_exit() {
  if [[ -n ${MJ_CHILD:-} ]]; then kill -TERM "$MJ_CHILD" 2>/dev/null || true; wait "$MJ_CHILD" 2>/dev/null || true; fi
  if [[ -z $MJ_DONE ]]; then
    md_job_end "$MJ_ID" "$(cat "$MEDIA_JOBS/$MJ_ID.cancel" 2>/dev/null || true)" "${MJ_ERR:-stopped}" "${MJ_ERRT:-It stopped before it finished}"
  fi
  if [[ -z $MJ_KEEP ]]; then rm -rf "${MJ_WORK:?}"; fi
}
md_cancelled() { [[ -n $MJ_TERM || -f $MEDIA_JOBS/$MJ_ID.cancel ]]; }
md_fail_job() { MJ_ERR=$1 MJ_ERRT=$2; return 1; }
# md_take_slot: a flock -n slot of pcl-heavy's (${XDG_RUNTIME_DIR}/pcl-heavy/slot<i>,
# i < PCL_HEAVY_SLOTS), so previews, auto-theme and media jobs share the
# machine-wide limit; "waiting" meanwhile, "busy" after PCL_MEDIA_WAIT (1800 s).
md_take_slot() {
  local dir n i t0=$EPOCHSECONDS waited='' wmax=${PCL_MEDIA_WAIT:-1800}
  dir=${PCL_HEAVY_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pcl-heavy} n=${PCL_HEAVY_SLOTS:-2}
  mkdir -p "$dir"
  while :; do
    for ((i = 0; i < n; i++)); do
      exec {MJ_SLOT}>"$dir/slot$i"
      if flock -n "$MJ_SLOT"; then return 0; fi
      exec {MJ_SLOT}>&-
    done
    if [[ -z $waited ]]; then waited=1; md_state waiting; fi
    if md_cancelled; then return 1; fi
    if (( EPOCHSECONDS - t0 >= wmax )); then
      md_fail_job busy "Other media jobs kept every slot busy for $((wmax / 60)) min"; return 1
    fi
    sleep 1
  done
}
# md_bg <cmd...>: start a heavy command in the background (capped unless
# this job has its own unit); MJ_CHILD is its pid. md_wait: its status.
md_bg() {
  local MD_ARGV=()
  md_capped_argv --mem "$(md_job_mem)" "$@"
  "${MD_ARGV[@]}" &
  MJ_CHILD=$!
}
md_wait() {
  local rc=0
  while kill -0 "$MJ_CHILD" 2>/dev/null; do
    if md_cancelled; then kill -TERM "$MJ_CHILD" 2>/dev/null || true; fi
    sleep 0.2
  done
  wait "$MJ_CHILD" || rc=$?
  MJ_CHILD=
  return "$rc"
}
# md_poll_encode <out seconds> <frac before> <weight> <total>: follow
# ffmpeg -progress while it runs; the record is written every 0.5 s at most.
md_poll_encode() {
  local dur=$1 base=$2 w=$3 tot=$4 us sp f eta rc=0
  while kill -0 "$MJ_CHILD" 2>/dev/null; do
    sleep 0.5
    if md_cancelled; then kill -TERM "$MJ_CHILD" 2>/dev/null || true; continue; fi
    read -r us sp < <(awk -F= '/^out_time_us=/ { u = $2 } /^speed=/ { s = $2 } END { printf "%d %s\n", u + 0, s + 0 }' \
                        "$MJ_WORK/progress" 2>/dev/null || echo "0 0") || true
    f=$(awk -v u="${us:-0}" -v d="$dur" -v b="$base" -v w="$w" -v t="$tot" \
          'BEGIN { x = (d > 0 ? u / 1e6 / d : 0); if (x > 1) x = 1; if (x < 0) x = 0; printf "%.4f", (b + w * x) / t }')
    eta=null
    if awk -v s="${sp:-0}" 'BEGIN { exit !(s > 0) }'; then
      eta=$(awk -v u="${us:-0}" -v d="$dur" -v s="$sp" 'BEGIN { e = (d - u / 1e6) / s; if (e < 0) e = 0; printf "%d", e + 0.5 }')
    else sp=null; fi
    md_progress "$f" "$(awk -v u="${us:-0}" 'BEGIN { printf "%.1f", u / 1e6 }')" "$sp" "$eta"
  done
  wait "$MJ_CHILD" || rc=$?
  MJ_CHILD=
  return "$rc"
}
md_runner() {
  MJ_ID=$1 MJ_WORK=$MEDIA_WORK/$1 MJ_CHILD='' MJ_TERM='' MJ_KEEP='' MJ_DONE='' MJ_ERR='' MJ_ERRT='' MJ_SLOT=''
  local jf rec src t recipe key mode kind reuse='' w_est=0 tot limit chk ext dest
  jf=$(media_job_file "$MJ_ID")
  trap md_runner_term TERM INT HUP
  trap md_runner_exit EXIT
  mkdir -p "$MJ_WORK"
  md_job_upd "$MJ_ID" --argjson pid "$BASHPID" '.pid = $pid' || true
  md_take_slot || return 1
  # probing
  md_state probing
  src=$(md_job_get "$MJ_ID" .source.path)
  [[ -f $src ]] || { md_fail_job broken "The file is gone"; return 1; }
  rec=$(media_probe_json "$src")
  if [[ $rec != *'"error":null'* ]]; then
    t=$(jq -r '.error // "broken"' <<<"$rec"); md_fail_job "$t" "$(md_error_text "$t")"; return 1
  fi
  t=$(media_jq -c --arg m "$(md_job_get "$MJ_ID" .model)" 'media_target($m; $M)')
  [[ $t != null ]] || { md_fail_job unsupported "Unknown screen model"; return 1; }
  # the recipe (plan §2.4) and its key: the choices that shape the output,
  # the source's identity and the prep version (not the frame the crop was
  # chosen on, nor what the estimate trims)
  recipe=$(media_jq -c --argjson p "$rec" --argjson t "$t" --slurpfile j "$jf" --argjson ver "$MEDIA_PREP_VERSION" '
    $j[0].request as $q | ($q.start // 0) as $start
    | media_crop($q.crop; $p.dw; $p.dh; $t.w; $t.h) as $crop
    | ($crop == [0, 0, $p.dw, $p.dh]) as $full
    | (if $p.kind == "image" then
         (if $t.image == "png" or $p.alpha or ($p.codec // "" | IN("png", "gif", "bmp")) then "png" else "jpeg" end) as $codec
         | {mode: (if $full and $p.dw == $t.w and $p.dh == $t.h and $p.alpha != true and ($p.rotation // 0) == 0
                      and (($p.orientation // "TopLeft") | IN("TopLeft", "Undefined"))
                      and ($p.codec // "") == $codec then "copy" else "still" end),
            codec: $codec, fps: null}
       else
         {mode: (if $full and $p.codec == "h264" and $p.pix_fmt == "yuv420p" and $p.w == $t.w and $p.h == $t.h
                     and ($p.rotation // 0) == 0 and ($p.sar // 1) == 1 and ($p.fps // 999) <= 60 and $p.alpha != true
                     and $p.interlaced != true and $p.hdr != true and ($p.container // "" | test("mp4|mov"))
                     and $start == 0 and $q.duration == null and ($p.duration // 1e9) <= $t.max_s then "remux" else "encode" end),
          codec: "h264", fps: ([($p.fps // $t.fps), $t.fps] | min | media_r3)}
       end) as $m
    | {v: 1, mode: $m.mode, crop: $crop, time: $q.time, start: $start, duration: $q.duration, fps: $m.fps,
       size: [$t.w, $t.h], codec: $m.codec,
       crf: (if $m.codec == "h264" then $t.crf else null end), maxrate: (if $m.codec == "h264" then $t.maxrate else null end),
       bg: (if $p.alpha then "black" else null end)}
    | . + {key_input: {v, mode, crop, start, duration, fps, size, codec, crf, maxrate, bg, max_s: $t.max_s,
                        src: {path: $p.path, size: $p.size, mtime: $p.mtime}, prep: $ver}}')
  key=$(jq -cS '.key_input' <<<"$recipe" | sha256sum | cut -c1-64)
  recipe=$(jq -c --arg k "$key" 'del(.key_input) + {key: $k}' <<<"$recipe")
  mode=$(jq -r .mode <<<"$recipe") kind=$(jq -r .kind <<<"$rec") dest=$(md_job_get "$MJ_ID" .dest)
  md_job_upd "$MJ_ID" --argjson r "$recipe" --argjson p "$rec" '.recipe = $r
    | .source = {path: $p.path, size: $p.size, mtime: $p.mtime, kind: $p.kind, w: $p.dw, h: $p.dh, duration: $p.duration, fps: $p.fps}' || true
  # dedupe 1: the draft already has this very recipe's output
  if reuse=$(md_find_reuse "$key"); then
    md_finish "$recipe" "$t" "$reuse"
    return
  fi
  # the estimate step: capped models (the pump), for clips long enough to matter
  if [[ $(jq -r '.cap_mb // empty' <<<"$t") != "" && ($mode == encode || $mode == remux) ]] &&
     jq -e --argjson r "$recipe" '((.duration // 0) - ($r.start // 0)) > 20' >/dev/null <<<"$rec"; then
    w_est=10
  fi
  tot=$((2 + w_est + 85 + 3))
  md_progress "$(awk -v t="$tot" 'BEGIN { printf "%.4f", 2 / t }')"
  if md_cancelled; then return 1; fi
  # the clip it keeps (plan §2.6): max_s, the estimate for capped models, the trim window
  limit=$(jq -r .max_s <<<"$t")
  if (( w_est > 0 )); then
    md_state estimating
    md_estimate "$rec" "$recipe" "$t" "$tot" >"$MJ_WORK/estimate.json" || return 1
    limit=$(jq -r .limit_s "$MJ_WORK/estimate.json")
    md_job_upd "$MJ_ID" --slurpfile e "$MJ_WORK/estimate.json" '.estimate = $e[0]' || true
  fi
  if md_cancelled; then return 1; fi
  recipe=$(media_jq -c --argjson r "$recipe" --argjson p "$rec" --argjson l "$limit" '$r
    | if .mode == "copy" or .mode == "still" then .duration = null else
        ((($p.duration // 0) - (.start // 0)) | if . < 0 then 0 else . end) as $avail
        | ([$avail, (.duration // $avail), $l] | min) as $keep
        | .duration = ($keep | media_r3)
        | if .mode == "remux" and $keep < $avail - 0.05 then .mode = "encode" else . end end')
  mode=$(jq -r .mode <<<"$recipe")
  md_job_upd "$MJ_ID" --argjson r "$recipe" --argjson w "$(media_jq -c --argjson r "$recipe" --argjson p "$rec" --argjson t "$t" '
    [ (if $r.duration != null and ((($p.duration // 0) - ($r.start // 0)) - $r.duration) > 0.5 then
         {code: "trimmed", text: "Uses the first \($r.duration | media_mmss).", keep_s: ($r.duration | floor)} else empty end),
      (if $r.crop[2] < $t.w * 0.8 then {code: "low-res", text: "Low resolution; it may look soft"} else empty end),
      (if $p.hdr then {code: "hdr", text: "Colours may look flat"} else empty end),
      (if ($p.dw // 0) > 7680 or ($p.dh // 0) > 7680 or ($p.duration // 0) > 7200 then
         {code: "huge", text: "A very large source; preparing it takes a while"} else empty end),
      (if $p.alpha then {code: "alpha", text: "Transparent parts become black"} else empty end) ]')" \
    '.recipe = $r | .warnings = $w' || true
  # disk (plan §2.6), now that the length is known
  chk=$(md_disk_check "$(md_out_estimate "$(jq -r '.duration // 0' <<<"$recipe")" "$t" "$kind")" \
        "$([[ -z $dest ]] && echo 1 || echo 0)" "$MJ_WORK" "${dest:-$STATE_DIR/drafts}")
  if [[ -n $chk ]]; then md_fail_job "${chk%% *}" "${chk#* }"; return 1; fi
  # encoding
  md_state encoding
  ext=$(md_out_ext "$recipe")
  md_encode "$rec" "$recipe" "$t" "$((2 + w_est))" "$tot" "$MJ_WORK/out.$ext" || return 1
  if md_cancelled; then return 1; fi
  md_finish "$recipe" "$t" ""
}
md_out_ext() {
  case $(jq -r '.codec' <<<"$1") in png) echo png ;; jpeg) echo jpg ;; *) echo mp4 ;; esac
}
# md_find_reuse <key>: "rel" of a file the draft (media_sources) or its theme
# (src/media.json) made with this recipe before, when it is still there.
md_find_reuse() {
  local key=$1 draft root rel df
  draft=$(md_job_get "$MJ_ID" .draft)
  [[ -n $draft && -z $(md_job_get "$MJ_ID" .dest) ]] || return 1
  df=$(editor_draft_file "$draft")
  [[ -f $df ]] || return 1
  root=$(editor_media_root "$draft")
  rel=$(jq -r --arg k "$key" '[(.media_sources // {}) | to_entries[] | select(.value.recipe.key == $k) | .key][0] // empty' "$df" 2>/dev/null || true)
  if [[ -z $rel && -n $root && -f $root/src/media.json ]]; then
    rel=$(jq -r --arg k "$key" '[(.files // {}) | to_entries[] | select(.value.recipe.key == $k) | .key][0] // empty' "$root/src/media.json" 2>/dev/null || true)
  fi
  [[ -n $rel ]] || return 1
  editor_draft_abspath "$draft" "$rel" >/dev/null 2>&1 || return 1
  echo "$rel"
}
# md_estimate <probe> <recipe> <target> <total weight>: the pump's clip limit
# (plan §2.6): three 4 s samples (at 10, 50 and 90 %) through our recipe and
# then encoded as the daemon does (libx264 ultrafast, no B-frames, 4
# threads, the panel's transposed size): bytes/s x 1.25 and the speed;
# limit = min(max_s, 0.8 x cap / bytes_per_s, 100 s x speed) and, with
# hardware_video, 0.8 x cap / (w h fps / 4 / 8). Sampling fails: the
# hardware formula stands in. Prints the estimate object.
md_estimate() {
  local rec=$1 recipe=$2 t=$3 tot=$4 d start pos T n=0 bytes=0 secs=0 wall=0 len s0 s1 b ok=1 hw
  d=$(jq -r '.duration // 0' <<<"$rec") start=$(jq -r '.start // 0' <<<"$recipe")
  hw=$(jq -r '.hardware_video // false' "$CFG_LIVE" 2>/dev/null || echo false)
  for pos in 0.1 0.5 0.9; do
    md_cancelled && return 1
    read -r T len < <(awk -v d="$d" -v s="$start" -v p="$pos" 'BEGIN {
        a = d - s; if (a < 0) a = 0; t = s + a * p - 2; if (t < s) t = s; l = 4; if (t + l > d) l = d - t; if (l < 0) l = 0
        printf "%.3f %.3f\n", t, l }')
    awk -v l="$len" 'BEGIN { exit !(l > 0.2) }' || continue
    s0=${EPOCHREALTIME/./}
    if md_sample_encode "$rec" "$recipe" "$t" "$T" "$len" "$MJ_WORK/sample$n.h264" && [[ -s $MJ_WORK/sample$n.h264 ]]; then
      s1=${EPOCHREALTIME/./}
      b=$(stat -c %s "$MJ_WORK/sample$n.h264")
      bytes=$((bytes + b)) wall=$((wall + s1 - s0))
      secs=$(awk -v a="$secs" -v l="$len" 'BEGIN { printf "%.3f", a + l }')
    else
      md_cancelled && return 1
      ok=
      break
    fi
    rm -f "$MJ_WORK/sample$n.h264"
    n=$((n + 1))
    md_progress "$(awk -v n="$n" -v t="$tot" 'BEGIN { printf "%.4f", (2 + 10 * n / 3) / t }')"
  done
  if (( n == 0 )); then ok=; fi
  jq -nc --argjson t "$t" --argjson fps "$(jq -r '.fps // 30' <<<"$recipe")" --arg ok "$ok" --argjson bytes "$bytes" \
    --argjson secs "$secs" --argjson wall "$wall" --argjson hw "$hw" '
    ($t.cap_mb * 1048576 * 0.8) as $room
    | ($t.w * $t.h * $fps / 4 / 8) as $hwbps
    | if $ok == "1" and $secs > 0 and $wall > 0 then
        ($bytes / $secs * 1.25 | floor) as $bps | ($secs / ($wall / 1e6)) as $speed
        | {method: "sampled", bytes_per_s: $bps, speed: (($speed * 100 | floor) / 100),
           by_size_s: (if $bps > 0 then ($room / $bps | floor) else null end), by_speed_s: (100 * $speed | floor)}
      else {method: "fallback", bytes_per_s: ($hwbps | floor), speed: null, by_size_s: ($room / $hwbps | floor), by_speed_s: null} end
    | .by_hw_s = (if $hw == true then ($room / $hwbps | floor) else null end)
    | .max_s = $t.max_s
    | .limit_s = ([.max_s, .by_size_s, .by_speed_s, .by_hw_s] | map(numbers) | min)'
}
# md_sample_encode <probe> <recipe> <target> <at s> <seconds> <out>: one
# estimate sample (tests replace it to force the fallback).
md_sample_encode() {
  local rec=$1 recipe=$2 t=$3 at=$4 len=$5 out=$6 vf tr fps
  fps=$(jq -r '.fps // 30' <<<"$recipe")
  case $(jq -r '((.orientation // 0) % 360 + 360) % 360' <<<"$t") in
    90) tr=,transpose=1 ;; 180) tr=,transpose=1,transpose=1 ;; 270) tr=,transpose=2 ;; *) tr= ;;
  esac
  vf=$(md_vf "$rec" "$recipe" "$t")$tr
  md_bg ffmpeg -nostdin -v error -y -ss "$at" -t "$len" -i "file:$(jq -r .path <<<"$rec")" -map 0:v:0 -an -sn -dn \
    -vf "$vf" -r "$fps" -c:v libx264 -preset ultrafast -x264opts bframes=0 -threads 4 -pix_fmt yuv420p \
    -color_range pc -f h264 "$out" 2>>"$MJ_WORK/err"
  md_wait
}
# md_vf <probe> <recipe> <target>: the -vf chain of an encode (no alpha).
md_vf() {
  jq -rn --argjson p "$1" --argjson r "$2" --argjson t "$3" '
    (if $p.interlaced then "yadif," else "" end)
    + "crop=\($r.crop[2]):\($r.crop[3]):\($r.crop[0]):\($r.crop[1]),scale=\($t.w):\($t.h):flags=lanczos,setsar=1,fps=\($r.fps // $t.fps)"'
}
# md_encode <probe> <recipe> <target> <weight before> <total> <out>: the
# recipe's output (plan §2.4), with progress. Never writes next to the source.
md_encode() {
  local rec=$1 recipe=$2 t=$3 base=$4 tot=$5 out=$6 src mode dur start fps crf mr vf g ok='' in=() alpha
  src=$(jq -r .path <<<"$rec") mode=$(jq -r .mode <<<"$recipe") alpha=$(jq -r '.alpha == true' <<<"$rec")
  dur=$(jq -r '.duration // 0' <<<"$recipe") start=$(jq -r '.start // 0' <<<"$recipe")
  : >"$MJ_WORK/progress"
  case $mode in
    copy)
      cp --reflink=auto -- "$src" "$out" || { md_fail_job broken "Could not copy the file"; return 1; } ;;
    still)
      if MAGICK_TEMPORARY_PATH=$MJ_WORK md_bg magick -limit memory 512MiB -limit map 1GiB "${src}[0]" -auto-orient \
          -background black -alpha remove -alpha off \
          -crop "$(jq -r '"\(.crop[2])x\(.crop[3])+\(.crop[0])+\(.crop[1])"' <<<"$recipe")" +repage \
          -filter Lanczos -resize "$(jq -r '"\(.size[0])x\(.size[1])!"' <<<"$recipe")" -strip -quality 95 "$out" \
          2>>"$MJ_WORK/err" && md_wait && [[ -s $out ]]; then
        ok=1
      fi
      if [[ -z $ok ]]; then
        md_cancelled && return 1
        rm -f "$out"
        vf="crop=$(jq -r '"\(.crop[2]):\(.crop[3]):\(.crop[0]):\(.crop[1])"' <<<"$recipe"),scale=$(jq -r '"\(.size[0]):\(.size[1])"' <<<"$recipe"):flags=lanczos,setsar=1"
        if [[ $alpha == true ]]; then vf="format=rgba,premultiply=inplace=1,format=rgb24,$vf"; fi
        md_bg ffmpeg -nostdin -v error -y -i "file:$src" -frames:v 1 -vf "$vf" -q:v 2 -map_metadata -1 "$out" 2>>"$MJ_WORK/err"
        md_wait && [[ -s $out ]] || { md_cancelled && return 1; md_fail_job unsupported "This PC can't decode the picture"; return 1; }
      fi ;;
    remux)
      md_bg ffmpeg -nostdin -hide_banner -loglevel error -y -i "file:$src" -map 0:v:0 -c copy -an -sn -dn \
        -map_metadata -1 -map_chapters -1 -movflags +faststart -progress "file:$MJ_WORK/progress" -nostats "$out" 2>>"$MJ_WORK/err"
      md_poll_encode "$dur" "$base" 85 "$tot" || { md_cancelled && return 1; md_fail_job unsupported "Could not copy the video stream"; return 1; } ;;
    encode)
      fps=$(jq -r '.fps // 30' <<<"$recipe") crf=$(jq -r .crf <<<"$recipe") mr=$(jq -r .maxrate <<<"$recipe")
      g=$(awk -v f="$fps" 'BEGIN { printf "%d", f * 2 + 0.5 }')
      if awk -v s="$start" 'BEGIN { exit !(s > 0) }'; then in+=(-ss "$start"); fi
      if [[ -n ${PCL_MEDIA_READRATE:-} ]]; then in+=(-readrate "$PCL_MEDIA_READRATE"); fi
      in+=(-i "file:$src" -t "$dur")
      if [[ $alpha == true ]]; then
        vf=$(md_vf "$rec" "$recipe" "$t")
        in+=(-filter_complex "color=black:s=$(jq -r '"\(.w)x\(.h)"' <<<"$t"):r=${fps}[bg];[0:v:0]${vf}[fg];[bg][fg]overlay=shortest=1,format=yuv420p[out]"
             -map "[out]")
      else
        in+=(-map 0:v:0 -vf "$(md_vf "$rec" "$recipe" "$t"),format=yuv420p")
      fi
      md_bg ffmpeg -nostdin -hide_banner -loglevel error -y "${in[@]}" -an -sn -dn -map_metadata -1 -map_chapters -1 \
        -c:v libx264 -preset veryfast -crf "$crf" -maxrate "$mr" -bufsize "$(( $(jq -r '.maxrate_bits' <<<"$t") * 2 ))" \
        -g "$g" -threads "$(md_threads)" -pix_fmt yuv420p -movflags +faststart \
        -progress "file:$MJ_WORK/progress" -nostats "$out" 2>>"$MJ_WORK/err"
      if ! md_poll_encode "$dur" "$base" 85 "$tot" || [[ ! -s $out ]]; then
        md_cancelled && return 1
        if grep -qiE 'no space left|disk quota' "$MJ_WORK/err" 2>/dev/null; then md_fail_job disk-full "The disk filled up"; return 1; fi
        md_fail_job unsupported "ffmpeg could not decode the video: $(tail -n1 "$MJ_WORK/err" 2>/dev/null | cut -c1-160)"
        return 1
      fi ;;
  esac
  [[ -s $out ]] || { md_fail_job broken "Nothing came out"; return 1; }
  md_progress "$(awk -v b="$base" -v t="$tot" 'BEGIN { printf "%.4f", (b + 85) / t }')" "$dur" "" 0
}
# md_same_file <sha256> <bytes> <base>...: "base \0 rel \0" of a file under
# <base>/media with these bytes (dedupe 2), through the hash cache.
md_same_file() {
  local sha=$1 bytes=$2 b f; shift 2
  for b in "$@"; do
    [[ -n $b && -d $b/media ]] || continue
    while IFS= read -r -d '' f; do
      if [[ $(media_sha256 "$f") == "$sha" ]]; then printf '%s\0%s\0' "$b" "${f#"$b"/}"; return 0; fi
    done < <(find "$b/media" -type f -size "${bytes}c" ! -name '.*' -print0 2>/dev/null)
  done
  return 1
}
# media_sha256 <file>: its sha256, through $CACHE/media/hashes.tsv (dev ino size mtime sha256).
media_sha256() {
  local f=$1 id h
  id=$(stat -Lc '%d %i %s %Y' -- "$f" 2>/dev/null) || return 1
  id=${id// /$'\t'}
  if [[ -f $MEDIA_DIR/hashes.tsv ]]; then
    h=$(awk -F'\t' -v k="$id" '($1 "\t" $2 "\t" $3 "\t" $4) == k { h = $5 } END { print h }' "$MEDIA_DIR/hashes.tsv" 2>/dev/null || true)
    if [[ -n $h ]]; then echo "$h"; return 0; fi
  fi
  h=$(sha256sum <"$f" | cut -c1-64) || return 1
  mkdir -p "$MEDIA_DIR"
  printf '%s\t%s\n' "$id" "$h" >>"$MEDIA_DIR/hashes.tsv"
  echo "$h"
}
# md_finish <recipe> <target> <reused rel or "">: finishing (plan §2.5):
# sha, dedupe, into the stage (or --out), then into the draft; done.
md_finish() {
  local recipe=$1 t=$2 reuse=$3 draft dest out ext sha bytes rel abs stage root df same=() rc=0 rev jf
  jf=$(media_job_file "$MJ_ID")
  md_state finishing
  draft=$(md_job_get "$MJ_ID" .draft) dest=$(md_job_get "$MJ_ID" .dest)
  if [[ -n $reuse ]]; then
    abs=$(editor_draft_abspath "$draft" "$reuse")
    md_job_upd "$MJ_ID" --arg rel "$reuse" --arg abs "$abs" --argjson b "$(stat -c %s -- "$abs" 2>/dev/null || echo 0)" \
      --arg sha "$(media_sha256 "$abs" || true)" '.output = {rel: $rel, abs: $abs, bytes: $b, sha256: $sha, reused: true}' || true
  else
    ext=$(md_out_ext "$recipe") out=$MJ_WORK/out.$ext
    [[ -s $out ]] || { md_fail_job broken "Nothing came out"; return 1; }
    sha=$(sha256sum <"$out" | cut -c1-64) bytes=$(stat -c %s "$out")
    if [[ -n $dest ]]; then
      # --out: a new file, never over one that appeared meanwhile
      if [[ -e $dest ]]; then md_fail_job invalid "$dest appeared meanwhile; it was left alone"; return 1; fi
      if cp --reflink=auto -- "$out" "$dest.$BASHPID.tmp"; then mv -n -- "$dest.$BASHPID.tmp" "$dest" || true; fi
      if [[ -e $dest.$BASHPID.tmp || ! -f $dest ]]; then rm -f "$dest.$BASHPID.tmp"; md_fail_job invalid "Could not write $dest"; return 1; fi
      md_job_upd "$MJ_ID" --arg abs "$dest" --argjson b "$bytes" --arg sha "$sha" \
        '.output = {rel: null, abs: $abs, bytes: $b, sha256: $sha, reused: false}' || true
      MJ_DONE=1
      md_job_upd "$MJ_ID" '.state = "done" | .ended = $now | .pid = null | .error = null | .progress = (.progress + {frac: 1, eta: 0})' || true
      return 0
    fi
    df=$(editor_draft_file "$draft")
    if [[ ! -f $df ]]; then
      # the draft is gone: the output stays in work/ for GC (orphans go after a day)
      MJ_KEEP=1
      md_job_upd "$MJ_ID" --arg abs "$out" --argjson b "$bytes" --arg sha "$sha" \
        '.output = {rel: null, abs: $abs, bytes: $b, sha256: $sha, reused: false}' || true
      md_fail_job no-draft "The unsaved edits it was for are gone"; return 1
    fi
    stage=$(editor_draft_stage "$draft" --create) root=$(editor_media_root "$draft")
    [[ -n $stage && -d $stage/media ]] || { md_fail_job no-draft "The draft has no stage"; return 1; }
    mapfile -d '' -t same < <(md_same_file "$sha" "$bytes" "$stage" "$root" || true)
    if (( ${#same[@]} == 2 )); then
      # dedupe 2: these bytes are there already
      abs=${same[0]}/${same[1]} rel=${same[1]}
      md_job_upd "$MJ_ID" --arg rel "$rel" --arg abs "$abs" --argjson b "$bytes" --arg sha "$sha" \
        '.output = {rel: $rel, abs: $abs, bytes: $b, sha256: $sha, reused: true}' || true
    else
      rel=media/$(md_stem "$(md_job_get "$MJ_ID" .source.path)")-${sha:0:8}.$ext abs=$stage/$rel
      # recorded before it lands, so GC counts it as a job output meanwhile
      md_job_upd "$MJ_ID" --arg rel "$rel" --arg abs "$abs" --argjson b "$bytes" --arg sha "$sha" \
        '.output = {rel: $rel, abs: $abs, bytes: $b, sha256: $sha, reused: false}' || true
      if [[ ! -e $abs ]] && ! mv -T -- "$out" "$abs" 2>/dev/null; then
        if ! cp --reflink=auto -- "$out" "$stage/media/.${abs##*/}.$BASHPID.tmp" ||
           ! mv -f -- "$stage/media/.${abs##*/}.$BASHPID.tmp" "$abs"; then
          rm -f "$stage/media/.${abs##*/}.$BASHPID.tmp"
          md_fail_job disk-full "Could not store the output"; return 1
        fi
      fi
    fi
  fi
  # into the draft as "then" says (none: its wait just ends)
  if [[ -n $(md_job_get "$MJ_ID" .role) ]]; then
    rev=$(editor_media_apply "$draft" "$jf" 2>"$MJ_WORK/apply.err") || rc=$?
    if (( rc == 0 )); then
      rev=$(tail -n1 <<<"$rev")
      if ! md_int_ok "${rev:-x}"; then rev=$(editor_draft_rev "$draft" 2>/dev/null || true); fi
      md_job_upd "$MJ_ID" --argjson rev "${rev:-null}" '.applied = {rev: $rev, at: $now}' || true
    elif [[ ! -f $(editor_draft_file "$draft") ]]; then
      md_fail_job no-draft "The unsaved edits it was for are gone"; return 1
    elif (( rc == 1 )); then
      MJ_DONE=1
      md_job_upd "$MJ_ID" '.state = "cancelled" | .ended = $now | .pid = null
        | .error = {code: "superseded", text: "A newer choice replaced it"}' || true
      return 0
    else
      # 2: the draft refused it (its reason is on stderr); the job failed
      rev=$(sed 's/^pc-lights: //' "$MJ_WORK/apply.err" 2>/dev/null | tail -n1 | cut -c1-200)
      md_fail_job not-applied "${rev:-The unsaved edits did not take it}"
      return 1
    fi
  fi
  MJ_DONE=1
  md_job_upd "$MJ_ID" '.state = "done" | .ended = $now | .pid = null | .error = null
    | .progress = (.progress + {frac: 1, eta: 0})' || true
}

# ---- GC (plan §1.4) -----------------------------------------------------------------------
# md_ref_paths: every file something still needs, absolute and NUL-separated,
# each behind its kind (live | theme | history | draft | job | preview):
# CFG_LIVE's and TPL_LIVE's paths, every theme (theme.json,
# theme.known-good.json, the files in clip folders, its template files and
# their paths), the history (against its theme folder), every draft (through
# its stage and its media root), job outputs that wait to be applied, and
# the preview's saved and applied screens.
md_ref_paths() {
  local f d name root stage df
  # [kind, base, ref] triples, then resolved
  {
    jq -c '[.lcds[]? | .. | objects | .path? | strings] | .[] | ["live", "", .]' "$CFG_LIVE" 2>/dev/null || true
    jq -c '[.. | objects | .path? | strings] | .[] | ["live", "", .]' "$TPL_LIVE" 2>/dev/null || true
    for f in "$CACHE"/preview/applied-lcds.json "$CACHE"/preview/saved-lcds.json; do
      jq -c '[.. | objects | .path? | strings] | .[] | ["preview", "", .]' "$f" 2>/dev/null || true
    done
    for d in "$THEME_DIR"/*/; do
      d=${d%/}
      for f in "$d/theme.json" "$d/theme.known-good.json"; do
        [[ -f $f ]] || continue
        md_jq_refs "$f" | jq -c --arg d "$d" '["theme", $d, .]'
      done
    done
    for d in "$STATE_DIR"/theme-history/*/; do
      d=${d%/} name=${d##*/}
      for f in "$d"/*.json; do
        [[ -f $f ]] || continue
        md_jq_refs "$f" | jq -c --arg d "$THEME_DIR/$name" '["history", $d, .]'
      done
    done
    for df in "$STATE_DIR"/drafts/*.json; do
      [[ -f $df ]] || continue
      name=${df##*/} name=${name%.json}
      root=$(jq -r '.media_root // empty' "$df" 2>/dev/null || true) stage=$STATE_DIR/drafts/$name.media
      jq '.theme // {}' "$df" >"$TMP/md-gc-draft.json" 2>/dev/null || continue
      md_jq_refs "$TMP/md-gc-draft.json" | jq -c --arg s "$stage" --arg r "$root" '["draft", $s, .], (if $r != "" then ["draft", $r, .] else empty end)'
    done
    jq -nc --rawfile raw <(md_job_lines) '
      [$raw | split("\u001e")[] | select(length > 0) | try fromjson catch null | objects
       | select((.state | IN("done", "failed", "cancelled") | not)
                or (.state == "done" and .error == null and (.applied == null or .then == "none")))
       | .output.abs? | strings] | .[] | ["job", "", .]'
  } | jq -rj 'select(type == "array" and (.[2] | type == "string") and .[2] != "")
      | .[0] + "\u0000" + (if (.[2] | startswith("/")) then .[2] else .[1] + "/" + (.[2] | ltrimstr("./")) end) + "\u0000"' |
    md_expand_refs
}
# md_jq_refs <theme json>: its references (JSON strings, one a line): screen
# paths and clips, _prev paths, templates, and the paths inside each template.
md_jq_refs() {
  local f=$1 t d=${1%/*}
  jq -c -L "$PCL_LIB" 'include "theme"; '"$(<"$PCL_LIB/media.jq")"' media_refs(.)[]' "$f" 2>/dev/null || true
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    [[ $t == /* ]] || t=$d/$t
    jq -c '[.. | objects | .path? | strings] | .[]' "$t" 2>/dev/null || true
  done < <(jq -r '(.templates // [])[]? | strings' "$f" 2>/dev/null || true)
}
# md_expand_refs: NUL "kind path" pairs -> the same with every file inside a
# referenced folder, paths normalised (realpath -ms).
md_expand_refs() {
  local kind p f
  while IFS= read -r -d '' kind && IFS= read -r -d '' p; do
    p=$(realpath -ms -- "$p" 2>/dev/null || echo "$p")
    printf '%s\0%s\0' "$kind" "$p"
    if [[ -d $p ]]; then
      while IFS= read -r -d '' f; do printf '%s\0%s\0' "$kind" "$f"; done < <(find "$p" -type f -print0 2>/dev/null)
    fi
  done
}
# md_gc_candidates [draft]: NUL "kind path" of the files GC may delete:
# "stage" (a draft stage's; with a name, only that draft's) and "made" (a
# theme file its src/media.json lists), plus "hand" (a theme's own media
# file that isn't editor-made: reported, never deleted). Without a name.
md_gc_candidates() {
  local one=${1:-} d f rel
  for d in "$STATE_DIR"/drafts/*.media; do
    [[ -d $d ]] || continue
    if [[ -n $one && ${d##*/} != "$one.media" ]]; then continue; fi
    while IFS= read -r -d '' f; do printf 'stage\0%s\0' "$f"; done < <(find "$d" -type f -print0 2>/dev/null)
  done
  [[ -z $one ]] || return 0
  for d in "$THEME_DIR"/*/; do
    d=${d%/}
    [[ -d $d/media ]] || continue
    local -A made=()
    if [[ -f $d/src/media.json ]]; then
      while IFS= read -r -d '' rel; do made[$rel]=1; done < <(jq -j '(.files // {}) | keys[] | . + "\u0000"' "$d/src/media.json" 2>/dev/null || true)
    fi
    while IFS= read -r -d '' f; do
      rel=${f#"$d"/}
      if [[ -n ${made[$rel]:-} ]]; then printf 'made\0%s\0' "$f"; else printf 'hand\0%s\0' "$f"; fi
    done < <(find "$d/media" -type f ! -name '.*' -print0 2>/dev/null)
    unset made
  done
}
# md_gc_media [draft] [--dry-run]: delete what may go (plan §1.4): a stage
# file or an editor-made theme file that nothing references. Under the
# drafts lock, the references are read after the candidates were listed.
# Prints {deleted, freed_bytes, kept_referenced, unused_hand_placed, history_bytes}.
md_gc_media() {
  local one='' dry='' a kind p w=$TMP/md-gc.$BASHPID
  for a in "$@"; do case $a in --dry-run) dry=1 ;; *) one=$a ;; esac; done
  mkdir -p "$w"
  md_gc_candidates "$one" >"$w/cand"
  md_drafts_lock || { rm -rf "$w"; echo '{"deleted":[],"freed_bytes":0,"kept_referenced":0,"unused_hand_placed":[],"history_bytes":0,"skipped":"busy"}'; return 0; }
  md_ref_paths >"$w/refs"
  jq -nc --rawfile c "$w/cand" --rawfile r "$w/refs" '
    def pairs: split("\u0000") as $x | [range(0; ($x | length) / 2 | floor) as $i | {k: $x[2 * $i], p: $x[2 * $i + 1]}];
    ($r | pairs | reduce .[] as $x ({}; .[$x.p] += [$x.k])) as $by
    | [$c | pairs[] | . + {refs: ($by[.p] // [] | unique)}]
    | {del: [.[] | select(.k != "hand" and (.refs | length) == 0) | .p],
       kept: ([.[] | select(.k != "hand" and (.refs | length) > 0)] | length),
       hand: [.[] | select(.k == "hand" and (.refs | length) == 0) | .p],
       history: [.[] | select(.refs == ["history"]) | .p]}' >"$w/plan"
  local deleted=() freed=0 hb=0 b dirs=()
  while IFS= read -r -d '' p; do
    b=$(stat -c %s -- "$p" 2>/dev/null || echo 0)
    if [[ -z $dry ]]; then rm -f -- "$p" || continue; fi
    deleted+=("$p") freed=$((freed + b))
  done < <(jq -j '.del[] + "\u0000"' "$w/plan")
  while IFS= read -r -d '' p; do hb=$((hb + $(stat -c %s -- "$p" 2>/dev/null || echo 0))); done < <(jq -j '.history[] + "\u0000"' "$w/plan")
  if [[ -z $dry ]] && (( ${#deleted[@]} )); then md_gc_provenance "${deleted[@]}"; fi
  # stages of drafts that are gone: emptied above, now removed
  for p in "$STATE_DIR"/drafts/*.media; do
    [[ -d $p ]] || continue
    if [[ -n $one && ${p##*/} != "$one.media" ]]; then continue; fi
    if [[ -z $dry && ! -f ${p%.media}.json ]]; then find "$p" -depth -type d -empty -delete 2>/dev/null || true; fi
  done
  md_drafts_unlock
  jq -c --argjson f "$freed" --argjson hb "$hb" '{deleted: $ARGS.positional, freed_bytes: $f, kept_referenced: .kept,
    unused_hand_placed: .hand, history_bytes: $hb}' "$w/plan" --args "${deleted[@]}"
  rm -rf "$w"
}
# md_gc_provenance <deleted path>...: each theme's src/media.json without
# the files GC deleted (tmp + mv: themes share it through hard links).
md_gc_provenance() {
  local p d rels mj t
  local -A by=()
  for p in "$@"; do
    [[ $p == "$THEME_DIR"/*/media/* ]] || continue
    d=${p#"$THEME_DIR"/} d=$THEME_DIR/${d%%/*}
    by[$d]+=${p#"$d"/}$'\n'
  done
  for d in "${!by[@]}"; do
    mj=$d/src/media.json
    [[ -f $mj ]] || continue
    rels=${by[$d]} t=$mj.$BASHPID.tmp
    # (the name is set here: $BASHPID in jq's redirection would be jq's own)
    if jq --arg r "$rels" '($r | split("\n") | map(select(. != ""))) as $gone
        | .files |= with_entries(select(.key | IN($gone[]) | not))' "$mj" >"$t" 2>/dev/null && [[ -s $t ]]; then
      mv -f "$t" "$mj" || true
    fi
    rm -f "$t"
  done
}
# md_gc_caches [--dry-run]: thumbnails (oldest first, down to 300 MB), crop
# frames older than a day, ended jobs older than 7 days, scratch without a
# running job (orphaned outputs after a day). Prints {thumbs, frames, jobs, work, bytes}.
md_gc_caches() {
  local dry=${1:-} cap=$MEDIA_THUMB_CAP total=0 n_t=0 n_f=0 n_j=0 n_w=0 bytes=0 line sz p id st ended d
  if [[ -d $MEDIA_THUMBS ]]; then
    total=$(find "$MEDIA_THUMBS" -type f -printf '%s\n' 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
    if (( total > cap )); then
      while IFS= read -r -d '' line; do
        (( total > cap )) || break
        sz=${line#* } sz=${sz%% *} p=${line#* * }
        if [[ -z $dry ]]; then rm -f -- "$p"; fi
        total=$((total - sz)) bytes=$((bytes + sz)) n_t=$((n_t + 1))
      done < <(find "$MEDIA_THUMBS" -type f -name '*.webp' -printf '%T@ %s %p\0' 2>/dev/null | sort -z -n)
    fi
  fi
  if [[ -d $MEDIA_FRAMES ]]; then
    while IFS= read -r -d '' line; do
      sz=${line%% *} p=${line#* }
      if [[ -z $dry ]]; then rm -f -- "$p"; fi
      bytes=$((bytes + sz)) n_f=$((n_f + 1))
    done < <(find "$MEDIA_FRAMES" -type f -mmin +1440 -printf '%s %p\0' 2>/dev/null)
    if [[ -z $dry ]]; then find "$MEDIA_FRAMES" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true; fi
  fi
  for p in "$MEDIA_JOBS"/j-*.json; do
    [[ -f $p ]] || continue
    id=${p##*/} id=${id%.json}
    st=$(md_job_get "$id" .state) ended=$(md_job_get "$id" '.ended // .updated // 0')
    md_is_final "$st" || continue
    if (( EPOCHSECONDS - ${ended:-0} > 7 * 86400 )); then
      if [[ -z $dry ]]; then rm -rf -- "$p" "$MEDIA_JOBS/$id.cancel" "${MEDIA_WORK:?}/$id"; fi
      n_j=$((n_j + 1))
    fi
  done
  for d in "$MEDIA_WORK"/*/; do
    d=${d%/} id=${d##*/}
    [[ -d $d ]] || continue
    st=$(md_job_get "$id" .state)
    # a running job's scratch stays; so does, for a day, an orphaned output
    # (its draft went away) and a folder without a record (being set up)
    if [[ -n $st ]] && ! md_is_final "$st"; then continue; fi
    if [[ -z $st || $(md_job_get "$id" .error.code) == no-draft ]] &&
       [[ -n $(find "$d" -maxdepth 0 -mmin -1440 -print 2>/dev/null) ]]; then continue; fi
    sz=$(du -sb -- "$d" 2>/dev/null | cut -f1 || echo 0)
    if [[ -z $dry ]]; then rm -rf -- "$d"; fi
    bytes=$((bytes + ${sz:-0})) n_w=$((n_w + 1))
  done
  if [[ -z $dry ]]; then md_index_compact; fi
  jq -nc --argjson t "$n_t" --argjson f "$n_f" --argjson j "$n_j" --argjson w "$n_w" --argjson b "$bytes" \
    '{thumbs: $t, frames: $f, jobs: $j, work: $w, bytes: $b}'
}
# media_gc [--dry-run]: the whole GC; prints the report (plan §1.2).
media_gc() {
  local dry=${1:-} m c a=()
  if [[ $dry == --dry-run ]]; then a=(--dry-run); fi
  md_reap_jobs
  m=$(md_gc_media "${a[@]}")
  c=$(md_gc_caches "$dry")
  jq -nc --argjson m "$m" --argjson c "$c" --argjson dry "$([[ -n $dry ]] && echo true || echo false)" \
    '$m + {freed_bytes: ($m.freed_bytes + $c.bytes), caches: $c, dry_run: $dry}'
}
# media_gc_draft <name>: after a save, discard, rename or preview end: that
# draft's stage without what nothing references; when the draft is gone,
# its jobs are cancelled and its stage goes. Quiet; never fails.
media_gc_draft() {
  local name=$1 f id
  [[ -n $name ]] || return 0
  if [[ ! -f $(editor_draft_file "$name") ]]; then
    for f in "$MEDIA_JOBS"/j-*.json; do
      [[ -f $f ]] || continue
      id=${f##*/} id=${id%.json}
      if [[ $(md_job_get "$id" .draft) == "$name" ]] && ! md_is_final "$(md_job_get "$id" .state)"; then
        media_cancel_job "$id" --nowait || true
      fi
    done
  fi
  md_gc_media "$name" >/dev/null 2>&1 || true
}
md_gc_cmd() {
  local dry='' r
  while (( $# )); do
    case $1 in --dry-run) dry=--dry-run ;; --json) MD_JSON=1 ;; *) md_fail 2 usage "$MEDIA_USAGE" ;; esac
    shift
  done
  r=$(media_gc "$dry")
  md_out "$r" "$(jq -r '"gc: \(if .dry_run then "would delete" else "deleted" end) \(.deleted | length) file(s) and \(.caches.thumbs + .caches.frames + .caches.jobs + .caches.work) cache item(s), \(.freed_bytes / 1048576 | floor) MB; kept \(.kept_referenced) referenced; \(.unused_hand_placed | length) unused hand-placed"' <<<"$r")"
}

# ---- the "media" command ------------------------------------------------------------------
media_cmd() {
  local verb=${1:-}
  (( $# )) && shift
  MD_JSON=
  mkdir -p "$MEDIA_DIR"
  case $verb in
    list) md_list "$@" ;;
    probe) md_probe_cmd "$@" ;;
    frame) md_frame_cmd "$@" ;;
    thumb) md_thumb_cmd "$@" ;;
    prepare) md_prepare "$@" ;;
    jobs) md_jobs_cmd "$@" ;;
    cancel) md_cancel_cmd "$@" ;;
    gc) md_gc_cmd "$@" ;;
    --run-job) media_run_job "$@" ;;
    --index) media_index_run ;;
    *) md_fail 2 usage "$MEDIA_USAGE" ;;
  esac
}
