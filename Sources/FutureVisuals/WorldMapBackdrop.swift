import SwiftUI

/// The world on the Equal Earth projection, each country shaded by its value in a
/// `world/countries` field, or a dot at a latitude and longitude (docs/DESIGN.md, 9.6).
public struct WorldMapBackdrop: Backdrop {
    public let id = "world-map"
    public let name = "World map"
    public let geometries: Set<String> = ["world/countries"]
    public let drawsPoints = true

    public init() {}

    /// The map's place in a graph: as large as fits, centred, keeping its shape.
    /// Countries shaded less than this aren't filled.
    static let faintest = 0.005

    public static func mapRect(in size: CGSize) -> CGRect {
        let height = max(0, min(size.height * 0.94, size.width / EqualEarth.aspect * 0.98))
        let width = height * EqualEarth.aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Every country, faint, with its outline: the same whatever the cursor shows.
    public func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize) {
        let rect = Self.mapRect(in: size)
        guard rect.width > 1, rect.height > 1 else { return }
        let world = Self.cache.paths(in: rect).world
        context.fill(world, with: .color(.white.opacity(0.045)))
        context.stroke(world, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 0.5, lineJoin: .round))
    }

    /// Countries shaded by the field, and the point.
    public func draw(_ input: BackdropInput, in context: inout GraphicsContext, size: CGSize) {
        let rect = Self.mapRect(in: size)
        guard rect.width > 1, rect.height > 1 else { return }
        let shades = input.intensities()
        if !shades.isEmpty {
            for country in Self.cache.paths(in: rect).countries {
                // Too faint to see, so not worth a fill: most countries, most of the time.
                guard let intensity = shades[country.code], intensity >= Self.faintest else { continue }
                context.fill(country.path, with: .color(input.color.opacity(0.05 + 0.35 * intensity)))
            }
        }
        if let point = input.point {
            let unit = EqualEarth.unit(longitude: point.longitude, latitude: point.latitude)
            let center = CGPoint(x: rect.minX + unit.x * rect.height, y: rect.minY + unit.y * rect.height)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                         with: .color(input.color.opacity(0.18)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(input.color.opacity(0.85)))
        }
    }

    /// Countries' outlines on a map 1 high, made once.
    static let unitPaths: [(code: String, path: Path)] = WorldCountries.all.map { country in
        var path = Path()
        for ring in country.rings {
            guard let first = ring.first else { continue }
            path.move(to: EqualEarth.unit(longitude: first.x, latitude: first.y))
            for point in ring.dropFirst() { path.addLine(to: EqualEarth.unit(longitude: point.x, latitude: point.y)) }
            path.closeSubpath()
        }
        return (country.code, path)
    }

    static let cache = PathCache()

    /// The outlines at the last size drawn, each country's and all of them as one path, so drawing
    /// again at that size only fills them.
    final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var rect: CGRect?
        private var countries: [(code: String, path: Path)] = []
        private var world = Path()

        func paths(in rect: CGRect) -> (countries: [(code: String, path: Path)], world: Path) {
            lock.lock()
            defer { lock.unlock() }
            if self.rect != rect {
                let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.height, y: rect.height)
                countries = WorldMapBackdrop.unitPaths.map { ($0.code, $0.path.applying(transform)) }
                var world = Path()
                for country in countries { world.addPath(country.path) }
                self.world = world
                self.rect = rect
            }
            return (countries, world)
        }
    }
}
