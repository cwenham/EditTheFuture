# Edit The Future

A Swift app (Mac first, then iPad and iPhone) showing an infinite, editable graph of values over time, driven by up to 8 linked models.

**Start with [docs/HANDOFF.md](docs/HANDOFF.md)**: where the work stands, what's next, and how to check your work. The design is in [docs/DESIGN.md](docs/DESIGN.md) and the UI spec in [docs/UI.md](docs/UI.md).

## Commands

- Build: `swift build`
- Test: `swift test` (Swift Testing)
- Benchmarks: `swift run -c release etf-bench [engine|state|frames|flick|far|loop|engine-loop|cursor-loop]`; `etf-bench predict readings.csv [step day] [since 1976-01-01]` scores the Forecast models on saved readings
- Python for scripts: `scripts/fetch-python.sh` once per checkout (into `Vendor/Python`, not in git). Without it, Python slots pause. Run it again if Python's tests show as skipped: SwiftPM caches whether the folder was there.
- A script without the app: `swift run etf-script model.lua --through 2040-01-01`
- A feed without the app: `swift run etf-feed "[feed: fred, series: DGS10]" --since 2026-01-01`; `--check` fetches every ready-made feed that needs no key; `--rates GBP,EUR` fetches exchange rates.
- The command-line tool, once the app is built: `.build/EditTheFuture.app/Contents/MacOS/etf help` (`etf value savings --at 2030`, `etf data savings --every monthly`). The app trusts only the copy inside it.
- App: `scripts/build-app.sh`, then `open .build/EditTheFuture.app`. It's a menu bar app; show the panel with ⌃⌥Space or `open "etf://show?timeline=savings&at=2060-01"`.

## Rules

- **Branches:** start each new feature or fix on its own branch from `main`, named like `feature/links-view` or `fix/wheel-scrolling`.
- **Commits:** commit only when the user asks, on that branch. Merge into `main` only when the user asks. The remote is `origin` (github.com/cwenham/EditTheFuture); push only when the user asks.
- **Docs:** keep DESIGN.md and UI.md in step with the code, written plainly.
- **Threads:** the main thread never computes. `ScenarioEngine` (an actor) owns the scenario, and `ScenarioStore` draws from its cached results. Tests `await store.waitUntilIdle()` before reading results.
- **Redraws:** never assign an `@Observable` property its current value. Views read only what they draw (`timelineState()`, `cursorState()`, `statusText()`).
- **Extreme values:** values can be huge, infinite or NaN.
  - Format with `ValueStyle`, which also says what currency money is in.
  - Build ranges with `niceTicks` or `ScenarioStore.laneDomain`.
  - Never convert a model value to `Int`, or build a `ClosedRange` from unchecked numbers.
- **Far-future dates:** compare `Date`s directly. A microsecond nudge is lost past about 2150.
- **Feeds and exchange rates** (DESIGN.md 15.8, 5.11): sign-ins live in the Keychain, never in `scenario.md`, and go only to their own hosts over HTTPS. Tests never touch the network: answer from fixtures through `FeedTransport`, and keep sign-ins in `MemoryCredentialStore`.
- **Scripts** (DESIGN.md 6.4): keep Lua and Python's APIs the same, and test both languages side by side. Nothing may download or install code (no pip), so the app stays within App Store rules.
