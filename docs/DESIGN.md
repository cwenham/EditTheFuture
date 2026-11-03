# Edit The Future: design

Draft 1, 2026-10-24. This document records the design agreed so far. Section 19 maps it to the code in this repository.

## 1. Vision

Edit The Future is a macOS, iPadOS and iOS app built around an infinite graph of values changing over time. You scroll to any point in the past or future and insert or delete events that change the graph. Behind each graph is either:

- a simple calculation of change over time, like a savings account with an interest rate and scheduled deposits, or
- a simulation model corrected by real-world readings: an investment driven by a market model, a climate model, population growth of people, bacteria or yeast, material fatigue, and so on.

Up to 8 models run side by side and can feed each other values and events, the way spreadsheet tabs reference each other. The app is meant to be consulted constantly while you work in other programs. It appears and disappears instantly with a hot-key, a hardware controller, or a call from another program, and copying a snapshot of the graph or its data takes a single keystroke.

## 2. Platforms and targets

| Platform | Deployment target | Notes |
|---|---|---|
| macOS | 15 (Sequoia), universal binary | Must run on Intel. The primary development machine is an iMac Pro (Intel Xeon), which cannot run macOS 26. |
| iPadOS / iOS | 26 | iPhone 17 class devices; Apple Intelligence available. |
| Engine package | macOS 14, iOS 17 | Pure Swift, no UI dependencies. |

Consequences:

- The Mac app must not depend on macOS 26-only APIs (Foundation Models, Liquid Glass). Use them only behind availability checks.
- macOS 26 is the last macOS release that supports Intel Macs. Plan for Apple silicon-only features to arrive on Mac over time, and use capability borrowing (section 7) to bridge the gap.

### 2.1 Packages and embedding

Begun in November 2026. The engine and the graph are meant to be used by other apps that link the package, not only by Edit The Future. The package's libraries are layered so an app takes only what it needs:

| Library | What it is | Draws? |
|---|---|---|
| `FutureEngine`, `FutureFormula`, `FutureScript`, `FutureSimulation` | The engine, the formula language, scripts and simulation modules. | No |
| `FutureVisuals` | What backdrops show (9.6): `BackdropKind`, `BackdropInput`, the world's countries, the bright stars, and `RGBA`, a colour as plain numbers. | No |
| `FutureKit` | A scenario to run, edit and read: `ScenarioStore`, with `ScenarioEngine` computing off the main thread (4.8), undo, editing slots, events and formulas, Predict, Refit, Drag the future and drift alerts, and the value types views draw (`TimelineState`, `CursorState`). It imports no SwiftUI, AppKit or UIKit. | No |
| `FutureFiles` | Scenarios kept as `.etf` folders (15): `ScenarioDocument`, the Scenarios folder (`ScenarioLibrary`), and keeping feeds and exchange rates up to date (`FeedCenter`, `RateCenter`). Optional. | No |
| `FutureUI` | The views: the graph, the side pane and its tabs, the model picker, the formula editor, the whole panel (`PanelView`), and the backdrops' drawings. | Yes |

**A scenario without files.** `ScenarioStore(definition:configuration:)` runs a `ScenarioDefinition` held in memory. An app that keeps scenarios its own way saves by turning `scenarioFile()` into text with `ScenarioFormat.text(for:)`, whenever `onScenarioChange` fires, and never needs `FutureFiles`.

**What an app can give a scenario:** a `ScenarioConfiguration`, with the simulation modules slots may run (a `ModuleCatalog`, with the data those modules need), the backdrops they may draw (`BackdropCatalog`), the models the picker offers and Predict with tries (`templates`), and where feed sign-ins are kept and how feeds are fetched. `.standard` is the app's. Everything that builds a model, offers a template or picks a backdrop reads the store's configuration, not a global: `SlotConfig.model` and `ScenarioStore.assemble` take the module catalog, and `ScenarioDocument.open` passes its configuration on.

**What's public.** Inside the package, the views and the app reach the store through `package` access; only what an app that embeds the package needs is `public`. The store's panel plumbing (the pointer, the panel's opacity, focus requests) is `package`. The rest of the public surface is still wider than an embedding app needs, and will be trimmed as the views an app can place on their own are made public.

**The views an app can place** (`FutureUI`), each filling the frame it's given:

| View | What it is |
|---|---|
| `ScenarioGraph(store:parts:interactive:wheel:drawsBackground:)` | The focused graph with its time axis, and optionally its title, the events strip and the lanes (`Parts`). The cursor follows the pointer. Interactive, clicks pick dates and events, set targets and select slots; read-only, they don't. |
| `ScenarioEditor(store:)` | The side pane's tabs (Event, Slot, Formula) and what they show, with Drag the future's card while a target is set. |
| `EventEditor`, `SlotEditor`, `FormulaEditorPane` (Mac) | One tab each, with its own popovers and sheets. Each has a `minimumWidth`. |
| `PanelView(store:actions:wheel:)` | The whole panel, as the app shows it. |

**Moving through time.** A graph takes the wheel, the trackpad and pinches over itself, wherever it's placed: a view behind it watches the window's events and takes those inside its bounds (SwiftUI has no wheel events on macOS 14), and never takes clicks. Elsewhere the wheel scrolls what's under the pointer, as before. `TimelineWheel` holds whether the mouse has a horizontal wheel; graphs given the same one agree, and the app's remembers it in its defaults and lets the menu change it. `TimelineKeys.handle(_:store:)` answers the graph's keys (docs/UI.md, 4.1) for an app to call from its own key handling, as the panel does for keys no text field took.

**Settings the views keep.** The panel remembers its side pane's side and widths under names of its own (`PanelView.sideKey` and the like, `EditTheFuture.panel.…`), so an app embedding it keeps them apart from its own. The Mac app moves the old, plain names across when it starts.

**How the views look.** A `FutureStyle` sets the views' colours, fonts and appearance, through the environment: `.futureStyle(style)` on the views or anything around them. `.standard` is the panel's look (UI.md, section 2) and the default; `.light` is the same views on a light background. An app starts from either and changes what it wants:

| Part | What it sets |
|---|---|
| `colors` | The panel colour behind everything (`.clear` lets what's behind show), text and secondary text, `ink` (white on dark, black on light: faint fills, borders and selections are it at a low opacity), the text on filled buttons, hairlines, the graph's grid, tints and lines, proposals, warnings, errors, successes and readings, and the formula editor's colours (`code`). Slots keep their own colours, which come from the scenario. |
| `fonts` | A `scale` for every size, a `family` in place of the system font (code stays monospaced), or the system font's `design`. |
| `colorScheme` | Light or dark, for the controls inside: buttons, menus, text fields. |
| `panePadding`, `cornerRadius` | Inside the editing panes. |

How the views follow it:

- `Theme.text` and the other colours are `ThemeColor`s: a `ShapeStyle` that looks its colour up in the style where it's drawn, so `.foregroundStyle(Theme.secondary)` needs nothing else. Canvases draw them with `.style(_:)`. Code that needs a plain `Color`, such as the values a plot is built from, reads the style from the environment and asks it: `style[Theme.proposal]`.
- Fixed sizes go through `.futureFont(size, weight:design:)`, which reads the style's fonts. Text drawn in a canvas uses `context.environment.futureStyle.fonts`. The events strip's labels keep the system font at 11 points, because they're measured with CoreText to stop them overlapping.
- The formula editor's `NSTextView` gets its colours and font size from the style when SwiftUI updates it (`FormulaColors`), and colours its text again when they change.
- Views never use fixed colours such as `Color.white`; the clipboard image is always drawn in the standard style.
- The graph's columns (the label and value columns, lane heights) don't grow with the font scale, so a large scale can cut labels short.

**Still to do:** an example app built only on the public API, and trimming the rest of the public surface. On iOS, the graph has no touch gestures for moving through time yet.

## 3. Glossary

| Term | Meaning | FMI / SSP equivalent |
|---|---|---|
| Scenario | A set of model slots sharing one start date, plus their events and connections. Coordinates evaluation. | Importer (FMI 3.0's name for the co-simulation host) |
| Slot | One model instance in a scenario, with a name like `Climate`. The UI shows 8 slots per bank. | FMU instance / SSP component |
| Model | Code that turns state plus inputs into the next state. Built-in Swift, formula, WebAssembly, native binary or remote. | FMU |
| Variable | A named value a model exposes or needs. Has a causality: parameter, input, output, or local. | Variable with causality |
| Connection | Wires one slot's output to another slot's input, with a resampling rule and a timing. | SSP connection |
| Event route | Delivers events generated by one slot to another. | (Clocks / events) |
| Communication point | A step boundary on a model's time grid: start + i × step rate. | Communication point *tᵢ* |
| Step | Advancing a model from one communication point to the next. | `fmi3DoStep` |
| Authored event | An event a person added: a deposit, a rate change, a shock. | |
| Recurring event | A rule that produces authored events on a schedule. | |
| Generated event | An event a model emitted, like `OverCapacity`. | |
| Reading | A real-world observation used to correct a model's state. | |
| Miss | How far a reading is from what its step worked out before the reading replaced it (8.4). | |
| Fit | Choosing parameter values that make a slot's misses small (8.4). | |
| Checkpoint | A saved model state that recomputation can restart from. | `fmi3GetFMUState` |
| Branch | An alternative future for the whole scenario. | |
| Bank | A page of 8 slots, shown together in the UI and on the hardware. | (DAW control-surface bank) |

## 4. Engine

### 4.1 Lazy, demand-driven evaluation

Nothing is computed until something asks for it. When the graph needs values up to some date, the engine advances each slot only that far. Scrolling further asks for more. Every query is "make sure slot S is computed through date D, then read it."

### 4.2 Time grids

Each model declares a step rate: seconds, minutes, hours, days, weeks, months, quarters or years. Rates are calendar-aware, so monthly steps land on the same day of each month. Steps use a UTC Gregorian calendar, so daylight-saving changes never move a boundary. Point *i* is computed as start + *i* × rate directly from the start date, never by repeated addition, so month-end dates don't drift. A Jan 31 start gives Feb 28/29, then Mar 31, and so on.

Step windows are half-open: the step that ends at point *i* covers the time after point *i−1*, up to and including point *i*. The first step also includes the start instant for events. Events and readings are delivered to the step whose window contains them. A reading at the start instant belongs to the start (4.6), not to the first step as well.

### 4.3 Checkpoints and invalidation

Each slot keeps:

- the variable values at every communication point it has computed, and
- a full state snapshot every N steps (default 32), plus the start.

Inserting, moving or deleting something at time T discards that slot's points at or after T, rewinds to the newest checkpoint before T, and recomputes on demand. The invalidation then spreads to every slot downstream through connections and event routes, starting from the same time T (section 5.5). This works the same way as keyframes in video, or rollback in game replays.

### 4.4 Determinism

Recomputation must reproduce exactly the values it replaces, or rewinding would change history. So:

- Each step gets a random generator seeded from (scenario seed, slot, step index). Stochastic results then don't depend on scroll order or how often a range was recomputed.
- Events within a step are processed in a fixed order: time, then kind, then id.
- Generated events get IDs derived from the slot, step and position, so they're identical when regenerated.

### 4.5 Kinds of model

Models declare capabilities so the engine can take shortcuts:

- **Closed-form**: can jump straight to any date (compound interest). Future optimization: skip stepping when a model has no inputs.
- **Stepped**: has to walk forward (most simulations).
- **Stochastic**: uses randomness. Candidates for ensembles (4.6).
- **Assimilating**: corrects its state from readings.

### 4.6 Past, present and future

- **Past**: real readings, used to correct the model's state up to "now" (data assimilation, for example a Kalman filter or simple nudging). Before the first reading, a model can run backwards when its maths allows it (hindcast). Otherwise the graph starts at the scenario start.
  - **Before the start** (October 2026): every model's line begins at the scenario's start, but the graph reaches back to the earliest reading of a value a slot's graph shows, and draws the readings there (UI.md 2.4, 5.1). The engine computes nothing before the start, so that part of the graph is readings only. Hindcast is still to do: it would work for models whose steps can be undone, such as compound interest, but not for ones with `max`, events or randomness.
  - **Built so far** (October 2026): the simplest assimilation, direct insertion, for formulas and scripts alike. A reading of a parameter sets it at the start of its step, as a `set` event would. A reading of a value replaces what the step worked out, so the next step carries on from what was observed. When a step has several readings of one name, the latest wins. The start takes the latest reading of each name at or before it, so a scenario that starts after its readings begin starts from them. Until October 2026 a reading at the start instant was applied again at the first step, so the first step repeated it; it now belongs only to the start, and `Scenario.engineVersion` is 3.
  - Values worked out from a replaced value in the same step (a definition without `[t-1]` that reads it) see the reading from the next step on.
  - Nudging and Kalman filters are still to do. Refitting parameters to readings is built in the engine, and choosing which model makes the projection is designed (8.4).
- **Now**: a vertical line. To its left the graph is anchored by observations, to its right it's a projection.
- **Future**: for stochastic models, run an ensemble of seeded runs and draw a fan of percentile bands (for example 10–90% and 25–75%) around the median. Compute the median first and refine the bands progressively as the user pauses.

### 4.7 Drawing large ranges

Always simulate at the model's own step. To draw, downsample to the screen: keep the min and max per pixel column, the way audio editors draw waveforms. This is implemented in `PlotCanvas`. Not done yet: caching downsampled tiles per zoom level, the way map tiles work, so zooming out to centuries never even reads millions of points.

### 4.8 Performance and concurrency

**Engine speed.** About 4 µs per formula step on the 2017 iMac Pro, down from 14 µs. The changes:

- **`CivilDate`:** step grids and formula built-ins use integer date arithmetic in UTC instead of `Calendar`. `Calendar` cost several microseconds per call and was 45% of step time. It's still used for non-UTC calendars, and tests check the two agree.
- **Fewer built-ins:** formulas compute only the built-ins they reference.
- **Compiled formulas:** names are resolved to array positions at compile time (`Executable`), so evaluating a step hashes no strings and allocates no dictionaries.
- **Flat history:** slot history is one array of numbers with a column per readable variable, instead of a dictionary per step.
- **Event delivery:** generated events are found by binary search, and slot bookkeeping isn't copied each step.
- **RK4 buffers:** differential equations reuse their stage buffers for the whole step instead of making new arrays at every stage, about a third faster. They still cost 32 evaluations of each derivative a step, so a model with a short step and several equations is better written as difference equations, or as a Swift module (6.5).

**Across cores.** Slots split into groups joined by connections or event routes. Groups never read each other, so `Scenario.ensureAll(through:)` computes them concurrently with `DispatchQueue.concurrentPerform`. Each slot is its own object, so a group only writes to its own slots. Eight independent slots compute about 4× faster on the 8-core Xeon. The engine calls `ensureAll` for every fetch, so zooming out, or edits that recompute a lot, use every core.

**Off the main thread.** The main thread never computes. `ScenarioEngine`, an actor running on a serial dispatch queue of its own, owns the `Scenario`. The store keeps the engine's latest results and draws only from those.

- **What crosses over:** plain values. The store sends edits (add or remove an event or rule), slot layouts, fetches (a date range plus the date to read parameters at) and previews (the draft change, which the engine adds, reads and removes again; while an event is being edited, the old event is taken out for the preview and put back after). It gets back each slot's samples, generated events and parameter values.
- **Slot layouts:** when slots are added, removed, moved, renamed or given new values, the store sends every slot with its model, values, events and rules, and a gap for each paused slot (5.9). If the same slots run under the same names, the engine swaps only the models that changed (`Scenario.replaceModel`), which recomputes those slots and the ones downstream and leaves the rest. Otherwise it rebuilds the scenario.
- **Slider previews:** while a parameter's slider is dragged, the engine swaps in the model with the dragged value, reads the slot's line and swaps the old model back.
- **Order:** the store sends work one operation at a time, in order, so a fetch always sees every edit made before it. Edits are never dropped. A new fetch or preview replaces one still waiting, since only the newest matters.
- **Stale results:** every edit increases the store's revision. Results carry the revision and fetch number they were asked for, and older ones are ignored.
- **Superseded fetches:** a fetch computes four years at a time. Between chunks it checks a lock-protected counter, the newest fetch number. When a newer fetch exists, it stops and returns what it has, so a long jump doesn't hold up the next request.
- **Prefetching:** a fetch covers the visible range plus 1.5 screen widths in the scroll direction and half a width behind. The store asks again only when the view comes within a tenth of a width of the edge of what it has.
- **While waiting:** lines end where the results end. Readouts past that point show "…" and "Computing", and the add-event pane shows "Working out the effect…". On launch the footer shows "Computing…" until the first results arrive, about 7 ms later.
- **Measured** (`etf-bench`, iMac Pro): the engine catches up 7–21 ms after creating the store, zooming out to 80 years, jumping to 2200 or making an edit near the start. In frame tests it keeps up with continuous scrolling and zooming, and is idle when each burst ends.
- **Tests** call `await store.waitUntilIdle()` before reading results.

**Not done yet:**

- **Pipelining inside a group:** an upstream slot works ahead while downstream slots catch up.
- **Remote and WebAssembly models** run off the main actor, with the coordinator batching steps to them (5.6).

### 4.9 Several outputs per slot

Added in November 2026. A model can work out any number of values each step, and all of them are kept:

- **Declaring them:** in a formula, every value it defines (`rabbits[t] = …`, `dfoxes/dt = …`); in a script, each `init` and `output`; in a module (6.5), its `state` and `outputs`. Foxes and rabbits, or the infectious, recovered and vaccinated, are outputs of one slot.
- **In the engine:** a slot's history has a column for each parameter and output (4.3), so every output can be read at any point: `Scenario.value` and `Scenario.series` by name, other slots' formulas (`Rabbits.foxes`), readings and Refit.
- **From outside:** the `etf` tool (`etf value foxes rabbits`, `etf data foxes rabbits`) and Shortcuts read any output by name, straight from the engine.
- **In the panel's results:** each fetch brings the value a slot's graph draws, plus the outputs asked for with `ScenarioStore.want(outputs:ofSlot:)`, by slot id. `outputSeries(_:ofSlotAt:)` and `outputValue(_:ofSlotAt:at:)` read them from the latest results, which keep them with their slot when slots move. Only what's asked for is fetched, since every output of every slot would multiply each fetch's work. Names a model hasn't got are left out. Nothing in the panel asks for any yet: graphs of several outputs, and backdrops (6.5), will. For values per key that are too many to fetch for every step, see fields (4.10).

### 4.10 Fields: values per key, at any point

Added in November 2026. Some models have values for each of many things: each country's share infected, each star's brightness. Storing them for every step would cost too much (200 countries a day for a century is about 58 MB), so they're fields: a model works one out from its state when asked.

- **Declaring them:** `ModelDescriptor.fields` lists `FieldDescriptor`s: a name, a label, the keys in order, a quantity, a `geometry` saying what the keys are, so a visual knows how to draw them (`world/countries` for ISO 3166 alpha-3 codes, `groups` for named parts of a whole), and a `scale` saying how to shade them: `share` (0 to 1 as they are), `relative` (against the largest at the time) or `logarithmic(faintest:full:)` for values spanning many powers of ten. Without one, percents are shares and anything else is relative. `TimelineModel.field(_:of:)` works one out from a state: one value for each key. Models without fields return nil, which is the default. Modules declare them in their shape and implement `NumericSimulation.field(_:of:)` (6.5); formulas and scripts have none yet.
- **Working one out:** `Scenario.field(_:of:at:)` gives the field at the slot's last point at or before a date, computing as needed. At the last computed point it uses the current state. Elsewhere it copies the newest checkpoint at or before the point and steps it forward, at most a checkpoint's interval (32 steps), with the same contexts the steps had: the same events, readings, inputs from other slots and random seeds. Models are deterministic (4.4), so it's the state the run had there. Computing a step and working out a field build their contexts with the same function (`stepContext(for:index:)`), so they can't drift apart. A field with the wrong number of values is the model's error.
- **In the panel:** `ScenarioStore.watch(fields:ofSlot:)` names the fields to work out at the cursor, by slot id. The store asks the engine for them whenever the cursor moves or new results arrive (which covers edits), and a request still waiting is replaced by the newer one, so a sweeping cursor never queues up work. The engine keeps the fields it worked out by slot, name and point until the next edit, so a cursor resting within one step costs nothing. `fieldsAtCursor` holds the results, and `field(_:ofSlotAt:)` reads one; only views that draw fields read them, so nothing else redraws. Nothing in the panel watches one yet: backdrops (6.5) will.
- **Epidemic** has one: `groups`, where everyone is, the share of the population in each group (susceptible, exposed, infectious, recovered, vaccinated), which adds up to 1.

### 4.11 Settled models

Added in November 2026, for models with short steps on an endless timeline. A worm that's stepped every minute would otherwise take 525,600 steps a year, for ever, after it has stopped changing.

- **Saying so:** a model whose descriptor has the `settles` capability is asked after each step whether it has settled (`TimelineModel.isSettled`): whether a step with no events, readings or inputs would change nothing, emit nothing and leave every value as it is. Models without the capability are never asked, so ordinary models pay nothing (the engine benchmarks were checked against the previous commit). Modules say it in their shape (`SimulationShape.settles`, `NumericSimulation.isSettled`); the Internet worm does.
- **Skipping:** when a settled slot is about to compute its next step, the engine finds the next step with one of the slot's own events, repeating events' occurrences or readings in it, and holds the slot's last point until just before it, or for ever when there's none. Held points aren't stored: a value at one is the last stored value, a field at one is worked out from the state the slot settled in, and `series` gives each held stretch as its first and last points, which draws the same flat line. Only slots that don't read other slots, receive their events or have inputs can skip, since anything else could change what a step gets. Slots that read a held slot see its held values.
- **Edits:** an event added inside a held stretch shortens it, and the slot carries on from where it settled, so adding an event decades ahead costs one step and what follows. The runner keeps a checkpoint where it settled for this.
- **Storage:** a slot's points are kept densely, row by index, until something is held; only then does the runner keep each stored point's index (`SlotRunner.sparse`). Held results aren't saved to the cache (15.5), since a settled slot is quick to compute again.
- **Seen from outside:** `computedThrough` is `Date.distantFuture` for a slot that holds for ever.

## 5. Multiple models (co-simulation)

### 5.1 The spreadsheet analogy

| Spreadsheet | Edit The Future |
|---|---|
| Tab | Model slot |
| Cell | A variable's value at time *t* |
| `=Weather!B4` | `Climate.temp` |
| Recalculation order | Dependency graph, evaluated at every communication point |
| Circular reference error | Error only for a loop within one step. Loops through `[t-1]` are fine. |
| Trace precedents / dependents | Provenance links on values and generated events |

### 5.2 The coupling rule

Within a single step, data and events must flow one way. Feedback is allowed when it crosses a step boundary: `Building.occupancy` reads the current step, while `Building.occupancy[t-1]` reads the previous one. The scenario rejects same-step loops when it validates, naming the slots in the loop and suggesting `[t-1]`. Loops inside a single formula model follow the same rule.

How a step is scheduled: to compute slot C at point *t*, the coordinator first makes sure that:

- every slot C reads in the same step has been computed through *t*, and
- every slot C reads with `[t-1]` has been computed through C's previous point.

This recursion always terminates when same-step links have no loops, even when lagged links form cycles. A lagged read only needs values before *t*, and those are already final.

### 5.3 Resampling on connections

Models step at different rates, so every connection says how the consumer reads the producer over the consumer's step window:

| Rule | Meaning | When the window holds no producer points |
|---|---|---|
| `hold` (default) | The producer's value at its last point at or before the consumer's point | n/a |
| `mean`, `min`, `max` | Over producer points inside the window | Falls back to `hold` |
| `sum` | Total over producer points inside the window | 0 (flows, like rainfall per month) |

Planned additions: interpolation, which needs the producer computed one point ahead, and weighted time averages.

With `[t-1]`, the same rule is applied to the consumer's previous window. "What this value was one step ago" holds exactly, whatever the two grids look like.

Units: variables can carry a unit. A connection between two units that don't match is rejected. Automatic conversion (°F to °C) is planned, using Foundation's `Measurement` types.

### 5.4 Events between models

- Models emit events during a step, and they're stamped with the step's end point, like observations at a communication point. This keeps delivery deterministic.
- A same-step route delivers events in the consumer's current window. A `[t-1]` route delivers the previous window's events. Every event is delivered exactly once.
- Generated events look different from authored ones in the UI and link back to their cause ("caused by occupancy > 450 in Building").
- You can **pin** a generated event, turning it into a fixed authored event, or **suppress** it ("what if the inspection never happens?"). Planned.

### 5.5 Invalidation across models

Changing slot A at time T invalidates A from T, then every slot that reads A, from T, and so on downstream. Values before T are kept everywhere. A slot that rewinds to an earlier checkpoint recomputes identical values up to T, so slots downstream don't need to rewind that far.

Viewing a slot pulls everything it depends on. Scrolling `FireRisk` to 2040 computes `Building` and `Climate` to 2040, even if their lanes are hidden.

### 5.6 Remote models and batching

With a same-step connection to a remote model, every step needs a network round trip. A `[t-1]` connection, or a coarser exchange interval, lets the coordinator ask a remote or WebAssembly model to "advance 500 steps and return samples" in one call. How often slots exchange values therefore sets the batch size. The UI should warn when a same-step link makes a remote model slow.

### 5.7 Scenarios and branches

A what-if branch covers the whole scenario, because forking `Climate` also forks everything that depends on it. Branches can be shown as ghost lines over the main timeline and compared. Undo history is per scenario.

### 5.8 Banks of 8

The engine has no slot limit. The UI and hardware show 8 slots per bank and page between banks, the same reason DAW control surfaces come in banks of 8. A model that only feeds others can sit in a later bank.

### 5.9 Slots that can't run

Before a scenario is built, `Wiring.check` works out which slots can run. A slot is paused when it reads a slot or value that isn't there, listens for events from a slot that isn't there or never sends them, reads itself by its own slot name, or is in a same-step loop with other slots. Anything that reads a paused slot, at any distance, is paused too, with the reason "Reads from Climate, which is paused".

Paused slots stay in the scenario's list with their events, but the engine doesn't run them. The rest run as usual. This replaces failing the whole scenario, so removing a slot others read from only pauses those readers (UI.md, 5.7).

### 5.10 FMI and SSP

The engine borrows FMI 3.0 and SSP vocabulary (see the glossary) so it can import FMUs (functional mock-up units) later. That would be Mac-only for binary FMUs, because they contain native code. It also keeps the concepts familiar to simulation engineers. The scenario plays the role FMI calls the importer, and the step method is the counterpart of `fmi3DoStep`. Further reading is in section 18.

### 5.11 Currencies and exchange rates

Built in October 2026. The code is `Currency`, `NumberStyle` and `ExchangeRates` in `FutureEngine`, `RateCopy` in `FutureDocument`, the rate sources in `FutureFeeds` (`Rates.swift`), `Money.swift` in `FutureKit`, and `RateCenter` in `FutureFiles`.

**Currencies.** A scenario has a currency (`currency: GBP` in its heading, US dollars when it doesn't say), and a slot can have one of its own (15.2). Formulas and scripts mark money with `as currency`, and it's in the slot's currency. A currency is an ISO 4217 code; about 40 have names, symbols and styles of their own (`Currency.common`), and any other code is written with its code.

**Converting between slots.**
- When a slot reads a value marked as currency from a slot in another currency, the engine converts it as it's read: the value times the rate from one currency to the other at the reading slot's step (`Scenario.computeNext`). It's the one place values cross between slots, so formulas, Lua and Python all convert the same way, and so do Refit and Predict with, whose slot copies carry the currencies and rates (`SlotCopy`).
- Nothing else is converted: a slot's own values, events, readings and parameters keep their numbers when its currency changes. Changing a slot from dollars to pounds turns $18,000 into £18,000. Events sent between slots aren't converted either, since the engine can't tell which of their fields are money.
- `rates: none` turns converting off: money passes between slots as it is.
- The store works out the same conversions for the views (`ScenarioStore.conversions`): the Slot tab says what's converted and at what rate, and the lane says `← Stocks.value ($→£)`.

**Rates.**
- `ExchangeRates` holds, for each currency, how many of it one US dollar buys at each time a source gave. Cross rates go through dollars. A rate holds until the next one; before the first, the first is used, and after the last, the last, so projections use the latest rate.
- The engine computes again only what new rates change: for each conversion, from the first time its two currencies' rates differ (`ExchangeRates.firstDifference`), back to a checkpoint. A new currency for a slot computes again only the slots whose conversion changed.
- A slot that needs rates the scenario doesn't have yet waits, paused with "Waiting for exchange rates from US dollars to British pounds", and so do the slots that read it. It runs once they arrive, rather than showing numbers that look right and aren't.

**Sources** (`rates:` in the heading):
- `ecb`, the default: the European Central Bank's reference rates, published each working day, from 4 January 1999, for about 30 currencies, through Frankfurter (`api.frankfurter.dev`), which is free and needs no key. One request fetches every day for several currencies: about 7,100 days in October 2026.
- `openexchangerates`: the ECB's rates for the past, with the latest from Open Exchange Rates (`openexchangerates.org`) for about 170 currencies. It needs an App ID, saved in the Keychain under `openexchangerates` and sent only to `openexchangerates.org`, over HTTPS, in an `Authorization: Token` header rather than the address. How fresh its rates are depends on the plan (hourly on the free one, every minute on the dearest); the app asks every 10 minutes while the scenario is open, about 4,300 requests a month, which needs a paid plan. A currency the ECB doesn't have (UAE dirhams, say) has only the latest rate, used for every date.
- `none`: no converting.
- `etf-feed --rates GBP,EUR [--since 2026-01-01] [--live]` fetches rates without the app.

**Kept with the scenario.** Rates are readings, so they travel with the scenario (15.1): `readings/exchange-rates.csv` holds the daily rates of the currencies the slots convert, and `readings/exchange-rates-live.csv` the latest live ones, as CSV with a `date` column and one per currency, in units per US dollar. The scenario opens with them, so slots that convert run at once, offline too, and their cached results (15.5) can be used. `RateCenter` then fetches what's due: the daily rates every 6 hours, from two weeks before the latest, and a currency the copy doesn't have from 1999; live rates every 10 minutes. After a failure it waits half an hour, and says why in the footer and the Slot tab. Refresh Data Feeds fetches them now.

**Fingerprints.** A slot that converts counts its conversions and the rates of both currencies in its fingerprint (15.5), so its cache is used only with the same rates. Other slots' fingerprints don't change.

**Number styles.**
- Each currency has the style it's usually written in (`Currency.regional`): separators, its local symbol, and where it goes. `$1,234.56`, `1.234,56 €`, `£1,234.56`, `1 234,56 kr`, `CHF 1’234.56`, `R$ 1.234,56`, `₹12,34,567`, `¥1,235`.
- Each slot is written in its currency's style: money, plain numbers, percents (`4,5 %`) and temperatures, in readouts, axes, lanes, the Slot tab, events and messages.
- Two currencies in a scenario that share a local symbol, such as US and Canadian dollars (`$`) or Swedish and Norwegian kronor (`kr`), use the symbols that tell them apart instead: `$` and `CA$`, `SEK` and `NOK`.
- `numbers:` in the heading chooses one style for every slot: `comma-point` (1,234.56), `point-comma` (1.234,56), `space-comma` (1 234,56), `apostrophe-point` (1’234.56) or `indian` (12,34,567.89). Symbols are then the ones that tell currencies apart, before the number where decimals follow a point and after it where they follow a comma.
- Typed numbers are read in the slot's style: `1.234,5` is 1234.5 where decimals follow a comma. There, a point is between thousands only when thousands follow it (`1.234`, `12.500`), so `1.5` and `0.045` still read as typed. Spaces and apostrophes between thousands are always read.
- Axes keep k, M, B and T for thousands, millions, billions and trillions in every style: `1,25M €`.
- `scenario.md`, the cache and copied tables keep plain numbers, with a point before decimals, so files read the same everywhere.

## 6. Where models come from (plug-ins)

### 6.1 One protocol, many hosts

The model interface is a small set of messages, not a Swift protocol, so the same model can run in any host:

| Message | Purpose |
|---|---|
| `describe` | Name, step rate, variables (with causality and units), events emitted, events subscribed to, capabilities |
| `start` | Create the state at the first communication point, given inputs |
| `doStep` | Advance one step, or a batch of steps, given inputs, events and readings. Returns values and generated events. |
| `getState` / `setState` | Checkpoint and restore (models that can't do this are re-run from the start) |

Hosts:

1. **Built-in Swift models**: simulation modules (6.5), each in a folder of its own, built against a small contract and conforming to `TimelineModel` through it.
2. **Formula models**: typed into the UI (6.2).
3. **Scripts**: Lua and Python, typed into the UI too (6.4).
4. **WebAssembly**: the main cross-platform plug-in format. Run in WasmKit, a WebAssembly runtime written in Swift that ships with the Swift 6.2 toolchain. Sandboxed by default (no file or network access unless granted). Plug-ins can be written in Swift, Rust, C or anything else that compiles to WebAssembly. Interpreted, so slower than native. For heavy plug-ins on iOS, a hidden WKWebView offers JIT-compiled WebAssembly.
5. **Native binaries (Mac only)**: out-of-process via ExtensionKit or an XPC service, so a crashing plug-in can't take the app down.
6. **Remote hosts**: a server, or a paired device (section 7), using the same messages over the network.
7. **FMUs (later, Mac)**: imported through the same interface.

Formulas, scripts and modules all conform to `AuthoredModel` (`TimelineModel` plus what the Slot tab shows), so the app builds and shows them the same way, and edits the text of those that have one.

Plug-ins never talk to each other. The scenario passes every input and event, which keeps them sandboxed and reproducible.

### 6.2 Formula language

Typed in the UI, one statement per line. `#` or `//` starts a comment.

```
step 1 month                 # step rate; units: second minute hour day week month quarter year
timeunit year                # optional: unit for dt and d/dt (defaults to the step's unit)
param rate = 5%              # parameter; "set" events can change it
param deposit = 200
init balance = 1000          # a state variable's starting value
balance[t] = balance[t-1] * (1 + rate / 12) + deposit
on bonus: balance += event.amount     # runs for each "bonus" event in the step
```

```
dP/dt = r * P * (1 - P / K)  # differential equation (needs init P), solved with RK4
```

```
demand[t] = base * (1 + 0.06 * (Climate.temp.mean - 18))   # another slot, resampled
occupancy[t] = min(capacity, occupancy[t-1] * 1.02)
when Building.occupancy > Building.fireCodeLimit emit OverCapacity
on FireRisk.OverCapacity[t-1]: occupancy = fireCodeLimit * 0.9
```

Parameters and starting values can say how people see and set them, after the value:

```
param rate = 4.5% range 0%..15% label "Interest rate"
param monthly = 400 range 0..5000 by 50 label "Monthly deposit" as currency
init balance = 18000 label "Balance" as currency
```

| Option | Meaning |
|---|---|
| `range low..high` | The slider's range. Values outside it can still be typed. |
| `by step` | The slider's step. |
| `label "text"` | The name shown in the Slot tab. Defaults to the variable's name. |
| `as currency` | How the value is written: `number`, `percent`, `currency` or `temperature`. A value written with `%` is a percent unless it says otherwise. `currency` (or `money`) is money in the slot's currency, which the slot or scenario chooses (15.2), so the same model works in pounds, euros or dollars. |
| `fit` | Refit may change it to match the slot's readings, within its `range` (8.4). Only on `param` and `init` lines. |

They become the variable's `label`, `minimum`, `maximum`, `increment`, `quantity` and `fittable` in the model's descriptor, like FMI's `min`, `max` and `description`. Plug-ins describe their parameters the same way. Lines that define a value can take `label` and `as` too, which name what the graph shows: `temp[t] = … label "Temperature" as temperature`.

A slot can override any parameter's or starting value's default (UI.md, 5.7), like an SSP parameter binding. The formula keeps its defaults, and the slot keeps its own values next to it.

References:

| Form | Meaning |
|---|---|
| `x` or `x[t]` | This step's value of a variable, or a parameter or built-in |
| `x[t-1]` | The variable's value at the previous point (its `init` value, or 0, at the start) |
| `Slot.var` | Another slot's variable this step (`hold`) |
| `Slot.var.mean` / `.sum` / `.min` / `.max` / `.hold` | Resampled over this step's window |
| `Slot.var[t-1]`, `Slot.var.mean[t-1]` | The same, one step earlier. Use these to close feedback loops. |
| `event.field` | A field of the event being handled (inside `on` only) |

Order within a step:

1. `set` events update parameters.
2. Differential equations are integrated over the step (RK4, 8 substeps). Derivatives see the ODE variables at each stage. Other variables keep their previous values during integration.
3. Definitions are evaluated in dependency order. A same-step loop is an error.
4. `on` handlers run for each matching event, in event order.
5. `when` conditions are checked. Each emits once each time its condition turns from false to true.

Built-ins:

- **Constants and time:** `pi`, `step` (index), `year` (fractional), `month`, `day`, `dayOfYear`, `days` (since the scenario start), `dt` (step length in the time unit).
- **Functions:** `min`, `max`, `abs`, `sqrt`, `exp`, `log`, `log10`, `sin`, `cos`, `tan`, `floor`, `ceil`, `round`, `pow`, `mod`, `clamp(x, lo, hi)`, `if(cond, a, b)`, `random()`, `normal(mean, sd)`.
- **Operators:** `+ - * / ^`, comparisons, `and`, `or`, `not`. A trailing `%` on a number divides it by 100.

Typing your own code is allowed on iOS; apps like Scriptable and Pythonista already do it. Planned: units in formulas, `local` variables hidden from other slots, compiling formulas to closures or bytecode for speed, and named imports with stable IDs that survive renames.

### 6.3 Platform rules for plug-ins

Findings from October 2026:

- **iOS won't load binaries the app didn't ship with.** App Store guideline 2.5.2 forbids downloading code that changes the app's features.
- **Guideline 4.7 explicitly allows plug-ins** and JavaScript mini apps, on these conditions:
  - 4.7.2: no access to native platform APIs without Apple's permission. Pure-computation models fit.
  - 4.7.3: no sharing of user data with a plug-in without consent each time. The connection wiring UI serves as that consent, for example before a HealthKit-fed slot's values reach a third-party plug-in.
  - 4.7.1 and 4.7.4: a public plug-in catalog needs content reporting and filtering, plus an index with universal links.
- **JavaScriptCore inside an iOS app has no JIT compiler.** It runs roughly 12–15× slower in CPU-heavy tests, and can't run WebAssembly. WKWebView runs out-of-process with JIT.
- **ExtensionKit's API exists on iOS 26**, but Apple's developer support says iOS apps can only host extensions they ship themselves. Third-party extensions are Mac-only.
- **The Mac App Store allows** hosting plug-ins enabled by other means (guideline 3.1.1).
- **Remote plug-ins** are always allowed.

### 6.4 Scripts: Lua and Python

Decided in October 2026. Scripts are models written in Lua or Python, edited in the Formula tab like formulas. Everything here has to work in apps sold through the Mac App Store and the iOS App Store.

| | Mac | iPhone and iPad |
|---|---|---|
| Lua 5.5 | Built into the app | The same |
| Lua libraries | Pure Lua files the user adds | The same |
| Python 3.14 | Bundled CPython, in the app's process | Embedded CPython, in the app's process |
| Python's standard library | Bundled | Bundled |
| Pure-Python libraries | Files and folders the user adds | The same |
| Native Python packages (numpy and the like) | Only ones the app ships with. None yet. | The same |
| pip, ensurepip, venv, LuaRocks | Not supported | Not supported |

**Where the interpreters come from:**
- **Lua** is compiled from source into the `CLua` target. Its `os`, `io`, `package` and `debug` libraries aren't built at all, which also keeps iOS-only restrictions (no `system`) out of the way.
- **Python** is BeeWare's [Python-Apple-support](https://github.com/beeware/Python-apple-support) build of CPython 3.14: a `Python.xcframework` with a Mac slice and iOS device and simulator slices. `scripts/fetch-python.sh` downloads it into `Vendor/Python` (not in git) and checks its checksum. The package links Python only when that folder exists, so a build without it still works, and Python slots pause with a note saying Python isn't in this build.
- **Packaging for the stores:**
  - On the Mac, `Python.framework`, with its standard library inside, goes in the app's `Contents/Frameworks`.
  - On iOS, the standard library goes in the app's `python` folder, and each compiled module becomes a framework of its own, as Apple requires. BeeWare's `build/utils.sh` does this when an iOS app target exists.
  - `fetch-python.sh` takes out `ensurepip` (which carries a pip wheel), `venv`, `idlelib`, the test suite, `tkinter` and the `python3` binary. So neither bundle can install packages.

**Why no pip:** App Store guideline 2.5.2 forbids downloading code that changes what an app does. Users can still add their own libraries: plain Lua and Python source files in the Libraries folder, the same way they type scripts. That's what Pythonista and Scriptable do.

**Third-party libraries:**
- **The Libraries folder** is `Libraries/lua` and `Libraries/python` in the app's Application Support folder. On iOS, it's in Documents, so the Files app can reach it.
  - `require "name"` in Lua loads `name.lua` or `name/init.lua` from there.
  - Python adds the folder to `sys.path`, so modules and packages import as usual.
  - After changing files there, scripts load again once Reload Script Libraries is chosen in the menu bar item (`ScriptPrograms.reloadLibraries()`). Open Script Libraries Folder makes the folders and opens them.
  - Python imports library modules afresh for each script, so two scripts never share a module's variables.
  - Python scripts load one at a time, since `sys.path` and `sys.modules` are shared by every thread. Each load gives `sys.path` a new list rather than changing the old one, so an import running in another script isn't disturbed.
- **Native Python packages** have to be compiled for each platform and signed into the app. So they're a list the app chooses and tests. numpy is the first candidate: it now publishes iOS builds. Each one makes the app bigger.

#### The script API

Lua and Python get the same API. A script declares its parameters, state and inputs when it loads, then defines `step(s, t)`:

```lua
every "1 month"
param("rate", "4.5%", { range = {"0%", "15%"}, by = "0.1%", label = "Interest rate" })
param("monthly", 400, { range = {0, 5000}, by = 50, label = "Monthly deposit", as = "currency" })
init("balance", 18000, { label = "Balance", as = "currency" })
output("interest", { as = "currency" })
emits "Millionaire"

function step(s, t)
  s.interest = s.balance * s.rate / 12
  s.balance = s.balance + s.interest + s.monthly
  if s.balance >= 1e6 then emit("Millionaire") end
end

on("deposit", function(s, e, t) s.balance = s.balance + e.amount end)
```

```python
every("1 month")
param("rate", "4.5%", range=("0%", "15%"), by="0.1%", label="Interest rate")
param("monthly", 400, range=(0, 5000), by=50, label="Monthly deposit", as_="currency")
init("balance", 18000, label="Balance", as_="currency")
output("interest", as_="currency")
emits("Millionaire")

def step(s, t):
    s.interest = s.balance * s.rate / 12
    s.balance += s.interest + s.monthly
    if s.balance >= 1e6:
        emit("Millionaire")

@on("deposit")
def deposit(s, e, t):
    s.balance += e.amount
```

| Declaration | Meaning |
|---|---|
| `every "1 month"` | The step rate, as in the formula language's `step`. Required. |
| `timeunit "year"` | The unit for `t.dt`. Defaults to the step's unit. |
| `param(name, value, options)` | A parameter. `set` events change it. |
| `init(name, value, options)` | A state variable and its starting value. |
| `output(name, options)` | A value the script works out each step. It starts at 0 unless `start = x` says otherwise. |
| `input(name, "Slot.value.mean[t-1]")` | Another slot's value, read as `s.name`. The reference works as it does in formulas. |
| `emits "Kind"` | An event kind the script can send. |
| `on("kind", fn)` | Runs `fn(s, e, t)` for each event of that kind in the step. `"Slot.Kind"` or `"Slot.Kind[t-1]"` listens to another slot's events. |
| `start(s, t)` | Optional. Runs once at the start, after the starting values are set. |

The options are the formula language's: `range`, `by`, `label` and `as` (`as_` in Python, where `as` is a keyword). As in formulas, `"currency"` is money in the slot's currency (15.2). Parameters and starting values also take `fit` (8.4): `{ fit = true }` in Lua, `fit=True` in Python. A value written as a string ending in `%`, like `"4.5%"`, is divided by 100 and shown as a percent.

What a step sees:
- **`s`** holds the parameters, state variables and outputs, which it can change, and the inputs, which it can only read. A name that isn't declared is an error, so typos don't go unnoticed.
- **`t`** holds the time:
  - `t.index` (the formula language's `step`), `t.year` (fractional), `t.month`, `t.day`, `t.dayOfYear`, `t.days` and `t.dt`.
  - `t.date`, as text like "2031-06-01".
  - `t.events`: the step's events.
  - `t.random()` and `t.normal(mean, sd)`.
  - `t.emit(kind, fields)`, the same as `emit`.
- **Events** have `kind`, `slot` (for another slot's events) and `date`, plus their fields: `e.amount`.

Order within a step, as for formulas: `set` events change parameters, `step` runs, then the `on` handlers run in event order.

#### ETF keeps the state

The engine copies a slot's state for checkpoints every 32 steps, for undo, previews and goal seek (4.3). So a script's state is the list of numbers it declared, and the app keeps it, not the interpreter. Each step, the app hands the numbers in and reads them back. This keeps scripts reproducible, and the same script could run on another machine (5.6).

Hidden state would break this, so the app guards against it:
- **Lua:** globals can't be changed once the script has loaded. Assigning one says to use `local`, or to declare the value with `init`.
- **Python** can't be stopped from keeping values in module variables. The docs and errors say not to.
- **Randomness** is seeded for each slot and step. Lua's `math.random` and Python's `random` module are seeded before every call, as well as `t.random`.

#### Safety

Scripts are the user's own code, or libraries the user added, so they run in the app's process, with guard rails rather than a full sandbox:
- **Time limits:** each call into a script stops after a time limit, which catches endless loops. Lua counts instructions and checks the clock. Python raises an exception in the script's thread from a watchdog; it can't interrupt long-running native code.
- **Lua's memory** is capped for each script, 64 MB by default.
- **Lua's `load`** takes text only, never bytecode, so a script can't load hand-made bytecode.
- **Python audit hooks** (PEP 578), installed in C so scripts can't remove them, block:
  - network connections;
  - starting or signalling processes;
  - importing `ctypes`, which reaches raw memory. Its own import catches the error from loading a library, so the import itself is blocked.
  - writing, deleting or renaming files.

  `os._exit` and `os.abort` are replaced, so a script can't end the app.

  Reading files is allowed. This is about keeping scripts reproducible, and about App Store guideline 4.7.2.
- **Crash isolation:** a crash in a native package, or memory growing without limit in Python, would take the app down. On the Mac, a later step can move Python into a sandboxed XPC service inside the app bundle, which the Mac App Store allows. iOS has no such option, so the list of native packages stays small and tested.

#### Threads and speed

- **Each script loads once** and is shared by every model built from the same text (`ScriptPrograms`). A lock lets one call in at a time.
- **Python has one interpreter** with the GIL. Python slots in different slot groups take turns, while formula and Lua slots still run on other cores. Sub-interpreters with their own GIL would lift this, but numpy and most native packages don't support them yet.
- **Loading scripts:** building a slot's model loads the script to read its declarations, as compiling a formula does. Lua loads in well under a millisecond. Python's interpreter takes a moment to start the first time, so the Mac app starts it on a background thread at launch.
- **Speed**, measured through the engine on the 2017 iMac Pro:

  | Model | Per step |
  |---|---|
  | Formula | 3 µs |
  | Lua | 8 µs |
  | Python | 13 µs |

  - **Lua:** most of the time goes on handing the state over and building `s` and `t`. The time-limit hook costs about 0.9 µs.
  - **Formatting dates:** `String(format:)` cost more than a Lua step, so dates are formatted by hand.
  - **Batches:** a later step can hand a script many steps per call when nothing else reads it within the step (5.6).

#### Errors while running

- **The error stops the slot:** a script that raises an error stops at that step. `ScriptError` conforms to `ModelFailure`, so the engine passes it on with its slot and line, rather than wrapping it.
- **What's kept:** the slot keeps what it computed before the error. The engine remembers the failure (`SlotFailure`) until the next edit, and every fetch reports it.
- **What the app shows:**
  - The graph shows "Stopped" and the message where the line ends.
  - The footer says when it stopped.
  - The Formula tab lists the error at its line.
- **Drafts:** loading a script only finds some mistakes, such as syntax errors and bad declarations. Others, like a misspelt `s.balnce`, only show up when a step runs. So the dashed preview, which runs the draft in the background anyway, reports its error to the Formula tab too.

#### The editor

The Formula tab edits scripts too:
- **Highlighting:** colours for each language.
- **Completion:** the script API, `s.` names and other slots' values.
- **Checks:** loading the script reports syntax errors, mistakes in declarations, and errors raised while it runs, with their line numbers. Wiring problems with other slots are reported as they are for formulas.
- **Preview, Apply and Revert** work as they do for formulas.

#### Running scripts without the app

`swift run etf-script model.lua --through 2040-01-01 --set rate=0.04` runs a script model on its own and prints its values as CSV. It's a start on the headless runtime.

**iOS:** FutureScript builds for iOS devices and the simulator, with `swift build --triple arm64-apple-ios17.0 --sdk $(xcrun --sdk iphoneos --show-sdk-path)`. The same `etf-script`, built for the simulator, runs Lua and Python scripts inside it:
- `xcrun simctl spawn <device> .build/ios-sim/debug/etf-script model.py`
- `SIMCTL_CHILD_ETF_PYTHON_HOME` points at `Vendor/Python/iOS/Python.xcframework`.
- `SIMCTL_CHILD_ETF_PYTHON_PATHS` points at the simulator slice's `lib-dynload`.

There's no iOS app yet, so packaging Python's standard library into one is still to do.

#### Remote runtimes (later)

The headless ETF runtime (5.6, 7) will run whole slot groups on the user's Mac or a server, for iOS devices that need a library the app doesn't ship. A server for many users is wanted, but it's deferred until the app's main features are settled.

### 6.5 Simulation modules (Swift)

Begun in November 2026. A simulation too heavy for a formula or script, such as an epidemic spreading between 200 countries, is written in Swift and built into the app as a module.

**Kept apart from everything else.** Each module is a SwiftPM target in a folder of its own under `Sources/Simulations/`, and depends only on `FutureEngine` and the contract, `FutureSimulation`. Its tests depend on the same three targets, and run with no app. SwiftPM alone doesn't stop a target importing another of the package's modules it doesn't depend on, once that module has been built, so two things check it:
- `ModuleIsolationTests` reads every module's source on each `swift test`: modules may import only Foundation, `FutureEngine`, `FutureSimulation`, Accelerate and simd (the catalog also imports the modules), and may not use files, the network, settings, the environment or other processes (`FileManager`, `URLSession`, `Bundle`, `UserDefaults`, `ProcessInfo` and the like).
- `swift build --explicit-target-dependency-import-check error` refuses any target importing a package module it doesn't depend on.

**The contract** (`FutureSimulation`):

| Part | What it is |
|---|---|
| `SimulationModule` | `id` (written in scenario.md, so it never changes), `version` (goes up when the model's meaning changes), `info` (name, summary, picker category, the slot's name, what the graph shows first, the backdrop it suggests, and its trigger), `needs` (data it asks for) and `makeModel(name:values:data:)`, which returns an `AuthoredModel`. |
| `ModuleTrigger` | The event that sets a module off, such as `infect` with an amount of 10, and the starting values that keep it quiet until then (`infected: 0`). A new slot gets the event at the cursor and those values, so it begins where the person is looking rather than at the scenario's start (UI.md, 5.7). Without one, a module starts at the scenario's start with its defaults. |
| `ModuleReference` | `epidemic@1`: a module and the version a scenario was made with. |
| `DataNeed`, `DataTable`, `ModuleData` | What a module asks the app for by name ("countries"), and the tables the app hands over: rows with a key each, such as a country code, and columns of numbers. The module never knows where they came from. |
| `ModuleDataSource` | Where the app gets modules' data: bundled with the app, a feed or a cache. The app supplies one, and tests supply their own. None of the modules so far needs data. |
| `ModuleCatalog` | The modules an app offers, with its data source. It checks the app has the module, a version at least as new as the scenario's, and the data it needs, then builds the model. Older versions are run by the current one, so a module must keep its meaning for old scenarios or change its id. `SimulationCatalog` (`Sources/Simulations/Catalog`) lists the modules that come with the app. |
| `NumericSimulation`, `NumericModel` | Most modules keep their state as a row of numbers: parameters, starting values, outputs, then hidden numbers (such as whether an event was emitted). A module declares them in a `SimulationShape` and writes only `start` and `step`. Each parameter and starting value has a label and can have `about:`, a sentence on what it means, which the Slot tab shows on hover (`Variable.about`); the Epidemic, World epidemic and Internet worm modules give one for each. `NumericModel` does the rest, as `ScriptModel` does for scripts: `set` events, readings as corrections (4.6) and what they replaced (8.4), the slot's own values, Refit's copies, checkpoints and saved numbers for the cache. `Numbers` reads and writes by an `Int` enum that follows the shape, and `turnedTrue` emits an event once each time a condition becomes true, like a formula's `when`. |

**In the app:** a module is `ModelKind.module(reference)`, listed in the model picker as Swift under its own category. Its slot has the module's parameters and starting values in the Slot tab, takes its events in the Event tab, and can be predicted with, refitted and overlaid like any slot. The Formula tab says it's built in and has no text to edit. In `scenario.md` the slot's heading names it, and it has no block (15.2):

```markdown
## 7. Outbreak [Epidemic, module: epidemic@1, shows: infectious]

### Values
- r0: 3
```

A slot that names a module the app hasn't got, or a newer version than the app has, is paused with the reason (5.9).

**Beginning at the cursor:** all three modules have triggers. The Epidemic's is `imported` 10 with `exposed: 0`, the World epidemic's `imported` 10 (in the country where it starts) with `firstCases: 0`, and the Internet worm's `infect` 10 with `infected: 0`. So a scenario that starts in 2000 no longer has its outbreak over in the first minutes of 2000, out of sight. The trigger and the emptied values are written in scenario.md like any slot's own, and a module's defaults are unchanged, so older scenarios run as they did. A test checks every built-in module's trigger is an event it handles, and that nothing happens before it.

**Epidemic** (`Sources/Simulations/Epidemic`) is the first module: an outbreak in one population (SEIR), from R₀, the incubation, the days a case is infectious and the population, a step a day. Each day 1/days of the incubating and infectious move on, and new cases are those who can still catch it times 1 − e^(−R₀ × infectious ÷ (illness × population)). So each case infects R₀ people, everyone is counted once, and an unchecked outbreak reaches the share the final-size equation gives. `imported` events add cases, `vaccinate` events make people immune, and `set` events change R₀ (a lockdown). It emits Peak and HerdImmunity. It began as a formula; written as a module it runs about 3× faster than a one-line daily formula.

**World epidemic** (`Sources/Simulations/WorldEpidemic`, `world-epidemic@1`) is the second: Epidemic's model in each of the world's countries (177, Antarctica's research stations included), joined by travel. It's the first module that needs data: a `countries` table of ISO 3166 alpha-3 codes with each one's population, latitude and longitude. The app supplies it (`AppModuleData`, from the world map's table, 9.6) through `ModuleCatalog.app`, the built-in modules with the app's data, which all app code uses; `ModuleCatalog.builtIn` has none.

- **Travel:** a share of each country's contacts are with people from other countries (Contacts abroad, 0.1% to start, 0–5%). That share goes to the 20 countries its people meet most, by a gravity model: in proportion to each one's population over the distance between their label points to the 1.5, counting anything nearer than 500 km as 500 km. So the force in a country is R₀ × (1/illness) × ((1 − travel) × its own infectious share + travel × the others', weighted). `set travel 0 from 2027-03` is a travel ban. A country with no links keeps all its contacts at home, so one country alone is exactly Epidemic, step for step.
- **Arrival:** a country spreads it at home only once a whole person there has caught it; until then only cases from abroad count. Without that, every country would grow its own outbreak from a trace on the first day, as equations like these do, and no travel ban could keep it out.
- **Where it starts:** settings are numbers, so the start is a latitude and longitude (London to begin with), and the first cases (10) go to the country whose label point is nearest. `imported` events add cases there, or near the event's own `latitude` and `longitude`; `vaccinate` events are shared among countries by how many can still catch it.
- **What it shows:** world totals (infectious, incubating, new cases, ever infected, can still catch it, recovered, vaccinated, countries reached) as its values, and the fields `infectious` (the share infectious now, shaded logarithmically from one in a million to a tenth), `infected` (the share ever infected) and `groups` (where everyone is). It emits Peak. `ModuleInfo.backdrop` suggests `world-map of infectious`, which a new slot gets.
- **Speed:** about 4,000 multiply-adds a day while it spreads. Two things keep a century quick: counts below a trillionth of a person are none, since numbers near 10⁻³⁰⁸, which a dying outbreak reaches, are very slow on Intel chips; and once nobody anywhere is incubating or infectious, a step does nothing until an event. 100 years took 3.5 seconds before them and 0.36 after, on a busy iMac Pro; a field at the cursor takes about 0.3 ms.
- **Later:** real air-traffic flows instead of the gravity model (they're sold, not free), travel bans and lockdowns for single countries, and inputs from other slots.

**Internet worm** (`Sources/Simulations/Worm`, `worm@1`) is the third: a worm spreading by scanning random IPv4 addresses, as Code Red (2001) and Slammer (2003) did, after the two-factor model (Zou, Gong and Towsley, 2002). It steps every minute, worked out in one-second steps inside it.

- **Spreading:** each second, a vulnerable host is hit by one of the infected hosts' scans with chance 1 − e^(−scans × infected ÷ 2³²), which stays right however fast a worm scans. Each infected host scans at its scan rate times (1 − infected ÷ vulnerable)^congestion, so the network filling up slows it (Slammer did).
- **Fighting back:** a share of infected hosts are cleaned up each hour, and still-vulnerable hosts are patched at a rate that grows with the share of hosts already hit, people's awareness. `infect`, `patch` and `clean` events add infected hosts, patch vulnerable ones, and clean infected ones; `set` events change any of it, such as the scan rate when networks start filtering. It emits Peak.
- **Defaults** are Code Red's: 360,000 vulnerable hosts scanning 6 times a second, which gives the 1.8-an-hour growth fitted to its spread (Staniford, Paxson and Weaver, 2002). Slammer's numbers (75,000 hosts, 4,000 scans a second) double in about ten seconds and fill the Internet in minutes.
- **Settling** (4.11): once nobody is infected or nobody is left to infect, and nothing is being cleaned or patched, it has settled; fewer than a millionth of a host counts as none, so it does. A century then costs nothing. The timeline zooms in to an hour to watch it (UI.md, 2.5).
- **What it shows:** infected, still vulnerable, cleaned up, patched, ever infected, and scans a second from all hosts, which is the load it puts on the network; the field `groups` for parts of a whole, which a new slot draws.
- **Later:** worms that follow networks rather than scanning at random (topological, email and local-network worms), on a map of the Internet's links; the free maps of it (CAIDA's, TeleGeography's cables) have terms to check first.

**Next** (each its own branch):
1. **Fields** are done (4.10): values per key, worked out at the cursor from the nearest checkpoint.
2. **Backdrops** are begun (9.6): a world map and parts of a whole behind the focused graph, driven by a module's field or a formula's position.
3. **World travel** is done: the World epidemic, above.
4. **A sky map** and **the Internet worm** are done (9.6, above), with settled models (4.11), zooming in to an hour (UI.md, 2.5), and new slots beginning at the cursor (triggers, above). Worms that follow networks are later.
5. Moving scripts' own file lookups (the Libraries folder, Python's home) behind the same kind of interface.

## 7. Capability borrowing (paired devices)

Some capabilities exist only on some devices. Apple's on-device language model (the Foundation Models framework) needs Apple Intelligence: Apple silicon Macs, and iPhones from the 15 Pro onwards. An Intel Mac can't run it, and an iMac Pro can't upgrade to macOS 26 anyway.

Paired devices can lend capabilities to each other over the same message protocol as remote models:

1. **Discovery**: Bonjour on the local network. Requires the Local Network permission prompt on iOS (`NSLocalNetworkUsageDescription` and `NSBonjourServices`).
2. **Pairing**: a one-time code shown on one device and typed on the other. A key derived from it secures the connection with TLS-PSK (supported by Network.framework). Each device stores the other's identity, and pairings can be revoked.
3. **Capabilities are advertised and requested individually**, for example `nl.parseEvent`, `nl.parseFormula`, `readings.health`. Each one has its own permission.
4. **Natural-language example**: the Mac sends "extra $500 every payday from March" along with the scenario's slot names, variables and parameters. The iPhone runs a `LanguageModelSession` with guided generation into an `EventDraft` type, then returns structured JSON. The Mac shows a preview and nothing changes until the user confirms.
5. **Constraint**: iOS suspends apps soon after they leave the screen, so the phone app has to be open to serve requests. A phone on a charger in StandBy works well. The Mac shows whether the lender is reachable.

Providers for natural-language features, in order of preference: on-device Foundation Models (Apple silicon Mac, iPhone, iPad), a borrowed paired device, a local model, then an opt-in cloud API.

Drag the future and drift alerts are numerical and run anywhere, including Intel Macs.

## 8. Signature features

### 8.1 Drag the future (goal seek)

Grab the line at a future date and drag it to a target value. The app works out a change that gets there and proposes it as an event, like "add $640/month from January." The user accepts, adjusts or rejects it.

Built in November 2026 (UI.md, 5.2), apart from sketching. `Scenario.solve` (`FutureEngine/GoalSeek.swift`) finds the value of one change, a `GoalLever`: a parameter set from a date, or a one-off event that takes an amount. A parameter with a range is searched within it; one without, and an amount (from zero up), widen their search from where they are, doubling the step until the target is passed, or give up after 60 doublings. Then bisection, then the answer is rounded (whole units from 100 up, four significant figures below) and checked again; the `GoalSolution` says what it reaches. Each try upserts one trial event, so only the time after it is computed, and it's taken out at the end. `Scenario.goalSeek` stays for a fixed range.

- The user, or a sensible default, chooses what may change: a parameter from a date (`set deposit = x`), a one-off amount, a start date.
- The solver tries values with bisection, or secant when the function behaves. Each try inserts a trial event, so only the time after that event is recomputed, thanks to checkpoints. The scaffold implements this as `Scenario.goalSeek`.
- Several candidate fixes are offered side by side, smallest change first: each parameter from a chosen start, the same from a later one, and each one-off event the slot takes. Extending a term or accepting more risk would need levers of their own.
- **Apple Pencil, and dragging with the mouse:** sketch the whole curve you want. The solver fits the changes that best match it (least squares across many target points). It's the same solver Refit uses (8.4), with the sketch's points in place of readings.

### 8.2 Drift alerts

When real readings leave the range the model projected for them, the app says so: a pill on the graph, and a notification when the panel is hidden (UI.md, 5.6). It offers Refit (8.4), which fits the model's values to the new readings.

Built in November 2026, in `FutureEngine/Drift.swift` (`SlotCopy.drift`) and `FutureKit/Drifting.swift`.

- **The projection:** the latest stretch of readings is hidden from the model, which is projected from the slot's point before it, with the slot's own values and only the readings up to there, as the automatic pick's projections are (8.4). The stretch is the last year, or the last fifth of the readings' span when they span less than five years, and always holds at least the last three readings.
- **The range:** most models have no randomness, so there's no ensemble to draw bands from (4.6). Instead, earlier stretches of the same length, back to back before the latest one (up to 20), are each projected from the point before them, and their misses size the range: the typical miss (root mean square) at each quarter of the way through a stretch, never narrower further ahead, times 1.28, which holds the middle 80% (10–90%) of misses that spread normally. A projection that carries on from the latest reading starts close and wanders, so its range widens; a trend line's stays about the same. A steady bias, such as a held value under a rising series, counts in the typical miss, so it doesn't drift on its own.
- **Misses** are ratios (logs) where every reading is above zero, and differences for temperatures, percents and values that reach zero, as in fitting (8.4).
- **Drift** is the last reading outside the range, with most of the last three outside on the same side. A single odd reading isn't drift.
- **Too little to tell:** fewer than five readings, fewer than three readings after the cut-off or two before it, or fewer than three earlier stretches with readings. Then there's no check and no alert.
- **The outcome** (`DriftOutcome`): the cut-off, the projection and its range point by point, how many readings were checked and how many fell outside, whether it drifts, and how far the last reading is from the projection (a share of it, or in the value's units).
- **Speed:** a projection is one run of the slot, so a check is at most 21 runs. `etf-bench predict` times it for each Forecast model.
- **Not yet:** time-based wording ("running 2 days behind the model") for models of processes that run their course, such as a fermentation. That would need the model to say which of its values is progress. Bands from the held-back misses (8.4, Later) could also draw a range ahead of now, not only over the latest readings.

### 8.3 Natural-language events

Type or say "what if rates drop to 3% next June?" and get a structured event preview. The same mechanism can turn "model yeast growth in a 5L carboy at 20°C" into a formula with parameters. Providers are listed in section 7.

### 8.4 Predict with: choosing and fitting the model behind a projection

Designed in October 2026, and built: fit parameters, misses, the solver and Refit (`FutureEngine/Fitting.swift`), the Forecast models (`FutureKit/ForecastModels.swift`), the automatic pick, and Refit and Predict with in the panel (`FutureKit/Refitting.swift`, `Predicting.swift`; UI.md, 5.11). Tests cover formulas, Lua and Python.

A slot's model already makes its projection, and readings correct it up to now (4.6). So choosing how to predict a slot's future means choosing its model, and fitting the model to the readings means choosing its parameter values. This section adds four things:

1. **Fit parameters:** a model marks which of its values may be fitted to readings.
2. **Refit:** the app fits those values to the slot's readings and shows the result as a preview before anything changes.
3. **Predict with:** a menu of the models that can take the slot's readings, each one fitted, previewed and scored.
4. **The automatic pick:** the menu scores each model on readings it didn't see, and marks the best.

#### Fit parameters

A parameter or starting value marked `fit` is one that Refit may change:

```
step 1 month
timeunit year
param growth = 3% range -50%..100% label "Growth per year" fit
init value = 0
value[t] = value[t-1] * (1 + growth)^dt
```

- **Scripts** mark them the same way: `param("growth", "3%", { fit = true })` in Lua, `fit=True` in Python.
- **Bounds:** a fitted value stays within the `range` when the model gives one. Without a range it can take any finite value. A slot's own value can be outside its range, since values can be typed; the fit keeps it when nothing within the range does better.
- **Only declarations:** `fit` on a definition or a differential equation is a mistake, since only parameters and starting values have values to set.
- **Plug-ins** mark them in their descriptor (`fittable`), next to `minimum` and `maximum` (6.2).
- **Nothing marked:** a model can still be refitted. Refit then lists its parameters with a box to tick for each, and none are ticked to start with.
- **Parameters with readings** (a feed with `into: rate`) are set by their readings, so they're never offered for fitting.

#### What a fit measures

Readings replace the values they're readings of (4.6), so a slot's line always passes through its readings. A fit has to look instead at what the model worked out *before* each reading replaced it.

- **The miss:** for each reading of a value, the difference between the reading and what its step worked out. Models report what they worked out before a reading replaced it through `doStep(_:_:replaced:)`, as a `Prediction`. Formulas and scripts do; other models report nothing, so they can't be fitted. A scenario with `recordsMisses` on keeps each slot's misses (`Scenario.misses(in:through:)`). Only fitting turns it on for now: the app's scenario would need its saved results (15.5) to keep misses too.
- **The first reading:** a value's first reading after the start isn't a miss, because its step had nothing observed to start from. A data slot's value is 0 until then (15.8). A reading at or before the start is taken by the start, so then every later reading counts.
- **Ratios or differences:** when every reading of the value is above zero, a miss is measured as a ratio (the log of the reading divided by what was worked out). That way a series that grows tenfold counts its early years as much as its later ones. Otherwise, a miss is the plain difference. Temperatures and percents are always differences, since a temperature's zero is just a point on its scale, and a percent's misses read best in percentage points.
- **Fitting** makes the sum of the squared misses as small as it can, over a run in which readings correct the model as usual. Each miss is then one step ahead: how far the model went wrong, starting from the reading before. Exponential smoothing and most forecasting methods are fitted this way, and it takes only one run per try.
- **Scoring** asks a harder question: how far a projection made in the past misses the readings that came after it (the automatic pick, below).
- Readings of parameters aren't misses. They're inputs.

#### Readings before the start

A feed often goes back further than the scenario: Europe's temperatures start in 1850, and a scenario might start in 2022. Fitting uses them all.

- **Where a fit runs from:** the slot's first reading of a value, on the slot's grid of points stepped back from the scenario's start (`SlotCopy.runStart`). Without this, a scenario that starts in 2022 would fit Europe's warming to 5 of its 176 years.
- **When it can't:** a slot that reads other slots runs from the scenario's start, since what those slots computed starts there. So does a fit that includes a starting value, since a starting value is the value at the scenario's start.
- **Time in formulas and scripts:** `days` and `t.days` still count from the scenario's start (`Scenario.origin`), and are below zero before it, so fitted values mean the same in the fit as in the scenario. `step` and `t.index` count from where the run starts. The Forecast models use `year`, which is the same everywhere.
- **In the scenario,** the slot still starts at the scenario's start, from the latest reading at or before it (4.6). A model that learns as it goes, such as Recent change, learns again from there.

#### The solver

- **Method:** Levenberg–Marquardt, the standard method for least squares. It finds its slopes by nudging each value and running again, and keeps values within their `range`.
- **Starting points:** Refit starts from the slot's current values, and again from the middle of each range when there is one. It keeps the better of the two results, so it's less likely to settle in a poor local minimum. Comparing models starts once, from a first guess made from the readings, and stops sooner (`FitSettings.comparing`: at most 40 rounds, and once a round improves by less than a ten-millionth).
- **A copy of the slot:** `Scenario.copyForFitting` copies the slot's model, events and readings, and records what the slots it reads computed, through its last reading: their values and their events. Each fit builds a scenario of its own from them (a `Trial`), where the recordings play back (`RecordedModel`), so each try runs only this slot, from where the run starts to its last reading. Slots downstream aren't involved. A loop back through another slot (that slot reading this one with `[t-1]`) is taken as it was, not refitted. `SlotCopy.replacingModel` gives the same slot another model, leaving out the connections and events it has no use for.
- **Threads:** the copy is plain values, so a fit can run on any thread. The engine's thread only makes the copy, which keeps scrolling smooth while a fit runs. `isCancelled` is checked before each try.
- **Randomness:** stochastic models are fitted on their seeded run (4.4), so every try sees the same random numbers.
- **Extreme values:** a try that works out an infinite or NaN value counts as worse than any finite result, and so does zero or less where misses are ratios. The solver then steps back towards the last good values.
- **Speed:** a formula step takes about 3 µs, so a try over 1,000 steps takes about 3 ms, and fitting two values takes well under a second. Python is about four times slower (6.4). A differential equation costs more: in a debug build, fitting an S-curve's two values over 15 years of monthly readings took 95 tries and 2.6 seconds. Comparing every Forecast model, in a release build (`etf-bench predict`): Europe's monthly temperatures since 1850 take about 3 seconds; ten years of daily S&P 500 closes, 8; thirty years of daily US debt, 32, most of it Seasonal's.
- **Failures:** a try the model fails on (a script raising an error) counts as worse, like an infinite value. Failing at the slot's own values is an error, which Refit passes on.
- **Other uses:** the same solver fits sketched curves (8.1), with the sketch's points in place of readings. Goal seek stays as it is: one value and one target.

#### Refit

- **What it shows:** Refit fits the slot's marked or ticked values to its readings. It shows the result as a dashed preview, with each value's change and the typical miss before and after. Nothing changes until it's applied.
- **In the panel:** the Slot tab's Refit… opens a sheet (UI.md, 5.11). The engine's thread makes the copy; the fit runs on a task of its own.
- **In the engine:** `Scenario.refit(slot, FitSettings(values:since:))`, or `copyForFitting` then `fit` on another thread. The `FitOutcome` has the fitted values, the misses before and after (`MissSummary`: how many, the typical miss, and whether it's a ratio), and whether the fit improved on the slot's own values. When it didn't, the values are the slot's own. `SlotCopy.markedValues` lists the values marked `fit`, and `fittableValues` every parameter and starting value without readings of its own, for the boxes to tick.
- **Mistakes** (`FitError`): no readings of a value, nothing chosen, a name the model doesn't have, a value set by its readings, fewer readings than values to fit plus one, too few to compare models, and values that can't be compared with the readings at any setting.
- **Applying** writes the new values as the slot's own values (`### Values` in `scenario.md`, 15.2), as one change that undo takes back. The file format needs nothing new.
- **Which readings:** all of them by default. It can use only the latest instead (the last year, or 5, 10, 25 or 50 years), for a series whose behaviour has changed. Predict with offers the same choice.
- **Drift alerts** (8.2) offer the same Refit.
- **New readings** don't start a refit on their own (17). Models that learn from their readings as they go, such as Recent growth below, keep up without one.

#### Predict with

Predict with is a menu of the models that could make the slot's projection. Choosing one changes the slot's model, as Change model… does (UI.md, 5.7), so the slot keeps its name, color, events and readings.

- **Which models:**
  - **The slot's own,** as it is, with its marked values fitted. It's listed first, unless it's one of the Forecast models below.
  - **The Forecast models,** written around the value the readings are of, with its label and kind, when the readings are of one value. A feed into Climate's `temp` gets a Trend line of `temp`, so slots that read `Climate.temp` keep working. Models that work in ratios (Steady growth, Recent growth, S-curve) are offered only when every reading is above zero, and Seasonal only for steps shorter than a year.
  - **Library models** that have every value the readings are of, of the same kind (a `value` shown as currency doesn't compare with one in °C), and that read no other slot.
- **Fitted first:** each model is fitted to the slot's readings before it's shown. Its preview and score then show it at its best, not at its default values. Choosing a model keeps its fitted values.
- **The slot's step:** choosing a model keeps the slot's step, so the model's `step` line is set to the slot's. Forecast models are written with `timeunit year` and `dt`, or `year`, so they work at any step.
- **Models added later** join the menu by following the same rules, wherever they come from. Nothing else has to change for them.

**Forecast models.** A library category of their own (`ForecastModels`), listed in the model picker around a value called `value`. Each starts its fit from a first guess made from the readings: a model with a line starting at zero couldn't be compared with readings that are all above zero, and a wave or a ceiling fits more surely from near the answer.

| Model | What it does | Fitted | First guess |
|---|---|---|---|
| Hold the latest | Stays at the latest reading. Feeds' own slots start with it. It was called "Data series"; `scenario.md` files that name it so still read. | Nothing | |
| Steady change | Changes by the same amount every year, from the latest reading | `perYear` | First to last reading |
| Steady growth | Grows by the same percent every year, from the latest reading | `growth` | First to last reading |
| Recent change | Keeps changing by its recent change per year, which it learns from each new reading | `smoothing`: how much each new reading counts | |
| Recent growth | The same, for growth | `smoothing` | |
| Trend line | A straight line through the readings, measured from the start of 2000: `level + perYear * (year - 2000)` | `level`, `perYear` | The least-squares line |
| S-curve | Grows, then levels off (logistic), from the latest reading | `rate`, `capacity` | 1.5 × the highest reading |
| Seasonal | A straight line through the readings, plus a yearly wave | `level`, `perYear`, `swing`, `peak` (the month it's highest) | The line, then each month's average distance from it |

- **From the latest reading, or through the readings:** models that carry on from the latest reading suit series that wander, like prices and debt. On a noisy series, such as monthly temperatures, they carry one odd month forward forever, and a line through the readings does better. The automatic pick tells them apart.
- **Ratios:** where misses will be ratios, the guessed line is fitted to each reading's share of its size, so it stays above zero near the small early readings of a series that grew a lot.
- Recent change and Recent growth follow their readings as they arrive, so they keep up without a refit. They're made for readings at about every step. The fitted models keep their fitted values until the next Refit.

#### The automatic pick

- **Holding back:** the score hides later readings from each model and asks how far its projection misses them (`SlotCopy.score`).
  - Cut-offs fall at 60%, 70% and 80% of the span of readings compared. Each is on one of the slot's points, so no step has readings from both sides of it.
  - At each cut-off, the model is fitted to the readings up to it. It's then projected from the cut-off, and from three more points within the next tenth of the span, each time with only the readings up to that point. Each projection is compared with the readings in the next fifth of the span, so the last cut-off is compared with the last fifth.
  - With twelve projections, the score depends less on how close any one reading was to the trend. That matters for models that carry on from the latest reading: with a single cut-off, a lucky last reading let one beat a trend line on noisy data.
- **One more fit,** to every reading, gives the model's values and line.
- **The score:** the typical miss (the root mean square) over every projection's hidden readings, as a percent where misses are ratios ("off by 2.13%"), and otherwise in the value's own units ("off by 0.755 °C"), to three significant figures.
- **The best** has the lowest score. When two scores are within a tenth of each other, the model with fewer fitted values wins, since it's less likely to be fitting noise.
- **Use the best** chooses it. That's a one-off choice like any other: the menu never changes the slot's model by itself when new readings arrive (17).
- **Too few readings:** scoring needs at least 12 readings before the first cut-off and 4 after each. With fewer, the menu shows no scores and says why.
- **The work:** while the menu is open, the engine's thread copies the slot, and each model is scored on a thread of its own, one at a time, cheapest first, so the panel keeps scrolling. Scores fill in as each model finishes. Closing the menu cancels the work. Scores are kept for each model, its values, the slot's readings and the readings chosen, until one of those changes.
- **Seeing the score:** the preview draws the projection from the last cut-off over the readings it didn't see (UI.md, 2.4), which shows what the score measures.
- **On real data** (October 2026): Europe's monthly temperatures (anomalies) pick Trend line, at +0.04 °C a year over the last 50 years ("off by 0.75 °C", against 1.06 for Hold the latest); US debt picks Steady growth, at 5.8% a year; the S&P 500 picks Recent growth.

#### Later

- **Bands from misses:** the held-back misses at each distance ahead give a range that widens with distance. Models without randomness can't draw bands now (4.6), and drift alerts (8.2) could use the range too.
- **Speed for long daily series:** start runs at the chosen readings, or score on a monthly summary.
- **Kalman filters** (4.6) fit and correct at the same time, which suits noisy readings better.

## 9. User interface

The detailed UI design (visual language, layouts, input, interactions, accessibility) is in [UI.md](UI.md), with mockups on the design canvas linked there. This section is the summary.

### 9.1 The Mac panel

- An `NSPanel` that doesn't steal focus, floats above normal windows, and joins all Spaces including full-screen ones (`.canJoinAllSpaces` and `.fullScreenAuxiliary`).
- Translucent material background with an opacity control. The graph dominates the window and grows with it.
- Moves only by dragging its top bar. There's no click-through mode: it was dropped as unnecessary, since the panel hides with Esc or the hot-key.

### 9.2 Summon, dismiss and peek

- **Toggle**: a hot-key shows or hides the full panel.
- **Peek**: hold the key to show the panel, release to hide it. This is on the hardware accessory too.
- **Hot-keys** use Carbon `RegisterEventHotKey`, which needs no Accessibility permission. The KeyboardShortcuts package adds a shortcut-recorder UI. In sandboxed apps on macOS 15, Option-only and Option+Shift shortcuts were blocked (only partly relaxed in 15.2), so defaults include Command or Control.
- A hardware button can summon the panel even while the app is in the background (12.5).

### 9.3 Layout: tracks

- The focused slot is large. The other slots in the bank are thin lanes on the same time axis, like DAW tracks.
- Each slot has a color, which matches its LED on the hardware. Mute and solo per slot.
- A shared cursor shows every slot's value at the cursor time.
- Generated events show in a distinct style. Connections can be shown as a patch view.

### 9.4 Command bar

Type commands and events: "+500 monthly from Jan", "rate 4% from 2027-06", "goto 2040", "goto 100°C", "goto mortgage $0", "add loan to 7", "remove climate", "refit savings". `goto` with a value finds where a slot's line first reaches it (UI.md, 5.1). `add` and `remove` change slots (UI.md, 5.7). Natural-language input goes through section 7's providers.

### 9.5 iPad and iPhone

iOS apps can't float over other apps. Equivalents:

- Interactive widgets
- A Control Center control and the Action button for instant opening
- Siri and Shortcuts answers with a chart snippet (App Intents)
- Live Activities for something being actively tracked
- On iPad: multitasking windows, and Apple Pencil for sketching curves (8.1)

### 9.6 Backdrops

Begun in November 2026. A backdrop is an infographic drawn faintly behind the focused graph, showing the slot's state at the cursor: a world map shaded by each country's share infected, where everyone is in an outbreak, a ship's position. As the cursor moves through time, the backdrop follows it.

**Backdrops only draw.** What a backdrop is and shows lives in `FutureVisuals`, which knows nothing of slots, the store, files or SwiftUI. Its drawing lives in `FutureUI/Backdrops`. The store works out what a backdrop shows and hands it over in a `BackdropInput`: a field at the cursor (4.10) with its label, quantity and names for its keys, or a point (`GeoPoint`), in the slot's colour (`RGBA`).

| Part | What it is |
|---|---|
| `BackdropKind` (`FutureVisuals`) | `id` (written in scenario.md), `name` (the Slot tab's menu), the field `geometries` it draws (`world/countries`, `groups`), whether it `drawsPoints`, and the two values it places a point from (`pointNames`). |
| `BackdropCatalog` (`FutureVisuals`) | The backdrop kinds a scenario offers, found by id or by the geometry they draw. The store reads its configuration's (2.1). |
| `Backdrop` (`FutureUI`) | Draws a kind: `drawBase(color:in:size:)` for what doesn't follow the cursor, and `draw(_:in:size:)` for what does. `BackdropDrawings.builtIn` has one for each built-in kind. A new backdrop is a kind and a type that draws it. |
| `BackdropInput.intensities()` | Each key's value as 0–1 for shading: as it is for shares, else against the largest. |

**Built in:**
- **World map** (`world-map`): Natural Earth's 1:110m countries (public domain) on the Equal Earth projection, which keeps countries at their true relative sizes. It shades countries by a `world/countries` field, keyed by ISO 3166 alpha-3 codes, and draws a point. `scripts/make-world-countries.py` turns Natural Earth's GeoJSON into `WorldCountriesData.swift`, a compact table (81 KB) of each country's code, name, label position, population and outlines in hundredths of a degree. Nothing is downloaded at build or run time; the script is run by hand to update the map. `WorldCountries` reads the table; modules that need countries' data can get it from there through the app (6.5).
- **Parts of a whole** (`parts`): a ring split by a `groups` field, with each part's name and share beside it, left-aligned. Epidemic's "Where everyone is" draws with it.

**Choosing one:** a slot's heading in scenario.md says `backdrop: world-map` (the first field the backdrop can draw), `backdrop: world-map of infected` (that field) or `backdrop: world-map at lat lon` (a point from two of the slot's values, latitude then longitude). The Slot tab's Backdrop menu offers each backdrop with each field it draws, and the world map's position when the slot has values called `latitude` and `longitude` (or `lat` and `lon`), so a formula or script can drive one too. One that can't be read is kept as written and reported. A backdrop the app hasn't got draws nothing.

**Drawing:** only the focused slot's backdrop is drawn, under the graph's tints, grid and lines. The store asks for its field at the cursor as it does for watched fields (4.10), and for a point's two values with every fetch (4.9). Only the backdrop's views read `backdropState()`, so nothing else redraws as it changes. The base layer is a view of its own whose inputs are the backdrop and colour, so it's drawn again only when those or the size change; the world map's outlines are one path, filled and stroked once. Snapshots include the backdrop as it is at the cursor.

**Speed:** `etf-bench cursor-loop parts` and `cursor-loop map` sweep the cursor over a panel with each. On a busy iMac Pro, drawing every country's outline in each frame added about 9 ms a frame; with the base layer apart and the outlines as one path, the map adds about 2 ms and the ring about 1.6 ms, against about 15 ms for the panel.

- **Sky map** (`sky-map`): the 2,887 stars brighter than magnitude 5.5 from the Yale Bright Star Catalogue (5th revised edition, public, from NASA's HEASARC) on the Hammer projection: an oval twice as wide as high, every part at its true size, north up, right ascension increasing to the left as the sky is seen, 0h in the middle. Each star is a dot sized by its magnitude and tinted by its B−V colour index, with the celestial equator and the ecliptic. It brightens stars by a `sky/stars` field keyed by Harvard Revised number ("HR 2491" is Sirius), and draws a point from a slot's declination and right ascension (`dec` and `ra`, in degrees), such as a comet a formula moves. `scripts/make-bright-stars.py` turns the catalogue into `BrightStarsData.swift` (87 KB). Backdrops say which two values they place a point from (`BackdropKind.pointNames`).

**Later:** constellation lines (the free sets need their licences checked), a globe, a network of links (for worms between networks), easing between shadings, and showing the backdrop of an overlaid slot.

## 10. Commands and integrations

### 10.1 One command vocabulary

Menus, keyboard shortcuts, the URL scheme, the command-line tool, App Intents and hardware all send the same `Command` values. The app sends `DeviceFeedback` back to hardware. Both are defined in `FutureCommands`.

| Group | Commands |
|---|---|
| Window | `toggleWindow`, `peek(begin/end)` |
| Slots | `selectSlot(n)`, `toggleSlotVisible(n)`, `soloSlot(n)`, `nextBank`, `previousBank` |
| Timeline | `scroll(ticks)`, `zoom(ticks)`, `jumpToNow`, `show(timeline, at)`, `goto(text)`, `setWheelMode`, `cycleWheelMode` |
| Editing | `insertEventAtCursor`, `adjustParameter(name, ticks)`, `addEvent(EventRequest)`, `addModel(name, slot)`, `removeSlot(name)`, `undo`, `redo` |
| Clipboard | `copySnapshot(format)`, `copyData` |

- `goto` takes the command bar's text: a date, or a value with its unit or slot (`2035`, `savings 1m`, `25°C`).
- An `EventRequest` names a slot (or the focused one), a kind (`deposit`, `withdraw`, `set` for parameters, or another kind the slot takes), its values, the currency they were given in, a date (now when left out) and how often it repeats. A plain number for a percent is in percent, as in the Slot tab: 4.5 is 4.5%; `Amount.isFraction` marks one given with "%".
- `removeSlot` only asks: the panel shows the question in the Slot tab (13, rule 6).
- **Questions** (`Query`) never change anything: `status`, `slots`, `value(slot, variable, at)` and `series(slot, variable, from, through, every)`. A request from outside is a `Request`: a command or a question. Each gets a `Reply`, with a message in the panel's words and, for questions, the answer.
- Commands that arrive from outside are checked with `isWellFormed` before they run: slots 1–8, ticks within the URL scheme's limit, names up to 200 characters, finite amounts. Dates are checked as they're decoded.

Feedback to devices: each slot's name, color, state (idle, computing, error) and whether it's selected or soloed. Also the cursor's date and value text, the wheel mode, and whether peek is active.

### 10.2 Integrations

Everything that's reasonable and secure (section 13):

- **URL scheme `etf://`**, for example `etf://show?timeline=savings&at=2030-01`. Others: `etf://toggle`, `etf://now`, `etf://select?slot=3`, `etf://scroll?ticks=12`, `etf://zoom?ticks=-2`, `etf://copy?format=png|pdf|tsv|all`. Dates can be `YYYY`, `YYYY-MM` or `YYYY-MM-DD`.
- **Command-line tool `etf`**, inside the app, talking to it through a private local socket (10.3): `etf show savings --at 2030-01`, `etf value savings balance --at 2030-01`, `etf data savings --every monthly`, `etf copy --format tsv`, `etf event add savings deposit amount=500 --at 2027-01-01`.
- **Menu bar item** (`MenuBarExtra`): current values, quick toggle, recent timelines.
- **App Intents** on all platforms, powering Shortcuts, Spotlight and Siri (10.4): "What's my savings balance in 2030?" answers with a value and a chart snippet. Also intents to show a timeline, add a deposit or withdrawal, change a parameter, and copy a snapshot.
- **Local network API** for paired devices only (section 7).
- **AppleScript**: optional and low priority. App Intents and the CLI cover most needs.

### 10.3 The etf tool

`etf` (`Sources/etf`) only reads its arguments, connects and prints. Reading the arguments and printing replies are in `FutureCommands` (`CommandLineTool`), so they're tested without the app.

- **Commands:** `status`, `slots`, `value [SLOT] [VALUE] [--at DATE]`, `data [SLOT] [VALUE] [--from] [--through] [--every]` (CSV), `show`, `goto`, `focus`, `now`, `toggle`, `scroll`, `zoom`, `deposit`, `withdraw`, `set`, `event add`, `reading SLOT AMOUNT [--of VALUE] [--at DATE]`, `add`, `remove`, `undo`, `redo` and `copy`. `etf help` lists them.
- **Output:** text in the panel's words, the value as the panel writes it (`£96,420`), `--number` for every digit (`96420.12345`, `inf`, `nan`), CSV for `data`, and `--json` for the whole reply. Errors go to standard error. Exit codes: 0 done, 1 the app said no, 2 wrong arguments, 3 the app couldn't be reached.
- **Numbers** use a point for decimals whatever the slot's style, as scripts expect: `1,200.50`, `1.5k`, `4.5%`, `£500`, `500eur`. Commas only group thousands, so `1,5` is refused rather than read as 15.
- **Dates** are `2030`, `2030-06` or `2030-06-15`, in UTC like the engine. `value` gives the slot's last step at or before the date. `data` without dates covers ten years from today, one row a step, or one per `--every` holding the value then; it stops at 100,000 rows.
- **Starting the app:** when nothing is listening, `etf` starts the app it came in (or the one macOS knows) with `--background`, so the panel stays hidden until a command shows it, and waits up to 20 seconds.
- **The socket:** `~/Library/Application Support/Edit The Future/commands.sock`, or the per-user cache folder when that path is too long for a socket's address. One request and one reply a connection, each a length then JSON (`Wire`), with a version. JSON can't hold infinity or NaN, so they're written as `"inf"`, `"-inf"` and `"nan"`.
- **Why not XPC:** an app can't offer a named XPC service unless launchd knows the name first, which means a launch agent registered with `SMAppService`. That shows in Login Items, with a notice, likely again after every ad-hoc rebuild. A Unix socket gives the same check of the caller's code signature (13, rule 2) without it. The protocol is apart from the transport, so XPC can replace the socket later.
- **Questions** go through the engine's queue after anything already queued (`ScenarioEngine.read`), so the main thread still never computes. A value far ahead computes that far, as `goto` does.

### 10.4 Shortcuts, Siri and Spotlight

The intents are in the app (`EditTheFutureMac/Intents.swift`) and wait for its scenario to open. A slot is a `SlotEntity`, known by its formula name, which the scenario file keeps, so a shortcut finds it again after the app restarts.

| Intent | Does | Asks first |
|---|---|---|
| Get Value | A slot's value now or at a date, with a dialog ("Savings will be £96,420 in Jan 2030.") and a snippet of its line, from now to the date | No |
| Show Timeline | Shows the panel at a slot and a date. Spotlight runs it when a slot is picked from its results (`OpenIntent`) | No |
| Add Deposit or Withdrawal | Once or repeating, from a date | Yes |
| Change a Parameter | From a date; 4.5 means 4.5% for a percent | Yes |
| Add Reading | A reading of a slot's value, or another of its values by name, for a date or today; 4.5 means 4.5% for a percent | Yes |
| Copy Snapshot | Everything, a picture, PDF, a table or data only | No |

- **Siri phrases** (`EditTheFutureShortcuts`): "What's Savings in Edit The Future", "Show Savings in Edit The Future", "Add a deposit in Edit The Future", "Add a reading in Edit The Future", "Copy a snapshot from Edit The Future". Siri learns the slots' names from `updateAppShortcutParameters()`, called when a scenario opens and when slots change.
- **Spotlight** (macOS 15 and later): the slots are indexed as entities (`IndexedEntity`), and those no longer in the scenario are taken out.
- **A date picked in Shortcuts** is the day it falls on in the Mac's time zone, as a UTC date for the engine (`PartialDate(day:in:)`).
- **Asking first:** editing intents check the event (`ScenarioStore.describe`), ask with Shortcuts' own confirmation, then add it. The app's own alert isn't used for them.
- **Building:** Xcode makes the app's `Metadata.appintents` from constant values the compiler records. SwiftPM doesn't, so `Package.swift` asks the compiler for them on the app's module (`-emit-const-values`, with the protocols in `scripts/appintents-protocols.json`), and `scripts/build-app.sh` runs Xcode's `appintentsmetadataprocessor` on them. Without Xcode selected, the app builds without its intents.

## 11. Clipboard and export

One keystroke writes several representations at once, and the pasting app picks the one it understands:

| Representation | Pastes into |
|---|---|
| PNG (from `ImageRenderer`) | Chat apps, image editors |
| PDF (vector) | Keynote, Pages, documents |
| Tab-separated text of the visible data | Numbers, Excel, Google Sheets (as a table) |
| `com.editthefuture.snapshot` (JSON) | Another Edit The Future window (recreates the view) |

Default shortcuts: Command-C copies a snapshot of the visible range, Command-Shift-C copies the data. Dragging out of the window offers the same formats through `Transferable`.

## 12. Peripherals

### 12.1 Principles

- The app doesn't care what the device is. A device sends `Command` values, directly or through a mapping profile, and receives `DeviceFeedback`.
- The same command set works across every connection type.
- The engine and command layers have no hardware dependencies. Each platform adapter (CoreMIDI, CoreBluetooth, IOKit) converts to and from these types.

### 12.2 Connection types

| Connection | Mac | iPad | iPhone | Feedback to device | Notes |
|---|---|---|---|---|---|
| Keyboard and mouse (HID) | Yes | Yes | Yes | No | Zero setup; fallback |
| **MIDI over USB and Bluetooth LE** | Yes | Yes | Yes | Yes | **First choice.** No drivers, no MFi, built into CoreMIDI |
| Custom Bluetooth LE service | Yes | Yes | Yes | Yes | Richer data (for example a sparkline on a display) |
| Raw USB (HID or serial) | Yes | M-series iPads only, via DriverKit | No | Yes | iPad needs a driver entitlement |
| Wi-Fi (WebSocket or OSC) | Yes | Yes | Yes | Yes | Also lets an iPhone act as the Mac's controller |

Avoid ExternalAccessory, which requires the MFi program. If raw USB HID is used on the Mac, present a vendor-specific HID usage rather than a keyboard, so the Mac doesn't type stray characters.

### 12.3 MIDI profile (prototype)

Defined in `FutureCommands/MIDI.swift` as `MIDIProfile.prototype`, on MIDI channel 1:

| Control | Message | Command |
|---|---|---|
| Slot buttons 1–8 | Notes 36–43 | `selectSlot(1…8)` |
| Toggle window | Note 44 | `toggleWindow` |
| Peek | Note 45 (on = begin, off = end) | `peek` |
| Now | Note 46 | `jumpToNow` |
| Copy snapshot | Note 47 | `copySnapshot(.all)` |
| Insert event | Note 48 | `insertEventAtCursor` |
| Bank − / + | Notes 49 / 50 | `previousBank` / `nextBank` |
| Wheel mode | Note 51 | Cycles scroll → zoom → each adjustable parameter, sending `setWheelMode` |
| Main wheel | CC 16, relative | Depends on wheel mode: scroll, zoom, or adjust a parameter |
| Zoom knob | CC 17, relative | `zoom` |

- Relative encoders are read as two's complement by default (1 = +1, 127 = −1). Offset-64 and sign-magnitude are also supported.
- **Feedback:** slot LEDs use Note On on the same notes, with velocity as a palette color index. Channel 1 means solid, channel 2 means pulsing (computing). Names and cursor text go in SysEx messages that use the non-commercial manufacturer ID `0x7D`. Register a real manufacturer ID before shipping.
- **CoreMIDI** delivers Universal MIDI Packets (UMP). `MIDIMessage.parse(umpWords:)` handles MIDI 1.0 (type 2) and MIDI 2.0 (type 4) channel voice packets, so the adapter stays thin.

### 12.4 Self-description and learn mode

- **Self-description:** on connect, a device can send a descriptor listing its controls and suggested roles, so it works without setup.
- **Learn mode:** for remapping, or for off-the-shelf controllers. Click a function in the app, then move the control you want to bind to it.

### 12.5 Background behavior

On the Mac, MIDI, Bluetooth and HID input arrive while the app is in the background, so a hardware button can summon the panel. On iOS, a device press can't bring an app to the foreground.

### 12.6 Hardware ideas

- A colored LED per slot, pulsing while that slot computes.
- Wheel haptics, if available: detents that follow the zoom level (months, years), a bump when crossing an event, resistance at "now".
- Wheel modes: scroll time, zoom, or adjust a parameter live (twist the interest rate and watch every linked future update).
- Dedicated summon and peek buttons.

## 13. Security

The goal is to open the app up in every reasonable and secure way. The rules:

1. **Commands are classified as navigation, clipboard or editing.** Each source has a confirmation policy (`Command.requiresConfirmation(from:)`):

   | Source | Navigation | Clipboard | Editing |
   |---|---|---|---|
   | Keyboard, menu, peripheral, CLI | runs | runs | runs |
   | App Intents | runs | runs | confirm |
   | URL scheme | runs | confirm | confirm |
   | Paired device over the network | runs | runs | confirm |

   Any web page can open an `etf://` link, so links can navigate but can't edit data or overwrite the clipboard without confirmation. Plug-ins can never be installed from a URL.
2. **The etf tool:** the app listens on a private Unix socket (10.3): the file is readable and writable only by the user, in a folder only the user can open. Before reading anything, it checks the caller's code signature against its audit token from the kernel (`CallerCheck`): code signed by the app's team, or, in an ad-hoc build without a team, only the exact `etf` inside this app, by its code hash. Requests that are too large, unreadable or out of range are answered with why and never run. A caller that hangs up gets nothing. Without the tool in the bundle (as with `swift run`), the app doesn't listen.
3. **Network:** nothing listens. The app connects out only to paired devices and to the sources of a scenario's feeds (15.8).
   - Paired devices: explicit pairing, TLS-PSK, permissions per capability, revocable. No anonymous HTTP server.
   - Feeds fetch data (CSV and JSON), never code. Answers are capped at 64 MB, and requests have time limits. Cookies and caches aren't kept.
   - **Sign-ins** for feeds (API keys, tokens, usernames and passwords) are kept in the Keychain, never in `scenario.md`, which names a sign-in only by its name. Each sign-in is tied to the hosts it was saved for, and is sent only to them, only over HTTPS, and never through a redirect to another host. So a scenario from someone else can't send your key anywhere else, even by naming it (`credential: fred` on a feed at their own address).
4. **Plug-ins** are sandboxed: WebAssembly gets no file or network access by default, and native plug-ins run in a separate sandboxed process. Data reaches a plug-in only through connections the user created.
5. **Scripts** are the user's own code, so they run in the app's process with guard rails: time and memory limits, Lua without its `os`, `io` and `debug` libraries, and audit hooks that keep Python off the network and from writing files (6.4).
6. **Hardware** can send only commands from the vocabulary. Destructive edits (delete) always need on-screen confirmation.
7. **Siri and Shortcuts** go through App Intents, which have system-level consent. Editing intents ask for confirmation.
8. **Saved scenarios** can come from other people. Opening one runs its scripts (15.1). Its readings can name a database, which the app opens read-only, and only once the user has picked it (15.4). Its feeds are fetched, which tells their sources that someone opened it (17).

## 14. Sources of readings

- CSV or clipboard import, and single readings from the command bar, the etf tool and a Shortcuts "Add Reading" action. Built in November 2026 (UI.md, 5.10): imports of up to 100 readings go in a `csv` block in `scenario.md`, larger ones in a file in `readings/` (15.3).
- SQLite databases, read through a query (15.4)
- Feeds from public sources, fetched as they update (15.8): FRED, the US Treasury, the World Bank, the Bureau of Labor Statistics, NOAA, Open-Meteo, open data portals such as the CDC's, Tiingo, and CSV or JSON at any web address
- HealthKit (weight, for a body-weight model). The data lives on the iPhone, so it can be borrowed through section 7.
- WeatherKit historical weather
- FinanceKit (Apple Card, Apple Cash, Savings; US only, needs an entitlement)
- Market data APIs for securities. FRED has the main US indexes free (the S&P 500 and the Dow for the last 10 years only, under their licences); Tiingo has any ticker with a free key. Others are paid; check their licences.
- Sensors over the hardware or network protocols

## 15. Persistence and sync

Decided and built in October 2026, on the Mac. The code is `FutureDocument` (reading and writing the folder), `FutureFeeds` (fetching feeds, 15.8) and `ScenarioDocument` in `FutureFiles` (saving, reloading, feeds and the cache). Not built yet: sync, iOS and branches.

A scenario is saved as plain text that people can read, edit in any editor and keep in git, the way [KeybowNotes](https://github.com/cwenham/KeybowNotes) keeps its key trees in a Markdown outline. Values the models computed are saved beside it, so slow models don't have to run again.

### 15.1 The scenario folder

Each scenario is a folder with the extension `.etf`. The Mac and iOS show it as one document (a package). Terminal, text editors and git see an ordinary folder.

```
Home & money.etf/
  scenario.md       everything a person writes (15.2)
  readings/         imported history as CSV, and copies of readings from databases and feeds (15.3, 15.4, 15.8)
    sp500.csv
    Rates-fred-DGS10.csv
    exchange-rates.csv  exchange rates the slots convert money at (5.11)
  cache/            values the models computed; safe to delete (15.5)
    Market.etfcache
```

- `scenario.md` is the source of truth. Everything else is either linked from it or can be rebuilt.
- One folder holds one scenario: one group of linked slots.
- **Where scenarios live:** the Scenarios folder, beside the script Libraries folder: `Application Support/Edit The Future/Scenarios` on the Mac, `Documents/Scenarios` on iOS. At launch the app opens the scenario used last. The first time, it writes the built-in "Home & money" there. The scenario menu in the panel's header switches between the scenarios there and makes new ones (UI.md, 3), and Open Scenario… in the menu bar item opens one from anywhere (UI.md, 6).
- **New scenarios** go in the Scenarios folder, in a folder named after the scenario. Slashes and colons in the name become dashes, and leading dots are dropped, so the folder isn't hidden. A new one has one blank formula (a scenario needs at least one slot). A copy takes the folder's `scenario.md` and `readings/`, but not `cache/`, which would have to match the new start anyway.
- **Renaming:** when a scenario is renamed in the app and its folder had the old name, the folder is renamed to match once the change is saved, so Finder and the menu agree. Undo renames it back. The folder keeps its name when it was named something else, or when another folder already has the new name. A name changed in another editor never moves the folder, since that editor has the file open. The app remembers the new place as the one used last. Feeds carry on from the new folder: a fetch that was on its way when the folder moved is dropped rather than making the old folder again.
- **Start date and seed:** they're in the heading (15.2). Changing them in the app is one change, which ⌘Z takes back (UI.md, 3). Either one builds the engine's scenario again.
- **Saving:** changes in the app are saved half a second after they stop, so a burst of changes is one save. Closing a scenario, or quitting, saves too.
- **Changes from other apps:** the app checks `scenario.md` every second. When another editor has saved it, the app reads it again. Reloading goes through the same path as editing slots (4.8, "Slot layouts"), so only the slots that changed compute again.
  - The reload is one change, so ⌘Z takes it back, and the app says so. A new start or seed builds the scenario again, and undo starts afresh.
  - If the app has a change waiting to be saved, the file's version wins; ⌘Z brings the app's change back.
  - While the file can't be read (half-way through an edit, say), the app says why and doesn't save over it. Once it reads again, it loads.
  - The app doesn't write the file back after reading it, unless something in it changed.
- Where the panel was looking (the focused slot, the zoom, the cursor) isn't part of the scenario. Each opening starts at now; remembering it is still to do.
- A scenario from someone else holds their scripts, and opening it runs them. Scripts run with guard rails, not a full sandbox (6.4), so this needs a decision (17).
- In Finder the folder shows as an "Edit The Future scenario" document (the `com.editthefuture.scenario` type, a package), and double-clicking opens it in the app.

### 15.2 scenario.md

````markdown
# Home & money [start: 2022-01-01, seed: 0x5EEDF07E]

Notes can go anywhere, as ordinary text. The rates are the bank's quote from October 2026.

## 1. Savings [Savings account, shows: balance]

```etf
step 1 month
param rate = 4.5% range 0%..15% label "Interest rate"
param monthly = 400 range 0..5000 by 50 label "Monthly deposit" as currency
init balance = 18000 label "Balance" as currency
balance[t] = balance[t-1] * (1 + rate / 12) + monthly
on deposit: balance += event.amount
on withdraw: balance -= event.amount
```

### Values
- monthly: 650

### Events
- 2028-08-01 withdraw [amount: 6000]
- 2030-01-01 set [rate: 3.5%]
- 2027-03-01 deposit [amount: 500, every: 1 month, until: 2035-12-01]

## 2. Market [Market with ups and downs, shows: price, color: FF9F43]

```python
every("1 month")
param("drift", "6%", range=("-10%", "20%"))
init("price", 100)

def step(s, t):
    s.price *= 1 + s.drift / 12 + t.normal(0, 0.04)
```

### Readings
- [S&P 500 monthly closes](readings/sp500.csv)
- S&P 500 daily closes [feed: fred, series: SP500, into: price]

## 5. Kitchen [Room cooling, shows: temp]

```lua
every "1 hour"
param("outside", 10, { label = "Outside", as = "temperature" })
init("temp", 20, { label = "Temperature", as = "temperature" })

function step(s, t)
  s.temp = s.temp + (s.outside - s.temp) * 0.05
end
```

### Readings
- [Kitchen sensor](~/Data/sensors.sqlite)

```sql
select ts as date, temp_c as temp from readings where sensor = 'kitchen'
```
````

| Part | How it's written |
|---|---|
| The scenario | The first heading: the scenario's name, then its settings in brackets. `start` is required. `seed` defaults to the engine's own. `currency` (`GBP`, `EUR`) is what its money is in, and defaults to US dollars. `rates` (`ecb`, `openexchangerates` or `none`) is where exchange rates come from, and defaults to `ecb`; `numbers` (`point-comma` and others) is how numbers are written, and defaults to each currency's own (5.11). |
| A slot | A second-level heading: the slot's position, its name, then its settings in brackets. Positions 1–8 are the first bank (5.8); later banks aren't built yet. A missing number is an empty slot. The first setting in the brackets is the model's name, as the library calls it; it's left out for a model of the slot's own. Then `module` (a simulation module built into the app and its version, `epidemic@1`; 6.5), `shows` (the variable the graph draws), `as` (`number`, `percent`, `currency` or `temperature`), `currency` (a currency of the slot's own) and `color` (hex). Without `shows` the graph draws the model's first output, without `as` it uses that variable's own `as`, and without `currency` it uses the scenario's. |
| The model | The first fenced block in a model's language in the slot's section (not under Readings), exactly as the Formula tab shows it. The block's language gives the kind: `etf` for a formula (6.2), `lua` or `python` for a script (6.4). A part such as Values ends where the model's block starts. A slot with a `module` has no block; one there is kept as written, but not used, and changing a slot to a module takes its block away. |
| The slot's own values | `### Values`: one `- name: value` line for each parameter or starting value that differs from the model's default (6.2). |
| Events | `### Events`: one line per event or recurring rule. |
| Readings | `### Readings`: a `csv` block, a link to a CSV file (15.3), a link to a SQLite database followed by a `sql` block (15.4), or a feed's line (15.8). |
| Links between slots | Nothing extra. They're in the formulas and scripts already (`Climate.temp`). |
| Notes | Any other text, kept as written. |

Branches (5.7) aren't in the format yet. One possibility is a section that lists only what the branch changes, under the same headings (17).

**Brackets** follow KeybowNotes' rules. The final group in square brackets holds the settings, separated by commas. A setting is a `name: value` pair or a single word. Text with commas or brackets in it goes in double quotes, and numbers in brackets have no thousands separators.

**Events:**
- Each line is the date, the event's kind, then its fields in brackets: `- 2028-08-01 withdraw [amount: 6000]`.
- `set` events change parameters: `- 2030-01-01 set [rate: 3.5%]`.
- Recurring rules add `every`, in the formula language's step units (`1 month`, `2 weeks`), and can add `until` (inclusive) or `count`.
- The app writes events in date order, but any order reads.
- Generated events aren't written. They're results, kept in the cache (15.5).

**Currencies:**
- `# Budget [start: 2024-01-01, currency: GBP]` puts the scenario's money in pounds. `## 3. Oil [Hold the latest, currency: USD]` keeps one slot in US dollars whatever the scenario's currency.
- A currency is an ISO 4217 code, in any case. A symbol or name that means one currency reads too (`£`, `euros`), but the app writes codes.
- A slot's currency says how its money is written: its own `18000` is £18,000 in pounds and €18,000 in euros, so changing it relabels its amounts. Money it reads from a slot in another currency is converted at exchange rates (5.11).
- Without `currency` a scenario is in US dollars, which is what every scenario meant before currencies existed. So the app writes `currency` only when it's been chosen, or the file had it.
- A currency that can't be read is reported, kept as written, and US dollars (or the scenario's, for a slot) are used.

**Numbers:**
- A value is written in its quantity: `4.5%` for a percent, a plain number otherwise. Values are read with the command bar's rules, so `1.5k`, `$1200`, `£1200` and `1200 EUR` work too.
- The app writes each number so that it reads back as exactly the same value. When the short form doesn't (0.1 + 0.2), it writes every digit needed: `0.30000000000000004`.
- `inf`, `-inf` and `nan` are allowed, since values can be extreme.

**Dates** are ISO 8601, in UTC like the engine (4.2): `2028-08-01`, `2028-08`, or `2028-08-01T09:30` for steps shorter than a day. Years past 9999 take a sign and more digits, as ISO 8601 allows: `+31000-01-01`.

**Event IDs** aren't written. The engine orders events within a step by their IDs (4.4), so the app derives each one from its slot and its line: the date, kind and fields, and how many identical lines come before it. The same file always gives the same results, and adding notes or moving lines changes nothing.

**Writing back:**
- The app keeps what it doesn't understand: notes, other headings, blank lines, and settings it doesn't know.
- An edit in the app rewrites only the parts whose meaning changed, in one consistent form: a slot's heading, model, values, events or readings. A part written another way that means the same, such as `rate: 0.042` for `4.2%` or `amount: 6e3`, stays as it is. Within a part that changed, the items that didn't change keep their lines.
- `shows` and `as` are written when the file had them, or when they differ from the model's own.
- New slots go before the first slot with a later number, else after the last slot. A slot keeps its place when it's renamed or moved, since it's matched by name, then by number.

**Mistakes** are reported with their line, and only affect what they're in. The app shows the first in its footer, with how many more there are:
- A slot without a model is paused, with the reason, as slots that can't run are paused now (5.9). So is one whose `module` the app hasn't got, or that's newer than the app's. The other slots run.
- A slot heading with a number outside 1–8, a name that isn't one word, or a number or name already used, is kept as written but not used.
- An event or value line that can't be read is skipped and listed, and kept as written.
- Values and readings for variables the model doesn't have are listed.
- A scenario whose first heading or start date can't be read doesn't open, and the app says why (UI.md, 6).

### 15.3 Readings from CSV

- The first column is the date. The others are named after the slot's variables: `date,price`. The header line is required.
- An empty cell means no reading.
- Dates are written as in `scenario.md`.
- Small sets go in a `csv` block under `### Readings`. When importing, the app writes sets of more than 100 rows to a file in `readings/` and links to it (`readings/Savings-Statements.csv`), and readings added one at a time go in the slot's first `csv` block.
- The link's text says where the readings came from.

### 15.4 Readings from SQLite

Readings can come straight from a SQLite database, such as a sensor logger's, Home Assistant's or an export. SQLite is part of macOS and iOS (`import SQLite3`), so this needs no extra package.

- **The link and the query:** a link to the database, then a `sql` block. The query's columns follow the CSV rule: `date` first, then the slot's variable names.
- **Times:** `date` can be ISO text or seconds since 1970. Other forms are converted in the query, such as `ts / 1000.0 as date` for milliseconds. The app compares times as numbers, because SQLite's own date functions stop at the year 9999.
- **Values:** null means no reading. SQLite can't store NaN (it stores null instead), and −0 loses its sign. Neither matters for readings.
- **Read-only:** the app opens the database read-only and refuses `ATTACH` and `PRAGMA`, through an authorizer. Loading extensions stays off. The `sql` block holds one query, which must only read. A query has a time limit of 10 seconds, as scripts have limits. So a query can only read that one database.
- **Paths** are relative to the scenario folder; `~` is the home folder, and a path from `/` is absolute.
- **A copy travels with the scenario:** the app keeps a CSV copy of what it last read in `readings/`, named for the slot and the database (`readings/Kitchen-sensors.csv`). It reads the database, and updates the copy, when the scenario opens and whenever `scenario.md` changes. A scenario opened without the database, on another device or by someone else, uses the copy, and says so.
- **The sandbox.** iOS apps are always sandboxed, and the Mac App Store app will be too (the Mac app isn't yet). Then:
  - The user picks the database once. That gives the app access to it, and it's also consent: a scenario from someone else can't read a database on your device without asking. The app keeps that access (a security-scoped bookmark) in its own settings, not in the scenario.
  - SQLite makes `-wal`, `-shm` or `-journal` files beside a database, which the sandbox blocks. On the Mac, the app declares them as related files (`NSIsRelatedItemType` in its Info.plist). Otherwise it opens the database with `immutable=1` when it won't change while open, or imports a copy.
- **Large sets inside the scenario:** a set too big for CSV (millions of rows) can be a `.sqlite` file in `readings/`. It's read-only once imported.
- **Why CSV stays the default:**
  - A database isn't text. It can't be read or edited in a text editor, and git can't merge it. A `sqlite3 .dump` diff driver makes git's diffs readable, but that's all.
  - SQLite changes its file in place, while document saving (autosave, Versions, Save As) and iCloud Drive copy whole files. Syncing a database while it's open, or without its `-wal` file, can lose data.

  Reading databases avoids both problems. Writing them by default would bring them in.

**What readings do:** they reach the slot's model with each step (`StepContext.readings`, found by binary search), and changing them recomputes from the first reading that changed. Formulas and scripts take them as corrections (4.6). The focused graph draws the readings of the value it shows (UI.md, 2.4).

### 15.5 The cache

Some models take a long time to compute: ensembles (4.6), slow scripts, and remote and plug-in models. Their values are saved in `cache/`, so opening the scenario doesn't run them again.

- **What's kept for each slot:**
  - Its computed values: every column its history keeps (4.8).
  - Its checkpoints (4.3), which let the engine carry on from the end of the cache, or rewind to just before an edit, instead of starting over. A script's state is a list of numbers (6.4), so it saves as easily as a formula's. Plug-ins save theirs through `getState` (6.1).
  - Its generated events.
- **Format:** one file per slot.
  - The first line is a text header in JSON: the file format's version, the fingerprint, the column names, the step rate and start, the number of points, and where the checkpoints and events begin.
  - Then the values and the checkpoints, as little-endian doubles, starting on an 8-byte boundary, followed by the generated events as JSON. Event times and values are written as exact text, since JSON writers don't all keep every digit. Times of points aren't stored, because point *i* is start + *i* × step rate (4.2).
  - The app maps the file into memory and copies the numbers straight into the slot's history.
- **The engine's part:** a model writes its state as numbers and reads it back (`savedNumbers` and `restoredState` on `TimelineModel`; formulas and scripts do). `Scenario.history(of:)` hands out a slot's results and `restore(_:to:)` puts them back. A restored slot carries on, and rewinds for edits, exactly as if it had computed them.
- **Binary, not text:** nobody should edit computed values. Raw doubles keep every value exact, including infinity and NaN. They load at once, and take less than half the space of text. Jupyter notebooks show the cost of the other choice: they keep outputs in the same text file as the code, the diffs get huge, and people strip the outputs before committing.
- **The fingerprint** says what made the values. It's a SHA-256 hash of:
  - the model's kind and text, and the slot's own values
  - the slot's events and readings
  - the scenario's start and seed
  - the engine's version (`Scenario.engineVersion`), a number raised whenever a change to the engine could change results, and the cache format's version
  - for scripts, every file in the Libraries folder for that language (6.4), since a script might import any of them
  - the same for the slots it reads or listens to, however far upstream, including loops through `[t-1]`

  Event ids are part of it, since they order events within a step (4.4). So an event added in the app gets the id reading the file would give it.
- **Using it:** when a scenario opens, the app works out each slot's fingerprint and uses the cache only if it matches. So an edit made in another editor can never show stale values, and a change to Climate retires EnergyBill's cache too. Cache files that no longer match are deleted when the scenario closes.
- **When:** when the scenario closes: on opening another, or on quitting, which waits up to 5 seconds for it. A file that's already there and still matches isn't written again.
- **What gets cached:**
  - Slots that took more than a second to compute. The engine times each slot's steps, not counting the slots it reads; this costs nothing measurable.
  - Remote and plug-in models, whose results may not be reproducible offline.
  - Not formula slots, as a rule: one computes 1,000 years of months in about 40 ms.
  - Not slots that stopped with an error.
- **Size:** the cache holds what the engine has computed, up to 256 MB for each scenario, costliest slots first.
- **Leaving it out:** the cache can be left out of git and sync. Each device rebuilds what it needs.
- **Later:** when only events changed, keep the cache up to the first changed event, the same rule the engine uses for edits (4.3).

### 15.6 Why Markdown

- **Most of a scenario is code.** Fenced blocks hold formulas and scripts exactly as typed, and GitHub, VS Code and Markdown viewers colour them. In YAML they'd be indented strings: a pasted Python script would need re-indenting, and a stray tab breaks the whole file.
- **People type the values.** YAML guesses types from how values look (its "Norway problem", where `NO` becomes false). ETF reads values with the command bar's rules, as it does everywhere else.
- **There's room for notes.** The reasons behind a scenario's assumptions can sit right next to them.
- **It follows KeybowNotes:** headings are sections, numbers are positions, and settings go in a final pair of square brackets. KeybowNotes' parser is shaped around key trees, so ETF needs its own small one.
- **No extra package.** Swift has no YAML parser built in.

### 15.7 Sync

CloudKit across Mac, iPad and iPhone (M5). Not designed yet. Readings linked from a database on one Mac reach other devices through their CSV copy (15.4).

### 15.8 Readings from feeds

Built in October 2026. A feed fetches readings from a public source: market closes, Treasury yields and auction prices, the national debt, consumer prices, temperatures, migration, disease. The app fetches the history once, then checks for new readings as the source updates. The code is `FutureFeeds` (sources, sign-ins, fetching), `FeedSpec` and `FeedCopy` in `FutureDocument`, `FeedEditing` in `FutureKit`, and `FeedCenter` in `FutureFiles`.

**In `scenario.md`**, a feed is one line under `### Readings`: its title, then its settings in brackets, starting with `feed:` and the source.

```markdown
### Readings
- 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent]
- US national debt [feed: treasury, dataset: v2/accounting/od/debt_to_penny, field: tot_pub_debt_out_amt, into: value]
- Statements [feed: csv, url: "https://bank.example/statements.csv", date: Posted, value: Balance, into: balance]
```

| Setting | Meaning |
|---|---|
| `feed` | The source: `fred`, `treasury`, `worldbank`, `bls`, `noaa`, `openmeteo`, `socrata`, `tiingo`, `csv` or `json`. |
| The source's own | What to fetch: `series`, `dataset` and `field`, `indicator` and `country`, `latitude` and `longitude`, `url`… |
| `into` | The slot's variable the readings are of: a parameter, such as `rate`, or a value, such as `balance`. Without it, the variable the graph shows. |
| `convert` | `percent` when the source gives percent points (4.5) and the slot takes a fraction (0.045); `fahrenheit` for °F into °C. Percent points convert exactly: 4.98 becomes 0.0498 as if it were typed. |
| `scale` | A plain multiplier, after `convert`. |
| `every` | How often to check for new readings, in the formula language's units (`1 day`). Without it, as often as the source updates. Never more than hourly. |
| `from` | The earliest reading to fetch. |
| `credential` | A saved sign-in to use, when it isn't the source's own. |

Mistakes in a feed's line are reported with the line, and the feed is skipped, as other mistakes are (15.2).

**The copy.** What a feed fetched is kept in `readings/`, named for the slot and what's fetched: `readings/Rates-fred-DGS10.csv`. A name that lost characters on the way (spaces, colons) gets a short hash, so two feeds never share a copy.
- The copy holds the readings as the source gives them, before `convert` and `scale`, with a `date` and a `value` column. Changing `into`, `convert`, `scale`, `every` or `credential` fetches nothing.
- Opening a scenario reads the copies, so it opens at once and works offline, on another device or for someone else. The copies travel with the scenario and can go in git.
- Renaming a slot takes its feeds' copies along.

**Fetching** (`FeedCenter`):
- When the scenario opens, and whenever its slots change, the app reads each feed's copy off the main thread. A feed with no copy, or whose copy is older than its refresh interval, is fetched. The app also looks for feeds that are due every ten minutes. Refresh Data Feeds in the menu bar item, and the refresh button in the Slot tab, fetch now.
- Fetches run one at a time. Each asks for the readings since 400 days before the latest one in the copy, because sources revise recent readings (consumer prices, yearly figures). The new readings replace the copy's from the first new one on, and older ones stay. The copy is written even when nothing changed, so its date says when it was checked.
- New readings aren't an edit. Nothing in `scenario.md` changes, and undo leaves them: undoing another change keeps the newest readings (`SlotReadings.keepingReadings`). The engine recomputes the slot from the first reading that changed.
- A failed fetch keeps the copy, says why in the Slot tab and the footer, and is tried again within the hour.
- Requests go through `URLSession`, without cookies or a cache, with a 64 MB limit on each answer and up to 200 pages a fetch. Tests answer from fixtures through `FeedTransport`.

**Sources.** Free ones first. Each was checked against the live service in October 2026; `swift run etf-feed --check` checks them again.

| Source | Covers | Sign-in |
|---|---|---|
| FRED (St. Louis Fed) | Market indexes, Treasury yields, mortgage and policy rates, consumer prices, federal debt, 800,000 other series | Optional. Without a key, its CSV download; with a free key, its API |
| US Treasury Fiscal Data | The debt to the penny (daily since 1993), the debt since 1790, average rates on Treasury securities, auction prices and yields | None |
| World Bank | Every country's inflation, net migration, migrant stock, government debt, population, tuberculosis, malaria | None |
| Bureau of Labor Statistics | Consumer prices (CPI), wages, jobs | Optional. Without a key, 10 years a request and 25 a day; a free key goes in the request's body |
| NOAA Climate at a Glance | Monthly temperatures: the globe, hemispheres and continents since 1850, the US and its states since 1895 | None |
| Open-Meteo | Daily weather for any place since 1940 | Optional: a commercial key uses its customer servers |
| Open data portals (Socrata) | Any dataset on data.cdc.gov or another portal, with a filter and sums across rows: emergency visits, hospital patients and wastewater levels for flu, COVID-19 and RSV, by state | Optional app token, in a header |
| Tiingo | Any stock's or fund's daily close | A free key for personal use |
| CSV or JSON at a web address | Anything else | Optional: a key in the address or a header, a bearer token, or a username and password |

Sources left out: Stooq now checks for a browser before its downloads; CMU Delphi's Epidata is moving to a new API; the WHO's data API failed on filtered queries. The setup screen lists 53 ready-made feeds across these sources (`FeedCatalog`).

**Sign-ins** are kept in the Keychain as generic passwords (service `com.editthefuture.feeds`, one item per sign-in, the credential as JSON). A built-in source's sign-in is named after the source (`fred`); a feed at a web address uses its host. Each is tied to its hosts (13.3). Checking whether one is saved reads only its attributes, which never asks the user. The sandbox (when the app has one) needs the outgoing network entitlement.

**A slot of its own.** A feed can be added as a new slot with the "Hold the latest" model (once called "Data series"): `value[t] = value[t-1]`, at the feed's own step. A ready-made feed of money says its currency (`FeedPreset.currency`; all of today's are US dollars), and its slot gets it as its own, so oil stays in dollars in a scenario in pounds, and slots that read it convert it (5.11). Its readings replace the value, so the line follows them through the past and holds the latest one after. The value is 0 until the first reading, when the feed starts after the scenario does. Predict with (8.4) offers other models for the slot, such as Steady growth or Trend line, fitted to its readings and scored on them.

**Running a feed without the app:** `swift run etf-feed "[feed: fred, series: DGS10]" --since 2026-01-01` prints its readings as CSV, using the Keychain's sign-ins; `--key KEY` uses a key just once. `etf-feed treasury10` runs a ready-made feed, `--list` lists them, and `--check` fetches the last 120 days of each one that needs no key.

## 16. Roadmap

| Milestone | Contents |
|---|---|
| M0 (this scaffold) | Engine package: time grids, events, checkpoints, coordinator with connections, event routes and same-step loop checks, goal seek, formula language, command vocabulary, URL scheme, MIDI decoding and profile, tests |
| M1 | Mac app shell: floating panel, hot-key, peek, graph and lanes, docked add-event pane, command bar, multi-format clipboard, URL scheme handling, menu bar item |
| Scripts | Lua and Python models (6.4). Done in October 2026, between M1 and M2. |
| M2 | CoreMIDI adapter and hardware prototype profile; App Intents (Shortcuts, Spotlight, Siri); the command-line tool. App Intents and the `etf` tool are done (10.3, 10.4), the tool through a local socket rather than XPC. The CoreMIDI adapter waits for the hardware. |
| M3 | Drag the future UI; readings import; drift alerts. All done in November 2026, with feeds, direct-insertion assimilation, Refit, Predict with and the automatic pick (15.8, 4.6, 8.4, 8.2, 14, 8.1). Sketching a whole curve (8.1) is left for M5, with Apple Pencil. |
| M4 | WebAssembly host; remote-host protocol; iPhone app with capability borrowing for natural-language events |
| M5 | iPad with Apple Pencil curve sketching; widgets and Control Center controls; CloudKit sync |
| Later | Ensembles and fan charts; FMU import; ExtensionKit plug-ins on Mac; custom Bluetooth LE service |

## 17. Open questions

- Should models run backwards from the start (hindcast, 4.6), so their lines reach back beside the readings? The graph already reaches back to the first reading.
- Should formulas have units, and should they convert automatically?
- How should pinned and suppressed generated events be stored so they survive model edits?
- Ensemble size and progressive refinement budget per frame.
- Market data provider and licensing. FRED and Tiingo for now (15.8).
- Opening a scenario from someone else fetches its feeds, which tells their sources that it was opened. A feed at a web address could point at the scenario's author. Should the app ask first, as for scripts?
- Branch storage: copy-on-write event lists vs a diff log. In the saved file (15.2), should a branch list only what it changes?
- A slot's formula is a copy of the library model. Should a slot offer to update when the library model it came from changes?
- Opening a scenario from someone else runs its scripts (15.1). Should the app ask first, for example when the Mac marks the folder as downloaded?
- Should Refit, or the automatic pick, run on its own when new readings arrive (8.4)? It would change values without a preview, and rewrite `scenario.md` after every fetch. Drift alerts (8.2) now say when a refit is worth a look.
- Should drift alerts check readings of a slot's other values, not only the one its graph shows? And should a slot be able to turn its alerts off?
- Predict with writes the Forecast models around whatever value the readings are of, but only offers library models that have that value (8.4). Should it also offer library models whose value has another name, and point the readings at that value when one is chosen (a feed's `into`, a CSV file's column)?
- Should models be able to read their own past readings (`t.readings` in scripts)? A script could then fit itself, for example with a statistics library.
- Should stochastic models be fitted to their ensemble's median (4.6), rather than to one seeded run?

## 18. Further reading: FMI and co-simulation

In suggested order:

1. **FMI beginners tutorial** (Modelica Association, SIMULTECH 2024): slides and notebooks covering concepts, FMPy, and connecting multiple FMUs. https://github.com/modelica/fmi-beginners-tutorial-2024
2. **FMI 3.0 cheat sheet**: one page of the vocabulary. https://dr-clementcoic.github.io/fmi-cheat-sheet/
3. **FMI 3.0.2 specification**, especially the Co-Simulation chapter (communication points, `fmi3DoStep`, causality). https://fmi-standard.org/docs/3.0.2/
4. **Reference FMUs**: small example models (BouncingBall, VanDerPol and others) with C source. https://github.com/modelica/Reference-FMUs
5. **fmusim tutorial**: run FMUs from the command line. https://modelica.github.io/fmusim/tutorial/
6. **FMI Implementers' Guide**. https://modelica.github.io/fmi-guides/main/fmi-guide/
7. **SSP** (System Structure and Parameterization): the companion standard for wiring several models together, which is the closest match to scenarios. https://ssp-standard.org/docs/2.0
8. **"Co-simulation: State of the art"**, Gomes et al. (2017): the best overview of how co-simulation hosts schedule steps, handle loops and mix step rates. https://arxiv.org/abs/1702.00686
9. **VTI FMI Tutorial**: hands-on exercises with OpenModelica and OMSimulator. https://fmi-tutorial.vti.se/

## 19. Code map

```
CLAUDE.md            briefing loaded by Claude Code sessions
docs/
  DESIGN.md          this document
  UI.md              UI design and mockup index
  HANDOFF.md         where the work stands, for the next session
Package.swift
Sources/
  FutureEngine/      time grids, CivilDate, events, variables, TimelineModel, fields, Scenario (coordinator, parallel groups), wiring checks, goal seek, fitting (misses, slot copies, least squares, Refit), drift checks
  FutureFormula/     formula language: lexer, parser, analysis, resolution to arrays, evaluator, FormulaModel; editing tools (colouring, completion, diagnoses with fixes)
  FutureScript/      Lua and Python scripts (6.4): ScriptModel, ScriptPrograms (loading and sharing), the two runtimes and their preludes (the script API), editing tools
  FutureVisuals/     what backdrops show (9.6), without SwiftUI: BackdropKind and the catalog, BackdropInput, RGBA, Natural Earth's countries (WorldCountriesData.swift) on Equal Earth, the Bright Star Catalogue (BrightStarsData.swift) on Hammer
  FutureSimulation/  the contract simulation modules are built against (6.5): SimulationModule, ModuleReference, data needs and tables, ModuleCatalog, NumericSimulation and NumericModel
  Simulations/       one folder per simulation module, each its own target seeing only FutureEngine and FutureSimulation
    Epidemic/        the Epidemic module (SEIR)
    WorldEpidemic/   the World epidemic module: SEIR in each country, joined by travel
    Worm/            the Internet worm module: random scanning, two-factor, settles
    Catalog/         SimulationCatalog: the modules that come with the app
  CLua/              Lua 5.5.1 from lua.org, without os, io, package and debug, plus etf_lua.c (memory cap, time limit, require)
  CPythonBridge/     etf_python.c: starting CPython, audit hooks, the watchdog for time limits. Built only when Vendor/Python exists.
  FutureCommands/    Command vocabulary, questions and replies, DeviceFeedback, etf:// URL scheme, the etf tool's arguments and printing, the local socket and its caller check, MIDI decoding, profile and feedback
  FutureDocument/    saved scenarios (15): scenario.md's reader and writer, numbers and dates, readings from CSV and SQLite, feeds' lines and copies, cache files, the scenario folder
  FutureFeeds/       feeds (15.8): sources (Providers/), ready-made feeds (FeedCatalog), sign-ins and the Keychain, fetching; tables of readings to import (ImportTable)
  FutureKit/         a scenario to run, edit and read, with no UI (2.1): ScenarioStore, ScenarioEngine (background actor), ScenarioConfiguration, model library, slot, event, feed and formula editing, Predict, Refit, Drag the future, drift alerts, command bar parsing, snapshots' data, answers and edits for the etf tool and Shortcuts (OutsideRequests), the value types views draw (PanelState.swift)
  FutureFiles/       scenarios as .etf folders: ScenarioDocument (saving, reloading, the cache), the Scenarios folder and its scenario menu, FeedCenter and RateCenter
  FutureUI/          the views: panel, Canvas plots, side pane (Event, Slot and Formula tabs), model picker, formula editor, feed setup, scenario menu and form, the backdrops' drawings (Backdrops/), snapshot exporter, scroll mapping
  EditTheFutureMac/  the menu bar app: floating panel, hot-keys, menu bar item, etf:// links, the command router and the socket server, App Intents, drift notifications
  etf-bench/         performance benchmarks (swift run -c release etf-bench)
  etf-script/        runs a script model without the app and prints CSV
  etf/               the command-line tool inside the app: sends one request and prints the reply (10.3)
  etf-feed/          fetches a feed without the app and prints CSV
Vendor/Python/       CPython from BeeWare, fetched by scripts/fetch-python.sh (not in git)
Tests/
  FutureEngineTests/    grids, recurrence, lazy evaluation, invalidation, coupling, loops, event routes, fast paths, parallel groups, least squares, fields from checkpoints, settled models
  FutureFormulaTests/   parsing, parameter options and slot values, wiring checks, editing tools, savings maths, ODEs, coupled scenarios, goal seek, determinism, readings as corrections, fit and Refit, drift
  FutureVisualsTests/   the country table, the projections, shading, points, the star table and the catalog
  FutureSimulationTests/ the module contract: NumericModel's events, readings and saved numbers, references, the catalog's checks, tables
  Simulations/Worm/       the Internet worm against the logistic curve, Code Red's and Slammer's numbers, settling, congestion, cleanup, patching, events, conservation
  Simulations/WorldEpidemic/  the World epidemic on small made-up worlds: one country is Epidemic step for step, spread by distance and size, travel bans, imported cases, vaccines, conservation, links
  Simulations/Epidemic/  the Epidemic module against the final-size equation, early growth, R₀ below 1, vaccination, imported cases, events, extremes and conservation
  FutureScriptTests/    both languages side by side: results, readings as corrections, declarations, events, inputs, randomness, errors and lines, time and memory limits, libraries, Python's audit hooks, fit and Refit; colouring and completion
  FutureCommandsTests/  URL scheme, confirmation policy, the etf tool's arguments, amounts and printing, the wire format, the socket (round trips, refused callers, stale sockets), MIDI parsing and mapping, feedback encoding
  FutureDocumentTests/  scenario.md read and written back, mistakes, numbers and dates; CSV and SQLite readings and their guards; feeds' lines, copies and merging; cache files; restored results
  FutureFeedsTests/     each source's requests and answers (from fixtures), dates and numbers, sign-ins and their hosts, paging, errors, the ready-made feeds
  Support/              FutureTestSupport: dates and scenarios the next three share
  FutureKitTests/       store, configuration, slot editing, formula and script editing, model library, command bar, add-event pane, plot thinning, snapshots' data, requests from the etf tool and Shortcuts, drift alerts, modules' triggers and easing to a new slot's curve
  FutureFilesTests/     scenario documents, the scenario menu and its folder, feeds fetched into a scenario, exchange rates, currencies written and read, readings imported
  FutureUITests/        the mounted panel, overlays, the events strip, the side pane, the editor's text view, the model picker, scroll mapping, easing, the clipboard, each backdrop drawn into an image
scripts/
  build-app.sh       builds .build/EditTheFuture.app, with Python.framework in it when it's fetched, the .etf document type, the etf tool and the App Intents metadata
  appintents-protocols.json  the protocols whose constant values the compiler records for App Intents
  fetch-python.sh    downloads and checks CPython for the Mac and iOS into Vendor/Python
  make-world-countries.py  turns Natural Earth's 1:110m countries (GeoJSON) into the world map's table
  make-bright-stars.py     turns the Yale Bright Star Catalogue into the sky map's table
```

Run the tests with `swift test`.
