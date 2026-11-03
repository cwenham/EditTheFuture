import Foundation
import FutureVisuals

// Places in the Slot tab (docs/UI.md, 5.7): a latitude and longitude a model takes, typed or pasted
// as text rather than slid, with a menu of countries that fills in both.

extension SlotValue {
    /// Half of a place: which coordinate a value is, and the name of the other half.
    public struct Coordinate: Sendable, Equatable {
        public enum Axis: Sendable, Equatable {
            case latitude, longitude
        }

        public let axis: Axis
        public let partner: String
    }

    /// The same values with each latitude and longitude pair marked. A pair is two of them whose
    /// names end in "latitude" and "longitude" (or "lat" and "lon", "lng" or "long") after the same
    /// start, in any case: `originLatitude` and `originLongitude`, or `lat` and `lon`.
    static func markingPlaces(_ values: [SlotValue]) -> [SlotValue] {
        var marked = values
        let lowered = values.map { $0.name.lowercased() }
        for (index, name) in lowered.enumerated() {
            for (lat, lons) in [("latitude", ["longitude"]), ("lat", ["lon", "lng", "long"])] where name.hasSuffix(lat) {
                let start = name.dropLast(lat.count)
                guard let partner = lons.lazy.compactMap({ lon in lowered.firstIndex(of: start + lon) }).first,
                      marked[index].coordinate == nil, marked[partner].coordinate == nil else { continue }
                marked[index].coordinate = Coordinate(axis: .latitude, partner: values[partner].name)
                marked[partner].coordinate = Coordinate(axis: .longitude, partner: values[index].name)
            }
        }
        return marked
    }
}

/// Reading and writing coordinates as people paste them: "51.5074, -0.1278", "51.5074° N, 0.1278° W",
/// "51°30′26″N 0°7′39″W" or "N 51.5 W 0.13".
public enum GeoText {
    /// One coordinate, signed decimal degrees, with up to four decimals: "51.5074", "−0.1278".
    public static func text(_ degrees: Double) -> String {
        if !degrees.isFinite { return SlotValue.number(degrees) }
        var text = String(format: "%.4f", abs(degrees))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (degrees < 0 && text != "0" ? "−" : "") + text
    }

    /// What was typed or pasted into a field for `axis`: one coordinate, or a latitude and
    /// longitude together. nil when it isn't coordinates.
    public static func parse(_ text: String, for axis: SlotValue.Coordinate.Axis) -> Reading? {
        let parts = components(text)
        switch parts.count {
        case 1:
            let part = parts[0]
            if let named = part.axis, named != axis { return nil }
            guard let degrees = part.degrees(on: axis) else { return nil }
            return .one(degrees)
        case 2:
            var (first, second) = (parts[0], parts[1])
            // Letters say which is which: "0.1278° W, 51.5074° N". Without them, latitude comes first.
            if first.axis == .longitude || second.axis == .latitude { swap(&first, &second) }
            guard first.axis != .longitude, second.axis != .latitude,
                  let latitude = first.degrees(on: .latitude), let longitude = second.degrees(on: .longitude) else { return nil }
            return .both(latitude: latitude, longitude: longitude)
        default:
            return nil
        }
    }

    public enum Reading: Equatable {
        case one(Double)
        case both(latitude: Double, longitude: Double)
    }

    /// The largest each coordinate can be.
    static func limit(_ axis: SlotValue.Coordinate.Axis) -> Double { axis == .latitude ? 90 : 180 }

    /// A coordinate as written: a signed number of degrees, perhaps with minutes and seconds, and
    /// perhaps a hemisphere letter before or after.
    private struct Part {
        var degrees: Double
        var negative: Bool
        var hemisphere: Character?

        var axis: SlotValue.Coordinate.Axis? {
            switch hemisphere {
            case "N", "S": .latitude
            case "E", "W": .longitude
            default: nil
            }
        }

        func degrees(on axis: SlotValue.Coordinate.Axis) -> Double? {
            var value = negative ? -degrees : degrees
            if hemisphere == "S" || hemisphere == "W" { value = -abs(value) }
            guard value.isFinite, abs(value) <= GeoText.limit(axis) else { return nil }
            return value
        }
    }

    private static func components(_ text: String) -> [Part] {
        // Minus signs and primes come in several forms; make them one each.
        var cleaned = text.uppercased()
        for (from, to) in [("−", "-"), ("–", "-"), ("º", "°"), ("′", "'"), ("’", "'"), ("″", "\""), ("”", "\""), ("''", "\"")] {
            cleaned = cleaned.replacingOccurrences(of: from, with: to)
        }
        // "51,5" on its own is a decimal comma, not two numbers.
        if cleaned.wholeMatch(of: #/\s*[+-]?\d+,\d+\s*/#) != nil { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
        let number = #/([+-])?\s*(\d+(?:\.\d+)?)\s*°?\s*(?:(\d+(?:\.\d+)?)\s*')?\s*(?:(\d+(?:\.\d+)?)\s*")?/#
        let matches = cleaned.matches(of: number)
        guard !matches.isEmpty else { return [] }
        // Between the numbers there may be separators and a hemisphere letter, and nothing else.
        var gaps: [Character?] = []
        var from = cleaned.startIndex
        for range in matches.map(\.range) + [cleaned.endIndex..<cleaned.endIndex] {
            let gap = cleaned[from..<range.lowerBound].filter { !",;/ \t\n".contains($0) }
            guard gap.count <= 1, gap.allSatisfy({ "NSEW".contains($0) }) else { return [] }
            gaps.append(gap.first)
            from = range.upperBound
        }
        // Letters come before the numbers when the text starts with one ("N 51.5 W 0.13"), else after.
        let before = gaps[0] != nil
        if before && gaps[gaps.count - 1] != nil { return [] }
        var parts: [Part] = []
        for (index, match) in matches.enumerated() {
            let output = match.output
            guard let whole = Double(output.2) else { return [] }
            let minutes = output.3.flatMap { Double($0) } ?? 0
            let seconds = output.4.flatMap { Double($0) } ?? 0
            guard minutes < 60, seconds < 60 else { return [] }
            parts.append(Part(degrees: whole + minutes / 60 + seconds / 3_600, negative: output.1 == "-",
                              hemisphere: before ? gaps[index] : gaps[index + 1]))
        }
        return parts
    }
}

/// The countries the Slot tab's place menu offers: those with people in them, by name, with the
/// point where the world map puts each one's name, which is also where World epidemic measures
/// distances from (`AppModuleData.countries`).
public enum CountryPlaces {
    public struct Country: Identifiable, Sendable, Equatable {
        public var id: String { code }
        public let code: String
        public let name: String
        public let latitude: Double
        public let longitude: Double
    }

    public static let all: [Country] = WorldCountries.all
        .filter { $0.population > 0 }
        .map { Country(code: $0.code, name: $0.name, latitude: $0.labelLatitude, longitude: $0.labelLongitude) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// The country whose point is nearest, along the ground, as World epidemic picks where it starts.
    public static func nearest(latitude: Double, longitude: Double) -> Country? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        return all.min { distance(latitude, longitude, $0) < distance(latitude, longitude, $1) }
    }

    private static func distance(_ latitude: Double, _ longitude: Double, _ country: Country) -> Double {
        let radians = Double.pi / 180
        let (φ1, φ2) = (latitude * radians, country.latitude * radians)
        let Δφ = φ2 - φ1, Δλ = (country.longitude - longitude) * radians
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

extension ScenarioStore {
    /// Sets several of a slot's parameters or starting values as one change, which one undo takes back:
    /// a place's latitude and longitude.
    public func setStartingValues(_ values: [String: Double], inSlotAt index: Int) {
        guard isSlot(index) else { return }
        guard values.values.allSatisfy(\.isFinite) else {
            say("That value is too big to use.", isError: true)
            return
        }
        var config = configs[index]
        for (name, value) in values { config.values[name] = value }
        guard config != configs[index] else { return }
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }
}
