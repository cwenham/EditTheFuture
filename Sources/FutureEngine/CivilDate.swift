import Foundation

/// Gregorian dates in UTC, computed with integer arithmetic instead of `Calendar`.
///
/// `Calendar` costs microseconds per call, which dominated the engine's step time. Step grids and
/// formula built-ins use this whenever the calendar is UTC Gregorian (the default), and fall back
/// to `Calendar` otherwise. The day-number conversions are Howard Hinnant's `days_from_civil` and
/// `civil_from_days` algorithms.
public struct CivilDate: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let secondsIntoDay: Double

    public init(_ date: Date) {
        let seconds = date.timeIntervalSince1970
        let days = Int((seconds / 86_400).rounded(.down))
        secondsIntoDay = seconds - Double(days) * 86_400
        (year, month, day) = Self.civil(fromDays: days)
    }

    /// 1 for January 1st.
    public var dayOfYear: Int {
        Self.days(fromCivil: year, month, day) - Self.days(fromCivil: year, 1, 1) + 1
    }

    public var daysInYear: Int { Self.isLeapYear(year) ? 366 : 365 }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The date at a calendar day in UTC.
    public static func date(year: Int, month: Int, day: Int, secondsIntoDay: Double = 0) -> Date {
        Date(timeIntervalSince1970: Double(days(fromCivil: year, month, day)) * 86_400 + secondsIntoDay)
    }

    /// Adds calendar months, clamping the day to the target month's length as `Calendar` does
    /// (Jan 31 + 1 month = Feb 28 or 29).
    public func addingMonths(_ months: Int) -> Date {
        let total = year * 12 + (month - 1) + months
        let newYear = total >= 0 ? total / 12 : (total - 11) / 12
        let newMonth = total - newYear * 12 + 1
        let newDay = min(day, Self.daysInMonth(year: newYear, month: newMonth))
        return Self.date(year: newYear, month: newMonth, day: newDay, secondsIntoDay: secondsIntoDay)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date.
    public static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The proleptic Gregorian date for a number of days since 1970-01-01.
    public static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}

extension Calendar {
    /// Whether `CivilDate` arithmetic gives the same answers as this calendar.
    public var isUTCGregorian: Bool {
        identifier == .gregorian && (timeZone.identifier == "UTC" || timeZone.identifier == "GMT")
    }
}
