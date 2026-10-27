import Foundation
import Observation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// Notes that something happened, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Refit in the panel (docs/UI.md, 5.11): the sheet, the fit off the main thread, the dashed
/// preview, Apply and undo.
@MainActor
@Suite("Refit in the panel")
struct RefitTests {
    let now = utc(2026, 10, 25)
    let start = utc(2020, 1, 1)

    static let growth = """
        step 1 month
        param growth = 3% range -50%..100% label "Growth per month" fit
        param fee = 0
        init value = 0
        value[t] = value[t-1] * (1 + growth) - fee
        """

    /// Monthly readings from the start, growing by `rate` a month.
    func readings(count: Int, rate: Double) -> SlotReadings {
        let list = (0..<count).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: start)!, variable: "value",
                    value: 1000 * pow(1 + rate, Double(index)))
        }
        return SlotReadings(sources: [.inline(csv: "")], parts: [ReadingSet(list)])
    }

    func makeStore(readings: SlotReadings) async throws -> ScenarioStore {
        let definition = ScenarioDefinition(name: "Fits", start: start, slots: [
            SlotSpec(name: "Data", formula: Self.growth, variable: "value", format: .number, readings: readings),
            SlotSpec(name: "Plain", formula: Self.growth, variable: "value", format: .number),
        ])
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    func settle(_ store: ScenarioStore) async {
        await store.waitForRefit()
        await store.waitUntilIdle()
    }

    @Test("Only slots with readings of a value can be refitted")
    func refittable() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        #expect(store.canRefit(slot: store.slots[0].id))
        #expect(!store.canRefit(slot: store.slots[1].id))
        store.openRefit(slotAt: 1)
        #expect(store.refit == nil)
        #expect(store.messageIsError)
        #expect(store.message?.contains("no readings") == true)
    }

    @Test("Opening fits the marked values, shows the fitted line dashed, and Apply makes them the slot's own")
    func fitAndApply() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        let before = store.timelineState().focus.samples
        store.openRefit(slotAt: 0)
        #expect(store.sidePane == .slot)
        let opened = try #require(store.refit)
        #expect(opened.choices.map(\.name) == ["growth", "fee"])
        #expect(opened.choices.map(\.ticked) == [true, false])
        #expect(opened.choices[0].label == "Growth per month" && opened.choices[0].current == "3%")
        #expect(!opened.noneMarked)
        #expect(opened.phase == .fitting)

        await settle(store)
        let found = try #require(store.refit?.applicable)
        #expect(found.values == ["growth": 0.01])
        #expect(found.changes.map(\.to) == ["1%"])
        #expect(found.summary == "Misses the next reading by less than 0.1%, was 2.0%.")
        // The dashed line is the slot with the fitted growth; the slot itself hasn't changed.
        let preview = store.timelineState().focus.preview
        #expect(!preview.isEmpty)
        #expect(store.timelineState().focus.samples == before)
        #expect(store.configs[0].values.isEmpty)

        store.applyRefit()
        #expect(store.refit == nil)
        #expect(store.configs[0].values == ["growth": 0.01])
        #expect(store.message == "Refitted Data: Growth per month 3% → 1%")
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.preview.isEmpty)
        #expect(store.slots[0].parameterValues.first { $0.name == "growth" }?.value == 0.01)

        store.undo()
        #expect(store.configs[0].values.isEmpty)
    }

    @Test("Ticking and unticking values, and choosing readings, fit again")
    func choices() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        store.openRefit(slotAt: 0)
        await settle(store)

        store.setRefitChoice("growth", ticked: false)
        #expect(store.refit?.phase == .nothingTicked)
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.preview.isEmpty)

        store.setRefitChoice("fee", ticked: true)
        #expect(store.refit?.phase == .fitting)
        await settle(store)
        let fee = try #require(store.refit?.applicable)
        #expect(fee.values.keys.sorted() == ["fee"])

        store.setRefitChoice("growth", ticked: true)
        store.setRefitWindow(.year)
        #expect(store.refit?.window == .year)
        await settle(store)
        let both = try #require(store.refit?.applicable)
        #expect(abs(both.values["growth"]! - 0.01) < 1e-6)
        #expect(abs(both.values["fee"]!) < 1e-3)
    }

    @Test("Values that already fit best can't be applied")
    func alreadyBest() async throws {
        let store = try await makeStore(readings: readings(count: 40, rate: 0.03))
        store.openRefit(slotAt: 0)
        await settle(store)
        guard case .fitted(let found) = store.refit?.phase else {
            Issue.record("Expected a fit, got \(String(describing: store.refit?.phase))")
            return
        }
        #expect(!found.improved)
        #expect(store.refit?.applicable == nil)
        #expect(found.summary == "Misses the next reading by less than 0.1%.")
        #expect(store.timelineState().focus.preview.isEmpty)
        store.applyRefit()
        #expect(store.refit != nil)
        #expect(store.configs[0].values.isEmpty)
    }

    @Test("A fit that can't run says why")
    func failure() async throws {
        let store = try await makeStore(readings: readings(count: 2, rate: 0.01))
        store.openRefit(slotAt: 0)
        await settle(store)
        #expect(store.refit?.phase == .failed("Fitting needs at least 2 readings that follow an earlier one. Data has 1."))
    }

    @Test("Leaving the Slot tab, focusing another slot or cancelling closes the sheet and its preview")
    func closing() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        for leave in [{ store.focus(index: 1) }, { store.showFormulaEditor() }, { store.toggleSlotSettings() },
                      { store.beginEvent(at: store.now) }, { store.closeRefit() }] as [() -> Void] {
            store.focus(index: 0)
            store.openRefit(slotAt: 0)
            await settle(store)
            #expect(!store.timelineState().focus.preview.isEmpty)
            leave()
            #expect(store.refit == nil)
            await store.waitUntilIdle()
            #expect(store.parameterPreview.isEmpty)
        }
    }

    @Test("Cancelling while it fits drops the fit")
    func cancelWhileFitting() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        store.openRefit(slotAt: 0)
        store.closeRefit()
        await settle(store)
        #expect(store.refit == nil)
        #expect(store.parameterPreview.isEmpty)
    }

    @Test("The graph redraws when the fitted line arrives, without being nudged")
    func redraws() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        store.openRefit(slotAt: 0)
        let changed = Flag()
        withObservationTracking { _ = store.timelineState() } onChange: { changed.set() }
        await settle(store)
        #expect(!store.parameterPreview.isEmpty)
        #expect(changed.isSet)
    }

    @Test("The preview follows scrolling")
    func previewFollowsScrolling() async throws {
        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        store.openRefit(slotAt: 0)
        await settle(store)
        for _ in 0..<12 { store.pan(by: 0.9) }
        await store.waitUntilIdle()
        let state = store.timelineState()
        let last = try #require(state.focus.preview.last)
        #expect(last.time >= state.frame.end)
    }

    @Test("refit in the command bar opens the sheet for a slot, or the focused one")
    func command() async throws {
        #expect(try CommandBarParser.parse("refit") == .refit(nil))
        #expect(try CommandBarParser.parse("Refit Data") == .refit("Data"))

        let store = try await makeStore(readings: readings(count: 82, rate: 0.01))
        store.focus(index: 1)
        store.commandText = "refit data"
        _ = store.runCommand()
        #expect(store.refit?.slot == store.slots[0].id)
        #expect(store.focused.id == store.slots[0].id)
        await settle(store)

        store.commandText = "refit nowhere"
        _ = store.runCommand()
        #expect(store.messageIsError)
    }
}
