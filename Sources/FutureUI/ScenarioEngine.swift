import Foundation
import FutureDocument
import FutureEngine
import FutureFormula
import FutureScript

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
        let model: any AuthoredModel
        /// Identifies the model and the slot's values for it. When only this changes, the slot's
        /// model is swapped without rebuilding the rest of the scenario.
        let key: String
        /// What its money is in, when money read from other currencies is converted; nil when it isn't.
        var currency: Currency? = nil
    }

    /// Every slot as the store has it, in the store's order.
    struct Layout: Sendable {
        /// nil for a slot that's paused (docs/UI.md, 5.7): it's kept out of the scenario.
        let slots: [SlotSetup?]
        let events: [[Event]]
        let rules: [[RecurringEvent]]
        let readings: [ReadingSet]
    }

    enum Mutation: Sendable {
        case addEvent(slot: Int, Event)
        case removeEvent(slot: Int, id: UUID)
        case addRule(slot: Int, RecurringEvent)
        case removeRule(slot: Int, id: UUID)
        /// Slots were added, removed, moved, renamed or given new values, events or readings.
        case layout(Layout)
        /// A new start or seed: everything is built again.
        case rebuild(start: Date, seed: UInt64, layout: Layout)
        /// Results saved earlier (docs/DESIGN.md, 15.5), by slot index, put back instead of computed.
        case restore([Int: SlotHistory])
        /// A slot's readings changed, such as when a feed brought new ones (docs/DESIGN.md, 15.8).
        case readings(slot: Int, ReadingSet)
        /// New exchange rates (docs/DESIGN.md, 5.11). Slots that convert compute again from where they changed.
        case rates(ExchangeRates)
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

    /// An error a slot's model raised while computing, such as a script's, and how far it got.
    struct SlotFailure: Sendable, Equatable {
        let message: String
        /// The line in the slot's formula or script, when it's known.
        let line: Int?
        /// The last point computed before it failed.
        let date: Date

        var text: String { (line.map { "line \($0): " } ?? "") + message }
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
        /// Each slot's error while computing, by slot index.
        let failures: [SlotFailure?]
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
        /// The authored event a draft event replaces, while one is being edited: it's left out of the preview.
        var replacing: UUID? = nil
    }

    struct PreviewResult: Sendable {
        let version: Int
        let sequence: Int
        let samples: [Sample]
        let through: Date
        /// The error a previewed model raised, such as a draft script's. The samples stop there.
        var failure: SlotFailure? = nil
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

    private var start: Date
    private var seed: UInt64
    private var rates: ExchangeRates
    private var scenario: Scenario
    private var setups: [SlotSetup?]
    /// Each slot's readings as last sent, to tell when they change without comparing every reading.
    private var readingSets: [ReadingSet]
    /// Each store slot's place in the scenario, or nil while it's paused.
    private var ids: [SlotID?]
    /// Errors slots raised while computing, by slot name. Edits clear them; computing again finds them again.
    private var failures: [String: SlotFailure] = [:]
    nonisolated let latestGeneration = Generation()

    /// How far each chunk of a fetch computes before checking whether it's been superseded.
    static let chunk: TimeInterval = 4 * 365.2425 * 86_400

    init(start: Date, seed: UInt64 = Scenario.defaultSeed, layout: Layout, rates: ExchangeRates = .none) throws {
        self.start = start
        self.seed = seed
        self.rates = rates
        (scenario, ids) = try Self.build(start: start, seed: seed, layout: layout, rates: rates)
        setups = layout.slots
        readingSets = layout.readings
    }

    private static func build(start: Date, seed: UInt64, layout: Layout, rates: ExchangeRates) throws -> (Scenario, [SlotID?]) {
        let scenario = Scenario(start: start, seed: seed)
        var ids: [SlotID?] = []
        for (index, setup) in layout.slots.enumerated() {
            guard let setup else { ids.append(nil); continue }
            let id = try scenario.addSlot(setup.name, model: setup.model, currency: setup.currency)
            for event in layout.events[index] { scenario.add(event, to: id) }
            for rule in layout.rules[index] { scenario.add(rule, to: id) }
            scenario.setReadings(layout.readings[index].readings, for: id)
            ids.append(id)
        }
        try scenario.validate()
        scenario.setExchangeRates(rates)
        return (scenario, ids)
    }

    func apply(_ mutation: Mutation) {
        failures.removeAll()
        switch mutation {
        case .addEvent(let slot, let event): if let id = ids[slot] { scenario.add(event, to: id) }
        case .removeEvent(let slot, let eventID): if let id = ids[slot] { scenario.removeEvent(id: eventID, from: id) }
        case .addRule(let slot, let rule): if let id = ids[slot] { scenario.add(rule, to: id) }
        case .removeRule(let slot, let ruleID): if let id = ids[slot] { scenario.removeRecurring(id: ruleID, from: id) }
        case .layout(let layout): change(to: layout)
        case .rebuild(let start, let seed, let layout):
            self.start = start
            self.seed = seed
            rebuild(layout)
        case .restore(let histories):
            for (index, history) in histories where ids.indices.contains(index) {
                if let id = ids[index] { scenario.restore(history, to: id) }
            }
        case .readings(let slot, let set):
            guard readingSets.indices.contains(slot), readingSets[slot] != set else { return }
            readingSets[slot] = set
            if let id = ids[slot] { scenario.setReadings(set.readings, for: id) }
        case .rates(let rates):
            self.rates = rates
            scenario.setExchangeRates(rates)
        }
    }

    /// When the same slots run under the same names, swaps only the models that changed and brings
    /// each slot's events and readings up to date, so the rest keep what they've computed.
    /// Anything else rebuilds the scenario.
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
                for (index, id) in ids.enumerated() {
                    guard let id else { continue }
                    scenario.setCurrency(layout.slots[index]?.currency, of: id)
                    syncEvents(of: id, to: layout.events[index], rules: layout.rules[index])
                    if readingSets.indices.contains(index), readingSets[index] != layout.readings[index] {
                        scenario.setReadings(layout.readings[index].readings, for: id)
                    }
                }
                setups = layout.slots
                readingSets = layout.readings
                return
            } catch {
                // Fall through and rebuild from scratch.
            }
        }
        rebuild(layout)
    }

    private func rebuild(_ layout: Layout) {
        do {
            (scenario, ids) = try Self.build(start: start, seed: seed, layout: layout, rates: rates)
        } catch {
            // The store only sends slots whose wiring checks out, so this shouldn't happen. If it
            // does, run nothing rather than something half-wired.
            scenario = Scenario(start: start, seed: seed)
            ids = layout.slots.map { _ in nil }
        }
        setups = layout.slots
        readingSets = layout.readings
    }

    /// Removes events and rules the slot no longer has and adds new ones, by id. Unchanged ones
    /// stay, so only the time after a change is computed again.
    private func syncEvents(of id: SlotID, to events: [Event], rules: [RecurringEvent]) {
        let wanted = Set(events.map(\.id))
        let have = scenario.events(in: id)
        for event in have where !wanted.contains(event.id) { scenario.removeEvent(id: event.id, from: id) }
        let kept = Set(have.map(\.id))
        for event in events where !kept.contains(event.id) { scenario.add(event, to: id) }
        for event in events where kept.contains(event.id) {
            if let old = have.first(where: { $0.id == event.id }), old != event { scenario.upsert(event, in: id) }
        }

        let wantedRules = Set(rules.map(\.id))
        let haveRules = scenario.recurringEvents(in: id)
        for rule in haveRules where !wantedRules.contains(rule.id) || !rules.contains(rule) {
            scenario.removeRecurring(id: rule.id, from: id)
        }
        let keptRules = Set(scenario.recurringEvents(in: id).map(\.id))
        for rule in rules where !keptRules.contains(rule.id) { scenario.add(rule, to: id) }
    }

    /// Results worth saving (docs/DESIGN.md, 15.5): slots whose results took at least
    /// `minimumSeconds` to compute, that can save their state and didn't stop with an error.
    func resultsToSave(minimumSeconds: Double) -> [Int: SlotHistory] {
        var results: [Int: SlotHistory] = [:]
        for (index, id) in ids.enumerated() {
            guard let id, let setup = setups[index], failures[setup.name] == nil,
                  scenario.computeCost(of: id) >= minimumSeconds, let history = scenario.history(of: id) else { continue }
            results[index] = history
        }
        return results
    }

    /// Computes every slot through the requested range (independent groups on separate cores),
    /// a few years at a time, and returns what the panel draws.
    func fetch(_ request: FetchRequest) -> FetchResult {
        let running = ids.compactMap { $0 }
        var reached = min(request.from, request.through)
        while reached < request.through {
            let computed = running.compactMap { scenario.computedThrough($0) }.min() ?? scenario.start
            reached = min(request.through, max(reached, computed).addingTimeInterval(Self.chunk))
            do {
                try scenario.ensureAll(through: reached)
            } catch {
                record(error)
            }
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
            // A slot that failed partway shows what it computed before the error.
            let reach = failures[setup.name] == nil ? through : min(through, scenario.computedThrough(id) ?? scenario.start)
            series.append((try? scenario.series(setup.variable, of: id, from: request.from, through: reach)) ?? [])
            let events = (try? scenario.generatedEvents(in: id, through: reach)) ?? []
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
                           parameters: parameters, parameterDate: request.parameterDate,
                           failures: setups.map { $0.flatMap { failures[$0.name] } })
    }

    /// Remembers which slot failed and why.
    private func record(_ error: Error) {
        guard let (name, failure) = Self.failure(error, in: scenario) else { return }
        failures[name] = failure
    }

    /// The slot an error came from, and what to show for it.
    private static func failure(_ error: Error, in scenario: Scenario) -> (name: String, failure: SlotFailure)? {
        let name: String, message: String, line: Int?
        switch error {
        case let error as ScriptError:
            guard let slot = error.slot else { return nil }
            (name, message, line) = (slot, error.message, error.line)
        case EngineError.modelFailed(let slot, let text):
            (name, message, line) = (slot, text, nil)
        default:
            return nil
        }
        guard let id = scenario.slotID(named: name) else { return nil }
        return (name, SlotFailure(message: message, line: line, date: scenario.computedThrough(id) ?? scenario.start))
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

    /// A copy of a slot for Refit (docs/DESIGN.md, 8.4), or why there can't be one.
    enum FittingCopy: Sendable {
        case copy(SlotCopy)
        case failed(String)
    }

    /// Copies what fitting a slot needs, so the fit can run on another thread while this one
    /// carries on drawing.
    func copyForFitting(slot: Int) -> FittingCopy {
        guard ids.indices.contains(slot), let id = ids[slot] else {
            return .failed("This slot is paused, so it can't be refitted.")
        }
        do {
            return .copy(try scenario.copyForFitting(id))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// The slot's line with the change applied: tries the change, reads the line, then takes it out again.
    func preview(_ request: PreviewRequest) -> PreviewResult {
        guard let id = ids[request.slot], let original = setups[request.slot] else {
            return PreviewResult(version: request.version, sequence: request.sequence, samples: [], through: request.through)
        }
        var samples: [Sample] = []
        var failure: SlotFailure?
        switch request.change {
        case .event(let built):
            let replaced = request.replacing.flatMap { scenario.removeEvent(id: $0, from: id) }
            switch built {
            case .event(let event):
                scenario.add(event, to: id)
                samples = (try? scenario.series(original.variable, of: id, from: request.from, through: request.through)) ?? []
                scenario.removeEvent(id: event.id, from: id)
            case .rule(let rule):
                scenario.add(rule, to: id)
                samples = (try? scenario.series(original.variable, of: id, from: request.from, through: request.through)) ?? []
                scenario.removeRecurring(id: rule.id, from: id)
            }
            if let replaced { scenario.add(replaced, to: id) }
        case .model(let setup):
            // Only this slot and what it reads are computed for the line; putting the model back
            // leaves this slot and those downstream to be recomputed by the next fetch.
            if (try? scenario.replaceModel(of: id, with: setup.model)) != nil {
                do {
                    samples = try scenario.series(setup.variable, of: id, from: request.from, through: request.through)
                } catch {
                    failure = Self.failure(error, in: scenario)?.failure
                    let reached = min(request.through, scenario.computedThrough(id) ?? scenario.start)
                    samples = (try? scenario.series(setup.variable, of: id, from: request.from, through: reached)) ?? []
                }
                try? scenario.replaceModel(of: id, with: original.model)
            }
        }
        return PreviewResult(version: request.version, sequence: request.sequence, samples: samples, through: request.through,
                             failure: failure)
    }
}
