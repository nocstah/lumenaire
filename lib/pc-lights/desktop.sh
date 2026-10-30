# lib/pc-lights/desktop.sh — the desktop wallpaper per theme (the Motion Wallpaper plugin)
#
# Sourced by bin/lumenaire right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook, for every command but the read-only reports the
# plugin polls (status, themes and sensors --json; status --json reads this
# module's files itself, json.sh DESKTOP_V14_JQ). It only defines functions
# and constants; nothing runs at source time. Globals it reads (STATE_DIR,
# CACHE, THEME_DIR, TMP, ...) and helpers (die, log, put_json, nul_jq,
# omarchy_theme_for, theme_exists, active_name, ...) live in bin/lumenaire,
# json.sh and theme.sh.
#
# Owner: the desktop wallpaper (replaces the standalone motion-wallpaper-theme script)
# Public: desktop_cmd
# The whole engine is checked from bin/lumenaire; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154
#
# The Motion Wallpaper plugin (nosignal.motion-wallpaper) plays a video on the
# desktop background. An Omarchy theme can ship an animated version of any of
# its wallpapers: backgrounds/.animated/<the still's name>.mp4|webm|mkv (a
# hidden folder, so Omarchy's own wallpaper cycling never picks the video).
# Each Lumenaire theme has desktop settings: whether its animated wallpaper
# plays (animated), and how the plugin holds still while you work
# (pause_while_active, resume_after_idle seconds, while_active freeze|still).
# The desktop is on the Lumenaire theme its Omarchy theme pairs with
# (omarchy_theme_for, the mapping omarchy_pair uses), so sakura and
# sakura-light share sakura's settings.
#
# Portrait monitors: beside <still>.mp4 a theme may ship
# <still>.portrait.mp4|webm|mkv, a clip framed for a monitor turned a quarter
# (Hyprland transform 1, 3, 5 or 7). The main clip plays on every monitor
# (playAll); each connected portrait monitor then gets the portrait clip as
# its own (playOn <connector> <clip>). Without a portrait clip such a monitor
# follows the main clip: an override this engine set is dropped
# (clearScreen). A per-screen clip the user picked in the plugin's panel is
# never touched; one inside any theme's .animated folder counts as a theme's.
#
#   lumenaire desktop [--theme T] [--json]   the settings, and what is on screen
#   lumenaire desktop set [--theme T] animated|pause true|false|toggle
#   lumenaire desktop set [--theme T] resume <1-600> | while freeze|still
#   lumenaire desktop sync [--json]          apply the current theme's settings
#   lumenaire desktop toggle [--json]        moving <-> still on screen (the key)
#   lumenaire desktop watch                  sync on every monitor change (the
#                                            motion-wallpaper-monitors service)
#
# Files:
#   $STATE_DIR/desktop.json    the user's choices: {"v": 1, "defaults": {...},
#                              "themes": {"<theme>": {partial}}} (never theme.json:
#                              auto-themes keep refreshing, theme history stays clean)
#   $CACHE/desktop/owned       the clip this engine started: the only one it stops
#   $CACHE/desktop/owned-screens.json  the per-monitor clips this engine set,
#                              {"<connector>": "<clip>"}: the only ones it clears
#   $CACHE/desktop/state.json  what the last sync saw ({v, available, omarchy_theme,
#                              theme, has_animated, portrait, playing, user_clip, at}),
#                              for status --json
#   $CACHE/desktop/lock        one desktop change at a time (the hook, the watcher, the key)
#
# The plugin answers over the shell's IPC. A command reads its status once,
# without -q (-q is quiet: it swallows the reply), then sends only what
# differs, with -q: setPauseWhileActive/setResumeAfterIdle/setWhileActive
# when the theme's value differs from the plugin's, playAll/stop when the clip
# must change, playOn/clearScreen when a monitor's own clip must. With the
# shell down or the plugin missing every command still exits 0 and reports
# "available": false.

DESK_USAGE='usage: lumenaire desktop [--theme T] [--json]
       lumenaire desktop set [--theme T] animated|pause true|false|toggle
       lumenaire desktop set [--theme T] resume <1-600>
       lumenaire desktop set [--theme T] while freeze|still
       lumenaire desktop reset [--theme T]
       lumenaire desktop sync|toggle [--json]
       lumenaire desktop watch'

# The OSD glyphs (Nerd Font): a film strip, a picture.
DESK_GLYPH_ANIMATED='󰕧'
DESK_GLYPH_STILL='󰋩'

# The paths, at call time (a test's overrides may move STATE_DIR and CACHE).
# The old script's state is only read by the one-time migration.
desk_paths() {
  DESK_FILE=$STATE_DIR/desktop.json
  DESK_DIR=$CACHE/desktop
  DESK_OWNED=$DESK_DIR/owned
  DESK_OWNSCR_FILE=$DESK_DIR/owned-screens.json
  DESK_STATE=$DESK_DIR/state.json
  DESK_CUR=$HOME/.local/state/omarchy/current
  DESK_OLD=$HOME/.local/state/motion-wallpaper-theme
}

# desk_fail <rc> <code> <message>: {error, code} on stdout, the message on
# stderr, exit <rc>: 2 bad input (usage, invalid, not-found), 75 busy.
desk_fail() {
  echo "pc-lights: $3" >&2
  jq -nc --arg e "$3" --arg c "$2" '{error: $e, code: $c}'
  exit "$1"
}

# The hook, the path watcher and the key can fire together: one at a time.
# Whoever can't get the lock in 10 s gives up (a sync quietly: the one
# holding it does the same work).
desk_lock() {
  mkdir -p "$DESK_DIR"
  exec 4>"$DESK_DIR/lock"
  flock -w 10 4
}
desk_unlock() { exec 4>&-; }

# ---- settings ---------------------------------------------------------------------
# desktop.json as text ("" when missing), without a fork.
desk_read() {
  DESK_RAW=
  { IFS= read -r -d '' DESK_RAW <"$DESK_FILE"; } 2>/dev/null || true
}

# desk_settings <theme>: its effective settings (json.sh desk_view) into
# DESK_ANIMATED, DESK_PAUSE (true/false), DESK_RESUME (seconds), DESK_WHILE.
desk_settings() {
  desk_read
  IFS=$'\t' read -r DESK_ANIMATED DESK_PAUSE DESK_RESUME DESK_WHILE < <(jq -rn --arg d "$DESK_RAW" --arg t "$1" \
    "$DESKTOP_V14_JQ"'desk_view($d; $t).settings | [.animated, .pause_while_active, .resume_after_idle, .while_active] | @tsv')
}

# desk_store <theme> <key> <json value>: one setting of one theme, written
# atomically; other keys, themes and the defaults stay as they are. A file
# that isn't a JSON object is kept as desktop.json.bad and started over.
desk_store() {
  desk_read
  mkdir -p "$STATE_DIR"
  if [[ -n $DESK_RAW ]] && ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$DESK_RAW"; then
    cp -f "$DESK_FILE" "$DESK_FILE.bad" 2>/dev/null || true
    log "desktop: $DESK_FILE was not a JSON object; kept it as desktop.json.bad and started over"
    DESK_RAW=
  fi
  jq -n --arg d "$DESK_RAW" --arg t "$1" --arg k "$2" --argjson v "$3" "$DESKTOP_V14_JQ"'
    (((try ($d | fromjson) catch null) | objects) // {}) as $o
    | {v: 1, defaults: (($o.defaults | objects) // desk_builtin), themes: (($o.themes | objects) // {})}
      + ($o | del(.v, .defaults, .themes))
    | .themes[$t] = (((.themes[$t] | objects) // {}) + {($k): $v})' | put_json "$DESK_FILE"
}

# ---- what is on the desktop -------------------------------------------------------
# The Omarchy theme now (DESK_SLUG, "" without Omarchy) and the Lumenaire
# theme the desktop is on (DESK_THEME): the slug through omarchy-map.json,
# the way omarchy_pair pairs them; without Omarchy, the active case theme.
desk_current() {
  DESK_SLUG=
  { read -r DESK_SLUG <"$DESK_CUR/theme.name"; } 2>/dev/null || true
  if [[ $DESK_SLUG =~ ^[A-Za-z0-9._-]+$ ]]; then
    DESK_THEME=$(omarchy_theme_for "$DESK_SLUG")
  else
    DESK_SLUG='' DESK_THEME=$(active_name)
  fi
}

# desk_theme_ok <theme>: a theme --theme may name (exit 2 not-found if not):
# an existing theme, or the desktop's own (an auto-theme may not be built yet).
desk_theme_ok() {
  [[ $1 == "$DESK_THEME" ]] || theme_exists "$1" || desk_fail 2 not-found "no theme $THEME_DIR/$1/theme.json"
}

# The wallpaper on screen (DESK_BG, the still; "" when there is none, e.g.
# mid-switch) and its animated version (DESK_CLIP): the same name in a
# .animated folder. The theme's own folders come first: Omarchy replaces its
# working copy (current/theme) on every switch, so a clip played from there
# could vanish under the player, and two themes' clips would share one path.
# The portrait version (DESK_PCLIP) is <name>.portrait.<ext>, looked up the
# same way.
desk_wallpaper() {
  local d ext name dirs=()
  DESK_CLIP= DESK_PCLIP=
  DESK_BG=$(readlink -f "$DESK_CUR/background" 2>/dev/null) || DESK_BG=
  if [[ ! -f $DESK_BG ]]; then DESK_BG=; return 0; fi
  name=${DESK_BG##*/}
  name=${name%.*}
  if [[ -n $DESK_SLUG ]]; then
    dirs+=("$HOME/.config/omarchy/themes/$DESK_SLUG/backgrounds" "$HOME/.config/omarchy/backgrounds/$DESK_SLUG"
      "${OMARCHY_PATH:-/usr/share/omarchy}/themes/$DESK_SLUG/backgrounds")
  fi
  dirs+=("${DESK_BG%/*}")
  for d in "${dirs[@]}"; do
    for ext in mp4 webm mkv; do
      if [[ -z $DESK_CLIP && -f $d/.animated/$name.$ext ]]; then DESK_CLIP=$d/.animated/$name.$ext; fi
      if [[ -z $DESK_PCLIP && -f $d/.animated/$name.portrait.$ext ]]; then DESK_PCLIP=$d/.animated/$name.portrait.$ext; fi
    done
  done
}

# The connected monitors (hyprctl monitors -j; a disabled one isn't there)
# into DESK_MONS, [{name, portrait}]: portrait is a quarter turn, transform 1
# or 3 (5 and 7 are the same turns, flipped). "[]" without Hyprland.
desk_monitors() {
  DESK_MONS=$(hyprctl monitors -j 2>/dev/null | jq -c '[.[]? | objects | select(.disabled != true and (.name | type) == "string")
    | {name, portrait: ((((.transform // 0) | tonumber? // 0) | floor) % 2 == 1)}]' 2>/dev/null) || DESK_MONS=
  [[ -n $DESK_MONS ]] || DESK_MONS='[]'
}

# ---- the plugin -------------------------------------------------------------------
# desk_mw <fn> [arg]: a call that needs no reply (-q: quiet, best effort).
desk_mw() { omarchy-shell -q motion-wallpaper "$@" >/dev/null 2>&1 || true; }

# Read the plugin's status, without -q. DESK_AVAIL true/false and
# DESK_REASON (no-plugin: the shell runs without the plugin; shell-down: no
# shell, or it doesn't answer), and from the status MW_ENABLED, MW_PATH and
# MW_PAUSE, MW_RESUME, MW_WHILE ("" for a plugin without the pause settings),
# MW_OUTPUT (the monitors the main clip targets: "all" or a connector) and
# MW_SV (its per-monitor clips, screenVideos, as JSON; MW_PER_SCREEN false
# for a plugin without them).
desk_status() {
  local out='' rc=0 err='' f=()
  DESK_AVAIL=false DESK_REASON='' MW_ENABLED=false MW_PATH='' MW_PAUSE='' MW_RESUME='' MW_WHILE=''
  MW_OUTPUT=all MW_SV='{}' MW_PER_SCREEN=false
  out=$(omarchy-shell motion-wallpaper status 2>"$TMP/mw-err") || rc=$?
  if (( rc == 0 )); then
    mapfile -t f < <(jq -r 'objects | (.enabled == true), (.videoPath // "" | tostring),
      (if has("pauseWhileActive") then .pauseWhileActive == true | tostring else "" end),
      (.resumeAfterIdle // "" | tostring), (.whileActive // "" | tostring), (.output // "all" | tostring),
      (has("screenVideos") | tostring),
      ((.screenVideos | objects // {}) | with_entries(select(.value | type == "string")) | tojson)' <<<"$out" 2>/dev/null)
    if (( ${#f[@]} == 8 )); then
      DESK_AVAIL=true
      MW_ENABLED=${f[0]} MW_PATH=${f[1]} MW_PAUSE=${f[2]} MW_RESUME=${f[3]} MW_WHILE=${f[4]}
      MW_OUTPUT=${f[5]} MW_PER_SCREEN=${f[6]} MW_SV=${f[7]}
      return 0
    fi
  fi
  { IFS= read -r -d '' err <"$TMP/mw-err"; } 2>/dev/null || true
  case $rc:$err in
    0:* | *"Target not found"* | *"Function not found"*) DESK_REASON=no-plugin ;;
    *) DESK_REASON=shell-down ;;
  esac
  return 1
}

# The clip this engine started (DESK_OWN, "" for none), and desk_own <clip|"">;
# the per-monitor clips it set (DESK_OWNSCR, the file's text, "" for none).
desk_owned() {
  DESK_OWN= DESK_OWNSCR=
  { IFS= read -r DESK_OWN <"$DESK_OWNED"; } 2>/dev/null || true
  { IFS= read -r -d '' DESK_OWNSCR <"$DESK_OWNSCR_FILE"; } 2>/dev/null || true
}
desk_own() {
  DESK_OWN=$1
  if [[ -n $1 ]]; then
    mkdir -p "$DESK_DIR"
    printf '%s\n' "$1" | put_json "$DESK_OWNED"
  else
    rm -f "$DESK_OWNED"
  fi
}

# A clip inside a theme's backgrounds/.animated/ is that theme's, whoever
# started it: never the user's own pick, so a switch may replace or stop it.
# (2026-09-25: a stale sakura night clip, revived by the toggle, counted as
# the user's and kept playing on sakura-light over its own animation.)
desk_theme_clip() { [[ $1 == */backgrounds/.animated/* ]]; }

# What the plugin shows (the status read): DESK_PLAYING (a clip on screen:
# enabled, and its file is there) and DESK_USER (that clip is one the user
# picked: not started by this engine, not the theme's own, not any theme's).
desk_playing() {
  DESK_PLAYING=false DESK_USER=false
  if [[ $MW_ENABLED == true && -n $MW_PATH && -f $MW_PATH ]]; then
    DESK_PLAYING=true
    if [[ $MW_PATH != "$DESK_OWN" && $MW_PATH != "$DESK_CLIP" ]] && ! desk_theme_clip "$MW_PATH"; then DESK_USER=true; fi
  fi
}

# ---- per-monitor clips ------------------------------------------------------------
# A monitor's own clip in screenVideos is this engine's when it is the clip
# owned-screens.json holds for that monitor, or any theme's (.animated); every
# other entry is the user's ("" too: a monitor they blanked).
# shellcheck disable=SC2016 # jq, not shell
DESK_SCREENS_JQ='
  def own_of($raw): (((try ($raw | fromjson) catch null) | objects) // {}) | with_entries(select(.value | type == "string"));
  def theme_clip: type == "string" and test("/backgrounds/\\.animated/");
  def ours($sv; $o; $n): ($sv | has($n)) and (($o[$n] != null and $sv[$n] == $o[$n]) or ($sv[$n] | theme_clip));'

# desk_play_main <clip>: the main clip on every monitor. playAll drops every
# per-monitor clip, so with any in place it is play (the default clip; the
# plugin keeps its overrides) and setOutput all when the plugin targets one
# monitor; desk_apply_screens then sorts out this engine's own.
desk_play_main() {
  if [[ $MW_SV == '{}' || $MW_PER_SCREEN != true ]]; then
    desk_mw playAll "$1"
    MW_SV='{}'
  else
    desk_mw play "$1"
    if [[ $MW_OUTPUT != all ]]; then desk_mw setOutput all; fi
  fi
  MW_ENABLED=true MW_PATH=$1 MW_OUTPUT=all
}

# desk_apply_screens <portrait clip|"">: every connected portrait monitor gets
# the clip as its own (playOn), unless the user gave it one; with "" (no
# portrait version, animated off, the user's clip on screen) and on any other
# monitor, a clip this engine set, or a theme's, is dropped (clearScreen), so
# the monitor follows the main clip. owned-screens.json keeps what it set.
desk_apply_screens() {
  local p=$1 a own='{}' lines=()
  [[ $MW_PER_SCREEN == true ]] || return 0
  if [[ -n $p ]]; then desk_monitors; else DESK_MONS='[]'; fi
  # Nothing set, nothing to set: no jq.
  if [[ $MW_SV == '{}' && -z $DESK_OWNSCR && $DESK_MONS != *'"portrait":true'* ]]; then return 0; fi
  mapfile -t lines < <(jq -rn --argjson sv "$MW_SV" --arg own "$DESK_OWNSCR" --argjson mons "$DESK_MONS" --arg p "$p" \
    "$DESK_SCREENS_JQ"'
    own_of($own) as $o
    | [$mons[] | select(.portrait and $p != "") | .name] as $want
    | [$want[] as $n | if ($sv | has($n)) and (ours($sv; $o; $n) | not) then empty
        elif $sv[$n] == $p then {keep: $n} else {play: $n} end] as $a
    | [(($sv | keys) + ($o | keys)) | unique[] | . as $n | select(($want | index($n)) == null and ours($sv; $o; $n))] as $c
    | ($a[] | select(.play) | "play\t\(.play)"), ($c[] | "clear\t\(.)"),
      "own\t\([$a[] | {key: (.play // .keep), value: $p}] | from_entries | tojson)",
      "sv\t\(reduce ($a[] | .play // empty) as $n ($sv; .[$n] = $p) | reduce $c[] as $n (.; del(.[$n])) | tojson)"')
  for a in "${lines[@]}"; do
    case $a in
      play$'\t'*) desk_mw playOn "${a#*$'\t'}" "$p"; log "desktop: playing $p on ${a#*$'\t'} (portrait)" ;;
      clear$'\t'*) desk_mw clearScreen "${a#*$'\t'}"; log "desktop: ${a#*$'\t'} follows the main clip again" ;;
      own$'\t'*) own=${a#*$'\t'} ;;
      sv$'\t'*) MW_SV=${a#*$'\t'} ;;
    esac
  done
  if [[ $own == '{}' ]]; then
    rm -f "$DESK_OWNSCR_FILE"; DESK_OWNSCR=
  elif [[ $own != "${DESK_OWNSCR%$'\n'}" ]]; then
    mkdir -p "$DESK_DIR"
    printf '%s\n' "$own" | put_json "$DESK_OWNSCR_FILE"
    DESK_OWNSCR=$own
  fi
}

# ---- apply ------------------------------------------------------------------------
# The pause settings of the desktop's theme, each only when the plugin has
# another value (a plugin without them gets none).
desk_apply_pause() {
  local sent=''
  [[ -n $MW_PAUSE ]] || return 0
  if [[ $MW_PAUSE != "$DESK_PAUSE" ]]; then
    desk_mw setPauseWhileActive "$DESK_PAUSE"; MW_PAUSE=$DESK_PAUSE; sent+=", pause while active $DESK_PAUSE"
  fi
  if [[ $MW_RESUME != "$DESK_RESUME" ]]; then
    desk_mw setResumeAfterIdle "$DESK_RESUME"; MW_RESUME=$DESK_RESUME; sent+=", resume after $DESK_RESUME s idle"
  fi
  if [[ $MW_WHILE != "$DESK_WHILE" ]]; then
    desk_mw setWhileActive "$DESK_WHILE"; MW_WHILE=$DESK_WHILE; sent+=", while active $DESK_WHILE"
  fi
  if [[ -n $sent ]]; then log "desktop: $DESK_THEME: ${sent#, }"; fi
  return 0
}

# The clip: the theme's animated wallpaper plays when it has one and
# "animated" is on; otherwise the clip this engine started stops. A clip the
# user picked is never replaced or stopped. Then the portrait monitors: the
# theme's portrait clip while its main clip plays, else back to the main clip
# (desk_apply_screens). No wallpaper (mid-switch): the playback stays as it is.
desk_apply_clip() {
  local clip=$DESK_CLIP pclip=''
  [[ -n $DESK_BG ]] || return 0
  if [[ $DESK_ANIMATED != true ]]; then clip=; fi
  desk_playing
  if [[ -n $clip ]]; then
    if [[ $DESK_USER == true ]]; then
      :
    elif [[ $MW_ENABLED == true && $MW_PATH == "$clip" ]]; then
      desk_own "$clip"
      pclip=$DESK_PCLIP
    else
      desk_play_main "$clip"
      desk_own "$clip"
      log "desktop: playing $clip ($DESK_THEME)"
      pclip=$DESK_PCLIP
    fi
  else
    if [[ $MW_ENABLED == true && -n $MW_PATH ]] && { [[ -n $DESK_OWN && $MW_PATH == "$DESK_OWN" ]] || desk_theme_clip "$MW_PATH"; }; then
      desk_mw stop
      MW_ENABLED=false
      log "desktop: stopped $MW_PATH (${DESK_BG##*/} has no animated version, or $DESK_THEME is set to still)"
    fi
    desk_own ""
  fi
  desk_apply_screens "$pclip"
}

# The cache status --json reads: what this run saw and left on screen.
desk_cache() {
  local anim=false portrait=false playing=null user=null
  if [[ -n $DESK_CLIP ]]; then anim=true; fi
  if [[ -n $DESK_PCLIP ]]; then portrait=true; fi
  if [[ $DESK_AVAIL == true ]]; then desk_playing; playing=$DESK_PLAYING user=$DESK_USER; fi
  mkdir -p "$DESK_DIR"
  jq -nc --argjson avail "$DESK_AVAIL" --arg slug "$DESK_SLUG" --arg theme "$DESK_THEME" --argjson anim "$anim" \
    --argjson portrait "$portrait" --argjson playing "$playing" --argjson user "$user" --argjson now "$EPOCHSECONDS" "$nul_jq"'
    {v: 1, available: $avail, omarchy_theme: ($slug | n), theme: $theme, has_animated: $anim,
     portrait: $portrait, playing: $playing, user_clip: $user, at: $now}' | put_json "$DESK_STATE"
}

# ---- the view ---------------------------------------------------------------------
# desk_print <theme> [json]: the view of a theme, as JSON or as text. What is
# on screen (background, has_animated, playing, user_clip) is only known for
# the desktop's own theme: null for another one, and playing/user_clip null
# while the plugin can't be asked. screens (the desktop's theme only, null
# for another): each connected monitor, whether it is portrait, the clip the
# plugin is set to show there (its own, or the main clip it targets; null
# when stopped or unknown) and whether that clip is playing (its file is there).
desk_print() {
  local t=$1 cur=false anim=null playing=null user=null screens=null
  if [[ $t == "$DESK_THEME" ]]; then
    cur=true anim=false
    if [[ -n $DESK_CLIP ]]; then anim=true; fi
    if [[ $DESK_AVAIL == true ]]; then desk_playing; playing=$DESK_PLAYING user=$DESK_USER; fi
    desk_screens_view
    screens=$DESK_SCREENS_VIEW
  fi
  desk_read
  jq -rn --arg d "$DESK_RAW" --arg t "$t" --argjson avail "$DESK_AVAIL" --arg reason "$DESK_REASON" \
    --arg slug "$DESK_SLUG" --arg bg "$DESK_BG" --argjson cur "$cur" --argjson anim "$anim" \
    --argjson playing "$playing" --argjson user "$user" --argjson screens "$screens" --arg json "${2:-}" "$nul_jq$DESKTOP_V14_JQ"'
    def onoff: if . then "on" else "off" end;
    desk_view($d; $t) as $s
    | {v: 1, available: $avail, reason: ($reason | n), omarchy_theme: ($slug | n), theme: $t,
       background: (if $cur then ($bg | n) else null end), has_animated: $anim, playing: $playing,
       user_clip: $user, screens: $screens, settings: $s.settings, stored: $s.stored, defaults: $s.defaults}
    | if $json != "" then tojson
      else "desktop wallpaper: \(.theme)" + (if .omarchy_theme then " (Omarchy theme \(.omarchy_theme))" else "" end),
        "  Motion Wallpaper: " + (if .available then "running" elif .reason == "no-plugin"
          then "the plugin is not installed or not enabled" else "the Omarchy shell is not running" end),
        (if $cur | not then "  (not the theme on the desktop now)"
         elif .background == null then "  no wallpaper right now"
         else "  wallpaper: \(.background | split("/") | last), "
           + (if .has_animated then "with an animated version" else "no animated version" end)
           + (if .playing == true then (if .user_clip then "; playing a clip you picked" else "; playing" end)
              elif .playing == false then "; still" else "" end) end),
        (if (.screens // []) | length > 1 then "  monitors: " + ([.screens[] | .name + (if .portrait then " (portrait)" else "" end)
           + ": " + (if .playing then .clip | split("/") | last else "still" end)] | join(", ")) else empty end),
        "  animated \(.settings.animated | onoff), pause while active \(.settings.pause_while_active | onoff),"
          + " resume after \(.settings.resume_after_idle) s idle, while active: \(.settings.while_active)",
        "  set for \(.theme): " + (if .stored == {} then "nothing (the defaults apply)"
          else [.stored | to_entries[] | "\(.key) \(.value)"] | join(", ") end)
      end'
}

# desk_screens_view: the view's screens, into DESK_SCREENS_VIEW (JSON).
desk_screens_view() {
  local name portrait clip playing rows='' en=false
  desk_monitors
  if [[ $DESK_AVAIL == true && $MW_ENABLED == true ]]; then en=true; fi
  while IFS=$'\t' read -r name portrait clip; do
    playing=false
    if [[ -n $clip && -f $clip ]]; then playing=true; fi
    rows+=$name$'\t'$portrait$'\t'$clip$'\t'$playing$'\n'
  done < <(jq -rn --argjson mons "$DESK_MONS" --argjson sv "$MW_SV" --arg path "$MW_PATH" \
    --arg out "$MW_OUTPUT" --argjson en "$en" '
    $mons[] | .name as $n
    | [$n, .portrait, (if ($en | not) then "" elif ($sv | has($n)) then $sv[$n]
        elif $out == "all" or $out == $n then $path else "" end)] | @tsv')
  DESK_SCREENS_VIEW=$(jq -Rnc '[inputs | split("\t") | select(length == 4 and .[0] != "")
    | {name: .[0], portrait: (.[1] == "true"), clip: (if .[2] == "" then null else .[2] end), playing: (.[3] == "true")}]' <<<"$rows")
}

# ---- the OSD ----------------------------------------------------------------------
# "sakura-light" -> "Sakura Light"; an auto-theme goes by its Omarchy theme's name.
desk_pretty() {
  local w ws=() out=()
  IFS=- read -ra ws <<<"${1#omarchy-}"
  for w in "${ws[@]}"; do out+=("${w^}"); done
  echo "${out[*]}"
}
desk_osd() { omarchy osd -i "$1" -m "$2" -d 1400 >/dev/null 2>&1 || true; }

# ---- migration --------------------------------------------------------------------
# The standalone motion-wallpaper-theme script kept a "still" choice per
# Omarchy theme (~/.local/state/motion-wallpaper-theme/still/<slug>) and the
# clip it started (.../owned). Once: every still file becomes animated false
# for the theme its slug pairs with (the folder is then renamed
# still.migrated), and owned moves to $CACHE/desktop/owned (the old file is
# renamed owned.migrated). The lock must be held.
desk_needs_migration() { [[ -f $DESK_OLD/owned || -d $DESK_OLD/still ]]; }
desk_migrate() {
  local f slug n=0 dest
  if [[ -f $DESK_OLD/owned ]]; then
    if [[ ! -e $DESK_OWNED ]]; then mkdir -p "$DESK_DIR"; cp "$DESK_OLD/owned" "$DESK_OWNED"; fi
    mv -f "$DESK_OLD/owned" "$DESK_OLD/owned.migrated" || true
  fi
  [[ -d $DESK_OLD/still ]] || return 0
  for f in "$DESK_OLD"/still/*; do
    [[ -f $f ]] || continue
    slug=${f##*/}
    # "unknown" was the script's name for "no Omarchy theme".
    [[ $slug =~ ^[A-Za-z0-9._-]+$ && $slug != unknown ]] || continue
    desk_store "$(omarchy_theme_for "$slug")" animated false
    n=$((n + 1))
  done
  dest=$DESK_OLD/still.migrated
  if [[ -e $dest ]]; then dest+=.$EPOCHSECONDS; fi
  if mv -T "$DESK_OLD/still" "$dest"; then
    log "desktop: moved $n still-wallpaper choice(s) from $DESK_OLD/still into $DESK_FILE"
  else
    log "desktop: could not rename $DESK_OLD/still; its choices are in $DESK_FILE"
  fi
}

# ---- commands ---------------------------------------------------------------------
# desktop [--theme T] [--json]: read-only but for the one-time migration.
desk_show() {
  local theme=$1
  if desk_needs_migration && desk_lock; then desk_migrate; desk_unlock; fi
  desk_current
  theme=${theme:-$DESK_THEME}
  desk_theme_ok "$theme"
  if [[ $theme == "$DESK_THEME" ]]; then desk_wallpaper; desk_owned; fi
  desk_status || true
  desk_print "$theme" "$2"
}

# desktop sync: the hook, the path watcher and the shim's default.
desk_sync() {
  desk_lock || return 0
  desk_migrate
  desk_current
  desk_settings "$DESK_THEME"
  desk_wallpaper
  desk_owned
  if desk_status; then
    desk_apply_pause
    desk_apply_clip
  fi
  desk_cache
  if [[ -n $1 ]]; then desk_print "$DESK_THEME" json; fi
}

# desktop toggle (the key): what is on screen flips, moving -> still or
# still -> moving, and "animated" of the desktop's theme remembers it. With
# no shell or no plugin there is nothing to flip (no OSD either: the OSD is
# the shell's).
desk_toggle() {
  local pretty
  desk_lock || return 0
  desk_migrate
  desk_current
  desk_wallpaper
  desk_owned
  if ! desk_status; then
    desk_cache
    if [[ -n $1 ]]; then desk_print "$DESK_THEME" json; fi
    return 0
  fi
  pretty=$(desk_pretty "$DESK_THEME")
  desk_playing
  if [[ $DESK_PLAYING == true ]]; then
    desk_store "$DESK_THEME" animated false
    desk_mw stop
    MW_ENABLED=false
    desk_own ""
    desk_apply_screens ""
    log "desktop: toggle: $DESK_THEME set to its still wallpaper"
    desk_osd "$DESK_GLYPH_STILL" "$pretty · still wallpaper"
  else
    desk_store "$DESK_THEME" animated true
    if [[ -n $DESK_CLIP ]]; then
      desk_play_main "$DESK_CLIP"
      desk_own "$DESK_CLIP"
      desk_apply_screens "$DESK_PCLIP"
      log "desktop: toggle: $DESK_THEME set to its animated wallpaper"
      desk_osd "$DESK_GLYPH_ANIMATED" "$pretty · animated wallpaper"
    elif [[ -n $MW_PATH && -f $MW_PATH ]] && ! desk_theme_clip "$MW_PATH"; then
      # No animated version: bring back the user's last clip (never another
      # theme's animation).
      desk_mw play "$MW_PATH"
      MW_ENABLED=true
      desk_apply_screens ""
      desk_osd "$DESK_GLYPH_ANIMATED" "Animated wallpaper"
    else
      desk_osd "$DESK_GLYPH_STILL" "$pretty has no animated wallpaper"
    fi
  fi
  desk_settings "$DESK_THEME"
  desk_apply_pause
  desk_cache
  if [[ -n $1 ]]; then desk_print "$DESK_THEME" json; fi
}

# desktop set [--theme T] <key> <value>: validate, store, and when T is the
# desktop's theme apply that one setting at once (animated: the clip; the
# pause settings: their setter, if the plugin differs); print the --json view.
desk_set() {
  local theme=$1 key=$2 val=$3 k cur
  case $key in
    animated) k=animated ;;
    pause) k=pause_while_active ;;
    resume) k=resume_after_idle ;;
    while) k=while_active ;;
    *) desk_fail 2 usage "no desktop setting '$key': use animated, pause, resume or while" ;;
  esac
  case $key in
    animated | pause)
      [[ $val =~ ^(true|false|toggle)$ ]] || desk_fail 2 invalid "$key takes true, false or toggle, not '$val'" ;;
    resume)
      if ! [[ $val =~ ^[0-9]{1,3}$ ]] || (( 10#$val < 1 || 10#$val > 600 )); then
        desk_fail 2 invalid "resume takes whole seconds from 1 to 600, not '$val'"
      fi
      val=$((10#$val)) ;;
    while)
      [[ $val =~ ^(freeze|still)$ ]] || desk_fail 2 invalid "while takes freeze or still, not '$val'"
      val=\"$val\" ;;
  esac
  desk_lock || desk_fail 75 busy "another desktop change held the lock for 10 s; try again"
  desk_migrate
  desk_current
  theme=${theme:-$DESK_THEME}
  desk_theme_ok "$theme"
  if [[ $val == toggle ]]; then
    desk_settings "$theme"
    if [[ $key == animated ]]; then cur=$DESK_ANIMATED; else cur=$DESK_PAUSE; fi
    if [[ $cur == true ]]; then val=false; else val=true; fi
  fi
  desk_store "$theme" "$k" "$val"
  log "desktop: $theme: $k set to ${val//\"/}"
  if [[ $theme == "$DESK_THEME" ]]; then
    desk_settings "$theme"
    desk_wallpaper
    desk_owned
    if desk_status; then
      if [[ $key == animated ]]; then desk_apply_clip; else desk_apply_pause; fi
    fi
    desk_cache
  else
    desk_status || true
  fi
  desk_print "$theme" json
}

# desk_reset <theme>: drop a theme's own settings, so it follows the defaults
# again (the panel's "Use defaults"), and apply them when it is the desktop's.
desk_reset() {
  local theme=$1
  desk_lock || desk_fail 75 busy "another desktop change held the lock for 10 s; try again"
  desk_migrate
  desk_current
  theme=${theme:-$DESK_THEME}
  desk_theme_ok "$theme"
  desk_read
  if [[ -n $DESK_RAW ]] && jq -e --arg t "$theme" 'type == "object" and (.themes[$t] != null)' >/dev/null 2>&1 <<<"$DESK_RAW"; then
    jq --arg t "$theme" 'del(.themes[$t])' <<<"$DESK_RAW" | put_json "$DESK_FILE"
    log "desktop: $theme: back to the defaults"
  fi
  if [[ $theme == "$DESK_THEME" ]]; then
    desk_settings "$theme"
    desk_wallpaper
    desk_owned
    if desk_status; then desk_apply_pause; desk_apply_clip; fi
    desk_cache
  else
    desk_status || true
  fi
  desk_print "$theme" json
}

# desktop watch (the motion-wallpaper-monitors service): a sync now, then
# one after every monitor change. It follows Hyprland's event socket
# (socket2, through socat): monitoradded, monitorremoved (and their v2
# forms) for a hot-plug, configreloaded for a monitor turned in the config.
# A burst of events settles first (1 s quiet, at most 3 s) and gets one sync,
# each a child "lumenaire desktop sync" (the lock keeps it from racing the
# hook). Exits 1 without a socket and 0 when the stream ends (Hyprland
# restarted); the unit restarts it either way.
desk_watch() {
  local rt=${XDG_RUNTIME_DIR:-/run/user/$UID} sock='' s ev end
  command -v socat >/dev/null 2>&1 || { log "desktop watch: socat is missing (package socat)"; return 1; }
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -e $rt/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock ]]; then
    sock=$rt/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock
  else
    for s in "$rt"/hypr/*/.socket2.sock; do
      if [[ -e $s ]] && [[ -z $sock || $s -nt $sock ]]; then sock=$s; fi
    done
  fi
  [[ -n $sock ]] || { log "desktop watch: no Hyprland event socket under $rt/hypr"; return 1; }
  log "desktop watch: following monitor changes on $sock"
  "$0" desktop sync >/dev/null || true
  while IFS= read -r ev; do
    case $ev in monitoradded* | monitorremoved* | configreloaded*) ;; *) continue ;; esac
    log "desktop watch: ${ev%%>>*} ${ev#*>>}; syncing"
    end=$((EPOCHSECONDS + 3))
    while (( EPOCHSECONDS < end )) && IFS= read -r -t 1 ev; do :; done
    "$0" desktop sync >/dev/null || true
  done < <(socat -U - "UNIX-CONNECT:$sock" 2>/dev/null)
  log "desktop watch: the event stream ended (Hyprland restarted?)"
}

desktop_cmd() {
  local theme='' json='' args=()
  desk_paths
  DESK_AVAIL=false DESK_REASON='' DESK_SLUG='' DESK_THEME='' DESK_BG='' DESK_CLIP='' DESK_PCLIP='' DESK_OWN=''
  DESK_OWNSCR='' DESK_MONS='[]' MW_ENABLED=false MW_PATH='' MW_OUTPUT=all MW_SV='{}' MW_PER_SCREEN=false
  while (( $# )); do
    case $1 in
      --theme)
        (( $# >= 2 )) || desk_fail 2 usage "$DESK_USAGE"
        theme=$2; shift 2 ;;
      --theme=*) theme=${1#--theme=}; shift ;;
      --json) json=1; shift ;;
      -h | --help) echo "$DESK_USAGE"; return 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ -n $theme && ! $theme =~ ^[A-Za-z0-9._-]+$ ]]; then desk_fail 2 not-found "no theme called '$theme'"; fi
  case ${args[0]:-}:${#args[@]} in
    :0) desk_show "$theme" "$json" ;;
    set:3) desk_set "$theme" "${args[1]}" "${args[2]}" ;;
    reset:1) desk_reset "$theme" ;;
    sync:1 | toggle:1)
      [[ -z $theme ]] || desk_fail 2 usage "desktop ${args[0]} acts on the desktop's theme: no --theme"
      if [[ ${args[0]} == sync ]]; then desk_sync "$json"; else desk_toggle "$json"; fi ;;
    watch:1)
      [[ -z $theme && -z $json ]] || desk_fail 2 usage "desktop watch takes no --theme or --json"
      desk_watch ;;
    *) desk_fail 2 usage "$DESK_USAGE" ;;
  esac
}
