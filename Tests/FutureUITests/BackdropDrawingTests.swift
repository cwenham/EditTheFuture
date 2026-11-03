import Foundation
import SwiftUI
import Testing
import FutureEngine
import FutureVisuals
@testable import FutureUI

/// The backdrops drawn into images (docs/DESIGN.md, 9.6).
@Suite("Backdrop drawing")
struct BackdropDrawingTests {
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

    /// The backdrop drawn into an image, as RGBA bytes.
    @MainActor
    func render(_ backdrop: any Backdrop, _ input: BackdropInput, size: CGSize) -> (bytes: [UInt8], width: Int)? {
        let view = Canvas { context, size in
            backdrop.drawBase(color: Color(input.color), in: &context, size: size)
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
        let shaded = BackdropInput(field: FieldSample(name: "f", time: .now, keys: ["FRA"], values: [1]), color: RGBA(hex: "#FFFFFF"))
        let plain = BackdropInput(color: RGBA(hex: "#FFFFFF"))
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
                                      label: "Where everyone is", keyLabels: ["susceptible": "Can still catch it"], color: RGBA(hex: "#FF9500"))
            #expect(render(PartsBackdrop(), input, size: CGSize(width: 900, height: 400)) != nil)
        }
        _ = render(PartsBackdrop(), BackdropInput(color: RGBA(hex: "#FF9500")), size: CGSize(width: 900, height: 400))
    }

    @Test("The sky map draws its stars at any size, and a point where it should be")
    @MainActor
    func skyMapDraws() throws {
        let size = CGSize(width: 820, height: 400)
        let input = BackdropInput(point: GeoPoint(latitude: 20, longitude: 300), color: RGBA(hex: "#FFFFFF"))
        let rect = SkyMapBackdrop.mapRect(in: size)
        let unit = Hammer.unit(rightAscension: 300, declination: 20)
        let x = Int(rect.minX + unit.x * rect.height), y = Int(rect.minY + unit.y * rect.height)
        let lit = try #require(render(SkyMapBackdrop(), input, size: size))
        let dark = try #require(render(SkyMapBackdrop(), BackdropInput(color: RGBA(hex: "#FFFFFF")), size: size))
        func red(_ image: (bytes: [UInt8], width: Int)) -> Int { Int(image.bytes[(y * image.width + x) * 4]) }
        #expect(red(lit) > red(dark) + 100)
        for tiny in [CGSize(width: 0, height: 0), CGSize(width: 3, height: 1)] { _ = render(SkyMapBackdrop(), input, size: tiny) }
        // Sirius shows, brighter than empty sky.
        let sirius = Hammer.unit(rightAscension: 101.287, declination: -16.716)
        let sx = Int(rect.minX + sirius.x * rect.height), sy = Int(rect.minY + sirius.y * rect.height)
        #expect(Int(dark.bytes[(sy * dark.width + sx) * 4]) > 40)
    }

    @Test("The sky map's stars are larger and bluer the brighter and hotter they are")
    func skyMapStars() {
        #expect(SkyMapBackdrop.radius(magnitude: -1.46) > SkyMapBackdrop.radius(magnitude: 5.5))
        #expect(SkyMapBackdrop.tint(colorIndex: -0.2).blue > SkyMapBackdrop.tint(colorIndex: 1.6).blue)
        #expect(BackdropDrawings.builtIn.backdrop(id: "sky-map")?.kind.pointNames.map(\.1) == ["rightAscension", "ra"])
    }
}
