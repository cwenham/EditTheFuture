# Handoff

Where the work stands, for the next Claude session. Last updated 2026-10-25, in the commit that added model selection and slot settings (the one after `67f76f5`).

Read this first, then [DESIGN.md](DESIGN.md) (engine and architecture) and [UI.md](UI.md) (the UI spec, with implementation notes in section 12). The UI mockups are on a design canvas linked at the top of UI.md.

## The project

Edit The Future is a Swift app, Mac first, then iPad and iPhone. It shows an infinite, editable graph of values over time. Up to 8 linked models (slots) run side by side, like tabs in a spreadsheet. Each model is a calculation, a simulation, or a formula typed into the app, for example:

```
step 1 month
param rate = 4.5%
init balance = 18000
balance[t] = balance[t-1] * (1 + rate / 12) + monthly
on deposit: balance += event.amount
```

On the Mac it lives in a floating, translucent panel summoned with a hot-key. Snapshots copy to the clipboard in several formats at once. It's meant to be "opened up in all reasonable and secure ways": an `etf://` URL scheme, a CLI, a menu bar item, App Intents, Shortcuts, Spotlight, Siri, plug-ins, and hardware controllers (MIDI first).

## History

| Commit | What |
|---|---|
| `44d0bb5` | Design doc and engine scaffold (milestone M0) |
| `1e9d746` | UI spec and mockups |
| `f06316a` | M1 Mac app shell |
| `cb6514b` | Performance: Canvas plots instead of Swift Charts, split drawing state, integer date maths, compiled formulas, slot groups across cores |
| `022704c` | Computing moved to a background actor; crash fixes for huge values |
| `4b7b7de` | Now button, `goto` for values, far-future readout fix |
| after `67f76f5` | Model library and picker, adding, changing, moving and removing slots, the Slot tab, parameter ranges and labels in formulas, paused slots |

Milestones M0 and M1 from DESIGN.md section 16 are done.

## What works

The Mac app, with the built-in "Home & money" scenario. It has five slots: Savings, Index fund, Mortgage, Climate and Energy bill, which reads Climate's temperature.

- **The panel:**
  - Floating `NSPanel`. ⌃⌥Space toggles it, and holding it peeks.
  - ⌃⌥C copies a snapshot, and ⌃⌥E opens the panel ready to add an event.
  - Menu bar item.
  - Moves only by dragging its top bar.
- **The timeline:**
  - A focused graph plus a lane for each other slot.
  - A cursor that follows the pointer, with readouts.
  - Generated events (Heatwave) on the events strip.
- **Scrolling and zooming:**
  - On a two-wheel mouse, the horizontal wheel scrolls and the vertical wheel zooms. The second wheel is detected automatically, and the menu has a toggle to override that.
  - On a one-wheel mouse, the wheel scrolls and Shift + wheel zooms.
  - Trackpads swipe to scroll and pinch to zoom.
  - Scrolling carries the cursor along.
- **Keys:** ← → (⇧ moves a year), T for now, E to add an event at the cursor, 1–8 to focus the slot at that position, ⌘I for the Slot tab, + − to zoom.
- **Header:** slot chips, a Now button, Copy, opacity, and Hide.
- **Slots and models** (UI.md, 5.7):
  - A library of 13 formula models in five categories (`ModelLibrary`). The demo scenario is built from it.
  - Click an empty chip to open the model picker: search, categories, a preview of each model's line, its parameters. Adds with defaults.
  - Right-click a chip: Slot settings, Change model…, Duplicate, Move to slot, Remove…. Chips can also be dragged onto another number.
  - Slots keep their positions; removing one leaves a gap. The last slot can't be removed.
  - Removing a slot others read pauses them, with the reason shown on the graph, the lane and the chip. Undo brings it back.
  - Renaming rewrites references in other slots' formulas.
  - Every slot change can be undone.
  - Command bar: `add savings account`, `add loan to 7`, `remove climate`.
- **Side pane:** docked left or right; drag its title bar to swap sides. Two tabs:
  - **Slot** (⌘I): name, model, parameters with sliders and typed values, starting values, which output the graph shows, format, color, Duplicate and Remove. Dragging a slider shows a dashed preview; letting go applies it.
  - **Event:** adding events, below.
- **Add-event pane (the Event tab):**
  - The date defaults to now, and clicking the graph picks a date.
  - Deposit, withdraw or set a parameter, once or repeating.
  - A live preview of the effect.
- **Command bar (⌘K):**
  - Adding: `+500 monthly from 2027-03`, `set rate 4% from 2027-06`.
  - Moving: `goto 2035`, `goto 100°C`, `goto mortgage $0`, `now`.
  - Slots: `focus savings`, `add savings account`, `add loan to 7`, `remove climate`.
  - Other: `copy`, `copy data`, `undo`, `redo`.
- **Clipboard:** PNG, PDF, a tab-separated table and the app's own JSON, all in one copy.
- **`etf://` links:** `show`, `now`, `toggle`, `select`, `scroll`, `zoom`, `copy`. Commands that edit, sent from outside the app, ask for confirmation.
- **Speed:**
  - The engine runs on its own thread and fetches ahead in the scroll direction.
  - Slot groups run on separate cores.
  - The main thread only draws.

## Not built yet

- **Saving:** nothing persists. Added events are lost when the app quits (DESIGN.md, 15).
- **Scenarios:** there's no scenario menu, only the built-in scenario.
- **Programming models** (the next topic): the formula editor, saving a slot's model to the library ("Your models"), a Blank formula, scripts (Lua, Python) and plug-ins. The picker's Plug-ins category is empty until then.
- **Panel features from UI.md:**
  - Editing or moving existing events (5.4).
  - Drag the future (5.2). The engine's `GoalSeek` exists.
  - Bands, readings and drift alerts (5.6).
  - Mute and solo, and banks ([ and ]).
  - Click to pin the cursor, and ⌥-scroll to zoom the value axis.
  - Glance HUD and settings.
- **M2, the next milestone:**
  - A CoreMIDI adapter and the hardware prototype profile. MIDI decoding and the profile already exist in `FutureCommands/MIDI.swift`.
  - App Intents for Shortcuts, Spotlight and Siri.
  - A CLI over XPC.
- **Later milestones:** iPhone and iPad apps, widgets, plug-in hosts (WebAssembly, remote, ExtensionKit), FMU import, ensembles.

## Loose ends

- `README.md` still describes only the engine package.
- `goto` with a value, and adding, removing and changing slots, exist only in the panel and command bar. They aren't in the `Command` vocabulary, `etf://` links or the CLI, although UI.md principle 3 says every command should be reachable everywhere.
- Not checked by hand in the app: dragging chips onto another number, and the chip context menus. Computer use can't find the app, so they were checked only in tests and offscreen renders. The picker popover was checked in an on-screen non-activating panel in a throwaway test.
- A slider can't be cancelled with Esc while it's being dragged: the slider's tracking loop holds the keyboard until the mouse is let go. Undo covers it.
- The picker's preview only works for models that don't read other slots.
- `etf://show?at=` accepts only four-digit years, so links can't reach past 9999, although scrolling can.
- On the time axis, the leftmost year label is half clipped, and the cursor's date flag hides the label under it.
- The engine keeps every step from the scenario's start. Memory grows with distance: about 100 MB at the year 31,000, engine only.
- Each fetch filters all of a slot's generated events from the start. That's fine at today's sizes.
- DESIGN.md 4.8 lists engine work not done yet: pipelining inside a slot group, and remote and WebAssembly models off the main actor.

## How the code fits together

| Module | Key parts |
|---|---|
| `FutureEngine` | `Wiring.check` decides which slots can run before a scenario is built. `Scenario`, the coordinator. It evaluates lazily, keeps checkpoints every 32 steps, invalidates downstream, and checks connections for same-step loops (`[t-1]` lags allow feedback). It resamples between step rates, routes events, and runs independent slot groups concurrently in `ensureAll`. Also `SlotRunner` (flat history arrays), `TimeGrid` and `CivilDate` (fast UTC Gregorian maths), and `GoalSeek`. |
| `FutureFormula` | The formula language (DESIGN.md 6.2): lexer, parser (with `range`, `by`, `label` and `as` options), analyzer, resolution to array positions (`Executable`), evaluator, and `FormulaModel`, which takes a slot's own values and reports its constant defaults. |
| `FutureCommands` | The `Command` vocabulary, `etf://` parsing, the confirmation policy, MIDI decoding, the controller profile and feedback. |
| `FutureUI` | `ScenarioStore` (main actor, `@Observable`) holds the frame, cursor, focus, add-event draft, undo and the command bar, and draws only from the engine's cached results (`computed`). `ScenarioEngine` (an actor on its own serial queue) owns the `Scenario` and runs edits, fetches, previews and `goto` searches in order. Fetches compute four years at a time and stop when a newer fetch is waiting. Also `PanelState` (the value types views draw), Canvas views, `CommandBarParser`, `Formatting` (`ValueFormat`, `niceTicks`, `DateText`) and the snapshot exporter. Slots: `SlotConfig` (the store's record of each slot, replaced whole for undo), `SlotEditing` (the store's slot changes), `ModelLibrary`, and the views `SidePane`, `SlotPane` and `ModelPicker`. |
| `EditTheFutureMac` | `AppDelegate` (status item and hot-keys), `FloatingPanel`, `PanelController` (hosting, keys, scroll mapping, copy), `CommandRouter` (runs `Command`s, asks for confirmation), `HotKeyCenter` (Carbon hot-keys). |
| `etf-bench` | Benchmarks that render the real panel. |

## Checking your work

- **Tests:** `swift test` runs about 130 tests in about 12 seconds.
  - Store tests must `await store.waitUntilIdle()` before reading results.
  - `PanelViewTests` mounts the real panel in a window. Its `.runaway` scenario makes values huge, infinite and NaN within a few years.
- **Benchmarks:** `swift run -c release etf-bench [section]`:
  - Sections: `engine`, `state`, `frames`, `flick [frames]`, `far [year]`, `loop`, `engine-loop`, `cursor-loop [scroll|preview]`.
  - They report main-thread CPU time, which matters more than wall time.
  - Results are noisy when other apps keep the Mac busy, so check `uptime` first.
  - For a fair before-and-after, build the previous commit in a scratch folder: `git archive HEAD | tar -x -C <dir>`.
- **The app:** `scripts/build-app.sh`, then `open .build/EditTheFuture.app`. It's a menu bar app with no Dock icon. To restart it: `pkill -f "EditTheFuture.app/Contents/MacOS/EditTheFuture"`.
- **Seeing the app.** The computer-use screenshot tool couldn't see the panel, and typing keys through `osascript` wasn't allowed. What worked:
  - Show the panel with a link: `open "etf://show?timeline=savings&at=2060-01"`.
  - Capture the window by ID. Get the ID with a few lines of Swift calling `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)`, filtered on the owner name "Edit The Future". Then run `screencapture -x -o -l <id> out.png`.
  - For states a link can't reach, such as after a command-bar command, render the real panel offscreen in a throwaway test:
    - Put an `NSHostingView(rootView: PanelView(...))` in a 1400×820 `NSWindow`.
    - Run the command and `await store.waitUntilIdle()`.
    - Lay out, display and run the run loop a few times.
    - Write a PNG with `cacheDisplay(in:to:)`.
- **Crash reports:** `~/Library/Logs/DiagnosticReports/EditTheFuture-*.ips`. Everything after the first line is JSON, and the faulting thread's frames are symbolicated.

## Lessons learned

- **Values get extreme.** Compound interest thousands of years out passes Int.max, then overflows to infinity, then can become NaN. Two crashes came from this.
  - Format values with `ValueFormat`, which switches to scientific notation from 10¹⁵.
  - Build axis ranges with `niceTicks` and lane ranges with `ScenarioStore.laneDomain`.
  - Never convert a model value to `Int`, or build a `ClosedRange` from unchecked numbers.
- **Far-future dates lose precision.** Compare `Date`s directly. Nudging one by a microsecond does nothing past about 2150.
- **Redraws:** never assign an `@Observable` property its current value. Even setting `nil` to `nil` redraws every view that reads it.
- **Separate state on purpose:** `timelineState()`, `cursorState()` and `statusText()` are separate so SwiftUI redraws only what changed.
- **Shadowing:** in `let a = f(x), b = g(a)` the second initializer sees the new `a`. This caused one bug, and nearly a second.
- **Windows in tests:** set `isReleasedWhenClosed = false`, or AppKit frees the window twice.
- **Frame benchmarks:**
  - SwiftUI only applies changes when the run loop runs, so each frame runs it and calls `CATransaction.flush()`.
  - Wrap each frame in `autoreleasepool`, or memory piles up. That's an artifact of the benchmark loop; the app's event loop empties the pool itself.
- **Swift Charts** was dropped for Canvas: it spent 40–100 ms a frame on a few thousand marks (UI.md, 12).
- **SwiftUI sliders with `step`** draw a tick mark per step on the Mac. A 10,000-step range took 16 seconds of main-thread time. Snap the value yourself instead (`SlotValue.snapped`).
- **Popovers from the panel:** a SwiftUI `.popover` works from the non-activating `NSPanel`. To check one in a test, put the view in an on-screen `NSPanel` (`orderFrontRegardless`) and look for an `_NSPopoverWindow` in `NSApp.windows`; offscreen windows don't show popovers.
- **Removing slots shifts indices.** Undo records refer to slots by their `id`, not their index, and results are remapped by `id` when the list changes.
  - Views must keep a slot's `id` (or the `SlotInfo` itself), never its index, and look the index up when they draw or act (`store.slotIndex(id:)`). After a removal, SwiftUI can draw a child view once more with the inputs its parent gave it last time, before the parent catches up. A chip that kept an index read past the end of `store.slots` and crashed the app when the last slot was removed.
  - The store's slot functions ignore an index with no slot, as a second line of defense.

## Working with the user

- Asks for commits explicitly ("Commit … with a sensible message"). Commit only then.
  - Commits go straight to `main`; there's no remote.
  - Messages have a plain-language subject, then a body saying what changed and why, with measurements where there are any. They end with the `Co-Authored-By` line.
- Docs are kept in step with the code, written plainly in short sentences.
- Tests the app by hand, thoroughly, and reports crashes. Expect fully zoomed-out views and fast scrolling thousands of years ahead.
- Uses a mouse with two scroll wheels.
- Environment:
  - 2017 iMac Pro: Intel Xeon W-2140B, 8 cores and 16 threads.
  - macOS 15.7.9, Xcode 26.3, Swift 6.2.4.
  - The package uses Swift 6 language mode and targets macOS 14 and iOS 17.
