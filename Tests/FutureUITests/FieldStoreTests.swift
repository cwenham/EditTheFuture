import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// Fields at the cursor in the panel (docs/DESIGN.md, 4.10): watched by name, worked out off the
/// main thread when the cursor moves or results change, and kept with their slot.
@MainActor
@Suite("Fields at the cursor")
struct FieldStoreTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> (ScenarioStore, UUID) {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        store.addModel(ModelLibrary.epidemic, atPosition: 6)
        await store.waitUntilIdle()
        return (store, store.focused.id)
    }

    func groups(_ store: ScenarioStore, _ id: UUID) throws -> FieldSample {
        let index = try #require(store.slotIndex(id: id))
        return try #require(store.field("groups", ofSlotAt: index))
    }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        utc(year, month, day).addingTimeInterval(Double(hour) * 3600)
    }

    @Test("Nothing is worked out until a field is watched")
    func noneUntilWatched() async throws {
        let (store, id) = try await makeStore()
        store.setCursor(utc(2027, 3))
        await store.waitUntilIdle()
        #expect(store.fieldsAtCursor.isEmpty)
        #expect(store.watchedFields[id] == nil)
    }

    @Test("A watched field arrives for the cursor, and follows it")
    func followsCursor() async throws {
        let (store, id) = try await makeStore()
        store.setCursor(at(2022, 3, 20, 12))
        store.watch(fields: ["groups", "nonsense"], ofSlot: id)
        await store.waitUntilIdle()
        let first = try groups(store, id)
        #expect(first.time == utc(2022, 3, 20))
        #expect(first.keys == ["susceptible", "exposed", "infectious", "recovered", "vaccinated"])
        #expect(abs(first.values.reduce(0, +) - 1) < 1e-9)
        #expect(store.fieldsAtCursor[id]?.keys.sorted() == ["groups"])

        store.setCursor(utc(2022, 6, 3))
        await store.waitUntilIdle()
        let later = try groups(store, id)
        #expect(later.time == utc(2022, 6, 3))
        #expect(later["recovered"]! > first["recovered"]!)

        // The same point again changes nothing.
        let before = store.fieldsAtCursor
        store.setCursor(at(2022, 6, 3, 18))
        await store.waitUntilIdle()
        #expect(store.fieldsAtCursor == before)
    }

    @Test("An edit before the cursor changes the field there")
    func afterEdit() async throws {
        let (store, id) = try await makeStore()
        store.setCursor(utc(2023, 6))
        store.watch(fields: ["groups"], ofSlot: id)
        await store.waitUntilIdle()
        #expect(try groups(store, id)["vaccinated"] == 0)

        let index = try #require(store.slotIndex(id: id))
        store.add(Event(time: utc(2022, 1, 15), kind: "vaccinate", values: ["amount": 250_000]), toSlotAt: index)
        await store.waitUntilIdle()
        #expect(try groups(store, id)["vaccinated"] == 0.25)
    }

    @Test("Fields stay with their slot when it moves, and stop when unwatched")
    func followsSlot() async throws {
        let (store, id) = try await makeStore()
        store.setCursor(utc(2027, 1))
        store.watch(fields: ["groups"], ofSlot: id)
        await store.waitUntilIdle()
        let index = try #require(store.slotIndex(id: id))
        store.moveSlot(at: index, toPosition: 7)
        await store.waitUntilIdle()
        #expect(try groups(store, id).time == utc(2027, 1))

        store.watch(fields: [], ofSlot: id)
        await store.waitUntilIdle()
        #expect(store.fieldsAtCursor.isEmpty)
        let moved = try #require(store.slotIndex(id: id))
        #expect(store.field("groups", ofSlotAt: moved) == nil)
    }

    @Test("The cursor stops at the start, where the field is everyone's starting group")
    func atStart() async throws {
        let (store, id) = try await makeStore()
        store.watch(fields: ["groups"], ofSlot: id)
        store.setCursor(utc(2010, 1))
        await store.waitUntilIdle()
        let field = try groups(store, id)
        #expect(field.time == utc(2022, 1))
        #expect(field.values == [0.99999, 0.00001, 0, 0, 0])
    }
}
