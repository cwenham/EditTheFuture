import Foundation
import FutureDocument
import FutureEngine

/// An authored event, one-off or repeating, loaded into the add-event pane to be changed (docs/UI.md, 5.4).
public struct EditedEvent: Equatable, Sendable {
    /// The slot it belongs to.
    public let slot: UUID
    /// The event or repeating event as it was when it was loaded.
    let original: EventDraft.Built
    /// What the pane held before, put back when editing ends.
    let previousDraft: EventDraft

    public var id: UUID { original.id }
    /// When it happens, or first happens.
    public var time: Date { original.time }
    /// The one-off event being edited, or nil for a repeating one.
    public var event: Event? {
        if case .event(let event) = original { return event }
        return nil
    }
    /// The repeating event being edited, or nil for a one-off one.
    public var rule: RecurringEvent? {
        if case .rule(let rule) = original { return rule }
        return nil
    }
}

extension ScenarioStore {
    /// Loads one of the focused slot's own events into the add-event pane, after its diamond, or a
    /// repeating event's bar or label, was clicked. Save (or ↩) changes it, Delete removes it, and
    /// Cancel leaves it as it was.
    public func editEvent(id: UUID) {
        guard slots.indices.contains(focusedIndex) else { return }
        let original: EventDraft.Built
        if let event = configs[focusedIndex].events.first(where: { $0.id == id }) {
            original = .event(event)
        } else if let rule = configs[focusedIndex].rules.first(where: { $0.id == id }) {
            original = .rule(rule)
        } else {
            return
        }
        let slot = slots[focusedIndex]
        var draft = EventDraft(slotIndex: focusedIndex, date: original.time, kind: .setParameter)
        draft.parameter = slot.parameters.first ?? ""
        let values = original.values
        if original.kind == Event.setKind {
            // The pane changes one parameter at a time, once.
            guard values.count == 1, let entry = values.first, !original.isRule else {
                say(original.isRule ? "The Event tab can't change a repeating parameter change. Change it in scenario.md."
                                    : "This event sets several parameters at once. Change it in scenario.md.", isError: true)
                return
            }
            draft.parameter = entry.key
            let percent = slot.parameterValues.first { $0.name == entry.key }?.quantity == .percent
            draft.valueText = Self.editableText(entry.value, percent: percent, numbers: slot.writing.numbers)
        } else {
            guard values.count == 1, let amount = values["amount"] else {
                say("The Event tab can't change this \(original.kind) event. Change it in scenario.md.", isError: true)
                return
            }
            draft.kind = .event(original.kind)
            draft.amountText = Self.editableText(amount, percent: false, numbers: slot.writing.numbers)
        }
        if case .rule(let rule) = original {
            guard let repeats = EventDraft.Repeat.allCases.first(where: { $0.rate == rule.every }) else {
                say("This event repeats \(Self.describe(rule.every)), which the Event tab can't show. Change it in scenario.md.",
                    isError: true)
                return
            }
            draft.repeats = repeats
        }
        // Clicking another marker while editing still goes back to the pane as it was before the first.
        let previous = editingEvent?.previousDraft ?? eventDraft
        if confirmingEventDeletion { confirmingEventDeletion = false }
        if draftError != nil { draftError = nil }
        editingEvent = EditedEvent(slot: slot.id, original: original, previousDraft: previous)
        if draft != eventDraft { eventDraft = draft } else { updateDraftPreview() }
        requestEventFieldFocus()
    }

    /// Saves the pane's changes to the event being edited, as one change that undo takes back.
    /// Choosing a repeat turns a one-off event into a repeating one, and Never the other way round.
    /// A repeating event keeps its end ("until") and count, which the pane doesn't show.
    @discardableResult
    public func saveEditedEvent() -> Bool {
        guard let editing = editingEvent else { return false }
        guard let index = slotIndex(id: editing.slot) else {
            stopEditingEvent()
            return false
        }
        switch buildDraft() {
        case .failure(let problem):
            draftError = problem.message
            return false
        case .success(var built):
            let old = editing.original
            if case .rule(let oldRule) = old, case .rule(var rule) = built {
                rule.count = oldRule.count
                // An end before the new first date would leave nothing, so it goes.
                if let until = oldRule.until, until >= rule.first { rule.until = until }
                built = .rule(rule)
            }
            let before = describe(old, inSlotAt: index)
            let title = slots[index].title
            if built.sameAs(old) {
                stopEditingEvent()
                say("No changes to \(before)")
                return true
            }
            guard changeEvent(id: old.id, inSlotAt: index, to: built) else {
                stopEditingEvent()
                say("That event isn't there any more", isError: true)
                return false
            }
            switch built {
            case .event:
                say("Changed \(before) to \(describe(built, inSlotAt: index)) in \(title)")
            case .rule(let rule):
                let amount = rule.values["amount"].map(amountStyle(inSlotAt: index, kind: rule.kind).full) ?? ""
                say("Changed \(before) to a \(EventDraft.title(forKind: rule.kind).lowercased()) of \(amount) "
                    + "\(Self.describe(rule.every)) from \(DateText.monthYear(rule.first)) in \(title)")
            }
            stopEditingEvent()
            return true
        }
    }

    /// "−$6,000 on Aug 2028", or "Vaccinate 6,000 every week from Mar 2022".
    func describe(_ item: EventDraft.Built, inSlotAt index: Int) -> String {
        switch item {
        case .event(let event): return "\(label(for: event, inSlotAt: index)) on \(DateText.monthYear(event.time))"
        case .rule(let rule): return "\(label(for: rule, inSlotAt: index)) from \(DateText.monthYear(rule.first))"
        }
    }

    /// Asks to confirm deleting the event being edited (docs/DESIGN.md, 13).
    public func requestEventDeletion() {
        guard editingEvent != nil, !confirmingEventDeletion else { return }
        confirmingEventDeletion = true
    }

    public func cancelEventDeletion() {
        if confirmingEventDeletion { confirmingEventDeletion = false }
    }

    /// "Delete −$6,000 on Aug 2028 from Savings?"
    public var eventDeletionQuestion: String {
        guard let editing = editingEvent, let index = slotIndex(id: editing.slot) else { return "" }
        return "Delete \(describe(editing.original, inSlotAt: index)) from \(slots[index].title)? Undo brings it back."
    }

    /// Deletes the event being edited, as one change that undo takes back.
    public func deleteEditedEvent() {
        guard let editing = editingEvent else { return }
        if let index = slotIndex(id: editing.slot) {
            let what = describe(editing.original, inSlotAt: index)
            let title = slots[index].title
            if changeEvent(id: editing.id, inSlotAt: index, to: nil) {
                say("Deleted \(what) from \(title)")
            }
        }
        stopEditingEvent()
    }

    /// Leaves the event as it is, and puts back what the pane held before it was clicked.
    public func stopEditingEvent() {
        guard let editing = editingEvent else { return }
        editingEvent = nil
        if confirmingEventDeletion { confirmingEventDeletion = false }
        if draftError != nil { draftError = nil }
        var draft = editing.previousDraft
        // Slots may have moved since; the draft always targets the focused slot.
        draft.slotIndex = focusedIndex
        if draft != eventDraft { eventDraft = draft } else { updateDraftPreview() }
        retargetDraft(force: true)
    }

    /// While editing, keeps the draft on its event's slot. Stops editing when the event has gone
    /// (undone, or changed in scenario.md) or another slot was focused.
    func followEditedEvent() {
        guard let editing = editingEvent else { return }
        guard let index = slotIndex(id: editing.slot), index == focusedIndex,
              configs[index].events.contains(where: { $0.id == editing.id })
                || configs[index].rules.contains(where: { $0.id == editing.id }) else {
            stopEditingEvent()
            return
        }
        if eventDraft.slotIndex != index { eventDraft.slotIndex = index }
    }

    /// A number as the pane's fields show it, in the slot's style, reading back exactly: "6,000",
    /// "1234.5", "4.5%", or "6.000" and "1234,5" where decimals follow a comma.
    static func editableText(_ value: Double, percent: Bool, numbers: NumberStyle = .commaPoint) -> String {
        var candidates: [String] = []
        if !percent, value.rounded() == value, abs(value) < ValueFormat.writtenOutLimit {
            candidates.append(ValueFormat.grouped(value))
        }
        candidates.append(FileNumber.text(value, percent: percent))
        candidates.append(FileNumber.text(value))
        // Exponents and words ("1e+20", "inf") are written as they are, so they read back.
        let written = candidates.map { $0.contains("e") || $0.contains("n") ? $0 : numbers.localize($0) }
        return written.first { CommandBarParser.parseAmount($0, numbers: numbers)?.bitPattern == value.bitPattern }
            ?? FileNumber.text(value)
    }
}
