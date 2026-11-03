import Foundation
import Testing
import FutureEngine
@testable import FutureVisuals

@Suite("Backdrops")
struct BackdropTests {
    @Test("The country table reads whole: every country once, with outlines on the globe")
    func countries() {
        let all = WorldCountries.all
        #expect(all.count == 177)
        #expect(Set(all.map(\.code)).count == all.count)
        #expect(all.allSatisfy { $0.code.count == 3 && $0.code == $0.code.uppercased() })
        for code in ["FRA", "NOR", "GBR", "USA", "CHN", "BRA", "AUS", "KOS", "ATA"] {
            #expect(WorldCountries.byCode[code] != nil, "\(code)")
        }
        #expect(WorldCountries.byCode["FRA"]?.name == "France")
        #expect(WorldCountries.byCode["IND"].map { $0.population > 1e9 } == true)
        let points = all.flatMap { $0.rings.flatMap { $0 } }
        #expect(points.count > 10_000)
        #expect(points.allSatisfy { abs($0.x) <= 180 && abs($0.y) <= 90 })
        // France's label is in France.
        let france = WorldCountries.byCode["FRA"]!
        #expect(abs(france.labelLatitude - 46.7) < 1 && abs(france.labelLongitude - 2.5) < 1)
    }

    @Test("Equal Earth puts the world on a map about twice as wide as it is high")
    func projection() {
        #expect(abs(EqualEarth.aspect - 2.0546) < 0.001)
        #expect(EqualEarth.project(longitude: 0, latitude: 0) == SIMD2(0, 0))
        let center = EqualEarth.unit(longitude: 0, latitude: 0)
        #expect(abs(center.x - EqualEarth.aspect / 2) < 1e-9 && abs(center.y - 0.5) < 1e-9)
        let corner = EqualEarth.unit(longitude: -180, latitude: 0)
        #expect(abs(corner.x) < 1e-9)
        #expect(abs(EqualEarth.unit(longitude: 0, latitude: 90).y) < 1e-9)
        // North is up, east is right.
        let paris = EqualEarth.unit(longitude: 2.35, latitude: 48.86), sydney = EqualEarth.unit(longitude: 151.2, latitude: -33.9)
        #expect(paris.y < sydney.y && paris.x < sydney.x)
    }

    @Test("Shading: percents as they are, other values against the largest, and what isn't finite left out")
    func intensities() {
        let shares = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [0.2, 0.9]),
                                   quantity: .percent, color: RGBA(hex: "#0000FF"))
        #expect(shares.intensities() == ["A": 0.2, "B": 0.9])
        let small = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [0.001, 0.004]), color: RGBA(hex: "#0000FF"))
        #expect(small.intensities() == ["A": 0.25, "B": 1])
        let counts = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B", "C"], values: [50, 200, .nan]), color: RGBA(hex: "#0000FF"))
        #expect(counts.intensities() == ["A": 0.25, "B": 1])
        let percent = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A"], values: [1.5]), quantity: .percent, color: RGBA(hex: "#0000FF"))
        #expect(percent.intensities() == ["A": 1])
        let huge = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [.infinity, 3]), color: RGBA(hex: "#0000FF"))
        #expect(huge.intensities() == ["B": 1])
        #expect(BackdropInput(color: RGBA(hex: "#0000FF")).intensities().isEmpty)
        // Logarithmic: a millionth is nothing, a thousandth is half way, a tenth and more are full.
        let log = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B", "C", "D"], values: [1e-6, 1e-3, 0.1, 0.5]),
                                scale: .logarithmic(faintest: 1e-6, full: 0.1), color: RGBA(hex: "#0000FF"))
        let shaded = log.intensities()
        #expect(shaded["A"] == 0 && shaded["C"] == 1 && shaded["D"] == 1)
        #expect(abs(shaded["B"]! - 0.6) < 1e-9)
        // A relative scale on percents, when the field asks for it.
        let relative = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [0.1, 0.4]),
                                     quantity: .percent, scale: .relative, color: RGBA(hex: "#0000FF"))
        #expect(relative.intensities() == ["A": 0.25, "B": 1])
    }

    @Test("Points must be on the globe; longitudes wrap round")
    func points() {
        #expect(GeoPoint.valid(latitude: 51.5, longitude: -0.1) == GeoPoint(latitude: 51.5, longitude: -0.1))
        #expect(GeoPoint.valid(latitude: 10, longitude: 190) == GeoPoint(latitude: 10, longitude: -170))
        #expect(GeoPoint.valid(latitude: 91, longitude: 0) == nil)
        #expect(GeoPoint.valid(latitude: .nan, longitude: 0) == nil)
        #expect(GeoPoint.valid(latitude: nil, longitude: 0) == nil)
    }

    @Test("The catalog finds backdrops by id and by the geometry they draw")
    func catalog() {
        let catalog = BackdropCatalog.builtIn
        #expect(catalog.backdrop(id: "world-map")?.name == "World map")
        #expect(catalog.drawing(geometry: "groups").map(\.id) == ["parts"])
        #expect(catalog.drawing(geometry: "world/countries").map(\.id) == ["world-map"])
        #expect(catalog.backdrop(id: "world-map")?.drawsPoints == true)
        #expect(catalog.backdrop(id: "parts")?.drawsPoints == false)
    }

    @Test("The star table reads whole: the bright stars, brightest first, on the sky")
    func stars() {
        let stars = BrightStars.all
        #expect(stars.count == 2887)
        #expect(stars.first?.number == 2491)
        #expect(stars.first.map { abs($0.magnitude + 1.46) < 0.01 } == true)
        #expect(Set(stars.map(\.number)).count == stars.count)
        #expect(stars.allSatisfy { $0.rightAscension >= 0 && $0.rightAscension < 360 && abs($0.declination) <= 90 && $0.magnitude <= 5.5 })
        #expect(zip(stars, stars.dropFirst()).allSatisfy { $0.magnitude <= $1.magnitude })
        let polaris = stars.first { $0.number == 424 }
        #expect(polaris.map { $0.declination > 89 } == true)
        #expect(polaris?.key == "HR 424")
    }

    @Test("The Hammer projection: an oval twice as wide as high, 0h in the middle, east to the left, north up")
    func hammer() {
        let middle = Hammer.unit(rightAscension: 0, declination: 0)
        #expect(abs(middle.x - 1) < 1e-9 && abs(middle.y - 0.5) < 1e-9)
        #expect(Hammer.unit(rightAscension: 90, declination: 0).x < 1)
        #expect(Hammer.unit(rightAscension: 270, declination: 0).x > 1)
        #expect(abs(Hammer.unit(rightAscension: 123, declination: 90).y) < 1e-9)
        for ra in stride(from: 0.0, through: 360, by: 15) {
            for dec in stride(from: -90.0, through: 90, by: 15) {
                let p = Hammer.unit(rightAscension: ra, declination: dec)
                #expect(p.x >= -1e-9 && p.x <= 2 + 1e-9 && p.y >= -1e-9 && p.y <= 1 + 1e-9)
            }
        }
        #expect(BackdropCatalog.builtIn.drawing(geometry: "sky/stars").map(\.id) == ["sky-map"])
        #expect(BackdropKind.skyMap.pointNames.map(\.1) == ["rightAscension", "ra"])
    }

}
