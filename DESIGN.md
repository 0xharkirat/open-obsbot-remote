---
name: Open OBSBOT Bridge
description: The bridge window as a langar hall before the sangat sits - a row of set places, each served or marked as needing you.
colors:
  maroon: "#7A1F2B"
  on-maroon: "#FFFFFF"
  on-maroon-soft: "#EBD3D6"
  jute: "#C8A96B"
  green: "#2E7D4F"
  green-soft: "#B9DCC6"
  turmeric: "#E0A526"
  turmeric-mark: "#C0820F"
  turmeric-tint: "#FFF6E0"
  on-turmeric-tint: "#7A5409"
  limewash: "#F6F7F4"
  surface: "#FFFFFF"
  line: "#DCDDD8"
  ink: "#1D2125"
  ink-soft: "#4A535B"
  steel: "#9AA3AB"
  steel-light: "#E2E5E8"
  steel-dark: "#6B747C"
typography:
  display:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "32px"
    fontWeight: 700
    lineHeight: 1.15
  headline:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "19px"
    fontWeight: 700
  title:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "17px"
    fontWeight: 700
  value:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    letterSpacing: "0.2px"
    fontFeature: "tnum"
  body:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.4
  body-band:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.35
  button:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "15px"
    fontWeight: 700
  dialog-title:
    fontFamily: "Atkinson Hyperlegible, sans-serif"
    fontSize: "22px"
    fontWeight: 700
rounded:
  pill: "999px"
  plate: "14px"
  control: "10px"
  tooltip: "6px"
spacing:
  hair: "2px"
  step: "8px"
  sm: "12px"
  place-gap: "14px"
  panel: "18px"
  column-gap: "24px"
  section: "28px"
  gutter: "28px"
components:
  button-primary:
    backgroundColor: "{colors.maroon}"
    textColor: "{colors.on-maroon}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "44px"
  button-primary-disabled:
    backgroundColor: "{colors.steel-light}"
    textColor: "{colors.steel-dark}"
  button-outlined:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.maroon}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "0 16px"
    height: "44px"
  button-text:
    textColor: "{colors.maroon}"
    rounded: "{rounded.control}"
    height: "40px"
  runner-band:
    backgroundColor: "{colors.maroon}"
    textColor: "{colors.on-maroon}"
    typography: "{typography.display}"
    padding: "22px 16px 22px 28px"
  place-tile:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.plate}"
    padding: "0 14px"
    height: "92px"
  place-tile-needs:
    backgroundColor: "{colors.turmeric-tint}"
    textColor: "{colors.on-turmeric-tint}"
    rounded: "{rounded.plate}"
  panel:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.plate}"
    padding: "18px"
  panel-attention:
    backgroundColor: "{colors.turmeric-tint}"
    rounded: "{rounded.plate}"
    padding: "18px"
  camera-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0 8px 0 16px"
    height: "64px"
  copy-field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "44px"
  on-air-pill:
    backgroundColor: "{colors.maroon}"
    textColor: "{colors.on-maroon}"
    rounded: "{rounded.pill}"
    padding: "7px 12px"
  dialog:
    backgroundColor: "{colors.limewash}"
    textColor: "{colors.ink}"
    typography: "{typography.dialog-title}"
    rounded: "{rounded.plate}"
  snackbar:
    backgroundColor: "{colors.ink}"
  tooltip:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.on-maroon}"
    rounded: "{rounded.tooltip}"
---

# Design System: Open OBSBOT Bridge

Scope: this file records the Langar Hall world as it is built in the bridge desktop window (`apps/bridge/lib`), on macOS and Windows, with one design on both. The phone remote (`apps/rc`) does not use this system yet. The remote is a later surface; when it adopts the world, extend this file, do not fork it. The tokens live in `apps/bridge/lib/langar_theme.dart`; the custom parts live in `apps/bridge/lib/langar_widgets.dart`.

## Overview

**Creative North Star: "The Langar Hall"**

The service is a row of set places, as in a langar hall before the sangat sits. Limewashed walls, a long durrie-maroon runner, a steel thali at every place. The window shows which places are served and the one that still needs you. It is not a grey settings list of status dots and toggles, and it must not feel like a gamer or tech tool.

The window answers one question first: is everything OK for the service? A maroon runner band carries that answer as one large sentence. Under it, four equal places (Bridge, Cameras, OBS, Phones) each show a thali mark, a name and a real value. Only a place that needs the user changes emphasis, and its fix appears in the column below. The rest stays quiet. Density is low and the type is large, because the volunteer reads it in a dim hall, at a glance, maybe once a month.

The state is a shape, not only a colour. Places never move or resize; only their content changes. Motion is one authored moment (a 240 ms fill or empty of the plate, and a cross-fade of the answer), and nothing reflows.

**Key Characteristics:**
- One maroon runner band with a plain jute edge owns the top of the window.
- Four fixed places in one row; a place that needs you gains a turmeric edge and tint, never a new size or position.
- Three state shapes: filled green plate with a tick, open green ring, solid turmeric plate with an exclamation mark.
- One family (Atkinson Hyperlegible) at large, clear steps.
- Flat white panels on a limewash ground; standard Material controls themed to the world.
- Short plain words, about 80% ASD-STE100.

## Colors

A warm, quiet hall: limewash and white for the ground, maroon for the window's own voice, green for what is done or on its way, and turmeric held back for the one thing that needs you.

### Primary
- **Durrie Maroon** (`maroon`): the runner band, the Windows 11 title bar (DWM caption and border), the ON AIR pill, filled buttons, outlined button text and border, switches when on, the cursor, selection (maroon at about 27%) and the focus wash (maroon at 20%).
- **Band White** (`on-maroon`): the answer sentence, the settings icon and all text on maroon or ink.
- **Rose Thread** (`on-maroon-soft`): the detail sentence under the answer in the band.
- **Jute** (`jute`): the 4 px plain bottom edge of the runner band. Nothing else.

### Secondary
- **Leaf Green** (`green`): connected and in progress. The served plate and the heavy quarter of the in-progress ring. Holds a white tick at more than 5:1.
- **Pale Leaf** (`green-soft`): the track of the in-progress ring.

### Tertiary
- **Turmeric** (`turmeric`): the 2 px border of a place or panel that needs you.
- **Deep Turmeric** (`turmeric-mark`): the solid needs plate, dark enough to hold the white exclamation mark.
- **Turmeric Wash** (`turmeric-tint`): the fill of a needs tile and of an attention panel.
- **Turmeric Ink** (`on-turmeric-tint`): the bold value line on a needs tile.

### Neutral
- **Limewash** (`limewash`): the window ground and the dialog ground.
- **Plate White** (`surface`): tiles, panels, camera rows, copy fields, the QR backing.
- **Rule Grey** (`line`): 1 px borders on every resting container, and dividers.
- **Ink** (`ink`): text, the QR code, snackbars and tooltips.
- **Soft Ink** (`ink-soft`): value lines, meta text, icon buttons, a camera that is not connected.
- **Steel** (`steel`, `steel-light`, `steel-dark`): the scrollbar thumb (dark on hover or drag), the switch track and thumb when off, disabled filled buttons.

### Named Rules
**The Turmeric Means You Rule.** Turmeric appears only on a place, panel or plate that needs the user. It is never decoration, never a highlight, never on air. The ON AIR dot is white for this reason.

**The Green Is Good Rule.** Whatever is connected or in progress is green (user's call, 2026-10-11). Do not use amber, blue or grey for "starting"; the open green ring carries it.

**The One Voice Rule.** Maroon is the window's own colour. It is the band and the primary action, and it does not mark status.

## Typography

**Display Font:** Atkinson Hyperlegible Bold (bundled, OFL, `apps/bridge/assets/fonts`), sans-serif fallback
**Body Font:** Atkinson Hyperlegible Regular

**Character:** one family built for low-vision legibility, used at large sizes so a volunteer reads it across a dim hall. Hierarchy comes from size and weight, never from a second family.

### Hierarchy
- **Display** (700, 32 px, 1.15): the one-sentence answer in the band ("Ready for the service", "2 things need you"), in white.
- **Band body** (400, 16 px, 1.35): the detail sentence under the answer, in Rose Thread.
- **Value** (700, 24 px, tabular figures, 0.2 px tracking): the address to open on the phone. The revealed PIN uses it at 34 px with 6 px tracking.
- **Dialog title** (700, 22 px): settings and confirm dialogs.
- **Headline** (700, 19 px): section heads, such as Cameras and the fix names (Connect OBS, Connect a phone).
- **Title** (700, 17 px): place names, camera names, setting names.
- **Body** (400, 15 px, 1.4): instructions and numbered fix steps.
- **Label** (400, 14 px, 1.35): values on places, meta lines, field labels, hints. Bold in Turmeric Ink on a needs tile.
- **Button** (700, 15 px; text buttons 14 px).

### Named Rules
**The Big Answer Rule.** The window has exactly one Display line, and it is the answer. The only text set larger is the revealed PIN (34 px Value), and it shows only when the user asks for it.

**The Plain Words Rule.** Copy is short plain words, about 80% ASD-STE100: one idea per sentence, the verb first in instructions ("Paste this into Input."). No em dashes anywhere.

## Layout

The window opens at 920 x 720 and does not go below 720 x 560. Content scrolls under a fixed band.

- **Band:** full width, padding 22 px top and bottom, 28 px left, 16 px right; the settings icon sits at its top right.
- **Page:** 28 px side gutter, 20 px top, 24 px bottom.
- **Places row:** four equal places with 14 px between them, 92 px tall. When a place is narrower than 190 px (at the 720 px minimum a place is about 155 px), the thali shrinks from 44 px to 34 px and its gap from 12 px to 10 px, so the value still fits.
- **Body:** 28 px under the places. Two columns, Cameras (flex 11) and the fix column (flex 10), with a 24 px gap. Under 760 px of content width the columns stack, fix column first, then Cameras, 28 px apart.
- **Fix column:** one section per place that needs you, in place order, 24 px apart, so no fix hides behind another. With nothing to fix it offers pairing, then the OBS output field.
- **Rhythm:** the base step is 8 px (between camera rows). In use: 2 px between a name and its value, 6 px under labels, 10 to 12 px inside panels, 18 px panel padding, 24 px between columns and fixes, 28 px between page bands.

### Named Rules
**The Set Places Rule.** Places never move, reflow or resize. Two value lines are always reserved in each tile, so every name sits on the same line whether or not its value wraps.

## Elevation & Depth

Flat by default, with tonal layering: white plates on a limewash ground, each with a 1 px Rule Grey border. The only shadow is a soft ambient lift under the four place tiles, so they read as set plates on the runner; panels, rows and fields have none. Attention is shown by colour and border weight, never by raising a surface.

### Shadow Vocabulary
- **Place lift** (`0 2px 6px rgba(29,33,37,0.06)`): the four place tiles only.

### Named Rules
**The Flat Panel Rule.** Panels never get a shadow. A panel that needs you gets a turmeric border and tint, not elevation.

## Shapes

Softly rounded plates and controls, and true circles for state.

- Plates (place tiles, panels, dialogs) round at 14 px.
- Controls (buttons, camera rows, copy fields, the QR backing) round at 10 px.
- The ON AIR pill is fully round; tooltips round at 6 px; the scrollbar thumb is 6 px wide with 3 px ends.
- Borders: 1 px Rule Grey at rest; 2 px turmeric for needs; outlined buttons take a 2 px maroon border.
- The runner band is square, full bleed, with its one 4 px jute edge at the bottom.
- The thali is a circle. Its state is drawn in the circle: fill, ring or mark.

## Components

Standard Material components, themed to the world, plus five custom parts. The controls feel plain and sure: big targets (44 px), bold short labels, maroon.

### Buttons
- **Shape:** gently rounded (10 px).
- **Primary (FilledButton):** maroon fill, white bold 15 px label, 44 px tall, 18 px side padding. Used for the main fix action (Start the bridge, Show PIN and QR code).
- **Outlined (OutlinedButton):** white with a 2 px maroon border and maroon label, 44 px tall, 16 px side padding. Used for Put on air, Copy, and second actions.
- **Text (TextButton):** maroon label, 14 px, 40 px tall. Used for Hide, Cancel, Phone cannot connect?
- **Icon (IconButton):** Soft Ink, 40 px square. White on the band, with a 13% white hover wash.
- **Disabled:** steel-light fill.
- **Focus:** a maroon wash at 20%.

### Copy Field
- **Style:** a label line above; a 44 px white field with a 1 px line border and 10 px radius, text 14 px on one line with ellipsis; an outlined Copy button beside it.
- **State:** on copy the button reads "Copied" with a check icon for 1.5 s, then returns. A secret token is shown masked (`?t=••••••••`) and copied in full.

### Cards / Containers (Panel)
- **Corner Style:** 14 px.
- **Background:** Plate White; Turmeric Wash when it needs you.
- **Shadow Strategy:** none (see Elevation).
- **Border:** 1 px Rule Grey; 2 px Turmeric when it needs you.
- **Internal Padding:** 18 px.

### Camera Row
One row per camera, 64 px tall, white with a 1 px line border and 10 px radius. Name in Title (Soft Ink when not connected), state under it in Label ("Ready", "Asleep", "Privacy mode", "Not connected"). At the right: the ON AIR pill on the camera OBS shows, otherwise an outlined Put on air button, then a rename icon. No previews; full control stays in the remote.

### Dialogs, Snackbars, Tooltips, Switches
- **Dialog:** limewash ground, 14 px radius, 22/700 title. Settings, Rename camera, Reset pairing?
- **Snackbar:** ink ground, 15 px text, floating ("Pairing link copied").
- **Tooltip:** ink with white 13 px text, 6 px radius.
- **Switch:** maroon track and white thumb when on; steel-light track and steel-dark thumb when off.

### Runner Band (signature)
The maroon band at the top, with a plain 4 px jute bottom edge. It holds the one-sentence answer in white Display and the detail in Rose Thread. When the answer changes it cross-fades in 240 ms (ease-out expo) in place, and is a live region for screen readers. On Windows 11 the title bar continues the maroon (DWM caption and border colour, white caption text), so the band starts at the top of the window.

### Thali Mark (signature)
The status plate on each place, 44 px (34 px in a narrow place).
- **Served:** a filled Leaf Green plate with a white round-capped tick.
- **In progress:** an open ring in Pale Leaf with one quarter, from the top, drawn heavier in Leaf Green.
- **Needs you:** a solid Deep Turmeric plate with a white exclamation mark.
- **Motion:** when the state changes, the plate fills from its centre outward in 240 ms (ease-out expo), or empties back for in progress. The mark appears after 60% of the fill. Nothing around it moves.
- **Semantics:** read as "ready", "waiting" or "needs you".

### Place Tile (signature)
A 92 px plate: thali, then the place name (Title, one line) and its real value (Label, two lines reserved). Needs you: Turmeric Wash fill, 2 px Turmeric border, value bold in Turmeric Ink, animated over 240 ms. Values are real ("Running", "1 ready", "Not connected", "None connected").

### ON AIR Pill (signature)
A maroon pill, 7 px by 12 px padding, with an 8 px white dot and "ON AIR" in 13 px bold, 0.8 px tracking, white. It marks the one camera that OBS shows now.

### Pairing
The address in Value (selectable), the second address in Label, then "Show PIN and QR code" as a primary button. Revealed: a 132 px ink-on-white QR in a white rounded backing, the PIN in 34 px Value with wide tracking, "Hides in 60 seconds.", then Copy link and Hide. The PIN hides itself after 60 s.

## Do's and Don'ts

### Do:
- **Do** answer "is everything OK for the service?" first, in one sentence in the band, in Display.
- **Do** show every state as a shape and a colour together: filled green plate with tick, open green ring, solid turmeric plate with exclamation mark.
- **Do** keep the four places fixed in size and position; reserve two value lines in each.
- **Do** put the fix for a place that needs you in the fix column, one section per place, in place order.
- **Do** show real values only: the LAN address, the OBS input URL, camera names, the paired-phone count.
- **Do** use the themed Material controls (FilledButton, OutlinedButton, TextButton, IconButton, Switch, AlertDialog) at 44 px targets.
- **Do** keep motion to the 240 ms fill or empty and the answer cross-fade (ease-out expo).
- **Do** write short plain words, about 80% ASD-STE100, verb first in steps.

### Don't:
- **Don't** use a woven, checker or striped pattern anywhere, on the band or on a plate (user-pinned, 2026-10-11). The band's jute edge is one plain line.
- **Don't** use turmeric for anything but "needs you": not for on air, not for hover, not for a highlight.
- **Don't** mark connected or in progress with any colour but green.
- **Don't** grow, move or reorder a place to draw attention; change its border, tint and plate only.
- **Don't** raise a panel with a shadow; the place lift is for the four tiles only.
- **Don't** add camera previews or a wall of settings to this window; settings sit behind the one icon in the band.
- **Don't** add a second type family, or a second line at display size.
- **Don't** use em dashes in any copy or file.
