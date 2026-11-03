import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit

/// More than one output of a slot in the panel's results (docs/DESIGN.md, 4.9): asked for by name,
/// fetched with the value the graph draws, and kept with their slot when slots move.
@MainActor
@Suite("Slot outputs")
struct OutputTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    /// The value the etf tool and Shortcuts read, straight from the engine.
    func engineValue(_ store: ScenarioStore, slot: String, _ variable: String, at date: Date) async throws -> Double {
        guard case .success(let answer) = await store.value(slot: slot, variable: variable, at: date, now: now) else {
            throw CancellationError()
        }
        return answer.reading.value
    }

    @Test("Only the drawn value comes with results until other outputs are asked for")
    func noneByDefault() async throws {
        let store = try await makeStore()
        let computed = try #require(store.computed)
        let noOutputs = computed.outputs.allSatisfy { $0.isEmpty }
        #expect(noOutputs)
        #expect(store.outputSeries("balance", ofSlotAt: 0) == computed.series[0])
        #expect(store.outputSeries("monthly", ofSlotAt: 0) == nil)
    }

    @Test("A script's foxes come with its rabbits, and match what the engine has")
    func scriptOutputs() async throws {
        let store = try await makeStore()
        store.addModel(ModelLibrary.predatorPrey, atPosition: 6)
        let index = store.focusedIndex
        #expect(store.slots[index].variable == "rabbits")
        store.want(outputs: ["foxes"], ofSlot: store.slots[index].id)
        await store.waitUntilIdle()

        let foxes = try #require(store.outputSeries("foxes", ofSlotAt: index))
        #expect(!foxes.isEmpty)
        #expect(foxes.count == store.outputSeries("rabbits", ofSlotAt: index)?.count)
        let date = utc(2027, 6)
        let fetched = try #require(store.outputValue("foxes", ofSlotAt: index, at: date))
        let direct = try await engineValue(store, slot: "Rabbits", "foxes", at: date)
        #expect(fetched == direct)
    }

    @Test("A module's outputs: several at once, and names it hasn't got are left out")
    func moduleOutputs() async throws {
        let store = try await makeStore()
        store.addModel(ModelLibrary.epidemic, atPosition: 6)
        let index = store.focusedIndex, id = store.slots[index].id
        store.want(outputs: ["recovered", "vaccinated", "caught", "r0", "nonsense"], ofSlot: id)
        await store.waitUntilIdle()
        for name in ["recovered", "vaccinated", "caught", "r0"] {
            #expect(store.outputSeries(name, ofSlotAt: index)?.isEmpty == false, "\(name)")
        }
        #expect(store.outputSeries("nonsense", ofSlotAt: index) == nil)
        #expect(store.computed?.outputs[index].keys.sorted() == ["caught", "r0", "recovered", "vaccinated"])

        // What came with the results is what the engine has.
        let date = utc(2027, 1)
        let recovered = try #require(store.outputValue("recovered", ofSlotAt: index, at: date))
        let direct = try await engineValue(store, slot: "Outbreak", "recovered", at: date)
        #expect(abs(recovered - direct) < 1e-9)

        // Asking for none stops them coming with later results.
        store.want(outputs: [], ofSlot: id)
        store.show(utc(2060, 1))
        await store.waitUntilIdle()
        #expect(store.computed?.outputs[index].isEmpty == true)
    }

    @Test("Outputs follow later fetches, and stay with their slot when it moves")
    func followsSlot() async throws {
        let store = try await makeStore()
        store.addModel(ModelLibrary.predatorPrey, atPosition: 6)
        let id = store.focused.id
        store.want(outputs: ["foxes"], ofSlot: id)
        await store.waitUntilIdle()

        store.show(utc(2080, 1))
        await store.waitUntilIdle()
        let index = try #require(store.slotIndex(id: id))
        let foxes = try #require(store.outputSeries("foxes", ofSlotAt: index))
        #expect(foxes.contains { $0.time >= utc(2080, 1) })

        store.moveSlot(at: index, toPosition: 7)
        let moved = try #require(store.slotIndex(id: id))
        // Straight away, from the results the store already has...
        #expect(store.outputSeries("foxes", ofSlotAt: moved)?.isEmpty == false)
        await store.waitUntilIdle()
        // ...and from the fetch after the move.
        #expect(store.outputSeries("foxes", ofSlotAt: moved)?.contains { $0.time >= utc(2080, 1) } == true)
        #expect(store.wantedOutputs[id] == ["foxes"])
    }
}
