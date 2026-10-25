import Foundation
import FutureEngine
import FutureFormula

/// One slot as the store keeps it: everything needed to build it again. Changes to slots replace
/// the whole list, so undo just puts the old list back.
struct SlotConfig: Sendable, Equatable {
    /// Stays the same for the slot's life, whatever happens to other slots.
    var id = UUID()
    /// 0-based position in the bank. Positions can have gaps.
    var position: Int
    /// The name formulas use, e.g. "IndexFund".
    var name: String
    /// The model's name, e.g. "Savings account".
    var model: String
    var kind: ModelKind
    var formula: String
    var variable: String
    /// A color of its own, or nil for its position's palette color.
    var color: String?
    var format: ValueFormat
    /// Its own parameter and starting values, in place of the formula's defaults.
    var values: [String: Double] = [:]
    var events: [Event] = []
    var rules: [RecurringEvent] = []

    /// Identifies the model with the slot's values, so the engine can tell what changed.
    var modelKey: String {
        let values = self.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.bitPattern)" }.joined(separator: ",")
        return formula + "\u{1}" + values
    }

    func makeModel(values: [String: Double]? = nil) throws -> FormulaModel {
        try FormulaModel(formula, name: name, values: values ?? self.values)
    }
}

/// A parameter or starting value as the Slot tab shows it (docs/UI.md, 5.7).
public struct SlotValue: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    /// "Interest rate", or the name when the model gives no label.
    public let label: String
    public let quantity: Quantity
    public let minimum: Double?
    public let maximum: Double?
    public let increment: Double?
    /// What the slot starts with. nil when the formula works it out as it runs, from the date or
    /// another slot, and the slot has no value of its own.
    public let value: Double?
    /// The formula's own value, when it's a plain number.
    public let defaultValue: Double?
    /// Whether the slot has its own value in place of the default.
    public let isChanged: Bool

    /// The slider's range, when the model gives a usable one.
    public var sliderRange: ClosedRange<Double>? {
        guard let low = minimum, let high = maximum, low.isFinite, high.isFinite, low < high else { return nil }
        return low...high
    }

    /// A slider position rounded to the model's step and kept in range: 0.04531 → 0.045 for a step of 0.1%.
    public func snapped(_ value: Double) -> Double {
        var result = value
        if let step = increment, step > 0, step.isFinite {
            let base = minimum ?? 0
            result = base + ((value - base) / step).rounded() * step
            // Drop the binary noise from the multiplication: 0.045000000000000005 → 0.045.
            result = Double(String(format: "%.12g", result)) ?? result
        }
        if let range = sliderRange { result = min(max(result, range.lowerBound), range.upperBound) }
        return result
    }

    public func text(_ value: Double) -> String {
        SlotValue.text(value, quantity)
    }

    /// Reads what was typed: "4.5%", "$1,200", "1.5k", "21°C". Percent values are typed in percent,
    /// so "6" means 6%.
    public func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = CommandBarParser.parseValue(trimmed) else { return nil }
        if quantity == .percent, !trimmed.contains("%") { return parsed.value / 100 }
        return parsed.value
    }

    /// "4.5%", "$1,324", "0.03 °C", "30.1".
    static func text(_ value: Double, _ quantity: Quantity) -> String {
        switch quantity {
        case .number: return number(value)
        case .percent: return number(value * 100) + "%"
        case .currency: return (value < 0 ? "−$" : "$") + number(abs(value))
        case .temperature: return number(value) + " °C"
        }
    }

    /// Up to four significant figures, with thousands grouped: "1,324", "30.1", "0.004".
    static func number(_ value: Double) -> String {
        if value.isNaN { return "—" }
        if value.isInfinite { return value < 0 ? "−∞" : "∞" }
        let magnitude = abs(value)
        let sign = value < 0 ? "−" : ""
        if magnitude >= ValueFormat.writtenOutLimit || (magnitude > 0 && magnitude < 1e-4) {
            return sign + ValueFormat.scientific(magnitude)
        }
        if magnitude >= 1000 { return sign + ValueFormat.grouped(magnitude.rounded()) }
        return sign + String(format: "%.4g", magnitude)
    }
}

/// A value the graph can show.
public struct SlotOutput: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let label: String
}

extension StepRate {
    /// "monthly", "every 2 weeks".
    var adverb: String {
        switch self {
        case .seconds(1): return "every second"
        case .minutes(1): return "every minute"
        case .hours(1): return "hourly"
        case .days(1): return "daily"
        case .weeks(1): return "weekly"
        case .months(1): return "monthly"
        case .quarters(1): return "quarterly"
        case .years(1): return "yearly"
        case .seconds(let n): return "every \(n) seconds"
        case .minutes(let n): return "every \(n) minutes"
        case .hours(let n): return "every \(n) hours"
        case .days(let n): return "every \(n) days"
        case .weeks(let n): return "every \(n) weeks"
        case .months(let n): return "every \(n) months"
        case .quarters(let n): return "every \(n) quarters"
        case .years(let n): return "every \(n) years"
        }
    }
}
