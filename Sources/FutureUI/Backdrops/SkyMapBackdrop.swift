import SwiftUI
import FutureVisuals

/// The night sky's brightest stars, faint behind the graph, with a point at a right ascension and
/// declination, such as where a model puts a comet or a planet, or stars brightened by a
/// `sky/stars` field (docs/DESIGN.md, 9.6).
public struct SkyMapBackdrop: Backdrop {
    public let kind = BackdropKind.skyMap

    public init() {}

    /// The map's place in a graph: as large as fits, centred, twice as wide as it's high.
    public static func mapRect(in size: CGSize) -> CGRect {
        let height = max(0, min(size.height * 0.94, size.width / 2 * 0.98))
        return CGRect(x: (size.width - 2 * height) / 2, y: (size.height - height) / 2, width: 2 * height, height: height)
    }

    /// A dot's radius for a magnitude: Sirius about 2.6 points, the faintest about 0.5.
    public static func radius(magnitude: Double) -> CGFloat {
        CGFloat(max(0.5, 2.6 - (magnitude + 1.5) * 0.3))
    }

    /// The tint of a B−V colour index, from blue-white to orange.
    public static func tint(colorIndex: Double?) -> (red: Double, green: Double, blue: Double) {
        guard let index = colorIndex, index.isFinite else { return (1, 1, 1) }
        let t = min(1, max(0, (index + 0.3) / 1.9))
        return (0.75 + 0.25 * min(1, t * 2), 0.82 + 0.1 * (1 - abs(t - 0.4)), 1 - 0.45 * t)
    }

    /// The sky's outline, the celestial equator and the ecliptic, and every star: the same whatever
    /// the cursor shows.
    public func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize) {
        let rect = Self.mapRect(in: size)
        guard rect.width > 2, rect.height > 1 else { return }
        func place(_ ra: Double, _ dec: Double) -> CGPoint {
            let unit = Hammer.unit(rightAscension: ra, declination: dec)
            return CGPoint(x: rect.minX + unit.x * rect.height, y: rect.minY + unit.y * rect.height)
        }
        context.stroke(Path(ellipseIn: rect), with: .style(Theme.ink.opacity(0.10)), lineWidth: 0.5)
        // The celestial equator and the ecliptic, tilted 23.44° to it; each broken where it wraps.
        let tilt = 23.44 * Double.pi / 180
        for line in ["equator", "ecliptic"] {
            var path = Path(), last: CGPoint?
            for step in 0...360 {
                let longitude = Double(step) * .pi / 180
                let ra: Double, dec: Double
                if line == "equator" {
                    (ra, dec) = (Double(step), 0)
                } else {
                    ra = atan2(sin(longitude) * cos(tilt), cos(longitude)) * 180 / .pi
                    dec = asin(sin(tilt) * sin(longitude)) * 180 / .pi
                }
                let point = place(ra, dec)
                if let last, abs(point.x - last.x) < rect.width / 2 { path.addLine(to: point) } else { path.move(to: point) }
                last = point
            }
            context.stroke(path, with: .style(Theme.ink.opacity(line == "ecliptic" ? 0.09 : 0.06)),
                           style: StrokeStyle(lineWidth: 0.6, dash: line == "ecliptic" ? [3, 3] : []))
        }
        let scale = min(1, rect.height / 400)
        for star in BrightStars.all {
            let center = place(star.rightAscension, star.declination)
            let radius = Self.radius(magnitude: star.magnitude) * max(0.6, scale)
            let tint = Self.tint(colorIndex: star.colorIndex)
            // Brighter stars stand out more, but every one stays faint behind the graph.
            let opacity = 0.18 + 0.32 * min(1, max(0, (5.5 - star.magnitude) / 6))
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                         with: .color(Color(red: tint.red, green: tint.green, blue: tint.blue).opacity(opacity)))
        }
    }

    /// Stars brightened by the field, and the point.
    public func draw(_ input: BackdropInput, in context: inout GraphicsContext, size: CGSize) {
        let rect = Self.mapRect(in: size)
        guard rect.width > 2, rect.height > 1 else { return }
        func place(_ ra: Double, _ dec: Double) -> CGPoint {
            let unit = Hammer.unit(rightAscension: ra, declination: dec)
            return CGPoint(x: rect.minX + unit.x * rect.height, y: rect.minY + unit.y * rect.height)
        }
        let shades = input.intensities()
        if !shades.isEmpty {
            for star in BrightStars.all {
                guard let intensity = shades[star.key], intensity >= 0.005 else { continue }
                let center = place(star.rightAscension, star.declination)
                let radius = Self.radius(magnitude: star.magnitude) + 4 * intensity
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(Color(input.color).opacity(0.15 + 0.5 * intensity)))
            }
        }
        if let point = input.point {
            let center = place(point.longitude, point.latitude)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                         with: .color(Color(input.color).opacity(0.18)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(Color(input.color).opacity(0.85)))
        }
    }
}
