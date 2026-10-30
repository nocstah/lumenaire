# lib/pc-lights/media.jq — the media pipeline's jq half (screens plan §1.3, §2):
# probe records, fit scores, crop maths, the media list, recipe keys and the
# references GC keeps.
#
# Only defs: media.sh (media_jq) and the editor's screens view splice this
# file in as text after 'include "theme";' (jq 1.8.2 aborts on a module that
# includes another), so it may use theme.jq (models, th_role_dev, ...) and
# every name here starts with media_.
#
# Owner: screens plan §8 B1 (media pipeline)
# Public: media_title media_fit media_target media_crop media_norm_ffprobe
#         media_norm_magick media_list media_refs media_mmss media_status

def media_r3: if type == "number" then (. * 1000 | round) / 1000 else . end;
def media_num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
# "30000/1001" -> 29.97; null for 0/0 and junk.
def media_rate: if type == "string" and test("^[0-9]+/[0-9]+$") then
    (split("/") | map(tonumber)) as [$n, $d] | (if $d > 0 and $n > 0 then $n / $d else null end)
  else media_num end;
# 125 -> "2:05"
def media_mmss: (. // 0 | floor) as $s | "\($s / 60 | floor):\($s % 60 | tostring | if length < 2 then "0" + . else . end)";

# ---- names --------------------------------------------------------------------
def media_video_exts: ["mp4", "m4v", "mov", "mkv", "webm", "avi"];
def media_image_exts: ["png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif"];
def media_ext: split("/") | last | if test("\\.") then split(".") | last | ascii_downcase else "" end;
# The kind a file's name suggests (before it is probed).
def media_ext_kind: media_ext as $e
  | if $e == "gif" then "animation" elif ($e | IN(media_image_exts[])) then "image" else "video" end;
# media_title: a path -> a short title: the name without its extension (and
# without the -<sha8> a staged copy carries), _ and - as spaces, a space
# between a word and a number ("planet37" -> "planet 37").
def media_title:
  split("/") | last
  | sub("\\.[A-Za-z0-9]{1,5}$"; "")
  | sub("-[0-9a-f]{8}$"; "")
  | gsub("[_-]+"; " ")
  | gsub("(?<a>[A-Za-z]{3})(?<d>[0-9])"; "\(.a) \(.d)")
  | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
  | if . == "" then "untitled" else . end;

# ---- models -------------------------------------------------------------------
def media_prep_defaults($M): {fps: 30, max_s: 120, crf: 21, maxrate: "8M", image: "auto"}
  + ((($M | objects | ._prep_defaults) // {}) | with_entries(select(.key | startswith("_") | not)));
# "12M" -> 12000000 (bits/s)
def media_bits: if type == "number" then . else
  (ascii_downcase | capture("^(?<n>[0-9.]+)(?<u>[km]?)$")) as $c
  | ($c.n | tonumber) * ({"": 1, k: 1000, m: 1000000}[$c.u]) | floor end;
# media_target($model; $M): what media prepared for a model must be
# (models.json: media size, orientation, prep), or null for an unknown model.
def media_target($fam; $M): models($M).lcd[$fam] as $m
  | if $m == null then null else
      (media_prep_defaults($M) + ($m.prep // {})) as $p
      | {model: $fam, aspect: $m.aspect, screen: ($m.screen // null), w: $m.media[0], h: $m.media[1],
         orientation: ($m.orientation // 0), max_fps: ($m.max_fps // null), cap_mb: ($m.transcode_cap_mb // null),
         fps: $p.fps, max_s: $p.max_s, crf: $p.crf, maxrate: $p.maxrate, maxrate_bits: ($p.maxrate | media_bits),
         image: $p.image, lconnect: ($m.lconnect // [])} end;
# {folder: Model} from every model's lconnect folders (the first model wins).
def media_lc_map($M): reduce (models($M).lcd | to_entries[] | .key as $k | (.value.lconnect // [])[] | {f: ., m: $k}) as $x
  ({}; if has($x.f) then . else .[$x.f] = $x.m end);

# ---- probe records (plan §2.1) ------------------------------------------------
# {path, size, mtime, kind: video|image|animation, container, codec, pix_fmt,
#  w, h, dw, dh, rotation, sar, fps, duration, frames, alpha, hdr, interlaced,
#  audio, error: null|no-picture|unsupported|broken}; dw x dh is what a viewer
# sees (rotation and pixel aspect applied).
def media_rot: media_num // 0 | round | ((. % 360) + 360) % 360;
def media_norm_ffprobe($j; $path; $size; $mtime):
  ($j.streams // []) as $s
  | ([$s[] | select(.codec_type == "video" and ((.disposition.attached_pic // 0) != 1))] | first) as $v
  | ($j.format // {}) as $f
  | if $v == null then
      {path: $path, size: $size, mtime: $mtime, kind: null, container: ($f.format_name // null), codec: null, pix_fmt: null,
       w: null, h: null, dw: null, dh: null, rotation: 0, sar: 1, fps: null, duration: ($f.duration | media_num | media_r3),
       frames: null, alpha: false, hdr: false, interlaced: false, audio: any($s[]; .codec_type == "audio"), error: "no-picture"}
    else
      ($v.width | media_num) as $w | ($v.height | media_num) as $h
      | ([($v.side_data_list // [])[] | .rotation? | media_num | numbers] | first // ($v.tags.rotate | media_num) // 0 | media_rot) as $rot
      | (($v.sample_aspect_ratio // "1:1") | if test("^[0-9]+:[0-9]+$") then split(":") | map(tonumber)
         | if .[0] > 0 and .[1] > 0 then .[0] / .[1] else 1 end else 1 end) as $sar
      | (if $w != null and $h != null then [($w * $sar | round), $h] else [$w, $h] end) as [$bw, $bh]
      | ($rot == 90 or $rot == 270) as $swap
      | (($v.avg_frame_rate | media_rate) as $a | ($v.r_frame_rate | media_rate) as $r
         | if $a != null and $a > 0 and $a < 1000 then $a elif $r != null and $r < 1000 then $r else null end) as $fps
      | (($v.nb_frames | media_num) // ($v.nb_read_packets | media_num)) as $frames
      | ($f.format_name // "") as $fmt
      | ($v.codec_name // null) as $codec
      | ($v.pix_fmt // "") as $pf
      | (if $codec == "gif" or $codec == "apng" then (if ($frames // 2) > 1 then "animation" else "image" end)
         elif ($fmt | test("_pipe$|^image2$|^webp$")) then "image"
         elif $frames == 1 then "image"
         else "video" end) as $kind
      | {path: $path, size: $size, mtime: $mtime, kind: $kind, container: ($fmt | if . == "" then null else . end),
         codec: $codec, pix_fmt: (if $pf == "" then null else $pf end), w: $w, h: $h,
         dw: (if $swap then $bh else $bw end), dh: (if $swap then $bw else $bh end),
         rotation: $rot, sar: ($sar | media_r3),
         fps: (if $kind == "image" then null else $fps | media_r3 end),
         duration: (if $kind == "image" then null else ($f.duration | media_num) // ($v.duration | media_num) | media_r3 end),
         frames: $frames,
         alpha: ($pf | test("^(rgba|argb|bgra|abgr|yuva|gbrap|ya[0-9]|rgba64|bgra64)") or ($pf == "pal8" and $codec == "gif")),
         hdr: (($v.color_transfer // "") | IN("smpte2084", "arib-std-b67")),
         interlaced: (($v.field_order // "") | IN("tt", "bb", "tb", "bt")),
         audio: any($s[]; .codec_type == "audio"),
         error: (if $codec == null or $w == null or $h == null or $w <= 0 or $h <= 0 then "unsupported" else null end)}
    end;
# One "w|h|orientation|channels|frames|format" line of magick identify -ping.
def media_norm_magick($line; $path; $size; $mtime):
  ($line | split("|")) as $x
  | ($x[0] | media_num) as $w | ($x[1] | media_num) as $h
  | ($x[2] // "" | IN("LeftTop", "RightTop", "RightBottom", "LeftBottom")) as $swap
  | ($x[5] // "" | ascii_downcase) as $fmt
  | {path: $path, size: $size, mtime: $mtime, kind: "image", container: $fmt, codec: $fmt, pix_fmt: null,
     w: $w, h: $h, dw: (if $swap then $h else $w end), dh: (if $swap then $w else $h end),
     rotation: ({RightTop: 90, BottomRight: 180, LeftBottom: 270}[$x[2] // ""] // 0), sar: 1, fps: null, duration: null,
     frames: 1, alpha: (($x[3] // "") | split(" ")[0] | test("a$")), hdr: false, interlaced: false, audio: false,
     orientation: ($x[2] // null),
     error: (if $w == null or $h == null or $w <= 0 or $h <= 0 then "unsupported" else null end)};
def media_broken($path; $size; $mtime; $code):
  {path: $path, size: $size, mtime: $mtime, kind: null, container: null, codec: null, pix_fmt: null, w: null, h: null,
   dw: null, dh: null, rotation: 0, sar: 1, fps: null, duration: null, frames: null, alpha: false, hdr: false,
   interlaced: false, audio: false, error: $code};

# ---- fit (plan §1.3b) ---------------------------------------------------------
# media_fit($probe; $target): how well a probed file fits a model.
#   keep   area a centre crop to the model's aspect keeps, min(r, 1/r),
#          r = source aspect / model aspect
#   scale  model width / crop width (above 1: upscaled)
#   score  keep^1.5 x (scale > 1 ? scale^-0.5 : 1) x (made for the same shape
#          1.05, for another 0.9, unknown 1), at most 1
#   state  exact (same size) | scaled (keep >= 0.98) | cropped (keep >= 0.6)
#          | poor | unknown (not probed, or unusable)
#   note   long (over the model's max_s) | low-res (scale > 1.25) | hdr | alpha | null
# $probe may carry made_for (a model) and made_for_aspect; $target is
# media_target (or any {model, aspect, w, h, max_s}).
def media_fit($p; $t):
  if ($p | type) != "object" or $p.error != null or ($p.dw // 0) <= 0 or ($p.dh // 0) <= 0
     or ($t | type) != "object" or ($t.w // 0) <= 0 or ($t.h // 0) <= 0 then
    {state: "unknown", keep: null, scale: null, score: null, note: null}
  else
    ($p.dw / $p.dh) as $sa | ($t.w / $t.h) as $ta | ($sa / $ta) as $r
    | ([$r, 1 / $r] | min) as $keep
    | (if $sa > $ta then $p.dh * $ta else $p.dw end) as $cw
    | ($t.w / $cw) as $scale
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
  end;

# ---- crop (plan §1.2 "media prepare") -----------------------------------------
# media_crop($crop; $sw; $sh; $tw; $th): the crop the encoder uses, [x, y, w, h]
# in display pixels of a $sw x $sh source, for a $tw x $th model. No crop:
# the centre "cover" crop. A given crop keeps its centre: an aspect more than
# 1 % off the model's is shrunk to it, a crop bigger than the frame is scaled
# down (aspect kept), then moved inside the frame; all four even.
def media_even: (. / 2 | floor) * 2;
def media_crop($c; $sw; $sh; $tw; $th):
  ($tw / $th) as $ta
  | (if ($c | type) == "array" and ($c | length) == 4 and ($c | all(type == "number")) and $c[2] > 0 and $c[3] > 0 then $c
     else (if $sw / $sh > $ta then [($sh * $ta), $sh] else [$sw, ($sw / $ta)] end) as [$w, $h]
       | [(($sw - $w) / 2), (($sh - $h) / 2), $w, $h] end) as [$x, $y, $w, $h]
  | ($x + $w / 2) as $cx | ($y + $h / 2) as $cy
  | (if ((($w / $h) / $ta) - 1 | fabs) > 0.01 then
       (if $w / $h > $ta then [($h * $ta), $h] else [$w, ($w / $ta)] end) else [$w, $h] end) as [$w, $h]
  | ([1, $sw / $w, $sh / $h] | min) as $s
  | ($w * $s) as $w | ($h * $s) as $h
  | ([[($cx - $w / 2), ($sw - $w)] | min, 0] | max) as $x
  | ([[($cy - $h / 2), ($sh - $h)] | min, 0] | max) as $y
  | ([($w | media_even), 2] | max) as $w | ([($h | media_even), 2] | max) as $h
  | [([[($x | media_even), ($sw - $w | media_even)] | min, 0] | max),
     ([[($y | media_even), ($sh - $h | media_even)] | min, 0] | max), $w, $h];

# ---- theme references ---------------------------------------------------------
# media_theme_refs($T): every media reference of a theme's screens (v3 keyed
# by role, v2 a list): {key, model, ref}; ref is a file or a clip folder,
# relative to the theme folder (or absolute).
def media_theme_refs($T):
  [($T.screens // {}) | to_entries[] | .key as $k | .value | (if type == "array" then .[] else . end) | objects
   | . as $e | (($e.path | strings), (($e.clips // []) | arrays | .[] | strings), ($e._prev.path? | strings))
   | {key: $k, model: ($e.model // null), ref: ltrimstr("./")}];
def media_ref_hit($rel; $ref): $rel == $ref or ($rel | startswith($ref + "/"));
# media_refs($T): every path a theme (or draft theme) needs kept: screen
# paths, clip files and folders, _prev paths, template files.
def media_refs($T): [media_theme_refs($T)[].ref] + [($T.templates // []) | arrays | .[] | strings] | unique;

# ---- the list (plan §1.3b) ----------------------------------------------------
def media_group_label($id; $M): models($M) as $MM
  | if $id == "theme" then "This theme" elif $id == "themes" then "Other themes"
    elif $id == "lconnect:uploads" then "Your L-Connect uploads" elif $id == "library" then "Library"
    elif $id == "videos" then "Videos" elif $id == "pictures" then "Pictures" elif $id == "files" then "Other files"
    elif ($id | startswith("lconnect:")) then ($MM.lcd[$id | ltrimstr("lconnect:")] // {}) as $m
      | if $m.screen == "fan" then "Fan clips" elif $m.screen == "pump" and $m.aspect == "round" then "Round pump clips"
        elif $m.screen == "pump" then "Pump clips"
        elif $m.screen == "main" and $m.media == [1920, 480] then "8.8\" clips" else "Screen clips" end
    else $id end;
# media_list($a; $raw; $idx; $thumbs; $M): the list reply, then (a second
# output) the paths the indexer should look at, the page's first.
#   $a      {source, target (media_target), role, q, offset, limit, running,
#            can_index, tools_missing, truncated, thumbdir, stage, root,
#            lib_roots, files_roots: {videos, pictures}, theme (the theme
#            source's theme JSON), prov: {rel: model}, themes: {name: {rel: model}}}
#   $raw    NUL-separated records of 8 fields: tag (stage | root | theme:<name>
#           | lib:<i> | files:videos|pictures|other), path, size, mtime, dev,
#           inode, id, thumbnail key
#   $idx    index records; $thumbs NUL-separated thumbnail file names
def media_list($a; $raw; $idx; $thumbs; $M):
  models($M) as $MM
  | media_lc_map($M) as $lc
  | $a.target as $t
  | (reduce ($idx[] | objects | select(.path | type == "string")) as $r ({}; .[$r.path] = $r)) as $im
  | (reduce ($thumbs | split("\u0000")[] | select(length > 0)) as $n ({};
      if ($n | endswith(".webp")) then .[$n | rtrimstr(".webp")] = "ready"
      elif ($n | endswith(".fail")) then .[$n | rtrimstr(".fail")] //= "failed" else . end)) as $tk
  | ($raw | split("\u0000")) as $f
  | [range(0; ($f | length) / 8 | floor) as $i | $f[$i * 8:$i * 8 + 8]
     | {tag: .[0], path: .[1], size: (.[2] | tonumber), mtime: (.[3] | tonumber), dev: .[4], ino: .[5],
        id: ("m-" + .[6]), k: .[7]}] as $recs
  # one item per file: theme source by rel (the stage wins), the rest by inode
  | (if ($a.source | startswith("theme:")) then
       [$recs[] | . + {rel: (if .tag == "stage" then .path | ltrimstr($a.stage + "/") else .path | ltrimstr($a.root + "/") end)}]
       | group_by(.rel) | map((map(select(.tag == "stage")) + map(select(.tag != "stage")))[0] + {in_use: []})
     else
       $recs | group_by([.dev, .ino]) | map(
         [.[] | select(.tag | startswith("theme:")) | .tag | ltrimstr("theme:")] as $names
         | ((map(select(.tag | startswith("theme:") | not)) + map(select(.tag | startswith("theme:"))))[0])
         + {in_use: ($names | unique)})
     end) as $files
  | [$files[] | . as $r
     | ($im[$r.path] // null) as $ix
     | ($ix != null and $ix.size == $r.size and $ix.mtime == $r.mtime) as $fresh
     | ($r.path | split("/") | .[-2] // "") as $parent
     # where it came from: group, rel, made_for
     | (if $r.tag == "stage" or $r.tag == "root" then
          [media_theme_refs($a.theme // {})[] | select(media_ref_hit($r.rel; .ref))] as $hits
          | {group: "theme", rel: $r.rel, where: $r.tag, used_by: ([$hits[].key | tostring] | unique),
             made_for: ([$hits[].model | strings][0] // $a.prov[$r.rel] // null)}
        elif ($r.tag | startswith("theme:")) then
          ($r.tag | ltrimstr("theme:")) as $tn
          | ($r.path | ltrimstr($a.theme_dir + "/" + $tn + "/")) as $trel
          | {group: "themes", rel: null, where: null, used_by: [],
             made_for: ([($a.themes[$tn] // {}) | to_entries[] | select(media_ref_hit($trel; .key)) | .value | strings][0])}
        elif ($r.tag | startswith("lib:")) then
          ($a.lib_roots[$r.tag | ltrimstr("lib:") | tonumber] // "") as $root
          | ($r.path | ltrimstr($root + "/") | split("/") | .[:-1]) as $segs
          | ([$segs[] | $lc[.] | strings][0]) as $mf
          | {group: (if ($segs | index("uploaded")) != null then "lconnect:uploads"
                     elif $mf != null then "lconnect:" + $mf else "library" end),
             rel: null, where: null, used_by: [], made_for: $mf}
        else
          {group: ($r.tag | ltrimstr("files:") | if . == "videos" or . == "pictures" then . else "files" end),
           rel: null, where: null, used_by: [], made_for: null}
        end) as $o
     | (if $fresh then $ix + {made_for: $o.made_for, made_for_aspect: ($MM.lcd[$o.made_for // ""].aspect // null)} else null end) as $p
     | ($tk[$r.k] // "pending") as $ts
     | {id: $r.id, path: $r.path, rel: $o.rel, where: $o.where, group: $o.group, title: ($r.path | media_title),
        kind: (if $fresh and $ix.kind != null then $ix.kind else $r.path | media_ext_kind end),
        w: (if $fresh then $ix.dw else null end), h: (if $fresh then $ix.dh else null end),
        duration: (if $fresh then $ix.duration else null end), fps: (if $fresh then $ix.fps else null end),
        bytes: $r.size, mtime: $r.mtime,
        probe_state: (if $fresh | not then "pending" elif $ix.error != null then "failed" else "ready" end),
        error: (if $fresh then $ix.error else null end),
        thumb: (if $ts == "ready" then "\($a.thumbdir)/\($r.k[0:2])/\($r.k).webp" else null end),
        thumb_state: $ts,
        made_for: $o.made_for,
        fit: (if $fresh then media_fit($p; $t) else media_fit(null; $t) end),
        in_use: $r.in_use, used_by: $o.used_by}] as $all
  | (($a.q // "") | ascii_downcase) as $q
  | [$all[] | select($q == "" or (.title | ascii_downcase | contains($q))
                     or (.path | split("/") | .[-2] // "" | ascii_downcase | contains($q)))] as $items
  # group order: clips made for this shape, other themes, uploads, the rest
  # of the library, clips made for other shapes; then Videos, Pictures
  | ([$items[].group] | unique) as $gids
  | (def grank: if . == "theme" then [0, ""]
         elif startswith("lconnect:") and . != "lconnect:uploads" and ($MM.lcd[ltrimstr("lconnect:")].aspect // "") == $t.aspect then [1, .]
         elif . == "themes" then [2, ""] elif . == "lconnect:uploads" then [3, ""] elif . == "library" then [4, ""]
         elif startswith("lconnect:") then [5, .] elif . == "videos" then [6, ""] elif . == "pictures" then [7, ""]
         else [8, .] end;
     $gids | sort_by(grank)) as $order
  | ($order | to_entries | map({(.value): .key}) | add // {}) as $gpos
  | ($items | sort_by($gpos[.group],
       (if .probe_state == "ready" then 0 elif .probe_state == "pending" then 1 else 2 end),
       -(.fit.score // 0), -.mtime, .path)) as $sorted
  | ($a.offset // 0) as $off | ($a.limit // 60) as $lim
  | ([$sorted[] | select(.probe_state == "pending" or .thumb_state == "pending")] | length) as $todo
  | {v: 1, source: $a.source,
     for: {role: ($a.role // null), model: $t.model, shape: $t.aspect, media: [$t.w, $t.h]},
     total: ($sorted | length), offset: $off, limit: $lim,
     indexing: {state: (if $todo == 0 then "done" elif $a.can_index then "running" else "off" end),
                done: ([$sorted[] | select(.probe_state != "pending")] | length), of: ($sorted | length)},
     tools_missing: ($a.tools_missing // []), truncated: ($a.truncated // false),
     groups: [$order[] | {id: ., label: media_group_label(.; $M)}],
     items: $sorted[$off:$off + $lim]},
    ([($sorted[$off:$off + $lim] + $sorted[:$off] + $sorted[$off + $lim:])[]
      | select(.probe_state == "pending" or .thumb_state == "pending") | .path]);

# ---- jobs ---------------------------------------------------------------------
# media_status($jobs; $now): status --json's "media" (contract v1.3): the
# running jobs and the ones that ended in the last hour, newest first.
def media_final: IN("done", "failed", "cancelled");
def media_status($jobs; $now):
  [$jobs[] | objects | select(.id | type == "string")
   | select((.state | media_final | not) or ($now - (.ended // .updated // 0)) <= 3600)] as $j
  | {running: ([$j[] | select(.state | media_final | not)] | length),
     jobs: [$j | sort_by(-(.started // 0), .id)[:20][]
            | {id, draft, role, state, progress: (.progress.frac // null), error, then, applied}]};
