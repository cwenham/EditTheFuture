# Edit The Future

An infinite, editable graph of values over time for macOS, iPadOS and iOS. Scroll into the past or future, insert or delete events, and watch up to 8 linked models (calculations or simulations) update together.

The design lives in [docs/DESIGN.md](docs/DESIGN.md).

## What's here

This repository currently holds the engine as a Swift package:

- `FutureEngine`: time grids, events, the `TimelineModel` protocol, and `Scenario`, which runs linked models lazily with checkpoints and goal seek.
- `FutureFormula`: a small formula language for models typed into the app (`balance[t] = balance[t-1] * (1 + rate/12) + deposit`).
- `FutureCommands`: the command vocabulary shared by menus, hot-keys, the `etf://` URL scheme, the CLI, App Intents and hardware controllers, plus MIDI decoding and feedback.

## Requirements

Xcode 16 or later (Swift 6). The engine targets macOS 14 and iOS 17.

## Run the tests

```bash
swift test
```
