import Foundation
import FutureDocument
import FutureEngine

/// An authored event loaded into the add-event pane to be changed (docs/UI.md, 5.4).
public struct EditedEvent: Equatable, Sendable {
    /// The slot it belongs to.
    public let slot: UUID
    /// The event as it was when it was loaded.
    public let event: Event
    /// What the pane held before, put back when editing ends.
    let previousDraft: EventDraft
}

extension ScenarioStore {
    /// Loads one of the focused slot's one-off events into the add-event pane, after its marker
    /// was clicked. Save (or ↩) changes it, Delete removes it, and Cancel leaves it as it was.
    public func editEvent(id: UUID) {
        guard slots.indices.contains(focusedIndex),
              let event = configs[focusedIndex].events.first(where: { $0.id == id }) else { return }
        let slot = slots[focusedIndex]
        var draft = EventDraft(slotIndex: focusedIndex, date: event.time, kind: .setParameter)
        draft.parameter = slot.parameters.first ?? ""
        if event.kind == Event.setKind {
            // The pane changes one parameter at a time.
            guard event.values.count == 1, let entry = event.values.first else {
                say("This event sets several parameters at once. Change it in scenario.md.", isError: true)
                return
            }
            draft.parameter = entry.key
            let percent = slot.parameterValues.first { $0.name == entry.key }?.quantity == .percent
            draft.valueText = Self.editableText(entry.value, percent: percent)
        } else {
            guard event.values.count == 1, let amount = event.values["amount"] else {
                say("The Event tab can't change this \(event.kind) event. Change it in scenario.md.", isError: true)
                return
            }
            draft.kind = .event(event.kind)
            draft.amountText = Self.editableText(amount, percent: false)
        }
        // Clicking another marker while editing still goes back to the pane as it was before the first.
        let previous = editingEvent?.previousDraft ?? eventDraft
        if confirmingEventDeletion { confirmingEventDeletion = false }
        if draftError != nil { draftError = nil }
        editingEvent = EditedEvent(slot: slot.id, event: event, previousDraft: previous)
        if draft != eventDraft { eventDraft = draft } else { updateDraftPreview() }
        requestEventFieldFocus()
    }

    /// Saves the pane's changes to the event being edited, as one change that undo takes back.
    /// Choosing a repeat turns it into a recurring event.
    @discardableResult
    public func saveEditedEvent() -> Bool {
        guard let editing = editingEvent else { return false }
        guard let index = slotIndex(id: editing.slot) else {
            stopEditingEvent()
            return false
        }
        switch eventDraft.build() {
        case .failure(let problem):
            draftError = problem.message
            return false
        case .success(let built):
            let old = editing.event
            let before = "\(label(for: old, inSlotAt: index)) on \(DateText.monthYear(old.time))"
            let title = slots[index].title
            if case .event(let event) = built, event.time == old.time, event.kind == old.kind, event.values == old.values {
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
            case .event(let event):
                say("Changed \(before) to \(label(for: event, inSlotAt: index)) on \(DateText.monthYear(event.time)) in \(title)")
            case .rule(let rule):
                let amount = rule.values["amount"].map { ValueFormat.currency.full($0) } ?? ""
                say("Changed \(before) to a \(EventDraft.title(forKind: rule.kind).lowercased()) of \(amount) "
                    + "\(Self.describe(rule.every)) from \(DateText.monthYear(rule.first)) in \(title)")
            }
            stopEditingEvent()
            return true
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
        return "Delete \(label(for: editing.event, inSlotAt: index)) on \(DateText.monthYear(editing.event.time)) "
            + "from \(slots[index].title)? Undo brings it back."
    }

    /// Deletes the event being edited, as one change that undo takes back.
    public func deleteEditedEvent() {
        guard let editing = editingEvent else { return }
        if let index = slotIndex(id: editing.slot) {
            let what = "\(label(for: editing.event, inSlotAt: index)) on \(DateText.monthYear(editing.event.time))"
            let title = slots[index].title
            if changeEvent(id: editing.event.id, inSlotAt: index, to: nil) {
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
              configs[index].events.contains(where: { $0.id == editing.event.id }) else {
            stopEditingEvent()
            return
        }
        if eventDraft.slotIndex != index { eventDraft.slotIndex = index }
    }

    /// A number as the pane's fields show it, reading back exactly: "6,000", "1234.5", "4.5%".
    static func editableText(_ value: Double, percent: Bool) -> String {
        var candidates: [String] = []
        if !percent, value.rounded() == value, abs(value) < ValueFormat.writtenOutLimit {
            candidates.append(ValueFormat.grouped(value))
        }
        candidates.append(FileNumber.text(value, percent: percent))
        candidates.append(FileNumber.text(value))
        return candidates.first { CommandBarParser.parseAmount($0)?.bitPattern == value.bitPattern } ?? FileNumber.text(value)
    }
}
