# Edit The Future

A Swift app (Mac first, then iPad and iPhone) showing an infinite, editable graph of values over time, driven by up to 8 linked models.

**Start with [docs/HANDOFF.md](docs/HANDOFF.md)**: where the work stands, what's next, and how to check your work. The design is in [docs/DESIGN.md](docs/DESIGN.md) and the UI spec in [docs/UI.md](docs/UI.md).

## Commands

- Build: `swift build`
- Test: `swift test` (Swift Testing)
- Benchmarks: `swift run -c release etf-bench [engine|state|frames|flick|far|loop|engine-loop|cursor-loop]`
- App: `scripts/build-app.sh`, then `open .build/EditTheFuture.app`. It's a menu bar app; show the panel with ⌃⌥Space or `open "etf://show?timeline=savings&at=2060-01"`.

## Rules

- **Commits:** commit only when the user asks. Commits go to `main` (there's no remote).
- **Docs:** keep DESIGN.md and UI.md in step with the code, written plainly.
- **Threads:** the main thread never computes. `ScenarioEngine` (an actor) owns the scenario, and `ScenarioStore` draws from its cached results. Tests `await store.waitUntilIdle()` before reading results.
- **Redraws:** never assign an `@Observable` property its current value. Views read only what they draw (`timelineState()`, `cursorState()`, `statusText()`).
- **Extreme values:** values can be huge, infinite or NaN.
  - Format with `ValueFormat`.
  - Build ranges with `niceTicks` or `ScenarioStore.laneDomain`.
  - Never convert a model value to `Int`, or build a `ClosedRange` from unchecked numbers.
- **Far-future dates:** compare `Date`s directly. A microsecond nudge is lost past about 2150.
