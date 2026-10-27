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
| `reading` | `#ECEEF1` at 85% | Readings: dots on a thin line |

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
| Readings (past) | Dots on a thin line in `reading`, 85% opacity. The dots show while they're at least 6 points apart; closer, just the line. Built for the focused graph, for readings of the value it shows. |
| Projection (future) | Thicker solid line |
| Bands | 25–75% at 16% fill, 10–90% at 12% fill |
| Preview or proposal | Dashed line in `proposal` |
| Held-back test (5.11) | A thin dotted line in `proposal`: the selected model's projection from the last cut-off over the readings it didn't see, with a faint dotted line down the graph at the cut-off |
| Recurring event | Thin bar in the slot color, label at its start |
| One-off event | Filled diamond, label centered above |
| Generated event | Hollow circle, italic secondary label |
| Proposed event | Dashed diamond or dashed bar in `proposal` |
| Event being edited | Ringed in `proposal`; faint once the draft moves it to another date |
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
- Eight slot chips: number, color and name. Empty slots are dashed with a "+"; clicking one opens the model picker (5.7). Right-clicking a chip opens its menu, and dragging a chip onto another number moves it. A paused slot's chip shows a pause symbol.
- Now (puts the cursor on now, scrolling back to it if needed), Copy snapshot, an opacity slider, and Hide.

**Focus area:**
- Slot name and model summary ("Market model · monthly · median with bands").
- Toggles for Bands, Readings and Events.
- The graph with its y axis.
- A readout column: cursor date, value, what kind of value it is (Reading, Statement, Projection, Median projection), and the 10–90% range when there is one. "Reading" shows while the cursor is within the slot's readings of the value the graph shows. Long values shrink to fit.

**Now line:** labelled "Now · Oct 2026". When the latest readings leave the projected band, a drift pill sits to its left.

**Events strip:** one row under the time axis for the focused slot. Its label reads "click a date or an event": clicking a one-off event's diamond edits it (5.4), and clicking anywhere else picks that date.

**Side pane:** always visible, docked on the left or right of the timeline. Drag its title bar to the other side, where a drop zone lights up, or use its arrow button; the side is remembered. It has three tabs:
- **Event:** adds events to the focused slot (5.3).
- **Slot:** the focused slot's name, model, parameters, starting values and display settings (5.7).
- **Formula:** the focused slot's formula editor (5.7). The pane is wider while it shows.

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
| 1–8 | Focus the slot at that position |
| S / M | Solo or mute the focused slot |
| [ / ] | Previous or next bank |
| Click the graph or events strip | Pick that date for the add-event pane and put the keyboard in its amount field |
| Click a lane's graph | The same, and switch the pane (and focus) to that lane's slot |
| Click an event's diamond | Load the event into the add-event pane to change or delete it (5.4) |
| E | Pick the cursor's date for the add-event pane |
| Drag the projection | Drag the future (5.2) |
| ⇧-drag the projection | Sketch a target curve |
| ⌘C / ⇧⌘C | Copy snapshot / copy data |
| ⌘K | Command bar |
| ⌘I | The side pane's Slot tab for the focused slot (pressed again, back to Event) |
| ⌥⌘I | The side pane's Formula tab for the focused slot |
| ⌘↩ | In the Formula tab: apply the formula |
| ⌘L | Links view (planned) |
| Right-click a slot chip | The chip's menu (5.7) |
| Esc | Cancel the current gesture, then leave the field being edited, then hide the panel |

**Where the wheel works:** the wheel and trackpad swipes move time only while the pointer is over the graphs and lanes. Anywhere else they scroll what's under the pointer, such as the formula editor, the insert palette or the Slot tab. Pinching zooms time anywhere in the panel.

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

- **The pane:** the side pane's Event tab, always visible and docked beside the timeline, so you can scroll as far as you like into the future and watch a draft's effect play out. It never scrolls with the graph.
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

- **Open:** clicking a one-off event's diamond loads it into the Event tab: its kind, its amount (or parameter and value) and its date. A click within 8 points of a diamond counts, and the pointer turns into a hand over one. The pane says "Editing an event", and the diamond gets a ring.
- **Change:** anything in the form.
  - Picking a date moves the event: click the graph, press E, or use the date picker. The old diamond fades, and a dashed one shows the new date.
  - Choosing a repeat turns it into a recurring event.
  - The dashed line previews the scenario with the event as edited, in place of the old one. The effect counts from whichever date is earlier, so moving an event later shows the difference from where it was.
- **Save** (or ↩) replaces the event, as one change that undo takes back. **Cancel** (or Esc) leaves it as it was. Either way, the pane goes back to what it held before the click.
- **Delete…** asks first, in the pane (DESIGN.md, section 13), then removes the event. Undo brings it back.
- **Stopping:** focusing another slot or pressing ⌃⌥E stops editing, and so does undoing the event's addition.
- **Limits:** the pane changes one value at a time. An event that sets several parameters, or carries values other than an amount, can't be loaded; clicking one says to change it in scenario.md.
- **VoiceOver:** the events strip has an "Edit" action for each one-off event in view.
- **Not built yet:** editing a recurring event by clicking its bar, and dragging a marker sideways to move it in time, snapping to step boundaries (hold ⌥ to move freely).
- Undo and redo cover every change.

### 5.5 Generated events

- Hovering shows where an event came from ("From Climate: temp above 30 °C, 14 Jul 2027").
- Actions: **Pin** turns it into a fixed authored event; **Suppress** asks what happens without it.

### 5.6 Drift alerts

- A pill appears on the graph, and a notification is sent when the app isn't visible.
- Clicking the pill opens Refit (5.11), set to the last year of readings: the model's parameters fitted again, shown as a preview before anything changes.

### 5.7 Models and slots

**Models and slots are separate things:**
- A **model** is a reusable definition: a formula, a script or a plug-in. The model library lists them.
- A **slot** holds one model, with its own name, color, parameter values, events and readings. Two slots can hold the same model, for example two savings accounts.
- Formulas and scripts are copied into the slot when it's added, so changing one slot never changes another. Plug-ins will be referred to by ID and version, since there's no source to copy.
- **Slots keep their positions.** Removing one leaves a gap, so the others keep their numbers, colors and hardware buttons. A scenario always keeps at least one slot.

**The model picker** is a popover. It opens from an empty chip or its menu to add a model, and from a chip's Change model… or the Slot tab's Change… to give a slot a different one.
- A search field at the top. Categories on the left: Money, Growth, Climate, Health, Physics, Blank and Plug-ins. Plug-ins stays empty until the WebAssembly host arrives (DESIGN.md, 16, M4). Blank has a small formula, a small Lua script and a small Python script to start your own from; adding one opens the Formula tab.
- Changing a model starts on the slot's current model.
- Each model shows its kind (Formula, Lua or Python; later Plug-in or Remote) and a one-line description. Python models are listed only when the app includes Python (DESIGN.md, 6.4).
- The detail shows a preview of the model's line over 20 years with its defaults, its parameters and starting values, its step, and the events it handles and sends. The preview is computed off the main thread. A model that reads another slot, like Energy bill, has no preview on its own.
- **Add to slot N** adds the model with its defaults, focuses the slot and opens the Slot tab. ↩ does the same, and Esc closes the picker.
- **Changing** a slot's model keeps the slot's name, color, events and readings. Parameter and starting values carry over wherever the new model has one of the same name. The picker says when some of the slot's events won't apply ("2 deposit events won't apply to this model"). They're kept, but ignored.

**The Slot tab** in the side pane (⌘I) shows the focused slot:
- **Name.** Names start with a letter and can use letters, digits and spaces. Formulas write them without spaces: "Rainy day fund" is `RainyDayFund`. Renaming a slot updates the formulas and scripts in other slots that refer to it, so `Climate.temp` becomes `Weather.temp`, and `"Climate.temp"` in a script becomes `"Weather.temp"`.
- **Model:** its name and kind, with Change…. Under it, Edit formula… and, for a slot with readings of one of its values, Refit… (5.11). For such slots, the name is the Predict with menu: "Predict with Hold the latest ⌄" (5.11).
- **Parameters:** each has its label and value, and a slider when the model gives it a range.
  - These are the values the slot starts with. Changes from a date are events: they're added in the Event tab and listed under the slider ("Changes to 4.0% from Jun 2027"). "Change from a date…" opens the Event tab, ready to set that parameter.
  - While a slider is dragged, a dashed line shows the slot's new future. Letting go applies it.
  - Typing a value and pressing ↩ applies it straight away. Percent parameters are typed in percent: "6" means 6%.
  - A changed parameter has a reset button that puts back the model's default.
  - Every change can be undone.
- **Starting values:** the model's `init` values, such as a starting balance, at the scenario's start date. They're typed and reset the same way.
- **Readings:** where the slot's readings come from (5.10). Each feed shows its title, its source, what it's fetching and what it's readings of ("FRED · DGS10 → rate, as a percent"), and how many readings it has, to when, and when it was checked ("1,704 readings to Oct 2026 · checked 5 min. ago"). While it's fetching, "Fetching…"; when a fetch failed, why, in red. Edit… opens the feed setup screen; × removes the feed, which undo brings back; the refresh button fetches the slot's feeds now. Readings from files and databases are listed too, to be edited in `scenario.md`. Add a feed… opens the feed setup screen.
- **Display:** which of the model's values the graph shows, its format (currency, temperature, percent or number) and its color. A slot with a color of its own has a reset button that puts back its position's color.
- **Duplicate** copies the slot, with its events, to the next free position.
- **Remove** asks first, at the top of the pane: "Remove Climate and its 2 events? Energy bill reads Climate.temp, so it will pause. You can undo this." Undo brings the slot back with its events, and focuses it.
- Event markers name parameter changes the way the model does: "Interest rate → 4%".

**The chip menu** (right-click a chip): Slot settings, Change model…, Duplicate, Move to slot (1–8), Remove…. An empty chip's menu has Add a model…. Dragging a chip onto another number moves the slot there, swapping with any slot already there. A moved slot takes its new position's default color unless it has a color of its own.

**Paused slots:** a slot pauses when:
- it reads a slot or value that isn't there,
- it listens for events from a slot that isn't there or doesn't emit them,
- it's part of a same-step loop with other slots, or
- it reads from a paused slot.

A paused slot shows "Paused" and the reason in place of its line and values, and its chip shows a pause symbol. It never shows stale numbers. It runs again as soon as the problem goes away, for example after undoing a removal.

**Stopped slots:** a script that raises an error while running stops at that step.
- Its line ends there.
- The graph shows "Stopped", the line number and the message at its top, and a lane shows them at its right.
- The footer says when it stopped ("Fails stopped after Jan 2030: line 4: too far").
- The Formula tab lists the error at its line.
- Any edit clears it. If the error is still there, the next computation finds it again.

**Command bar:** `add savings account` adds a model to the first free slot, `add loan to 7` to slot 7, and `remove climate` asks to remove a slot in the Slot tab. 1–8 focus by position; an empty position says how to fill it.

**The Formula tab** (⌥⌘I, or Edit formula… in the Slot tab) edits the focused slot's formula, or its script (Edit script…). The side pane widens to 480 points while it shows.
- **The editor:** SF Mono with line numbers. Keywords are purple, numbers amber, `[t]` and `[t-1]` green, other slots' values and `event.amount` blue, built-ins cyan, labels green and comments grey.
- **Completion:** typing a name opens a list under the caret of what fits there.
  - In an expression: this formula's values and parameters, other slots (choosing one goes straight on to its values), functions (the caret lands between the brackets), built-ins and `and`, `or`, `not`.
  - After `Climate.temp.`, the resampling rules. At the start of a line, the statements. After `step 1`, time units. After `as`, kinds of value. After `on Climate.`, its events too.
  - ↑ and ↓ choose, ↩ or Tab puts the choice in, and Esc closes the list. A second Esc leaves the editor. Nothing is offered inside comments or labels.
- **Insert palette**, under the editor: functions, time and constants, this formula's names, and each other slot's values and events, as chips. Clicking one puts it at the caret, and hovering explains it.
- **Checking:** 300 ms after typing stops, the formula is checked. A mistake gets a dotted underline on the word (or the line), a faint band on its line, and a red line number. A box under the editor explains up to three problems, with their lines, and offers fixes as buttons:
  - a misspelt name or function: "Use rate"
  - a value that uses itself, or two values that use each other, within the same step: "Use balance[t-1]"
  - another slot, value or event that isn't there: "Use Climate.temp"
  - a same-step loop with another slot: "Use EnergyBill.bill[t-1]"
  - taking away a value another slot reads: "Energy bill would pause", as a warning.
- **Preview:** while the formula has no mistakes and the slot would run, the graph shows its new line dashed.
- **Apply** (⌘↩) makes the draft the slot's formula; undo puts the old one back. The model's name gets "(edited)". If the value the graph showed is gone, it shows the formula's first value instead. Mistakes block Apply; warnings don't, and the slots they name pause.
- **Revert** puts the slot's formula back. A draft is kept per slot until it's applied or reverted, so switching tabs or slots loses nothing; "Not applied" marks one.
- **Scripts** (Lua and Python, DESIGN.md 6.4) use the same tab, with these differences:
  - **Colouring by language.** The script API (`every`, `param`, `emit`…) is cyan, the language's own functions and modules pink, keywords purple, and other slots' references inside strings and `s.`, `t.` and `e.` fields blue.
  - **Completion:**
    - Inside a string: other slots, then a slot's values and events.
    - After `s.`: the script's parameters, values and inputs.
    - After `t.`: the time fields. After `e.`: an event's kind, slot and date.
    - Elsewhere: the script API, the language's functions and keywords.
  - **Insert palette:** the script API, inserted as a template in the script's language; `t.` fields; this script's `s.` names; other slots' values and events.
  - **Checks:**
    - Loading the script finds syntax errors and mistakes in declarations, at their line.
    - The dashed preview runs the draft and adds any error it raises, such as "s.wrost isn't declared. … Did you mean s.worst?".
    - Problems with other slots point inside the reference string, with the same fixes as formulas.
  - **Applying** a blank model's script keeps its name, such as "Custom Lua script", without "(edited)".

**Planned:**
- **Variables, Events and Readings** beside the formula, as in the mockup, with each value at the cursor.
- **Saving to the library:** a slot's model saved as "Your models".
- **Plug-ins** in the picker (DESIGN.md, 6).
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

### 5.10 Data feeds

A feed fetches readings from a public source and keeps them up to date (DESIGN.md, 15.8). Readings correct the slot's model: a reading of a parameter sets it from its date, and a reading of a value replaces it (DESIGN.md, 4.6).

**Where it opens:**
- **Add a feed…** in the Slot tab's Readings, for the focused slot.
- **Edit…** on one of the slot's feeds.
- **Add a data feed…** in an empty chip's menu, and **Data feed…** at the bottom of the model picker's categories when adding a model. These give the feed a slot of its own, with the "Hold the latest" model (once called "Data series"), which follows its readings and holds the latest one. Predict with (5.11) offers other ways to project it, compared on its readings.

**The feed setup screen** is a popover, 880 × 560, laid out like the model picker:
- A search field at the top ("debt, CPI, rain, flu…"), searching titles, descriptions, sources and settings.
- **Categories** on the left: Markets, Rates and bonds, Debt, Inflation, Climate, Migration, Disease, and Any source. "Most sources are free and need no key."
- **Ready-made feeds** in the middle, each with its source. A key marks the ones that need one. Any source has any FRED series, World Bank indicator, BLS series, Fiscal Data dataset or open data portal dataset, and CSV or JSON at a web address.
- **The feed**, on the right:
  - Its name, a description, the source with a link to its website, and what its values are ("percent", "°C above the 1901–2000 average").
  - **What to fetch:** the source's settings, filled in from the ready-made feed: a series, a dataset and field, a country, a place. A ⌄ menu beside a setting offers common values (countries, US states' temperature series, BLS series). Help under each says where to find its value.
  - **How to use the readings:** which of the slot's parameters and values the readings are of (the value the graph shows to start); Convert (none, percent points to a fraction, °F to °C), set to fit when the source's units differ from the variable's; how often to check (as the source updates, hourly, daily, weekly, monthly); and the earliest reading.
  - **Sign-in:** whether the source needs one (Not needed, Optional, Needed), what a key changes, and a link to get one ("Get a free key"). A box to paste the key, with an eye button to show it. Sources at a web address also offer a key in a header, a bearer token, or a username and password, in a menu, with the parameter's or header's name. When one is saved: "A sign-in for fred is saved. Paste a new one to replace it", with Forget. Under it: "Kept in your Keychain, never in the scenario file. Sent only to api.stlouisfed.org, over HTTPS." Sources that need no sign-in don't show this part.
- **Footer:** Test fetches the last year of readings without adding anything, using the sign-in as typed, and shows how many came, their span and the latest, with a small chart, or what went wrong. Cancel (Esc), and Add to *slot* (↩), Save when editing, or Add to slot *N* for a slot of its own. Add needs the source's required settings, and a sign-in when the source needs one. A sign-in typed in is saved to the Keychain when the feed is added.

**After adding:** the feed's line is written to `scenario.md`, the footer says "Fetching its readings…", and the Slot tab shows its progress. Readings appear as dots on the graph when it shows their value.

### 5.11 Predict with and Refit

This is how the app chooses and fits the model behind a slot's projection (DESIGN.md, 8.4). There's no mockup yet. Both are built (October 2026).

**Predict with** is a popover from the Slot tab, 700 × 460, laid out like the model picker. For a slot with readings of one of its values, the Model row's name is a menu button: "Predict with Hold the latest ⌄".
- **The header:** "Predict Data with", the readings to fit and compare on (as Refit's, below), and **Use the best**, which chooses the model tagged Best once every score is in.
- **The list,** on the left: the slot's own model first under "This slot" (unless it's one of the Forecast models), then the Forecast models, then library models that have the same value, under their categories (DESIGN.md, 8.4). Each row has the model's name, its one-line description, and its score once it's worked out ("off by 2.13%", "off by 0.755 °C"), "…" until then, or "can't compare" when its values can't be compared with the readings. The best has a Best tag, and the slot's own model a tick.
- **Selecting** (hover, or ↑ and ↓): the graph shows the model's fitted line dashed, a screen to each side of the view, and its held-back test dotted (2.4). The card on the right shows its name, its score ("Off by 0.755 °C. How far its projections missed 1,164 readings they didn't see, made at three cut-offs and the points after them. The dotted line is its projection from Aug 2016."), and its values fitted to every reading ("Change per year 0.04251 °C"). Scores have three significant figures, so close ones can be told apart.
- **Choosing** (click, or ↩ with the card's **Use Trend line**): the slot gets that model with its fitted values, rounded to six significant figures, as one change that undo takes back. The footer says so: "Data now predicts with Trend line: Value in 2000 0.7304 °C, Change per year 0.04239 °C". Choosing the slot's own model writes its refitted values, as Refit does. **Cancel** (Esc) changes nothing.
- **At the bottom:** while it works, "Comparing 7 models…" with a spinner; with too few readings, why ("Comparing models needs more readings: at least 12 before the first cut-off, and 4 after each. Data has 15 in all."), and no scores. Then **Other model…**, which opens the model picker, and **Edit formula…**.
- **Closing:** Cancel, choosing, focusing another slot, opening Refit, or switching to the Event or Formula tab closes the menu, drops its previews and stops its work. Scores are kept, so opening it again shows them straight away.
- **Speed:** a few seconds for monthly readings over a century; about half a minute for 30 years of daily ones. Scores fill in as each model finishes, cheapest first, and the panel keeps scrolling.

**Refit…** opens a sheet in the side pane, in place of the Slot tab's settings. It's offered for a slot that runs and has readings of one of its values.
- **The title:** "Refit Debt", and "Fits values to Debt's readings. Nothing changes until you apply them."
- **What may change:** a box for each parameter and starting value without readings of its own, with its value now. The ones the model marks `fit` start ticked. A model with none marked starts with none ticked, and says "Tick the values to fit."
- **Which readings:** a menu of All readings, The last year, and The last 5, 10, 25 or 50 years, counted back from the latest reading. Earlier readings still correct the model; only their misses don't count. Readings from before the scenario's start count too (DESIGN.md, 8.4).
- **The fit** runs as soon as the sheet opens, and again when a box or the readings change. While it runs, the sheet says "Fitting…" with a spinner. The fit runs off the main thread and the engine's, so the panel keeps scrolling.
- **The result:** each value's change ("Growth per month 3% → 1.191%"), and the typical miss with the new values and with the old ones ("Misses the next reading by 0.5%, was 1.9%."). The graph shows the refitted line dashed, a screen to each side of the view, and asks again when scrolling goes further.
- **Apply** (⌘↩) makes the new values the slot's own, rounded to six significant figures, as one change that undo takes back. The footer says what changed: "Refitted Debt: Growth per month 3% → 1.191%". **Cancel** (Esc) leaves everything as it was.
- **No better fit:** when the fit can't improve on the current values, the sheet says "These values already fit best", and Apply is off.
- **Mistakes** show in red in place of the result, such as "Fitting needs at least 2 readings that follow an earlier one. Debt has 1."
- **Closing:** Cancel, focusing another slot, or switching to the Event or Formula tab closes the sheet and drops the fit and its dashed line. A fit still running is stopped.

**Command bar:** `refit` opens Refit for the focused slot, and `refit debt` for a slot by name or number. `predict` opens Predict with for the focused slot, and `predict data` for another. `predict data with trend line` opens it with that model selected, and `predict data with best` selects the best once the scores are in; ↩ then chooses it. Planned: sent from outside the app (`etf://`, the CLI), these will ask for confirmation, as other edits do.

## 6. Menu bar item

- **Values:** the current scenario's values now and at a pinned date.
- **Actions:** Show panel, Copy snapshot, Add event at now.
- **Scenarios** (DESIGN.md, 15):
  - **Open Scenario…** picks a scenario's `.etf` folder, or the `scenario.md` in it. The one open now is saved and closed first.
  - **Edit scenario.md** opens the file in the Mac's editor for Markdown, or TextEdit when there isn't one. Changes saved there show in the panel within a couple of seconds.
  - **Show Scenario in Finder** and **Open Scenarios Folder**.
  - A scenario that can't be opened says why, with Try Again, Edit scenario.md and Cancel (Quit when nothing else is open).
- **Scripts:** Open Script Libraries Folder (made if it isn't there) and Reload Script Libraries, which loads every script again with the folder's current files.
- **Feeds:** Refresh Data Feeds checks every feed in the scenario for new readings now (5.10).
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
  - Axis labels and the events strip are drawn in a `Canvas` too, which keeps the number of SwiftUI views small. So a click on the strip is matched to a diamond by its position (`EventsStrip.editableEvent`). The pointing hand comes from clear views over the diamonds with SwiftUI's link pointer style (`DiamondHotspots`). Setting `NSCursor` from a hover handler flickered between the hand and the arrow, because SwiftUI's hosting view sets the pointer itself on every mouse move.
  - **Huge numbers:** the timeline goes on forever, so compounding values eventually outgrow every number. From 10¹⁵ up, values show in scientific notation ("$1.14e28"). Values that overflow show as "∞", and the line breaks where they start. Ranges and tick steps are clamped to ±10³⁰⁰ so they stay finite. (Converting a label past Int.max to a whole number crashed the app.)
- **State and redrawing:**
  - One `@Observable` store per scenario. Views read only what they draw, so SwiftUI redraws only what changed.
    - `timelineState()`: the plots, axes and events. It doesn't read the cursor.
    - `cursorState()`: the readout, each lane's value, and the cursor line and dot, drawn as small shape views on top.
    - `statusText()`: the footer.
    - The add-event pane reads the draft, and only its effect box reads the cursor.
  - Never assign an `@Observable` property its current value. Even setting `nil` to `nil` redraws every view that reads it.
  - The store never computes. It asks `ScenarioEngine` (an actor on its own thread) for the visible range and draws the latest results it has. Past the end of those results, lines stop and readouts show "…" until the rest arrives (DESIGN.md, 4.8).
- **Slots** (5.7):
  - The store keeps each slot as a plain record: its position, name, model source, its own values, display settings, events and rules. Every change to slots replaces the whole list, so undo puts the old list back.
  - Before anything reaches the engine, the store compiles each model and checks how the slots read each other (`Wiring.check`, DESIGN.md 5.9). Slots that can't run are paused, not dropped.
  - The engine gets the whole layout. When only models or values changed, it swaps just those models, and only those slots and the slots that read them are recomputed. Adding, removing, moving or renaming rebuilds the scenario.
  - The latest results follow their slots when the list changes, so lines stay on screen until the engine has new ones.
  - **Models:** a slot's model is any `AuthoredModel`, a `FormulaModel` or a `ScriptModel`; `SlotConfig.makeModel` builds the right one from its kind.
  - **Errors while computing:** errors a slot raises come back with each fetch as a `SlotFailure`, and the store keeps them by slot (`slotFailures`). A preview's error comes back with the preview, and the Formula tab adds it to the draft's check.
  - The formula editor is an `NSTextView` (TextKit 1) with an `NSRulerView` for line numbers. `FormulaHighlighter` colours the whole text after each change, or `ScriptHighlighter` for scripts. Formulas and scripts are short enough that this costs nothing noticeable.
  - The completion list is the app's own SwiftUI overlay, driven by the text view's keys. AppKit's built-in completion puts the selected word in when you type on, and opens on Esc, which isn't what a formula wants.
  - Sliders don't use SwiftUI's `step`: on the Mac it draws a tick mark per step, and a range of 10,000 steps took 16 seconds to draw. The value is snapped to the step instead.
- **Feeds** (5.10, DESIGN.md 15.8):
  - The store keeps each slot's readings by source (`SlotReadings.parts`), so a feed's new readings replace only its own. They reach the engine as a readings change (`ScenarioEngine.Mutation.readings`), not a layout, and aren't an edit.
  - `FeedCenter` belongs to the `ScenarioDocument`. It keeps each feed's state in `store.feedStatuses`, by slot and what the feed fetches (`FeedKey`), which the Slot tab reads.
  - The focused graph's readings are turned into samples once per readings set and variable (`readingSamples`), not every frame.
  - The setup screen's sign-in section avoids a segmented control: with four kinds it was wider than the pane and pushed the popover's columns off its edges.
- **Refit** (5.11, DESIGN.md 8.4):
  - `Refitting.swift` keeps the sheet's state (`ScenarioStore.refit`, a `RefitState`) and which slots can be refitted (`refittable`, kept up to date as slots and readings change). `RefitSheet` draws it.
  - A fit asks the engine for a copy of the slot through the engine's queue (`copyForFitting`), so the copy follows every edit before it. It then runs `SlotCopy.fit` in a detached task, with a `CancelFlag` it checks before each try. Answers from a fit that was stopped or replaced are ignored (`refitSequence`).
  - The dashed line is a slot preview, as for sliders and formulas (`parameterPreview`), with the fitted values as the slot's own.
  - `timelineState()` reads `parameterPreview` every time. It used to read it only when `previewSlot` (not observed) named the focused slot, so a preview that arrived later, like Refit's, didn't redraw the graph until something else did.
- **Predict with** (5.11, DESIGN.md 8.4):
  - `Predicting.swift` keeps the menu's state (`ScenarioStore.predict`, a `PredictState`) and the held-back line (`heldBack`, observed on its own so scores filling in don't redraw the graph). `PredictMenu` draws it. `ForecastModels.swift` writes the Forecast models around a value and makes their first guesses.
  - Opening works out the menu's models on the main thread (parsing a few formulas). Scoring asks the engine for a copy of the slot, as Refit does, then scores one model at a time in a detached task with `SlotCopy.replacingModel` and `score`. Answers from work that was stopped or replaced are ignored (`predictSequence`).
  - Scores are kept by model, values, readings, start and readings chosen (`predictScores`), and why a slot's models can't be compared, the same way (`predictProblems`).
  - The ranking is `PredictState.best(of:)`, so it can be tested without scoring anything.
  - `etf-bench predict readings.csv [start …] [step day|week|month|year] [since …]` scores the Forecast models on a feed's saved readings, as the menu does, and times each.
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
