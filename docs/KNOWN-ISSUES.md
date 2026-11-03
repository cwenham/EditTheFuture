# Known issues

Problems known to be in the app now, with what causes them and what would fix them. Add new ones here, and take them out when they're fixed. Work not built yet is in [HANDOFF.md](HANDOFF.md), under "Not built yet".

## Times in the Event tab follow the Mac's time zone, not the panel's

*Found 2026-11-03.*

The panel shows times in UTC: the time axis, the cursor's date, the readout, and scenario.md. The Event tab's date picker shows the Mac's own time zone instead. So does the start of the day that clicking the graph picks for an event, when zoomed out to more than a few days. A new simulation slot's starting event follows the same rule (UI.md, 5.7).

- **What you see:** nothing in Britain in winter, when the Mac's time is UTC. In British summer time, an event picked by clicking a day, or a simulation's starting event placed while zoomed out, lands at 23:00 the day before as the panel shows it. The date picker says 00:00.
- **Where:** `ScenarioStore.eventDate(near:)` in `EventDraft.swift` uses `Calendar.current`; the date picker in `AddEventPane.swift` has no time zone set.
- **Fix:** pick one time zone for the whole panel. Either give the date picker UTC (`.environment(\.timeZone, …)`) and snap to UTC days, or show the Mac's time zone everywhere.

## The model picker's preview ignores a simulation's trigger

*Found 2026-11-03.*

The picker previews a model over 20 years from the scenario's start, with its defaults. A simulation that something sets off (an outbreak, a worm) begins with a trigger at the cursor once it's added (DESIGN.md, 6.5), but the preview doesn't know that. It shows the module's defaults instead, which start the outbreak at the beginning. A worm, which spreads in hours, previews as a jump at the start and then a flat line.

- **Where:** `TemplatePreview.samples(for:start:)` in `Views/ModelPicker.swift`.
- **Fix:** preview a module with a trigger from the trigger, over the span where its line changes, as adding it does (`ScenarioEngine.curve`).

## A timing test can fail when the whole suite runs

*Found 2026-11-03.*

"Checks wait for typing to pause" (`FormulaEditingTests`) waits up to 10 seconds for a formula check that's due 0.3 seconds after typing stops. In a full `swift test` run, other tests can keep the main thread busy for longer than that, and it failed once in two runs. It passes alone and on a second run.

- **Fix:** let the test wait for the check directly rather than polling against a deadline, or give the check delay to the store so the test can shorten it.
