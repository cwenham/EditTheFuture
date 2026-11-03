import Foundation
import Testing
import FutureTestSupport
import FutureDocument
import FutureEngine
@testable import FutureKit

/// The view reaching back before the scenario's start, where there are only readings
/// (docs/UI.md, 2.4 and 5.1).
@MainActor
@Suite("Before the start")
struct BeforeStartTests {
    let history = HistoryScenario()
    var now: Date { history.now }
    var start: Date { history.start }
    var firstReading: Date { history.firstReading }

    func readings(from first: Date) -> SlotReadings { history.readings(from: first) }

    func makeStore(readingsFrom first: Date? = nil) async throws -> ScenarioStore {
        try await history.makeStore(readingsFrom: first)
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
        #expect(cursor.readoutValue == ValueStyle.number.full(1125))
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
}
