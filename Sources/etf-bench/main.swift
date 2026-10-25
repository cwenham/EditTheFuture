#if os(macOS)
import AppKit
import SwiftUI
import FutureEngine
import FutureFormula
import FutureUI

// Measures the engine, the panel state and real SwiftUI frames while scrolling, zooming
// and moving the cursor. Run with: swift run -c release etf-bench [section]

func utc(_ year: Int, _ month: Int = 1, _ day: Int = 1) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

func time(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

/// CPU time used by the calling thread, in milliseconds (excludes time spent waiting).
func threadCPUTime() -> Double {
    var spec = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
    return Double(spec.tv_sec) * 1000 + Double(spec.tv_nsec) / 1e6
}

func report(_ label: String, _ ms: Double, _ detail: String = "") {
    print(label.padding(toLength: 58, withPad: " ", startingAt: 0) + String(format: "%9.2f ms  ", ms) + detail)
}

/// One frame: let SwiftUI apply pending changes (it does so from a run-loop observer),
/// lay out, draw, and commit the layer tree.
@MainActor
func renderFrame(_ view: NSView) {
    RunLoop.main.run(mode: .default, before: Date())
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    CATransaction.flush()
}

/// The engine works on its own thread; this runs the main run loop (where its results are
/// delivered) until it has nothing left to do, and returns how long that took.
@MainActor
@discardableResult
func waitForEngine(_ store: ScenarioStore) -> Double {
    time {
        while !store.isEngineIdle {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
        }
    }
}

@MainActor
func benchEngine() throws {
    let definition = ScenarioDefinition.homeAndMoney
    for years in [50, 200] {
        let scenario = Scenario(start: definition.start)
        var ids: [SlotID] = []
        for spec in definition.slots { ids.append(try scenario.addSlot(spec.name, model: try FormulaModel(spec.formula, name: spec.name))) }
        let horizon = utc(2022 + years)
        let ms = try time { for id in ids { try scenario.ensure(id, through: horizon) } }
        let steps = years * 12 * ids.count
        report("engine: compute \(years) years, 5 monthly slots", ms, String(format: "%.1f µs/step", ms * 1000 / Double(steps)))
    }

    // Several independent slots: sequential versus spread across cores.
    func independentScenario(count: Int, daily: Bool) throws -> (Scenario, [SlotID]) {
        let scenario = Scenario(start: utc(2022))
        var ids: [SlotID] = []
        for index in 0..<count {
            let formula = daily
                ? "step 1 day\nparam r = 0.\(index + 1)\ntemp[t] = 11 - 9 * cos(2 * pi * (dayOfYear - 15) / 365) + r * (year - 2022)"
                : "step 1 month\nparam rate = \(3 + index)%\ninit balance = 1000\nbalance[t] = balance[t-1] * (1 + rate / 12) + 100"
            ids.append(try scenario.addSlot("Slot\(index)", model: try FormulaModel(formula)))
        }
        return (scenario, ids)
    }
    for (count, daily, years) in [(8, false, 200), (8, true, 50)] {
        let label = "\(count) independent \(daily ? "daily" : "monthly") slots, \(years) years"
        var (scenario, ids) = try independentScenario(count: count, daily: daily)
        let sequential = try time { for id in ids { try scenario.ensure(id, through: utc(2022 + years)) } }
        report("engine: \(label), one core", sequential)
        (scenario, ids) = try independentScenario(count: count, daily: daily)
        let parallel = try time { try scenario.ensureAll(through: utc(2022 + years)) }
        report("engine: \(label), all cores", parallel, String(format: "%.1fx faster", sequential / parallel))
        _ = ids
    }

    // A daily model, the kind that makes long zooms expensive.
    let daily = Scenario(start: utc(2022))
    let climate = try daily.addSlot("Climate", model: try FormulaModel("""
        step 1 day
        temp[t] = 11 - 9 * cos(2 * pi * (dayOfYear - 15) / 365) + 0.03 * (year - 2022)
        """))
    let ms = try time { try daily.ensure(climate, through: utc(2072)) }
    report("engine: compute 50 years of a daily slot", ms, String(format: "%.1f µs/step", ms * 1000 / Double(50 * 365)))

    // Editing near the start forces a recompute of everything after it.
    let scenario = Scenario(start: definition.start)
    var ids: [SlotID] = []
    for spec in definition.slots { ids.append(try scenario.addSlot(spec.name, model: try FormulaModel(spec.formula, name: spec.name))) }
    for id in ids { try scenario.ensure(id, through: utc(2100)) }
    let edit = try time {
        scenario.add(Event(time: utc(2027, 3), kind: "deposit", values: ["amount": 500]), to: ids[0])
        try scenario.ensure(ids[0], through: utc(2100))
    }
    report("engine: recompute after an edit (73 years)", edit)
}

@MainActor
func benchState() throws {
    var store: ScenarioStore!
    var ms = try time {
        store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
    }
    report("store: create (main thread)", ms)
    report("store: first results arrive", waitForEngine(store))
    _ = store.panelState()
    ms = time { for _ in 0..<50 { _ = store.panelState() } }
    report("panelState(), default view (19 years)", ms / 50)
    store.zoom(by: 1e6)
    report("engine: catch up after zooming to the widest view", waitForEngine(store))
    _ = store.panelState()
    ms = time { for _ in 0..<50 { _ = store.panelState() } }
    report("panelState(), widest view (80 years)", ms / 50)
    store.show(utc(2200))
    report("engine: catch up after jumping to 2200", waitForEngine(store))
    store.add(Event(time: utc(2027, 3), kind: "deposit", values: ["amount": 500]), toSlotAt: 0)
    report("engine: catch up after an edit near the start", waitForEngine(store))
}

@MainActor
func benchFrames() throws {
    let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
    let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    window.orderFrontRegardless()
    func frame() { renderFrame(view) }
    waitForEngine(store)
    frame()

    func measure(_ label: String, count: Int, step: (Int) -> Void) {
        let cpuStart = threadCPUTime()
        let ms = time {
            for i in 0..<count {
                step(i)
                frame()
            }
        }
        let cpu = (threadCPUTime() - cpuStart) / Double(count)
        let catchUp = waitForEngine(store)
        frame()
        report(label, ms / Double(count), String(format: "%.1f ms CPU on the main thread; engine caught up %.0f ms later", cpu, catchUp))
    }

    measure("frame: nothing changes (floor)", count: 60) { _ in }
    measure("frame: move cursor, default view", count: 60) { store.setCursor(fraction: Double($0) / 60) }
    measure("frame: scroll, default view", count: 60) { _ in store.pan(by: 0.02) }
    measure("frame: zoom out step by step", count: 30) { _ in store.zoom(by: 1.05) }
    store.zoom(by: 1e6)
    waitForEngine(store)
    frame()
    measure("frame: move cursor, widest view", count: 60) { store.setCursor(fraction: Double($0) / 60) }
    measure("frame: scroll, widest view", count: 60) { _ in store.pan(by: 0.02) }
    store.eventDraft.amountText = "500"
    store.eventDraft.repeats = .monthly
    waitForEngine(store)
    frame()
    measure("frame: scroll with an event preview", count: 60) { _ in store.pan(by: 0.05) }
    window.close()
}

let section = CommandLine.arguments.dropFirst().first ?? "all"
MainActor.assumeIsolated {
    do {
        if section == "all" || section == "engine" { try benchEngine() }
        if section == "all" || section == "state" { try benchState() }
        if section == "all" || section == "frames" { try benchFrames() }
        if section == "engine-loop" {
            // For profiling the engine: compute long horizons repeatedly.
            let end = Date().addingTimeInterval(10)
            var runs = 0
            while Date() < end {
                let definition = ScenarioDefinition.homeAndMoney
                let scenario = Scenario(start: definition.start)
                var ids: [SlotID] = []
                for spec in definition.slots { ids.append(try scenario.addSlot(spec.name, model: try FormulaModel(spec.formula, name: spec.name))) }
                for id in ids { try scenario.ensure(id, through: utc(2222)) }
                runs += 1
            }
            print("engine runs: \(runs)")
        }
        if section == "cursor-loop" {
            let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
            let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            waitForEngine(store)
            let preview = CommandLine.arguments.dropFirst(2).first == "preview"
            if preview {
                store.eventDraft.amountText = "500"
                store.eventDraft.repeats = .monthly
            }
            let end = Date().addingTimeInterval(10)
            var i = 0
            while Date() < end {
                i += 1
                if preview || CommandLine.arguments.dropFirst(2).first == "scroll" {
                    store.pan(by: i % 400 < 200 ? 0.03 : -0.03)
                } else {
                    store.setCursor(fraction: Double(i % 100) / 100)
                }
                renderFrame(view)
            }
            print("frames: \(i)")
        }
        if section == "far" {
            // Memory and time for computing far ahead, the way the app's engine does (4-year chunks).
            func rss() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_maxrss) / 1_048_576
            }
            let definition = ScenarioDefinition.homeAndMoney
            let scenario = Scenario(start: definition.start)
            for spec in definition.slots { _ = try scenario.addSlot(spec.name, model: try FormulaModel(spec.formula, name: spec.name)) }
            let target = Int(CommandLine.arguments.dropFirst(2).first ?? "31000") ?? 31000
            var year = 2026
            let ms = try time {
                while year < target {
                    year += 4
                    try scenario.ensureAll(through: utc(year))
                    if year % 5000 < 4 { print(String(format: "  year %d: peak memory %.0f MB", year, rss())) }
                }
            }
            report("far: compute to year \(target) in 4-year chunks", ms, String(format: "peak memory %.0f MB", rss()))
        }
        if section == "flick" {
            // Zoom out as far as possible, then flick far into the future: the gesture that
            // found the overflow crash. Reports main-thread cost per frame and the engine's lag.
            let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
            let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            store.zoom(by: 1e6)
            waitForEngine(store)
            renderFrame(view)
            let frames = Int(CommandLine.arguments.dropFirst(2).first ?? "600") ?? 600
            var worst = 0.0
            let cpuStart = threadCPUTime()
            var segmentStart = cpuStart, segmentWorst = 0.0
            let ms = time {
                for i in 0..<frames {
                    // The app's event loop empties the autorelease pool after every event; this
                    // loop has to do it itself, or each frame's temporary objects pile up.
                    autoreleasepool {
                        // Bursts of fast scrolling with short pauses, like flicks of a wheel.
                        if i % 40 < 30 { store.pan(by: 0.08) }
                        let frameTime = time { renderFrame(view) }
                        worst = max(worst, frameTime)
                        segmentWorst = max(segmentWorst, frameTime)
                    }
                    if (i + 1) % 1000 == 0 {
                        let now = threadCPUTime()
                        print(String(format: "  frames %5d–%5d, to year %5d: %.1f ms CPU per frame, worst %.0f ms", i - 998, i + 1,
                                     Calendar(identifier: .gregorian).component(.year, from: store.frame.end),
                                     (now - segmentStart) / 1000, segmentWorst))
                        segmentStart = now
                        segmentWorst = 0
                    }
                }
            }
            let cpu = (threadCPUTime() - cpuStart) / Double(frames)
            report("flick: \(frames) frames to year \(Calendar(identifier: .gregorian).component(.year, from: store.frame.end))", ms / Double(frames),
                   String(format: "%.1f ms CPU on the main thread; worst frame %.0f ms", cpu, worst))
            report("flick: engine caught up", waitForEngine(store))
            renderFrame(view)
            print(store.statusText(), "·", store.cursorState().readoutValue)
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print(String(format: "peak memory: %.0f MB", Double(usage.ru_maxrss) / 1_048_576))
        }
        if section == "loop" {
            // For profiling: keep scrolling and zooming for a while.
            let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
            let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            waitForEngine(store)
            let end = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst(2).first ?? "15") ?? 15)
            var i = 0
            while Date() < end {
                i += 1
                if i % 200 < 100 { store.pan(by: 0.02) } else { store.zoom(by: i % 2 == 0 ? 1.08 : 0.95) }
                store.setCursor(fraction: Double(i % 100) / 100)
                renderFrame(view)
            }
            print("loop frames: \(i)")
        }
    } catch {
        print("benchmark failed: \(error)")
    }
}
#endif
