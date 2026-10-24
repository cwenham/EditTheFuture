# Edit The Future: UI design

Draft 1, 2026-10-25. Companion to [DESIGN.md](DESIGN.md).

Mockups are on the design canvas at https://claude.ai/artifact/PoMFiacRKa3XwhCmEK9hXM, which stays private until it's shared. The Mac panel artboard is interactive: move the pointer over the graph to scrub the cursor, click the slot chips or lane names to change focus, and drag the opacity slider.

| Artboard | What it shows |
|---|---|
| Mac panel (interactive) | The floating panel over another app: slot chips, focused graph with bands, readings, events, now line, drift pill, lanes, command bar |
| Drag the future | Target handle, proposed path, ranked fixes |
| Add an event | Popover at the cursor, natural-language field answered by the paired iPhone, manual form, live preview |
| Glance | Click-through HUD pinned over a spreadsheet, hardware wheel toast |
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
- Default size 1180×760. Resizable; the frame is remembered per display.

**Header:**
- Scenario menu.
- Eight slot chips: number, color and name. Empty slots are dashed with a "+".
- Copy snapshot, a click-through toggle, an opacity slider, and Hide.

**Focus area:**
- Slot name and model summary ("Market model · monthly · median with bands").
- Toggles for Bands, Readings and Events.
- The graph with its y axis.
- A readout column: cursor date, value, what kind of value it is (Reading, Statement, Projection, Median projection), and the 10–90% range when there is one.

**Now line:** labelled "Now · Oct 2026". When the latest readings leave the projected band, a drift pill sits to its left.

**Events strip:** one row under the time axis for the focused slot.

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
| Two-finger horizontal scroll, mouse wheel | Scroll time |
| Pinch, ⌘-scroll | Zoom time (semantic zoom: days → months → years → decades) |
| ⌥-scroll | Zoom the value axis (auto-fit is the default; ⌥0 resets) |
| ← / → | Move the cursor one step; ⇧ moves one year |
| T | Jump to now |
| 1–8 | Focus a slot |
| S / M | Solo or mute the focused slot |
| [ / ] | Previous or next bank |
| E, double-click | Add an event at the cursor |
| Drag the projection | Drag the future (5.2) |
| ⇧-drag the projection | Sketch a target curve |
| ⌘C / ⇧⌘C | Copy snapshot / copy data |
| ⌘K | Command bar |
| ⌘I / ⌘L | Slot inspector / links view |
| Esc | Cancel the current gesture, otherwise hide the panel |

### 4.2 Global hot-keys

All of these are configurable. Defaults include Control because sandboxed apps on macOS 15 can't register Option-only shortcuts.

| Hot-key | Does |
|---|---|
| ⌃⌥Space, tap | Toggle the panel |
| ⌃⌥Space, hold for more than 250 ms | Peek: shown while held, hidden on release |
| ⌃⌥T | Toggle click-through |
| ⌃⌥C | Copy snapshot without showing the panel |
| ⌃⌥E | Add an event at now |

**Peek:**
- The panel appears within one frame (no slide animation) in click-through mode, at the user's peek opacity.
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
- On iPhone, scrubbing gives a light haptic tick at each year.

### 5.2 Drag the future

1. **Grab:** hovering the projection after now shows a grab handle.
2. **Drag:** dragging up or down sets a target at that date. A bracket shows the gap ("+$86,860").
3. **Solve:** the solver re-runs as you drag, throttled to about 30 Hz, and each new request cancels the previous one. The proposed path is drawn dashed.
4. **Choose a fix:** the side card ranks fixes by smallest change. "Change" (deposits, interest rate, withdrawals, anything) and "Starting" limit what the solver may touch. ↑/↓ chooses a fix and ⌘↩ adds it as events. Esc cancels.
5. **Sketch instead:** ⇧-drag draws a whole curve, and the solver fits several events to it. Apple Pencil does the same on iPad (section 8).

### 5.3 Adding an event

- **Where:** E or double-click opens a popover at the cursor.
- **Describe it:** the natural-language field comes first. Under it is a summary of what was understood, with ✓, and which device answered ("via iPhone 17"). With no provider available, the field is hidden and the form stands alone.
- **The form:** a kind control (Deposit, Withdraw, Rate, Shock, Custom), then amount, first date, repeats and until.
- **Preview:** a dashed line on the graph, and the effect at a chosen horizon ("Effect by Jan 2040: +$X").
- **Confirm:** ↩ adds the event; Esc cancels.

### 5.4 Editing and moving events

- Clicking a marker opens the same popover, with Delete. Deleting asks for confirmation (DESIGN.md, section 13).
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

- A compact card pinned to a screen corner, in click-through mode.
- Shows chosen slots at now and at a pinned date, each with a sparkline.
- ⌃⌥T makes it interactive. Holding ⌃⌥Space peeks the full panel.

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
  - `MenuBarExtra` for the menu bar item and a `Settings` scene
  - global hot-keys with the KeyboardShortcuts package; peek handles key-down and key-up separately
- **Charts:** Swift Charts on macOS 15 and iOS 17+.
  - Marks: `LineMark` for lines, `AreaMark` for bands, `PointMark` for readings, `RuleMark` for now and the cursor.
  - Scrubbing: `chartXSelection`.
  - Scrolling: `chartScrollableAxes(.horizontal)`, `chartXVisibleDomain` and `chartScrollPosition`.
  - Drag gestures: `chartOverlay`.
  - Feed the charts downsampled tiles from the engine (DESIGN.md, 4.7). Move to a Canvas or Metal renderer only if profiling demands it.
- **State:**
  - One `@Observable` view model per scenario, backed by an actor that owns the `Scenario`.
  - The visible range and the cursor drive `ensure(through:)`, as cancellable tasks.
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
