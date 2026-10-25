import Foundation
import Observation
import SwiftUI
import FutureEngine
import FutureFormula

/// The app's state for one scenario: the engine, what's focused, the cursor, the visible range,
/// the command bar and undo. Views read `timelineState()`, `cursorState()` and `statusText()` separately.
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
        didSet { if eventDraft != oldValue { updateDraftPreview() } }
    }
    /// The draft slot's line with the draft event applied, for the dashed preview. Empty until the draft is complete.
    public internal(set) var draftPreview: [Sample] = []
    public internal(set) var draftError: String?
    /// Incremented to ask the pane to focus its amount field.
    public internal(set) var eventFieldFocusRequest = 0
    /// How far ahead `draftPreview` has been computed.
    @ObservationIgnored var previewHorizon = Date.distantPast

    /// Called when the command bar asks for something only the app can do (copying).
    @ObservationIgnored public var onAppAction: ((CommandBarAction) -> Void)?

    @ObservationIgnored let scenario: Scenario
    @ObservationIgnored private var undoStack: [Change] = []
    @ObservationIgnored private var redoStack: [Change] = []

    public init(definition: ScenarioDefinition, now: Date = Date()) throws {
        let scenario = Scenario(start: definition.start)
        var infos: [SlotInfo] = []
        for (index, spec) in definition.slots.enumerated() {
            let model = try FormulaModel(spec.formula, name: spec.name)
            let id = try scenario.addSlot(spec.name, model: model)
            let reads = model.descriptor.inputs.compactMap { $0.source?.text }
            infos.append(SlotInfo(id: id, key: index + 1, name: spec.name, title: displayName(spec.name),
                                  variable: spec.variable, colorHex: spec.color ?? SlotPalette.color(forSlotAt: index),
                                  format: spec.format, summary: spec.summary,
                                  reads: reads.isEmpty ? nil : "← " + reads.joined(separator: ", "),
                                  eventKinds: model.handledEventKinds, parameters: model.parameterNames))
        }
        for initial in definition.events {
            guard let id = scenario.slotID(named: initial.slot) else { continue }
            scenario.add(initial.event, to: id)
        }
        try scenario.validate()

        self.scenario = scenario
        self.name = definition.name
        self.slots = infos
        self.start = definition.start
        self.now = now
        self.cursor = now
        let year = 365.2425 * 86_400
        let frameStart = max(definition.start, now.addingTimeInterval(-5 * year))
        self.frame = TimeFrame(start: frameStart, end: frameStart.addingTimeInterval(19 * year))
        self.eventDraft = makeDraft(slotIndex: 0, date: now)
    }

    public var focused: SlotInfo { slots[focusedIndex] }

    public var linkCount: Int { scenario.connections.count + scenario.eventRoutes.count }

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
        if let number = Int(text), slots.indices.contains(number - 1) {
            focus(index: number - 1)
            return true
        }
        let wanted = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard let index = slots.firstIndex(where: { $0.name.lowercased() == wanted }) else { return false }
        focus(index: index)
        return true
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
        frame = newFrame
        extendPreviewIfNeeded()
    }

    /// Zooms around `anchor` (the cursor by default). Factor < 1 zooms in.
    public func zoom(by factor: Double, around anchor: Date? = nil) {
        let span = min(max(frame.span * factor, Self.minimumSpan), Self.maximumSpan)
        let anchor = anchor ?? (frame.contains(cursor) ? cursor : frame.date(atFraction: 0.5))
        let proportion = anchor.timeIntervalSince(frame.start) / frame.span
        let newStart = max(start, anchor.addingTimeInterval(-proportion * span))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(span))
        extendPreviewIfNeeded()
    }

    private func reveal(_ date: Date) {
        guard !frame.contains(date) else { return }
        let newStart = max(start, date.addingTimeInterval(-frame.span / 2))
        frame = TimeFrame(start: newStart, end: newStart.addingTimeInterval(frame.span))
        extendPreviewIfNeeded()
    }

    // MARK: Editing

    public func add(_ event: Event, toSlotAt index: Int) {
        scenario.add(event, to: slots[index].id)
        undoStack.append(.addedEvent(slot: index, event))
        redoStack.removeAll()
        scenarioChanged()
    }

    public func add(_ rule: RecurringEvent, toSlotAt index: Int) {
        scenario.add(rule, to: slots[index].id)
        undoStack.append(.addedRule(slot: index, rule))
        redoStack.removeAll()
        scenarioChanged()
    }

    /// Refreshes views and the draft's preview after the scenario's events change.
    private func scenarioChanged() {
        revision += 1
        updateDraftPreview()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let change = undoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event): scenario.removeEvent(id: event.id, from: slots[slot].id)
        case .addedRule(let slot, let rule): scenario.removeRecurring(id: rule.id, from: slots[slot].id)
        }
        redoStack.append(change)
        scenarioChanged()
        say("Undone")
    }

    public func redo() {
        guard let change = redoStack.popLast() else { return }
        switch change {
        case .addedEvent(let slot, let event): scenario.add(event, to: slots[slot].id)
        case .addedRule(let slot, let rule): scenario.add(rule, to: slots[slot].id)
        }
        undoStack.append(change)
        scenarioChanged()
        say("Redone")
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
            let parameters = scenario.descriptor(of: focused.id).variables.filter { $0.causality == .parameter }.map(\.name)
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
    // touches `cursor` alone, which only the cursor views read.

    /// Everything the timeline draws that doesn't depend on the cursor.
    public func timelineState() -> TimelineState {
        _ = revision
        let margin: TimeInterval = 62 * 86_400
        let from = frame.start.addingTimeInterval(-margin)
        let through = frame.end.addingTimeInterval(margin)

        // Compute any missing range for all slots at once, with independent groups on separate cores.
        try? scenario.ensureAll(through: through)
        func samples(_ slot: SlotInfo) -> [Sample] {
            (try? scenario.series(slot.variable, of: slot.id, from: from, through: through)) ?? []
        }
        func range(_ list: [Sample]) -> (low: Double, high: Double)? {
            var low = Double.infinity, high = -Double.infinity
            for sample in list where frame.contains(sample.time) {
                low = min(low, sample.value)
                high = max(high, sample.value)
            }
            return low <= high ? (low, high) : nil
        }

        let focusSlot = focused
        let focusSamples = samples(focusSlot)
        let draftOnFocus = eventDraft.slotIndex == focusedIndex ? eventDraft : nil
        let preview = draftOnFocus == nil ? [] : draftPreview
        let lineRange = range(focusSamples), previewRange = range(preview)
        let low = min(lineRange?.low ?? 0, previewRange?.low ?? .infinity)
        let high = max(lineRange?.high ?? 1, previewRange?.high ?? -.infinity)
        let (domain, ticks) = niceTicks(low: low, high: high, includeZero: focusSlot.format == .currency)
        let focus = FocusedSlotState(
            index: focusedIndex, name: focusSlot.title, summary: focusSlot.summary, color: focusSlot.color,
            format: focusSlot.format, samples: focusSamples, preview: preview, draftDate: draftOnFocus?.date,
            yDomain: domain, yTicks: ticks, events: markers(for: focusSlot))

        let lanes = slots.enumerated().filter { $0.offset != focusedIndex }.map { index, slot -> LaneState in
            let list = samples(slot)
            let bounds = range(list) ?? (0, 1)
            let pad = max((bounds.high - bounds.low) * 0.12, abs(bounds.high) * 0.01, 1e-9)
            return LaneState(id: index, key: slot.key, name: slot.title, color: slot.color, samples: list,
                             yDomain: (bounds.low - pad)...(bounds.high + pad), reads: slot.reads)
        }

        return TimelineState(scenarioName: name, frame: frame, now: now, focus: focus, lanes: lanes,
                             yearTicks: TimelineState.yearTicks(for: frame))
    }

    /// The readout and lane values at the cursor.
    public func cursorState() -> CursorState {
        _ = revision
        func value(_ slot: SlotInfo) -> Double? {
            guard cursor >= start else { return nil }
            return try? scenario.value(slot.variable, of: slot.id, at: cursor)
        }
        let focusSlot = focused
        let focusValue = value(focusSlot)
        var laneValues: [Int: String] = [:]
        for (index, slot) in slots.enumerated() where index != focusedIndex {
            laneValues[index] = value(slot).map(slot.format.full) ?? "—"
        }
        return CursorState(date: cursor, readoutDate: DateText.monthYear(cursor),
                           readoutValue: focusValue.map(focusSlot.format.full) ?? "—",
                           readoutNote: cursor > now ? "Projection" : "Model",
                           focusValue: focusValue, laneValues: laneValues)
    }

    /// "Computed through Dec 2045 · 5 of 8 slots · 1 link".
    public func statusText() -> String {
        _ = revision
        _ = frame
        let computed = slots.compactMap { scenario.computedThrough($0.id) }.min()
        return [
            computed.map { "Computed through " + DateText.monthYear($0) },
            "\(slots.count) of \(Scenario.bankSize) slots",
            "\(linkCount) link\(linkCount == 1 ? "" : "s")",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// The whole panel at once, for clipboard snapshots and tests.
    public func panelState() -> PanelState {
        PanelState(timeline: timelineState(), cursor: cursorState(), status: statusText(), eventPreview: eventPreview())
    }

    private func markers(for slot: SlotInfo) -> [EventMarker] {
        var markers: [EventMarker] = []
        for event in scenario.events(in: slot.id) where event.time <= frame.end {
            markers.append(EventMarker(id: event.id, date: event.time, endDate: nil, label: Self.label(for: event), kind: .oneOff))
        }
        for rule in scenario.recurringEvents(in: slot.id) where rule.first <= frame.end {
            let end = min(rule.until ?? frame.end, frame.end)
            let amount = rule.values["amount"].map { ValueFormat.currency.full($0) } ?? ""
            let sign = rule.kind == "withdraw" ? "−" : "+"
            markers.append(EventMarker(id: rule.id, date: rule.first, endDate: end,
                                       label: "\(sign)\(amount) \(Self.describe(rule.every))", kind: .recurring))
        }
        if let generated = try? scenario.generatedEvents(in: slot.id, through: frame.end) {
            for event in generated where event.time >= frame.start {
                markers.append(EventMarker(id: event.id, date: event.time, endDate: nil, label: event.kind, kind: .generated))
            }
        }
        return markers.sorted { $0.date < $1.date }
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
        var ordered = [focused]
        ordered += slots.enumerated().filter { $0.offset != focusedIndex }.map(\.element)
        let slotData = ordered.map { slot in
            let points = ((try? scenario.series(slot.variable, of: slot.id, from: frame.start, through: frame.end)) ?? [])
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
