import Foundation
import FutureEngine
import FutureCommands

/// What a line typed into the command bar asks for.
public enum CommandBarAction: Equatable, Sendable {
    case jumpToNow
    case moveCursor(Date)
    /// Move the cursor to where a slot's line first reaches `value`. `slot` nil means the slot that
    /// `format` (the value's unit) points to; a value without a unit always names its slot.
    /// `currency` is the currency typed with it, as typed: "£", "$", "euros".
    case findValue(slot: String?, value: Double, format: ValueFormat?, currency: String? = nil)
    /// A slot by name or by its number (1...8).
    case focus(String)
    /// `kind` is "deposit" for `+amount` and "withdraw" for `-amount`. `at` nil means the cursor.
    /// `currency` is the currency typed with the amount, as typed.
    case addEvent(kind: String, amount: Double, at: Date?, repeats: StepRate?, currency: String? = nil)
    case setParameter(name: String, value: Double, at: Date?)
    /// Adds a library model by name, to a slot number (1...8) or the first free one.
    case addModel(String, slot: Int?)
    /// Asks to remove a slot, by name or number.
    case removeSlot(String)
    /// Opens Refit for a slot, by name or number, or the focused slot (docs/UI.md, 5.11).
    case refit(String?)
    /// Opens Predict with for a slot, or the focused one, with a model selected by name, or the
    /// best once the scores are in (docs/UI.md, 5.11).
    case predict(slot: String?, with: String?)
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
    case badGoto(String)

    public var description: String {
        switch self {
        case .empty: return "Type a command, e.g. +500 monthly from 2027-03"
        case .notUnderstood(let text): return "I didn't understand “\(text)”. Try +500 monthly, set rate 4% from 2027-06, goto 2035, goto 25°C or now."
        case .badGoto(let text): return "“\(text)” isn't a date, or a value with its unit or slot. Try goto 2035, goto Jun 2035, goto $1M, goto 25°C or goto savings 50000."
        case .badDate(let text): return "“\(text)” isn't a date I know. Use 2035, 2035-06, 2035-06-15 or Jun 2035."
        case .badAmount(let text): return "“\(text)” isn't an amount. Use 500, 1,200 or 1.5k."
        }
    }
}

/// Parses the command bar's small language (docs/UI.md, 5.3 and DESIGN.md, 9.4):
///
/// - `now`, `today`
/// - `goto 2035`, `go to Jun 2035`, `show 2035-06-15`
/// - `goto 100°C`, `goto climate 212°F`, `goto mortgage $0`, `goto savings 1.5m`
/// - `focus savings`, `3`
/// - `+500`, `+500 monthly from 2027-03`, `-6,000 on Aug 2028`, `+1.2k every year`
/// - `set rate 4% from 2027-06`, `set monthly 650`
/// - `add savings account`, `add loan to 7`, `remove climate`
/// - `refit`, `refit savings`
/// - `predict`, `predict data with trend line`, `predict data with best`
/// - `copy`, `copy data`, `undo`, `redo`
///
/// Natural-language input goes to a language model instead (DESIGN.md, section 7).
public enum CommandBarParser {
    /// - Parameter numbers: how the focused slot writes numbers, so `+1.234,50` reads as 1234.5
    ///   where decimals follow a comma.
    public static func parse(_ input: String, numbers: NumberStyle = .commaPoint) throws -> CommandBarAction {
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
            let skip = words.first == "go" ? 2 : 1
            words.removeFirst(skip)
            let originalWords = Array(text.split(whereSeparator: \.isWhitespace).map(String.init).dropFirst(skip))
            let rest = words.joined(separator: " ")
            // A date wins, so `goto 2035` stays a year. A value needs a unit (`goto $1M`), or a slot
            // name before it (`goto savings 50000`).
            if let date = parseDate(rest) { return .moveCursor(date) }
            if let parsed = parseValue(rest, numbers: numbers), let format = parsed.format {
                return .findValue(slot: nil, value: parsed.value, format: format, currency: parsed.currency)
            }
            for split in 1..<max(words.count, 1) {
                if let parsed = parseValue(words[split...].joined(separator: " "), numbers: numbers) {
                    return .findValue(slot: originalWords[..<split].joined(separator: " "), value: parsed.value,
                                      format: parsed.format, currency: parsed.currency)
                }
            }
            throw CommandBarError.badGoto(originalWords.joined(separator: " "))
        }

        if words.first == "add", words.count >= 2 {
            var rest = Array(text.split(whereSeparator: \.isWhitespace).map(String.init).dropFirst())
            var slot: Int?
            if rest.count >= 2, let number = Int(rest[rest.count - 1]) {
                let before = rest[rest.count - 2].lowercased()
                if before == "to" || before == "slot" {
                    slot = number
                    rest.removeLast(before == "slot" && rest.count >= 3 && rest[rest.count - 3].lowercased() == "to" ? 3 : 2)
                }
            }
            guard !rest.isEmpty else { throw CommandBarError.notUnderstood(text) }
            return .addModel(rest.joined(separator: " "), slot: slot)
        }

        if words.first == "predict" {
            let rest = text.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            if let with = rest.firstIndex(where: { $0.lowercased() == "with" }) {
                let slot = rest[..<with].joined(separator: " ")
                let model = rest[(with + 1)...].joined(separator: " ")
                guard !model.isEmpty else { throw CommandBarError.notUnderstood(text) }
                return .predict(slot: slot.isEmpty ? nil : slot, with: model)
            }
            return .predict(slot: rest.isEmpty ? nil : rest.joined(separator: " "), with: nil)
        }

        if words.first == "refit" {
            let rest = text.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " ")
            return .refit(rest.isEmpty ? nil : rest)
        }

        if ["remove", "delete"].contains(words.first), words.count >= 2 {
            return .removeSlot(text.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " "))
        }

        if words.first == "set", words.count >= 3 {
            let originalWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let name = originalWords[1]
            guard let value = parseAmount(words[2], numbers: numbers) else { throw CommandBarError.badAmount(words[2]) }
            let at = try parseWhen(Array(words.dropFirst(3)))
            return .setParameter(name: name, value: value, at: at)
        }

        if let sign = words.first?.first, sign == "+" || sign == "-" || sign == "−" {
            var first = words.removeFirst()
            first.removeFirst()
            if first.isEmpty, !words.isEmpty { first = words.removeFirst() }
            // A currency's code or name can follow the amount: `+500 euros monthly`.
            if let next = words.first, Currency.split("0" + next)?.rest == "0" {
                first += next
                words.removeFirst()
            }
            guard let (amount, currency) = parseAmountAndCurrency(first, numbers: numbers), amount > 0 else {
                throw CommandBarError.badAmount(first)
            }
            var repeats: StepRate?
            if let rate = words.first.flatMap(frequency) {
                repeats = rate
                words.removeFirst()
            } else if words.first == "every", words.count >= 2, let rate = frequency(words[1]) {
                repeats = rate
                words.removeFirst(2)
            }
            let at = try parseWhen(words)
            return .addEvent(kind: sign == "+" ? "deposit" : "withdraw", amount: amount, at: at, repeats: repeats, currency: currency)
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

    /// `500`, `$1,200`, `£1,200`, `1.5k`, `2m`, `4%` (→ 0.04).
    static func parseAmount(_ word: String, numbers: NumberStyle = .commaPoint) -> Double? {
        parseAmountAndCurrency(word, numbers: numbers)?.amount
    }

    /// An amount and the currency typed with it, if any, as typed: `£1,200` is 1200 and "£".
    static func parseAmountAndCurrency(_ word: String, numbers: NumberStyle = .commaPoint) -> (amount: Double, currency: String?)? {
        var text = numbers.normalize(word.lowercased())
        var currency: String?
        if let (rest, unit) = Currency.split(text) {
            text = rest
            currency = unit
        }
        var multiplier = 1.0
        if text.hasSuffix("%") { multiplier = 0.01; text.removeLast() }
        else if text.hasSuffix("k") { multiplier = 1_000; text.removeLast() }
        else if text.hasSuffix("m") { multiplier = 1_000_000; text.removeLast() }
        guard let value = Double(text), value.isFinite else { return nil }
        return (value * multiplier, currency)
    }

    /// A value with an optional unit: `$1.5m`, `£6,000`, `-6,000 dollars`, `2k EUR`, `25°C`, `25 c`,
    /// `77°F` (converted to °C), `1.2k`, `4%`. The format is the unit's (currency or temperature), or
    /// nil for a bare number. `currency` is the currency as typed: "£", "$", "eur".
    static func parseValue(_ text: String, numbers: NumberStyle = .commaPoint) -> (value: Double, format: ValueFormat?, currency: String?)? {
        // Only the number has digits: a space may separate it from its unit ("25 °C", "2.5bn dollars"),
        // but not from another number ("3 $250k" is slot 3, then a value).
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard tokens.filter({ $0.contains(where: \.isNumber) }).count == 1 else { return nil }
        var text = numbers.normalize(tokens.joined())
            .replacingOccurrences(of: "−", with: "-")
        var format: ValueFormat?
        var currency: String?
        var fahrenheit = false
        // A currency first, so "500 chf" isn't read as °F.
        if let (rest, unit) = Currency.split(text) {
            text = rest
            format = .currency
            currency = unit
        }
        // Longest first, so "degreesf" isn't read as "f" after "degrees".
        let temperatureUnits: [(String, Bool)] = [
            ("degreesfahrenheit", true), ("degreescelsius", false), ("fahrenheit", true), ("celsius", false),
            ("degreesf", true), ("degreesc", false), ("degrees", false), ("degf", true), ("degc", false),
            ("deg", false), ("°f", true), ("°c", false), ("℉", true), ("℃", false), ("°", false), ("f", true), ("c", false),
        ]
        for (unit, isFahrenheit) in temperatureUnits where format == nil && text.hasSuffix(unit) {
            text.removeLast(unit.count)
            format = .temperature
            fahrenheit = isFahrenheit
            break
        }
        var multiplier = 1.0
        if format != .temperature {
            let multipliers: [(String, Double)] = [("bn", 1e9), ("tn", 1e12), ("k", 1e3), ("m", 1e6), ("b", 1e9), ("t", 1e12), ("%", 0.01)]
            for (suffix, value) in multipliers where text.hasSuffix(suffix) {
                text.removeLast(suffix.count)
                multiplier = value
                break
            }
        }
        // Digits, a point, a sign and an exponent only: Double() also reads words like "inf" and "nan".
        guard text.contains(where: \.isNumber), text.allSatisfy({ $0.isNumber || ".-+e".contains($0) }),
              let number = Double(text), number.isFinite else { return nil }
        let value = fahrenheit ? (number - 32) * 5 / 9 : number * multiplier
        guard value.isFinite else { return nil }
        return (value, format, currency)
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
