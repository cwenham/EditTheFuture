# Handoff

Where the work stands, for the next Claude session. Last updated 2026-10-31, on `feature/intents-and-cli` (branched from `969f7c8` on `main`, not merged yet): App Intents and the `etf` command-line tool, from milestone M2.

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
| `bc8cc29` | Model library and picker, adding, changing, moving and removing slots, the Slot tab, parameter ranges and labels in formulas, paused slots |
| `6764b20` | The formula editor: colouring, completion, insert palette, checks with one-click fixes, preview, apply and revert. The wheel moves time only over the graphs. |
| `85d9ac2` | New features and fixes start on their own branches. |
| `7fd8363` | Lua and Python scripts as models, on the Mac and ready for iOS (DESIGN.md, 6.4). |
| `6a2875b` | The model picker can add script models; `fetch-python.sh` keeps Python in the build. Merged from `feature/scripting`. |
| `8f551cf` | The save format designed: Markdown scenarios, CSV or SQLite readings, a binary cache (DESIGN.md, 15). |
| `8e68250` | Saving built: `.etf` scenario folders with `scenario.md`, outside edits loaded as they're saved, readings from CSV and SQLite, and a cache of slow slots. Merged from `feature/document-format`. |
| `2f244a9` | Python scripts load one at a time, which fixed a flaky libraries test: loads on different threads raced on `sys.path`. |
| `b6d51e4` | Clicking an event's diamond edits it in the Event tab, with Save, Cancel and Delete (UI.md, 5.4). Merged from `feature/edit-events`. |
| `500e406` | Data feeds: readings fetched from public sources and kept up to date, with sign-ins in the Keychain and a setup screen (DESIGN.md 15.8, UI.md 5.10). Readings now correct formulas and scripts (DESIGN.md 4.6) and show on the focused graph. Merged from `feature/data-feeds`. |
| `ca33769` | Predict with, Refit and the automatic pick designed (DESIGN.md 8.4, UI.md 5.11). |
| `cd09c0c` | Fitting in the engine: `fit` on params and inits, misses, a bounded least-squares solver, and Refit on a copy of the slot, in formulas, Lua and Python. |
| `78f4827` | Refit and Predict with in the panel: eight Forecast models (Trend line among them), each scored on readings it didn't see, with the best tagged. Fits use readings from before the scenario's start. Merged from `feature/predict-with`. |
| `dd77c64` | The graph scrolls back before the scenario's start, to the earliest reading, with the part before the start shaded and a dashed "Start" line. |
| `3f2fd0e` | The scenario menu: switching, New, Duplicate and Edit (name, start date and seed) from the scenario's name in the panel. Merged from `feature/scenario-menu` (`b4e39a2`) and `feature/history-before-start`. |
| `969f7c8` | Currencies, exchange rates and regional number styles: a currency for each scenario and slot, money converted between slots at the ECB's daily rates or live ones from Open Exchange Rates, and each currency written in its usual style (DESIGN.md 5.11). Merged from `feature/currencies`. |

Milestones M0 and M1 from DESIGN.md section 16 are done. Of M2, App Intents and the command-line tool are built on `feature/intents-and-cli`; the CoreMIDI adapter waits for the hardware.

## What works

The Mac app, with scenarios saved as plain text (DESIGN.md, 15). The first launch writes the built-in "Home & money" scenario to the Scenarios folder. It has five slots: Savings, Index fund, Mortgage, Climate and Energy bill, which reads Climate's temperature.

- **Saving** (DESIGN.md, 15):
  - A scenario is a `.etf` folder in `~/Library/Application Support/Edit The Future/Scenarios`, holding `scenario.md` (Markdown in KeybowNotes' style), `readings/` and `cache/`. Finder shows it as one document.
  - The app opens the scenario used last, and saves changes half a second after they stop.
  - Edits made to `scenario.md` in another editor show in the panel within a couple of seconds, as one change that ⌘Z takes back. A file that can't be read is reported, and the app doesn't save over it.
  - Writing back keeps notes, unknown settings and lines with mistakes, and rewrites only the parts whose meaning changed.
  - Readings: `csv` blocks, linked CSV files, SQLite databases read through a query (read-only, `ATTACH` and `PRAGMA` refused, 10-second limit), and feeds (below), with a CSV copy kept in `readings/`.
  - Cache: when a scenario closes, slots that took over a second to compute are saved to `cache/` as binary, with a fingerprint of everything that made them. They're used on the next opening only if it still matches.
  - Menu bar item: Open Scenario…, Edit scenario.md, Show Scenario in Finder, Open Scenarios Folder.
  - **The scenario menu** (UI.md 3): clicking the scenario's name in the header lists every scenario in the Scenarios folder, with the open one ticked, and opens the one chosen. New Scenario… (one blank formula), Duplicate… (a copy with its readings), Edit… (name, start date and seed), Show in Finder and Open Other…. The form is a popover from the name. Edit's Save is undoable, a new start date included. Renaming renames the folder when it had the old name (DESIGN.md 15.1).

- **Data feeds** (DESIGN.md 15.8, UI.md 5.10):
  - A feed is a line under a slot's `### Readings`: `- 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent]`. `into` picks the parameter or value; `convert` turns percent points into fractions or °F into °C.
  - Ten sources (`FutureFeeds/Providers`): FRED, US Treasury Fiscal Data, World Bank, BLS, NOAA Climate at a Glance, Open-Meteo, Socrata open data portals (the CDC's), Tiingo, and CSV or JSON at any web address. 53 ready-made feeds across markets, rates and bonds, debt, inflation, climate, migration and disease (`FeedCatalog`). All but Tiingo work without a key.
  - `FeedCenter` (owned by `ScenarioDocument`) reads each feed's copy in `readings/` when the scenario opens, fetches feeds with no copy or an old one, and checks every ten minutes. Each fetch asks for the readings since 400 days before the latest, and merges. New readings go to the engine without being an edit; undo keeps them. A failed fetch keeps the copy and says why.
  - Sign-ins (API key, key in a header, bearer token, username and password) are kept in the Keychain (`KeychainCredentialStore`), never in `scenario.md`, and sent only to the hosts they were saved for, over HTTPS, and not through redirects to other hosts.
  - The feed setup screen: Add a feed… in the Slot tab's new Readings section, Edit… on a feed, Add a data feed… on an empty chip, and Data feed… in the model picker. Categories, ready-made feeds, the source's settings, how to use the readings, the sign-in with a box to paste a key, and Test, which fetches a year of readings without adding anything.
  - A feed in a slot of its own gets the "Hold the latest" model, once called "Data series" (`value[t] = value[t-1]` at the feed's step), which follows the readings and holds the latest.
  - Menu bar item: Refresh Data Feeds. `swift run etf-feed` fetches a feed without the app.
- **Currencies** (DESIGN.md 5.11 and 15.2, UI.md 3 and 5.7):
  - A scenario has a currency (`# Budget [start: 2024-01-01, currency: GBP]`), chosen in the scenario menu's Edit…, New… and Duplicate… forms. Without one it's in US dollars, as every scenario was before. New scenarios take the open scenario's; the built-in "Home & money" starts in the Mac's own (`Currency.local`).
  - A slot can have its own (`## 3. Oil [Hold the latest, currency: USD]`), from the Slot tab's Currency menu, which shows when anything in the slot is money. Ready-made feeds in US dollars get their slot in dollars.
  - Formulas and scripts are unchanged: `as currency` means the slot's currency, so every Money model works in any currency.
  - A slot's own amounts are relabelled, not converted: £18,000 becomes 18.000 €. Everything that wrote "$" now writes the slot's currency: axes, readouts, lanes, parameters and sliders, event labels, command bar messages, Predict with and Refit, the model picker, and the copied table's headings ("Savings (balance, GBP)").
  - **Exchange rates** (DESIGN.md 5.11): money a slot reads from a slot in another currency is converted in the engine at each step's rate, for formulas, Lua and Python alike, and in Refit and Predict with's copies. Rates come from the European Central Bank through Frankfurter (free, daily since 1999, about 30 currencies), optionally with live rates from Open Exchange Rates on top (App ID in the Keychain, sent in a header, checked every 10 minutes), or not at all (`rates: none`). They're kept in `readings/exchange-rates.csv` and `exchange-rates-live.csv`, read when the scenario opens, and fetched again when due by `RateCenter`. New rates compute again only the slots that convert, from where the rates changed. A slot without the rates it needs waits, paused, with its readers. The Slot tab says what's converted and at what rate; the lane says `($→£)`. `swift run etf-feed --rates GBP,EUR [--live]`.
  - **Regional styles:** each currency is written the way it usually is (`1.234,56 €`, `1 234 kr`, `CHF 1’234.56`, `₹12,34,567`), and each slot in its currency's style: money, numbers, percents and temperatures. Currencies that share a local symbol in one scenario use the ones that tell them apart (`$` and `CA$`). `numbers:` chooses one style for all. Typed numbers are read in the slot's style, in the command bar, the Slot tab and the Event tab.
  - Typing: `£500`, `500€`, `2k EUR`, `500 pounds` in the command bar, the Slot tab, the Event tab and `scenario.md`. A currency typed must be the slot's: `goto savings $5` and `+€500` on a slot in pounds say so instead of acting.
  - About 40 currencies in the menus (`Currency.common`); any ISO 4217 code works in `scenario.md`, written with its code ("HNL 1,200").
- **Readings correct models** (DESIGN.md 4.6): direct insertion, the same for formulas, Lua and Python. A reading of a parameter sets it at its step, as a `set` event would; a reading of a value replaces what the step worked out. The start takes the latest readings before it. `Scenario.engineVersion` is now 2, so older caches are recomputed.
- **Fitting to readings, and choosing models** (DESIGN.md 8.4):
  - `fit` marks a param or init as one Refit may change: `param growth = 3% range -50%..100% fit`, `{ fit = true }` in Lua, `fit=True` in Python. It becomes `Variable.fittable`.
  - Formulas and scripts report what each step worked out before a reading replaced it (`doStep(_:_:replaced:)`, `Prediction`). A scenario with `recordsMisses` on keeps them as `Miss`es.
  - `Scenario.refit(slot, FitSettings(values:since:))` fits values to the slot's readings with Levenberg–Marquardt (`LeastSquares`), from the slot's own values and from the middle of each range. It runs on a copy of the slot (`copyForFitting`, then `SlotCopy.fit` on any thread), with recordings of the slots it reads, and never changes the scenario. The `FitOutcome` has the values, the typical miss before and after, and whether it improved.
  - Fits use readings from before the scenario's start: runs start at the slot's first reading (`SlotCopy.runStart`), unless the slot reads other slots or a starting value is fitted. `days` still counts from the scenario's start (`Scenario.origin`).
  - Misses are ratios when every reading is above zero, and differences otherwise, and always differences for temperatures and percents. A value's first reading after the start isn't counted.
  - `SlotCopy.score(variable, settings)` is the automatic pick's score: fits at cut-offs of 60%, 70% and 80% of the span, projects from four points after each, and gives the typical miss on the hidden readings, then fits to every reading for the values. `SlotCopy.replacingModel` tries another model on the same slot.
  - **Refit in the panel** (UI.md 5.11): Refit… in the Slot tab, for a slot with readings of a value, opens a sheet with a box for each value that may change, a menu for which readings count, and the result: each value's change and the typical miss before and after. The fitted line shows dashed. Apply (⌘↩) makes the values the slot's own, undoably; Cancel (Esc) drops them. `refit` and `refit savings` in the command bar. The fit runs on a task of its own, so the panel keeps scrolling.
  - **The Forecast models** (`ForecastModels.swift`): Hold the latest, Steady change, Steady growth, Recent change, Recent growth, Trend line, S-curve and Seasonal, written around whichever value a slot's readings are of, each with a first guess from the readings. A Forecast category in the model picker.
  - **Predict with in the panel** (UI.md 5.11): for a slot with readings, the Slot tab's model name opens a popover listing the slot's own model, the Forecast models and matching library models. Each is fitted and scored on readings it didn't see, one at a time off the main thread, with the best tagged (lowest score; within a tenth of it, fewest fitted values). Hovering or ↑ and ↓ preview a model's fitted line dashed and its held-back projection dotted. Click or ↩ chooses it, undoably. A Which readings menu, Use the best, and `predict data with trend line` or `with best` in the command bar. Scores are kept until the model, values or readings change.
  - `swift run -c release etf-bench predict readings.csv [step day] [since 1976-01-01]` scores the Forecast models on a feed's saved readings. Europe's temperatures pick Trend line, US debt Steady growth, the S&P 500 Recent growth.
- **Readings on the graph** (UI.md 2.4): the focused graph draws readings of the value it shows as dots on a thin line (just the line when they're dense), and the readout says "Reading" over them.
- **Before the start** (UI.md 2.4, 5.1): the view and cursor reach back to the earliest reading a slot's graph shows (`ScenarioStore.earliest`), not just to the scenario's start. Before the start the plots are shaded, a dashed line labelled "Start · Jan 2022" marks where the models' lines begin, and the readout shows the reading at the cursor or "Before the start".
- **The panel:**
  - Floating `NSPanel`. ⌃⌥Space toggles it, and holding it peeks.
  - ⌃⌥C copies a snapshot, and ⌃⌥E opens the panel ready to add an event.
  - Menu bar item.
  - Moves only by dragging its top bar.
- **The timeline:**
  - A focused graph plus a lane for each other slot.
  - A cursor that follows the pointer, with readouts. After a command places it (a link, `goto`, Now, the arrow keys), it stays put until the pointer moves (UI.md 5.1).
  - Generated events (Heatwave) on the events strip.
- **Scrolling and zooming:**
  - On a two-wheel mouse, the horizontal wheel scrolls and the vertical wheel zooms. The second wheel is detected automatically, and the menu has a toggle to override that.
  - On a one-wheel mouse, the wheel scrolls and Shift + wheel zooms.
  - Trackpads swipe to scroll and pinch to zoom.
  - Scrolling carries the cursor along.
  - The wheel and swipes move time only over the graphs and lanes (`ScenarioStore.timelineFrame`). Elsewhere they scroll what's under the pointer, like the formula editor.
- **Keys:** ← → (⇧ moves a year), T for now, E to add an event at the cursor, 1–8 to focus the slot at that position, ⌘I for the Slot tab, ⌥⌘I for the Formula tab, + − to zoom.
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
- **Side pane:** docked left or right; drag its title bar to swap sides. Three tabs:
  - **Slot** (⌘I): name, model, parameters with sliders and typed values, starting values, which output the graph shows, format, color, Duplicate and Remove. Dragging a slider shows a dashed preview; letting go applies it.
  - **Formula** (⌥⌘I, UI.md 5.7): the formula editor. Line numbers and colouring; a completion list as you type; a palette of functions, built-ins and other slots' values to click in; checks 300 ms after typing stops, with underlines and one-click fixes; a dashed preview; Apply (⌘↩, undoable) and Revert. Drafts are kept per slot.
  - **Event:** adding events, below.
- **Blank formula** in the picker starts a small formula and opens the Formula tab.
- **Scripts** (DESIGN.md 6.4, UI.md 5.7):
  - Lua 5.5 and Python 3.14 models, with the same API in both. A script declares `every`, `param`, `init`, `output`, `input`, `emits` and `on`, and a `step(s, t)` function. The app keeps the state as numbers.
  - Lua is compiled in (`CLua`). Python is BeeWare's CPython framework, bundled in the app by `scripts/build-app.sh`. Neither has pip.
  - Library models: Predator and prey (Lua), Market with ups and downs (Python), and blank Lua and Python scripts.
  - The Formula tab edits scripts: colouring, completion, the insert palette, checks with lines (including errors the preview raises), wiring fixes inside reference strings, apply and revert.
  - A script that errors while running stops there, with "Stopped" on the graph and the error in the footer and the Formula tab.
  - Guard rails: time limits on every call, Lua's memory cap and missing `os`, `io` and `debug` libraries, and Python audit hooks against the network, processes, `ctypes` and writing files.
  - Libraries: Lua and Python files in the Libraries folder, opened and reloaded from the menu bar item.
  - `swift run etf-script model.lua` runs a script model on its own and prints CSV.
- **Add-event pane (the Event tab):**
  - The date defaults to now, and clicking the graph picks a date.
  - Deposit, withdraw or set a parameter, once or repeating.
  - A live preview of the effect.
- **Editing events** (UI.md, 5.4): clicking a one-off event's diamond loads it into the Event tab. Save replaces it (one undoable change, with the id reading the file would give it), Cancel leaves it, and Delete… asks first. The preview leaves the old event out. `EventEditing.swift`.
- **Command bar (⌘K):**
  - Adding: `+500 monthly from 2027-03`, `set rate 4% from 2027-06`.
  - Moving: `goto 2035`, `goto 100°C`, `goto mortgage $0`, `now`.
  - Slots: `focus savings`, `add savings account`, `add loan to 7`, `remove climate`.
  - Other: `copy`, `copy data`, `undo`, `redo`.
- **Clipboard:** PNG, PDF, a tab-separated table and the app's own JSON, all in one copy.
- **`etf://` links:** `show`, `now`, `toggle`, `select`, `scroll`, `zoom`, `copy`. Commands that edit, sent from outside the app, ask for confirmation.
- **The `etf` tool** (DESIGN.md 10.3, UI.md 4.4): inside the app at `Contents/MacOS/etf`. `status`, `slots`, `value`, `data` (CSV), `show`, `goto`, `focus`, `now`, `toggle`, `scroll`, `zoom`, `deposit`, `withdraw`, `set`, `event add`, `add`, `remove`, `undo`, `redo`, `copy`; `--json`, `--number`, `--no-launch`, `--timeout`. It talks to the app through a private socket (`~/Library/Application Support/Edit The Future/commands.sock`), and the app checks the caller is that exact `etf` by its code hash (or the same team, once signed with one). When the app isn't running, `etf` starts it with the panel hidden.
- **Shortcuts, Siri and Spotlight** (DESIGN.md 10.4): Get Value (with a dialog and a snippet of the line), Show Timeline (an `OpenIntent`, so Spotlight can open a slot), Add Deposit or Withdrawal, Change a Parameter (both ask first), Copy Snapshot. A `SlotEntity` for each slot, by formula name. Four App Shortcuts with Siri phrases. Slots indexed in Spotlight on macOS 15. `scripts/build-app.sh` makes `Metadata.appintents` with Xcode's `appintentsmetadataprocessor`.
- **The command vocabulary** gained `goto`, `addEvent`, `addModel` and `removeSlot`, and questions (`Query`: status, slots, value, series). Everything from outside is checked for range (`isWellFormed`) and answered with a `Reply`.
- **Speed:**
  - The engine runs on its own thread and fetches ahead in the scroll direction.
  - Slot groups run on separate cores.
  - The main thread only draws.

## Not built yet

- **More for saving** (DESIGN.md, 15):
  - Deleting a scenario from the panel. For now, move its folder to the Trash in Finder.
  - Remembering where the panel was looking for each scenario.
  - Better assimilation than direct insertion (nudging, Kalman filters), and drift alerts (UI.md 5.6).
  - Readings in the lanes, and the Readings toggle in the focus area (UI.md, 3).
  - Asking before running scripts from a scenario someone else made (DESIGN.md, 17).
  - Sync, iOS documents, branches, and the sandbox's related-files declaration for SQLite.
- **More for currencies:**
  - Converting readings and events: a feed in dollars into a slot in pounds is relabelled, not converted, and so are events sent between slots. Feeds could say their currency (`[feed: fred, …, currency: USD]`) and be converted as slots are.
  - Rates before 1999, from FRED's H.10 series (`DEXUSUK` and others, daily from 1971), and history for the currencies the ECB doesn't have. Open Exchange Rates' history costs a request a day.
  - Choosing how often live rates are checked, to match the plan. It's every 10 minutes.
  - Regional words for thousands and millions on axes ("Mio."); axes say k, M, B and T in every style.
  - Typing a currency code that isn't in the menu, in the app. For now those go in `scenario.md`.
- **More for programming models:** saving a slot's model to the library ("Your models"), and plug-ins. The picker's Plug-ins category is empty until then.
- **More for scripts** (DESIGN.md, 6.4):
  - An iOS app, and packaging Python's standard library into it (BeeWare's `build/utils.sh`).
  - Native Python packages such as numpy, bundled and tested for each platform.
  - Python in a sandboxed XPC service on the Mac, so a crash in native code can't take the app down.
  - Several steps per call, for speed.
  - The headless runtime and remote slot groups. A server for many users is deferred.
- **From the slot inspector mockup:** Variables, Events and Readings beside the formula, with values at the cursor, and the links view.
- **Panel features from UI.md:**
  - Editing recurring events, and dragging events to move them (5.4). One-off events can be edited by clicking them.
  - Drag the future (5.2). The engine's `GoalSeek` exists.
  - Bands, readings and drift alerts (5.6).
  - Mute and solo, and banks ([ and ]).
  - Click to pin the cursor, and ⌥-scroll to zoom the value axis.
  - Glance HUD and settings.
- **The rest of M2:** a CoreMIDI adapter and the hardware prototype profile, once the hardware is ready. MIDI decoding and the profile already exist in `FutureCommands/MIDI.swift`; `CommandRouter` answers the hardware's commands (`setWheelMode`, `adjustParameter`, banks, mute and solo) with "comes later" for now.
- **More for the etf tool and Shortcuts:**
  - `refit` and `predict` from outside (UI.md 5.11 plans them, asking first).
  - A Shortcuts "Add reading" action (DESIGN.md 14), opening another scenario, and Siri answers for dates ("in 2030"): Siri phrases can only hold slots, so Siri asks for the date or uses now.
  - An installer for `etf` on the PATH. For now, link it: `ln -s "$PWD/.build/EditTheFuture.app/Contents/MacOS/etf" /usr/local/bin/etf`.
  - XPC in place of the socket, if the app gets a Developer ID and a launch agent is wanted (DESIGN.md 10.3).
- **Later milestones:** iPhone and iPad apps, widgets, plug-in hosts (WebAssembly, remote, ExtensionKit), FMU import, ensembles.

## Loose ends

- **Data feeds:**
  - Checked in the real app: opening a scenario with two feeds fetched the debt since 1993 (8,420 readings) and the 10-year yield since 1962 (16,188) into `readings/`, and the panel drew the debt with "Reading" in the readout. The feed setup screen, the Slot tab's Readings section and the dots were checked in offscreen renders, not by clicking in the app. Not checked by hand: the popovers opening from the Slot tab, the empty chip's menu and the model picker; Test; saving a sign-in.
  - **The Keychain and ad-hoc signing:** `build-app.sh` signs with `-`, so each build is a different app to the Keychain. After a rebuild, macOS may ask before the app can read a sign-in it saved. Not seen yet, since no sign-in was saved in the app. Tests use `MemoryCredentialStore`.
  - Opening a scenario from someone else fetches its feeds, which tells the sources (DESIGN.md 17). A feed's address could be the author's own.
  - The World Bank seems to ignore the `date` range, so each refresh fetches the whole series. It's small, and merging handles it.
  - Open-Meteo counts a long range as many calls. The ready-made feeds start in 1990, about 900 calls' worth of the free 10,000 a day, once.
  - BLS without a key allows 25 requests a day, and fetches 10 years a request. The first fetch of 30 years is three requests.
  - Some sources from the request didn't make it: Stooq now checks for a browser (bot detection), CMU Delphi's Epidata is moving to a new API (retired for data after 2026-09-22), the WHO's API failed on filtered queries, and the World Bank's refugee indicator is gone.
  - NOAA's CO₂ file (gml.noaa.gov) was down once during `etf-feed --check`, and fine with curl earlier.
  - A data series' value is 0 until its first reading, when the feed starts after the scenario does.
  - The zoom stops at about 18 months, where daily readings are too dense for dots. Monthly and weekly ones show dots.
  - The sandboxed app (Mac App Store) will need the outgoing network entitlement (`com.apple.security.network.client`).

- **Fitting:**
  - The app's scenario doesn't keep misses (`recordsMisses` is off), because saved results (`SlotCache`) don't include them. Drift alerts will need both.
  - Refit takes the slots a slot reads as they are. A loop back through another slot isn't refitted.
  - A differential equation makes each try slow in debug builds: an S-curve over 15 years of months took 2.6 seconds in a test. Release builds are much faster, but this wasn't measured.
  - Refit in the panel was checked in tests and offscreen renders of the real panel (the sheet, the Refit… link, the dashed line), not by clicking in the app. Not checked by hand: Esc and ⌘↩ reaching the sheet's buttons in the floating panel, and the readings menu.
  - The sheet and the Predict with menu don't notice new readings arriving while they're open; closing and opening again fits to them.
  - Predict with: ↑ and ↓ rely on the popover taking keyboard focus in the floating panel, and Esc and ↩ on its Cancel and Use buttons. Comparing every model takes about 30 seconds for 30 years of daily readings (US debt), most of it Seasonal's; ideas are in DESIGN.md 8.4, Later.
  - Recent change and Recent growth learn a change per step from each reading, so readings much sparser than the step (yearly readings in a monthly slot) make them overreact. Their smoothing often settles at its lowest, 0.1%, on noisy monthly data.
  - Forecast models' values that only readings can size (a trend line's level, a change per year) have no range, so the Slot tab shows them without a slider.
  - Fitting several values with readings of different values adds their misses together. Differences in different units could outweigh each other; ratios don't.
- **Currencies:**
  - Checked in tests and in offscreen renders of the real panel (the Slot tab's Currency menu, a lane in dollars beside slots in pounds) and the Edit form. Not checked by clicking in the app: the two menus opening from the floating panel.
  - A currency changed in another editor isn't part of the reload's undo, as a new name isn't: ⌘Z after an outside edit puts the slots back but keeps the new currency.
  - Symbols are fixed English ones (CA$, A$, CN¥), not the region's: a Canadian sees "CA$" for their own dollars. That keeps a file reading the same on every Mac.
  - VoiceOver's lane reading in UI.md 11 still says "dollars"; it isn't built yet.
  - Exchange rates were checked against the live services with `etf-feed --rates` (Frankfurter's rates, and Open Exchange Rates' answer to a wrong App ID), in tests from fixtures, and in the real app: a scenario in pounds with a slot in US dollars fetched 7,124 days of rates into `readings/exchange-rates.csv` within seconds, and drew the converted line. No real App ID was tried: the live path's success was only tested from a fixture. The Slot tab's note and the form's new fields were checked in offscreen renders, not by clicking in the app.
  - A slot going from waiting for rates to running rebuilds the engine's scenario, as unpausing a slot does, so every slot computes again once. With the copy in `readings/`, that only happens the first time a currency is needed.
  - Live rates are a single latest point per currency. Between the ECB's daily rates and the live one, the live one is used from its time on, so today's readout follows the live rate.
  - A 4,300-request month assumes the scenario is open around the clock; the free plan's 1,000 runs out in about a week of that.
- **The scenario menu:**
  - Checked in tests and in captures of the real menu and popover on screen in a throwaway test. Not checked by clicking in the app: the menu opening from the floating panel, typing in the form, Esc and ↩ reaching its buttons, and switching from the menu.
  - A new start date goes through `rebuild`, then `refreshSlots`, whose `updateEarliest` keeps the view and cursor within reach: back to the earliest reading when there are readings before the start.
  - Undoing a later start date doesn't scroll the view back: it stays where the new start put it.
  - The start date is a date picker in the system's date order, in UTC like the engine. Years past 9999 can be typed in `scenario.md`, not in the picker.
- `README.md` still describes only the engine package.
- **Editing events:** clicking a diamond and the steady pointing hand over it were checked by hand on macOS 15. Not checked by hand: Esc reaching the pane's Cancel button in the floating panel, and the pointer on macOS 14, which uses `NSCursor` push and pop instead of `.pointerStyle(.link)`.
- `goto` with a value, and adding and removing slots, are now in the `Command` vocabulary and the `etf` tool, but not in `etf://` links. Changing a slot's model isn't in either.
- **The etf tool and Shortcuts:**
  - Checked in tests (the tool's arguments and printing, the wire format, real socket round trips, a refused caller, an Apple-signed `nc` let through by a code-signing requirement, stale sockets, the store's answers and edits on the demo and runaway scenarios) and in the real app with a scratch copy of a scenario: `etf` started the app hidden in about 2.4 seconds, read values and CSV, added a monthly deposit, refused a deposit in the wrong currency, set a rate, found where Savings reaches £1m, and undid back to the file as it was.
  - **Not seen in Shortcuts yet.** The bundle's `Metadata.appintents` lists all five intents and the slot entity, and `linkd` (the daemon that runs App Intents) connected to the app as it launched, but the actions weren't looked at in the Shortcuts app, nor Siri's phrases, the snippet, the confirmations, or Spotlight's results. Computer use gets Shortcuts only for clicking (no typing), its Gallery doesn't list apps' actions, and its action catalogue (`~/Library/Shortcuts/ToolKit`) is privacy-protected. To check: in Shortcuts, make a new shortcut and search the actions for "Edit The Future".
  - On macOS 14 the editing intents ask with `requestConfirmation(result:confirmationActionName:)`, which is deprecated (the build warns); macOS 15 uses the new one.
  - An ad-hoc rebuild changes the bundled `etf`'s hash, so an `etf` from an older build can't talk to a newer app, and says so. A link on the PATH to the bundle's copy always matches.
  - `CallerCheck.forApp` trusts the same team's code once the app is signed with a team. With a Developer ID, it may be worth also pinning the identifier `com.editthefuture.etf`.
  - The intents' Siri phrases aren't localized (`--no-app-shortcuts-localization`).
- Not checked by hand in the app: dragging chips onto another number, the chip context menus, and typing in the formula editor (completion keys, palette clicks, ⌘↩). The editor's text view was driven in tests (typing, completion, accepting, Esc) and rendered offscreen. Computer use can't find the app, so they were checked only in tests and offscreen renders. The picker popover was checked in an on-screen non-activating panel in a throwaway test.
- A slider can't be cancelled with Esc while it's being dragged: the slider's tracking loop holds the keyboard until the mouse is let go. Undo covers it.
- The picker's preview only works for models that don't read other slots.
- `etf://show?at=` accepts only four-digit years, so links can't reach past 9999, although scrolling can.
- On the time axis, the leftmost year label is half clipped, and the cursor's date flag hides the label under it.
- The engine keeps every step from the scenario's start. Memory grows with distance: about 100 MB at the year 31,000, engine only.
- Each fetch filters all of a slot's generated events from the start. That's fine at today's sizes.
- DESIGN.md 4.8 lists engine work not done yet: pipelining inside a slot group, and remote and WebAssembly models off the main actor.
- **Scripts:**
  - Not checked by hand in the app: typing a script, its completion list and palette clicks. The panel was rendered offscreen with Lua and Python scripts in the Formula tab, and the app was checked to load the bundled Python.
  - Building a slot's model loads its script on the main thread, as compiling a formula does. That's well under a millisecond for Lua, but Python's first start takes a moment. The Mac app starts Python on a background thread at launch to hide it.
  - Python slots take turns on the GIL, while formula and Lua slots still run on other cores.
  - A script's state is numbers only. Lists of numbers in the state would need the history and checkpoints to handle them.
  - The time limit counts wall time, so a very busy Mac could stop a slow script call early. One test hit the default 2 seconds while a first-time `import` ran under full load; that test now has a longer limit.
  - `FutureUI` imports AppKit, so only `FutureEngine`, `FutureFormula` and `FutureScript` build for iOS so far.
  - Python's bundled packages are the standard library only.
  - A library imported inside `step`, rather than at the top of the script, can still fail now and then: another script loading at that moment takes the library's modules out of `sys.modules` to import them afresh. Imports at the top happen while loading, one script at a time, so they're safe.

## How the code fits together

| Module | Key parts |
|---|---|
| `FutureEngine` | `Currency` (ISO 4217 codes, symbols, names, each one's regional style, and reading them from typed text), `NumberStyle` and `MoneyWriting`; `ExchangeRates`, `ExchangeRateSource` and `CurrencyPair` (DESIGN.md 5.11): `Scenario` converts money between slots in different currencies (`setCurrency`, `setExchangeRates`, `conversions(into:)`). `Fitting.swift`: `Miss`, `SlotCopy` (a slot copied with recordings of the slots it reads, `RecordedModel`), `LeastSquares` and `Scenario.refit` (DESIGN.md 8.4). `Wiring.check` decides which slots can run before a scenario is built. `Scenario`, the coordinator. It evaluates lazily, keeps checkpoints every 32 steps, invalidates downstream, and checks connections for same-step loops (`[t-1]` lags allow feedback). It resamples between step rates, routes events, and runs independent slot groups concurrently in `ensureAll`. Also `SlotRunner` (flat history arrays), `TimeGrid` and `CivilDate` (fast UTC Gregorian maths), and `GoalSeek`. |
| `FutureScript` | Lua and Python scripts (DESIGN.md 6.4). `ScriptModel` (an `AuthoredModel`) keeps the state as numbers. `ScriptPrograms` loads each script once and shares it, behind a lock. `LuaRuntime` and `PythonRuntime` drive the interpreters through `CLua` and `CPythonBridge`. `LuaPrelude` and `PythonPrelude` implement the script API and report declarations as JSON (`ScriptDescription`, checked into a `ScriptShape`). `ScriptTools`: `ScriptHighlighter`, `ScriptCompleter` and `ScriptVocabulary`. |
| `CLua`, `CPythonBridge` | C: Lua 5.5.1 with `etf_lua.c` (sandboxed state, memory cap, time-limit hook, `require`); `etf_python.c` (CPython start, audit hooks, watchdog). `CPythonBridge` is in the package only when `Vendor/Python` exists. |
| `FutureFormula` | The formula language (DESIGN.md 6.2): lexer, parser (with `range`, `by`, `label` and `as` options), analyzer, resolution to array positions (`Executable`), evaluator, and `FormulaModel`, which takes a slot's own values and reports its constant defaults. `FormulaTools`: `FormulaVocabulary` (functions and built-ins with descriptions), `FormulaHighlighter`, `FormulaCompleter` and `FormulaDiagnoser`, all working on half-written text. |
| `FutureCommands` | The `Command` vocabulary (with `EventRequest`, `Amount`, `Repetition`), `etf://` parsing, the confirmation policy, MIDI decoding, the controller profile and feedback. `Request.swift`: `Query`, `Request`, `Reply` and its answers, and `Wire` (versioned JSON, infinity and NaN as text). `CommandLineTool`: the `etf` tool's arguments, amounts and printing. `CommandSocket.swift`: `CommandServer`, `CommandClient`, `Caller` (from the socket's audit token) and `CallerCheck` (code-signing requirements). |
| `FutureDocument` | Saved scenarios (DESIGN.md, 15), with no UI: `ScenarioFormat` reads `scenario.md` into a `ScenarioFile` and writes it back over the text it came from (`ParsedScenario` keeps where each part was). `FileNumber` and `FileDate` write numbers and dates exactly. `EventIdentity` gives events the ids the file would. `ReadingLoader`, `CSVReadings` and `DatabaseReadings` (SQLite) make a `ReadingSet`, with each source's readings apart (`LoadedReadings.parts`). `FeedSpec` is a feed's line, `FeedCopy` its copy in `readings/` and the merging of new readings. `SlotCache` reads and writes cache files; `Fingerprint` hashes. `ScenarioPackage` is the folder. |
| `FutureFeeds` | Feeds (DESIGN.md, 15.8), with no UI: `FeedProvider` and the sources in `Providers/`, `FeedCatalog` (ready-made feeds), `FeedCredential` with `KeychainCredentialStore` and `MemoryCredentialStore`, `FeedFetcher` (sign-ins, hosts, pages, errors) over a `FeedTransport`, `Rates.swift` (exchange rates: `FrankfurterRates`, `OpenExchangeRates`, `RateFetcher`) (`URLSessionTransport`, with a guard on redirects), and `FeedDate`, `FeedNumber`, `JSONPath` and `FeedTable` for what sources send. |
| `FutureUI` | `ScenarioStore` (main actor, `@Observable`) holds the frame, cursor, focus, add-event draft, undo and the command bar, and draws only from the engine's cached results (`computed`). `ScenarioEngine` (an actor on its own serial queue) owns the `Scenario` and runs edits, fetches, previews and `goto` searches in order. Fetches compute four years at a time and stop when a newer fetch is waiting. Also `PanelState` (the value types views draw), Canvas views, `CommandBarParser`, `Formatting` (`ValueFormat`, the kind of value; `ValueStyle`, a format with its currency, which writes values; `niceTicks`, `DateText`) and the snapshot exporter. Slots: `SlotConfig` (the store's record of each slot, replaced whole for undo), `SlotEditing` (the store's slot changes), `ModelLibrary`, and the views `SidePane`, `SlotPane` and `ModelPicker`. Formulas: `FormulaEditing` (drafts, checks, preview, apply) and the views `FormulaPane` and `FormulaEditor` (an `NSTextView` with line numbers and its own completion list). Saving: `ScenarioDocument` (opens a folder off the main thread, saves after changes, checks the file every second, writes the cache on closing, moves the folder after a rename) and `ScenarioLibrary` (the Scenarios folder, new scenarios and copies); `ScenarioMenu.swift` (`ScenarioSettings`, `ScenarioForm`, `ScenarioMenuActions`) and the views in `ScenarioMenuView.swift` (`ScenarioTitle`, the `NSMenu`, `ScenarioFormView`); `ScenarioFileMapping` turns the store into a `ScenarioFile` and back (`reload(from:)`), and works out fingerprints. Money: `Money.swift` (`ScenarioMoney`, `SlotConversion`, conversions, writings, waiting for rates, the Slot tab's note) and `RateCenter` (fetching rates into `readings/`). Feeds: `FeedCenter` (fetching, copies, statuses), `FeedEditing` (adding, changing and removing feeds, a feed's own slot, new readings, readings for drawing), and the views `FeedSetup` and the Slot tab's Readings section. |
| `EditTheFutureMac` | `AppDelegate` (status item, hot-keys, the socket server), `FloatingPanel`, `PanelController` (hosting, keys, scroll mapping, copy), `CommandRouter` (runs `Command`s, asks for confirmation, answers with a `Reply`) and `Outside` (holds requests until a scenario is open), `HotKeyCenter` (Carbon hot-keys). `Intents.swift`: the App Intents, `SlotEntity`, the App Shortcuts and the snippet. |
| `etf-bench` | Benchmarks that render the real panel. |
| `etf` | The command-line tool inside the app: reads its arguments, starts the app if needed, sends one request and prints the reply. |
| `etf-feed` | Fetches a feed without the app and prints CSV; `--list` and `--check` for the ready-made feeds. |

## Checking your work

- **Python:** `scripts/fetch-python.sh` downloads CPython into `Vendor/Python` (not in git). Without it, everything builds and Python slots pause. Re-run it on a new checkout, and whenever a build leaves Python out although the folder is there: Python's tests show as skipped, and the picker says "Python isn't included in this build".
- **iOS:** `FutureScript` builds for iOS, and `etf-script` built for the simulator runs scripts inside it. The commands are in DESIGN.md 6.4.
- **Tests:** `swift test` runs about 445 tests in about 40 seconds. Feed tests never touch the network: they answer from fixtures (`FakeTransport`, `QueuedTransport`) and keep sign-ins in memory.
- **Exchange rates against the live sources:** `swift run etf-feed --rates GBP,EUR --since 2026-10-01` (the ECB, through Frankfurter), and `--live` with `--key` for Open Exchange Rates.
- **Feeds against the live sources:** `swift run etf-feed --check` fetches the last 120 days of every ready-made feed that needs no key, and says which failed. In October 2026 all 45 worked, apart from NOAA's CO₂ server being down once.
- **Feeds in the app:** write a scenario with feed lines in a scratch folder and `open -a .build/EditTheFuture.app "<folder>/Test.etf"`. The copies appear in its `readings/` within seconds. Opening it changes `scenario.lastOpened` in the app's defaults (`defaults read com.editthefuture.mac`), so put it back afterwards.
  - Store tests must `await store.waitUntilIdle()` before reading results.
  - `PanelViewTests` mounts the real panel in a window. Its `.runaway` scenario makes values huge, infinite and NaN within a few years.
- **Benchmarks:** `swift run -c release etf-bench [section]`:
  - Sections: `engine`, `state`, `frames`, `flick [frames]`, `far [year]`, `loop`, `engine-loop`, `cursor-loop [scroll|preview]`.
  - They report main-thread CPU time, which matters more than wall time.
  - Results are noisy when other apps keep the Mac busy, so check `uptime` first.
  - For a fair before-and-after, build the previous commit in a scratch folder: `git archive HEAD | tar -x -C <dir>`.
- **The app:** `scripts/build-app.sh`, then `open .build/EditTheFuture.app`. It's a menu bar app with no Dock icon. To restart it: `pkill -f "EditTheFuture.app/Contents/MacOS/EditTheFuture"`.
  - **In a worktree,** a plain `open "etf://…"` can start the main checkout's copy alongside yours, and the link goes there while your `etf` talks to yours. Send links with `open -a "$PWD/.build/EditTheFuture.app" "etf://…"`.
  - **A resting pointer:** `CGWarpMouseCursorPosition` moves the pointer without sending mouse events, and needs no permission (posting events needs Accessibility). `etf status` then prints the cursor. Ask first: it takes the pointer from the user.
- **Seeing the app.** The computer-use screenshot tool couldn't see the panel, and typing keys through `osascript` wasn't allowed. What worked:
  - Show the panel with a link: `open "etf://show?timeline=savings&at=2060-01"`.
  - Capture the window by ID. Get the ID with a few lines of Swift calling `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)`, filtered on the owner name "Edit The Future". Then run `screencapture -x -o -l <id> out.png`.
  - For states a link can't reach, such as after a command-bar command, render the real panel offscreen in a throwaway test:
    - Put an `NSHostingView(rootView: PanelView(...))` in a 1400×820 `NSWindow`.
    - Run the command and `await store.waitUntilIdle()`.
    - Lay out, display and run the run loop a few times.
    - Write a PNG with `cacheDisplay(in:to:)`.
- **Saving:** the app reads and writes `~/Library/Application Support/Edit The Future/Scenarios`. To check outside edits, change `scenario.md` there while the app runs. Delete the folder to start again from the built-in scenario. In tests, `ScenarioDocument.open(_:now:watch: false)` and `checkFile(force: true)` avoid waiting for the timer, and `ScenarioDocument.cacheThreshold = 0` caches every slot.
- **The etf tool in the app:** after `scripts/build-app.sh`, use `.build/EditTheFuture.app/Contents/MacOS/etf` (a `swift run etf` copy isn't trusted by the app). To try edits without touching a real scenario, copy one to a scratch folder, `open -a "$PWD/.build/EditTheFuture.app" "<folder>/Copy.etf"` (`open -a` needs the app's full path), and put `scenario.lastOpened` back afterwards. `etf status` says which scenario is open.
- **The system log:** in zsh, `log` is a shell builtin; use `/usr/bin/log show`. Default-level lines are rarely kept, so the app's own `NSLog`s and `linkd`'s connections are about all there is.
- **Crash reports:** `~/Library/Logs/DiagnosticReports/EditTheFuture-*.ips`. Everything after the first line is JSON, and the faulting thread's frames are symbolicated.

## Lessons learned

- **Scoring on one cut-off is a lottery for models that carry on from the latest reading.** On noisy readings, how far the last reading before the cut-off was from the trend decides their score. With one cut-off, and then three, Steady change beat Trend line on test data that was a noisy straight line. Twelve projections (three fits, four starting points each) fixed it at little cost, since a projection is one run and a fit is dozens.
- **Starting points matter more than the solver.** A trend line starting at zero, or an ordinary straight line through readings that grew tenfold, works out values at or below zero, which can't be compared with readings above zero as ratios; the solver then has nowhere to start. The Forecast models start from guesses made from the readings, weighted by size where misses are ratios.
- **Observation and short-circuits:** a view redraws only for observed properties its last drawing read. `timelineState()` read `parameterPreview` only after checking `previewSlot`, which isn't observed, so Refit's dashed line didn't appear until something else redrew the graph. Read observed values before any condition that might skip them. The test "The graph redraws when the fitted line arrives" fails without the fix.
- **A reading at the start instant was applied twice:** by the start, which takes the latest readings at or before it, and again by the first step, whose window includes the start for events. The first step then repeated the reading, and fitting saw a miss that wasn't one. Readings at the start now belong only to the start, and `Scenario.engineVersion` is 3.
- **Values get extreme.** Compound interest thousands of years out passes Int.max, then overflows to infinity, then can become NaN. Two crashes came from this.
  - Format values with `ValueStyle`, which switches to scientific notation from 10¹⁵.
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
- **The formula editor's completion list is the app's own,** not AppKit's: AppKit's inserts the selected word when you type on and opens on Esc. `FormulaTextView` handles ↑ ↓ ↩ Tab and Esc while the list shows. To test it, put a `FormulaEditorContainer` in a window and call `insertText` and `accept` on its text view.
- **Checks belong to the text they checked** (`FormulaCheck.text`). The pane says "Checking…" and draws no underlines until the check for the current text arrives.
- **SwiftPM caches the evaluated `Package.swift`,** and the build plan made from it, without knowing that the manifest checks for `Vendor/Python`. After a build without the folder, later builds kept leaving Python out, and Python's tests were silently skipped. `fetch-python.sh` clears the manifest cache and touches `Package.swift`. Check that Python's tests ran, not just that the run passed.
- **The model picker** builds each library model to show its details, and disables Add when that fails. It built every model as a formula, so script models couldn't be added. It now builds them by kind, and says why when a model can't be added.
- **Lua's count hook** makes the VM check on every instruction, which costs about 0.9 µs a step. It's what stops endless loops, so it stays.
- **`String(format:)`** took longer than a whole Lua step. Format hot-path text by hand.
- **Freezing Lua's globals:** `__newindex` only fires for keys that aren't there, so the globals move to a backing table. Keep a local reference to `_G` while doing it: clearing the `_G` key mid-loop made the global lookup return nil.
- **Python audit hooks** run during CPython's own start, when it opens its output streams for writing, so the hook only applies once the start is done. `import ctypes` catches the `PermissionError` from loading a library (it's an `OSError`), so the import itself has to be blocked.
- **A Python time limit** is an async exception set from a watchdog thread, holding the GIL. One that never got raised is cleared at the end of the call, so it can't leak into the next call on that thread.
- **The GIL doesn't make Python code run in one piece.** It passes between threads every few milliseconds and during file reads. "Libraries load from the Libraries folder" failed about one run in three because of two races on the shared `sys.path`:
  - Two scripts loading at once each rewrote `sys.path`, so a load without libraries removed the folder while another load was importing from it. Loads now take a lock in `etf_py_load`, before the GIL, so waiting doesn't hold the GIL or count against the time limit.
  - Taking an entry out of `sys.path` shifts the rest, so an import on another thread that was part-way through the list skipped one, usually the standard library. Each load now gives `sys.path` a new list.
  - The tests "Scripts loading at the same time each find their libraries" and "Scripts loading on other threads don't hide the standard library from imports" fail without each fix.
- **Feeds:**
  - `"abc".contains("")` is false in Swift, so a match-anything test helper matched nothing.
  - `FileDate.parse("202609")` reads the year 202,609, since years can have more digits. `FeedDate` checks forms made only of digits first.
  - 4.98 / 100 is 0.049800000000000004. `convert: percent` lowers the exponent of the number's shortest text instead, so 4.98 becomes 0.0498, as if typed.
  - A segmented picker with four long choices doesn't shrink: it pushed the setup screen's columns off both edges. A menu picker fits.
  - Outside a popover, an offscreen render of the setup screen comes out light. Give the window `.darkAqua` and the view `Theme.panel` behind it.
  - Undo puts back whole slot lists, readings included. Without `keepingReadings`, undoing an unrelated change put back older feed readings.
- **Writing Swift with Python:** a `"\n"` in a Python string becomes a real line break in the Swift file. Use a raw string or `\\n`.
- **The mouse pointer:** SwiftUI's hosting view handles `cursorUpdate:` and `mouseMoved:` and sets the pointer itself (macOS 15). `NSCursor.set()` from a hover handler fights it and flickers. Use `.pointerStyle(...)` on a view under the pointer (`linkPointer()` in `TimelineViews.swift`). Synthetic mouse events in tests don't reach SwiftUI's hover, so the pointer can only be checked by hand.
- **Hover under a still pointer:** `onContinuousHover` reports `.active` under a pointer that hasn't moved, for example when the panel appears under it. So the cursor ignores hover after a command until the pointer moves on screen (`ScenarioStore.pointerHovered(at:fraction:)`, UI.md 5.1). Compare `NSEvent.mouseLocation`, not the hover's location, which shifts when the layout does. Checked with the pointer warped over the graph and the panel hidden: a link to Jan 2030 left the cursor at the pointer's date within 0.2 seconds before the fix, and at Jan 2030 after it. The cursor following again once the pointer moves was checked only in tests, since the pointer can't be moved with events here.
- **SwiftUI's global coordinates start at the window's top,** not the hosting view's: in a window with a title bar they're 28 points lower. Measure in a space named on the panel's root (`PanelView.panelSpace`), which matches `hosting.convert(event.locationInWindow, from: nil)`.
- **Popovers from the panel:** a SwiftUI `.popover` works from the non-activating `NSPanel`. To check one in a test, put the view in an on-screen `NSPanel` (`orderFrontRegardless`) and look for an `_NSPopoverWindow` in `NSApp.windows`; offscreen windows don't show popovers.
- **Removing slots shifts indices.** Undo records refer to slots by their `id`, not their index, and results are remapped by `id` when the list changes.
  - Views must keep a slot's `id` (or the `SlotInfo` itself), never its index, and look the index up when they draw or act (`store.slotIndex(id:)`). After a removal, SwiftUI can draw a child view once more with the inputs its parent gave it last time, before the parent catches up. A chip that kept an index read past the end of `store.slots` and crashed the app when the last slot was removed.
  - The store's slot functions ignore an index with no slot, as a second line of defense.

- **XPC needs launchd to know the name.** `NSXPCListener(machServiceName:)` in an ordinary app fails silently: clients' connections are just invalidated. `bootstrap_check_in` with a new name does work at run time (Chromium relies on it), but gives a raw Mach port, not an XPC listener. Hence the socket (DESIGN.md 10.3).
- **SIGPIPE from a caller that hung up:** macOS refuses `setsockopt` (`SO_NOSIGPIPE`) on a socket whose other end has already closed, so writing a reply to it stopped the whole process with SIGPIPE. It happened when the "is anyone listening?" check connected and closed at once. Now a connection whose option can't be set is closed without a word, and a reset counts as hanging up. The test "A socket left behind is replaced…" stopped the test run without the fix.
- **App Intents without Xcode:** SwiftPM builds the intents' code but not the `Metadata.appintents` Shortcuts reads. The compiler writes the constant values it needs with `-emit-const-values` and a list of protocols (`-const-gather-protocols-file`; the list is in Xcode's `SWBApplePlatform`), and `appintentsmetadataprocessor` takes them with the source list. In release builds the values are one file for the module, in debug builds one per source file.
- **The test runner isn't signed,** so a code-signing check can't let it through. A program Apple signed stands in: `/usr/bin/nc -U` talks to a Unix socket, and `anchor apple` lets it in.
- **Saved scenarios** (DESIGN.md, 15):
  - Folder listings give directory URLs a trailing slash, so two URLs for one folder can differ. `ScenarioPackage` normalizes its URL.
  - JSON writers don't all keep every digit of a `Double`, so the cache writes event times and values as exact text (`FileNumber`).
  - SQLite stores NaN as null and loses the sign of −0, and its date functions stop at the year 9999. Readings treat null as no reading and compare times as numbers.
  - The writer compares meaning, not text, before rewriting a part. Comparing text made the first save rewrite `rate: 0.042` as `4.2%`, and drop or add `shows` and `as`.
  - Event ids order events within a step, so they're part of the fingerprint. Events added in the app get the id reading the file would give them, or the cache would never match after a restart.

## Working with the user

- Asks for commits explicitly ("Commit … with a sensible message"). Commit only then.
  - From 2026-10-26, each new feature or fix starts on its own branch from `main` (`feature/…` or `fix/…`). Commit there when asked, and merge into `main` only when asked. There's no remote. Everything up to `6764b20` went straight to `main`. `feature/scripting` was the first branch, then `feature/document-format`, `feature/edit-events`, `feature/data-feeds`, `feature/predict-with` and `feature/currencies`, all merged by fast-forward. `feature/scenario-menu` and `feature/history-before-start` were merged together in a merge commit.
  - Messages have a plain-language subject, then a body saying what changed and why, with measurements where there are any. They end with the `Co-Authored-By` line.
- Docs are kept in step with the code, written plainly in short sentences.
- Tests the app by hand, thoroughly, and reports crashes. Expect fully zoomed-out views and fast scrolling thousands of years ahead.
- Uses a mouse with two scroll wheels.
- Environment:
  - 2017 iMac Pro: Intel Xeon W-2140B, 8 cores and 16 threads.
  - macOS 15.7.9, Xcode 26.3, Swift 6.2.4.
  - The package uses Swift 6 language mode and targets macOS 14 and iOS 17.
