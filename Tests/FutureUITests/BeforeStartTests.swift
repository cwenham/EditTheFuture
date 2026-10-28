import Foundation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// The view reaching back before the scenario's start, where there are only readings
/// (docs/UI.md, 2.4 and 5.1).
@MainActor
@Suite("Before the start")
struct BeforeStartTests {
    let now = utc(2026, 10, 25)
    let start = utc(2020, 1, 1)
    let firstReading = utc(2000, 1, 1)

    static let growth = """
        step 1 month
        param growth = 0.5%
        init value = 1000
        value[t] = value[t-1] * (1 + growth)
        """

    /// Monthly readings from 2000 through 2024: 1000 plus the month's number.
    func readings(from first: Date) -> SlotReadings {
        let list = (0..<300).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: first)!, variable: "value",
                    value: 1000 + Double(index))
        }
        return SlotReadings(sources: [.inline(csv: "")], parts: [ReadingSet(list)])
    }

    func makeStore(readingsFrom first: Date? = nil) async throws -> ScenarioStore {
        let definition = ScenarioDefinition(name: "History", start: start, slots: [
            SlotSpec(name: "Data", formula: Self.growth, variable: "value", format: .number,
                     readings: readings(from: first ?? firstReading)),
            SlotSpec(name: "Plain", formula: Self.growth, variable: "value", format: .number),
        ])
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    @Test("Without readings before the start, the view and cursor stop at the start")
    func stopsAtTheStart() async throws {
        let store = try await makeStore(readingsFrom: utc(2021, 1, 1))
        #expect(store.earliest == start)
        store.pan(by: -100)
        #expect(store.frame.start == start)
        store.show(utc(2010, 1))
        #expect(store.cursor == start)
        #expect(!store.timelineState().showsStart)
    }

    @Test("With readings before the start, the view and cursor reach back to the first one")
    func reachesTheFirstReading() async throws {
        let store = try await makeStore()
        #expect(store.earliest == firstReading)
        let span = store.frame.span
        store.pan(by: -100)
        #expect(store.frame.start == firstReading)
        #expect(store.frame.span == span)
        store.show(utc(1990, 1))
        #expect(store.cursor == firstReading)
        store.zoom(by: 1e6)
        #expect(store.frame.start >= firstReading)
        await store.waitUntilIdle()
    }

    @Test("Before the start the graph draws readings and no line, and marks the start")
    func drawsReadingsOnly() async throws {
        let store = try await makeStore()
        store.zoom(by: 1e6)
        store.pan(by: -100)
        await store.waitUntilIdle()
        let timeline = store.timelineState()
        #expect(timeline.frame.start == firstReading)
        #expect(timeline.start == start)
        #expect(timeline.showsStart)
        #expect(timeline.startText == "Start · Jan 2020")
        #expect(timeline.focus.readings.contains { $0.time < start })
        #expect(!timeline.focus.samples.isEmpty)
        #expect(timeline.focus.samples.allSatisfy { $0.time >= start })
        #expect(timeline.lanes.allSatisfy { $0.samples.allSatisfy { $0.time >= start } })
    }

    @Test("Before the start the readout shows the reading at the cursor, and the lanes a dash")
    func readoutBeforeTheStart() async throws {
        let store = try await makeStore()
        store.show(utc(2010, 6, 15))
        await store.waitUntilIdle()
        let cursor = store.cursorState()
        // June 2010 is the 126th month from January 2000.
        #expect(cursor.focusValue == 1125)
        #expect(cursor.readoutValue == ValueFormat.number.full(1125))
        #expect(cursor.readoutNote == "Reading")
        #expect(cursor.laneValues[1] == "—")

        // A slot without readings has nothing to show there.
        store.focus(index: 1)
        let plain = store.cursorState()
        #expect(plain.focusValue == nil)
        #expect(plain.readoutValue == "—")
        #expect(plain.readoutNote == "Before the start")
        #expect(plain.laneValues[0] == "—")

        // From the start on, it's the model's value again.
        store.show(utc(2030, 1))
        await store.waitUntilIdle()
        let after = store.cursorState()
        #expect(after.readoutNote == "Projection")
        #expect(after.readoutValue != "—")
    }

    @Test("Taking the readings away brings the view and cursor back to the start")
    func readingsTakenAway() async throws {
        let store = try await makeStore()
        store.pan(by: -100)
        store.show(utc(2005, 1))
        let span = store.frame.span
        store.setReadings(.none, forSlotAt: 0)
        #expect(store.earliest == start)
        #expect(store.frame.start == start)
        #expect(store.frame.span == span)
        #expect(store.cursor == start)
        await store.waitUntilIdle()
    }

    @Test("Clicking before the start picks the start for a new event")
    func eventsStartAtTheStart() async throws {
        let store = try await makeStore()
        store.beginEvent(at: utc(2010, 1))
        #expect(store.eventDraft.date >= start)
        #expect(store.eventDraft.date < start.addingTimeInterval(86_400))
    }

    @Test("The start's label goes left of its line when there's room and it misses the Now label")
    func startLabelPlacement() {
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (400, 490)) == 294)
        // Too close to the left edge.
        #expect(StartLabel.trailingEdge(startX: 60, labelWidth: 90, nowLabel: nil) == nil)
        // A scenario that starts after now, with the Now label in the way.
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (180, 270)) == nil)
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (60, 150)) == 294)
    }
}
