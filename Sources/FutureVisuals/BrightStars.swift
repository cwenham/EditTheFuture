import Foundation

/// A star from the Yale Bright Star Catalogue (public domain), as `BrightStarsData.swift` holds it.
public struct BrightStar: Sendable, Equatable {
    /// Harvard Revised number, such as 2491 for Sirius: the key in a `sky/stars` field ("HR 2491").
    public let number: Int
    /// J2000, in degrees.
    public let rightAscension: Double
    public let declination: Double
    /// Visual magnitude: smaller is brighter, Sirius is −1.46.
    public let magnitude: Double
    /// B−V colour index: blue below 0, white about 0.5, orange above 1; nil when unknown.
    public let colorIndex: Double?

    public var key: String { "HR \(number)" }
}

/// The stars of the sky map (docs/DESIGN.md, 9.6), read once from the table the script
/// `scripts/make-bright-stars.py` made: every star brighter than magnitude 5.5.
public enum BrightStars {
    public static let all: [BrightStar] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5, let number = Int(parts[0]), let ra = Double(parts[1]), let dec = Double(parts[2]),
              let magnitude = Double(parts[3]) else { return nil }
        return BrightStar(number: number, rightAscension: ra, declination: dec, magnitude: magnitude, colorIndex: Double(parts[4]))
    }
}

/// The whole sky on the Hammer projection: an oval twice as wide as it's high, with every part at
/// its true size. As on star charts, north is up and right ascension increases to the left, as the
/// sky is seen from Earth, with 0h in the middle.
public enum Hammer {
    static let root2 = 2.0.squareRoot()

    /// A point on a map 1 high and 2 wide, y down, for a right ascension and declination in degrees.
    public static func unit(rightAscension: Double, declination: Double) -> CGPoint {
        var ra = rightAscension.truncatingRemainder(dividingBy: 360)
        if ra > 180 { ra -= 360 } else if ra < -180 { ra += 360 }
        let lambda = -ra * .pi / 180, phi = declination * .pi / 180
        let scale = (1 + cos(phi) * cos(lambda / 2)).squareRoot()
        let x = 2 * root2 * cos(phi) * sin(lambda / 2) / scale
        let y = root2 * sin(phi) / scale
        // x is within ±2√2 and y within ±√2.
        return CGPoint(x: (x + 2 * root2) / (2 * root2), y: (root2 - y) / (2 * root2))
    }
}
