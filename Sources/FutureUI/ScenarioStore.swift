import Foundation
import Observation
import SwiftUI
import FutureEngine
import FutureFormula

/// The app's state for one scenario: what's focused, the cursor, the visible range, the add-event
/// draft, the command bar and undo. Views read `timelineState()`, `cursorState()` and `statusText()`
/// separately.
///
/// The scenario itself lives in a `ScenarioEngine` actor on a thread of its own. The store keeps
/// the latest results (`computed`) and draws only from those, so the main thread never waits for
/// the engine. Edits, fetches and previews go to the engine one at a time, in order.
@MainActor
@Observable
public final class ScenarioStore {
    public struct SlotInfo: Identifiable, Sendable {
        public let id: SlotID
        /// 1-based position, as on the slot chips and hardware buttons.
        public let key: Int
        /// Name used in formulas, e.g. "IndexFund".
        public let name: String
        /// Name shown to people, e.g. "Index fund".
        public let title: String
        public let variable: String
        public let colorHex: String
        public let format: ValueFormat
        public let summary: String
        public let reads: String?
        /// Kinds of event the slot's formula handles, e.g. ["deposit", "withdraw"].
        public let eventKinds: [String]
        /// Parameters that `set` events can change.
        public let parameters: [String]

        public var color: Color { Color(hex: colorHex) }
    }

    private enum Change {
        case addedEvent(slot: Int, Event)
        case addedRule(slot: Int, RecurringEvent)
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

    public let name: String
    public let slots: [SlotInfo]
    public let now: Date
    public let start: Date

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
    /// Incremented to ask the pane to focus its amount field.
    public internal(set) var eventFieldFocusRequest = 0
    /// How far ahead the latest preview was requested.
    @ObservationIgnored var previewThrough = Date.distantPast
    /// Identifies the newest preview request; older results are dropped.
    @ObservationIgnored var previewSequence = 0

    /// The latest results from the engine. Everything on screen is drawn from these.
    var computed: ScenarioEngine.FetchResult?

    /// Called when the command bar asks for something only the app can do (copying).
    @ObservationIgnored public var onAppAction: ((CommandBarAction) -> Void)?

    /// The store's own copy of each slot's authored events and rules, for drawing markers
    /// without asking the engine.
    @ObservationIgnored private var authored: [[Event]]
    @ObservationIgnored private var recurring: [[RecurringEvent]]
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

    public let linkCount: Int

    public init(definition: ScenarioDefinition, now: Date = Date()) throws {
        var infos: [SlotInfo] = []
        var setups: [ScenarioEngine.SlotSetup] = []
        for (index, spec) in definition.slots.enumerated() {
            let model = try FormulaModel(spec.formula, name: spec.name)
            let reads = model.descriptor.inputs.compactMap { $0.source?.text }
            infos.append(SlotInfo(id: SlotID(rawValue: index), key: index + 1, name: spec.name, title: displayName(spec.name),
                                  variable: spec.variable, colorHex: spec.color ?? SlotPalette.color(forSlotAt: index),
                                  format: spec.format, summary: spec.summary,
                                  reads: reads.isEmpty ? nil : "← " + reads.joined(separator: ", "),
                                  eventKinds: model.handledEventKinds, parameters: model.parameterNames))
            setups.append(ScenarioEngine.SlotSetup(name: spec.name, variable: spec.variable, model: model))
        }
        var authored = Array(repeating: [Event](), count: definition.slots.count)
        var initial: [(slot: Int, event: Event)] = []
        for event in definition.events {
            guard let index = definition.slots.firstIndex(where: { $0.name == event.slot }) else { continue }
            authored[index].append(event.event)
            initial.append((index, event.event))
        }
        let engine = try ScenarioEngine(start: definition.start, slots: setups, events: initial)

        self.engine = engine
        self.linkCount = engine.linkCount
        self.authored = authored
        self.recurring = Array(repeating: [], count: definition.slots.count)
        self.name = definition.name
        self.slots = infos
        self.start = definition.start
        self.now = now
        self.cursor = now
        let year = 365.2425 * 86_400
        let frameStart = max(definition.start, now.addingTimeInterval(-5 * year))
        self.frame = TimeFrame(start: frameStart, end: frameStart.addingTimeInterval(19 * year))
        self.eventDraft = makeDraft(slotIndex: 0, date: now)
        requestData()
    }

    public var focused: SlotInfo { slots[focusedIndex] }

    // MARK: Navigation

    /// Focuses a slot. The add-event pane follows the focused slot.
    public func focus(index: Int) {
        guard slots.indices.contains(index) else { return }
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

    /// A slot by number ("3") or name ("savings", "Index fund", "indexfund").
    func slotIndex(named text: String) -> Int? {
        if let number = Int(text), slots.indices.contains(number - 1) { return number - 1 }
        let wanted = text.lowercased().replacingOccurrences(of: " ", with: "")
        return slots.firstIndex(where: { $0.name.lowercased() == wanted })
    }

    public func setCursor(_ date: Date) {
        cursor = max(start, date)
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
        let newStart = max(start, frame.start.addingTimeInterval(shift))
        let newFrame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(frame.span))
        guard newFrame != frame else { return }  // at the start already: don't redraw for nothing
        if fraction != 0 { scrollDirection = fraction > 0 ? 1 : -1 }
        // The cursor moves with the view so it stays under the pointer (which doesn't move while
        // the wheel scrolls), and the readout shows the date being pointed at.
        if frame.contains(cursor) { cursor = max(start, cursor.addingTimeInterval(newStart.timeIntervalSince(frame.start))) }
        frame = newFrame
        frameChanged()
    }

    /// Zooms around `anchor` (the cursor by default). Factor < 1 zooms in.
    public func zoom(by factor: Double, around anchor: Date? = nil) {
        let span = min(max(frame.span * factor, Self.minimumSpan), Self.maximumSpan)
        let anchor = anchor ?? (frame.contains(cursor) ? cursor : frame.date(atFraction: 0.5))
        let proportion = anchor.timeIntervalSince(frame.start) / frame.span
        let newStart = max(start, anchor.addingTimeInterval(-proportion * span))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(span))
        frameChanged()
    }

    private func reveal(_ date: Date) {
        guard !frame.contains(date) else { return }
        let newStart = max(start, date.addingTimeInterval(-frame.span / 2))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(frame.span))
        frameChanged()
    }

    /// After the view moves: fetch whatever isn't computed yet and extend the preview.
    private func frameChanged() {
        requestData()
        extendPreviewIfNeeded()
    }

    // MARK: Editing

    public func add(_ event: Event, toSlotAt index: Int) {
        authored[index].append(event)
        undoStack.append(.addedEvent(slot: index, event))
        redoStack.removeAll()
        send(.addEvent(slot: index, event))
    }

    public func add(_ rule: RecurringEvent, toSlotAt index: Int) {
        recurring[index].append(rule)
        undoStack.append(.addedRule(slot: index, rule))
        redoStack.removeAll()
        send(.addRule(slot: index, rule))
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let change = undoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event):
            authored[slot].removeAll { $0.id == event.id }
            send(.removeEvent(slot: slot, id: event.id))
        case .addedRule(let slot, let rule):
            recurring[slot].removeAll { $0.id == rule.id }
            send(.removeRule(slot: slot, id: rule.id))
        }
        redoStack.append(change)
        say("Undone")
    }

    public func redo() {
        guard let change = redoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event):
            authored[slot].append(event)
            send(.addEvent(slot: slot, event))
        case .addedRule(let slot, let rule):
            recurring[slot].append(rule)
            send(.addRule(slot: slot, rule))
        }
        undoStack.append(change)
        say("Redone")
    }

    /// Sends an edit to the engine, then refetches and re-previews. The queue keeps them in order.
    private func send(_ mutation: ScenarioEngine.Mutation) {
        revision += 1
        enqueue(.mutate(mutation))
        requestData()
        updateDraftPreview()
    }

    // MARK: Engine queue

    private enum EngineOperation {
        case mutate(ScenarioEngine.Mutation)
        case fetch(ScenarioEngine.FetchRequest)
        case preview(ScenarioEngine.PreviewRequest)
        case find(ScenarioEngine.FindRequest)

        var isFetch: Bool { if case .fetch = self { return true } else { return false } }
        var isPreview: Bool { if case .preview = self { return true } else { return false } }
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
        case .preview: engineQueue.removeAll(where: \.isPreview)
        case .mutate, .find: break
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
            case .preview(let request): receive(await engine.preview(request))
            case .find(let request): receive(await engine.find(request))
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
        requestData()  // the view may have moved on, or this fetch was cut short
    }

    func requestPreview(_ request: ScenarioEngine.PreviewRequest) {
        enqueue(.preview(request))
    }

    private func receive(_ result: ScenarioEngine.PreviewResult) {
        guard result.sequence == previewSequence, result.version == revision else { return }
        draftPreview = result.samples
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
            guard let series = computed?.series[index], !series.isEmpty else { return [] }
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
        let preview = draftOnFocus == nil ? [] : draftPreview
        let lineRange = range(focusSamples), previewRange = range(preview)
        let low = min(lineRange?.low ?? 0, previewRange?.low ?? .infinity)
        let high = max(lineRange?.high ?? 1, previewRange?.high ?? -.infinity)
        let (domain, ticks) = niceTicks(low: low, high: high, includeZero: focusSlot.format == .currency)
        let focus = FocusedSlotState(
            index: focusedIndex, name: focusSlot.title, summary: focusSlot.summary, color: focusSlot.color,
            format: focusSlot.format, samples: focusSamples, preview: preview, draftDate: draftOnFocus?.date,
            yDomain: domain, yTicks: ticks, events: markers(forSlotAt: focusedIndex))

        let lanes = slots.enumerated().filter { $0.offset != focusedIndex }.map { index, slot -> LaneState in
            let list = samples(index)
            let bounds = range(list) ?? (0, 1)
            return LaneState(id: index, key: slot.key, name: slot.title, color: slot.color, samples: list,
                             yDomain: Self.laneDomain(low: bounds.low, high: bounds.high), reads: slot.reads)
        }

        return TimelineState(scenarioName: name, frame: frame, now: now, focus: focus, lanes: lanes,
                             yearTicks: TimelineState.yearTicks(for: frame))
    }

    /// The readout and lane values at the cursor, from the latest results. Shows "…" while the
    /// cursor is past what's been computed.
    public func cursorState() -> CursorState {
        let computed = self.computed
        let ready = computed.map { cursor >= start && cursor <= $0.through } ?? false
        func value(_ index: Int) -> Double? {
            guard ready, let series = computed?.series[index] else { return nil }
            return Self.held(series, at: cursor)
        }
        let focusSlot = focused
        let focusValue = value(focusedIndex)
        var laneValues: [Int: String] = [:]
        for (index, slot) in slots.enumerated() where index != focusedIndex {
            laneValues[index] = ready ? (value(index).map(slot.format.full) ?? "—") : "…"
        }
        return CursorState(date: cursor, readoutDate: DateText.monthYear(cursor),
                           readoutValue: ready ? (focusValue.map(focusSlot.format.full) ?? "—") : "…",
                           readoutNote: !ready ? "Computing" : cursor > now ? "Projection" : "Model",
                           focusValue: focusValue, laneValues: laneValues)
    }

    /// "Computed through Dec 2045 · 5 of 8 slots · 1 link".
    public func statusText() -> String {
        [
            computed?.computedThrough.map { "Computed through " + DateText.monthYear($0) } ?? "Computing…",
            "\(slots.count) of \(Scenario.bankSize) slots",
            "\(linkCount) link\(linkCount == 1 ? "" : "s")",
        ].joined(separator: " · ")
    }

    /// The whole panel at once, for clipboard snapshots and tests.
    public func panelState() -> PanelState {
        PanelState(timeline: timelineState(), cursor: cursorState(), status: statusText(), eventPreview: eventPreview())
    }

    private func markers(forSlotAt index: Int) -> [EventMarker] {
        var markers: [EventMarker] = []
        for event in authored[index] where event.time <= frame.end {
            markers.append(EventMarker(id: event.id, date: event.time, endDate: nil, label: Self.label(for: event), kind: .oneOff))
        }
        for rule in recurring[index] where rule.first <= frame.end {
            let end = min(rule.until ?? frame.end, frame.end)
            let amount = rule.values["amount"].map { ValueFormat.currency.full($0) } ?? ""
            let sign = rule.kind == "withdraw" ? "−" : "+"
            markers.append(EventMarker(id: rule.id, date: rule.first, endDate: end,
                                       label: "\(sign)\(amount) \(Self.describe(rule.every))", kind: .recurring))
        }
        for event in computed?.generated[index] ?? [] where frame.contains(event.time) {
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
            let points = (computed?.series[index] ?? [])
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
