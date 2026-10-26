import Foundation

/// How far a model moves in one step. Calendar-aware: `.months(1)` means calendar months.
public enum StepRate: Hashable, Sendable, Codable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)
    case months(Int)
    case quarters(Int)
    case years(Int)

    public static let daily = StepRate.days(1)
    public static let weekly = StepRate.weeks(1)
    public static let monthly = StepRate.months(1)
    public static let yearly = StepRate.years(1)

    /// The calendar component and amount to add for one step.
    var calendarStep: (component: Calendar.Component, count: Int) {
        switch self {
        case .seconds(let n): return (.second, n)
        case .minutes(let n): return (.minute, n)
        case .hours(let n): return (.hour, n)
        case .days(let n): return (.day, n)
        case .weeks(let n): return (.day, 7 * n)
        case .months(let n): return (.month, n)
        case .quarters(let n): return (.month, 3 * n)
        case .years(let n): return (.year, n)
        }
    }

    /// The rate's own unit, with a count of one. `.months(3)` becomes `.months(1)`.
    public var unit: StepRate {
        switch self {
        case .seconds: return .seconds(1)
        case .minutes: return .minutes(1)
        case .hours: return .hours(1)
        case .days: return .days(1)
        case .weeks: return .weeks(1)
        case .months: return .months(1)
        case .quarters: return .quarters(1)
        case .years: return .years(1)
        }
    }

    /// Average length of one step in seconds. Used for estimates and for `dt`, never for boundaries.
    public var approximateSeconds: Double {
        let day = 86_400.0
        switch self {
        case .seconds(let n): return Double(n)
        case .minutes(let n): return Double(n) * 60
        case .hours(let n): return Double(n) * 3_600
        case .days(let n): return Double(n) * day
        case .weeks(let n): return Double(n) * 7 * day
        case .months(let n): return Double(n) * 30.436_875 * day
        case .quarters(let n): return Double(n) * 3 * 30.436_875 * day
        case .years(let n): return Double(n) * 365.2425 * day
        }
    }

    var isValid: Bool { calendarStep.count > 0 }

    /// "1 month", "2 weeks": the formula language's step units, as a saved scenario writes them.
    public var text: String {
        let (count, unit): (Int, String)
        switch self {
        case .seconds(let n): (count, unit) = (n, "second")
        case .minutes(let n): (count, unit) = (n, "minute")
        case .hours(let n): (count, unit) = (n, "hour")
        case .days(let n): (count, unit) = (n, "day")
        case .weeks(let n): (count, unit) = (n, "week")
        case .months(let n): (count, unit) = (n, "month")
        case .quarters(let n): (count, unit) = (n, "quarter")
        case .years(let n): (count, unit) = (n, "year")
        }
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// Reads "1 month", "2 weeks", "month" or "monthly". nil for anything else.
    public init?(text: String) {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let adverbs: [String: StepRate] = ["hourly": .hours(1), "daily": .days(1), "weekly": .weeks(1),
                                           "fortnightly": .weeks(2), "monthly": .months(1), "quarterly": .quarters(1),
                                           "yearly": .years(1), "annually": .years(1)]
        if words.count == 1, let rate = adverbs[words[0]] {
            self = rate
            return
        }
        let count: Int, unit: String
        switch words.count {
        case 1: (count, unit) = (1, words[0])
        case 2:
            guard let number = Int(words[0]), number > 0, number <= 1_000_000 else { return nil }
            (count, unit) = (number, words[1])
        default: return nil
        }
        switch unit.hasSuffix("s") ? String(unit.dropLast()) : unit {
        case "second", "sec": self = .seconds(count)
        case "minute", "min": self = .minutes(count)
        case "hour": self = .hours(count)
        case "day": self = .days(count)
        case "week": self = .weeks(count)
        case "month": self = .months(count)
        case "quarter": self = .quarters(count)
        case "year": self = .years(count)
        default: return nil
        }
    }
}

extension Calendar {
    /// Gregorian calendar in UTC, so step boundaries never move with daylight saving.
    public static let utcGregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// A model's communication points: start + i × rate.
///
/// Points are always computed from the start, never by repeated addition, so a Jan 31 start
/// gives Feb 28/29 and then Mar 31 instead of drifting to the 28th.
public struct TimeGrid: Hashable, Sendable {
    public let start: Date
    public let rate: StepRate
    public let calendar: Calendar
    /// The start as a UTC calendar day, when `CivilDate` arithmetic can replace `Calendar`.
    private let civilStart: CivilDate?

    public init(start: Date, rate: StepRate, calendar: Calendar = .utcGregorian) {
        self.start = start
        self.rate = rate
        self.calendar = calendar
        self.civilStart = calendar.isUTCGregorian ? CivilDate(start) : nil
    }

    public func point(_ index: Int) -> Date {
        if index == 0 { return start }
        let step = rate.calendarStep
        if let civilStart {
            let amount = step.count * index
            switch step.component {
            case .second: return start.addingTimeInterval(Double(amount))
            case .minute: return start.addingTimeInterval(Double(amount) * 60)
            case .hour: return start.addingTimeInterval(Double(amount) * 3_600)
            case .day: return start.addingTimeInterval(Double(amount) * 86_400)
            case .month: return civilStart.addingMonths(amount)
            case .year: return civilStart.addingMonths(amount * 12)
            default: break
            }
        }
        return calendar.date(byAdding: step.component, value: step.count * index, to: start)!
    }

    /// Index of the last point at or before `date`, or nil when `date` is before the start.
    public func lastIndex(atOrBefore date: Date) -> Int? {
        guard date >= start else { return nil }
        let estimate = date.timeIntervalSince(start) / rate.approximateSeconds
        var index = max(0, Int(estimate.rounded(.down)))
        while index > 0 && point(index) > date { index -= 1 }
        while point(index + 1) <= date { index += 1 }
        return index
    }

    /// Index of the first point at or after `date`.
    public func firstIndex(atOrAfter date: Date) -> Int {
        guard let last = lastIndex(atOrBefore: date) else { return 0 }
        return point(last) == date ? last : last + 1
    }
}

/// The slice of time one step covers: after `lower`, up to and including `upper`.
/// The first step of a timeline also includes `lower` itself.
public struct StepWindow: Hashable, Sendable {
    public let lower: Date
    public let upper: Date
    public let includesLower: Bool

    public init(lower: Date, upper: Date, includesLower: Bool) {
        self.lower = lower
        self.upper = upper
        self.includesLower = includesLower
    }

    public func contains(_ date: Date) -> Bool {
        (includesLower ? date >= lower : date > lower) && date <= upper
    }

    /// The window of step `index` on `grid`. Step 0 is the start instant.
    public static func forStep(_ index: Int, on grid: TimeGrid) -> StepWindow {
        if index == 0 {
            return StepWindow(lower: grid.start, upper: grid.start, includesLower: true)
        }
        return StepWindow(lower: grid.point(index - 1), upper: grid.point(index), includesLower: index == 1)
    }
}
