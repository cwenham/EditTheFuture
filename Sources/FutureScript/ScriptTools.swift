import Foundation

// Tools for the Formula tab when it edits a script (docs/DESIGN.md, 6.4): colouring, completion,
// and finding references to other slots. They work on half-written text.

public enum ScriptTokenKind: String, Sendable, Hashable {
    case keyword, number, string, comment
    /// The script API: `every`, `param`, `emit`…
    case api
    /// The language's own functions and modules: `math`, `print`, `len`…
    case library
    /// Another slot's value or event, inside a string: `"Climate.temp"`.
    case reference
    /// A field of the state, time or an event: the `balance` in `s.balance`.
    case field
    case name
    case symbol
}

public struct ScriptToken: Sendable, Hashable {
    public let kind: ScriptTokenKind
    /// In UTF-16 units, like NSString.
    public let range: NSRange
    public let text: String
}

/// The script API, for completion and the insert palette.
public enum ScriptVocabulary {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let summary: String
        /// What the palette inserts in each language, and how far back from its end the caret goes.
        public let lua: (text: String, caretBack: Int)
        public let python: (text: String, caretBack: Int)

        public func insertion(_ language: ScriptLanguage) -> (text: String, caretBack: Int) {
            language == .lua ? lua : python
        }

        public static func == (a: Entry, b: Entry) -> Bool { a.name == b.name }
        public func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    public static let declarations: [Entry] = [
        Entry(name: "every", summary: "How often the script steps, like \"1 month\"",
              lua: ("every \"1 month\"", 0), python: ("every(\"1 month\")", 0)),
        Entry(name: "param", summary: "A parameter, which set events can change",
              lua: ("param(\"name\", 0)", 0), python: ("param(\"name\", 0)", 0)),
        Entry(name: "init", summary: "A value the script keeps, and its starting value",
              lua: ("init(\"name\", 0)", 0), python: ("init(\"name\", 0)", 0)),
        Entry(name: "output", summary: "A value the script works out each step",
              lua: ("output(\"name\")", 0), python: ("output(\"name\")", 0)),
        Entry(name: "input", summary: "Another slot's value, read as s.name",
              lua: ("input(\"name\", \"Slot.value\")", 0), python: ("input(\"name\", \"Slot.value\")", 0)),
        Entry(name: "emits", summary: "An event kind the script can send",
              lua: ("emits \"Kind\"", 0), python: ("emits(\"Kind\")", 0)),
        Entry(name: "on", summary: "Runs for each event of a kind",
              lua: ("on(\"deposit\", function(s, e, t)\n  \nend)", 5),
              python: ("@on(\"deposit\")\ndef deposit(s, e, t):\n    ", 0)),
        Entry(name: "emit", summary: "Sends an event, in step or an on handler",
              lua: ("emit(\"Kind\", { amount = 1 })", 0), python: ("emit(\"Kind\", amount=1)", 0)),
        Entry(name: "timeunit", summary: "The unit for t.dt, like \"year\"",
              lua: ("timeunit \"year\"", 0), python: ("timeunit(\"year\")", 0)),
        Entry(name: "step", summary: "The function that works out each step",
              lua: ("function step(s, t)\n  \nend", 4), python: ("def step(s, t):\n    ", 0)),
        Entry(name: "start", summary: "Runs once at the start, after the starting values are set",
              lua: ("function start(s, t)\n  \nend", 4), python: ("def start(s, t):\n    ", 0)),
    ]

    /// Fields of `t`.
    public static let time: [(name: String, summary: String)] = [
        ("index", "The step's number; the start is 0"),
        ("year", "The year, with a fraction for the time of year"),
        ("month", "The month, 1 to 12"),
        ("day", "The day of the month"),
        ("dayOfYear", "The day of the year, from 1"),
        ("days", "Days since the scenario started"),
        ("dt", "The step's length, in the time unit"),
        ("date", "The date as text, like \"2031-06-01\""),
        ("events", "This step's events"),
        ("random", "A random number from 0 to 1: t.random()"),
        ("normal", "A random number from a bell curve: t.normal(mean, sd)"),
        ("emit", "Sends an event, like emit"),
    ]

    /// Fields every event has, besides its own.
    public static let eventFields: [(name: String, summary: String)] = [
        ("kind", "The event's kind"),
        ("slot", "The slot that sent it, for another slot's events"),
        ("date", "When it happened, like \"2031-06-01\""),
    ]

    static let apiNames: Set<String> = ["every", "timeunit", "param", "init", "output", "input", "emits", "on", "emit"]

    static func keywords(_ language: ScriptLanguage) -> Set<String> {
        switch language {
        case .lua:
            return ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local",
                    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "global"]
        case .python:
            return ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                    "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"]
        }
    }

    static func library(_ language: ScriptLanguage) -> Set<String> {
        switch language {
        case .lua:
            return ["math", "string", "table", "utf8", "coroutine", "print", "pairs", "ipairs", "tostring", "tonumber",
                    "type", "select", "error", "assert", "pcall", "xpcall", "require", "load", "next", "rawget", "rawset",
                    "rawequal", "rawlen", "setmetatable", "getmetatable", "unpack"]
        case .python:
            return ["print", "len", "range", "abs", "min", "max", "sum", "round", "int", "float", "str", "bool", "list",
                    "dict", "tuple", "set", "enumerate", "zip", "sorted", "reversed", "map", "filter", "any", "all",
                    "isinstance", "pow", "divmod", "math", "random", "statistics", "self"]
        }
    }
}

public enum ScriptHighlighter {
    /// Tokens to colour. Strings that name a value or event of one of `slots`, like "Climate.temp",
    /// are references; with no slots given, any "Name.name" string is.
    public static func tokens(in source: String, language: ScriptLanguage, slots: Set<String>? = nil) -> [ScriptToken] {
        let units = Array(source.utf16)
        var tokens: [ScriptToken] = []
        let keywords = ScriptVocabulary.keywords(language), library = ScriptVocabulary.library(language)
        var i = 0
        func add(_ kind: ScriptTokenKind, _ start: Int, _ end: Int) {
            tokens.append(ScriptToken(kind: kind, range: NSRange(location: start, length: end - start), text: text(units, start, end)))
        }
        func at(_ offset: Int) -> UInt16? { i + offset < units.count ? units[i + offset] : nil }

        while i < units.count {
            let c = units[i]
            let start = i
            // Comments.
            if language == .lua, c == dash, at(1) == dash {
                if at(2) == openBracket, let level = longBracketLevel(units, i + 2) {
                    i = longBracketEnd(units, from: i + 2, level: level)
                } else {
                    while i < units.count && units[i] != newline { i += 1 }
                }
                add(.comment, start, i)
                continue
            }
            if language == .python, c == hash {
                while i < units.count && units[i] != newline { i += 1 }
                add(.comment, start, i)
                continue
            }
            // Strings.
            if language == .lua, c == openBracket, let level = longBracketLevel(units, i) {
                i = longBracketEnd(units, from: i, level: level)
                add(.string, start, i)
                continue
            }
            var quoteStart = i
            if language == .python, isLetter(c), let prefixLength = stringPrefixLength(units, i) {
                quoteStart = i + prefixLength
            }
            if quoteStart < units.count, units[quoteStart] == doubleQuote || units[quoteStart] == singleQuote {
                let quote = units[quoteStart]
                let triple = language == .python && quoteStart + 2 < units.count
                    && units[quoteStart + 1] == quote && units[quoteStart + 2] == quote
                i = quoteStart + (triple ? 3 : 1)
                let contentStart = i
                var contentEnd = units.count
                while i < units.count {
                    if units[i] == backslash { i += 2; continue }
                    if triple {
                        if units[i] == quote && i + 2 < units.count && units[i + 1] == quote && units[i + 2] == quote {
                            contentEnd = i
                            i += 3
                            break
                        }
                    } else if units[i] == quote {
                        contentEnd = i
                        i += 1
                        break
                    } else if units[i] == newline {
                        contentEnd = i
                        break
                    }
                    i += 1
                }
                i = min(i, units.count)
                contentEnd = min(contentEnd, units.count)
                let content = text(units, contentStart, contentEnd)
                if isReference(content, slots: slots) {
                    add(.string, start, contentStart)
                    add(.reference, contentStart, contentEnd)
                    if contentEnd < i { add(.string, contentEnd, i) }
                } else {
                    add(.string, start, i)
                }
                continue
            }
            // Numbers.
            if isDigit(c) || (c == dot && at(1).map(isDigit) == true) {
                i += 1
                while i < units.count {
                    let d = units[i]
                    if isDigit(d) || d == dot || isLetter(d) || d == underscore { i += 1; continue }
                    if (d == plus || d == dash), let previous = Optional(units[i - 1]), previous == 101 || previous == 69 { i += 1; continue }
                    break
                }
                add(.number, start, i)
                continue
            }
            // Names.
            if isLetter(c) || c == underscore {
                while i < units.count && (isLetter(units[i]) || isDigit(units[i]) || units[i] == underscore) { i += 1 }
                let word = text(units, start, i)
                let afterDot = start > 0 && units[start - 1] == dot
                if afterDot, start >= 2, let owner = previousWord(units, before: start - 1), ["s", "t", "e"].contains(owner) {
                    add(.field, start, i)
                } else if afterDot {
                    add(.name, start, i)
                } else if keywords.contains(word) {
                    add(.keyword, start, i)
                } else if ScriptVocabulary.apiNames.contains(word) {
                    add(.api, start, i)
                } else if library.contains(word) {
                    add(.library, start, i)
                } else {
                    add(.name, start, i)
                }
                continue
            }
            if c == space || c == tab || c == newline || c == carriageReturn {
                i += 1
                continue
            }
            i += 1
            add(.symbol, start, i)
        }
        return tokens
    }

    /// "Climate.temp", "Climate.temp.mean[t-1]", "FireRisk.OverCapacity".
    static func isReference(_ content: String, slots: Set<String>?) -> Bool {
        guard let reference = ScriptShape.reference(content) ?? ScriptShape.subscription(content).map({
            .init(slot: $0.slot, variable: $0.kind) }) else { return false }
        return slots?.contains(reference.slot) ?? true
    }
}

/// A choice the completion list offers.
public struct ScriptCompletion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case parameter, variable, input, field, slot, slotValue, slotEvent, api, library, keyword
    }

    /// What's inserted, e.g. "balance" or "Climate.".
    public let text: String
    public let label: String
    public let detail: String
    public let kind: Kind
    public let caretBack: Int
}

/// Another slot, as completion offers it.
public struct ScriptSlotSummary: Sendable, Hashable {
    public let name: String
    public let values: [String]
    public let events: [String]

    public init(name: String, values: [String], events: [String]) {
        self.name = name
        self.values = values
        self.events = events
    }
}

public enum ScriptCompleter {
    /// What could go at `cursor` (in UTF-16 units): the stretch of text a choice replaces, and the choices.
    public static func complete(_ source: String, at cursor: Int, language: ScriptLanguage,
                                slots: [ScriptSlotSummary]) -> (range: NSRange, items: [ScriptCompletion]) {
        let units = Array(source.utf16)
        let cursor = min(max(0, cursor), units.count)
        var start = cursor
        while start > 0 && (isLetter(units[start - 1]) || isDigit(units[start - 1]) || units[start - 1] == underscore) { start -= 1 }
        let prefix = text(units, start, cursor)
        let range = NSRange(location: start, length: cursor - start)
        func matching(_ items: [ScriptCompletion]) -> [ScriptCompletion] {
            let lower = prefix.lowercased()
            return items.filter { $0.text.lowercased().hasPrefix(lower) && $0.text != prefix }
        }

        // Inside a string: other slots, then their values and events.
        if let quote = openQuote(units, before: start) {
            let typed = text(units, quote + 1, start)
            if typed.isEmpty {
                return (range, matching(slots.map {
                    ScriptCompletion(text: $0.name + ".", label: $0.name, detail: "Slot", kind: .slot, caretBack: 0) }))
            }
            let parts = typed.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 2, parts[1].isEmpty, let slot = slots.first(where: { $0.name == parts[0] }) {
                let values = slot.values.map { ScriptCompletion(text: $0, label: $0, detail: "\(slot.name)'s value", kind: .slotValue, caretBack: 0) }
                let events = slot.events.map { ScriptCompletion(text: $0, label: $0, detail: "\(slot.name)'s event", kind: .slotEvent, caretBack: 0) }
                return (range, matching(values + events))
            }
            return (range, [])
        }

        // After s., t. or e.
        if start > 0, units[start - 1] == dot, let owner = previousWord(units, before: start - 1) {
            switch owner {
            case "s":
                let declared = declaredNames(in: source, language: language)
                var items = declared.parameters.map { ScriptCompletion(text: $0, label: $0, detail: "Parameter", kind: .parameter, caretBack: 0) }
                items += declared.variables.map { ScriptCompletion(text: $0, label: $0, detail: "Value", kind: .variable, caretBack: 0) }
                items += declared.inputs.map { ScriptCompletion(text: $0, label: $0, detail: "Input from another slot", kind: .input, caretBack: 0) }
                return (range, matching(items))
            case "t":
                return (range, matching(ScriptVocabulary.time.map {
                    let call = $0.name == "random" || $0.name == "normal" || $0.name == "emit"
                    return ScriptCompletion(text: $0.name + (call ? "()" : ""), label: $0.name, detail: $0.summary, kind: .field, caretBack: call ? 1 : 0)
                }))
            case "e":
                return (range, matching(ScriptVocabulary.eventFields.map {
                    ScriptCompletion(text: $0.name, label: $0.name, detail: $0.summary, kind: .field, caretBack: 0) }))
            default:
                return (range, [])
            }
        }

        guard !prefix.isEmpty else { return (range, []) }
        var items = ScriptVocabulary.declarations.filter { ScriptVocabulary.apiNames.contains($0.name) }.map {
            ScriptCompletion(text: $0.name, label: $0.name, detail: $0.summary, kind: .api, caretBack: 0)
        }
        items += ScriptVocabulary.library(language).sorted().map { ScriptCompletion(text: $0, label: $0, detail: language.title, kind: .library, caretBack: 0) }
        items += ScriptVocabulary.keywords(language).sorted().map { ScriptCompletion(text: $0, label: $0, detail: "Keyword", kind: .keyword, caretBack: 0) }
        return (range, matching(items))
    }

    /// Names the script declares, found without running it.
    public static func declaredNames(in source: String, language: ScriptLanguage) -> (parameters: [String], variables: [String], inputs: [String]) {
        var parameters: [String] = [], variables: [String] = [], inputs: [String] = []
        let pattern = #"\b(param|init|output|input)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], [], []) }
        let ns = source as NSString
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 1)), name = ns.substring(with: match.range(at: 2))
            switch kind {
            case "param": if !parameters.contains(name) { parameters.append(name) }
            case "input": if !inputs.contains(name) { inputs.append(name) }
            default: if !variables.contains(name) { variables.append(name) }
            }
        }
        return (parameters, variables, inputs)
    }

    /// Where the script names another slot inside a string, like "Climate.temp": the range of
    /// each reference without its quotes.
    public static func references(toSlot slot: String, in source: String, language: ScriptLanguage) -> [(range: NSRange, text: String)] {
        ScriptHighlighter.tokens(in: source, language: language, slots: [slot])
            .filter { $0.kind == .reference }
            .map { ($0.range, $0.text) }
    }

    /// The line (from 1) holding a UTF-16 offset.
    public static func line(of location: Int, in source: String) -> Int {
        var line = 1
        for (index, unit) in source.utf16.enumerated() {
            if index >= location { break }
            if unit == newline { line += 1 }
        }
        return line
    }
}

// MARK: Helpers

private let newline: UInt16 = 10, carriageReturn: UInt16 = 13, space: UInt16 = 32, tab: UInt16 = 9
private let doubleQuote: UInt16 = 34, singleQuote: UInt16 = 39, backslash: UInt16 = 92
private let dash: UInt16 = 45, plus: UInt16 = 43, dot: UInt16 = 46, hash: UInt16 = 35, underscore: UInt16 = 95
private let openBracket: UInt16 = 91, closeBracket: UInt16 = 93, equals: UInt16 = 61

private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
private func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0xC0 }

private func text(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
    guard start < end else { return "" }
    return String(decoding: units[start..<end], as: UTF16.self)
}

/// The word just before a dot at `dot`: the `s` in `s.balance`.
private func previousWord(_ units: [UInt16], before dot: Int) -> String? {
    var start = dot
    while start > 0 && (isLetter(units[start - 1]) || isDigit(units[start - 1]) || units[start - 1] == underscore) { start -= 1 }
    guard start < dot else { return nil }
    if start > 0 && units[start - 1] == 46 { return nil }
    return text(units, start, dot)
}

/// Lua's long brackets: `[[` is level 0, `[==[` is level 2.
private func longBracketLevel(_ units: [UInt16], _ index: Int) -> Int? {
    guard index < units.count, units[index] == openBracket else { return nil }
    var level = 0, i = index + 1
    while i < units.count && units[i] == equals { level += 1; i += 1 }
    return i < units.count && units[i] == openBracket ? level : nil
}

private func longBracketEnd(_ units: [UInt16], from index: Int, level: Int) -> Int {
    var i = index + level + 2
    while i < units.count {
        if units[i] == closeBracket {
            var j = i + 1, count = 0
            while j < units.count && units[j] == equals { count += 1; j += 1 }
            if count == level && j < units.count && units[j] == closeBracket { return j + 1 }
        }
        i += 1
    }
    return units.count
}

/// Python's string prefixes: r, b, f, u, rb, br, fr, rf, in either case.
private func stringPrefixLength(_ units: [UInt16], _ index: Int) -> Int? {
    let letters: Set<UInt16> = [114, 82, 98, 66, 102, 70, 117, 85]
    var i = index
    while i < units.count && i - index < 2 && letters.contains(units[i]) { i += 1 }
    guard i > index, i < units.count, units[i] == doubleQuote || units[i] == singleQuote else { return nil }
    return i - index
}

/// Where the string the caret is in starts, if it's in one on this line.
private func openQuote(_ units: [UInt16], before index: Int) -> Int? {
    var lineStart = index
    while lineStart > 0 && units[lineStart - 1] != newline { lineStart -= 1 }
    var open: Int?
    var quote: UInt16 = 0
    var i = lineStart
    while i < index {
        let c = units[i]
        if let _ = open {
            if c == backslash { i += 2; continue }
            if c == quote { open = nil }
        } else if c == doubleQuote || c == singleQuote {
            open = i
            quote = c
        } else if c == hash || (c == dash && i + 1 < index && units[i + 1] == dash) {
            return nil
        }
        i += 1
    }
    return open
}
