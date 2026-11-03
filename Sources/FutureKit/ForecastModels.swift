import Foundation
import FutureEngine

/// The Forecast models (docs/DESIGN.md, 8.4): simple ways to carry a series of readings into the
/// future, for Predict with to fit and compare. Each is written around whichever value the slot's
/// readings are of, at the slot's step, so choosing one keeps the slots that read it working.
public enum ForecastModels {
    public enum Kind: String, CaseIterable, Sendable {
        case holdTheLatest, steadyChange, steadyGrowth, recentChange, recentGrowth, trendLine, sCurve, seasonal

        public var name: String {
            switch self {
            case .holdTheLatest: return "Hold the latest"
            case .steadyChange: return "Steady change"
            case .steadyGrowth: return "Steady growth"
            case .recentChange: return "Recent change"
            case .recentGrowth: return "Recent growth"
            case .trendLine: return "Trend line"
            case .sCurve: return "S-curve"
            case .seasonal: return "Seasonal"
            }
        }

        public var summary: String {
            switch self {
            case .holdTheLatest: return "Stays at the latest reading"
            case .steadyChange: return "Changes by the same amount every year, from the latest reading"
            case .steadyGrowth: return "Grows by the same percent every year, from the latest reading"
            case .recentChange: return "Keeps changing by its recent change per year, learning from each reading"
            case .recentGrowth: return "Keeps growing by its recent percent per year, learning from each reading"
            case .trendLine: return "A straight line through the readings"
            case .sCurve: return "Grows, then levels off, from the latest reading"
            case .seasonal: return "A straight line through the readings, plus a yearly wave"
            }
        }

        var id: String { "forecast-" + rawValue }

        /// Models that work in ratios, so every reading has to be above zero.
        var needsPositive: Bool { self == .steadyGrowth || self == .recentGrowth || self == .sCurve }

        /// Names the formula uses besides the value, which the value can't share.
        var ownNames: [String] {
            switch self {
            case .holdTheLatest: return []
            case .steadyChange: return ["perYear"]
            case .steadyGrowth: return ["growth"]
            case .recentChange: return ["smoothing", "perYear", "previous"]
            case .recentGrowth: return ["smoothing", "rate", "previous"]
            case .trendLine: return ["level", "perYear"]
            case .sCurve: return ["rate", "capacity"]
            case .seasonal: return ["level", "perYear", "swing", "peak"]
            }
        }
    }

    /// What a Forecast model is written around: the value, how it's shown, and the slot's step.
    public struct Value: Hashable, Sendable {
        public var name: String
        public var label: String
        public var format: ValueFormat
        public var step: StepRate

        public init(name: String, label: String, format: ValueFormat, step: StepRate) {
            self.name = name
            self.label = label
            self.format = format
            self.step = step
        }
    }

    /// The models as the picker lists them, around a value called `value`, monthly.
    public static let library: [ModelTemplate] = Kind.allCases.map {
        template($0, for: Value(name: "value", label: "Value", format: .number, step: .months(1)))
    }

    /// The Forecast model that a template is, if it's one.
    public static func kind(of template: ModelTemplate) -> Kind? {
        Kind.allCases.first { $0.id == template.id }
    }

    /// The models that suit these readings of a value: those that work in ratios only when every
    /// reading is above zero, and Seasonal only for steps shorter than a year.
    public static func templates(for value: Value, readings: [Reading]) -> [ModelTemplate] {
        let positive = !readings.isEmpty && readings.allSatisfy { $0.value > 0 && $0.value.isFinite }
        let underAYear = value.step.approximateSeconds < 300 * 86_400
        return Kind.allCases.filter { kind in
            (positive || !kind.needsPositive) && (underAYear || kind != .seasonal) && !kind.ownNames.contains(value.name)
        }.map { template($0, for: value) }
    }

    public static func template(_ kind: Kind, for value: Value) -> ModelTemplate {
        ModelTemplate(id: kind.id, name: kind.name, category: .forecast, summary: kind.summary, slotName: "Data",
                      formula: formula(kind, for: value), variable: value.name, format: value.format)
    }

    /// The formula, written around the value.
    public static func formula(_ kind: Kind, for value: Value) -> String {
        let v = value.name
        let label = value.label.replacingOccurrences(of: "\"", with: "'")
        let shown = value.format == .number ? "" : " as \(value.format.rawValue)"
        let lines: [String]
        switch kind {
        case .holdTheLatest:
            lines = [
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Readings replace the value; between and after them it holds the latest.",
                "\(v)[t] = \(v)[t-1]",
            ]
        case .steadyChange:
            lines = [
                "timeunit year",
                "param perYear = 0 label \"Change per year\"\(shown) fit",
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Carries on from the latest reading by the same amount each year.",
                "\(v)[t] = \(v)[t-1] + perYear * dt",
            ]
        case .steadyGrowth:
            lines = [
                "timeunit year",
                "param growth = 3% range -50%..100% by 0.1% label \"Growth per year\" fit",
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Carries on from the latest reading by the same percent each year.",
                "\(v)[t] = \(v)[t-1] * (1 + growth) ^ dt",
            ]
        case .recentChange:
            lines = [
                "timeunit year",
                "param smoothing = 10% range 0.1%..100% by 0.1% label \"Smoothing\" fit",
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Learns the change per year from each new reading. Smoothing is how much each one counts.",
                "perYear[t] = if(previous[t-1] == 0, perYear[t-1], perYear[t-1] + smoothing * ((\(v)[t-1] - previous[t-1]) / dt - perYear[t-1])) label \"Recent change per year\"\(shown)",
                "previous[t] = \(v)[t-1] label \"Previous value\"\(shown)",
                "\(v)[t] = \(v)[t-1] + perYear * dt",
            ]
        case .recentGrowth:
            lines = [
                "timeunit year",
                "param smoothing = 10% range 0.1%..100% by 0.1% label \"Smoothing\" fit",
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Learns the growth rate from each new reading. Smoothing is how much each one counts.",
                "rate[t] = if(previous[t-1] <= 0 or \(v)[t-1] <= 0, rate[t-1], rate[t-1] + smoothing * (log(\(v)[t-1] / previous[t-1]) / dt - rate[t-1])) label \"Recent growth rate per year\" as percent",
                "previous[t] = \(v)[t-1] label \"Previous value\"\(shown)",
                "\(v)[t] = \(v)[t-1] * exp(rate * dt)",
            ]
        case .trendLine:
            lines = [
                "param level = 0 label \"\(label) in 2000\"\(shown) fit",
                "param perYear = 0 label \"Change per year\"\(shown) fit",
                "# A straight line through the readings, measured from the start of 2000.",
                "\(v)[t] = level + perYear * (year - 2000) label \"\(label)\"\(shown)",
            ]
        case .sCurve:
            lines = [
                "timeunit year",
                "param rate = 50% range 0%..500% by 1% label \"Growth rate per year\" fit",
                "param capacity = 1000 label \"Levels off at\"\(shown) fit",
                "init \(v) = 0 label \"\(label)\"\(shown)",
                "# Grows, then levels off at the capacity (logistic growth), from the latest reading.",
                "\(v)[t] = if(\(v)[t-1] <= 0, 0, capacity / (1 + (capacity / \(v)[t-1] - 1) * exp(-rate * dt)))",
            ]
        case .seasonal:
            lines = [
                "param level = 0 label \"\(label) in 2000\"\(shown) fit",
                "param perYear = 0 label \"Change per year\"\(shown) fit",
                "param swing = 0 label \"Seasonal swing\"\(shown) fit",
                "param peak = 7 range 1..13 by 0.1 label \"Peaks in month\" fit",
                "# A straight line through the readings, plus a yearly wave that's highest in the peak month.",
                "\(v)[t] = level + perYear * (year - 2000) + swing * cos(2 * pi * (year - (peak - 1) / 12)) label \"\(label)\"\(shown)",
            ]
        }
        return (["step \(value.step.text)"] + lines).joined(separator: "\n")
    }

    // MARK: First guesses

    /// Where fitting starts for a model, worked out from the readings it's fitted to. A line that
    /// starts at zero can't be compared with readings that are all above zero, and models with a
    /// wave or a ceiling fit more surely from near the answer. `inRatios` when the misses will be
    /// ratios: a line is then fitted to each reading's share of its size, so it stays above zero
    /// near the small readings of a series that grew a lot.
    public static func guess(_ kind: Kind, readings: [Reading], inRatios: Bool = false) -> [String: Double] {
        let points = readings.filter { $0.value.isFinite }.map { (year: fractionalYear($0.time), value: $0.value) }
        guard let first = points.first, let last = points.last, last.year > first.year else { return [:] }
        let years = last.year - first.year
        switch kind {
        case .holdTheLatest, .recentChange, .recentGrowth:
            return [:]
        case .steadyChange:
            return ["perYear": (last.value - first.value) / years]
        case .steadyGrowth:
            guard first.value > 0, last.value > 0 else { return [:] }
            return ["growth": min(max(Foundation.exp(Foundation.log(last.value / first.value) / years) - 1, -0.5), 1)]
        case .trendLine:
            let line = straightLine(points, relative: inRatios)
            return ["level": line.level, "perYear": line.perYear]
        case .sCurve:
            guard first.value > 0, last.value > 0, let highest = points.map(\.value).max() else { return [:] }
            let growth = Foundation.log(last.value / first.value) / years
            return ["capacity": 1.5 * highest, "rate": min(max(2 * growth, 0.05), 5)]
        case .seasonal:
            let line = straightLine(points, relative: inRatios)
            // The average distance from the line in each month of the year.
            var sums = [Double](repeating: 0, count: 12), counts = [Double](repeating: 0, count: 12)
            for point in points {
                let fraction = point.year - point.year.rounded(.down)
                let month = min(11, max(0, Int((fraction * 12).rounded(.down))))
                sums[month] += point.value - (line.level + line.perYear * (point.year - 2000))
                counts[month] += 1
            }
            let means = (0..<12).filter { counts[$0] > 0 }.map { (month: $0, mean: sums[$0] / counts[$0]) }
            guard let high = means.max(by: { $0.mean < $1.mean }), let low = means.min(by: { $0.mean < $1.mean }) else {
                return ["level": line.level, "perYear": line.perYear]
            }
            return ["level": line.level, "perYear": line.perYear, "swing": (high.mean - low.mean) / 2,
                    "peak": Double(high.month + 1)]
        }
    }

    /// The least-squares line through the points, as its value in 2000 and its change per year.
    /// `relative` weighs each point by one over its size squared, so misses count as shares.
    static func straightLine(_ points: [(year: Double, value: Double)], relative: Bool = false) -> (level: Double, perYear: Double) {
        let weights = points.map { relative && $0.value != 0 ? 1 / ($0.value * $0.value) : 1 }
        let total = weights.reduce(0, +)
        var meanYear = 0.0, meanValue = 0.0
        for (point, weight) in zip(points, weights) {
            meanYear += weight * point.year / total
            meanValue += weight * point.value / total
        }
        var covariance = 0.0, variance = 0.0
        for (point, weight) in zip(points, weights) {
            covariance += weight * (point.year - meanYear) * (point.value - meanValue)
            variance += weight * (point.year - meanYear) * (point.year - meanYear)
        }
        let perYear = variance > 0 ? covariance / variance : 0
        return (meanValue - perYear * (meanYear - 2000), perYear)
    }

    /// The calendar year with its fraction, as formulas' `year` gives it.
    static func fractionalYear(_ date: Date) -> Double {
        let civil = CivilDate(date)
        let start = CivilDate.date(year: civil.year, month: 1, day: 1)
        let next = CivilDate.date(year: civil.year + 1, month: 1, day: 1)
        return Double(civil.year) + date.timeIntervalSince(start) / next.timeIntervalSince(start)
    }
}
