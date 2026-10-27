import Foundation
import FutureEngine

/// The event being set up in the add-event pane (docs/UI.md, 5.3).
public struct EventDraft: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// One of the slot's own event kinds, e.g. "deposit".
        case event(String)
        /// A `set` event that changes a parameter.
        case setParameter
    }

    public enum Repeat: String, CaseIterable, Identifiable, Sendable {
        case never, weekly, fortnightly, monthly, quarterly, yearly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .never: return "Never"
            case .weekly: return "Every week"
            case .fortnightly: return "Every 2 weeks"
            case .monthly: return "Every month"
            case .quarterly: return "Every quarter"
            case .yearly: return "Every year"
            }
        }

        public var rate: StepRate? {
            switch self {
            case .never: return nil
            case .weekly: return .weekly
            case .fortnightly: return .weeks(2)
            case .monthly: return .monthly
            case .quarterly: return .quarters(1)
            case .yearly: return .yearly
            }
        }
    }

    public var slotIndex: Int
    public var date: Date
    public var kind: Kind
    public var amountText = ""
    public var parameter = ""
    public var valueText = ""
    public var repeats = Repeat.never

    /// "deposit" → "Deposit", "overpay" → "Overpay".
    public static func title(forKind kind: String) -> String {
        kind.prefix(1).uppercased() + kind.dropFirst()
    }

    /// What to add to the scenario, or why the draft isn't ready.
    func build() -> Result<Built, DraftProblem> {
        switch kind {
        case .event(let name):
            guard let amount = CommandBarParser.parseAmount(amountText.trimmingCharacters(in: .whitespaces)), amount > 0 else {
                return .failure(amountText.isEmpty ? .missingAmount : .badAmount(amountText))
            }
            if let rate = repeats.rate {
                return .success(.rule(RecurringEvent(kind: name, values: ["amount": amount], first: date, every: rate)))
            }
            return .success(.event(Event(time: date, kind: name, values: ["amount": amount])))
        case .setParameter:
            guard !parameter.isEmpty else { return .failure(.missingParameter) }
            guard let value = CommandBarParser.parseAmount(valueText.trimmingCharacters(in: .whitespaces)) else {
                return .failure(valueText.isEmpty ? .missingValue : .badAmount(valueText))
            }
            return .success(.event(Event.set([parameter: value], at: date)))
        }
    }

    enum Built: Sendable {
        case event(Event)
        case rule(RecurringEvent)
    }

    enum DraftProblem: Error, Equatable {
        case missingAmount, missingValue, missingParameter
        case badAmount(String)

        var message: String {
            switch self {
            case .missingAmount: return "Enter an amount, e.g. 500 or 1.2k"
            case .missingValue: return "Enter a value, e.g. 4% or 650"
            case .missingParameter: return "Choose a parameter"
            case .badAmount(let text): return "“\(text)” isn't a number. Use 500, $1,200, 1.5k or 4%"
            }
        }
    }
}

extension ScenarioStore {
    /// A fresh draft for a slot: its first event kind, or Set parameter, and its first parameter.
    func makeDraft(slotIndex: Int, date: Date) -> EventDraft {
        let slot = slots[slotIndex]
        var draft = EventDraft(slotIndex: slotIndex, date: date,
                               kind: slot.eventKinds.first.map(EventDraft.Kind.event) ?? .setParameter)
        draft.parameter = slot.parameters.first ?? ""
        return draft
    }

    /// Points the draft at the focused slot, keeping the amount, date and repeat where they still make sense.
    /// `force` checks it again even when the index is the same, for after slots were added or removed.
    func retargetDraft(force: Bool = false) {
        if editingEvent != nil {
            followEditedEvent()
            return
        }
        guard force || eventDraft.slotIndex != focusedIndex else { return }
        let slot = slots[focusedIndex]
        var draft = eventDraft
        draft.slotIndex = focusedIndex
        if case .event(let kind) = draft.kind, !slot.eventKinds.contains(kind) {
            draft.kind = slot.eventKinds.first.map(EventDraft.Kind.event) ?? .setParameter
        }
        if draft.kind == .setParameter, slot.parameters.isEmpty, let first = slot.eventKinds.first {
            draft.kind = .event(first)
        }
        if !slot.parameters.contains(draft.parameter) {
            draft.parameter = slot.parameters.first ?? ""
            draft.valueText = ""
        }
        if draftError != nil { draftError = nil }  // setting it, even to nil, redraws the pane
        if draft != eventDraft { eventDraft = draft }
    }

    /// Whether the draft's date is still the default (now) rather than a date picked on the graph.
    public var eventDateIsNow: Bool { eventDraft.date == now }

    /// Whether the draft has everything it needs to be added (and previewed).
    public var draftIsComplete: Bool {
        if case .success = eventDraft.build() { return true }
        return false
    }

    /// The draft parameter's value at the draft's date, from the latest results, e.g. 0.045.
    public func currentValue(ofParameter name: String) -> Double? {
        guard let parameters = computed?.parameters, parameters.indices.contains(eventDraft.slotIndex) else { return nil }
        return parameters[eventDraft.slotIndex][name]
    }

    /// Sets the draft's date from a click on the graph, and its slot when a lane was clicked.
    public func pickEventDate(_ date: Date, slotIndex: Int? = nil) {
        if let slotIndex { focus(index: slotIndex) }
        eventDraft.date = Calendar.current.startOfDay(for: max(start, date))
    }

    /// Picks a date and puts the keyboard in the pane's amount field.
    public func beginEvent(at date: Date, slotIndex: Int? = nil) {
        pickEventDate(date, slotIndex: slotIndex)
        requestEventFieldFocus()
    }

    /// Shows the Event tab with the keyboard in its amount (or value) field.
    func requestEventFieldFocus() {
        if sidePane != .event {
            closeRefit()
            closePredict()
            sidePane = .event
            focusEventFieldOnAppear = true
        }
        eventFieldFocusRequest += 1
    }

    /// Puts the draft's date back to now.
    public func resetEventDate() {
        eventDraft.date = now
    }

    /// Empties the amount and value and goes back to now.
    public func clearEvent() {
        var draft = eventDraft
        draft.amountText = ""
        draft.valueText = ""
        draft.date = now
        if draftError != nil { draftError = nil }
        eventDraft = draft
    }

    /// Adds the drafted event and clears the pane for the next one, or saves the event being
    /// edited. Returns false and sets `draftError` when the draft isn't complete.
    @discardableResult
    public func commitEvent() -> Bool {
        if editingEvent != nil { return saveEditedEvent() }
        let draft = eventDraft
        switch draft.build() {
        case .failure(let problem):
            draftError = problem.message
            return false
        case .success(let built):
            let slot = slots[draft.slotIndex]
            clearEvent()
            switch built {
            case .event(let event):
                add(event, toSlotAt: draft.slotIndex)
                say("Added \(label(for: event, inSlotAt: draft.slotIndex)) on \(DateText.monthYear(event.time)) to \(slot.title)")
            case .rule(let rule):
                add(rule, toSlotAt: draft.slotIndex)
                let amount = rule.values["amount"].map { ValueFormat.currency.full($0) } ?? ""
                say("Added \(EventDraft.title(forKind: rule.kind).lowercased()) of \(amount) \(Self.describe(rule.every)) from \(DateText.monthYear(rule.first)) to \(slot.title)")
            }
            return true
        }
    }

    /// Asks the engine for the dashed preview: the draft slot's line with the draft applied, one
    /// screen past the right edge so scrolling only asks again when it goes further.
    func updateDraftPreview() {
        previewSequence += 1
        guard case .success(let built) = eventDraft.build() else {
            if !draftPreview.isEmpty { draftPreview = [] }
            previewThrough = .distantPast
            return
        }
        if draftError != nil { draftError = nil }
        let margin: TimeInterval = 62 * 86_400
        let through = frame.end.addingTimeInterval(frame.span)
        previewThrough = through
        requestPreview(ScenarioEngine.PreviewRequest(version: revision, sequence: previewSequence, slot: eventDraft.slotIndex,
                                                     change: .event(built), from: effectStart.addingTimeInterval(-margin),
                                                     through: through.addingTimeInterval(margin), replacing: editingEvent?.event.id))
    }

    /// Where the draft starts to make a difference: its date, or the edited event's own date when
    /// that's earlier (moving an event later changes the line from where it was).
    var effectStart: Date {
        guard let editing = editingEvent else { return eventDraft.date }
        return min(eventDraft.date, editing.event.time)
    }

    /// Asks again when the view has scrolled past what the preview covers.
    func extendPreviewIfNeeded() {
        guard draftIsComplete, frame.end > previewThrough else { return }
        updateDraftPreview()
    }

    /// The draft's effect at the cursor and at the right edge, or nil until its preview is ready.
    func eventPreview() -> EventPreviewState? {
        let index = eventDraft.slotIndex
        guard !draftPreview.isEmpty, let computed, computed.series.indices.contains(index) else { return nil }
        let slot = slots[index]
        let effectStart = self.effectStart
        func effect(at date: Date) -> String {
            guard date <= computed.through else { return "…" }
            guard date >= start, date >= effectStart,
                  let before = Self.held(computed.series[index], at: date),
                  let after = Self.held(draftPreview, at: date) else {
                return "No change yet"
            }
            let difference = after - before
            if abs(difference) < 0.005 { return "No change" }
            let sign = difference > 0 ? "+" : "−"
            return sign + slot.format.full(abs(difference)).replacingOccurrences(of: "−", with: "")
        }
        return EventPreviewState(cursorDate: DateText.monthYear(cursor), atCursor: effect(at: cursor),
                                 edgeDate: DateText.monthYear(frame.end), atEdge: effect(at: frame.end))
    }
}
