import Foundation
import FutureEngine

/// How a slot's values are shown.
public enum ValueFormat: String, Sendable, Codable, Hashable {
    case currency
    case temperature
    case number
    /// A fraction shown as a percent: 0.045 is "4.5%".
    case percent

    /// Full value for readouts and lanes, e.g. "$41,223" or "14.2 °C". Values too big to write
    /// out are shown as "$1.23e18"; values that overflowed as "∞".
    public func full(_ value: Double) -> String {
        if value.isNaN { return "—" }
        let sign = value < 0 ? "−" : ""
        let magnitude = abs(value)
        switch self {
        case .currency:
            guard magnitude < Self.writtenOutLimit else { return sign + "$" + Self.scientific(magnitude) }
            return sign + "$" + Self.grouped(magnitude.rounded())
        case .temperature:
            guard magnitude < Self.writtenOutLimit else { return sign + Self.scientific(magnitude) + " °C" }
            return String(format: "%.1f °C", value)
        case .number:
            guard magnitude < Self.writtenOutLimit else { return sign + Self.scientific(magnitude) }
            return magnitude >= 100 ? Self.grouped(value.rounded()) : String(format: "%.2f", value)
        case .percent:
            let percent = magnitude * 100
            guard percent < Self.writtenOutLimit else { return sign + Self.scientific(percent) + "%" }
            return sign + (percent >= 100 ? Self.grouped(percent.rounded()) : String(format: "%.1f", percent)) + "%"
        }
    }

    /// Short value for axes, e.g. "$100k", "$1.25M", "$3B", "15°", "$2.5e18".
    public func axis(_ value: Double) -> String {
        switch self {
        case .currency:
            let sign = value < 0 ? "−" : ""
            let magnitude = abs(value)
            if magnitude == 0 { return "$0" }
            if magnitude >= Self.writtenOutLimit { return sign + "$" + Self.trimmed(magnitude) }
            if magnitude >= 1e12 { return sign + "$" + Self.trimmed(magnitude / 1e12) + "T" }
            if magnitude >= 1e9 { return sign + "$" + Self.trimmed(magnitude / 1e9) + "B" }
            if magnitude >= 1e6 { return sign + "$" + Self.trimmed(magnitude / 1e6) + "M" }
            if magnitude >= 1e3 { return sign + "$" + Self.trimmed(magnitude / 1e3) + "k" }
            return sign + "$" + Self.trimmed(magnitude)
        case .temperature:
            return Self.trimmed(value) + "°"
        case .number:
            return Self.trimmed(value)
        case .percent:
            return Self.trimmed(value * 100) + "%"
        }
    }

    /// "41223" → "41,223". Written out by hand: creating a NumberFormatter per label was a
    /// measurable part of each frame.
    static func grouped(_ value: Double) -> String {
        guard value.isFinite, abs(value) < writtenOutLimit else { return String(value) }
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

    /// Numbers at or above this are shown in scientific notation: written out, they'd be too long
    /// to read, and past Int.max (about 9.2e18) they can't become whole numbers at all.
    static let writtenOutLimit = 1e15

    /// "2", "2.5", "−0.25", "1e18", "∞".
    static func trimmed(_ value: Double) -> String {
        if value.isNaN { return "—" }
        if abs(value) >= writtenOutLimit { return (value < 0 ? "−" : "") + scientific(abs(value)) }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%g", rounded)
    }

    /// "1.23e18" for a positive value, "∞" for infinity.
    static func scientific(_ value: Double) -> String {
        if value == .infinity { return "∞" }
        return String(format: "%.3g", value).replacingOccurrences(of: "e+", with: "e")
    }
}

/// Evenly spaced "nice" axis values (steps of 1, 2, 2.5 or 5 × 10ⁿ) covering `low...high`.
///
/// Copes with any input: values beyond ±1e300 are clamped (so the range and its steps stay finite),
/// NaN counts as 0, and a range too narrow for its magnitude is widened instead of producing
/// ticks that round to the same number.
public func niceTicks(low: Double, high: Double, target: Int = 5, includeZero: Bool = false) -> (domain: ClosedRange<Double>, ticks: [Double]) {
    let limit = 1e300
    func clamp(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, -limit), limit) }
    let a = clamp(low), b = clamp(high)
    var low = min(a, b), high = max(a, b)
    if includeZero { low = min(low, 0); high = max(high, 0) }
    let magnitudeOfValues = max(abs(low), abs(high))
    if !(high - low > magnitudeOfValues * 1e-9) {
        let pad = max(magnitudeOfValues * 0.1, 1)
        low -= pad
        high += pad
    }
    let raw = (high - low) / Double(max(target, 1))
    let magnitude = pow(10, floor(log10(raw)))
    let normalized = raw / magnitude
    let step = (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10) * magnitude
    let start = floor(low / step) * step
    let end = ceil(high / step) * step
    guard step.isFinite, step > 0, start.isFinite, end.isFinite, start < end else { return (0...1, [0, 1]) }
    let count = min(Int(((end - start) / step).rounded()), 100)
    let ticks = (0...count).map { index -> Double in
        let value = start + Double(index) * step
        return abs(value) < step / 1e6 ? 0 : value
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
