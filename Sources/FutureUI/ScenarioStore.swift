import Foundation
import Observation
import SwiftUI
import FutureDocument
import FutureEngine
import FutureFeeds
import FutureFormula
import FutureScript

/// The app's state for one scenario: its slots, what's focused, the cursor, the visible range, the
/// side pane, the command bar and undo. Views read `timelineState()`, `cursorState()` and
/// `statusText()` separately.
///
/// The scenario itself lives in a `ScenarioEngine` actor on a thread of its own. The store keeps
/// the latest results (`computed`) and draws only from those, so the main thread never waits for
/// the engine. Edits, fetches and previews go to the engine one at a time, in order.
@MainActor
@Observable
public final class ScenarioStore {
    public struct SlotInfo: Identifiable, Sendable {
        /// Stays the same for the slot's life, whatever happens to other slots.
        public let id: UUID
        /// 1-based position, as on the slot chips and hardware buttons. Positions can have gaps.
        public let key: Int
        /// Name used in formulas, e.g. "IndexFund".
        public let name: String
        /// Name shown to people, e.g. "Index fund".
        public let title: String
        /// The model's name, e.g. "Savings account".
        public let model: String
        public let kind: ModelKind
        public let variable: String
        public let colorHex: String
        /// Whether the color was chosen, rather than taken from the slot's position.
        public let hasOwnColor: Bool
        public let format: ValueFormat
        /// "Savings account · Formula · monthly".
        public let summary: String
        public let reads: String?
        /// Kinds of event the slot's formula handles, e.g. ["deposit", "withdraw"].
        public let eventKinds: [String]
        /// Parameters that `set` events can change.
        public let parameters: [String]
        /// The parameters with their labels, ranges and the values the slot starts with.
        public let parameterValues: [SlotValue]
        /// Starting values (`init` lines), such as a starting balance.
        public let startingValues: [SlotValue]
        /// What the graph can show.
        public let outputs: [SlotOutput]
        /// Kinds of event the slot sends, e.g. ["Heatwave"].
        public let emits: [String]
        /// Why the slot can't run, or nil when it runs (docs/UI.md, 5.7).
        public let pausedReason: String?

        public var color: Color { Color(hex: colorHex) }
        public var isPaused: Bool { pausedReason != nil }

        public var isScript: Bool {
            if case .script = kind { return true }
            return false
        }

        /// What the slot's text is: "formula" or "script".
        public var noun: String { isScript ? "script" : "formula" }
    }

    /// The side pane's tabs (docs/UI.md, section 3).
    public enum SidePaneTab: String, Sendable {
        case event, slot
        /// The focused slot's formula editor (docs/UI.md, 5.7).
        case formula
    }

    /// Which model picker is open (docs/UI.md, 5.7).
    public enum PickerRequest: Equatable, Sendable {
        /// Adding a model at a 0-based position.
        case add(position: Int)
        /// Changing a slot's model.
        case change(slot: UUID)
    }

    private enum Change {
        case addedEvent(slot: UUID, Event)
        case addedRule(slot: UUID, RecurringEvent)
        /// An authored event was changed in the add-event pane (`new`), or deleted (nil). `at` is
        /// where it was in its slot's list.
        case changedEvent(slot: UUID, old: Event, at: Int, new: EventDraft.Built?)
        /// Slots were added, removed, moved or changed. Undo puts the old list back.
        case slots(before: [SlotConfig], after: [SlotConfig], focusBefore: UUID?, focusAfter: UUID?)
    }

    /// A parameter or starting value being dragged on its slider.
    struct ParameterDrag {
        let slot: UUID
        let name: String
        var value: Double
    }

    /// The largest magnitude a plot's range reaches. Leaves headroom so the range, its padding and
    /// its tick steps never overflow to infinity.
    nonisolated static let plotLimit = 1e300

    nonisolated static func clampToPlot(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, -plotLimit), plotLimit)
    }

    /// A lane's vertical range: its values with a little room above and below. Always a valid,
    /// finite range, whatever the values (building a range whose bounds are out of order traps).
    nonisolated static func laneDomain(low: Double, high: Double) -> ClosedRange<Double> {
        let a = clampToPlot(low), b = clampToPlot(high)
        let low = min(a, b), high = max(a, b)
        let pad = max((high - low) * 0.12, max(abs(low), abs(high)) * 0.01, 1e-9)
        let lower = low - pad, upper = high + pad
        return lower < upper ? lower...upper : (low - 1)...(low + 1)
    }

    public static let minimumSpan: TimeInterval = 2 * 365.2425 * 86_400
    public static let maximumSpan: TimeInterval = 80 * 365.2425 * 86_400
    /// Slot positions in a bank, as on the chips and hardware.
    public static let bankSize = Scenario.bankSize

    public internal(set) var name: String
    /// The slots in position order. Positions can have gaps; `SlotInfo.key` is the position.
    public private(set) var slots: [SlotInfo]
    public let now: Date
    public private(set) var start: Date
    /// How far back the view and the cursor reach: the scenario's start, or the first reading a
    /// slot's graph draws when that's earlier. Before the start there are only readings (docs/UI.md, 5.1).
    @ObservationIgnored public private(set) var earliest: Date
    /// The scenario's own seed, or nil for the engine's (docs/DESIGN.md, 4.4).
    public private(set) var seed: UInt64?
    /// Connections and event routes between the slots that run.
    public private(set) var linkCount: Int

    public private(set) var focusedIndex = 0
    public private(set) var cursor: Date
    public private(set) var frame: TimeFrame
    /// Bumped whenever the scenario's data changes, so views refresh.
    public private(set) var revision = 0
    public private(set) var message: String?
    public private(set) var messageIsError = false
    /// Incremented to ask the view to focus the command bar.
    public private(set) var commandBarFocusRequest = 0

    public var opacity = 0.86
    public var commandText = ""

    /// Which tab the side pane shows.
    public var sidePane = SidePaneTab.event
    /// The model picker that's open, if any.
    public var picker: PickerRequest?
    /// The feed setup screen that's open, if any (docs/UI.md, 5.10).
    public var feedSetup: FeedSetupRequest?
    /// Each feed's state, for the Slot tab. `FeedCenter` keeps it (docs/DESIGN.md, 15.8).
    public internal(set) var feedStatuses: [FeedKey: FeedStatus] = [:]
    /// Asks for feeds to be fetched now: one slot's, or every slot's with nil.
    @ObservationIgnored public var onRefreshFeeds: ((UUID?) -> Void)?
    /// Where feeds' sign-ins are kept. Tests use one in memory.
    @ObservationIgnored public var credentials: any CredentialStore = KeychainCredentialStore()
    /// How feeds reach the network. Tests answer from fixtures.
    @ObservationIgnored public var feedTransport: any FeedTransport = URLSessionTransport.shared
    /// The focused graph's readings as samples, by readings digest and variable, so drawing
    /// doesn't rebuild them every frame.
    @ObservationIgnored var readingSamples: (key: String, samples: [Sample])?
    /// The slot whose removal is waiting to be confirmed in the Slot tab.
    public internal(set) var pendingRemoval: UUID?

    /// The event in the add-event pane. Always present; it targets the focused slot and starts at now.
    public var eventDraft = EventDraft(slotIndex: 0, date: .distantPast, kind: .setParameter) {
        didSet {
            guard eventDraft != oldValue else { return }
            updateDraftPreview()
            // Parameter values are read at the draft's date, for the pane's "now" hint.
            if eventDraft.date != oldValue.date || eventDraft.slotIndex != oldValue.slotIndex { requestData(force: true) }
        }
    }
    /// The draft slot's line with the draft event applied, for the dashed preview. Empty until the draft is complete.
    public internal(set) var draftPreview: [Sample] = []
    public internal(set) var draftError: String?
    /// The authored event the add-event pane is changing, after its marker was clicked (docs/UI.md, 5.4).
    public internal(set) var editingEvent: EditedEvent?
    /// Whether the pane is asking to confirm deleting the event being edited.
    public internal(set) var confirmingEventDeletion = false
    /// Incremented to ask the pane to focus its amount field.
    public internal(set) var eventFieldFocusRequest = 0
    /// Set when the Event tab should focus its field as soon as it appears.
    @ObservationIgnored var focusEventFieldOnAppear = false
    /// How far ahead the latest preview was requested.
    @ObservationIgnored var previewThrough = Date.distantPast
    /// Identifies the newest preview request; older results are dropped.
    @ObservationIgnored var previewSequence = 0

    /// The focused slot's line while a parameter's slider is dragged, or with the formula being
    /// edited, drawn dashed.
    public internal(set) var parameterPreview: [Sample] = []
    @ObservationIgnored var parameterDrag: ParameterDrag?
    @ObservationIgnored var parameterPreviewSequence = 0
    /// Refit's sheet over the Slot tab, while it's open (docs/UI.md, 5.11).
    public internal(set) var refit: RefitState?
    /// Slots that have readings of one of their values, so Refit can run for them.
    public internal(set) var refittable: Set<UUID> = []
    @ObservationIgnored var refitTask: Task<Void, Never>?
    @ObservationIgnored var refitFlag: CancelFlag?
    @ObservationIgnored var refitSequence = 0
    /// The range Refit's dashed preview covers, while it shows one.
    @ObservationIgnored var refitPreviewRange: (from: Date, through: Date)?
    /// The Predict with menu, while it's open (docs/UI.md, 5.11).
    public internal(set) var predict: PredictState?
    /// The selected model's held-back test, drawn dotted on the graph.
    public internal(set) var heldBack: HeldBackLine?
    @ObservationIgnored var predictTask: Task<Void, Never>?
    @ObservationIgnored var predictFlag: CancelFlag?
    @ObservationIgnored var predictSequence = 0
    /// The menu's models, by row id.
    @ObservationIgnored var predictCandidates: [String: PredictCandidate] = [:]
    /// Scores kept by model, values, readings and window, until one of those changes.
    @ObservationIgnored var predictScores: [String: PredictState.Phase] = [:]
    /// Why a slot's models can't be compared, kept the same way.
    @ObservationIgnored var predictProblems: [String: String] = [:]
    /// The model and values the menu's dashed preview shows, and the range it covers.
    @ObservationIgnored var predictPreview: (id: String, values: [String: Double], from: Date, through: Date)?
    /// The slot `parameterPreview` belongs to, while a slider is dragged or a formula edited.
    @ObservationIgnored var previewSlot: UUID?

    /// Formulas being edited and not yet applied, by slot id.
    public internal(set) var formulaDrafts: [UUID: String] = [:]
    /// What's wrong with each slot's formula as it's being edited, worked out shortly after typing stops.
    public internal(set) var formulaChecks: [UUID: FormulaCheck] = [:]
    @ObservationIgnored var formulaCheckTask: Task<Void, Never>?
    /// Each slot's model descriptor from the last time slots were built (nil when its formula failed).
    @ObservationIgnored var descriptors: [ModelDescriptor?] = []

    /// The latest results from the engine. Everything on screen is drawn from these.
    var computed: ScenarioEngine.FetchResult?
    /// Errors slots raised while computing, such as a script's, by slot.
    var slotFailures: [UUID: ScenarioEngine.SlotFailure] = [:]
    /// Which slot each of `computed`'s arrays belongs to, so results can follow slots that move.
    @ObservationIgnored private var computedSlots: [UUID] = []

    /// Where the graphs and lanes are, in the panel's top-left coordinates (the hosting view's). The mouse wheel moves
    /// time only over them; elsewhere it scrolls what's under the pointer, like the formula editor.
    @ObservationIgnored public internal(set) var timelineFrame = CGRect.zero

    /// Whether a point in the panel (top-left coordinates) is over the graphs and lanes.
    public func isOverTimeline(_ point: CGPoint) -> Bool {
        timelineFrame.contains(point)
    }

    /// Called when the command bar asks for something only the app can do (copying).
    @ObservationIgnored public var onAppAction: ((CommandBarAction) -> Void)?

    /// Called whenever the scenario changes in a way its file records: slots, models, values,
    /// events. The scenario's document saves then (docs/DESIGN.md, 15).
    @ObservationIgnored public var onScenarioChange: (() -> Void)?

    /// Every slot with its model, values and events, in position order. `slots` is built from these.
    @ObservationIgnored var configs: [SlotConfig]
    @ObservationIgnored private var undoStack: [Change] = []
    @ObservationIgnored private var redoStack: [Change] = []

    // The engine and its queue of work.
    @ObservationIgnored let engine: ScenarioEngine
    @ObservationIgnored private var engineQueue: [EngineOperation] = []
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private var requested: (version: Int, from: Date, through: Date)?
    /// Which way the view last scrolled; fetches reach further that way.
    @ObservationIgnored private var scrollDirection = 1.0

    /// - Parameter savedResults: results saved earlier by slot name (docs/DESIGN.md, 15.5), already
    ///   checked against the slots' fingerprints. They're put back before anything is computed.
    public init(definition: ScenarioDefinition, now: Date = Date(), savedResults: [String: SlotHistory] = [:]) throws {
        let configs = Self.configs(from: definition)
        guard !configs.isEmpty else { throw EngineError.invalidSlotName("") }
        let assembly = Self.assemble(configs)

        self.engine = try ScenarioEngine(start: definition.start, seed: definition.seed ?? Scenario.defaultSeed,
                                         layout: assembly.layout)
        self.configs = configs
        self.slots = assembly.slots
        self.linkCount = assembly.linkCount
        self.descriptors = assembly.descriptors
        self.computedSlots = assembly.slots.map(\.id)
        self.name = definition.name
        self.start = definition.start
        self.earliest = Self.earliest(start: definition.start, configs: configs)
        self.seed = definition.seed
        self.now = now
        self.cursor = max(now, definition.start)
        let year = 365.2425 * 86_400
        // Opens at the start at the earliest, as without readings before it: they're a scroll away.
        // Opening a little before the start showed only a sliver of it at the left edge.
        let frameStart = max(definition.start, now.addingTimeInterval(-5 * year))
        self.frame = TimeFrame(start: frameStart, end: frameStart.addingTimeInterval(19 * year))
        self.eventDraft = makeDraft(slotIndex: 0, date: cursor)
        let restore = Dictionary(uniqueKeysWithValues: configs.enumerated().compactMap { index, config in
            savedResults[config.name].map { (index, $0) }
        })
        if !restore.isEmpty { enqueue(.mutate(.restore(restore))) }
        updateRefittable()
        requestData()
    }

    /// The slots a definition describes, in position order. A slot without a free position is left out.
    nonisolated static func configs(from definition: ScenarioDefinition) -> [SlotConfig] {
        var configs: [SlotConfig] = []
        for spec in definition.slots {
            let taken = Set(configs.map(\.position))
            guard let position = spec.position.flatMap({ taken.contains($0) ? nil : $0 })
                    ?? (0..<Scenario.bankSize).first(where: { !taken.contains($0) }) else { break }
            var config = SlotConfig(position: position, name: spec.name, model: spec.model, kind: spec.kind,
                                    formula: spec.formula, variable: spec.variable, color: spec.color,
                                    format: spec.format, values: spec.values, events: spec.events, rules: spec.rules)
            config.readings = spec.readings
            config.problem = spec.problem
            config.showsInFile = spec.showsInFile
            config.formatInFile = spec.formatInFile
            configs.append(config)
        }
        for event in definition.events {
            guard let index = configs.firstIndex(where: { $0.name == event.slot }) else { continue }
            configs[index].events.append(event.event)
        }
        return configs.sorted { $0.position < $1.position }
    }

    public var focused: SlotInfo { slots[focusedIndex] }

    // MARK: Building slots

    struct Assembly {
        let slots: [SlotInfo]
        let layout: ScenarioEngine.Layout
        let linkCount: Int
        let descriptors: [ModelDescriptor?]
    }

    /// Compiles each slot's model, checks how the slots read each other, and describes the result
    /// for the views and the engine. Slots that can't run are paused, not dropped.
    nonisolated static func assemble(_ configs: [SlotConfig]) -> Assembly {
        var models: [(any AuthoredModel)?] = []
        var errors: [Int: String] = [:]
        for (index, config) in configs.enumerated() {
            if let problem = config.problem {
                models.append(nil)
                errors[index] = problem
                continue
            }
            do {
                models.append(try config.makeModel())
            } catch {
                models.append(nil)
                errors[index] = String(describing: error)
            }
        }
        let report = Wiring.check(configs.indices.map { (configs[$0].name, models[$0]?.descriptor) })

        var slots: [SlotInfo] = []
        var setups: [ScenarioEngine.SlotSetup?] = []
        for (index, config) in configs.enumerated() {
            let model = models[index]
            let paused = errors[index] ?? report.problems[index]?.description
            setups.append(paused == nil ? model.map {
                ScenarioEngine.SlotSetup(name: config.name, variable: config.variable, model: $0, key: config.modelKey)
            } : nil)
            slots.append(slotInfo(config, model: model, paused: paused))
        }
        let layout = ScenarioEngine.Layout(slots: setups, events: configs.map(\.events), rules: configs.map(\.rules),
                                           readings: configs.map(\.readings.set))
        return Assembly(slots: slots, layout: layout, linkCount: report.linkCount, descriptors: models.map { $0?.descriptor })
    }

    nonisolated private static func slotInfo(_ config: SlotConfig, model: (any AuthoredModel)?, paused: String?) -> SlotInfo {
        let descriptor = model?.descriptor
        let reads = descriptor?.inputs.compactMap { $0.source?.text } ?? []
        func value(_ variable: Variable) -> SlotValue {
            SlotValue(name: variable.name, label: variable.label ?? variable.name, quantity: variable.quantity ?? .number,
                      minimum: variable.minimum, maximum: variable.maximum, increment: variable.increment,
                      value: model?.startingValues[variable.name], defaultValue: model?.declaredDefaults[variable.name],
                      isChanged: config.values[variable.name] != nil)
        }
        let parameters = descriptor?.variables.filter { $0.causality == .parameter } ?? []
        let starting = (model?.startingValueNames ?? []).compactMap { descriptor?.variable(named: $0) }
        let outputs = descriptor?.variables.filter { $0.causality == .output }.map { SlotOutput(name: $0.name, label: $0.label ?? $0.name) } ?? []
        var summary = [config.model, config.kind.title]
        if let rate = descriptor?.stepRate { summary.append(rate.adverb) }
        if let emits = descriptor?.emits, !emits.isEmpty { summary.append("emits " + emits.joined(separator: ", ")) }
        return SlotInfo(id: config.id, key: config.position + 1, name: config.name, title: displayName(config.name),
                        model: config.model, kind: config.kind, variable: config.variable,
                        colorHex: config.color ?? SlotPalette.color(forSlotAt: config.position), hasOwnColor: config.color != nil,
                        format: config.format, summary: summary.joined(separator: " · "),
                        reads: reads.isEmpty ? nil : "← " + reads.joined(separator: ", "),
                        eventKinds: model?.handledEventKinds ?? [], parameters: model?.parameterNames ?? [],
                        parameterValues: parameters.map(value), startingValues: starting.map(value),
                        outputs: outputs, emits: descriptor?.emits ?? [], pausedReason: paused)
    }

    /// Replaces the slots, remembering the old ones for undo.
    func applySlotChange(_ newConfigs: [SlotConfig], focus: UUID?) {
        let sorted = newConfigs.sorted { $0.position < $1.position }
        guard sorted != configs else { return }
        undoStack.append(.slots(before: configs, after: sorted, focusBefore: slots.indices.contains(focusedIndex) ? focused.id : nil,
                                focusAfter: focus))
        redoStack.removeAll()
        configs = sorted
        refreshSlots(focus: focus)
    }

    /// Rebuilds `slots` from `configs` and sends the new layout to the engine. The latest results
    /// follow their slots, so lines stay on screen until the engine has the new ones.
    private func refreshSlots(focus: UUID?) {
        let wanted = focus ?? (slots.indices.contains(focusedIndex) ? focused.id : nil)
        let assembly = Self.assemble(configs)
        let order = assembly.slots.map(\.id)
        if let computed {
            let old = Dictionary(uniqueKeysWithValues: computedSlots.enumerated().map { ($0.element, $0.offset) })
            func pick<T>(_ list: [T], empty: T) -> [T] {
                order.map { id in old[id].flatMap { list.indices.contains($0) ? list[$0] : nil } ?? empty }
            }
            self.computed = ScenarioEngine.FetchResult(
                version: computed.version, generation: computed.generation, from: computed.from, through: computed.through,
                series: pick(computed.series, empty: []), generated: pick(computed.generated, empty: []),
                computedThrough: computed.computedThrough, parameters: pick(computed.parameters, empty: [:]),
                parameterDate: computed.parameterDate, failures: pick(computed.failures, empty: nil))
        }
        computedSlots = order
        descriptors = assembly.descriptors
        slots = assembly.slots
        let ids = Set(order)
        if formulaDrafts.keys.contains(where: { !ids.contains($0) }) { formulaDrafts = formulaDrafts.filter { ids.contains($0.key) } }
        if formulaChecks.keys.contains(where: { !ids.contains($0) }) { formulaChecks = formulaChecks.filter { ids.contains($0.key) } }
        if linkCount != assembly.linkCount { linkCount = assembly.linkCount }
        let index = slots.firstIndex { $0.id == wanted } ?? min(focusedIndex, slots.count - 1)
        if focusedIndex != index { focusedIndex = index }
        if let pendingRemoval, !slots.contains(where: { $0.id == pendingRemoval }) { self.pendingRemoval = nil }
        if case .change(let id) = picker, !slots.contains(where: { $0.id == id }) { picker = nil }
        retargetDraft(force: true)
        revision += 1
        enqueue(.mutate(.layout(assembly.layout)))
        updateEarliest()
        requestData()
        updateDraftPreview()
        updateRefittable()
        refitSlotsChanged()
        predictSlotsChanged()
        onScenarioChange?()
    }

    /// Loads every script again with the current files in the Libraries folder.
    public func reloadScripts() {
        ScriptPrograms.reloadLibraries()
        refreshSlots(focus: nil)
        if slots.indices.contains(focusedIndex), sidePane == .formula { updateFormulaCheck(forSlotAt: focusedIndex) }
        say("Reloaded the script libraries")
    }

    // MARK: Navigation

    /// Focuses a slot. The add-event pane follows the focused slot.
    public func focus(index: Int) {
        guard slots.indices.contains(index) else { return }
        if let refit, refit.slot != slots[index].id { closeRefit() }
        if let predict, predict.slot != slots[index].id { closePredict() }
        focusedIndex = index
        retargetDraft()
    }

    /// Focuses by number ("3") or name ("savings", "Index fund").
    @discardableResult
    public func focus(named text: String) -> Bool {
        guard let index = slotIndex(named: text) else { return false }
        focus(index: index)
        return true
    }

    /// Focuses the slot at a 1-based position (the number keys and hardware buttons). An empty
    /// position says how to fill it.
    public func focus(key: Int) {
        guard let index = slots.firstIndex(where: { $0.key == key }) else {
            if (1...Self.bankSize).contains(key) { say("Slot \(key) is empty. Click its chip to add a model.") }
            return
        }
        focus(index: index)
    }

    /// A slot by number ("3") or name ("savings", "Index fund", "indexfund").
    func slotIndex(named text: String) -> Int? {
        if let number = Int(text) { return slots.firstIndex { $0.key == number } }
        let wanted = text.lowercased().replacingOccurrences(of: " ", with: "")
        return slots.firstIndex(where: { $0.name.lowercased() == wanted })
    }

    public func setCursor(_ date: Date) {
        cursor = max(earliest, date)
    }

    /// Moves the cursor to a fraction (0...1) of the visible width.
    public func setCursor(fraction: Double) {
        setCursor(frame.date(atFraction: min(max(fraction, 0), 1)))
    }

    /// Moves the cursor by steps of the focused slot's rate, or by years.
    public func moveCursor(by steps: Int, years: Bool = false) {
        let component: Calendar.Component = years ? .year : .month
        let next = DateText.calendar.date(byAdding: component, value: steps, to: cursor) ?? cursor
        setCursor(next)
        reveal(cursor)
    }

    public func jumpToNow() {
        cursor = now
        reveal(now)
    }

    /// Moves the cursor to `date`, scrolling it into view if needed.
    public func show(_ date: Date) {
        setCursor(date)
        reveal(cursor)
    }

    /// Scrolls by a fraction of the visible span (positive = later).
    public func pan(by fraction: Double) {
        let shift = frame.span * fraction
        let newStart = max(earliest, frame.start.addingTimeInterval(shift))
        let newFrame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(frame.span))
        guard newFrame != frame else { return }  // as far back as it goes already: don't redraw for nothing
        if fraction != 0 { scrollDirection = fraction > 0 ? 1 : -1 }
        // The cursor moves with the view so it stays under the pointer (which doesn't move while
        // the wheel scrolls), and the readout shows the date being pointed at.
        if frame.contains(cursor) { cursor = max(earliest, cursor.addingTimeInterval(newStart.timeIntervalSince(frame.start))) }
        frame = newFrame
        frameChanged()
    }

    /// Zooms around `anchor` (the cursor by default). Factor < 1 zooms in.
    public func zoom(by factor: Double, around anchor: Date? = nil) {
        let span = min(max(frame.span * factor, Self.minimumSpan), Self.maximumSpan)
        let anchor = anchor ?? (frame.contains(cursor) ? cursor : frame.date(atFraction: 0.5))
        let proportion = anchor.timeIntervalSince(frame.start) / frame.span
        let newStart = max(earliest, anchor.addingTimeInterval(-proportion * span))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(span))
        frameChanged()
    }

    private func reveal(_ date: Date) {
        guard !frame.contains(date) else { return }
        let newStart = max(earliest, date.addingTimeInterval(-frame.span / 2))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(frame.span))
        frameChanged()
    }

    /// The scenario's start, or the first reading of the value a slot's graph shows when that's earlier.
    nonisolated static func earliest(start: Date, configs: [SlotConfig]) -> Date {
        var earliest = start
        for config in configs {
            // Readings are in time order, so the first one of the value is the earliest.
            if let first = config.readings.set.readings.first(where: { $0.variable == config.variable }), first.time < earliest {
                earliest = first.time
            }
        }
        return earliest
    }

    /// Works out `earliest` again after the slots, their readings or the start change, and keeps the
    /// view and the cursor within it.
    private func updateEarliest() {
        earliest = Self.earliest(start: start, configs: configs)
        if frame.start < earliest { frame = TimeFrame(start: earliest, end: earliest.addingTimeInterval(frame.span)) }
        if cursor < earliest { cursor = earliest }
    }

    /// After the view moves: fetch whatever isn't computed yet and extend the preview.
    private func frameChanged() {
        requestData()
        extendPreviewIfNeeded()
        extendRefitPreviewIfNeeded()
        extendPredictPreviewIfNeeded()
    }

    // MARK: Editing

    public func add(_ event: Event, toSlotAt index: Int) {
        guard configs.indices.contains(index) else { return }
        // The id reading the scenario's file would give it, so saved results still match (DESIGN.md, 15.2).
        var event = event
        event.id = EventIdentity.newID(slot: configs[index].name, key: EventIdentity.key(event),
                                       taken: Set(configs[index].events.map(\.id)))
        configs[index].events.append(event)
        undoStack.append(.addedEvent(slot: configs[index].id, event))
        redoStack.removeAll()
        send(.addEvent(slot: index, event))
    }

    public func add(_ rule: RecurringEvent, toSlotAt index: Int) {
        guard configs.indices.contains(index) else { return }
        var rule = rule
        rule.id = EventIdentity.newID(slot: configs[index].name, key: EventIdentity.key(rule),
                                      taken: Set(configs[index].rules.map(\.id)))
        configs[index].rules.append(rule)
        undoStack.append(.addedRule(slot: configs[index].id, rule))
        redoStack.removeAll()
        send(.addRule(slot: index, rule))
    }

    /// Replaces an authored event with `new` (an event or a rule), or deletes it when `new` is nil,
    /// as one change that undo takes back. Returns false when the event isn't there.
    @discardableResult
    func changeEvent(id: UUID, inSlotAt index: Int, to new: EventDraft.Built?) -> Bool {
        guard configs.indices.contains(index), let position = configs[index].events.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let old = configs[index].events.remove(at: position)
        var change: EventDraft.Built?
        var mutations: [ScenarioEngine.Mutation] = [.removeEvent(slot: index, id: old.id)]
        switch new {
        case .event(var event)?:
            // The id reading the scenario's file would give it, as for a new event (DESIGN.md, 15.2).
            event.id = EventIdentity.newID(slot: configs[index].name, key: EventIdentity.key(event),
                                           taken: Set(configs[index].events.map(\.id)))
            configs[index].events.insert(event, at: position)
            change = .event(event)
            mutations.append(.addEvent(slot: index, event))
        case .rule(var rule)?:
            rule.id = EventIdentity.newID(slot: configs[index].name, key: EventIdentity.key(rule),
                                          taken: Set(configs[index].rules.map(\.id)))
            configs[index].rules.append(rule)
            change = .rule(rule)
            mutations.append(.addRule(slot: index, rule))
        case nil:
            break
        }
        undoStack.append(.changedEvent(slot: configs[index].id, old: old, at: position, new: change))
        redoStack.removeAll()
        send(mutations)
        return true
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let change = undoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                configs[index].events.removeAll { $0.id == event.id }
                send(.removeEvent(slot: index, id: event.id))
            }
        case .addedRule(let slot, let rule):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                configs[index].rules.removeAll { $0.id == rule.id }
                send(.removeRule(slot: index, id: rule.id))
            }
        case .changedEvent(let slot, let old, let position, let new):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                var mutations: [ScenarioEngine.Mutation] = []
                switch new {
                case .event(let event)?:
                    configs[index].events.removeAll { $0.id == event.id }
                    mutations.append(.removeEvent(slot: index, id: event.id))
                case .rule(let rule)?:
                    configs[index].rules.removeAll { $0.id == rule.id }
                    mutations.append(.removeRule(slot: index, id: rule.id))
                case nil:
                    break
                }
                configs[index].events.insert(old, at: min(position, configs[index].events.count))
                mutations.append(.addEvent(slot: index, old))
                send(mutations)
            }
        case .slots(let before, _, let focusBefore, _):
            configs = keepingReadings(before)
            refreshSlots(focus: focusBefore)
        }
        redoStack.append(change)
        followEditedEvent()
        say("Undone")
    }

    public func redo() {
        guard let change = redoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                configs[index].events.append(event)
                send(.addEvent(slot: index, event))
            }
        case .addedRule(let slot, let rule):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                configs[index].rules.append(rule)
                send(.addRule(slot: index, rule))
            }
        case .changedEvent(let slot, let old, let position, let new):
            if let index = configs.firstIndex(where: { $0.id == slot }) {
                configs[index].events.removeAll { $0.id == old.id }
                var mutations: [ScenarioEngine.Mutation] = [.removeEvent(slot: index, id: old.id)]
                switch new {
                case .event(let event)?:
                    configs[index].events.insert(event, at: min(position, configs[index].events.count))
                    mutations.append(.addEvent(slot: index, event))
                case .rule(let rule)?:
                    configs[index].rules.append(rule)
                    mutations.append(.addRule(slot: index, rule))
                case nil:
                    break
                }
                send(mutations)
            }
        case .slots(_, let after, _, let focusAfter):
            configs = keepingReadings(after)
            refreshSlots(focus: focusAfter)
        }
        undoStack.append(change)
        followEditedEvent()
        say("Redone")
    }

    /// Sends an edit to the engine, then refetches and re-previews. The queue keeps them in order.
    private func send(_ mutations: ScenarioEngine.Mutation...) {
        send(mutations)
    }

    /// Sends edits that belong together, with one refetch after them.
    private func send(_ mutations: [ScenarioEngine.Mutation]) {
        revision += 1
        for mutation in mutations { enqueue(.mutate(mutation)) }
        requestData()
        updateDraftPreview()
        onScenarioChange?()
    }

    /// Gives a slot new readings without making it an edit: undo leaves them (docs/DESIGN.md, 15.8).
    func setReadings(_ readings: SlotReadings, forSlotAt index: Int) {
        guard isSlot(index), readings != configs[index].readings else { return }
        configs[index].readings = readings
        revision += 1
        enqueue(.mutate(.readings(slot: index, readings.set)))
        updateEarliest()
        requestData()
        updateDraftPreview()
        updateRefittable()
    }

    /// Forgets undo and redo, when the scenario is replaced from its file with a new start or seed.
    func clearUndo() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Replaces the scenario's name, start and seed, and its slots, building the engine's scenario
    /// again. Undo starts afresh.
    func replaceScenario(name: String, start: Date, seed: UInt64?, configs newConfigs: [SlotConfig], focus: UUID?) {
        self.name = name
        self.start = start
        self.seed = seed
        configs = newConfigs.sorted { $0.position < $1.position }
        clearUndo()
        let assembly = Self.assemble(configs)
        enqueue(.mutate(.rebuild(start: start, seed: seed ?? Scenario.defaultSeed, layout: assembly.layout)))
        refreshSlots(focus: focus)  // which keeps the view and cursor within the new start's reach
    }

    /// A copy of a slot for Refit, made after everything already queued (docs/DESIGN.md, 8.4).
    func copyForFitting(slotAt index: Int) async -> ScenarioEngine.FittingCopy {
        await withCheckedContinuation { reply in
            enqueue(.copyForFitting(slot: index, reply: reply))
        }
    }

    /// Results worth saving (docs/DESIGN.md, 15.5), by slot index in `configs` as it is now. The
    /// engine answers after everything already queued.
    func resultsToSave(minimumSeconds: Double) async -> [Int: SlotHistory] {
        await withCheckedContinuation { reply in
            enqueue(.export(minimumSeconds: minimumSeconds, reply: reply))
        }
    }

    // MARK: Engine queue

    private enum EngineOperation {
        case mutate(ScenarioEngine.Mutation)
        case fetch(ScenarioEngine.FetchRequest)
        case preview(ScenarioEngine.PreviewRequest)
        case find(ScenarioEngine.FindRequest)
        case export(minimumSeconds: Double, reply: CheckedContinuation<[Int: SlotHistory], Never>)
        case copyForFitting(slot: Int, reply: CheckedContinuation<ScenarioEngine.FittingCopy, Never>)

        var isFetch: Bool { if case .fetch = self { return true } else { return false } }
        /// Draft-event previews and slider previews replace only their own kind.
        var previewOfModel: Bool? {
            guard case .preview(let request) = self else { return nil }
            if case .model = request.change { return true }
            return false
        }
    }

    /// Whether the engine has no work queued or running.
    public var isEngineIdle: Bool { !isDraining && engineQueue.isEmpty }

    /// Waits until the engine has finished everything queued, and its results are on screen.
    public func waitUntilIdle() async {
        while !isEngineIdle {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// Queues work for the engine. A new fetch or preview replaces one still waiting (only the
    /// newest matters); edits are never dropped or reordered.
    private func enqueue(_ operation: EngineOperation) {
        switch operation {
        case .fetch: engineQueue.removeAll(where: \.isFetch)
        case .preview: engineQueue.removeAll { $0.previewOfModel == operation.previewOfModel }
        case .mutate, .find, .export, .copyForFitting: break
        }
        engineQueue.append(operation)
        guard !isDraining else { return }
        isDraining = true
        Task { await drainEngineQueue() }
    }

    private func drainEngineQueue() async {
        while !engineQueue.isEmpty {
            switch engineQueue.removeFirst() {
            case .mutate(let mutation): await engine.apply(mutation)
            case .fetch(let request): receive(await engine.fetch(request))
            case .preview(let request):
                let result = await engine.preview(request)
                if case .model = request.change { receiveParameterPreview(result) } else { receive(result) }
            case .find(let request): receive(await engine.find(request))
            case .export(let minimum, let reply): reply.resume(returning: await engine.resultsToSave(minimumSeconds: minimum))
            case .copyForFitting(let slot, let reply): reply.resume(returning: await engine.copyForFitting(slot: slot))
            }
        }
        isDraining = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Asks the engine for the visible range plus some to spare, reaching further in the direction
    /// of scrolling. Does nothing when the latest results (or a request on its way) already cover the view.
    func requestData(force: Bool = false) {
        let span = frame.span
        let neededFrom = max(start, frame.start.addingTimeInterval(-span * 0.1))
        let neededThrough = frame.end.addingTimeInterval(span * 0.1)
        if !force {
            if let computed, computed.version == revision, computed.from <= neededFrom, computed.through >= neededThrough { return }
            if let requested, requested.version == revision, requested.from <= neededFrom, requested.through >= neededThrough { return }
        }
        let behind = scrollDirection < 0 ? 1.5 : 0.5
        let ahead = scrollDirection < 0 ? 0.5 : 1.5
        let from = max(start, frame.start.addingTimeInterval(-span * behind))
        let through = frame.end.addingTimeInterval(span * ahead)
        fetchGeneration += 1
        engine.latestGeneration.advance(to: fetchGeneration)
        requested = (revision, from, through)
        enqueue(.fetch(ScenarioEngine.FetchRequest(version: revision, generation: fetchGeneration, from: from,
                                                   through: through, parameterDate: eventDraft.date)))
    }

    private func receive(_ result: ScenarioEngine.FetchResult) {
        guard result.version == revision else { return }  // an edit came after this was asked for
        if let computed, computed.version == revision, computed.generation > result.generation { return }
        computed = result
        noteFailures(result.failures)
        requestData()  // the view may have moved on, or this fetch was cut short
    }

    /// Keeps the errors slots raised while computing, and says so when one first appears.
    private func noteFailures(_ list: [ScenarioEngine.SlotFailure?]) {
        var failures: [UUID: ScenarioEngine.SlotFailure] = [:]
        for (index, failure) in list.enumerated() where computedSlots.indices.contains(index) {
            if let failure { failures[computedSlots[index]] = failure }
        }
        guard failures != slotFailures else { return }
        let new = failures.filter { slotFailures[$0.key] != $0.value }
        slotFailures = failures
        for (id, failure) in new {
            guard let index = slotIndex(id: id) else { continue }
            say("\(slots[index].title) stopped after \(DateText.monthYear(failure.date)): \(failure.text)", isError: true)
        }
        if slots.indices.contains(focusedIndex), sidePane == .formula { updateFormulaCheck(forSlotAt: focusedIndex) }
    }

    func requestPreview(_ request: ScenarioEngine.PreviewRequest) {
        enqueue(.preview(request))
    }

    private func receive(_ result: ScenarioEngine.PreviewResult) {
        guard result.sequence == previewSequence, result.version == revision else { return }
        draftPreview = result.samples
    }

    private func receiveParameterPreview(_ result: ScenarioEngine.PreviewResult) {
        guard let id = previewSlot, result.sequence == parameterPreviewSequence, result.version == revision else { return }
        parameterPreview = result.samples
        if let failure = result.failure { noteDraftFailure(failure, inSlot: id) }
    }

    // MARK: Command bar

    public func requestCommandBarFocus(prefill: String? = nil) {
        if let prefill { commandText = prefill }
        commandBarFocusRequest += 1
    }

    /// Runs `commandText`. Returns the action for the caller to finish (copying needs AppKit),
    /// or nil when it was handled here or failed.
    @discardableResult
    public func runCommand() -> CommandBarAction? {
        do {
            let action = try CommandBarParser.parse(commandText)
            let handledHere = try perform(action)
            commandText = ""
            return handledHere ? nil : action
        } catch let error as CommandBarError {
            say(error.description, isError: true)
        } catch {
            say(String(describing: error), isError: true)
        }
        return nil
    }

    /// Runs the command bar's text and hands app-level actions to `onAppAction`.
    public func runCommandFromPanel() {
        if let action = runCommand() { onAppAction?(action) }
    }

    /// Performs an action. Returns false for actions the app must finish (copying).
    func perform(_ action: CommandBarAction) throws -> Bool {
        switch action {
        case .jumpToNow:
            jumpToNow()
            say("Now: " + DateText.monthYear(now))
        case .moveCursor(let date):
            show(date)
            say("Cursor at " + DateText.monthYear(cursor))
        case .findValue(let name, let value, let format):
            guard let index = slotForValue(named: name, format: format, value: value) else { return true }
            findValue(value, inSlotAt: index)
        case .focus(let text):
            guard focus(named: text) else { throw CommandBarError.notUnderstood("focus " + text) }
            say("Focused " + focused.title)
        case .addEvent(let kind, let amount, let at, let repeats):
            let when = at ?? cursor
            let values = ["amount": amount]
            let sign = kind == "deposit" ? "+" : "−"
            let amountText = sign + ValueFormat.currency.full(amount).replacingOccurrences(of: "−", with: "")
            if let repeats {
                add(RecurringEvent(kind: kind, values: values, first: when, every: repeats), toSlotAt: focusedIndex)
                say("Added \(amountText) \(Self.describe(repeats)) from \(DateText.monthYear(when)) to \(focused.title)")
            } else {
                add(Event(time: when, kind: kind, values: values), toSlotAt: focusedIndex)
                say("Added \(amountText) on \(DateText.monthYear(when)) to \(focused.title)")
            }
        case .setParameter(let name, let value, let at):
            let parameters = focused.parameters
            guard parameters.contains(name) else {
                say("\(focused.title) has no parameter called \(name). Its parameters: \(parameters.joined(separator: ", ")).", isError: true)
                return true
            }
            let when = at ?? cursor
            add(Event.set([name: value], at: when), toSlotAt: focusedIndex)
            say("Set \(name) to \(ValueFormat.number.axis(value)) from \(DateText.monthYear(when)) in \(focused.title)")
        case .addModel(let text, let key):
            guard let template = ModelLibrary.named(text) else {
                say("There's no model called “\(text)”. Try savings account, loan, index fund or seasonal temperature.", isError: true)
                return true
            }
            if let key {
                guard (1...Self.bankSize).contains(key) else {
                    say("Slots go from 1 to \(Self.bankSize).", isError: true)
                    return true
                }
                if let taken = slots.first(where: { $0.key == key }) {
                    say("Slot \(key) has \(taken.title) in it. Remove it first, or add to another slot.", isError: true)
                    return true
                }
            }
            addModel(template, atPosition: key.map { $0 - 1 })
        case .removeSlot(let text):
            guard let index = slotIndex(named: text) else {
                say("There's no slot called “\(text)”. Slots: \(slots.map(\.title).joined(separator: ", ")).", isError: true)
                return true
            }
            guard canRemoveSlot else {
                say("A scenario needs at least one slot. Change its model instead.", isError: true)
                return true
            }
            requestRemoval(ofSlotAt: index)
            say("Confirm in the Slot tab to remove \(slots[index].title).")
        case .refit(let text):
            guard let index = text.map(slotIndex(named:)) ?? focusedIndex else {
                say("There's no slot called “\(text ?? "")”. Slots: \(slots.map(\.title).joined(separator: ", ")).", isError: true)
                return true
            }
            openRefit(slotAt: index)
        case .predict(let text, let model):
            guard let index = text.map(slotIndex(named:)) ?? focusedIndex else {
                say("There's no slot called “\(text ?? "")”. Slots: \(slots.map(\.title).joined(separator: ", ")).", isError: true)
                return true
            }
            if openPredict(slotAt: index, with: model), model != nil {
                say("↩ in the menu chooses the selected model, Esc leaves it as it is.")
            }
        case .undo:
            undo()
        case .redo:
            redo()
        case .copySnapshot, .copyData:
            return false
        }
        return true
    }

    // MARK: Finding values

    /// How far ahead `goto` looks for a value before giving up.
    static let findHorizon: TimeInterval = 10_000 * 365.2425 * 86_400

    /// The slot a `goto` value refers to: the named one, else the focused slot if it's in the value's
    /// unit, else the only slot in that unit. Explains the problem and returns nil otherwise.
    func slotForValue(named name: String?, format: ValueFormat?, value: Double) -> Int? {
        func unit(_ format: ValueFormat) -> String {
            switch format {
            case .currency: return "dollars"
            case .temperature: return "°C"
            case .number: return "plain numbers"
            case .percent: return "percent"
            }
        }
        if let name {
            guard let index = slotIndex(named: name) else {
                say("There's no slot called “\(name)”. Slots: \(slots.map(\.title).joined(separator: ", ")).", isError: true)
                return nil
            }
            let slot = slots[index]
            if let format, format != slot.format {
                say("\(slot.title) is in \(unit(slot.format)), not \(unit(format)).", isError: true)
                return nil
            }
            return index
        }
        guard let format else { return focusedIndex }
        if focused.format == format { return focusedIndex }
        let matches = slots.indices.filter { slots[$0].format == format }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            say("No slot is in \(unit(format)).", isError: true)
        } else {
            let names = matches.map { slots[$0].title }
            say("Which slot? \(names.dropLast().joined(separator: ", ")) and \(names.last!) are in \(unit(format)). "
                + "Try goto \(names[0].lowercased()) \(format.axis(value)), or focus one first.", isError: true)
        }
        return nil
    }

    /// Focuses the slot and moves the cursor to where its line first reaches `value`, looking ahead
    /// from now. The engine searches in the background, after any edits already queued.
    public func findValue(_ value: Double, inSlotAt index: Int) {
        guard slots.indices.contains(index) else { return }
        focus(index: index)
        let from = max(now, start)
        say("Looking for \(slots[index].format.full(value)) in \(slots[index].title)…")
        enqueue(.find(ScenarioEngine.FindRequest(slot: index, target: value, from: from,
                                                 limit: from.addingTimeInterval(Self.findHorizon))))
    }

    private func receive(_ result: ScenarioEngine.FindResult) {
        let slot = slots[result.request.slot]
        let target = slot.format.full(result.request.target)
        guard let startValue = result.startValue else {
            say("\(slot.title) has no value to start from yet.", isError: true)
            return
        }
        let verb = startValue < result.request.target ? "reaches" : "falls to"
        guard let found = result.found else {
            let verbNow = startValue < result.request.target ? "reach" : "fall to"
            say("\(slot.title) doesn't \(verbNow) \(target) in the next 10,000 years.", isError: true)
            return
        }
        if found.time == result.request.from {
            show(found.time)
            say("\(slot.title) is at \(target) now.")
            return
        }
        show(found.time)
        say("\(slot.title) \(verb) \(target) in \(DateText.monthYear(found.time)).")
    }

    public func say(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }

    static func describe(_ rate: StepRate) -> String {
        switch rate {
        case .days(1): return "every day"
        case .weeks(1): return "every week"
        case .weeks(2): return "every 2 weeks"
        case .months(1): return "every month"
        case .quarters(1): return "every quarter"
        case .years(1): return "every year"
        default: return "on a schedule"
        }
    }

    // MARK: State for drawing
    //
    // Views read these separately so that SwiftUI only redraws what changed: moving the pointer
    // touches `cursor` alone, which only the cursor views read. All of them draw from `computed`.

    /// Everything the timeline draws that doesn't depend on the cursor.
    public func timelineState() -> TimelineState {
        _ = revision
        let margin: TimeInterval = 62 * 86_400
        let from = frame.start.addingTimeInterval(-margin)
        let through = frame.end.addingTimeInterval(margin)
        let computed = self.computed

        func samples(_ index: Int) -> [Sample] {
            guard let all = computed?.series, all.indices.contains(index), !slots[index].isPaused else { return [] }
            let series = all[index]
            guard !series.isEmpty else { return [] }
            let low = Self.firstIndex(in: series, atOrAfter: from)
            let high = Self.firstIndex(in: series, after: through)
            return low < high ? Array(series[low..<high]) : []
        }
        /// The visible values' range. Values that overflowed (infinite or NaN) can't be placed on an
        /// axis, so they're left out and the line breaks there; the rest is clamped so a range
        /// and its padding stay finite.
        func range(_ list: [Sample]) -> (low: Double, high: Double)? {
            var low = Double.infinity, high = -Double.infinity
            for sample in list where sample.value.isFinite && frame.contains(sample.time) {
                low = min(low, sample.value)
                high = max(high, sample.value)
            }
            guard low <= high else { return nil }
            return (Self.clampToPlot(low), Self.clampToPlot(high))
        }

        let focusSlot = focused
        let focusSamples = samples(focusedIndex)
        let draftOnFocus = eventDraft.slotIndex == focusedIndex ? eventDraft : nil
        // Read every time, so the graph redraws when a preview arrives. `previewSlot` isn't
        // observed, so reading this only after checking it would miss a preview that arrives later,
        // such as Refit's.
        let slotPreview = parameterPreview
        let dragging = previewSlot == focusSlot.id && !slotPreview.isEmpty
        let held = heldBack.flatMap { $0.slot == focusSlot.id ? $0 : nil }
        let preview = dragging ? slotPreview : draftOnFocus == nil ? [] : draftPreview
        let readings = visibleReadings(ofSlotAt: focusedIndex, from: from, through: through)
        let lineRange = range(focusSamples), previewRange = range(preview), readingRange = range(readings)
        let heldRange = range(held?.line ?? [])
        let lows: [Double] = [lineRange?.low ?? readingRange?.low ?? 0, previewRange?.low ?? .infinity,
                              readingRange?.low ?? .infinity, heldRange?.low ?? .infinity]
        let highs: [Double] = [lineRange?.high ?? readingRange?.high ?? 1, previewRange?.high ?? -.infinity,
                               readingRange?.high ?? -.infinity, heldRange?.high ?? -.infinity]
        let low = lows.min()!, high = highs.max()!
        let (domain, ticks) = niceTicks(low: low, high: high, includeZero: focusSlot.format == .currency)
        let focus = FocusedSlotState(
            index: focusedIndex, name: focusSlot.title, summary: focusSlot.summary, color: focusSlot.color,
            format: focusSlot.format, samples: focusSamples, readings: readings, preview: preview,
            heldBack: held?.line ?? [], cutoff: held?.cutoff,
            draftDate: dragging ? nil : draftOnFocus?.date,
            yDomain: domain, yTicks: ticks, events: markers(forSlotAt: focusedIndex),
            editingEventID: editingEvent?.slot == focusSlot.id ? editingEvent?.event.id : nil,
            pausedReason: focusSlot.pausedReason, stoppedReason: slotFailures[focusSlot.id]?.text)

        let lanes = slots.enumerated().filter { $0.offset != focusedIndex }.map { index, slot -> LaneState in
            let list = samples(index)
            let bounds = range(list) ?? (0, 1)
            return LaneState(id: index, key: slot.key, name: slot.title, color: slot.color, samples: list,
                             yDomain: Self.laneDomain(low: bounds.low, high: bounds.high), reads: slot.reads,
                             pausedReason: slot.pausedReason, stoppedReason: slotFailures[slot.id]?.text)
        }

        return TimelineState(scenarioName: name, frame: frame, now: now, start: start, focus: focus, lanes: lanes,
                             yearTicks: TimelineState.yearTicks(for: frame))
    }

    /// The readout and lane values at the cursor, from the latest results. Shows "…" while the
    /// cursor is past what's been computed.
    public func cursorState() -> CursorState {
        let computed = self.computed
        // Before the start there's no model, only readings (docs/UI.md, 5.1).
        let beforeStart = cursor < start
        let ready = computed.map { !beforeStart && cursor <= $0.through } ?? false
        func value(_ index: Int) -> Double? {
            guard ready, !slots[index].isPaused, let all = computed?.series, all.indices.contains(index) else { return nil }
            return Self.held(all[index], at: cursor)
        }
        let focusSlot = focused
        let focusValue = value(focusedIndex)
        var laneValues: [Int: String] = [:]
        for (index, slot) in slots.enumerated() where index != focusedIndex {
            laneValues[index] = slot.isPaused ? "Paused" : beforeStart ? "—" : ready ? (value(index).map(slot.format.full) ?? "—") : "…"
        }
        if focusSlot.isPaused {
            return CursorState(date: cursor, readoutDate: DateText.monthYear(cursor), readoutValue: "—",
                               readoutNote: "Paused", focusValue: nil, laneValues: laneValues)
        }
        if beforeStart {
            let reading = reading(ofSlotAt: focusedIndex, at: cursor)
            return CursorState(date: cursor, readoutDate: DateText.monthYear(cursor),
                               readoutValue: reading.map(focusSlot.format.full) ?? "—",
                               readoutNote: reading == nil ? "Before the start" : "Reading",
                               focusValue: reading, laneValues: laneValues)
        }
        let observed = readingSpan(ofSlotAt: focusedIndex).map { cursor >= $0.first && cursor <= $0.last } ?? false
        return CursorState(date: cursor, readoutDate: DateText.monthYear(cursor),
                           readoutValue: ready ? (focusValue.map(focusSlot.format.full) ?? "—") : "…",
                           readoutNote: !ready ? "Computing" : observed ? "Reading" : cursor > now ? "Projection" : "Model",
                           focusValue: focusValue, laneValues: laneValues)
    }

    /// "Computed through Dec 2045 · 5 of 8 slots · 1 link".
    public func statusText() -> String {
        let paused = slots.filter(\.isPaused).count
        return [
            computed?.computedThrough.map { "Computed through " + DateText.monthYear($0) }
                ?? (paused == slots.count ? "Nothing to compute" : "Computing…"),
            "\(slots.count) of \(Scenario.bankSize) slots",
            "\(linkCount) link\(linkCount == 1 ? "" : "s")",
        ].joined(separator: " · ") + (paused > 0 ? " · \(paused) paused" : "")
    }

    /// The whole panel at once, for clipboard snapshots and tests.
    public func panelState() -> PanelState {
        PanelState(timeline: timelineState(), cursor: cursorState(), status: statusText(), eventPreview: eventPreview())
    }

    private func markers(forSlotAt index: Int) -> [EventMarker] {
        var markers: [EventMarker] = []
        for event in configs[index].events where event.time <= frame.end {
            markers.append(EventMarker(id: event.id, date: event.time, endDate: nil, label: label(for: event, inSlotAt: index), kind: .oneOff))
        }
        for rule in configs[index].rules where rule.first <= frame.end {
            let end = min(rule.until ?? frame.end, frame.end)
            let amount = rule.values["amount"].map { ValueFormat.currency.full($0) } ?? ""
            let sign = rule.kind == "withdraw" ? "−" : "+"
            markers.append(EventMarker(id: rule.id, date: rule.first, endDate: end,
                                       label: "\(sign)\(amount) \(Self.describe(rule.every))", kind: .recurring))
        }
        let generated = computed.flatMap { $0.generated.indices.contains(index) ? $0.generated[index] : nil } ?? []
        for event in generated where frame.contains(event.time) {
            markers.append(EventMarker(id: event.id, date: event.time, endDate: nil, label: event.kind, kind: .generated))
        }
        return markers.sorted { $0.date < $1.date }
    }

    /// The last sample at or before `date`.
    static func held(_ samples: [Sample], at date: Date) -> Double? {
        let index = firstIndex(in: samples, after: date) - 1
        return index >= 0 ? samples[index].value : nil
    }

    /// The first sample after `date` (binary search). Compares dates directly: nudging `date` by a
    /// microsecond instead stops working past about 2150, where a Date can't hold that difference.
    static func firstIndex(in samples: [Sample], after date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The first sample at or after `date` (binary search).
    static func firstIndex(in samples: [Sample], atOrAfter date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Like `label(for:)`, with a parameter change in the model's words: "Interest rate → 4%".
    func label(for event: Event, inSlotAt index: Int) -> String {
        guard event.kind == Event.setKind, slots.indices.contains(index) else { return Self.label(for: event) }
        return event.values.sorted { $0.key < $1.key }.map { name, value in
            guard let parameter = slots[index].parameterValues.first(where: { $0.name == name }) else {
                return "\(name) → \(ValueFormat.number.axis(value))"
            }
            return "\(parameter.label) → \(parameter.text(value))"
        }.joined(separator: ", ")
    }

    static func label(for event: Event) -> String {
        let amount = event.values["amount"].map { ValueFormat.currency.full($0) }
        switch event.kind {
        case "deposit": return "+" + (amount ?? "")
        case "withdraw": return "−" + (amount ?? "")
        case "overpay": return "−" + (amount ?? "") + " overpayment"
        case Event.setKind:
            return event.values.sorted { $0.key < $1.key }
                .map { "\($0.key) → \(ValueFormat.number.axis($0.value))" }.joined(separator: ", ")
        default: return event.kind
        }
    }

    // MARK: Snapshot

    /// The visible data for the clipboard: the focused slot first, then the lanes.
    public func snapshotData() -> SnapshotData {
        let state = panelState()
        var order = [focusedIndex]
        order += slots.indices.filter { $0 != focusedIndex }
        let slotData = order.map { index in
            let slot = slots[index]
            let series = computed.flatMap { $0.series.indices.contains(index) ? $0.series[index] : nil } ?? []
            let points = (slot.isPaused ? [] : series)
                .filter { frame.contains($0.time) }
                .map { SnapshotData.Point(t: $0.time, v: $0.value) }
            return SnapshotData.Slot(name: slot.title, variable: slot.variable, color: slot.colorHex,
                                     format: slot.format, points: points)
        }
        return SnapshotData(scenario: name, createdAt: Date(), start: state.frame.start, end: state.frame.end,
                            cursor: cursor, now: now, slots: slotData)
    }
}

extension Color {
    /// `Color(hex: "#5AA9FF")`
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}
