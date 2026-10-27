import Foundation
import FutureEngine

// Tools for editing formulas (docs/UI.md, 5.7): colouring, completion, and diagnoses with
// one-click fixes. They work on text that's being typed, so none of them needs the formula to
// be valid. Ranges are UTF-16, as NSString and NSTextView count.

// MARK: Vocabulary

/// The formula language's words, with what they mean, for completion and the insert palette.
public enum FormulaVocabulary {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        /// How it's written, e.g. "clamp(x, lo, hi)".
        public let usage: String
        public let summary: String
    }

    /// Words that start a statement or join conditions.
    public static let keywords: Set<String> = ["step", "timeunit", "param", "init", "when", "emit", "on", "and", "or", "not"]
    /// Words for a param's or init's options: `range 0..10 by 1 label "Rate" as percent fit`.
    public static let optionWords: Set<String> = ["range", "by", "label", "as", "fit"]

    public static let functions: [Entry] = [
        Entry(name: "min", usage: "min(a, b, …)", summary: "The smallest of its values"),
        Entry(name: "max", usage: "max(a, b, …)", summary: "The largest of its values"),
        Entry(name: "clamp", usage: "clamp(x, low, high)", summary: "x, kept between low and high"),
        Entry(name: "if", usage: "if(condition, a, b)", summary: "a when the condition is true, otherwise b"),
        Entry(name: "abs", usage: "abs(x)", summary: "x without its sign"),
        Entry(name: "round", usage: "round(x)", summary: "x rounded to a whole number"),
        Entry(name: "floor", usage: "floor(x)", summary: "x rounded down"),
        Entry(name: "ceil", usage: "ceil(x)", summary: "x rounded up"),
        Entry(name: "sqrt", usage: "sqrt(x)", summary: "Square root"),
        Entry(name: "pow", usage: "pow(x, y)", summary: "x to the power y, the same as x ^ y"),
        Entry(name: "exp", usage: "exp(x)", summary: "e to the power x"),
        Entry(name: "log", usage: "log(x)", summary: "Natural logarithm"),
        Entry(name: "log10", usage: "log10(x)", summary: "Logarithm to base 10"),
        Entry(name: "mod", usage: "mod(x, y)", summary: "The remainder of x ÷ y"),
        Entry(name: "sin", usage: "sin(x)", summary: "Sine, in radians"),
        Entry(name: "cos", usage: "cos(x)", summary: "Cosine, in radians"),
        Entry(name: "tan", usage: "tan(x)", summary: "Tangent, in radians"),
        Entry(name: "random", usage: "random()", summary: "A random number from 0 to 1. Makes the model stochastic."),
        Entry(name: "normal", usage: "normal(mean, sd)", summary: "A random number from a normal distribution"),
    ]

    public static let builtins: [Entry] = [
        Entry(name: "year", usage: "year", summary: "The year, with how far through it, e.g. 2030.5"),
        Entry(name: "month", usage: "month", summary: "The month, 1 to 12"),
        Entry(name: "day", usage: "day", summary: "The day of the month"),
        Entry(name: "dayOfYear", usage: "dayOfYear", summary: "The day of the year, 1 to 366"),
        Entry(name: "days", usage: "days", summary: "Days since the scenario started"),
        Entry(name: "step", usage: "step", summary: "The step number, 0 at the start"),
        Entry(name: "dt", usage: "dt", summary: "The step's length in the time unit"),
        Entry(name: "pi", usage: "pi", summary: "3.14159…"),
    ]

    /// How a reading of another slot is resampled: `Climate.temp.mean`.
    public static let rules: [Entry] = [
        Entry(name: "hold", usage: "Slot.value.hold", summary: "Its last value at or before this step (the default)"),
        Entry(name: "mean", usage: "Slot.value.mean", summary: "The average over this step"),
        Entry(name: "sum", usage: "Slot.value.sum", summary: "The total over this step, for flows like rainfall"),
        Entry(name: "min", usage: "Slot.value.min", summary: "The lowest over this step"),
        Entry(name: "max", usage: "Slot.value.max", summary: "The highest over this step"),
    ]

    public static let units = ["second", "minute", "hour", "day", "week", "month", "quarter", "year"]
    public static let quantities = ["number", "percent", "currency", "temperature"]

    /// Lines that start a model, for completion at the start of a line.
    public static let statements: [Entry] = [
        Entry(name: "step", usage: "step 1 month", summary: "How often the model steps"),
        Entry(name: "timeunit", usage: "timeunit year", summary: "The unit for dt and d/dt"),
        Entry(name: "param", usage: "param rate = 5%", summary: "A parameter; set events can change it"),
        Entry(name: "init", usage: "init balance = 1000", summary: "A value's starting value"),
        Entry(name: "when", usage: "when temp > 30 emit Heatwave", summary: "Sends an event when a condition turns true"),
        Entry(name: "on", usage: "on deposit: balance += event.amount", summary: "Runs for each event of a kind"),
    ]
}

// MARK: Colouring

/// What a stretch of formula text is, so an editor can colour it.
public enum FormulaTokenKind: String, Sendable, Hashable {
    case keyword, number, string, comment, builtin, function
    /// Another slot's value or event: `Climate.temp.mean`.
    case reference
    /// `[t]` or `[t-1]`.
    case lag
    /// `event.amount`.
    case eventField
    /// A variable, parameter or unit.
    case name
    case symbol
}

public struct FormulaToken: Sendable, Hashable {
    public let kind: FormulaTokenKind
    public let range: NSRange
    public let text: String
}

public enum FormulaHighlighter {
    /// The formula's tokens, including comments, whether or not it's valid.
    public static func tokens(in source: String) -> [FormulaToken] {
        let units = Array(source.utf16)
        var tokens: [FormulaToken] = []
        var index = 0
        var firstWordOfLine: String?
        var previousWord: String?

        func unit(_ offset: Int) -> UInt16? { offset < units.count ? units[offset] : nil }
        func add(_ kind: FormulaTokenKind, _ start: Int, _ end: Int) {
            tokens.append(FormulaToken(kind: kind, range: NSRange(location: start, length: end - start),
                                       text: text(units, start, end)))
        }
        func skipSpaces(from offset: Int) -> Int {
            var offset = offset
            while let next = unit(offset), next == 32 || next == 9 { offset += 1 }
            return offset
        }

        while index < units.count {
            let c = units[index]
            if c == 10 {
                firstWordOfLine = nil
                previousWord = nil
                index += 1
            } else if c == 32 || c == 9 || c == 13 {
                index += 1
            } else if c == hash || (c == slash && unit(index + 1) == slash) {
                let start = index
                while let next = unit(index), next != 10 { index += 1 }
                add(.comment, start, index)
            } else if c == quote {
                let start = index
                index += 1
                while let next = unit(index), next != quote, next != 10 { index += 1 }
                if unit(index) == quote { index += 1 }
                add(.string, start, index)
            } else if isDigit(c) || (c == dot && unit(index + 1).map(isDigit) == true) {
                let start = index
                index = numberEnd(units, from: index)
                if unit(index) == percent { index += 1 }
                add(.number, start, index)
            } else if c == openBracket, let end = lagEnd(units, from: index) {
                add(.lag, index, end)
                index = end
            } else if isIdentifierStart(c) {
                let start = index
                index = identifierEnd(units, from: index)
                let word = text(units, start, index)
                let isFirst = firstWordOfLine == nil
                if isFirst { firstWordOfLine = word }
                let after = skipSpaces(from: index)
                if word == "event", unit(after) == dot, let next = unit(after + 1), isIdentifierStart(next) {
                    index = identifierEnd(units, from: after + 1)
                    add(.eventField, start, index)
                } else if unit(index) == dot, let next = unit(index + 1), isIdentifierStart(next) {
                    // `Slot.value`, `Slot.value.rule` or `Slot.Event`.
                    var end = identifierEnd(units, from: index + 1)
                    if unit(end) == dot, let next = unit(end + 1), isIdentifierStart(next) {
                        end = identifierEnd(units, from: end + 1)
                    }
                    index = end
                    add(.reference, start, end)
                } else if unit(after) == openParen {
                    add(.function, start, index)
                } else if firstWordOfLine == "step" || firstWordOfLine == "timeunit", !isFirst {
                    add(.name, start, index)  // a unit
                } else if previousWord == "as" {
                    add(.name, start, index)  // a kind of value
                } else if FormulaVocabulary.keywords.contains(word) && (word != "step" || isFirst) {
                    add(.keyword, start, index)
                } else if word == "fit", firstWordOfLine == "param" || firstWordOfLine == "init",
                          isFlag(units, start: start, end: index) {
                    add(.keyword, start, index)
                } else if FormulaVocabulary.optionWords.contains(word), isOption(units, start: start, end: index) {
                    add(.keyword, start, index)
                } else if FormulaVocabulary.builtins.contains(where: { $0.name == word }) {
                    add(.builtin, start, index)
                } else {
                    add(.name, start, index)
                }
                previousWord = word
                continue
            } else {
                let start = index
                index += 1
                if let next = unit(index), twoCharacterSymbols.contains([c, next]) { index += 1 }
                add(.symbol, start, index)
            }
            if c != 10, c != 32, c != 9, c != 13 { previousWord = nil }
        }
        return tokens
    }

    /// `range`, `by`, `label` and `as` are options when a value follows them, not when they're
    /// names in an expression (`range * 2`).
    private static func isOption(_ units: [UInt16], start: Int, end: Int) -> Bool {
        var before = start - 1
        while before >= 0, units[before] == 32 || units[before] == 9 { before -= 1 }
        if before >= 0, operatorUnits.contains(units[before]) { return false }
        var after = end
        while after < units.count, units[after] == 32 || units[after] == 9 { after += 1 }
        guard after < units.count else { return false }
        let next = units[after]
        return isDigit(next) || next == minus || next == quote || isIdentifierStart(next)
    }

    /// `fit` takes no value, so it's an option when it doesn't follow an operator and ends the line
    /// or comes before a comment or another option.
    private static func isFlag(_ units: [UInt16], start: Int, end: Int) -> Bool {
        var before = start - 1
        while before >= 0, units[before] == 32 || units[before] == 9 { before -= 1 }
        if before >= 0, operatorUnits.contains(units[before]) { return false }
        var after = end
        while after < units.count, units[after] == 32 || units[after] == 9 || units[after] == 13 { after += 1 }
        guard after < units.count else { return true }
        let next = units[after]
        return next == 10 || next == hash || next == slash || isIdentifierStart(next)
    }

    private static let hash: UInt16 = 35, slash: UInt16 = 47, quote: UInt16 = 34, dot: UInt16 = 46
    private static let percent: UInt16 = 37, openBracket: UInt16 = 91, closeBracket: UInt16 = 93
    private static let openParen: UInt16 = 40, minus: UInt16 = 45, letterT: UInt16 = 116
    private static let operatorUnits: Set<UInt16> = Set("+-*/^(,=<>".utf16)
    private static let twoCharacterSymbols: Set<[UInt16]> = Set(["+=", "-=", "*=", "/=", "<=", ">=", "==", "!=", ".."].map { Array($0.utf16) })

    /// The end of `[t]` or `[t-1]` starting at `start`, or nil when it isn't one.
    private static func lagEnd(_ units: [UInt16], from start: Int) -> Int? {
        var index = start + 1
        func skip() { while index < units.count, units[index] == 32 { index += 1 } }
        skip()
        guard index < units.count, units[index] == letterT else { return nil }
        index += 1
        skip()
        if index < units.count, units[index] == minus {
            index += 1
            skip()
            guard index < units.count, isDigit(units[index]) else { return nil }
            while index < units.count, isDigit(units[index]) { index += 1 }
            skip()
        }
        guard index < units.count, units[index] == closeBracket else { return nil }
        return index + 1
    }
}

// MARK: Shared scanning helpers

func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

/// Letters, `_`, and anything outside ASCII (letters in other scripts).
func isIdentifierStart(_ unit: UInt16) -> Bool {
    (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit >= 0x80
}

func isIdentifierPart(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }

func identifierEnd(_ units: [UInt16], from start: Int) -> Int {
    var index = start
    while index < units.count, isIdentifierPart(units[index]) { index += 1 }
    return index
}

func numberEnd(_ units: [UInt16], from start: Int) -> Int {
    var index = start
    while index < units.count, isDigit(units[index]) || units[index] == 95 { index += 1 }
    if index + 1 < units.count, units[index] == 46, isDigit(units[index + 1]) {
        index += 1
        while index < units.count, isDigit(units[index]) || units[index] == 95 { index += 1 }
    }
    if index < units.count, units[index] == 101 || units[index] == 69 {  // e or E
        var next = index + 1
        if next < units.count, units[next] == 43 || units[next] == 45 { next += 1 }
        if next < units.count, isDigit(units[next]) {
            index = next
            while index < units.count, isDigit(units[index]) { index += 1 }
        }
    }
    return index
}

func text(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
    String(decoding: units[start..<end], as: UTF16.self)
}

// MARK: Completion

/// Another slot, as completion and the insert palette offer it.
public struct FormulaSlotSummary: Sendable, Hashable {
    public let name: String
    /// Values other slots can read, with their labels.
    public let values: [(name: String, label: String)]
    /// Kinds of event it sends.
    public let events: [String]

    public init(name: String, values: [(name: String, label: String)], events: [String]) {
        self.name = name
        self.values = values
        self.events = events
    }

    public static func == (a: FormulaSlotSummary, b: FormulaSlotSummary) -> Bool {
        a.name == b.name && a.values.map(\.name) == b.values.map(\.name) && a.values.map(\.label) == b.values.map(\.label)
            && a.events == b.events
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(values.map(\.name))
        hasher.combine(events)
    }
}

public struct FormulaCompletion: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable, Comparable {
        case variable, parameter, eventField, slotValue, slotEvent, rule, slot, builtin, function, keyword, unit, quantity

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(kind.rawValue):\(text)" }
    /// What's inserted, e.g. "min()" or "Climate.".
    public let text: String
    /// What the list shows, e.g. "min(a, b, …)".
    public let label: String
    public let detail: String
    public let kind: Kind
    /// How far back from the end of `text` the caret goes: 1 puts it inside "min()".
    public let caretBack: Int

    public init(text: String, label: String, detail: String, kind: Kind, caretBack: Int = 0) {
        self.text = text
        self.label = label
        self.detail = detail
        self.kind = kind
        self.caretBack = caretBack
    }
}

public enum FormulaCompleter {
    /// What could go at `cursor`: the stretch of text a choice replaces, and the choices.
    public static func complete(_ source: String, at cursor: Int, slots: [FormulaSlotSummary],
                                ownName: String? = nil) -> (range: NSRange, items: [FormulaCompletion]) {
        let units = Array(source.utf16)
        let cursor = min(max(cursor, 0), units.count)
        var start = cursor
        while start > 0, isIdentifierPart(units[start - 1]) { start -= 1 }
        let range = NSRange(location: start, length: cursor - start)
        let prefix = text(units, start, cursor)
        if let first = prefix.utf16.first, isDigit(first) { return (range, []) }

        var lineStart = start
        while lineStart > 0, units[lineStart - 1] != 10 { lineStart -= 1 }
        let lineBefore = text(units, lineStart, start)
        if isInCommentOrText(lineBefore) { return (range, []) }
        let words = lineBefore.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        let firstWord = words.first
        let otherSlots = slots.filter { $0.name != ownName }

        var items: [FormulaCompletion] = []
        if start > 0, units[start - 1] == 46 {
            // After a dot: `Slot.`, `Slot.value.` or `event.`.
            let firstEnd = start - 1
            var firstStart = firstEnd
            while firstStart > 0, isIdentifierPart(units[firstStart - 1]) { firstStart -= 1 }
            let before = text(units, firstStart, firstEnd)
            var outer: String?
            if firstStart > 0, units[firstStart - 1] == 46 {
                var outerStart = firstStart - 1
                while outerStart > 0, isIdentifierPart(units[outerStart - 1]) { outerStart -= 1 }
                outer = text(units, outerStart, firstStart - 1)
            }
            if let outer, otherSlots.contains(where: { $0.name == outer }) {
                items = FormulaVocabulary.rules.map {
                    FormulaCompletion(text: $0.name, label: $0.name, detail: $0.summary, kind: .rule)
                }
            } else if before == "event" {
                items = [FormulaCompletion(text: "amount", label: "amount", detail: "The event's amount", kind: .eventField)]
            } else if let slot = otherSlots.first(where: { $0.name == before }) {
                items = slot.values.map {
                    FormulaCompletion(text: $0.name, label: $0.name, detail: $0.label == $0.name ? "\(slot.name)'s value" : $0.label,
                                      kind: .slotValue)
                }
                if firstWord == "on" {
                    items += slot.events.map {
                        FormulaCompletion(text: $0, label: $0, detail: "An event \(slot.name) sends", kind: .slotEvent)
                    }
                }
            }
        } else if words.isEmpty {
            // The start of a line: a statement, or a value to define.
            items = FormulaVocabulary.statements.map {
                FormulaCompletion(text: $0.name + " ", label: $0.name, detail: $0.usage, kind: .keyword)
            }
            let declared = declaredNames(in: source)
            items += declared.variables.map {
                FormulaCompletion(text: $0 + "[t] = ", label: $0 + "[t] =", detail: "Define \($0) each step", kind: .variable)
            }
        } else if (firstWord == "step" || firstWord == "timeunit") {
            items = FormulaVocabulary.units.map { FormulaCompletion(text: $0, label: $0, detail: "Time unit", kind: .unit) }
        } else if words.last == "as", lineBefore.hasSuffix(" ") {
            items = FormulaVocabulary.quantities.map {
                FormulaCompletion(text: $0, label: $0, detail: "How the value is written", kind: .quantity)
            }
        } else {
            let declared = declaredNames(in: source)
            items += declared.variables.map { FormulaCompletion(text: $0, label: $0, detail: "Value in this formula", kind: .variable) }
            items += declared.parameters.map { FormulaCompletion(text: $0, label: $0, detail: "Parameter", kind: .parameter) }
            items += otherSlots.map {
                FormulaCompletion(text: $0.name + ".", label: $0.name, detail: "Another slot's values", kind: .slot)
            }
            if firstWord == "on" {
                items.append(FormulaCompletion(text: "event.", label: "event", detail: "The event being handled", kind: .eventField))
            }
            items += FormulaVocabulary.functions.map {
                FormulaCompletion(text: $0.name + "()", label: $0.usage, detail: $0.summary, kind: .function, caretBack: 1)
            }
            items += FormulaVocabulary.builtins.map {
                FormulaCompletion(text: $0.name, label: $0.name, detail: $0.summary, kind: .builtin)
            }
            var keywords = ["and", "or", "not"]
            if firstWord == "when" { keywords.append("emit") }
            items += keywords.map { FormulaCompletion(text: $0 + " ", label: $0, detail: "Keyword", kind: .keyword) }
        }

        let lower = prefix.lowercased()
        let matching = items.filter { lower.isEmpty || $0.text.lowercased().hasPrefix(lower) }
        let sorted = matching.sorted { a, b in
            let aExact = a.text.hasPrefix(prefix), bExact = b.text.hasPrefix(prefix)
            if aExact != bExact { return aExact }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.text.lowercased() < b.text.lowercased()
        }
        // Nothing to offer when the only choice is what's already typed.
        if sorted.count == 1, sorted[0].text == prefix { return (range, []) }
        var seen = Set<String>()
        return (range, sorted.filter { seen.insert($0.text).inserted })
    }

    /// Whether the end of `line` is inside a comment or a quoted label.
    private static func isInCommentOrText(_ line: String) -> Bool {
        var inText = false
        var previous: Character?
        for character in line {
            if character == "\"" { inText.toggle() }
            if !inText && (character == "#" || (character == "/" && previous == "/")) { return true }
            previous = character
        }
        return inText
    }

    /// Parameters and values declared in a formula, found line by line so it works while the
    /// formula is half written.
    public static func declaredNames(in source: String) -> (parameters: [String], variables: [String]) {
        var parameters: [String] = [], variables: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
            guard let first = words.first else { continue }
            if first == "param", words.count > 1 {
                if !parameters.contains(words[1]) { parameters.append(words[1]) }
            } else if first == "init", words.count > 1 {
                if !variables.contains(words[1]) { variables.append(words[1]) }
            } else if trimmed.hasPrefix("d"), let slash = trimmed.range(of: "/dt"), trimmed[slash.upperBound...].trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<slash.lowerBound])
                if !name.isEmpty, !variables.contains(name) { variables.append(name) }
            } else if !FormulaVocabulary.keywords.contains(first), let equals = trimmed.firstIndex(of: "="),
                      trimmed[trimmed.index(after: equals)...].first != "=" {
                let left = trimmed[..<equals].replacingOccurrences(of: " ", with: "")
                if left == first || left == first + "[t]", !variables.contains(first) { variables.append(first) }
            }
        }
        return (parameters, variables)
    }
}

// MARK: Diagnoses and fixes

/// A change to the formula that fixes a problem, offered as a button.
public struct FormulaFix: Sendable, Hashable {
    public let title: String
    /// The whole formula with the fix made.
    public let source: String

    public init(title: String, source: String) {
        self.title = title
        self.source = source
    }
}

/// A problem with a formula, where it is, and how to fix it.
public struct FormulaDiagnosis: Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case error, warning }
    public let severity: Severity
    public let title: String
    public let detail: String?
    /// 1-based line, when there is one.
    public let line: Int?
    /// What to underline.
    public let range: NSRange?
    public let fixes: [FormulaFix]

    public init(severity: Severity, title: String, detail: String? = nil, line: Int? = nil, range: NSRange? = nil, fixes: [FormulaFix] = []) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.line = line
        self.range = range
        self.fixes = fixes
    }
}

public enum FormulaDiagnoser {
    /// Explains a mistake the formula language found, with fixes where there's an obvious one.
    public static func diagnose(_ error: FormulaError, in source: String) -> FormulaDiagnosis {
        switch error {
        case .unknownName(let name, let line):
            let declared = FormulaCompleter.declaredNames(in: source)
            let candidates = declared.parameters + declared.variables + FormulaVocabulary.builtins.map(\.name)
            let ranges = occurrences(of: name, kinds: [.name, .builtin], onLine: line, in: source)
            var fixes: [FormulaFix] = []
            if let better = closest(to: name, in: candidates.filter { $0 != name }) {
                fixes.append(FormulaFix(title: "Use \(better)", source: replacing(ranges, with: better, in: source)))
            }
            return FormulaDiagnosis(severity: .error, title: "\(name) isn't defined",
                                    detail: fixes.isEmpty ? "Add param \(name) = … or \(name)[t] = …, or check the spelling." : nil,
                                    line: line, range: ranges.first ?? lineRange(line, in: source), fixes: fixes)
        case .unknownFunction(let name, let line):
            let ranges = occurrences(of: name, kinds: [.function], onLine: line, in: source)
            var fixes: [FormulaFix] = []
            if let better = closest(to: name, in: FormulaVocabulary.functions.map(\.name)) {
                fixes.append(FormulaFix(title: "Use \(better)", source: replacing(ranges, with: better, in: source)))
            }
            return FormulaDiagnosis(severity: .error, title: "There's no function called \(name)", line: line,
                                    range: ranges.first ?? lineRange(line, in: source), fixes: fixes)
        case .wrongArgumentCount(let function, let expected, let line):
            let usage = FormulaVocabulary.functions.first { $0.name == function }?.usage
            return FormulaDiagnosis(severity: .error, title: "\(function) takes \(expected)", detail: usage.map { "Write it as \($0)." },
                                    line: line, range: occurrences(of: function, kinds: [.function], onLine: line, in: source).first
                                        ?? lineRange(line, in: source))
        case .sameStepLoop(let names):
            guard names.count >= 2 else { return general(error, in: source) }
            let (first, second) = (names[0], names[1])
            let chain = names.joined(separator: " → ")
            // Read the second from the previous step on the line that defines the first.
            let line = definitionLine(of: first, in: source)
            var fixes: [FormulaFix] = []
            var range: NSRange?
            if let line {
                let ranges = occurrences(of: second, kinds: [.name], onLine: line, in: source, afterEquals: true)
                    .filter { !isFollowedByLag($0, in: source) }
                if let target = ranges.first {
                    range = target
                    fixes.append(FormulaFix(title: "Use \(second)[t-1]", source: inserting("[t-1]", at: NSMaxRange(target), in: source)))
                }
            }
            if first == second {
                return FormulaDiagnosis(
                    severity: .error, title: "\(first) uses its own value from the same step",
                    detail: "Use \(first)[t-1] for its value at the previous step.",
                    line: line, range: range ?? line.flatMap { lineRange($0, in: source) }, fixes: fixes)
            }
            return FormulaDiagnosis(
                severity: .error, title: "\(first) and \(second) depend on each other within the same step",
                detail: "\(chain). Read one of them from the previous step, so each step can finish.",
                line: line, range: range ?? line.flatMap { lineRange($0, in: source) }, fixes: fixes)
        default:
            return general(error, in: source)
        }
    }

    private static func general(_ error: FormulaError, in source: String) -> FormulaDiagnosis {
        FormulaDiagnosis(severity: .error, title: error.message, line: error.line,
                         range: error.line.flatMap { lineRange($0, in: source) })
    }

    /// The closest of `candidates` to a misspelt `name`: the same apart from case, or at most
    /// two letters different (one for short names).
    public static func closest(to name: String, in candidates: [String]) -> String? {
        if let same = candidates.first(where: { $0.lowercased() == name.lowercased() }) { return same }
        let limit = name.count <= 4 ? 1 : 2
        let scored = candidates.map { ($0, distance(name.lowercased(), $0.lowercased())) }.filter { $0.1 <= limit }
        return scored.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }

    /// Edit distance (insertions, deletions and substitutions).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Each line's range, without its line break. Line 1 is at index 0.
    public static func lineRanges(_ source: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for (offset, unit) in source.utf16.enumerated() where unit == 10 {
            ranges.append(NSRange(location: start, length: offset - start))
            start = offset + 1
        }
        ranges.append(NSRange(location: start, length: source.utf16.count - start))
        return ranges
    }

    /// A line's text without the space around it, for underlining.
    public static func lineRange(_ line: Int, in source: String) -> NSRange? {
        let lines = lineRanges(source)
        guard line >= 1, line <= lines.count else { return nil }
        let range = lines[line - 1]
        let text = (source as NSString).substring(with: range)
        let leading = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let trimmed = text.trimmingCharacters(in: .whitespaces).utf16.count
        return NSRange(location: range.location + leading, length: max(trimmed, 0))
    }

    /// Where a word appears as a token on a line.
    static func occurrences(of word: String, kinds: Set<FormulaTokenKind>, onLine line: Int, in source: String,
                            afterEquals: Bool = false) -> [NSRange] {
        let lines = lineRanges(source)
        guard line >= 1, line <= lines.count else { return [] }
        let lineRange = lines[line - 1]
        let tokens = FormulaHighlighter.tokens(in: source).filter { NSLocationInRange($0.range.location, lineRange) || ($0.range.location == NSMaxRange(lineRange) && lineRange.length == 0) }
        var pastEquals = !afterEquals
        var found: [NSRange] = []
        for token in tokens {
            if token.kind == .symbol, token.text == "=" || token.text.hasSuffix("=") { pastEquals = true; continue }
            if pastEquals, kinds.contains(token.kind), token.text == word { found.append(token.range) }
        }
        return found
    }

    /// Where references to another slot appear: each `Slot.value…` token naming `slot`.
    public static func references(toSlot slot: String, in source: String) -> [FormulaToken] {
        FormulaHighlighter.tokens(in: source).filter { $0.kind == .reference && $0.text.hasPrefix(slot + ".") }
    }

    /// The line that defines a value: `name[t] = …`, `name = …` or `dname/dt = …`.
    static func definitionLine(of name: String, in source: String) -> Int? {
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            if trimmed.hasPrefix(name + "[t]=") || (trimmed.hasPrefix(name + "=") && !trimmed.hasPrefix(name + "=="))
                || trimmed.hasPrefix("d\(name)/dt=") {
                return index + 1
            }
        }
        return nil
    }

    static func isFollowedByLag(_ range: NSRange, in source: String) -> Bool {
        let units = Array(source.utf16)
        var index = NSMaxRange(range)
        while index < units.count, units[index] == 32 { index += 1 }
        return index < units.count && units[index] == 91
    }

    /// The formula with each range replaced by `text`.
    public static func replacing(_ ranges: [NSRange], with text: String, in source: String) -> String {
        let string = NSMutableString(string: source)
        for range in ranges.sorted(by: { $0.location > $1.location }) { string.replaceCharacters(in: range, with: text) }
        return string as String
    }

    public static func inserting(_ text: String, at location: Int, in source: String) -> String {
        let string = NSMutableString(string: source)
        string.insert(text, at: location)
        return string as String
    }
}
