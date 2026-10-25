import Foundation
import FutureEngine
import FutureFormula

/// Owns the scenario and does all of its computing on a thread of its own, so the main thread
/// never waits for the engine (docs/DESIGN.md, 4.8).
///
/// The store sends it edits, fetches for a range of dates, and previews of a draft event or a
/// parameter being dragged, one at a time and in order (see `ScenarioStore`'s engine queue).
/// Everything that crosses over is a plain value: events, dates, models and arrays of samples.
///
/// Slots are indexed the way the store lists them. A paused slot has no place in the scenario:
/// its series are empty and edits to it are kept by the store until it runs again.
actor ScenarioEngine {
    struct SlotSetup: Sendable {
        let name: String
        let variable: String
        let model: FormulaModel
        /// Identifies the model and the slot's values for it. When only this changes, the slot's
        /// model is swapped without rebuilding the rest of the scenario.
        let key: String
    }

    /// Every slot as the store has it, in the store's order.
    struct Layout: Sendable {
        /// nil for a slot that's paused (docs/UI.md, 5.7): it's kept out of the scenario.
        let slots: [SlotSetup?]
        let events: [[Event]]
        let rules: [[RecurringEvent]]
    }

    enum Mutation: Sendable {
        case addEvent(slot: Int, Event)
        case removeEvent(slot: Int, id: UUID)
        case addRule(slot: Int, RecurringEvent)
        case removeRule(slot: Int, id: UUID)
        /// Slots were added, removed, moved, renamed or given new values.
        case layout(Layout)
    }

    struct FetchRequest: Sendable {
        /// The store's revision when it asked; results for an older revision are ignored.
        let version: Int
        /// Increases with every fetch the store asks for; a running fetch stops early once a newer one exists.
        let generation: Int
        let from: Date
        let through: Date
        /// When to read parameter values (the add-event pane's date).
        let parameterDate: Date
    }

    struct FetchResult: Sendable {
        let version: Int
        let generation: Int
        let from: Date
        /// How far the result reaches. Less than requested when a newer fetch cut this one short.
        let through: Date
        /// Each slot's drawn variable, by slot index.
        let series: [[Sample]]
        /// Each slot's generated events from `from` through `through`.
        let generated: [[Event]]
        let computedThrough: Date?
        /// Each slot's parameter values at `parameterDate`.
        let parameters: [[String: Double]]
        let parameterDate: Date
    }

    /// What a preview tries out.
    enum PreviewChange: Sendable {
        /// The add-event pane's draft.
        case event(EventDraft.Built)
        /// The slot with different starting values, while a slider is dragged.
        case model(SlotSetup)
    }

    struct PreviewRequest: Sendable {
        let version: Int
        let sequence: Int
        let slot: Int
        let change: PreviewChange
        let from: Date
        let through: Date
    }

    struct PreviewResult: Sendable {
        let version: Int
        let sequence: Int
        let samples: [Sample]
        let through: Date
    }

    struct FindRequest: Sendable {
        let slot: Int
        let target: Double
        /// Where the search starts (now), and how far it goes before giving up.
        let from: Date
        let limit: Date
    }

    struct FindResult: Sendable {
        let request: FindRequest
        /// The slot's value at `from`. Below the target, the search looks for the line rising to it;
        /// above, falling to it.
        let startValue: Double?
        /// The first computed point from `from` on where the line reaches the target, or nil if it
        /// doesn't before `limit`.
        let found: Sample?
    }

    /// The newest fetch generation the store has asked for. Read without hopping onto the actor,
    /// so a fetch that's running can see it has been superseded.
    final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var latest = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }

        func advance(to generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            latest = max(latest, generation)
        }
    }

    /// A serial queue of its own, so long computations never tie up Swift's shared thread pool.
    private let queue = DispatchSerialQueue(label: "com.editthefuture.engine", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let start: Date
    private var scenario: Scenario
    private var setups: [SlotSetup?]
    /// Each store slot's place in the scenario, or nil while it's paused.
    private var ids: [SlotID?]
    nonisolated let latestGeneration = Generation()

    /// How far each chunk of a fetch computes before checking whether it's been superseded.
    static let chunk: TimeInterval = 4 * 365.2425 * 86_400

    init(start: Date, layout: Layout) throws {
        self.start = start
        (scenario, ids) = try Self.build(start: start, layout: layout)
        setups = layout.slots
    }

    private static func build(start: Date, layout: Layout) throws -> (Scenario, [SlotID?]) {
        let scenario = Scenario(start: start)
        var ids: [SlotID?] = []
        for (index, setup) in layout.slots.enumerated() {
            guard let setup else { ids.append(nil); continue }
            let id = try scenario.addSlot(setup.name, model: setup.model)
            for event in layout.events[index] { scenario.add(event, to: id) }
            for rule in layout.rules[index] { scenario.add(rule, to: id) }
            ids.append(id)
        }
        try scenario.validate()
        return (scenario, ids)
    }

    func apply(_ mutation: Mutation) {
        switch mutation {
        case .addEvent(let slot, let event): if let id = ids[slot] { scenario.add(event, to: id) }
        case .removeEvent(let slot, let eventID): if let id = ids[slot] { scenario.removeEvent(id: eventID, from: id) }
        case .addRule(let slot, let rule): if let id = ids[slot] { scenario.add(rule, to: id) }
        case .removeRule(let slot, let ruleID): if let id = ids[slot] { scenario.removeRecurring(id: ruleID, from: id) }
        case .layout(let layout): change(to: layout)
        }
    }

    /// When the same slots run under the same names, swaps only the models that changed, so the
    /// other slots keep what they've computed. Anything else rebuilds the scenario.
    private func change(to layout: Layout) {
        let sameSlots = layout.slots.count == setups.count
            && zip(layout.slots, setups).allSatisfy { $0?.name == $1?.name }
        if sameSlots {
            do {
                for (index, setup) in layout.slots.enumerated() {
                    guard let setup, let id = ids[index], setup.key != setups[index]?.key else { continue }
                    try scenario.replaceModel(of: id, with: setup.model)
                }
                try scenario.validate()
                setups = layout.slots
                return
            } catch {
                // Fall through and rebuild from scratch.
            }
        }
        do {
            (scenario, ids) = try Self.build(start: start, layout: layout)
        } catch {
            // The store only sends slots whose wiring checks out, so this shouldn't happen. If it
            // does, run nothing rather than something half-wired.
            scenario = Scenario(start: start)
            ids = layout.slots.map { _ in nil }
        }
        setups = layout.slots
    }

    /// Computes every slot through the requested range (independent groups on separate cores),
    /// a few years at a time, and returns what the panel draws.
    func fetch(_ request: FetchRequest) -> FetchResult {
        let running = ids.compactMap { $0 }
        var reached = min(request.from, request.through)
        while reached < request.through {
            let computed = running.compactMap { scenario.computedThrough($0) }.min() ?? scenario.start
            reached = min(request.through, max(reached, computed).addingTimeInterval(Self.chunk))
            try? scenario.ensureAll(through: reached)
            if latestGeneration.value > request.generation { break }
        }
        let through = max(reached, request.from)

        var series: [[Sample]] = []
        var generated: [[Event]] = []
        var parameters: [[String: Double]] = []
        for (index, id) in ids.enumerated() {
            guard let id, let setup = setups[index] else {
                series.append([])
                generated.append([])
                parameters.append([:])
                continue
            }
            series.append((try? scenario.series(setup.variable, of: id, from: request.from, through: through)) ?? [])
            let events = (try? scenario.generatedEvents(in: id, through: through)) ?? []
            generated.append(events.filter { $0.time >= request.from })
            var values: [String: Double] = [:]
            for variable in scenario.descriptor(of: id).variables where variable.causality == .parameter {
                values[variable.name] = try? scenario.value(variable.name, of: id, at: max(request.parameterDate, scenario.start))
            }
            parameters.append(values)
        }
        return FetchResult(version: request.version, generation: request.generation, from: request.from, through: through,
                           series: series, generated: generated,
                           computedThrough: running.compactMap { scenario.computedThrough($0) }.min(),
                           parameters: parameters, parameterDate: request.parameterDate)
    }

    /// How much of the line a search reads at a time.
    static let findChunk: TimeInterval = 50 * 365.2425 * 86_400

    /// Finds where a slot's line first reaches a value, computing ahead only as far as needed (and
    /// only that slot and what it reads from).
    func find(_ request: FindRequest) -> FindResult {
        guard let id = ids[request.slot], let variable = setups[request.slot]?.variable,
              let startValue = try? scenario.value(variable, of: id, at: request.from), !startValue.isNaN else {
            return FindResult(request: request, startValue: nil, found: nil)
        }
        if startValue == request.target {
            return FindResult(request: request, startValue: startValue, found: Sample(time: request.from, value: startValue))
        }
        let rising = startValue < request.target
        var from = request.from
        while from < request.limit {
            let through = min(request.limit, from.addingTimeInterval(Self.findChunk))
            guard let samples = try? scenario.series(variable, of: id, from: from, through: through) else { break }
            if let hit = samples.first(where: { rising ? $0.value >= request.target : $0.value <= request.target }) {
                return FindResult(request: request, startValue: startValue, found: hit)
            }
            from = through
        }
        return FindResult(request: request, startValue: startValue, found: nil)
    }

    /// The slot's line with the change applied: tries the change, reads the line, then takes it out again.
    func preview(_ request: PreviewRequest) -> PreviewResult {
        guard let id = ids[request.slot], let original = setups[request.slot] else {
            return PreviewResult(version: request.version, sequence: request.sequence, samples: [], through: request.through)
        }
        var samples: [Sample] = []
        switch request.change {
        case .event(.event(let event)):
            scenario.add(event, to: id)
            samples = (try? scenario.series(original.variable, of: id, from: request.from, through: request.through)) ?? []
            scenario.removeEvent(id: event.id, from: id)
        case .event(.rule(let rule)):
            scenario.add(rule, to: id)
            samples = (try? scenario.series(original.variable, of: id, from: request.from, through: request.through)) ?? []
            scenario.removeRecurring(id: rule.id, from: id)
        case .model(let setup):
            // Only this slot and what it reads are computed for the line; putting the model back
            // leaves this slot and those downstream to be recomputed by the next fetch.
            if (try? scenario.replaceModel(of: id, with: setup.model)) != nil {
                samples = (try? scenario.series(setup.variable, of: id, from: request.from, through: request.through)) ?? []
                try? scenario.replaceModel(of: id, with: original.model)
            }
        }
        return PreviewResult(version: request.version, sequence: request.sequence, samples: samples, through: request.through)
    }
}
