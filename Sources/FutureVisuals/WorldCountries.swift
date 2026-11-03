import Foundation

/// A country from Natural Earth's 1:110m map (public domain), as `WorldCountriesData.swift` holds it.
public struct WorldCountry: Sendable, Equatable {
    /// ISO 3166 alpha-3, such as "FRA", or Natural Earth's own code for places without one ("KOS").
    public let code: String
    public let name: String
    /// Where a label goes, in degrees.
    public let labelLatitude: Double
    public let labelLongitude: Double
    /// Natural Earth's estimate, from about 2019.
    public let population: Double
    /// Outer rings, each a list of (longitude, latitude) in degrees.
    public let rings: [[SIMD2<Double>]]
}

/// The countries of the world map (docs/DESIGN.md, 9.6), read once from the table the script
/// `scripts/make-world-countries.py` made. Data a module needs about countries, such as
/// populations, can come from here through the app (DESIGN.md, 6.5).
public enum WorldCountries {
    public static let all: [WorldCountry] = parse(table)

    public static let byCode: [String: WorldCountry] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    /// Reads the table. A line that can't be read is skipped.
    static func parse(_ text: String) -> [WorldCountry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 6, let x = Double(parts[2]), let y = Double(parts[3]), let population = Double(parts[4]) else {
                return nil
            }
            let rings = parts[5].split(separator: ";").map(ring)
            return WorldCountry(code: String(parts[0]), name: String(parts[1]), labelLatitude: y, labelLongitude: x,
                                population: population, rings: rings.filter { $0.count >= 3 })
        }
    }

    /// "255,4656 -12,3": the first point, then each change, in hundredths of a degree.
    private static func ring(_ text: Substring) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        var x = 0, y = 0
        for (offset, pair) in text.split(separator: " ").enumerated() {
            let numbers = pair.split(separator: ",")
            guard numbers.count == 2, let dx = Int(numbers[0]), let dy = Int(numbers[1]) else { continue }
            if offset == 0 { (x, y) = (dx, dy) } else { x += dx; y += dy }
            points.append(SIMD2(Double(x) / 100, Double(y) / 100))
        }
        return points
    }
}

/// The Equal Earth projection (Šavrič, Patterson and Jenny, 2018): the whole world on a flat map,
/// with every country at its true size relative to the others, and shapes close to how they look.
public enum EqualEarth {
    static let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796
    static let m = 3.0.squareRoot() / 2

    /// The projected point, x across and y up, for a longitude and latitude in degrees.
    public static func project(longitude: Double, latitude: Double) -> SIMD2<Double> {
        let lambda = longitude * .pi / 180, phi = latitude * .pi / 180
        let theta = asin(m * sin(phi))
        let t2 = theta * theta, t6 = t2 * t2 * t2
        let x = lambda * cos(theta) / (m * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)))
        let y = theta * (a1 + a2 * t2 + t6 * (a3 + a4 * t2))
        return SIMD2(x, y)
    }

    /// Half the map's width and height: where 180° and the poles land.
    public static let halfWidth = project(longitude: 180, latitude: 0).x
    public static let halfHeight = project(longitude: 0, latitude: 90).y
    /// Width over height, about 2.05.
    public static var aspect: Double { halfWidth / halfHeight }

    /// A point on a map 1 high and `aspect` wide, with y down as screens have it.
    public static func unit(longitude: Double, latitude: Double) -> CGPoint {
        let p = project(longitude: longitude, latitude: latitude)
        return CGPoint(x: (p.x + halfWidth) / (2 * halfHeight), y: (halfHeight - p.y) / (2 * halfHeight))
    }
}
