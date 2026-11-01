import Foundation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// Drift alerts in the panel (docs/UI.md, 5.6): the check after readings change, the pill, the band,
/// the lane's mark, the notification hook and Refit on the last year.
@MainActor
@Suite("Drift alerts in the panel")
struct DriftPanelTests {
    let now = utc(2026, 10, 25)
    let start = utc(2020, 1, 1)

    static let growth = """
        step 1 month
        param growth = 1% range -50%..100% label "Growth per month" fit
        init value = 0
        value[t] = value[t-1] * (1 + growth)
        """

    /// Monthly readings from the start, growing 1% a month, with the last `jumped` of them 20% higher.
    func readings(count: Int, jumped: Int) -> SlotReadings {
        let list = (0..<count).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: start)!, variable: "value",
                    value: 1000 * pow(1.01, Double(index)) * (index >= count - jumped ? 1.2 : 1))
        }
        return SlotReadings(sources: [.inline(csv: "")], parts: [ReadingSet(list)])
    }

    func makeStore(_ readings: SlotReadings) async throws -> ScenarioStore {
        let definition = ScenarioDefinition(name: "Drift", start: start, slots: [
            SlotSpec(name: "Data", formula: Self.growth, variable: "value", format: .number, readings: readings),
            SlotSpec(name: "Plain", formula: Self.growth, variable: "value", format: .number),
        ])
        let store = try ScenarioStore(definition: definition, now: now)
        store.driftDelay = .zero
        store.scheduleDriftCheck()
        await settle(store)
        return store
    }

    func settle(_ store: ScenarioStore) async {
        await store.waitForDriftCheck()
        await store.waitUntilIdle()
    }

    @Test("Readings that leave the projected range show a pill and a band on the graph, and a mark on the lane")
    func showsDrift() async throws {
        let store = try await makeStore(readings(count: 82, jumped: 8))
        let id = store.slots[0].id
        let alert = try #require(store.drift(forSlot: id))
        #expect(alert.text == "20.0% above the projection")
        #expect(alert.detail.hasPrefix("Data's readings since "))
        #expect(alert.detail.hasSuffix(" are running 20.0% above what its model projected for them."))

        let focus = store.timelineState().focus
        let mark = try #require(focus.drift)
        #expect(mark.text == alert.text)
        #expect(!mark.band.isEmpty && !mark.line.isEmpty)
        // The band is within the graph's range.
        #expect(mark.band.allSatisfy { focus.yDomain.contains($0.low) && focus.yDomain.contains($0.high) })

        store.focus(index: 1)
        let lanes = store.timelineState().lanes
        #expect(lanes.first { $0.name == "Data" }?.drift == alert.detail)
        #expect(store.timelineState().focus.drift == nil)
    }

    @Test("Readings that follow the model don't drift, and the alert goes when new readings follow it again")
    func noDriftAndClearing() async throws {
        let store = try await makeStore(readings(count: 82, jumped: 0))
        #expect(store.drifts.isEmpty)
        #expect(store.timelineState().focus.drift == nil)

        store.setReadings(readings(count: 82, jumped: 8), forSlotAt: 0)
        await settle(store)
        #expect(store.drift(forSlot: store.slots[0].id) != nil)

        store.setReadings(readings(count: 82, jumped: 0), forSlotAt: 0)
        await settle(store)
        #expect(store.drifts.isEmpty)
    }

    @Test("Each drift is passed on for a notification once, until newer readings drift again")
    func notifiesOnce() async throws {
        let store = try await makeStore(readings(count: 82, jumped: 0))
        var alerts: [DriftAlert] = []
        store.onDrift = { alerts.append($0) }

        store.setReadings(readings(count: 82, jumped: 8), forSlotAt: 0)
        await settle(store)
        #expect(alerts.count == 1)
        #expect(alerts.first?.title == "Data")

        // The same drift checked again, after an unrelated change, isn't passed on again.
        store.setReadings(readings(count: 82, jumped: 0), forSlotAt: 0)
        await settle(store)
        store.setReadings(readings(count: 82, jumped: 8), forSlotAt: 0)
        await settle(store)
        #expect(alerts.count == 1)

        // A newer reading that still drifts is.
        store.setReadings(readings(count: 83, jumped: 9), forSlotAt: 0)
        await settle(store)
        #expect(alerts.count == 2)
    }

    @Test("Clicking the pill focuses the slot and opens Refit on the last year of readings")
    func pillOpensRefit() async throws {
        let store = try await makeStore(readings(count: 82, jumped: 8))
        store.focus(index: 1)
        store.openDriftRefit(slot: store.slots[0].id)
        #expect(store.focusedIndex == 0)
        #expect(store.sidePane == .slot)
        let refit = try #require(store.refit)
        #expect(refit.window == .year)
        #expect(refit.choices.first { $0.name == "growth" }?.ticked == true)
        await store.waitForRefit()
        store.closeRefit()
    }

    @Test("Removing a drifting slot's readings takes its alert away")
    func removingReadings() async throws {
        let store = try await makeStore(readings(count: 82, jumped: 8))
        #expect(!store.drifts.isEmpty)
        store.setReadings(.none, forSlotAt: 0)
        await settle(store)
        #expect(store.drifts.isEmpty)
    }
}
