import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Places in the Slot tab")
struct SlotPanePlacesTests {
    @Test("The World epidemic's start is a place: no sliders, a country sets both in one change, and goals leave it alone")
    func worldEpidemic() async throws {
        let slot = try #require(ModelLibrary.template(id: "world-epidemic")).slot(position: 0)
        let store = try ScenarioStore(definition: ScenarioDefinition(name: "P", start: utc(2026, 1, 1), slots: [slot]),
                                      now: utc(2026, 11, 3))
        await store.waitUntilIdle()
        let values = store.focused.parameterValues
        let latitude = try #require(values.first { $0.name == "originLatitude" })
        let longitude = try #require(values.first { $0.name == "originLongitude" })
        #expect(latitude.coordinate?.axis == .latitude && latitude.sliderRange == nil)
        #expect(longitude.coordinate?.axis == .longitude && longitude.sliderRange == nil)
        #expect(SlotPane.place(startingAt: latitude, in: values)?.longitude == longitude)
        #expect(SlotPane.place(startingAt: longitude, in: values) == nil)
        // London to begin with.
        #expect(CountryPlaces.nearest(latitude: latitude.value!, longitude: longitude.value!)?.code == "GBR")

        let japan = try #require(CountryPlaces.all.first { $0.code == "JPN" })
        store.setStartingValues(["originLatitude": japan.latitude, "originLongitude": japan.longitude], inSlotAt: 0)
        await store.waitUntilIdle()
        #expect(store.configs[0].values["originLatitude"] == japan.latitude)
        #expect(store.configs[0].values["originLongitude"] == japan.longitude)
        #expect(CountryPlaces.nearest(latitude: japan.latitude, longitude: japan.longitude)?.code == "JPN")
        store.undo()
        await store.waitUntilIdle()
        #expect(store.configs[0].values["originLatitude"] == nil && store.configs[0].values["originLongitude"] == nil)
    }
}
