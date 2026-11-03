import Foundation
import Testing
import FutureTestSupport
import FutureDocument
import FutureEngine
import FutureSimulation
import FutureVisuals
@testable import FutureKit

/// The World epidemic module in the app, with the world's countries the app gives it (docs/DESIGN.md, 6.5 and 9.6).
@MainActor
@Suite("World epidemic in the app")
struct WorldEpidemicSlotTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> (ScenarioStore, Int) {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        let template = try #require(ModelLibrary.template(id: "world-epidemic"))
        #expect(store.addModel(template.startingAtStart, atPosition: 6))
        await store.waitUntilIdle()
        return (store, store.focusedIndex)
    }

    @Test("The app gives it every country with people, and the picker lists it under Health with the world map")
    func library() throws {
        let countries = AppModuleData.countries
        #expect(countries.count > 170)
        #expect(countries.keys.contains("GBR") && countries.keys.contains("CHN"))
        #expect(countries.column("population")?.allSatisfy { $0 > 0 } == true)
        let template = try #require(ModelLibrary.template(id: "world-epidemic"))
        #expect(template.kind.title == "Swift")
        #expect(template.category == .health)
        #expect(template.backdrop == BackdropBinding(id: "world-map", field: "infectious"))
    }

    @Test("A new slot draws the world map, lit where it started, and saves both")
    func newSlot() async throws {
        let (store, index) = try await makeStore()
        #expect(store.focused.name == "Pandemic")
        #expect(store.focused.backdrop == BackdropBinding(id: "world-map", field: "infectious"))
        #expect(store.backdropChoices(forSlotAt: index).map(\.title)
                == ["World map: Infectious now", "World map: Ever infected", "Parts of a whole: Where everyone is"])

        // Three months in, it's mostly in Britain, where it starts by default; far away there's none yet.
        store.setCursor(utc(2022, 4))
        await store.waitUntilIdle()
        let state = try #require(store.backdropState())
        #expect(state.id == "world-map")
        #expect(state.input.scale == .logarithmic(faintest: 1e-6, full: 0.1))
        let shades = state.input.intensities()
        let britain = try #require(shades["GBR"])
        #expect(britain > 0.3)
        #expect(shades.values.allSatisfy { $0 <= britain })
        #expect(shades["AUS"] == 0)
        #expect(state.input.field?.keys.count == AppModuleData.countries.count)

        let file = store.scenarioFile().slots[index]
        #expect(file.module == "world-epidemic@1")
        #expect(file.backdrop == BackdropSetting(id: "world-map", field: "infectious"))
    }

    @Test("It reaches most of the world, and starts where it's told")
    func spreads() async throws {
        let (store, index) = try await makeStore()
        let reached = try #require(await store.value(slot: "Pandemic", variable: "reached", at: utc(2024, 1), now: now).value)
        #expect(reached > 150)

        // Starting in Brazil instead.
        store.setStartingValue("originLatitude", to: -14, inSlotAt: index)
        store.setStartingValue("originLongitude", to: -51, inSlotAt: index)
        store.setCursor(utc(2022, 4))
        await store.waitUntilIdle()
        let shades = try #require(store.backdropState()).input.intensities()
        let brazil = try #require(shades["BRA"])
        #expect(brazil > 0.3 && shades.values.allSatisfy { $0 <= brazil })
        #expect(shades["GBR"] ?? 0 < brazil)
    }
}

private extension Result where Success == ScenarioStore.OutsideValue {
    var value: Double? { (try? get())?.reading.value }
}
