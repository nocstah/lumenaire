---
name: Lumenaire
description: A compact native Omarchy popup for the PC case lighting engine lumenaire.
typography:
  headline:
    fontFamily: "monospace"
    fontWeight: 700
  section:
    fontFamily: "monospace"
    fontWeight: 700
  body:
    fontFamily: "monospace"
    fontWeight: 400
  label:
    fontFamily: "monospace"
    fontWeight: 400
components:
  button:
    typography: "{typography.body}"
  icon-button:
    typography: "{typography.body}"
  text-link:
    typography: "{typography.body}"
  reading:
    typography: "{typography.headline}"
  theme-card:
    typography: "{typography.body}"
  swatch:
    typography: "{typography.label}"
---

# Design System: Lumenaire

## Overview

**Creative North Star: "The case, read from the bar"**

Lumenaire is an Operate and Monitor surface: a bar entry that says what the
case is doing, and a compact popup for picking a lighting theme, switching the
lights and the screens, moving the pump video along, setting how each theme's
desktop wallpaper moves, and making or editing a theme. Its visual authority
is the installed Omarchy shell: it inherits the current theme, font alias,
control states and popup geometry, and introduces no palette of its own. This
follows [PRODUCT.md](PRODUCT.md).

The one place colour belongs to the content is the case itself: theme
previews, colour swatches and the bar icon's tint show the case theme's colours
as data. Everything around them stays on the Omarchy palette, so a hot pink
case theme never tints the panel's text.

**What makes it calm:**

- One job per row. A row has a name, one short state, and at most the control
  it needs. Everything else (file names, per-fan RPMs, hex codes, why a switch
  waits, what a setting does in detail) lives in tooltips.
- Exactly three kinds of button, and states never look like buttons.
- One spacing rhythm and one left and right edge for all content.
- Plain words in sentence case: "Theme colours", "Custom", "Show on case",
  "Keep colours vivid on LEDs". No engine jargon on screen, and no command
  lines except the one-time hardware check the preview needs.

## Colors

The palette is whichever Omarchy theme is active. Text takes one of four
tones (`Label.tone`); a tone that would read too faintly on this theme's popup
is moved towards the popup text until it passes WCAG AA (`Look.js`), so a
light theme's red or grey never goes pale.

| Tone / reference | Use |
| --- | --- |
| `text`: `Color.popups.text` | Names, numbers, sentences, notice text (also on urgent notices). |
| `muted`: `Color.muted` | Captions, units, state words, subtitles, "From Omarchy", the countdown. |
| `accent`: `Color.accent` | The active theme's name and outline, "󰄬 Active", "Custom", "Draft", links, the unsaved dot, primary buttons, a chosen card or swatch. |
| `urgent`: `Color.urgent` | Failures ("Failed", "Couldn't show it"), hot readings, danger buttons, the LED warning dot; the tint and glyph of an urgent notice. |
| `Style.normalFillFor`, `hoverFillFor`, `focusBorderFor` | Tile and notice plates, hover and keyboard-cursor fills and rings. |
| `Color.background` | The opaque plate of popups and of the pencil on a card. |
| Case colours | Data only: previews, swatches, part chips, the bar icon, the screens' pictures. |

**The Native Binding Rule.** Use `Color`, `Style` and `qs.Ui` at the point of
use. Never copy resolved theme values into the plugin.

**The Accent Rule.** The accent marks what is primary, active or custom, and
nothing else. Live readings are in the text colour; a reading is only
coloured when it is hot.

## Typography

`Style.fontFamily` (the `monospace` fontconfig alias) throughout, always
`Text.PlainText`, elided or wrapped, numbers tabular.

| Role | Size | Use |
| --- | --- | --- |
| Headline | `Style.font.heading`, bold | "Lumenaire", the editor's theme name, "New theme" |
| Reading | `Style.font.title`, bold | Live values |
| Section | `Style.font.subtitle`, bold | "Themes", "Colours", "Parts", "Advanced", "Start from", "Name it" |
| Body | `Style.font.body` | Names, rows, sentences, buttons |
| Label | `Style.font.bodySmall` | Captions, units, states, subtitles, hints |

Thousands are grouped with a no-break space ("2 548 RPM"); when the panel is
narrow the readings drop the space ("2548") so five fit on one row.

## Layout

- Panel content is 468 px wide (`Style.space(468)`), capped at 720 px and
  scrolled; it is checked at 468 and 360 px.
- Spacing is `Style.space` on one rhythm: **4, 8, 12, 16, 24**. 24 before a
  section, 16 between blocks inside a page and from a page header, 12 between
  a section title and its content and inside plates, 8 between controls, 4
  inside a group. 2 only between a caption and its value.
- One left and one right edge: headers, readings, tiles, cards, swatches and
  buttons sit on the content edges. Rows that highlight on hover (parts, menu
  rows, the Wallpaper row) let their fill bleed 8 px past the edges so their
  words stay on them; the back arrow is pulled out the same way so its glyph
  lines up. The page scrolls in a view 8 px wider on each side, so a bleed or
  a ring outside a card is never cut off.
- One divider, where two unrelated rows meet: between the pump video and the
  night theme on the main page (`Ui.PanelSeparator`, strength 0.08);
  everywhere else spacing separates.

## Shapes

**The Host Corner Rule.** Corners are the host's: `Style.cornerRadius`, which
mirrors Hyprland's `decoration:rounding`. On a square Omarchy the panel is
square, on a rounded theme it rounds like every other shell panel, and it
never sets a floor of its own.

- Buttons, icon buttons, choice chips, fields, rows, menus, confirms, tiles,
  cards and notices take `Style.cornerRadius` as it is (the host `Ui.Button`,
  `Ui.CursorSurface` and `Ui.TextField` already do). Switches are the host's
  `Ui.ToggleSwitch` as it comes: a pill when the host rounds, square when it
  doesn't.
- Small or picture-like things cap it so they keep their shape: swatches and
  colour chips at a quarter of their side, the hue strip and the blend bar at
  a pill, theme previews and the picker's colour square at 10 px.
- A ring drawn outside something (the keyboard cursor on a card, a chosen or
  hovered swatch, the picker's parts, a filled button's focus) keeps its gap
  all the way round: its corner is the inner corner plus the gap, or square
  when the inner one is.
- True circles only where the shape is the meaning: the picker's handles, the
  "Unsaved" dot and a swatch's LED warning dot.
- Theme previews keep the engine's 684:267 ratio and are clipped on a Canvas
  (`ThemeArt`), which draws the same on the GPU and in the software renders;
  before the image is there, the theme's swatch fills it as stripes.
- A screen's media (`MediaThumb`) is drawn the same way, at the screen's own
  shape (square fans, the 2288:1080 pump, the 4:1 strip), capped at 10 px;
  a round pump is drawn round, the shape being the meaning. Without a
  picture it is the plate with the screen's glyph; a file that doesn't fit
  is drawn whole on the plate. The crop frame's four handles are circles
  (the picker's knobs).
- Outlines are 1 px at low alpha; the active theme and a chosen swatch or card
  get 2 px in the accent.

## Buttons

Exactly three kinds, plus inline links for resets:

| Kind | Look | Use |
| --- | --- | --- |
| Primary (`Action kind: "primary"`) | Filled accent, text in whichever of background and foreground stands out | The one main action of a view: Save, Create, Next, Use (crop), Detect hardware, Edit (notice). `kind: "danger"` fills it with urgent for a confirmed Delete or Discard. |
| Secondary (`Action`) | Outlined | Every other action: ＋ New, Edit, Retry, Show log, Continue, Keep editing, Another, Copy command, Cancel, Change…, Remove, ＋ Add clip, Try again, Choose another, Crop to fit, Show more. |
| Icon (`IconButton`) | A Nerd Font glyph in a 28 px square, the host hover-cursor fill and ring, always a tooltip | ⋯ (More), ✕ (Close, Dismiss, remove a clip), ← (Back), ✎ (Edit on a card, on a plate), ⏭ ⏸ ▶ (pump video), ＋ (add a colour), ↑ ↓ (move a clip). |
| Link (`TextLink`) | Accent text, underlined on hover | Only one-click resets: "Use theme colours", "Same as all fans", "Use default" (brightness), "Reset framing", "Use defaults" (wallpaper). |

A disabled button dims to 0.45 and keeps its tooltip where the host allows.
The keyboard cursor on a button is the host hover-cursor treatment; on a
filled button, a 2 px accent ring outside the fill. States are words, never
buttons: "󰄬 Active", "󰖔 Night", "Draft", "Custom", "Theme colours".

## Components

### Main page

Top to bottom:

1. **Header**: "Lumenaire", the active theme's name in the accent (tooltip: the
   theme on the case), **Edit** for it (secondary, when the editor can open
   it), then ⋯ and ✕. ⋯ opens a menu: a muted "Last change: Sakura applied at
   11:42 · 21 s", then Refresh, Rebuild previews, Show log. Esc closes.
2. **Notices** (`Notice`): a calm plate per notice with a glyph, one sentence,
   at most two buttons and ✕ when it can be dismissed. The service chooses the
   sentence; an urgent one tints the plate and glyph, never the words. The
   panel adds its own: "Saved Hellfire. Use it now?" (Use) after the editor
   saves a theme that isn't on, devices out of range, screens missing on USB.
   Media being prepared for a theme no open editor shows is one line too:
   "Preparing Sakura's pump video… 42 %", or "Couldn't prepare Sakura's fan 2
   video." (urgent, ✕).
3. **Readings** (`Metric`): one row of equal cells, only for what this PC has:
   Coolant, Pump, Fans, CPU, GPU. A muted caption, a bold number and a muted
   unit. Fans is the mean of every fan; its tooltip lists each group. GPU load
   and power are in the GPU tooltip. A missing or stale value (coolant older
   than 15 s) is "—", with the last value in the tooltip; a hot one is urgent.
4. **Power** (`PowerTile`): Lights and Screens side by side, each a glyph, the
   name, one muted word ("On", "Off", "On…", "Waiting…") and a switch; the
   whole tile toggles. Why it waits, and what it switches, are its tooltip.
5. **Pump video**: one row under the tiles, "Pump video", "2 of 6", a muted
   "next in 4:04", ⏭ and ⏸/▶. The clip's file name is the tooltip. Hidden
   without a rotating screen.
6. **Night theme**: one row, the title, "Stealth · 00:00–07:00" (and "skipped
   tonight" while a pick overrides it) and the switch. The Omarchy pairing and
   when a change takes effect are the tooltip.
7. **Wallpaper**: the same kind of row for the desktop's animated wallpaper
   (the Motion Wallpaper plugin), as the theme the desktop follows has it
   (the one paired with the Omarchy theme): "Wallpaper", one muted state
   ("Animated · pauses while you work", "Animated", "Still", "No animated
   version") and a switch for the theme's animated setting. Without an
   animated version the switch is dimmed and can't change, its tooltip
   saying so (the page still sets it, for a wallpaper that has one). The row
   opens its page (a hover fill that bleeds like the editor's rows). Shown
   only while the engine says the desktop takes the settings (status
   `desktop.available`, or before its first sync the view read when the
   panel opens).
8. **Themes**, last, so every quick control above shows without scrolling
   and the gallery is what scrolls: the section title, "Building previews…"
   while they build, and **＋ New**. A never-saved new theme waits as one row,
   "Neon Cyan isn't saved yet" (Continue). Then the grid, two columns at every
   width (three made the names and the pictures too small), and a muted "From
   Omarchy" group for the generated themes.

### Theme card

`ThemeCard`: the preview (`ThemeArt`), then the name on the left and
one state on the right: "󰄬 Active" (accent, plus the accent outline),
"Applying… 0:12" (accent), "Queued", "Applies later" (saved while the lights
are off), "Failed" (urgent), "󰖔 Night". A second small line only when it
matters: "Draft" (accent) and how much of it this PC can't show ("Skips pump
media", "LEDs only", details in the tooltip). A click picks it; hover or the
keyboard cursor shows a ring and the ✎ button on the picture's corner; a
right click or the menu key opens its menu: Edit, Wallpaper… (while the
desktop takes the settings), Duplicate, Rename…, Delete….

### Menus and confirms

`MenuPopup`, a `Controls.Popup` in the panel's own window (never a separate
window), anchored under what opened it: right-aligned, or left-aligned when
that would leave the panel, above when there is no room below. As a menu:
rows of glyph and word, a muted note on top, danger rows in urgent; j/k and
Enter. As a confirm: one sentence, an optional name field, Cancel and one
primary or danger button; Enter confirms, Esc cancels. The card confirms
("Apply Sakura again?", "Stealth is on until 07:00. Apply Abyss now?",
Rename, Delete or why it can't be deleted) open under the card.

### Names

`NameField`: one field with the name as typed ("Neon Cyan"); the engine gets
`Format.slugify` of it ("neon-cyan"). No rules text. Only when it can't be used
does one line say why, with a one-click fix: "Sakura already exists." [Use
"Sakura 3"], "Use letters or numbers.", "Omarchy names are kept for generated
themes." [Use "Blue"]. New theme, Rename and Save as copy all use it.

### New theme page

`NewTheme`, a page in the panel, two steps with "1 of 2" in the header and ←
(or Esc) back a step:

1. **Start from**, four cards (two across, one under the other when narrow):
   *A colour* (twelve LED-true colours, "More colours…" for the picker; the
   other two colours follow the one picked, `Palette.fromMain`), *Match my
   desktop* ("Use Sakura's colours": the Omarchy theme's colours made
   LED-friendly, `Palette.fromDesktop`), *Copy a theme* (small previews of every
   theme; a duplicate), *Surprise me* (a random palette, "Another" for the
   next). The choice shows its palette as three captioned swatches. Next.
2. **Name it**: the palette (or the copied theme's preview), the name field
   filled with a suggestion ("Neon Cyan", "Sakura copy", the desktop's name),
   Create (or Enter).

Create starts the draft (`theme new`, `theme duplicate`) and opens the editor
with the preview going out at once; nothing is applied until Save. Duplicate
from a card or the editor opens straight on "Name it".

### Editor

`ThemeEditor`, a page in the panel:

- **Header**: ← (Back to themes), the name, "● Unsaved" while there are
  changes; **Save** (primary, off when nothing changed; on the theme that is on
  the case it saves and applies, no question) and ⋯: Save as copy…, Discard
  changes, Duplicate, Rename…, Delete… (danger, confirmed). A new theme's ⋯ is
  Rename… and Discard this theme….
- **Leaving** never asks: the engine keeps the draft. The card then says
  "Draft", and opening it again shows one line, "You have unsaved changes"
  (Keep editing, Discard…). Discard is the only confirm.
- **Notices**, one line and one action each: can't save yet (the first
  problem, Show), changed outside the editor (Save as copy…; Overwrite is in
  ⋯), made from Omarchy (Duplicate instead), the engine's own line.
- **Show on case** (`PreviewStatus`): the switch and one muted line: "Live",
  "Updating…", "On", "Off", "Paused while Hellfire applies", "Paused: heat
  warning is on", "Stops in 0:42" (Keep showing), "Stopped by the night theme"
  or "Stopped: the screens went off" (Show again), "Couldn't show it" in
  urgent (Try again), "Lights are off",
  "Needs a one-time hardware check" (Copy command; the command is the
  tooltip). The detail of each is its tooltip.
- **Colours**: Main, Second and Accent as 44 px swatches with their names
  under them; a click selects one and opens the picker under the row.
- **Parts** (`RoleRow`): one row per part this PC has (Fans, Strimers, Rings,
  GPU, Motherboard, RAM): glyph, name, its colours as small chips, and a muted
  "Theme colours" or an accent "Custom". The whole row expands to its controls
  (Inner and Outer swatches, one Colour, or the Strimer and gradient
  controls), then "Use theme colours" when it is custom, then "Customise
  each…" when the part has several devices (fan groups, the two Strimers, the
  pump and screen rings, the board's ARGB headers); those list as rows of
  their own, with "Same as all fans" to follow the part again.
- **Strimers**: Effect (dropdown), Speed (a slider from Slow to Fast),
  Direction (↻ ↺, `Segmented`), six colour swatches. **GPU and RAM**: Style
  (Solid, Blend), the colours with ＋, a bar of the blend, Remove under the
  picker, and for RAM whether the blend runs across the sticks or on each.
- **Screens**, between Parts and Advanced: the case map (see "Screens").
- **Advanced**, collapsed: "Keep colours vivid on LEDs", "Colour correction
  for this PC", each with one muted line, and "Heat warning colour".
- **Save** waits while media is being prepared for the draft (off, with
  "Waiting for the pump video to finish preparing" as its tooltip).

### Screens

`ScreensSection` in the editor, shown once the engine has read the draft's
screens (`theme screens --json`) and only for a v3 theme on a PC whose profile
has LCDs:

- **The case map** (`CaseMap`): the section title "Screens", then every
  screen at its place, from the view's place hints: the top fans in a row,
  the side columns (the right 3-fan column), the pump in the middle and the
  wide 8.8" screen under it; a side column spans the middle, its first tile
  level with the pump, its last with the main screen. A PC with other
  screens gets its own map from the same rules (three fans along the bottom
  and a round pump, no 8.8"). Square tiles are 40 px at 360 and 56 at 468;
  the pump is two squares tall.
- **A tile** (`ScreenTile`) is the screen's media as a picture at its shape,
  nothing written on it. The draft changing it: the accent outline, 2 px. A
  job preparing media for it: the picture dimmed with its percentage. A
  failure (a job, or the screen refusing what the preview sent): the small
  urgent dot of a swatch's LED warning. Where it is, what it shows and its
  state are the tooltip ("Fan 3 · right column", then "planet 37 · 0:42").
  Nothing chosen: the plate and the screen's glyph ("Unchanged: this theme
  leaves it as it is"). A screen the profile doesn't manage is dimmed.
- **One line under the map**, the first that applies, with at most one
  action: "Fan 3 couldn't be prepared" (urgent; Try again, or Choose another
  when the file can't be read), "Fan 2 couldn't show it" (urgent; Choose
  another), "Pump: preparing… 42 %", "Updating…", "Screens are off", "On the
  case", "Shows after you save". Nothing to say: no line.

### Screen page

`ScreenPage`, a page in the panel opened from a tile (the editor stays
loaded under it, so ← comes back to it as it was, cursor on that tile):

- **Header**: ← (Back to the theme), the screen's name ("Fan 3", "Pump",
  "8.8" screen") and a muted subtitle, only where it fits whole: the fan's
  place ("Right column"), the pump's "One clip" or "Takes turns · 5 clips".
  A fan has ⋯: "Use on every fan screen".
- **The line** under the header says where it stands, job first, then the
  preview, then what the view warns about, with its one action on the right:
  "Preparing… 42 %" (Cancel), "Couldn't prepare it" (urgent; Try again or
  Choose another, the reason as tooltip: "It isn't a picture or video this
  PC can read", "Not enough disk space", "Stopped"), "Couldn't show it"
  (urgent; the daemon's error as tooltip), "Doesn't fit this screen" (Crop
  to fit), "Its file is missing", "Screens are off", "Not connected",
  "Updating…", "On the case", "Shows after you save". The engine's note on
  the last change ("Rotation turned off: pictures can't take turns.", "Uses
  the first 1:56.") follows in a smaller line, and so does a change it
  refused, in one calm sentence per reason ("It doesn't fit this screen;
  crop it first.", "That file isn't there any more.", "Still preparing…
  Save when it's done."), its own words as the tooltip.
- **Shows** (the 8.8" screen): Clock and stats | Picture or video (`Segmented`).
  Choosing Picture or video goes back to the media it had, else opens the
  picker; the layout is kept for later.
- **The media**: its picture beside "Video · 0:42" (or "Picture",
  "Animation", "Unchanged") and Change… and Remove; the 8.8" strip across
  the page with them under it, and only the picture while it shows its
  layout. A fan dealt from the theme's shared list has no Remove (it always
  shows something). While a job prepares new media the picture is the file
  being made, dimmed. Media that doesn't fit is drawn whole on the plate.
- **The pump's clips** (`ClipList`), once it has two: a row per clip in the
  order they take turns, its number, its picture and its length, ↑ ↓ ✕ on
  hover or the keyboard cursor; a clip being prepared waits in the list where
  it will land ("Preparing… 42 %", Cancel). Rows move by dragging (the row
  lifts, an accent line shows where it lands), by ↑ ↓ or from the keyboard;
  the new order shows at once. Then ＋ Add clip, Change every (1 min · 5 min ·
  15 min · 1 h · Off; a value off the grid selects none) and Shuffle. With
  one clip, ＋ Add clip sits under the media.
- **Brightness**: a slider from 0 to 100 in steps of 5 and its value ("80 %",
  muted while the screen keeps its own), with "Use default" under it when
  this theme sets one.
- Captions sit in one column of 88 px; a row whose chips don't fit beside
  its caption puts them under it.
- A nearly full disk is one calm notice at the top ("Your disk is nearly
  full. New media may not fit.").

### Picker

`MediaPicker`, the screen page's second step (subtitle "Choose what it
shows", or "Add a clip"):

- **Tabs** (`Segmented`): This theme, Library (your other themes, the
  L-Connect clips and uploads), My files (Videos and Pictures). It opens on
  This theme when that has something that fits, else Library.
- **Search** (`Ui.TextField`), then "Looking through your files… 212 of 857"
  while the engine reads new files.
- **Files** (`MediaTile`), best fits first, under their group's muted caption
  ("Pump clips", "Other themes", "Your L-Connect uploads", "Videos",
  "Pictures"; none when there is one group), in columns by the screen's
  shape: square 4 (3 at 360), the pump 2, the strip 2 (1 at 360). Each is
  its picture at the screen's shape and one muted line: "0:12", "Picture",
  "Animation", "0:12 · cropped" ("Cropped" when narrow), "Doesn't fit"
  (drawn whole on the plate), "Checking…" (not read yet). The file on this
  screen now has the accent outline. Its name, size, fit and the themes
  using it are the tooltip. Show more under the grid when there are more.
- **Choosing** a file that fits prepares it at once (a theme's own file is
  used as it is) and goes back to the screen; any other opens the crop page.
- **Empty**: "Nothing here yet", "Nothing matches", "Looking through your
  files…", "This folder can't be read", "Screen editing needs ffmpeg and
  ImageMagick."

### Crop

`CropView`, the third step (subtitle "Crop to fit"), for a file of another
shape:

- A frame grab of it (`media frame`; its thumbnail stands in until it
  arrives) with the screen's shape laid over it: outside, the picture is
  dimmed (`Color.background` at 0.55), the frame is a white line inside a
  dark one, which reads on any picture, and a round screen's corners are
  dimmed too. The frame moves by dragging; its round handles and the wheel
  zoom it.
- **Zoom**, **Moment** (videos: "0:14 / 0:42", a third of the way in to
  start), one muted line on what the framing keeps: "Fits as it is", "Keeps
  84 % of the picture", "Uses the first 2:00" (tooltip: how long the screen
  takes), "Low resolution; it may look soft" (half again the screen's size
  or more); "Reset framing" when moved, and **Use**.

### Wallpaper page

`WallpaperPage`, a page in the panel, from the Wallpaper row (the theme the
desktop follows) or a card's Wallpaper… (any theme). The settings are the
theme's own and apply at once, no Save:

- **Header**: ← (Back to themes), "Wallpaper" and the theme's name, muted.
- **Animated wallpaper**: the switch and one muted line: "This wallpaper has
  an animated version", "No animated version for this wallpaper" (the switch
  keeps the theme's choice for a wallpaper that has one), "Playing a video
  you picked" (Motion Wallpaper's own choice, which the theme leaves alone),
  or for another theme "Applies when Hellfire is on".
- **Pause while you work**, while animated: the switch and "Holds still while
  you use the keyboard or mouse". While it pauses, two captioned choices
  (`Segmented`) under it: **Resume after** 3 s · 5 s · 10 s · 30 s (a value
  set elsewhere joins them in its place) and **While you work** Freeze ·
  Show still image. Captions sit in one column; when a row's chips don't fit
  beside it, both rows put them under their captions.
- **Use defaults**, when the theme keeps a setting of its own that differs
  from the defaults.
- A change shows at once and the engine's answer settles it. One line under
  the header says what stands in the way: "That change didn't go through."
  (urgent, the engine's words as its tooltip), "The desktop isn't
  answering right now." or "Animated wallpapers need the Motion Wallpaper
  plugin." (muted, nothing else on the page), "Reading the settings…".

### Swatches, picker and LED hint

- **Swatch** (`Swatch`): the colour itself in a chip with a 1 px outline, an
  optional caption under it, the accent ring while its picker is open, the
  hover ring, and a small urgent dot when an LED warning applies. The name
  and hex are the tooltip; no hex on screen.
- **Picker** (`ColorPicker`): inline, one at a time: an SV square, a hue strip,
  the hex field with the colour it had beside it (click to go back), and the
  presets in three groups set apart (this theme's colours, colours that look
  true on LEDs, recent picks), each swatch's tooltip naming its group. No
  paragraph.
- **LED hint** (`CalibrationHint`): one line, "On the LEDs ■ → ■", only when
  the LEDs will show something else, and at most one short warning ("Pale
  colours look white on LEDs") with its fix as a small button, "■ Use".

### Bar entry

Unchanged: `Ui.BarIconButton` with the lightbulb (`nf-md-lightbulb`, or
`_off`), tinted with the case theme's lead colour, and a short readout ("32°",
"2.5k"). Dimmed while starting, on an engine error, offline or with the lights
off; accent while a change runs, urgent for an unseen failure.

## Keyboard

- **Main page**: the arrows or h/j/k/l walk the theme grid (the first press
  shows the cursor), Enter applies, `e` edits the cursor card (or the active
  theme), `n` starts a new theme, the menu key or Shift+F10 opens the card
  menu, Tab moves to the next bar panel, Esc closes a popup, then the panel.
- **New theme**: j/k walk the rows (the four cards are a 2×2 grid), h/l move
  across the cards, the colours and the themes, Enter chooses; in the name
  field Enter creates and Esc goes back.
- **Editor**: j/k walk a flat list of rows (Show on case, the three colours,
  the parts and their open controls, the screens in map order, the map's
  action, Advanced and its settings), Enter or Space opens the picker,
  expands, opens a screen or activates, h/l step a speed or a choice
  and fold a row, `r` resets, `p` switches the preview, Ctrl+S saves, the menu
  key opens ⋯, Esc goes picker → popup → back. In the picker, Tab cycles
  square → hue → hex → presets and the arrows move by 2 % or 2° (Shift: 10).
- **Screen page**: j/k walk its rows (Shows, the line's action, Change…,
  Remove, the clips, ＋ Add clip, Change every, Shuffle, Brightness); h/l
  step Change every, Shuffle, Brightness (by 5) and Shows; `r` resets the
  brightness; on a clip, Enter picks it up (j/k carry it, Enter or Esc puts
  it down), Shift+J/K or Alt+↑/↓ move it at once, x or Delete removes it; the
  menu key opens ⋯; Esc goes back.
- **Wallpaper page**: j/k walk its rows (Animated wallpaper, Pause while you
  work, Resume after, While you work, Use defaults), Enter or Space switches
  or steps a choice, h/l set a switch off or on or step a choice, `r` uses
  the defaults, Esc goes back.
- **Picker**: Tab/Shift+Tab or 1/2/3 switch the tabs, `/` goes to the
  search (Esc leaves it), the arrows or h/j/k/l move over the files (across
  the group captions, then to Show more), Enter chooses.
- **Crop**: the arrows or h/j/k/l move the frame 1 % (Shift: 10 %), + and -
  zoom, [ and ] step the moment by 1 s (Shift: 5 s), 0 resets, Enter uses it,
  Esc goes back to the picker.
- The cursor is always visible: a ring on cards, pictures and swatches, the
  host hover-cursor fill and ring on rows and buttons, a ring outside filled
  buttons.

## Do's and Don'ts

### Do:

- Say what is happening in a word or two, and put the detail in a tooltip.
- End progress with "…" and show elapsed time instead of animating.
- Show a missing or stale value as "—".
- Offer the fix next to the problem: "Use ■", "Use “Sakura 3”", Show.
- Verify at 468 and 360 px on a light and a dark theme (`tests/render.py`,
  every `tests/fixtures/*.json`), square and rounded (`LUMENAIRE_RADIUS=0`
  and `10`), and look at every render. The screen fixtures draw their
  pictures from `tests/ui/thumbs/` (the theme previews cut up by
  `tests/ui/make-thumbs.py`); their words are checked by
  `tests/ui/screens-parity.mjs`.

### Don't:

- Tint text or controls with the case theme's colours.
- Draw a state as a button, or add a fourth kind of button.
- Put instructions, file names, hex codes or command lines on screen (a
  media file's name, size and path are its tooltip).
- Ask before leaving the editor: drafts are kept.
- Add pulsing, spinners or custom transitions; the host's own motion only.
- Round what the host keeps square, or force a switch into a pill: corners
  are `Style.cornerRadius`, capped only for small things and pictures.
- Hide a failure or a missing device behind a generic success.
- Run a lighting change as a child process of the shell.
