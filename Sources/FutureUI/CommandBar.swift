import Foundation
import FutureEngine
import FutureCommands

/// What a line typed into the command bar asks for.
public enum CommandBarAction: Equatable, Sendable {
    case jumpToNow
    case moveCursor(Date)
    /// A slot by name or by its number (1...8).
    case focus(String)
    /// `kind` is "deposit" for `+amount` and "withdraw" for `-amount`. `at` nil means the cursor.
    case addEvent(kind: String, amount: Double, at: Date?, repeats: StepRate?)
    case setParameter(name: String, value: Double, at: Date?)
    case copySnapshot
    case copyData
    case undo
    case redo
}

public enum CommandBarError: Error, Equatable, CustomStringConvertible {
    case empty
    case notUnderstood(String)
    case badDate(String)
    case badAmount(String)

    public var description: String {
        switch self {
        case .empty: return "Type a command, e.g. +500 monthly from 2027-03"
        case .notUnderstood(let text): return "I didn't understand “\(text)”. Try +500 monthly, set rate 4% from 2027-06, goto 2035 or now."
        case .badDate(let text): return "“\(text)” isn't a date I know. Use 2035, 2035-06, 2035-06-15 or Jun 2035."
        case .badAmount(let text): return "“\(text)” isn't an amount. Use 500, $1,200 or 1.5k."
        }
    }
}

/// Parses the command bar's small language (docs/UI.md, 5.3 and DESIGN.md, 9.4):
///
/// - `now`, `today`
/// - `goto 2035`, `go to Jun 2035`, `show 2035-06-15`
/// - `focus savings`, `3`
/// - `+500`, `+500 monthly from 2027-03`, `-6,000 on Aug 2028`, `+1.2k every year`
/// - `set rate 4% from 2027-06`, `set monthly 650`
/// - `copy`, `copy data`, `undo`, `redo`
///
/// Natural-language input goes to a language model instead (DESIGN.md, section 7).
public enum CommandBarParser {
    public static func parse(_ input: String) throws -> CommandBarAction {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommandBarError.empty }
        let lower = text.lowercased()
        var words = lower.split(whereSeparator: \.isWhitespace).map(String.init)

        switch lower {
        case "now", "today": return .jumpToNow
        case "copy", "copy snapshot": return .copySnapshot
        case "copy data": return .copyData
        case "undo": return .undo
        case "redo": return .redo
        default: break
        }

        if let number = Int(lower), (1...8).contains(number) { return .focus(String(number)) }

        if words.first == "focus", words.count >= 2 {
            return .focus(text.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " "))
        }

        if ["goto", "show"].contains(words.first) || (words.first == "go" && words.dropFirst().first == "to") {
            words.removeFirst(words.first == "go" ? 2 : 1)
            let dateText = words.joined(separator: " ")
            guard let date = parseDate(dateText) else { throw CommandBarError.badDate(dateText) }
            return .moveCursor(date)
        }

        if words.first == "set", words.count >= 3 {
            let originalWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let name = originalWords[1]
            guard let value = parseAmount(words[2]) else { throw CommandBarError.badAmount(words[2]) }
            let at = try parseWhen(Array(words.dropFirst(3)))
            return .setParameter(name: name, value: value, at: at)
        }

        if let sign = words.first?.first, sign == "+" || sign == "-" || sign == "−" {
            var first = words.removeFirst()
            first.removeFirst()
            if first.isEmpty, !words.isEmpty { first = words.removeFirst() }
            guard let amount = parseAmount(first), amount > 0 else { throw CommandBarError.badAmount(first) }
            var repeats: StepRate?
            if let rate = words.first.flatMap(frequency) {
                repeats = rate
                words.removeFirst()
            } else if words.first == "every", words.count >= 2, let rate = frequency(words[1]) {
                repeats = rate
                words.removeFirst(2)
            }
            let at = try parseWhen(words)
            return .addEvent(kind: sign == "+" ? "deposit" : "withdraw", amount: amount, at: at, repeats: repeats)
        }

        throw CommandBarError.notUnderstood(text)
    }

    /// `from 2027-03`, `on Aug 2028`, `in 2030`, or nothing.
    static func parseWhen(_ words: [String]) throws -> Date? {
        guard !words.isEmpty else { return nil }
        var rest = words
        if ["from", "on", "in", "at", "starting"].contains(rest[0]) { rest.removeFirst() }
        let dateText = rest.joined(separator: " ")
        guard let date = parseDate(dateText) else { throw CommandBarError.badDate(dateText) }
        return date
    }

    static func frequency(_ word: String) -> StepRate? {
        switch word {
        case "daily", "day": return .daily
        case "weekly", "week": return .weekly
        case "fortnightly", "biweekly": return .weeks(2)
        case "monthly", "month": return .monthly
        case "quarterly", "quarter": return .quarters(1)
        case "yearly", "annually", "year": return .yearly
        default: return nil
        }
    }

    /// `500`, `$1,200`, `1.5k`, `2m`, `4%` (→ 0.04).
    static func parseAmount(_ word: String) -> Double? {
        var text = word.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        var multiplier = 1.0
        if text.hasSuffix("%") { multiplier = 0.01; text.removeLast() }
        else if text.hasSuffix("k") { multiplier = 1_000; text.removeLast() }
        else if text.hasSuffix("m") { multiplier = 1_000_000; text.removeLast() }
        guard let value = Double(text), value.isFinite else { return nil }
        return value * multiplier
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `2035`, `2035-06`, `2035-06-15`, `jun 2035`, `june 2035`, `15 jun 2035`.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let partial = PartialDate(trimmed) { return partial.date }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        func month(_ word: String) -> Int? {
            let prefix = String(word.prefix(3))
            return months.firstIndex(of: prefix).map { $0 + 1 }
        }
        if parts.count == 2, let m = month(parts[0]), let year = Int(parts[1]),
           let date = PartialDate(year: year, month: m) {
            return date.date
        }
        if parts.count == 3, let day = Int(parts[0]), let m = month(parts[1]), let year = Int(parts[2]),
           let date = PartialDate(year: year, month: m, day: day) {
            return date.date
        }
        return nil
    }
}
