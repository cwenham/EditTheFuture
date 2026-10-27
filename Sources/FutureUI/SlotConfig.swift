import Foundation
import FutureDocument
import FutureEngine
import FutureFormula
import FutureScript

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
    var readings = SlotReadings.none
    /// Why the slot can't run, from a mistake in its section of scenario.md, such as a missing model.
    var problem: String?
    /// Whether scenario.md says what the graph shows (`shows`) and how (`as`). When it doesn't,
    /// they're left out while they're still the model's own.
    var showsInFile = true
    var formatInFile = false

    /// Identifies the model with the slot's values, so the engine can tell what changed.
    var modelKey: String {
        let values = self.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.bitPattern)" }.joined(separator: ",")
        var key = formula + "\u{1}" + values
        // Reloading libraries makes scripts load again.
        if case .script(let language) = kind { key += "\u{1}\(language.rawValue)\u{1}\(ScriptPrograms.generation)" }
        return key
    }

    func makeModel(values: [String: Double]? = nil) throws -> any AuthoredModel {
        try Self.model(kind: kind, source: formula, name: name, values: values ?? self.values)
    }

    /// The slot's model built from other text, such as a draft in the editor.
    func makeModel(source: String) throws -> any AuthoredModel {
        try Self.model(kind: kind, source: source, name: name, values: values)
    }

    /// A formula or script model.
    static func model(kind: ModelKind, source: String, name: String = "Model", values: [String: Double] = [:]) throws -> any AuthoredModel {
        switch kind {
        case .formula: return try FormulaModel(source, name: name, values: values)
        case .script(let language): return try ScriptModel(source, language: language, name: name, values: values)
        case .plugin, .remote: throw ScriptError("\(kind.title) models can't run yet.")
        }
    }
}

/// Where a slot's readings come from, and what they say (docs/DESIGN.md, 15.3, 15.4 and 15.8).
public struct SlotReadings: Sendable, Equatable {
    public private(set) var sources: [ReadingSource]
    /// What each source gave, in the order of the sources.
    public private(set) var parts: [ReadingSet]
    /// All of them together.
    public private(set) var set: ReadingSet

    public init(sources: [ReadingSource], parts: [ReadingSet]) {
        self.sources = sources
        self.parts = sources.indices.map { parts.indices.contains($0) ? parts[$0] : .empty }
        set = Self.combined(self.parts)
    }

    /// Readings that aren't split by source yet: they count as the first source's.
    public init(sources: [ReadingSource], set: ReadingSet) {
        self.init(sources: sources, parts: sources.isEmpty ? [] : [set])
    }

    public static let none = SlotReadings(sources: [], parts: [])

    private static func combined(_ parts: [ReadingSet]) -> ReadingSet {
        let filled = parts.filter { !$0.readings.isEmpty }
        if filled.isEmpty { return .empty }
        if filled.count == 1 { return filled[0] }
        return ReadingSet(filled.flatMap(\.readings))
    }

    /// The same sources with one source's readings replaced.
    public func replacing(part index: Int, with readings: ReadingSet) -> SlotReadings {
        guard parts.indices.contains(index), parts[index] != readings else { return self }
        var parts = self.parts
        parts[index] = readings
        return SlotReadings(sources: sources, parts: parts)
    }

    /// Other sources. Sources it already had keep their readings; new ones have none until they're read.
    public func with(sources new: [ReadingSource]) -> SlotReadings {
        var unused = Array(zip(sources, parts))
        let parts = new.map { source -> ReadingSet in
            guard let found = unused.firstIndex(where: { $0.0 == source }) else { return .empty }
            return unused.remove(at: found).1
        }
        return SlotReadings(sources: new, parts: parts)
    }

    /// These sources, with the readings of the same sources in `newer` wherever it has them.
    func keepingReadings(of newer: SlotReadings) -> SlotReadings {
        var unused = Array(zip(newer.sources, newer.parts))
        var parts = self.parts
        for (index, source) in sources.enumerated() {
            if let found = unused.firstIndex(where: { $0.0 == source }) { parts[index] = unused.remove(at: found).1 }
        }
        return SlotReadings(sources: sources, parts: parts)
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
