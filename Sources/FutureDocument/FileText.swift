import Foundation
import FutureEngine

/// Numbers as a saved scenario writes them (docs/DESIGN.md, 15.2): exact, so they read back as the
/// same value, with `inf`, `-inf` and `nan` allowed.
public enum FileNumber {
    /// Reads `6000`, `4.5%`, `-12.5`, `1.5k`, `$1200`, `£1200`, `1200 EUR`, `1e+20`, `inf`, `nan`. Thousands separators
    /// are allowed only where `commas` says so (not inside brackets, where commas separate settings).
    public static func parse(_ text: String, commas: Bool = true) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "−", with: "-")
        switch text {
        case "inf", "+inf", "infinity", "+infinity", "∞": return .infinity
        case "-inf", "-infinity", "-∞": return -.infinity
        case "nan": return .nan
        default: break
        }
        if commas { text = text.replacingOccurrences(of: ",", with: "") }
        if let (rest, _) = Currency.split(text.contains(" ") ? text.replacingOccurrences(of: " ", with: "") : text) { text = rest }
        var multiplier = 1.0
        for (suffix, value) in [("°c", 1.0), ("°", 1), ("%", 0.01), ("bn", 1e9), ("tn", 1e12), ("k", 1e3), ("m", 1e6),
                                ("b", 1e9), ("t", 1e12)] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            multiplier = value
            break
        }
        // Digits, a point, a sign and an exponent only: Double() also reads words like "infinity".
        guard text.contains(where: \.isNumber), text.allSatisfy({ $0.isASCII && ($0.isNumber || ".-+e".contains($0)) }),
              let number = Double(text) else { return nil }
        // Percents divide, so 4.5% is exactly the value written as 0.045.
        return multiplier == 0.01 ? number / 100 : number * multiplier
    }

    /// The shortest text that reads back as exactly `value`. Percents are written as `4.5%` when
    /// that reads back exactly too.
    public static func text(_ value: Double, percent: Bool = false) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if percent {
            let written = shortest(value * 100) + "%"
            if let back = parse(written), back.bitPattern == value.bitPattern { return written }
        }
        return shortest(value)
    }

    /// Swift's own description is the shortest text that reads back exactly: "6000.0", "0.1", "1e+20".
    static func shortest(_ value: Double) -> String {
        var text = "\(value)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    /// Whether two numbers are the same, counting NaN as equal to itself.
    public static func same(_ a: Double, _ b: Double) -> Bool {
        a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN)
    }
}

/// Dates as a saved scenario writes them: ISO 8601 in UTC, like the engine (docs/DESIGN.md, 15.2).
public enum FileDate {
    /// Reads `2028`, `2028-08`, `2028-08-01`, `2028-08-01T09:30`, `2028-08-01T09:30:15Z` and years
    /// with a sign and more digits: `+31000-01-01`, `-0500-03-01`. With `spaces`, a space may stand
    /// for the `T`, as databases often write it: `2028-08-01 09:30:00`.
    public static func parse(_ text: String, spaces: Bool = false) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if spaces { text = text.replacingOccurrences(of: " ", with: "T") }
        if text.hasSuffix("Z") || text.hasSuffix("z") { text.removeLast() }
        let parts = text.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard let datePart = parts.first, parts.count <= 2 else { return nil }

        // The year: four digits, or a sign and four or more.
        var rest = Substring(datePart)
        var sign = 1
        var signed = false
        if let first = rest.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            signed = true
            rest = rest.dropFirst()
        }
        let yearDigits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (4...12).contains(yearDigits.count), signed || yearDigits.count == 4 || yearDigits.first != "0",
              let yearNumber = Int(yearDigits) else { return nil }
        let year = sign * yearNumber
        rest = rest.dropFirst(yearDigits.count)
        var numbers: [Int] = []
        while !rest.isEmpty {
            guard rest.first == "-" else { return nil }
            rest = rest.dropFirst()
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count == 2, let number = Int(digits) else { return nil }
            numbers.append(number)
            rest = rest.dropFirst(2)
        }
        guard numbers.count <= 2 else { return nil }
        let month = numbers.count > 0 ? numbers[0] : 1
        let day = numbers.count > 1 ? numbers[1] : 1
        guard (1...12).contains(month), (1...CivilDate.daysInMonth(year: year, month: month)).contains(day) else { return nil }

        var seconds = 0.0
        if parts.count == 2 {
            guard numbers.count == 2 else { return nil }
            let clock = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(clock.count), clock[0].count == 2, clock[1].count == 2,
                  let hour = Int(clock[0]), let minute = Int(clock[1]), (0...23).contains(hour), (0...59).contains(minute)
            else { return nil }
            seconds = Double(hour * 3_600 + minute * 60)
            if clock.count == 3 {
                guard clock[2].count >= 2, clock[2].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                      let second = Double(clock[2]), second >= 0, second < 61 else { return nil }
                seconds += second
            }
        }
        return CivilDate.date(year: year, month: month, day: day, secondsIntoDay: seconds)
    }

    /// `2028-08-01`, `2028-08-01T09:30`, `+31000-01-01`.
    public static func text(_ date: Date) -> String {
        let civil = CivilDate(date)
        var text = year(civil.year) + "-" + twoDigits(civil.month) + "-" + twoDigits(civil.day)
        let seconds = civil.secondsIntoDay
        if seconds != 0 {
            let whole = Int(seconds.rounded(.down))
            text += "T" + twoDigits(whole / 3_600) + ":" + twoDigits(whole / 60 % 60)
            let rest = seconds - Double(whole / 60 * 60)
            if rest != 0 {
                let secondText = rest == rest.rounded() ? twoDigits(Int(rest)) : (rest < 10 ? "0" : "") + "\(rest)"
                text += ":" + secondText
            }
        }
        return text
    }

    /// Four digits from 0 to 9999; a sign and the digits otherwise.
    static func year(_ year: Int) -> String {
        if (0...9999).contains(year) { return pad(year, 4) }
        return (year < 0 ? "-" : "+") + pad(abs(year), 4)
    }

    static func twoDigits(_ number: Int) -> String { pad(number, 2) }

    static func pad(_ number: Int, _ width: Int) -> String {
        let digits = String(number)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

/// A slot or event name: a letter, then letters, digits or underscores.
func isIdentifier(_ text: some StringProtocol) -> Bool {
    guard let first = text.first, first.isLetter || first == "_" else { return false }
    return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}
