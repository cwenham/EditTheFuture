import Foundation
import FutureEngine

/// A feed: readings fetched from a public source, such as FRED or the US Treasury, and kept in a
/// copy in `readings/` (docs/DESIGN.md, 15.8). In `scenario.md` it's a line under `### Readings`:
///
/// ```
/// - 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent]
/// ```
///
/// Keys and passwords are never written here. They're kept in the Keychain (`FutureFeeds`).
public struct FeedSpec: Sendable, Hashable {
    /// Says where the readings come from, as the line's text.
    public var title: String
    /// The source, as `feed:` names it: `fred`, `treasury`, `worldbank`…
    public var provider: String
    /// The other settings, in the order they're written. Values are text, as written.
    public var settings: [FeedSetting]

    public init(title: String, provider: String, settings: [FeedSetting] = []) {
        self.title = title
        self.provider = provider
        self.settings = settings
    }

    /// A setting's value. Setting nil removes it; setting a new one adds it at the end.
    public subscript(key: String) -> String? {
        get { settings.first { $0.key == key }?.value }
        set {
            if let index = settings.firstIndex(where: { $0.key == key }) {
                if let newValue { settings[index].value = newValue } else { settings.remove(at: index) }
            } else if let newValue {
                settings.append(FeedSetting(key, newValue))
            }
        }
    }

    /// Settings about how the readings are used, rather than what's fetched. Changing them
    /// doesn't fetch again.
    public static let usageKeys: Set<String> = ["into", "convert", "scale", "every", "credential"]

    /// The settings that say what's fetched.
    public var query: [FeedSetting] { settings.filter { !Self.usageKeys.contains($0.key) } }

    /// The slot's variable the readings are of. Without it, the variable the slot's graph shows.
    public var variable: String? { self["into"] }

    /// How often to check for new readings: `every: 1 day`. nil for the source's own default.
    public var refresh: StepRate? { self["every"].flatMap(StepRate.init(text:)) }

    /// The saved sign-in to use, when it isn't the source's own (`FutureFeeds`).
    public var credentialName: String? { self["credential"] }

    /// The earliest reading to fetch: `from: 1990-01-01`.
    public var start: Date? { self["from"].flatMap { FileDate.parse($0) } }

    public var conversion: FeedConversion? { self["convert"].flatMap(FeedConversion.init(rawValue:)) }

    /// A plain multiplier, applied after `convert`.
    public var scale: Double { self["scale"].flatMap { FileNumber.parse($0, commas: false) } ?? 1 }

    /// A value from the source as the slot's variable takes it.
    public func value(_ raw: Double) -> Double {
        (conversion?.apply(raw) ?? raw) * scale
    }

    /// Identifies what's fetched: the source and the settings that pick its readings.
    public var identity: String {
        ([provider] + query.map { "\($0.key)=\($0.value)" }).joined(separator: "\u{1}")
    }

    /// Where the fetched readings are kept: `readings/Rates-fred-DGS10.csv`. They're kept as the
    /// source gives them, before `convert` and `scale`, so changing those needs no new fetch.
    public func copyPath(slot: String) -> String {
        var slug = ([provider] + query.map(\.value)).joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        var cleaned = ""
        var previousDash = false
        for scalar in slug.unicodeScalars {
            if scalar.isASCII && allowed.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash {
                cleaned.append("-")
                previousDash = true
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Two queries could clean up to the same name, so a name that lost anything gets a short hash.
        if cleaned != slug || cleaned.count > 48 {
            var hash = Fingerprint()
            hash.add(identity)
            let kept = String(cleaned.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            cleaned = kept + "-" + hash.finish().prefix(8)
        }
        slug = cleaned
        return "readings/\(slot)-\(slug).csv"
    }

    // MARK: The line in scenario.md

    /// `10-year Treasury yield [feed: fred, series: DGS10, into: rate]`, without the list marker.
    public var line: String {
        let all = [Setting(key: "feed", value: provider)] + settings.map { Setting(key: $0.key, value: $0.value) }
        let title = self.title.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? provider : title) + " [" + all.map(\.text).joined(separator: ", ") + "]"
    }

    /// Reads a feed's line, without its list marker. nil when it isn't a feed: its last brackets
    /// have no `feed:` setting.
    public static func parse(line: String) throws -> FeedSpec? {
        guard let (label, settings) = Setting.split(line) else {
            guard line.contains("feed:") else { return nil }
            throw FeedLineError("The brackets don't close.")
        }
        guard let feed = settings.first(where: { $0.key == "feed" }) else { return nil }
        guard let provider = feed.value?.trimmingCharacters(in: .whitespaces), !provider.isEmpty else {
            throw FeedLineError("feed: names the source, like feed: fred.")
        }
        var rest: [FeedSetting] = []
        for setting in settings where setting.key != "feed" {
            guard let value = setting.value else {
                throw FeedLineError("“\(setting.key)” needs a value, like series: DGS10.")
            }
            rest.append(FeedSetting(setting.key, value))
        }
        let spec = FeedSpec(title: label, provider: provider.lowercased(), settings: rest)
        if let every = spec["every"], StepRate(text: every) == nil {
            throw FeedLineError("“\(every)” isn't a time step. Write every: 1 day.")
        }
        if let from = spec["from"], FileDate.parse(from) == nil {
            throw FeedLineError("“\(from)” isn't a date. Write from: 1990-01-01.")
        }
        if let convert = spec["convert"], FeedConversion(rawValue: convert) == nil {
            let names = FeedConversion.allCases.map(\.rawValue).joined(separator: " or ")
            throw FeedLineError("convert: is \(names), not “\(convert)”.")
        }
        if let scale = spec["scale"], FileNumber.parse(scale, commas: false) == nil {
            throw FeedLineError("“\(scale)” isn't a number. Write scale: 1000.")
        }
        if let into = spec["into"], !isIdentifier(into) {
            throw FeedLineError("“\(into)” isn't a variable's name.")
        }
        return spec
    }
}

/// One `name: value` setting of a feed.
public struct FeedSetting: Sendable, Hashable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// Units a source gives that the slot takes differently.
public enum FeedConversion: String, Sendable, CaseIterable {
    /// The source gives percent points (4.5), and the slot takes a fraction (0.045).
    case percent
    /// The source gives °F, and the slot takes °C.
    case fahrenheit

    public func apply(_ value: Double) -> Double {
        switch self {
        case .percent:
            // 4.98 becomes 0.0498 as if it were typed, not 0.049800000000000004 as dividing gives.
            guard value.isFinite else { return value / 100 }
            // Two less on the exponent of the shortest text that reads back as the value.
            let parts = "\(value)".split(separator: "e")
            let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            return Double(parts[0] + "e" + String(exponent - 2)) ?? value / 100
        case .fahrenheit:
            return (value - 32) * 5 / 9
        }
    }

    public var title: String {
        switch self {
        case .percent: return "Percent points to a fraction (4.5 → 4.5%)"
        case .fahrenheit: return "°F to °C"
        }
    }
}

struct FeedLineError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: The copy in readings/

/// One reading from a feed, as the source gives it.
public struct FeedPoint: Sendable, Hashable {
    public var time: Date
    public var value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

/// A feed's readings as kept in `readings/`: CSV with a `date` and a `value` column.
public enum FeedCopy {
    public static func text(_ points: [FeedPoint]) -> String {
        // A copy with no readings yet still names its columns.
        guard !points.isEmpty else { return "date,value\n" }
        return CSVReadings.text(points.map { Reading(time: $0.time, variable: "value", value: $0.value) })
    }

    public static func parse(_ text: String) throws -> [FeedPoint] {
        try CSVReadings.parse(text).filter { $0.variable == "value" }.map { FeedPoint(time: $0.time, value: $0.value) }
            .sorted { $0.time < $1.time }
    }

    /// New readings in place of the old ones from the first new reading on. Older readings stay,
    /// so a fetch of recent readings keeps the history, and revised readings replace the old ones.
    public static func merge(_ old: [FeedPoint], with new: [FeedPoint]) -> [FeedPoint] {
        let fresh = cleaned(new)
        guard let first = fresh.first?.time else { return old }
        return old.filter { $0.time < first } + fresh
    }

    /// In time order, one reading per time (the last given), without NaN.
    public static func cleaned(_ points: [FeedPoint]) -> [FeedPoint] {
        var byTime: [Date: Double] = [:]
        for point in points where !point.value.isNaN { byTime[point.time] = point.value }
        return byTime.keys.sorted().map { FeedPoint(time: $0, value: byTime[$0]!) }
    }
}
