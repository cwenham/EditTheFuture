import Foundation
import Testing
import FutureDocument
import FutureEngine
import FutureVisuals
@testable import FutureUI

/// Backdrops behind the focused graph (docs/DESIGN.md, 9.6): chosen per slot, fed with the field at
/// the cursor or a position, saved in scenario.md and undone like any slot change.
@MainActor
@Suite("Backdrops in the panel")
struct BackdropStoreTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> (ScenarioStore, Int) {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        store.addModel(ModelLibrary.epidemic, atPosition: 6)
        await store.waitUntilIdle()
        return (store, store.focusedIndex)
    }

    @Test("An Epidemic slot offers its groups as parts of a whole; other slots offer nothing")
    func choices() async throws {
        let (store, index) = try await makeStore()
        #expect(store.backdropChoices(forSlotAt: index).map(\.title) == ["Parts of a whole: Where everyone is"])
        #expect(store.backdropChoices(forSlotAt: 0).isEmpty)
        #expect(store.backdropState() == nil)
    }

    @Test("Choosing one draws the field at the cursor, with the model's names for its parts, and undo takes it away")
    func choosing() async throws {
        let (store, index) = try await makeStore()
        store.setCursor(utc(2022, 4))
        store.setBackdrop(BackdropBinding(id: "parts", field: "groups"), inSlotAt: index)
        await store.waitUntilIdle()
        let state = try #require(store.backdropState())
        #expect(state.id == "parts")
        let field = try #require(state.input.field)
        #expect(field.time == utc(2022, 4))
        #expect(abs(field.values.reduce(0, +) - 1) < 1e-9)
        #expect(state.input.label == "Where everyone is")
        #expect(state.input.quantity == .percent)
        #expect(state.input.keyLabels["susceptible"] == "Can still catch it")
        #expect(state.input.color == store.focused.color)
        #expect(store.panelState().backdrop == state)
        #expect(store.scenarioFile().slots[index].backdrop == BackdropSetting(id: "parts", field: "groups"))

        // It follows the cursor.
        store.setCursor(utc(2022, 9))
        await store.waitUntilIdle()
        #expect(store.backdropState()?.input.field?.time == utc(2022, 9))

        store.undo()
        await store.waitUntilIdle()
        #expect(store.backdropState() == nil)
        #expect(store.scenarioFile().slots[index].backdrop == nil)
    }

    @Test("Only the focused slot's backdrop is drawn, and worked out")
    func focusedOnly() async throws {
        let (store, index) = try await makeStore()
        let id = store.slots[index].id
        store.setCursor(utc(2022, 4))
        store.setBackdrop(BackdropBinding(id: "parts"), inSlotAt: index)
        await store.waitUntilIdle()
        #expect(store.fieldsAtCursor[id]?["groups"] != nil)

        store.focus(index: 0)
        await store.waitUntilIdle()
        #expect(store.backdropState() == nil)
        #expect(store.fieldsAtCursor.isEmpty)

        store.focus(index: try #require(store.slotIndex(id: id)))
        await store.waitUntilIdle()
        #expect(store.backdropState()?.input.field != nil)
    }

    @Test("A slot with a latitude and longitude puts a point on the world map")
    func position() async throws {
        let ship = SlotSpec(name: "Ship", formula: "step 1 month\nlat[t] = 50 - month\nlon[t] = -30 + 2 * month",
                            variable: "lat", format: .number)
        let store = try ScenarioStore(definition: ScenarioDefinition(name: "Voyage", start: utc(2026, 1), slots: [ship]), now: now)
        await store.waitUntilIdle()
        #expect(store.backdropChoices(forSlotAt: 0).map(\.title) == ["World map: Position"])
        store.setBackdrop(BackdropBinding(id: "world-map", latitude: "lat", longitude: "lon"), inSlotAt: 0)
        store.setCursor(utc(2026, 3))
        await store.waitUntilIdle()
        #expect(store.backdropState()?.input.point == GeoPoint(latitude: 47, longitude: -24))
        store.setCursor(utc(2026, 6, 15))
        await store.waitUntilIdle()
        #expect(store.backdropState()?.input.point == GeoPoint(latitude: 44, longitude: -18))
    }

    @Test("A field the model hasn't got draws an empty backdrop, and a backdrop the app hasn't got draws none")
    func missing() async throws {
        let (store, index) = try await makeStore()
        store.setBackdrop(BackdropBinding(id: "parts", field: "nothing"), inSlotAt: index)
        await store.waitUntilIdle()
        #expect(store.backdropState()?.input.field == nil)
        store.setBackdrop(BackdropBinding(id: "sky-map"), inSlotAt: index)
        await store.waitUntilIdle()
        #expect(store.backdropState() == nil)
    }
}
