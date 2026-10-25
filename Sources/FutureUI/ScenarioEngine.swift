import Foundation
import FutureEngine
import FutureFormula

/// Owns the scenario and does all of its computing on a thread of its own, so the main thread
/// never waits for the engine (docs/DESIGN.md, 4.8).
///
/// The store sends it edits, fetches for a range of dates, and previews of a draft event, one at a
/// time and in order (see `ScenarioStore`'s engine queue). Everything that crosses over is a plain
/// value: events, dates and arrays of samples.
actor ScenarioEngine {
    struct SlotSetup: Sendable {
        let name: String
        let variable: String
        let model: FormulaModel
    }

    enum Mutation: Sendable {
        case addEvent(slot: Int, Event)
        case removeEvent(slot: Int, id: UUID)
        case addRule(slot: Int, RecurringEvent)
        case removeRule(slot: Int, id: UUID)
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

    struct PreviewRequest: Sendable {
        let version: Int
        let sequence: Int
        let slot: Int
        let change: EventDraft.Built
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

    private let scenario: Scenario
    private let ids: [SlotID]
    private let variables: [String]
    nonisolated let linkCount: Int
    nonisolated let latestGeneration = Generation()

    /// How far each chunk of a fetch computes before checking whether it's been superseded.
    static let chunk: TimeInterval = 4 * 365.2425 * 86_400

    init(start: Date, slots: [SlotSetup], events: [(slot: Int, event: Event)]) throws {
        let scenario = Scenario(start: start)
        var ids: [SlotID] = []
        for slot in slots {
            ids.append(try scenario.addSlot(slot.name, model: slot.model))
        }
        for (slot, event) in events {
            scenario.add(event, to: ids[slot])
        }
        try scenario.validate()
        self.scenario = scenario
        self.ids = ids
        self.variables = slots.map(\.variable)
        self.linkCount = scenario.connections.count + scenario.eventRoutes.count
    }

    func apply(_ mutation: Mutation) {
        switch mutation {
        case .addEvent(let slot, let event): scenario.add(event, to: ids[slot])
        case .removeEvent(let slot, let id): scenario.removeEvent(id: id, from: ids[slot])
        case .addRule(let slot, let rule): scenario.add(rule, to: ids[slot])
        case .removeRule(let slot, let id): scenario.removeRecurring(id: id, from: ids[slot])
        }
    }

    /// Computes every slot through the requested range (independent groups on separate cores),
    /// a few years at a time, and returns what the panel draws.
    func fetch(_ request: FetchRequest) -> FetchResult {
        var reached = min(request.from, request.through)
        while reached < request.through {
            let computed = ids.compactMap { scenario.computedThrough($0) }.min() ?? scenario.start
            reached = min(request.through, max(reached, computed).addingTimeInterval(Self.chunk))
            try? scenario.ensureAll(through: reached)
            if latestGeneration.value > request.generation { break }
        }
        let through = max(reached, request.from)

        var series: [[Sample]] = []
        var generated: [[Event]] = []
        var parameters: [[String: Double]] = []
        for (index, id) in ids.enumerated() {
            series.append((try? scenario.series(variables[index], of: id, from: request.from, through: through)) ?? [])
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
                           computedThrough: ids.compactMap { scenario.computedThrough($0) }.min(),
                           parameters: parameters, parameterDate: request.parameterDate)
    }

    /// How much of the line a search reads at a time.
    static let findChunk: TimeInterval = 50 * 365.2425 * 86_400

    /// Finds where a slot's line first reaches a value, computing ahead only as far as needed (and
    /// only that slot and what it reads from).
    func find(_ request: FindRequest) -> FindResult {
        let id = ids[request.slot], variable = variables[request.slot]
        guard let startValue = try? scenario.value(variable, of: id, at: request.from), !startValue.isNaN else {
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

    /// The draft slot's line with the draft change applied: tries the change, reads the line, then takes it out again.
    func preview(_ request: PreviewRequest) -> PreviewResult {
        let id = ids[request.slot]
        switch request.change {
        case .event(let event): scenario.add(event, to: id)
        case .rule(let rule): scenario.add(rule, to: id)
        }
        let samples = (try? scenario.series(variables[request.slot], of: id, from: request.from, through: request.through)) ?? []
        switch request.change {
        case .event(let event): scenario.removeEvent(id: event.id, from: id)
        case .rule(let rule): scenario.removeRecurring(id: rule.id, from: id)
        }
        return PreviewResult(version: request.version, sequence: request.sequence, samples: samples, through: request.through)
    }
}
