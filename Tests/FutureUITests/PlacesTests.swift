import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// Latitudes and longitudes in the Slot tab: typed or pasted as text, or set from a country.
@MainActor
@Suite("Places")
struct PlacesTests {
    @Test("Coordinates are read as people paste them")
    func reading() {
        #expect(GeoText.parse("51.5074", for: .latitude) == .one(51.5074))
        #expect(GeoText.parse("-0.1278", for: .longitude) == .one(-0.1278))
        #expect(GeoText.parse("−0.1278", for: .longitude) == .one(-0.1278))
        #expect(GeoText.parse("0.1278° W", for: .longitude) == .one(-0.1278))
        #expect(GeoText.parse("33.87 S", for: .latitude) == .one(-33.87))
        #expect(GeoText.parse("51,5", for: .latitude) == .one(51.5))
        #expect(GeoText.parse("51.5074, -0.1278", for: .latitude) == .both(latitude: 51.5074, longitude: -0.1278))
        #expect(GeoText.parse("51.5074 -0.1278", for: .longitude) == .both(latitude: 51.5074, longitude: -0.1278))
        #expect(GeoText.parse("51.5074° N, 0.1278° W", for: .latitude) == .both(latitude: 51.5074, longitude: -0.1278))
        #expect(GeoText.parse("0.1278° W, 51.5074° N", for: .latitude) == .both(latitude: 51.5074, longitude: -0.1278))
        #expect(GeoText.parse("N 40.7 W 74", for: .latitude) == .both(latitude: 40.7, longitude: -74))
        guard case .both(let lat, let lon) = GeoText.parse("51°30′26″N 0°7′39″W", for: .latitude) else {
            Issue.record("DMS wasn't read")
            return
        }
        #expect(abs(lat - 51.50722) < 1e-4 && abs(lon + 0.1275) < 1e-4)
    }

    @Test("What isn't a coordinate isn't read")
    func notCoordinates() {
        #expect(GeoText.parse("London", for: .latitude) == nil)
        #expect(GeoText.parse("91", for: .latitude) == nil)
        #expect(GeoText.parse("181", for: .longitude) == nil)
        #expect(GeoText.parse("0.12 W", for: .latitude) == nil)
        #expect(GeoText.parse("1, 2, 3", for: .latitude) == nil)
        #expect(GeoText.parse("51°75′N", for: .latitude) == nil)
        #expect(GeoText.parse("", for: .latitude) == nil)
    }

    @Test("Coordinates are written with up to four decimals")
    func writing() {
        #expect(GeoText.text(51.5) == "51.5")
        #expect(GeoText.text(-0.1278) == "−0.1278")
        #expect(GeoText.text(51.50722) == "51.5072")
        #expect(GeoText.text(-0.00001) == "0")
        #expect(GeoText.text(180) == "180")
    }

    @Test("Latitude and longitude pairs are found by name, and nothing else is")
    func pairs() {
        func value(_ name: String) -> SlotValue {
            SlotValue(name: name, label: name, quantity: .number, money: .money(.usd), minimum: -90, maximum: 90,
                      increment: 0.1, value: 1, defaultValue: 1, isChanged: false)
        }
        let marked = SlotValue.markingPlaces(["r0", "originLatitude", "originLongitude", "lat", "lng", "latitude", "flat"].map(value))
        #expect(marked[0].coordinate == nil)
        #expect(marked[1].coordinate == .init(axis: .latitude, partner: "originLongitude"))
        #expect(marked[2].coordinate == .init(axis: .longitude, partner: "originLatitude"))
        #expect(marked[3].coordinate == .init(axis: .latitude, partner: "lng"))
        #expect(marked[4].coordinate == .init(axis: .longitude, partner: "lat"))
        #expect(marked[5].coordinate == nil)  // no longitude to go with it
        #expect(marked[6].coordinate == nil)
        // A place has no slider, though the model gives it a range.
        #expect(marked[1].sliderRange == nil)
        #expect(marked[0].sliderRange != nil)
    }

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

    @Test("Every country in the menu is nearest to its own point, with a name, in order")
    func countries() {
        #expect(CountryPlaces.all.count > 150)
        #expect(CountryPlaces.all.map(\.name) == CountryPlaces.all.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        for country in CountryPlaces.all {
            #expect(!country.name.isEmpty)
            #expect(CountryPlaces.nearest(latitude: country.latitude, longitude: country.longitude)?.code == country.code)
        }
    }
}
