import Foundation
import FutureEngine

/// How a slot's values are shown.
public enum ValueFormat: String, Sendable, Codable, Hashable {
    case currency
    case temperature
    case number

    /// Full value for readouts and lanes, e.g. "$41,223" or "14.2 °C".
    public func full(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch self {
        case .currency:
            return (value < 0 ? "−$" : "$") + Self.grouped(abs(value).rounded())
        case .temperature:
            return String(format: "%.1f °C", value)
        case .number:
            return abs(value) >= 100 ? Self.grouped(value.rounded()) : String(format: "%.2f", value)
        }
    }

    /// Short value for axes, e.g. "$100k", "$1.25M", "15°".
    public func axis(_ value: Double) -> String {
        switch self {
        case .currency:
            let sign = value < 0 ? "−" : ""
            let magnitude = abs(value)
            if magnitude == 0 { return "$0" }
            if magnitude >= 1_000_000 { return sign + "$" + Self.trimmed(magnitude / 1_000_000) + "M" }
            if magnitude >= 1_000 { return sign + "$" + Self.trimmed(magnitude / 1_000) + "k" }
            return sign + "$" + Self.trimmed(magnitude)
        case .temperature:
            return Self.trimmed(value) + "°"
        case .number:
            return Self.trimmed(value)
        }
    }

    /// "41223" → "41,223". Written out by hand: creating a NumberFormatter per label was a
    /// measurable part of each frame.
    static func grouped(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 9e15 else { return String(value) }
        let integer = Int(value.rounded())
        let digits = String(abs(integer))
        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3 + 1)
        for (offset, digit) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return integer < 0 ? "-" + result : result
    }

    static func trimmed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%g", rounded)
    }
}

/// Evenly spaced "nice" axis values (steps of 1, 2, 2.5 or 5 × 10ⁿ) covering `low...high`.
public func niceTicks(low: Double, high: Double, target: Int = 5, includeZero: Bool = false) -> (domain: ClosedRange<Double>, ticks: [Double]) {
    var low = low, high = high
    if includeZero { low = min(low, 0); high = max(high, 0) }
    if !(high > low) {
        let pad = max(abs(low) * 0.1, 1)
        low -= pad
        high += pad
    }
    let raw = (high - low) / Double(max(target, 1))
    let magnitude = pow(10, floor(log10(raw)))
    let normalized = raw / magnitude
    let step = (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10) * magnitude
    let start = floor(low / step) * step
    let end = ceil(high / step) * step
    var ticks: [Double] = []
    var value = start
    while value <= end + step / 2 {
        ticks.append(abs(value) < step / 1e6 ? 0 : value)
        value += step
    }
    return (start...end, ticks)
}

enum DateText {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Mar 2031" in UTC. Built directly: a DateFormatter per call cost tens of microseconds,
    /// and labels are drawn many times per frame.
    static func monthYear(_ date: Date) -> String {
        let civil = CivilDate(date)
        return monthNames[civil.month - 1] + " " + String(civil.year)
    }

    /// "2031-03-15" in UTC.
    static func iso(_ date: Date) -> String {
        let civil = CivilDate(date)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    static func year(_ date: Date) -> Int {
        CivilDate(date).year
    }

    static func startOfYear(_ year: Int) -> Date {
        CivilDate.date(year: year, month: 1, day: 1)
    }

    static func startOfMonth(_ date: Date) -> Date {
        let civil = CivilDate(date)
        return CivilDate.date(year: civil.year, month: civil.month, day: 1)
    }
}
