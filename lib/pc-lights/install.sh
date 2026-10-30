# lib/pc-lights/install.sh — pc-lights install (plan §11)
#
# Sourced by bin/pc-lights right after its globals and traps, before the
# PCL_TEST_OVERRIDES hook (portability plan §11). It only defines functions
# and constants; nothing runs at source time. Globals it reads (CFG, CACHE,
# STATE_DIR, THEME_DIR, TMP, ...) and helpers (die, log, progress, put_json,
# nul_jq, ...) live in bin/pc-lights.
#
# Owner: WP8 (distribution)
# Public: install_cmd
# The whole engine is checked from bin/pc-lights; checked alone, a module
# can't see the globals it shares with the core, hence the disables.
# shellcheck shell=bash disable=SC2034,SC2153,SC2154

# ---- install ------------------------------------------------------------------
# lumenaire install [--dry-run] [--units] [--hook] [--examples] [--workarounds]
#                   [--replace] [--force] [--all]
#
# Puts this checkout (the folder bin/ and lib/ sit in: the plugin folder, or a
# clone) to work for the current user:
#   always         check the requirements, then link ~/.local/bin/lumenaire and
#                  its old name ~/.local/bin/pc-lights (the units and the hook
#                  call that one) to bin/lumenaire, and pcl-heavy and
#                  pc-lights-feeds when bin/ has them
#   --units        the systemd user units in systemd/, then daemon-reload and
#                  enable the login unit and the timers
#   --hook         the Omarchy theme-set hook (Omarchy only)
#   --examples     copy examples/themes/* into the themes folder, never over a
#                  theme of the same name
#   --workarounds  the TL fan LCD wake drop-in for lianli-daemon, only when the
#                  hardware profile has TL fan LCDs (run `pc-lights detect` first)
#   --desktop      the desktop wallpaper follows the theme (Omarchy with the Motion
#                  Wallpaper plugin): ~/.local/bin/motion-wallpaper-theme (a link to
#                  the tools/ shim, `lumenaire desktop sync|toggle`), its theme-set
#                  hook, motion-wallpaper-theme.path (+ .service, enabled),
#                  motion-wallpaper-monitors.service (the monitor watcher, enabled),
#                  and the suggested key binding, printed: bindings.lua is never edited
#   --all          --units --hook --examples (not --workarounds, not --desktop)
# Nothing that exists is overwritten by default: a file in the way of a link
# needs --replace (it is backed up to ~/.cache/pc-lights/install-backup/ and
# swapped atomically), a unit, hook or drop-in that differs from the shipped one
# is shown as a diff and needs --force. --dry-run prints every step and diff and
# writes nothing. It never installs a patched lianli-daemon (see
# workarounds/lianli/README-fixed-daemon.md), never restarts lianli-daemon and
# never changes the lighting.
#
# Paths are always under $HOME (like the rest of the engine; XDG_CONFIG_HOME is
# not used), so HOME=<scratch> installs into a scratch tree. systemctl is only
# called when HOME is the user's login home: a scratch HOME never reaches the
# real user manager.
#
# Exit: 0 done (or nothing to do), 1 a required tool is missing or something was
# left alone that needs --replace/--force, 2 bad usage.

INSTALL_USAGE="usage: pc-lights install [--dry-run] [--units] [--hook] [--examples] [--workarounds] [--desktop] [--replace] [--force] [--all]"

# The units systemd/ ships; the feeds pair only goes in when pc-lights-feeds
# exists (bin/ or ~/.local/bin), the rest always.
INSTALL_UNITS=(pc-lights.service pc-lights-schedule.service pc-lights-schedule.timer
  pc-lights-clips.service pc-lights-clips.timer lumenaire-ram-drift.service)
INSTALL_FEEDS_UNITS=(pc-lights-feeds.service pc-lights-feeds.timer)
# --desktop: the watcher that syncs the desktop wallpaper when the wallpaper
# changes within a theme (the hook covers theme switches), and the one that
# syncs it when a monitor comes or goes (a portrait monitor's own clip).
INSTALL_DESKTOP_UNITS=(motion-wallpaper-theme.service motion-wallpaper-theme.path motion-wallpaper-monitors.service)
# Services started with --now like the timers and path units: watchers, which
# change nothing but the desktop wallpaper.
INSTALL_START_NOW=(motion-wallpaper-monitors.service)

# Per run: dry run, overwrite switches, and what happened (for the summary).
INST_DRY='' INST_REPLACE='' INST_FORCE='' INST_ROOT='' INST_CHANGES=0 INST_HELD=0 INST_MISSING=0
INST_RELOAD='' INST_DROPIN='' INST_ENABLE=()

inst_say() { printf '  %-9s %s\n' "$1" "$2"; }
inst_head() { printf '\n%s\n' "$1"; }
inst_tilde() { local p=$1; [[ $p == "$HOME"/* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

# inst_do <description> <cmd...>: run it, or in a dry run only say it would.
inst_do() {
  local what=$1; shift
  INST_CHANGES=$((INST_CHANGES + 1))
  if [[ -n $INST_DRY ]]; then inst_say "would" "$what"; return 0; fi
  "$@" || die "install: $what failed"
  inst_say "done" "$what"
}

# The user manager only belongs to the login HOME; anything else is a scratch
# tree (tests, a chroot-like staging dir) and must never enable real units.
inst_real_home() {
  local h
  h=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
  [[ -n $h && $(readlink -f "$h") == "$(readlink -f "$HOME")" ]]
}

# inst_systemctl <args...>: systemctl --user, or a note when HOME is scratch.
inst_systemctl() {
  if [[ -n $INST_DRY ]]; then inst_say "would" "systemctl --user $*"; return 0; fi
  if ! inst_real_home; then
    inst_say "skip" "systemctl --user $* (HOME is not your login home)"
    return 0
  fi
  systemctl --user "$@" || { inst_say "FAILED" "systemctl --user $*"; return 1; }
  inst_say "done" "systemctl --user $*"
}

# ---- requirements -------------------------------------------------------------
# inst_need <group> <command> <package hint>: one line per tool. Group
# "required" counts towards the exit status; the rest only inform.
inst_need() {
  local group=$1 cmd=$2 pkg=$3 p
  if p=$(command -v "$cmd" 2>/dev/null); then
    inst_say "ok" "$(printf '%-14s %s' "$cmd" "$p")"
  else
    [[ $group == required ]] && INST_MISSING=$((INST_MISSING + 1))
    inst_say "missing" "$(printf '%-14s %s (%s)' "$cmd" "$group" "$pkg")"
  fi
}

inst_any() {   # inst_any <path...>: "yes" when any of them exists (unmatched globs don't)
  local p
  for p in "$@"; do [[ -e $p ]] && { echo yes; return 0; }; done
  echo no
}

inst_check() {   # inst_check <ok?> <label> <hint when not ok>
  if [[ $1 == yes ]]; then inst_say "ok" "$2"; else inst_say "missing" "$2: $3"; fi
}

inst_requirements() {
  local amd='' f
  inst_head "requirements (engine)"
  inst_need required jq jq
  inst_need required socat socat
  inst_need required python3 python
  inst_need required flock util-linux
  inst_need required systemd-run systemd
  inst_head "requirements (screen editing, theme previews, auto-themes, the plugin)"
  inst_need media ffmpeg "ffmpeg; screen editing needs ffmpeg and ImageMagick"
  inst_need media ffprobe ffmpeg
  inst_need media magick imagemagick
  inst_need plugin inotifywait inotify-tools
  inst_need optional nvidia-smi "nvidia-utils; only for an NVIDIA GPU temperature"

  inst_head "backend: lian-li-linux (Lian Li fans, Strimers, pumps, LCDs)"
  if command -v lianli-daemon >/dev/null 2>&1 || [[ -f /usr/lib/systemd/user/lianli-daemon.service ]]; then
    inst_say "ok" "lianli-daemon $(command -v lianli-daemon 2>/dev/null || echo '(unit only)')"
    inst_check "$([[ -S $SOCK ]] && echo yes || echo no)" "daemon socket $(inst_tilde "$SOCK")" \
      "not running; systemctl --user enable --now lianli-daemon"
    inst_check "$(inst_any /usr/lib/udev/rules.d/*lianli* /etc/udev/rules.d/*lianli*)" \
      "udev rules for the Lian Li USB devices" "reinstall lian-li-linux (it ships 60-lianli.rules)"
  else
    inst_say "absent" "lianli-daemon (the lian-li-linux package, e.g. AUR lianli-linux-git); without it pc-lights skips Lian Li gear"
  fi

  inst_head "backend: OpenRGB (GPU, motherboard, RAM, peripherals)"
  if command -v openrgb >/dev/null 2>&1; then
    inst_say "ok" "openrgb $(command -v openrgb)"
    inst_check "$([[ -d /sys/module/i2c_dev ]] && echo yes || echo no)" "i2c-dev module loaded" \
      "sudo modprobe i2c-dev; echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf"
    inst_check "$(inst_any /usr/lib/udev/rules.d/60-openrgb.rules /etc/udev/rules.d/60-openrgb.rules)" \
      "OpenRGB udev rules (60-openrgb.rules)" "reinstall openrgb, or install its udev rules package"
    grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null && amd=1
    if [[ -n $amd ]]; then
      inst_check "$([[ -d /sys/module/i2c_piix4 ]] && echo yes || echo no)" "i2c-piix4 module (AMD SMBus)" \
        "sudo modprobe i2c-piix4"
      inst_check "$(grep -qw 'acpi_enforce_resources=lax' /proc/cmdline 2>/dev/null && echo yes || echo no)" \
        "acpi_enforce_resources=lax on the kernel command line (RAM lighting on many AMD boards)" \
        "add it to your boot entry if OpenRGB lists no DRAM devices"
    fi
    # Two drivers for the same Lian Li gear fight each other.
    f=$HOME/.config/OpenRGB/OpenRGB.json
    if command -v lianli-daemon >/dev/null 2>&1 && [[ -f $f ]] &&
      [[ $(jq '[.Detectors.detectors // {} | to_entries[] | select((.key | test("Lian Li")) and .value != false)] | length' "$f" 2>/dev/null || echo 0) != 0 ]]; then
      inst_say "warn" "OpenRGB's Lian Li detectors are on: turn them off in OpenRGB (Settings > Supported Devices), lian-li-linux drives that gear"
    fi
  else
    inst_say "absent" "openrgb (package openrgb); without it pc-lights skips the GPU, board and RAM"
  fi
}

# ---- links in ~/.local/bin ----------------------------------------------------
# inst_link <src> <dest>: dest -> src as a symlink. An existing link to the same
# file is fine; anything else in the way needs --replace, is backed up first,
# and is swapped with one rename (a unit running the old engine keeps its open
# file; bash reads a script as it goes, so it is never edited in place).
inst_link() {
  local src=$1 dest=$2 name tmp bak
  name=$(basename "$dest")
  if [[ -L $dest && $(readlink -f "$dest") == "$(readlink -f "$src")" ]]; then
    inst_say "ok" "$(inst_tilde "$dest") -> $src"; return 0
  fi
  if [[ -e $dest || -L $dest ]]; then
    if [[ -z $INST_REPLACE ]]; then
      INST_HELD=$((INST_HELD + 1))
      inst_say "held" "$(inst_tilde "$dest") exists ($(if [[ -L $dest ]]; then echo "a link to $(readlink "$dest")"; else echo "a file"; fi)); --replace swaps it for a link to $src"
      return 0
    fi
    if [[ $name == pc-lights || $name == lumenaire ]] && ! inst_engine_idle; then
      INST_HELD=$((INST_HELD + 1))
      inst_say "held" "$(inst_tilde "$dest"): a pc-lights run is busy or queued; try again when it is idle"
      return 0
    fi
    bak=$CACHE/install-backup/$name.pre-install
    if [[ -L $dest ]]; then
      inst_do "save the old link target of $(inst_tilde "$dest") in $(inst_tilde "$bak.link")" \
        inst_write_text "$bak.link" "$(readlink "$dest")"
    else
      inst_do "back up $(inst_tilde "$dest") to $(inst_tilde "$bak")" inst_backup "$dest" "$bak"
    fi
  fi
  tmp=$(dirname "$dest")/.$name.pcl-install.$$
  inst_do "link $(inst_tilde "$dest") -> $src" inst_swap_link "$src" "$tmp" "$dest"
}

inst_swap_link() {   # <src> <tmp> <dest>: ln -s to a temp name, then one rename
  mkdir -p "$(dirname "$3")" && ln -sfn "$1" "$2" && mv -Tf "$2" "$3"
}
inst_backup() { mkdir -p "$(dirname "$2")" && cp -p "$1" "$2"; }
inst_write_text() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >"$1"; }

# Replacing the engine is only safe when nothing is running or queued (plan
# §12.9): busy.json with a live pid, or a pending request.
inst_engine_idle() {
  local pid
  pid=$(jq -r '.pid // empty' "$CACHE/busy.json" 2>/dev/null || true)
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  compgen -G "$PENDING/*.json" >/dev/null && return 1
  return 0
}

# ---- files (units, hook, drop-in) ---------------------------------------------
# inst_file <src> <dest> [mode]: copy when missing; identical is fine; a
# different file is shown as a diff and only replaced with --force (after a
# backup). Always a copy to a temp name in the same folder, then a rename.
inst_file() {
  local src=$1 dest=$2 mode=${3:-644} name bak
  name=$(basename "$dest")
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    inst_say "ok" "$(inst_tilde "$dest")"; return 1
  fi
  if [[ -e $dest ]]; then
    inst_say "differs" "$(inst_tilde "$dest") (- installed, + shipped):"
    diff -u --label installed --label shipped "$dest" "$src" | sed 's/^/            /' || true
    if [[ -z $INST_FORCE ]]; then
      INST_HELD=$((INST_HELD + 1))
      inst_say "held" "$(inst_tilde "$dest") kept; --force replaces it"
      return 1
    fi
    bak=$CACHE/install-backup/$name.pre-install
    inst_do "back up $(inst_tilde "$dest") to $(inst_tilde "$bak")" inst_backup "$dest" "$bak"
  fi
  inst_do "install $(inst_tilde "$dest")" inst_put_file "$src" "$dest" "$mode"
  return 0
}

inst_put_file() {   # <src> <dest> <mode>
  local tmp
  tmp=$(dirname "$2")/.$(basename "$2").pcl-install.$$
  mkdir -p "$(dirname "$2")" && cp "$1" "$tmp" && chmod "$3" "$tmp" && mv -f "$tmp" "$2"
}

# ---- parts --------------------------------------------------------------------
inst_bin() {
  local b feeds
  inst_head "engine"
  if [[ -d $INST_ROOT/.git ]]; then
    inst_say "note" "$INST_ROOT is a git checkout: its edits go live as soon as they are saved"
  fi
  # Both names point at the real script (bin/pc-lights is only a wrapper for
  # callers inside the checkout).
  inst_link "$INST_ROOT/bin/lumenaire" "$HOME/.local/bin/lumenaire"
  inst_link "$INST_ROOT/bin/lumenaire" "$HOME/.local/bin/pc-lights"
  for b in pcl-heavy pc-lights-feeds; do
    if [[ -x $INST_ROOT/bin/$b ]]; then inst_link "$INST_ROOT/bin/$b" "$HOME/.local/bin/$b"; fi
  done
  if ! command -v pcl-heavy >/dev/null 2>&1 && [[ ! -x $HOME/.local/bin/pcl-heavy && ! -x $INST_ROOT/bin/pcl-heavy ]]; then
    inst_say "missing" "pcl-heavy (previews and auto-themes run their media jobs through it; without it they run in a capped systemd scope)"
  fi
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) inst_say "note" "$HOME/.local/bin is not on PATH; the units and hooks use the full path, add it for your shell" ;;
  esac
}

inst_units() {
  local u dir=$HOME/.config/systemd/user units=("${INSTALL_UNITS[@]}") changed=''
  inst_head "systemd user units"
  if [[ -x $INST_ROOT/bin/pc-lights-feeds || -x $HOME/.local/bin/pc-lights-feeds ]]; then
    units+=("${INSTALL_FEEDS_UNITS[@]}")
  else
    inst_say "skip" "pc-lights-feeds.{service,timer} (no pc-lights-feeds; only LCD templates with live feeds use it)"
  fi
  for u in "${units[@]}"; do
    [[ -f $INST_ROOT/systemd/$u ]] || die "install: missing $INST_ROOT/systemd/$u"
    if inst_file "$INST_ROOT/systemd/$u" "$dir/$u"; then changed=1; fi
  done
  [[ -n $changed ]] && INST_RELOAD=1
  INST_ENABLE=(pc-lights.service)
  for u in "${units[@]}"; do
    if [[ $u == *.timer ]]; then INST_ENABLE+=("$u"); fi
  done
}

# One daemon-reload for everything installed above, then enable what isn't
# yet. The login unit is enabled, never started: starting it applies the saved
# lighting. The timers, path units and the desktop's monitor watcher start now. lianli-daemon is never restarted.
inst_activate() {
  local u todo=() timers=()
  [[ -n $INST_RELOAD || ${#INST_ENABLE[@]} -gt 0 ]] || return 0
  inst_head "activate"
  if [[ -n $INST_RELOAD ]]; then inst_systemctl daemon-reload || true; fi
  for u in "${INST_ENABLE[@]}"; do
    if inst_real_home && [[ $(systemctl --user is-enabled "$u" 2>/dev/null) == enabled ]]; then
      inst_say "ok" "$u enabled"
    elif [[ $u == *.timer || $u == *.path || " ${INSTALL_START_NOW[*]} " == *" $u "* ]]; then timers+=("$u")
    else todo+=("$u"); fi
  done
  if (( ${#todo[@]} )); then inst_systemctl enable "${todo[@]}" || true; fi
  if (( ${#timers[@]} )); then inst_systemctl enable --now "${timers[@]}" || true; fi
  if [[ -n $INST_DROPIN ]]; then
    inst_say "note" "lianli-daemon drop-ins take effect the next time it starts (not restarted now)"
  fi
}

inst_hook() {
  local dir=$HOME/.config/omarchy/hooks/theme-set.d
  inst_head "Omarchy theme-set hook"
  if [[ ! -d $HOME/.config/omarchy ]]; then
    inst_say "skip" "no ~/.config/omarchy (not an Omarchy desktop)"; return 0
  fi
  inst_file "$INST_ROOT/hooks/omarchy/theme-set.d/pc-lights" "$dir/pc-lights" 755 || true
  if [[ ! -f $STATE_DIR/omarchy-map.json ]]; then
    inst_say "note" "no ~/.config/pc-lights/omarchy-map.json: every Omarchy theme gets an auto-generated case theme; map slugs to your own themes there"
  fi
}

inst_examples() {
  local d n
  inst_head "example themes"
  for d in "$INST_ROOT"/examples/themes/*/; do
    [[ -f $d/theme.json ]] || continue
    n=$(basename "$d")
    if [[ -e $THEME_DIR/$n ]]; then
      inst_say "ok" "$n (a theme of that name exists; kept)"
      continue
    fi
    inst_do "copy example theme $n to $(inst_tilde "$THEME_DIR/$n")" inst_copy_dir "$d" "$THEME_DIR/$n"
  done
}

inst_copy_dir() {   # <src dir> <dest dir>: copy to a hidden temp name, then rename
  local tmp
  tmp=$(dirname "$2")/.$(basename "$2").pcl-install.$$
  mkdir -p "$(dirname "$2")" && rm -rf "$tmp" && cp -r "$1" "$tmp" && mv -T "$tmp" "$2"
}

# The desktop wallpaper (desktop.sh): the shim the hook, the watcher and the
# key call, the theme-set hook, the path unit. Omarchy only; the Motion
# Wallpaper plugin can come later (until then every sync is a no-op).
inst_desktop() {
  local u dir=$HOME/.config/systemd/user changed=''
  inst_head "desktop wallpaper (the Motion Wallpaper follows the theme)"
  if [[ ! -d $HOME/.config/omarchy ]]; then
    inst_say "skip" "no ~/.config/omarchy (not an Omarchy desktop)"; return 0
  fi
  if [[ ! -d $HOME/.config/omarchy/plugins/nosignal.motion-wallpaper ]]; then
    inst_say "note" "the Motion Wallpaper plugin (nosignal.motion-wallpaper) is not installed: nothing plays until it is"
  fi
  inst_link "$INST_ROOT/lib/pc-lights/tools/motion-wallpaper-theme" "$HOME/.local/bin/motion-wallpaper-theme"
  inst_file "$INST_ROOT/hooks/omarchy/theme-set.d/motion-wallpaper-theme" \
    "$HOME/.config/omarchy/hooks/theme-set.d/motion-wallpaper-theme" 755 || true
  for u in "${INSTALL_DESKTOP_UNITS[@]}"; do
    [[ -f $INST_ROOT/systemd/$u ]] || die "install: missing $INST_ROOT/systemd/$u"
    if inst_file "$INST_ROOT/systemd/$u" "$dir/$u"; then changed=1; fi
  done
  [[ -n $changed ]] && INST_RELOAD=1
  INST_ENABLE+=(motion-wallpaper-theme.path motion-wallpaper-monitors.service)
  inst_say "binding" "not added for you; for a key that flips the wallpaper between moving and still, put in ~/.config/hypr/bindings.lua:"
  # shellcheck disable=SC2016 # Lua, printed as it is
  printf '            %s\n' 'o.bind("SUPER + SHIFT + ALT + SPACE", "Toggle animated wallpaper",' \
    '              os.getenv("HOME") .. "/.local/bin/motion-wallpaper-theme toggle")'
}

# The TL fan LCD wake (see workarounds/lianli/wake-fan-lcds): only for a
# profile with TL fan LCDs, and only the ExecStartPre drop-in plus the script.
# It takes effect at the next lianli-daemon start; nothing is restarted here.
inst_workarounds() {
  local prof=$STATE_DIR/profile.json n dropin=$HOME/.config/systemd/user/lianli-daemon.service.d
  local wake=$HOME/.local/bin/lianli-wake-fan-lcds conf=$TMP/wake-fan-lcds.conf
  inst_head "workarounds"
  if [[ ! -f $prof ]]; then
    inst_say "skip" "no hardware profile yet; run \`pc-lights detect\` first"; return 0
  fi
  n=$(jq '[.devices // {} | .[] | select(.family == "TlFlexLcd" or .family == "TlLcd")] | length' "$prof" 2>/dev/null || echo 0)
  if [[ $n == 0 ]]; then
    inst_say "skip" "lianli.wake_fan_lcds: the profile has no TL fan LCDs, nothing to wake"
  else
    inst_say "note" "lianli.wake_fan_lcds: $n TL fan LCD(s); after a shutdown their receivers keep them off USB"
    command -v uv >/dev/null 2>&1 || inst_say "missing" "uv (the wake script runs with uv run --script; package uv)"
    inst_link "$INST_ROOT/workarounds/lianli/wake-fan-lcds" "$wake"
    sed "s|@WAKE_BIN@|%h/.local/bin/lianli-wake-fan-lcds|" "$INST_ROOT/workarounds/lianli/wake-fan-lcds.conf.in" >"$conf"
    if inst_file "$conf" "$dropin/wake-fan-lcds.conf"; then INST_RELOAD=1 INST_DROPIN=1; fi
  fi
  if [[ $(jq -r '.workarounds["lianli.fixed_binary"].present // false' "$prof" 2>/dev/null) == true ]]; then
    inst_say "note" "a patched lianli-daemon drop-in is in use; remove it when lian-li-linux is upgraded (workarounds/lianli/README-fixed-daemon.md)"
  fi
}

install_cmd() {
  local a want_units='' want_hook='' want_examples='' want_workarounds='' want_desktop=''
  for a in "$@"; do
    case $a in
      --dry-run) INST_DRY=1 ;;
      --units) want_units=1 ;;
      --hook) want_hook=1 ;;
      --examples) want_examples=1 ;;
      --workarounds) want_workarounds=1 ;;
      --desktop) want_desktop=1 ;;
      --all) want_units=1 want_hook=1 want_examples=1 ;;
      --replace) INST_REPLACE=1 ;;
      --force) INST_FORCE=1 ;;
      -h | --help) echo "$INSTALL_USAGE"; return 0 ;;
      *) echo "pc-lights: $INSTALL_USAGE" >&2; exit 2 ;;
    esac
  done
  INST_ROOT=$(readlink -f "$PCL_LIB/../..")
  [[ -x $INST_ROOT/bin/lumenaire ]] || die "install: no bin/lumenaire under $INST_ROOT"

  echo "lumenaire install from $INST_ROOT${INST_DRY:+ (dry run: nothing is written)}"
  inst_requirements
  if (( INST_MISSING )) && [[ -z $INST_DRY ]]; then
    die "install: $INST_MISSING required tool(s) missing (see above); install them and run it again"
  fi
  inst_bin
  if [[ -n $want_units ]]; then inst_units; fi
  if [[ -n $want_hook ]]; then inst_hook; fi
  if [[ -n $want_examples ]]; then inst_examples; fi
  if [[ -n $want_workarounds ]]; then inst_workarounds; fi
  if [[ -n $want_desktop ]]; then inst_desktop; fi
  inst_activate

  inst_head "summary"
  if [[ -n $INST_DRY ]]; then inst_say "dry run" "$INST_CHANGES change(s) would be made"
  else inst_say "done" "$INST_CHANGES change(s)"; fi
  (( INST_HELD )) && inst_say "held" "$INST_HELD item(s) left as they are (see above: --replace for links, --force for files)"
  (( INST_MISSING )) && inst_say "missing" "$INST_MISSING required tool(s)"
  if [[ ! -f $STATE_DIR/profile.json ]]; then
    inst_say "next" "lumenaire detect    (finds your devices and writes ~/.config/pc-lights/profile.json)"
  fi
  if [[ -z $want_examples ]] && ! compgen -G "$THEME_DIR/*/theme.json" >/dev/null; then
    inst_say "next" "lumenaire install --examples, or make a theme (docs/THEMES.md)"
  fi
  (( INST_HELD || INST_MISSING )) && exit 1
  exit 0
}
