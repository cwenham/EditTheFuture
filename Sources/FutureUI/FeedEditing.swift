import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

/// A feed in a slot: the slot, and what the feed fetches (`FeedSpec.identity`).
public struct FeedKey: Hashable, Sendable {
    public let slot: UUID
    public let identity: String

    public init(slot: UUID, identity: String) {
        self.slot = slot
        self.identity = identity
    }
}

/// Where a feed stands, for the Slot tab (docs/UI.md, 5.10).
public struct FeedStatus: Sendable, Equatable {
    public var isFetching = false
    /// When it was last fetched, or when its copy was written.
    public var checked: Date?
    public var count = 0
    public var first: Date?
    public var last: Date?
    /// The latest reading, as the source gives it.
    public var lastValue: Double?
    /// Why the last fetch failed.
    public var error: String?

    public init() {}
}

/// Which feed setup screen is open (docs/UI.md, 5.10).
public enum FeedSetupRequest: Equatable, Sendable {
    /// A new feed for a slot.
    case add(slot: UUID)
    /// One of a slot's feeds, by where it is in the slot's readings.
    case edit(slot: UUID, source: Int)
    /// A slot of its own, at a 0-based position, showing the feed's readings.
    case newSlot(position: Int)
}

/// Adding, changing and removing feeds, and taking in what they fetch (docs/DESIGN.md, 15.8).
/// Changes to a slot's feeds can be undone; new readings aren't changes, so undo leaves them.
extension ScenarioStore {
    // MARK: The setup screen

    public func openFeedSetup(_ request: FeedSetupRequest) {
        switch request {
        case .add(let id), .edit(let id, _):
            if let index = slotIndex(id: id) { showSlotSettings(forSlotAt: index) }
        case .newSlot:
            break
        }
        if picker != nil { picker = nil }
        if feedSetup != request { feedSetup = request }
    }

    public func closeFeedSetup() {
        if feedSetup != nil { feedSetup = nil }
    }

    // MARK: A slot's feeds

    /// Where a slot's readings come from, in order.
    public func readingSources(ofSlotAt index: Int) -> [ReadingSource] {
        isSlot(index) ? configs[index].readings.sources : []
    }

    /// The variables a feed can bring readings of: parameters, then values.
    public func feedTargets(ofSlotAt index: Int) -> [SlotOutput] {
        guard slots.indices.contains(index) else { return [] }
        let slot = slots[index]
        let parameters = slot.parameterValues.map { SlotOutput(name: $0.name, label: $0.label) }
        let names = Set(parameters.map(\.name))
        return parameters + slot.outputs.filter { !names.contains($0.name) }
    }

    /// The quantity of one of a slot's variables, such as percent for an interest rate.
    public func quantity(of variable: String, inSlotAt index: Int) -> Quantity? {
        guard descriptors.indices.contains(index) else { return nil }
        return descriptors[index]?.variable(named: variable)?.quantity
    }

    public func addFeed(_ spec: FeedSpec, toSlotAt index: Int) {
        guard isSlot(index) else { return }
        var config = configs[index]
        config.readings = config.readings.with(sources: config.readings.sources + [.feed(spec)])
        closeFeedSetup()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        say("Added the feed “\(spec.title)” to \(slots[focusedIndex].title). Fetching its readings…")
    }

    public func replaceFeed(at source: Int, inSlotAt index: Int, with spec: FeedSpec) {
        guard isSlot(index), configs[index].readings.sources.indices.contains(source) else { return }
        var config = configs[index]
        var sources = config.readings.sources
        sources[source] = .feed(spec)
        config.readings = config.readings.with(sources: sources)
        closeFeedSetup()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        say("Changed the feed “\(spec.title)”")
    }

    public func removeFeed(at source: Int, inSlotAt index: Int) {
        removeReadingSource(at: source, inSlotAt: index)
    }

    /// Adds a slot of its own for a feed, with a model that follows its readings and holds the
    /// latest one: the "Hold the latest" model with the feed's step. `currency` is the source's,
    /// when it gives money: the slot keeps it whatever the scenario's is.
    @discardableResult
    public func addFeedSlot(_ spec: FeedSpec, name: String, format: ValueFormat, currency: Currency? = nil, step: StepRate,
                            atPosition position: Int? = nil) -> Bool {
        guard let position = position ?? freePositions.first, freePositions.contains(position) else {
            say("All \(Self.bankSize) slots are full. Remove one first.", isError: true)
            return false
        }
        var feed = spec
        feed["into"] = "value"
        var config = SlotConfig(position: position, name: uniqueName(formulaName(fromTitle: name) ?? "Data"),
                                model: Self.dataSeriesName, kind: .formula,
                                formula: Self.dataSeriesFormula(label: spec.title, format: format, step: step),
                                variable: "value", format: format, currency: format == .currency ? currency : nil)
        config.readings = SlotReadings(sources: [.feed(feed)], parts: [])
        closeFeedSetup()
        applySlotChange(configs + [config], focus: config.id)
        showSlotSettings()
        say("Added “\(spec.title)” to slot \(position + 1). Fetching its readings…")
        return true
    }

    /// The model a feed's own slot starts with: "Hold the latest", once called "Data series".
    nonisolated static let dataSeriesName = ForecastModels.Kind.holdTheLatest.name

    /// A model that follows its readings and holds the latest one (docs/DESIGN.md, 4.6).
    nonisolated static func dataSeriesFormula(label: String, format: ValueFormat, step: StepRate) -> String {
        ForecastModels.formula(.holdTheLatest, for: ForecastModels.Value(name: "value", label: label, format: format, step: step))
    }

    /// Fetches feeds now: one slot's, or all of them.
    public func refreshFeeds(slot: UUID? = nil) {
        onRefreshFeeds?(slot)
    }

    // MARK: What feeds bring

    /// New readings for a slot's feeds, built off the main thread, by each feed as written. Not an
    /// edit: undo leaves them, and nothing in `scenario.md` changes.
    func receiveFeedReadings(_ sets: [FeedSpec: ReadingSet], forSlot id: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        var readings = configs[index].readings
        for (position, source) in readings.sources.enumerated() {
            guard case .feed(let spec) = source, let set = sets[spec] else { continue }
            readings = readings.replacing(part: position, with: set)
        }
        setReadings(readings, forSlotAt: index)
    }

    func setFeedStatus(_ status: FeedStatus?, for key: FeedKey) {
        guard feedStatuses[key] != status else { return }
        feedStatuses[key] = status
    }

    /// Slots as undo or redo puts them back, but with the readings each source has now, which may
    /// be newer than when the change was made.
    func keepingReadings(_ restored: [SlotConfig]) -> [SlotConfig] {
        restored.map { config in
            guard let current = configs.first(where: { $0.id == config.id }) else { return config }
            var config = config
            config.readings = config.readings.keepingReadings(of: current.readings)
            return config
        }
    }

    // MARK: Drawing readings

    /// The slot's readings of the value its graph shows, from `from` through `through`.
    func visibleReadings(ofSlotAt index: Int, from: Date, through: Date) -> [Sample] {
        let all = readingSamples(ofSlotAt: index)
        guard !all.isEmpty else { return [] }
        let low = Self.firstIndex(in: all, atOrAfter: from)
        // One either side, so the thin line reaches the edges.
        let high = min(all.count, Self.firstIndex(in: all, after: through) + 1)
        return Array(all[max(0, low - 1)..<high])
    }

    /// When the slot's readings of the value its graph shows begin and end.
    func readingSpan(ofSlotAt index: Int) -> (first: Date, last: Date)? {
        let all = readingSamples(ofSlotAt: index)
        guard let first = all.first, let last = all.last else { return nil }
        return (first.time, last.time)
    }

    /// The slot's latest reading of the value its graph shows at or before `date`, while `date` is
    /// within its readings: the readout before the scenario's start (docs/UI.md, 5.1).
    func reading(ofSlotAt index: Int, at date: Date) -> Double? {
        let all = readingSamples(ofSlotAt: index)
        guard let last = all.last, date <= last.time else { return nil }
        return Self.held(all, at: date)
    }

    private func readingSamples(ofSlotAt index: Int) -> [Sample] {
        guard isSlot(index) else { return [] }
        let set = configs[index].readings.set
        guard !set.readings.isEmpty else { return [] }
        let variable = configs[index].variable
        let key = set.digest + "\u{1}" + variable
        if let cached = readingSamples, cached.key == key { return cached.samples }
        let samples = set.readings.filter { $0.variable == variable }.map { Sample(time: $0.time, value: $0.value) }
        readingSamples = (key, samples)
        return samples
    }
}
