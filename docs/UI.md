# Edit The Future: UI design

Draft 1, 2026-10-25. Companion to [DESIGN.md](DESIGN.md).

Mockups are on the design canvas at https://claude.ai/artifact/PoMFiacRKa3XwhCmEK9hXM, which stays private until it's shared. The Mac panel artboard is interactive: move the pointer over the graph to scrub the cursor, click the slot chips or lane names to change focus, and drag the opacity slider.

| Artboard | What it shows |
|---|---|
| Mac panel (interactive) | The floating panel over another app: slot chips, focused graph with bands, readings, events, now line, drift pill, lanes, command bar |
| Drag the future | Target handle, proposed path, ranked fixes |
| Add an event | Earlier popover design, since replaced by the docked add-event pane (section 5.3) |
| Glance | Compact HUD pinned over a spreadsheet, hardware wheel toast (the mockup still labels it click-through, which has since been dropped) |
| Slot inspector | Formula editor with a same-step loop error and quick fix, links view with the loop highlighted |
| Menu bar item | Values now and at a pinned date, quick actions, controller and iPhone status |
| Settings | Controllers and paired devices |
| iPad | Apple Pencil sketch of a target path and the fitted plan |
| iPhone app | Single focused slot with a large readout, lanes list, ask bar |
| iPhone surfaces | Live Activity with drift, widgets, Siri answer |

## 1. Principles

1. **The graph is the app.** Chrome stays thin and gets out of the way of the timeline.
2. **Readable at a glance, over other work.** Large readouts, tabular figures, and a translucent window with a floor on contrast.
3. **One command vocabulary.** Everything on screen is also a `Command` (DESIGN.md, 10.1): reachable from keyboard, menus, the command bar, hardware, Shortcuts and the CLI.
4. **Direct manipulation.** Drag the line to set a goal, double-click the timeline to add an event, drag an event to move it.
5. **Color is never the only cue.** Slots carry a number and a name. Past and future differ in line weight and background tint. Generated events are hollow with italic labels. Proposals are dashed.
6. **Nothing changes without a preview.** Natural-language events, goal-seek fixes and Pencil sketches all show a dashed preview and need confirming.

## 2. Visual language

### 2.1 Color tokens (dark, the default)

| Token | Value | Use |
|---|---|---|
| `panel` | `rgba(20,22,27,α)`, α = 0.86 by default, user range 0.60–1.00 | Panel background over a blur of what's behind |
| `hairline` | `rgba(255,255,255,0.08)` | Dividers, chip borders |
| `text` | `#ECEEF1` | Primary text, values |
| `text.secondary` | `#A3A9B1` | Labels, axes, metadata. At least 4.5:1 at α ≥ 0.60 over a light window |
| `future` | `rgba(255,255,255,0.03)` | Tint right of the now line |
| `now` | `rgba(255,255,255,0.45)` | Now line |
| `cursor` | `rgba(255,255,255,0.85)` | Shared cursor line; date flag uses `text` on dark |
| `proposal` | `#A9D0FF` | Drag the future, previews, selected fix |
| `warning` | `#FFC77A` on `rgba(255,180,84,0.16)` | Drift alerts |
| `error` | `#FF9C9C` text, `#FF6B6B` strokes | Loops, failed models |
| `success` | `#9FE3C4` | Parsed natural language, positive deltas |

Light and high-contrast themes are open questions (section 13). With Reduce Transparency on, the panel is opaque (α = 1) and the blur is off.

### 2.2 Slot palette

The default color comes from the slot's position and matches the hardware LED for that button. Users can change it.

| Slot | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Color | `#5AA9FF` | `#4FD1A5` | `#FF9F43` | `#FF7A93` | `#C3A6FF` | `#F2D45C` | `#46C8E0` | `#E8A0D0` |

### 2.3 Type

- **UI:** SF Pro (the system font). Every number uses tabular figures.
- **Formulas:** SF Mono.
- **Sizes (Mac):** 11 axis and small labels, 12 secondary, 13 body, 15 section titles, 18 focused slot name, 22 cursor readout.
- **iOS:** the same sizes +2, following Dynamic Type.

### 2.4 Marks on the graph

| Mark | Drawn as |
|---|---|
| Readings (past) | Dots on a thin line, 85% opacity |
| Projection (future) | Thicker solid line |
| Bands | 25–75% at 16% fill, 10–90% at 12% fill |
| Preview or proposal | Dashed line in `proposal` |
| Recurring event | Thin bar in the slot color, label at its start |
| One-off event | Filled diamond, label centered above |
| Generated event | Hollow circle, italic secondary label |
| Proposed event | Dashed diamond or dashed bar in `proposal` |
| Drift | Warning pill attached to the now line |

## 3. Mac panel anatomy

**Window:**
- An `NSPanel` (non-activating, floating level, `.canJoinAllSpaces`, `.fullScreenAuxiliary`), hosting SwiftUI.
- Material background with the opacity from section 2.1. Corner radius 14.
- Default size 1400×820, minimum 1100×600. Resizable; the frame is remembered per display. The focused graph takes all the height left after the axis, events strip and lanes, so making the window taller makes the graph taller.
- Moves only by dragging the top bar. Drags on the timeline are kept for timeline gestures (drag the future, moving events).
- No click-through mode: the panel always takes clicks while it's visible, and hides with Esc or the hot-key.

**Header:**
- Scenario menu.
- Eight slot chips: number, color and name. Empty slots are dashed with a "+".
- Now (puts the cursor on now, scrolling back to it if needed), Copy snapshot, an opacity slider, and Hide.

**Focus area:**
- Slot name and model summary ("Market model · monthly · median with bands").
- Toggles for Bands, Readings and Events.
- The graph with its y axis.
- A readout column: cursor date, value, what kind of value it is (Reading, Statement, Projection, Median projection), and the 10–90% range when there is one.

**Now line:** labelled "Now · Oct 2026". When the latest readings leave the projected band, a drift pill sits to its left.

**Events strip:** one row under the time axis for the focused slot. Its label reads "click to pick a date".

**Add-event pane:** always visible, docked on the left or right of the timeline (section 5.3). Drag its title bar to the other side, where a drop zone lights up, or use its arrow button; the side is remembered.

**Lanes:** one per other slot in the bank. Each lane has:
- the slot number, color bar and name
- what it reads from other slots ("← Climate.temp.mean")
- mute and solo buttons
- a sparkline on the same time axis as the focused graph
- the value at the cursor

Clicking a lane's name focuses that slot.

**Cursor:** one vertical line through the graph and every lane, with a date flag on the time axis. Every readout shows values at the cursor.

**Footer:** the command bar (⌘K), which takes commands, events and questions, plus a status line ("Computed through Dec 2040 · 5 of 8 slots · 1 link").

## 4. Input

### 4.1 Inside the panel

| Input | Does |
|---|---|
| Move the pointer over the graph or lanes | Cursor follows (scrub) |
| Click | Pins the cursor; Esc unpins |
| Mouse with two wheels: horizontal wheel / vertical wheel | Scroll time / zoom time (wheel up zooms in) |
| Mouse with one wheel: wheel / Shift + wheel | Scroll time / zoom time |
| Trackpad or Magic Mouse: swipe / pinch, Shift or ⌘ + swipe | Scroll time / zoom time |
| ⌥-scroll | Zoom the value axis (auto-fit is the default; ⌥0 resets) |
| ← / → | Move the cursor one step; ⇧ moves one year |
| T, or the Now button | Jump to now |
| 1–8 | Focus a slot |
| S / M | Solo or mute the focused slot |
| [ / ] | Previous or next bank |
| Click the graph or events strip | Pick that date for the add-event pane and put the keyboard in its amount field |
| Click a lane's graph | The same, and switch the pane (and focus) to that lane's slot |
| E | Pick the cursor's date for the add-event pane |
| Drag the projection | Drag the future (5.2) |
| ⇧-drag the projection | Sketch a target curve |
| ⌘C / ⇧⌘C | Copy snapshot / copy data |
| ⌘K | Command bar |
| ⌘I / ⌘L | Slot inspector / links view |
| Esc | Cancel the current gesture, then leave the field being edited, then hide the panel |

**Mouse wheels:** macOS doesn't report how many wheels a mouse has, so the app watches for one. The first wheel event with a horizontal movement and no Shift held can only come from a horizontal wheel. From then on the vertical wheel zooms, and the app says so in the status line. (macOS turns Shift + vertical wheel into horizontal movement, so those events don't count.) The finding is remembered, and the menu bar item has a "Mouse Has a Horizontal Wheel" toggle to override it. Zooming centres on the pointer.

### 4.2 Global hot-keys

All of these are configurable. Defaults include Control because sandboxed apps on macOS 15 can't register Option-only shortcuts.

| Hot-key | Does |
|---|---|
| ⌃⌥Space, tap | Toggle the panel |
| ⌃⌥Space, hold for more than 250 ms | Peek: shown while held, hidden on release |
| ⌃⌥C | Copy snapshot without showing the panel |
| ⌃⌥E | Show the panel with the add-event pane's date at now and the keyboard in its amount field |

**Peek:**
- The panel appears within one frame (no slide animation), without taking keyboard focus from the app you're in.
- Releasing the key hides it.
- While peeking, the hardware wheel scrubs the cursor.
- The hardware peek button behaves the same way.

### 4.3 Hardware

Commands come through the MIDI profile (DESIGN.md, 12.3):
- Slot buttons focus slots. Toggle and Peek match the hot-keys.
- The wheel follows its mode. When the mode changes, a toast shows the new mode (the Glance artboard).
- Slot LEDs mirror slot colors, and pulse while a slot computes.

## 5. Interactions

### 5.1 Scrubbing and the cursor

- Scrubbing is free; computation follows lazily. If the cursor moves past what's computed, the readout shows a small spinner and the lanes fill in as results arrive.
- **Go to a date or a value:** the command bar's `goto` moves the cursor.
  - **Dates:** `goto 2035`, `goto Jun 2035`.
  - **Values:** `goto 100°C`, `goto mortgage $0`. The cursor lands where the line first reaches the value, looking ahead from now, rising or falling depending on where it starts. The slot is focused, and the footer says when ("Climate reaches 100.0 °C in Jul 4699").
  - **Which slot:** the unit picks it: the focused slot if it's in that unit, otherwise the only slot that is. If several are, it asks for a name (`goto savings $1M`). A bare number needs a slot name, since `goto 2035` means the year.
  - **Units:** dollars (`$1.5m`, `2bn dollars`), °C (`25°C`, `25 c`, `25 degrees`) and °F, converted to °C.
  - **Limits:** the search runs on the engine's thread and gives up after 10,000 years.
- On iPhone, scrubbing gives a light haptic tick at each year.

### 5.2 Drag the future

1. **Grab:** hovering the projection after now shows a grab handle.
2. **Drag:** dragging up or down sets a target at that date. A bracket shows the gap ("+$86,860").
3. **Solve:** the solver re-runs as you drag, throttled to about 30 Hz, and each new request cancels the previous one. The proposed path is drawn dashed.
4. **Choose a fix:** the side card ranks fixes by smallest change. "Change" (deposits, interest rate, withdrawals, anything) and "Starting" limit what the solver may touch. ↑/↓ chooses a fix and ⌘↩ adds it as events. Esc cancels.
5. **Sketch instead:** ⇧-drag draws a whole curve, and the solver fits several events to it. Apple Pencil does the same on iPad (section 8).

### 5.3 Adding an event

- **The pane:** always visible and docked beside the timeline, so you can scroll as far as you like into the future and watch a draft's effect play out. It never scrolls with the graph.
  - Docks on the left or right. Drag its title bar to the other side (drop zones light up), or press its arrow button. The side is remembered.
  - Follows the focused slot. Switching slots keeps the amount and date when the new slot handles the same kind of event.
- **When:** defaults to now. Clicking the graph or events strip picks that date; clicking a lane picks the date and switches to that lane's slot. "Now" puts it back. The date picker also shows and edits the time.
- **The form:**
  - A kind control offering only what the slot's model handles (Deposit, Withdraw, Overpay…), plus Set parameter when the model has parameters.
  - Amount (or parameter and new value), and repeats.
- **Preview:** as soon as the draft is complete, a dashed line shows the new future on the graph. The pane shows the effect at the cursor and at the right edge of the view; both update as you move the pointer and scroll. The preview is computed by trying the event and taking it out again, and is computed one screen ahead so scrolling stays smooth.
- **Confirm:** ↩ in the amount field or Add event adds it (undoable), then clears the amount and puts the date back to now. Clear empties the form. Mistakes get a message under the form ("Enter an amount, e.g. 500 or 1.2k").
- **Other ways in:** E picks the cursor's date; ⌃⌥E from any app shows the panel with the date at now; the command bar takes quick adds (`+500 monthly from 2027-03`).
- **Describe it:** a natural-language field will come first once a provider is available (DESIGN.md, section 7), showing what was understood and which device answered ("via iPhone 17"). Not in M1.

### 5.4 Editing and moving events

- Clicking a marker loads it into the add-event pane, with Delete. Deleting asks for confirmation (DESIGN.md, section 13).
- Dragging a marker sideways moves it in time, snapping to step boundaries; hold ⌥ to move freely.
- Undo and redo cover every change.

### 5.5 Generated events

- Hovering shows where an event came from ("From Climate: temp above 30 °C, 14 Jul 2027").
- Actions: **Pin** turns it into a fixed authored event; **Suppress** asks what happens without it.

### 5.6 Drift alerts

- A pill appears on the graph, and a notification is sent when the app isn't visible.
- Clicking the pill opens "Refit parameters": the model's parameters re-fitted to recent readings, shown as a preview before anything changes.

### 5.7 Slot inspector and links

- **Inspector (⌘I):** tabs for Formula, Variables, Events and Readings.
  - The formula editor checks the formula as you type (debounced 300 ms) and shows errors inline, with quick fixes. Example: "Use FireRisk.OverCapacity[t-1]".
  - Slots affected by an error pause and show "paused" instead of values. They don't show stale numbers.
- **Links view (⌘L):** slots as nodes, connections as wires.
  - Solid wire: same step. Dashed wire: previous step. Wires in a loop turn red.
  - Dragging from an output to another slot creates a connection, with resampling and timing pickers.

### 5.8 Glance HUD

- A compact card pinned to a screen corner. It doesn't take keyboard focus.
- Shows chosen slots at now and at a pinned date, each with a sparkline.
- Clicking it opens the full panel. Holding ⌃⌥Space peeks the full panel.

### 5.9 Copy snapshot

- **What's copied:** the focused slot and the visible lanes over the visible range. A setting can limit it to the focused slot.
- **Formats:** PNG, PDF, tab-separated data and the app's own snapshot format, all at once (DESIGN.md, section 11).
- **Feedback:** a brief flash and a toast: "Copied image, PDF, table and snapshot."

## 6. Menu bar item

- **Values:** the current scenario's values now and at a pinned date.
- **Actions:** Show panel, Copy snapshot, Add event at now, Open scenario.
- **Status:** controller and paired-device status lines.
- **Also:** Settings and Quit.
- **Icon:** monochrome, so it works in light and dark menu bars.

## 7. Settings

Sections:
- General
- Shortcuts
- Controllers and devices
- Plug-ins
- Privacy and security

**Controllers and devices** shows:
- each connected controller, with its profile, mapping table, encoder format, a LED-colors toggle and Learn controls
- paired devices, each with a toggle per capability: natural-language events, Health readings, use as a controller

## 8. iPad

- **Layout:** the same as the Mac, full screen or in a Stage Manager window. Touch targets are at least 44 pt.
- **Touch:** one finger scrubs; two fingers pan and pinch.
- **Pencil tools:** Sketch target, Place event, Erase. Pencil hover (on supported models) moves the cursor without touching.
- **Sketch flow:**
  1. Draw the path you want after now.
  2. The fit card lists the events that follow it and how closely ("Stays within 3% of your line").
  3. Adjust or add the events.
- **Keyboard:** with a keyboard attached, the Mac shortcuts apply.

## 9. iPhone app

- **Top:** one focused slot, with slot chips across the top.
- **Readout:** a large readout at the cursor (date, value, band).
- **Graph:** scrub with a finger; haptic ticks at each year.
- **Below the graph:** event chips for the focused slot, then a list of the other slots with sparklines and values at the cursor.
- **Ask bar:** at the bottom, with dictation. Adding an event opens a sheet with the same form as the Mac popover.
- **Lend to Mac:** a full-screen state that keeps the app awake while serving the paired Mac. Designed for StandBy on a charger (DESIGN.md, section 7).

## 10. iPhone and iPad system surfaces

| Surface | Content |
|---|---|
| Small widget | One slot now, with a sparkline |
| Medium widget | One slot at a target date, with its band |
| Large widget | Three lanes and a now line |
| Lock Screen widgets | Circular: one value. Rectangular: value plus a mini chart |
| Live Activity | A tracked process (fermentation, a savings goal) with progress, and drift when it's off the model |
| Siri / Shortcuts / Spotlight | App Intents answers with a snippet chart ("What will my savings be in 2030?") |
| Control Center / Action button | Open the app, add an event, copy a snapshot |

## 11. Accessibility

- **VoiceOver:**
  - The focused graph exposes an audio graph and chart summary (`AXChartDescriptor`).
  - Lanes read as "Savings, 96,420 dollars at January 2030".
  - The cursor moves with the VoiceOver rotor by step or by year.
- **Keyboard:** everything is reachable; focus rings are visible on the dark material.
- **Contrast:** the opacity slider stops at 60%. Below 80%, labels get a subtle backing so text stays at 4.5:1 over bright windows.
- **System settings:** Reduce Transparency makes the panel opaque. Increase Contrast strengthens hairlines and grid lines. Reduce Motion removes the panel and toast animations.
- **Dynamic Type** on iPad and iPhone; widgets use the system text styles.
- **Color:** never the only cue (section 1, principle 5).

## 12. Implementation notes

- **Mac shell:**
  - an `NSPanel` subclass hosting `NSHostingView`
  - an `NSStatusItem` for the menu bar item
  - global hot-keys with Carbon `RegisterEventHotKey`; peek handles key-down and key-up separately
- **Plots:** drawn with SwiftUI `Canvas`, one path per line (`PlotCanvas`).
  - M1 first used Swift Charts with one `LineMark` per data point. Profiling showed 80% of each frame going to Charts' generic view-graph work: 40–100 ms per frame for a few thousand marks. A path per line costs well under a millisecond.
  - Points that land in the same pixel column are reduced to that column's first, lowest, highest and last values, so a century of daily data still draws only a few thousand points.
  - Axis labels and the events strip are drawn in a `Canvas` too, which keeps the number of SwiftUI views small.
  - **Huge numbers:** the timeline goes on forever, so compounding values eventually outgrow every number. From 10¹⁵ up, values show in scientific notation ("$1.14e28"). Values that overflow show as "∞", and the line breaks where they start. Ranges and tick steps are clamped to ±10³⁰⁰ so they stay finite. (Converting a label past Int.max to a whole number crashed the app.)
- **State and redrawing:**
  - One `@Observable` store per scenario. Views read only what they draw, so SwiftUI redraws only what changed.
    - `timelineState()`: the plots, axes and events. It doesn't read the cursor.
    - `cursorState()`: the readout, each lane's value, and the cursor line and dot, drawn as small shape views on top.
    - `statusText()`: the footer.
    - The add-event pane reads the draft, and only its effect box reads the cursor.
  - Never assign an `@Observable` property its current value. Even setting `nil` to `nil` redraws every view that reads it.
  - The store never computes. It asks `ScenarioEngine` (an actor on its own thread) for the visible range and draws the latest results it has. Past the end of those results, lines stop and readouts show "…" until the rest arrives (DESIGN.md, 4.8).
- **Measuring:** `swift run -c release etf-bench` times the engine, the panel state, and real SwiftUI frames while scrolling, zooming and moving the cursor. It reports main-thread CPU time as well as wall time. `etf-bench flick [frames]` replays zooming all the way out and flicking far into the future, and `etf-bench far [year]` times the engine computing that far. `etf-bench loop`, `engine-loop` and `cursor-loop [scroll|preview]` run long enough to profile with `sample` or Instruments.
- **Snapshots:**
  - `ImageRenderer` renders a chrome-free snapshot view to PNG and PDF.
  - `NSPasteboard.writeObjects` writes several types at once; `Transferable` handles drag-out.
- **iOS:**
  - WidgetKit and App Intents for widgets, Siri, Shortcuts and Controls; ActivityKit for Live Activities.
  - Pencil strokes come from PencilKit (`PKCanvasView` over the graph), sampled into target points for the fit.

## 13. Open questions

- A light theme. The translucent dark panel suits most use, but some people work in bright apps all day.
- Comparing branches: ghost lines plus a difference lane? Needs its own artboard.
- Showing more than one bank at once, perhaps a compact overview strip.
- Axis units and mixed units when lanes are overlaid instead of stacked.
- What the graph shows before the scenario's start date.
- The pairing flow and "Lend to Mac" screens on iPhone.
