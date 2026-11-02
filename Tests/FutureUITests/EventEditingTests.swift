import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// Clicking an event's diamond to change or delete it (docs/UI.md, 5.4).
@MainActor
@Suite("Editing events")
struct EventEditingTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    /// Savings' −$6,000 withdrawal on 1 Aug 2028, from the built-in scenario.
    func withdrawal(_ store: ScenarioStore) throws -> Event {
        try #require(store.configs[0].events.first { $0.kind == "withdraw" })
    }

    @Test("Clicking a diamond loads its event into the Event tab")
    func loads() async throws {
        let store = try await makeStore()
        store.sidePane = .slot
        let event = try withdrawal(store)
        store.editEvent(id: event.id)

        #expect(store.editingEvent?.event == event)
        #expect(store.sidePane == .event)
        #expect(store.eventFieldFocusRequest == 1)
        #expect(store.eventDraft.kind == .event("withdraw"))
        #expect(store.eventDraft.amountText == "6,000")
        #expect(store.eventDraft.date == event.time)
        #expect(store.eventDraft.repeats == .never)
        #expect(store.timelineState().focus.editingEventID == event.id)
    }

    @Test("Saving changes the event in place, and undo and redo cover it")
    func savesInPlace() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)
        let event = try withdrawal(store)

        store.editEvent(id: event.id)
        store.eventDraft.amountText = "8000"
        #expect(store.commitEvent())
        #expect(store.editingEvent == nil)
        #expect(store.message == "Changed −$6,000 on Aug 2028 to −$8,000 on Aug 2028 in Savings")
        let events = store.configs[0].events
        #expect(events.count == 1)
        #expect(events[0].values == ["amount": 8000])
        #expect(events[0].time == event.time)
        await store.waitUntilIdle()
        let after = try #require(store.cursorState().focusValue)
        #expect(after < before - 2000 && after > before - 4000)
        #expect(store.timelineState().focus.events.filter { $0.kind == .oneOff }.map(\.label) == ["−$8,000"])

        store.undo()
        await store.waitUntilIdle()
        #expect(store.configs[0].events == [event])
        #expect(store.cursorState().focusValue == before)
        store.redo()
        await store.waitUntilIdle()
        #expect(store.configs[0].events == events)
        #expect(store.cursorState().focusValue == after)
    }

    @Test("The preview shows the event as edited, not as an extra copy")
    func previewReplaces() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let current = try #require(store.cursorState().focusValue)

        store.editEvent(id: try withdrawal(store).id)
        await store.waitUntilIdle()
        // Unchanged, the preview is the line as it is.
        #expect(ScenarioStore.held(store.draftPreview, at: store.cursor) == current)
        #expect(store.panelState().eventPreview?.atCursor == "No change")

        store.eventDraft.amountText = "8000"
        await store.waitUntilIdle()
        let previewed = try #require(ScenarioStore.held(store.draftPreview, at: store.cursor))
        #expect(current - previewed > 2000 && current - previewed < 4000)
        #expect(store.panelState().eventPreview?.atCursor.hasPrefix("−$2,") == true)
    }

    @Test("Moving an event later shows its effect from where it was")
    func moving() async throws {
        let store = try await makeStore()
        store.show(utc(2029, 6))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)
        let event = try withdrawal(store)

        store.editEvent(id: event.id)
        store.eventDraft.date = utc(2030, 8)
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.draftDate == utc(2030, 8))
        #expect(store.panelState().eventPreview?.atCursor.hasPrefix("+$6,") == true)

        #expect(store.commitEvent())
        await store.waitUntilIdle()
        #expect(store.configs[0].events.map(\.time) == [utc(2030, 8)])
        #expect(try #require(store.cursorState().focusValue) > before + 6000)
    }

    @Test("Deleting asks first, and undo puts the event back")
    func deletes() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)
        let event = try withdrawal(store)

        store.editEvent(id: event.id)
        store.requestEventDeletion()
        #expect(store.confirmingEventDeletion)
        #expect(store.eventDeletionQuestion == "Delete −$6,000 on Aug 2028 from Savings? Undo brings it back.")
        store.cancelEventDeletion()
        #expect(!store.confirmingEventDeletion)
        #expect(store.configs[0].events == [event])

        store.requestEventDeletion()
        store.deleteEditedEvent()
        #expect(store.editingEvent == nil)
        #expect(!store.confirmingEventDeletion)
        #expect(store.configs[0].events.isEmpty)
        #expect(store.message == "Deleted −$6,000 on Aug 2028 from Savings")
        await store.waitUntilIdle()
        #expect(try #require(store.cursorState().focusValue) > before + 6000)

        store.undo()
        await store.waitUntilIdle()
        #expect(store.configs[0].events == [event])
        #expect(store.cursorState().focusValue == before)
    }

    @Test("Cancel leaves the event alone and puts back what the pane held")
    func cancels() async throws {
        let store = try await makeStore()
        store.eventDraft.amountText = "750"
        let draft = store.eventDraft
        let event = try withdrawal(store)

        store.editEvent(id: event.id)
        store.eventDraft.amountText = "9000"
        store.stopEditingEvent()
        #expect(store.editingEvent == nil)
        #expect(store.eventDraft == draft)
        #expect(store.configs[0].events == [event])
        #expect(!store.canUndo)
        #expect(store.timelineState().focus.editingEventID == nil)

        // Saving with nothing changed is the same.
        store.editEvent(id: event.id)
        #expect(store.commitEvent())
        #expect(store.message == "No changes to −$6,000 on Aug 2028")
        #expect(store.eventDraft == draft)
        #expect(!store.canUndo)
    }

    @Test("Editing stops when another slot is focused, or the event is undone")
    func stopsWhenGone() async throws {
        let store = try await makeStore()
        store.editEvent(id: try withdrawal(store).id)
        store.focus(index: 1)
        #expect(store.editingEvent == nil)
        #expect(store.eventDraft.slotIndex == 1)
        #expect(store.eventDraft.amountText.isEmpty)

        store.focus(index: 0)
        store.commandText = "+500 from 2031-01"
        store.runCommand()
        let added = try #require(store.configs[0].events.last)
        store.editEvent(id: added.id)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.amountText == "500")
        store.undo()
        #expect(store.editingEvent == nil)
        await store.waitUntilIdle()
    }

    @Test("Choosing a repeat turns a one-off event into a recurring one")
    func becomesRecurring() async throws {
        let store = try await makeStore()
        let event = try withdrawal(store)
        store.editEvent(id: event.id)
        store.eventDraft.repeats = .yearly
        #expect(store.commitEvent())
        #expect(store.configs[0].events.isEmpty)
        let rule = try #require(store.configs[0].rules.first)
        #expect(rule.kind == "withdraw")
        #expect(rule.first == event.time)
        #expect(rule.every == .yearly)
        #expect(store.message?.hasPrefix("Changed −$6,000 on Aug 2028 to a withdraw of $6,000 every year") == true)

        store.undo()
        #expect(store.configs[0].events == [event])
        #expect(store.configs[0].rules.isEmpty)
        await store.waitUntilIdle()
    }

    @Test("A parameter change loads with its parameter and value")
    func parameterChange() async throws {
        let store = try await makeStore()
        store.focus(index: 4)
        let event = try #require(store.configs[4].events.first)
        store.editEvent(id: event.id)
        #expect(store.eventDraft.kind == .setParameter)
        #expect(store.eventDraft.parameter == "tariff")
        #expect(store.eventDraft.valueText == "1.12")

        store.eventDraft.valueText = "1.3"
        #expect(store.commitEvent())
        #expect(store.configs[4].events.map(\.values) == [["tariff": 1.3]])
        #expect(store.message == "Changed Tariff → 1.12 on Apr 2027 to Tariff → 1.3 on Apr 2027 in Energy bill")
        await store.waitUntilIdle()
    }

    @Test("Events the pane can't show whole are left for scenario.md")
    func refusesWhatItCantShow() async throws {
        let store = try await makeStore()
        store.add(Event.set(["rate": 0.05, "monthly": 100], at: utc(2030, 1)), toSlotAt: 0)
        let event = try #require(store.configs[0].events.last)
        store.editEvent(id: event.id)
        #expect(store.editingEvent == nil)
        #expect(store.messageIsError)
        await store.waitUntilIdle()
    }

    @Test("Numbers load as text that reads back exactly")
    func editableText() {
        #expect(ScenarioStore.editableText(6000, percent: false) == "6,000")
        #expect(ScenarioStore.editableText(1234.5, percent: false) == "1234.5")
        #expect(ScenarioStore.editableText(1e20, percent: false) == "1e+20")
        for (value, percent) in [(6000.0, false), (1234.5, false), (0.1 + 0.2, false), (1e20, false), (0.045, true),
                                 (0.07, true), (1.12, false), (0.1 + 0.2, true)] {
            let text = ScenarioStore.editableText(value, percent: percent)
            #expect(CommandBarParser.parseAmount(text) == value, "\(value) → \(text)")
        }
    }

    @Test("A click lands on the nearest diamond within a few points, or a repeating event's bar or label, never a generated event")
    func hitTesting() {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind, end: Date? = nil) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: end, label: "", kind: kind)
        }
        let first = marker(utc(2028, 8), .oneOff), second = marker(utc(2028, 9), .oneOff)
        let rule = marker(utc(2030, 1), .recurring, end: utc(2033, 1)), generated = marker(utc(2032, 1), .generated)
        let early = marker(utc(2020, 1), .oneOff)
        let items = EventsStrip.layout(markers: [early, first, second, rule, generated], frame: frame, width: width) { _, _ in 40 }
        func hit(_ date: Date, nudge: CGFloat = 0, y: CGFloat = EventsStrip.markerY) -> UUID? {
            EventsStrip.editableEvent(at: CGPoint(x: frame.x(date, width: width) + nudge, y: y), in: items)
        }
        #expect(hit(utc(2028, 8)) == first.id)
        #expect(hit(utc(2028, 8), nudge: -7) == first.id)
        #expect(hit(utc(2028, 9), nudge: 2) == second.id)
        #expect(hit(utc(2028, 8), nudge: -9) == nil)
        // A repeating event's bar, anywhere along it, but not above or past it.
        #expect(hit(utc(2031, 6), y: EventsStrip.barY(row: 0)) == rule.id)
        #expect(hit(utc(2031, 6), y: EventsStrip.labelY) == nil)
        #expect(hit(utc(2034, 1), y: EventsStrip.barY(row: 0)) == nil)
        #expect(hit(utc(2032, 1)) == nil)
        #expect(hit(frame.start) == nil)
        // Only events in view are laid out.
        #expect(items.map(\.id) == [first.id, second.id, rule.id, generated.id])
    }

    @Test("Labels never overlap: the edited event's goes first, then one-off, repeating and generated ones")
    func labelsDontOverlap() throws {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind, _ label: String, end: Date? = nil) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: end, label: label, kind: kind)
        }
        // A year is 100 points; each label is 80.
        let peak = marker(utc(2028, 1), .generated, "Peak"), herd = marker(utc(2028, 2), .generated, "HerdImmunity")
        let set = marker(utc(2028, 6), .oneOff, "R₀ → 1.1"), later = marker(utc(2031, 1), .oneOff, "R₀ → 2.5")
        let first = marker(utc(2027, 1), .recurring, "Vaccinate 6,000 every week")
        let second = marker(utc(2027, 3), .recurring, "Vaccinate 250 every week")
        let markers = [first, second, peak, herd, set, later]
        let items = EventsStrip.layout(markers: markers, frame: frame, width: width) { _, _ in 80 }
        let rects = items.compactMap(\.labelRect)
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) { #expect(!a.insetBy(dx: -EventsStrip.labelGap / 2 + 0.01, dy: 0).intersects(b)) }
            #expect(a.minX >= 0 && a.maxX <= width)
        }
        func shown(_ marker: EventMarker) -> Bool { items.first { $0.id == marker.id }?.labelRect != nil }
        #expect(shown(set) && shown(later) && shown(first))
        #expect(!shown(second) && !shown(peak) && !shown(herd))
        // Overlapping repeating events get rows of their own.
        #expect(items.first { $0.id == first.id }?.row == 0)
        #expect(items.first { $0.id == second.id }?.row == 1)

        // The event being edited wins its place over a one-off event's.
        let editing = EventsStrip.layout(markers: markers, frame: frame, width: width, editingID: second.id) { _, _ in 80 }
        #expect(editing.first { $0.id == second.id }?.labelRect != nil)
        #expect(editing.first { $0.id == first.id }?.labelRect == nil)

        // Labels are measured in the strip's font.
        #expect(EventsStrip.labelWidth("HerdImmunity", italic: true) > EventsStrip.labelWidth("Peak", italic: true))
        #expect(EventsStrip.labelWidth("Peak", italic: false) > 15)
    }

    @Test("Clicking a repeating event loads it with its repeat; saving keeps its end, and undo and redo cover it")
    func editsRepeating() async throws {
        let store = try await makeStore()
        let rule = RecurringEvent(kind: "deposit", values: ["amount": 300], first: utc(2027, 3), every: .monthly, until: utc(2035, 12))
        store.add(rule, toSlotAt: 0)
        let added = try #require(store.configs[0].rules.last)
        store.editEvent(id: added.id)
        #expect(store.editingEvent?.rule == added)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.amountText == "300")
        #expect(store.eventDraft.repeats == .monthly)
        #expect(store.eventDraft.date == added.first)
        #expect(store.timelineState().focus.editingEventID == added.id)

        store.eventDraft.amountText = "450"
        #expect(store.commitEvent())
        #expect(store.message == "Changed +$300 every month from Mar 2027 to a deposit of $450 every month from Mar 2027 in Savings")
        let changed = try #require(store.configs[0].rules.last)
        #expect(changed.values == ["amount": 450])
        #expect(changed.until == utc(2035, 12))
        #expect(store.configs[0].rules.count == 1)
        #expect(store.timelineState().focus.events.filter { $0.kind == .recurring }.map(\.label) == ["+$450 every month"])

        store.undo()
        #expect(store.configs[0].rules == [added])
        store.redo()
        #expect(store.configs[0].rules == [changed])
        await store.waitUntilIdle()
    }

    @Test("A repeating event can become a one-off, or be deleted, and undo puts it back")
    func repeatingToOneOffAndDelete() async throws {
        let store = try await makeStore()
        store.add(RecurringEvent(kind: "deposit", values: ["amount": 300], first: utc(2027, 3), every: .monthly), toSlotAt: 0)
        let rule = try #require(store.configs[0].rules.last)
        let events = store.configs[0].events

        store.editEvent(id: rule.id)
        store.eventDraft.repeats = .never
        #expect(store.commitEvent())
        #expect(store.configs[0].rules.isEmpty)
        #expect(store.configs[0].events.count == events.count + 1)
        store.undo()
        #expect(store.configs[0].rules == [rule])
        #expect(store.configs[0].events == events)

        store.editEvent(id: rule.id)
        store.requestEventDeletion()
        #expect(store.eventDeletionQuestion == "Delete +$300 every month from Mar 2027 from Savings? Undo brings it back.")
        store.deleteEditedEvent()
        #expect(store.configs[0].rules.isEmpty)
        #expect(store.message == "Deleted +$300 every month from Mar 2027 from Savings")
        store.undo()
        #expect(store.configs[0].rules == [rule])
        await store.waitUntilIdle()
    }

    @Test("The preview of an edited repeating event replaces it, not adds to it")
    func repeatingPreviewReplaces() async throws {
        let store = try await makeStore()
        store.add(RecurringEvent(kind: "deposit", values: ["amount": 300], first: utc(2027, 3), every: .monthly), toSlotAt: 0)
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let current = try #require(store.cursorState().focusValue)
        store.editEvent(id: try #require(store.configs[0].rules.last).id)
        await store.waitUntilIdle()
        // Unchanged, the preview matches the line: the rule isn't counted twice.
        #expect(ScenarioStore.held(store.draftPreview, at: store.cursor) == current)
        #expect(store.panelState().eventPreview?.atCursor == "No change")
    }

    @Test("Event kinds other than money name themselves, with the amount in the slot's own units")
    func labels() async throws {
        let store = try await makeStore()
        store.focus(index: 3)  // Climate: shows a temperature, not money.
        #expect(store.label(for: Event(time: now, kind: "vaccinate", values: ["amount": 6000]), inSlotAt: 3) == "Vaccinate 6,000")
        #expect(store.label(for: RecurringEvent(kind: "vaccinate", values: ["amount": 250], first: now, every: .weekly), inSlotAt: 3)
                == "Vaccinate 250 every week")
        #expect(store.label(for: Event(time: now, kind: "deposit", values: ["amount": 500]), inSlotAt: 3) == "+$500")
        #expect(store.label(for: RecurringEvent(kind: "overpay", values: ["amount": 100], first: now, every: .monthly), inSlotAt: 2)
                == "−$100 overpayment every month")
        #expect(store.label(for: Event(time: now, kind: "bonus", values: ["amount": 1, "extra": 2]), inSlotAt: 0) == "Bonus")
        await store.waitUntilIdle()
    }

    @Test func eventLinesAreForAddedEventsOnly() {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: nil, label: "", kind: kind)
        }
        let oneOff = marker(utc(2028, 8), .oneOff), rule = marker(utc(2030, 1), .recurring)
        let generated = marker(utc(2032, 1), .generated), early = marker(utc(2020, 1), .oneOff)
        let dates = FocusChart.eventLineDates([early, oneOff, rule, generated])
        #expect(dates == [early.date, oneOff.date, rule.date])
        // Only the ones in view get a line.
        #expect(PlotEventLines.xs(dates: dates, frame: frame, width: width)
                == [frame.x(oneOff.date, width: width), frame.x(rule.date, width: width)])
        // A day apart over ten years is well under 4 points: one line, not two.
        let nextDay = oneOff.date.addingTimeInterval(86_400)
        #expect(PlotEventLines.xs(dates: [nextDay, oneOff.date], frame: frame, width: width).count == 1)
    }
}
