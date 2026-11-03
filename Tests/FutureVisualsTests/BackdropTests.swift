import Foundation
import SwiftUI
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

    @Test("Shading: shares as they are, other values against the largest, and what isn't finite left out")
    func intensities() {
        let shares = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [0.2, 0.9]), color: .blue)
        #expect(shares.intensities() == ["A": 0.2, "B": 0.9])
        let counts = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B", "C"], values: [50, 200, .nan]), color: .blue)
        #expect(counts.intensities() == ["A": 0.25, "B": 1])
        let percent = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A"], values: [1.5]), quantity: .percent, color: .blue)
        #expect(percent.intensities() == ["A": 1])
        let huge = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["A", "B"], values: [.infinity, 3]), color: .blue)
        #expect(huge.intensities() == ["B": 1])
        #expect(BackdropInput(color: .blue).intensities().isEmpty)
    }

    @Test("Points must be on the globe; longitudes wrap round")
    func points() {
        #expect(GeoPoint.valid(latitude: 51.5, longitude: -0.1) == GeoPoint(latitude: 51.5, longitude: -0.1))
        #expect(GeoPoint.valid(latitude: 10, longitude: 190) == GeoPoint(latitude: 10, longitude: -170))
        #expect(GeoPoint.valid(latitude: 91, longitude: 0) == nil)
        #expect(GeoPoint.valid(latitude: .nan, longitude: 0) == nil)
        #expect(GeoPoint.valid(latitude: nil, longitude: 0) == nil)
    }

    @Test("Parts of a whole: shares of the total, written briefly")
    func parts() {
        #expect(PartsBackdrop.shares([1, 3]) == [0.25, 0.75])
        #expect(PartsBackdrop.shares([-1, .nan, 2]) == [0, 0, 1])
        #expect(PartsBackdrop.shares([0, 0]) == [0, 0])
        #expect(PartsBackdrop.percent(0.123) == "12.3%")
        #expect(PartsBackdrop.percent(0.5) == "50%")
        #expect(PartsBackdrop.percent(0.0004) == "<0.1%")
        #expect(PartsBackdrop.percent(0) == "0%")
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

    /// The backdrop drawn into an image, as RGBA bytes.
    @MainActor
    func render(_ backdrop: any Backdrop, _ input: BackdropInput, size: CGSize) -> (bytes: [UInt8], width: Int)? {
        let view = Canvas { context, size in
            backdrop.drawBase(color: input.color, in: &context, size: size)
            backdrop.draw(input, in: &context, size: size)
        }
            .frame(width: size.width, height: size.height)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data as Data? else { return nil }
        // Copy into a known layout.
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        _ = data
        return (bytes, width)
    }

    @Test("The world map shades a country where it is, and draws at any size")
    @MainActor
    func worldMapDraws() throws {
        let size = CGSize(width: 820, height: 400)
        let france = WorldCountries.byCode["FRA"]!
        let shaded = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["FRA"], values: [1]), color: .white)
        let plain = BackdropInput(color: .white)
        let rect = WorldMapBackdrop.mapRect(in: size)
        let unit = EqualEarth.unit(longitude: france.labelLongitude, latitude: france.labelLatitude)
        let x = Int(rect.minX + unit.x * rect.height), y = Int(rect.minY + unit.y * rect.height)
        let lit = try #require(render(WorldMapBackdrop(), shaded, size: size))
        let dim = try #require(render(WorldMapBackdrop(), plain, size: size))
        func red(_ image: (bytes: [UInt8], width: Int)) -> Int { Int(image.bytes[(y * image.width + x) * 4]) }
        #expect(red(lit) > red(dim) + 60, "France at (\(x), \(y)): \(red(lit)) against \(red(dim))")
        // Tiny and empty sizes draw nothing, and don't fail.
        for tiny in [CGSize(width: 0, height: 0), CGSize(width: 3, height: 1)] {
            _ = render(WorldMapBackdrop(), shaded, size: tiny)
        }
    }

    @Test("Parts of a whole draws with any field, including empty and odd ones")
    @MainActor
    func partsDraws() {
        let keys = ["susceptible", "exposed", "infectious", "recovered", "vaccinated"]
        for values in [[0.5, 0.1, 0.1, 0.2, 0.1], [0, 0, 0, 0, 0], [.nan, .infinity, -1, 1, 0]] {
            let input = BackdropInput(field: FieldSample(name: "groups", time: .now, keys: keys, values: values),
                                      label: "Where everyone is", keyLabels: ["susceptible": "Can still catch it"], color: .orange)
            #expect(render(PartsBackdrop(), input, size: CGSize(width: 900, height: 400)) != nil)
        }
        _ = render(PartsBackdrop(), BackdropInput(color: .orange), size: CGSize(width: 900, height: 400))
    }
}
