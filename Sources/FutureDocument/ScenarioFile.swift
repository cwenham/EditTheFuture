import Foundation
import FutureEngine

/// What a saved scenario says (docs/DESIGN.md, 15.2): read from `scenario.md` by `ScenarioFormat`,
/// and written back by it.
public struct ScenarioFile: Sendable, Equatable {
    public var name: String
    public var start: Date
    /// nil for the engine's own seed.
    public var seed: UInt64?
    public var slots: [SlotFile]

    public init(name: String, start: Date, seed: UInt64? = nil, slots: [SlotFile] = []) {
        self.name = name
        self.start = start
        self.seed = seed
        self.slots = slots
    }
}

/// One slot's section of `scenario.md`.
public struct SlotFile: Sendable, Equatable {
    /// 0-based; the file writes it from 1, as the chips do.
    public var position: Int
    /// The name formulas use, e.g. "IndexFund".
    public var name: String
    /// The model's name, as the library calls it. Empty when the heading doesn't say.
    public var model: String
    public var language: ModelLanguage
    /// The model's text, exactly as the Formula tab shows it.
    public var source: String
    /// The variable the graph draws.
    public var shows: String?
    /// `number`, `percent`, `currency` or `temperature`.
    public var format: String?
    /// Hex, without the "#": "5AA9FF".
    public var color: String?
    /// The slot's own parameter and starting values, in place of the model's defaults.
    public var values: [String: Double]
    /// Values (and `set` event fields) with these names are written as percents: `4.5%`.
    public var percentNames: Set<String>
    public var events: [Event]
    public var rules: [RecurringEvent]
    public var readings: [ReadingSource]
    /// Why the slot can't run, such as a missing model. Read from the file; never written.
    public var problem: String?

    public init(position: Int, name: String, model: String = "", language: ModelLanguage = .formula, source: String = "",
                shows: String? = nil, format: String? = nil, color: String? = nil, values: [String: Double] = [:],
                percentNames: Set<String> = [], events: [Event] = [], rules: [RecurringEvent] = [],
                readings: [ReadingSource] = [], problem: String? = nil) {
        self.position = position
        self.name = name
        self.model = model
        self.language = language
        self.source = source
        self.shows = shows
        self.format = format
        self.color = color
        self.values = values
        self.percentNames = percentNames
        self.events = events
        self.rules = rules
        self.readings = readings
        self.problem = problem
    }
}

/// What a slot's model is written in: the language of its fenced block.
public enum ModelLanguage: String, Sendable, Equatable, CaseIterable {
    case formula = "etf"
    case lua
    case python

    /// The block's language, as written after the opening fence.
    public init?(fence: String) {
        switch fence.lowercased() {
        case "etf", "formula": self = .formula
        case "lua": self = .lua
        case "python", "py": self = .python
        default: return nil
        }
    }
}

/// Where a slot's readings come from (docs/DESIGN.md, 15.3 and 15.4).
public enum ReadingSource: Sendable, Equatable {
    /// A `csv` block in `scenario.md`.
    case inline(csv: String)
    /// A link to a CSV file, relative to the scenario folder.
    case csvFile(title: String, path: String)
    /// A link to a SQLite database, and the query that reads it.
    case database(title: String, path: String, query: String)
    /// Readings fetched from a public source, kept in a copy in `readings/` (15.8).
    case feed(FeedSpec)

    /// The feed, when this is one.
    public var feed: FeedSpec? {
        if case .feed(let spec) = self { return spec }
        return nil
    }
}

/// A mistake in `scenario.md`, with its line (from 1).
public struct FileProblem: Sendable, Equatable, CustomStringConvertible {
    public var line: Int?
    public var message: String
    /// The slot it's in, if any.
    public var slot: String?

    public init(line: Int?, message: String, slot: String? = nil) {
        self.line = line
        self.message = message
        self.slot = slot
    }

    public var description: String { (line.map { "Line \($0): " } ?? "") + message }
}

// MARK: Settings in brackets

/// A setting in a final pair of square brackets: `name: value`, or a single word.
struct Setting: Equatable, Sendable {
    var key: String
    /// nil for a single word.
    var value: String?

    var text: String {
        guard let value else { return Setting.quoted(key) }
        return "\(key): \(Setting.quoted(value))"
    }

    /// Text with commas, brackets or quotes in it goes in double quotes.
    static func quoted(_ text: String) -> String {
        guard text.contains(where: { ",[]\"".contains($0) }) || text != text.trimmingCharacters(in: .whitespaces)
        else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Splits `Label [a, b: c]` into the label and its settings. A line without a final bracket
    /// group has none. Returns nil when the brackets don't close.
    static func split(_ line: String) -> (label: String, settings: [Setting])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]") else { return (trimmed, []) }
        // Find the "[" that opens the final group, skipping quoted text.
        let characters = Array(trimmed)
        var inQuotes = false
        var opening: Int?
        var depth = 0
        var index = characters.count - 1
        while index >= 0 {
            let character = characters[index]
            if character == "\"" && (index == 0 || characters[index - 1] != "\\") { inQuotes.toggle() }
            if !inQuotes {
                if character == "]" && (index == 0 || characters[index - 1] != "\\") { depth += 1 }
                if character == "[" && (index == 0 || characters[index - 1] != "\\") {
                    depth -= 1
                    if depth == 0 { opening = index; break }
                }
            }
            index -= 1
        }
        guard let opening else { return nil }
        let label = String(characters[..<opening]).trimmingCharacters(in: .whitespaces)
        let inside = String(characters[(opening + 1)..<(characters.count - 1)])
        guard let settings = parseList(inside) else { return nil }
        return (label, settings)
    }

    /// `a, b: c, d: "x, y"`.
    static func parseList(_ text: String) -> [Setting]? {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuotes { escaped = true; continue }
            if character == "\"" { inQuotes.toggle(); current.append(character); continue }
            if character == "," && !inQuotes {
                items.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        guard !inQuotes else { return nil }
        items.append(current)
        var settings: [Setting] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let colon = Self.colon(in: trimmed) {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                settings.append(Setting(key: key, value: unquote(value)))
            } else {
                settings.append(Setting(key: unquote(trimmed), value: nil))
            }
        }
        return settings
    }

    /// The first colon outside quotes, when what's before it is a plain name.
    private static func colon(in text: String) -> String.Index? {
        guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("\"") else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        return isIdentifier(key) ? colon : nil
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}

// MARK: Event lines

/// One line of a slot's `### Events`: `2028-08-01 withdraw [amount: 6000]`, or a rule with
/// `every`, `until` and `count`.
enum EventLine {
    enum Parsed {
        case event(time: Date, kind: String, values: [String: Double])
        case rule(first: Date, kind: String, values: [String: Double], every: StepRate, until: Date?, count: Int?)
    }

    /// Reads a line without its list marker. Throws a message saying what's wrong.
    static func parse(_ text: String) throws -> Parsed {
        guard let (label, settings) = Setting.split(text) else { throw LineError("The brackets don't close.") }
        let words = label.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else {
            throw LineError("An event is a date, a kind, then its fields in brackets: 2028-08-01 withdraw [amount: 6000].")
        }
        guard let time = FileDate.parse(words[0]) else { throw LineError("“\(words[0])” isn't a date. Write dates like 2028-08-01.") }
        let kind = words[1]
        guard isIdentifier(kind) else { throw LineError("“\(kind)” isn't an event kind: use one word, like deposit.") }
        var values: [String: Double] = [:]
        var every: StepRate?
        var until: Date?
        var count: Int?
        for setting in settings {
            guard let value = setting.value else {
                if setting.key.first?.isNumber == true {
                    throw LineError("Inside brackets, write numbers without commas: 6000, not 6,000.")
                }
                throw LineError("“\(setting.key)” needs a value: \(setting.key): 100.")
            }
            switch setting.key {
            case "every":
                guard let rate = StepRate(text: value) else { throw LineError("“\(value)” isn't a time step. Write every: 1 month.") }
                every = rate
            case "until" where every != nil || settings.contains(where: { $0.key == "every" }):
                guard let date = FileDate.parse(value) else { throw LineError("“\(value)” isn't a date.") }
                until = date
            case "count" where every != nil || settings.contains(where: { $0.key == "every" }):
                guard let number = Int(value), number > 0 else { throw LineError("count must be a whole number above 0.") }
                count = number
            default:
                guard isIdentifier(setting.key) else { throw LineError("“\(setting.key)” isn't a field name.") }
                guard let number = FileNumber.parse(value, commas: false) else {
                    throw LineError("“\(value)” isn't a number. Inside brackets, write numbers without commas: 6000.")
                }
                values[setting.key] = number
            }
        }
        if let every { return .rule(first: time, kind: kind, values: values, every: every, until: until, count: count) }
        return .event(time: time, kind: kind, values: values)
    }

    static func text(_ event: Event, percent: Set<String>) -> String {
        line(time: event.time, kind: event.kind, values: event.values, percent: event.kind == Event.setKind ? percent : [],
             extra: [])
    }

    static func text(_ rule: RecurringEvent, percent: Set<String>) -> String {
        var extra = [Setting(key: "every", value: rule.every.text)]
        if let until = rule.until { extra.append(Setting(key: "until", value: FileDate.text(until))) }
        if let count = rule.count { extra.append(Setting(key: "count", value: String(count))) }
        return line(time: rule.first, kind: rule.kind, values: rule.values, percent: rule.kind == Event.setKind ? percent : [],
                    extra: extra)
    }

    private static func line(time: Date, kind: String, values: [String: Double], percent: Set<String>, extra: [Setting]) -> String {
        let fields = values.sorted { $0.key < $1.key }.map {
            Setting(key: $0.key, value: FileNumber.text($0.value, percent: percent.contains($0.key)))
        } + extra
        let base = FileDate.text(time) + " " + kind
        return fields.isEmpty ? base : base + " [" + fields.map(\.text).joined(separator: ", ") + "]"
    }

    /// A stable id for an event or rule, from its slot, its line and how many identical lines come
    /// before it, so the same file always gives the same ids (docs/DESIGN.md, 15.2).
    static func id(slot: String, line: String, occurrence: Int) -> UUID {
        let text = slot + "\u{1}" + line + "\u{1}" + String(occurrence)
        var a: UInt64 = 0xCBF2_9CE4_8422_2325, b: UInt64 = 0x8422_2325_CBF2_9CE4
        for byte in text.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 &+ 0x9E37_79B9
        }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<8 { raw[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i))) }
            for i in 0..<8 { raw[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i))) }
        }
        return UUID(uuid: bytes)
    }
}

/// Stable ids for events and rules: the same ones reading `scenario.md` gives them, so an event
/// added in the app keeps its id when the file is read again (docs/DESIGN.md, 15.2).
public enum EventIdentity {
    /// The text that identifies an event, whatever way its numbers are written.
    public static func key(_ event: Event) -> String { EventLine.text(event, percent: []) }

    public static func key(_ rule: RecurringEvent) -> String { EventLine.text(rule, percent: []) }

    public static func id(slot: String, key: String, occurrence: Int) -> UUID {
        EventLine.id(slot: slot, line: key, occurrence: occurrence)
    }

    /// The id for a new event with this key: the first occurrence whose id isn't taken.
    public static func newID(slot: String, key: String, taken: Set<UUID>) -> UUID {
        var occurrence = 0
        while true {
            let id = id(slot: slot, key: key, occurrence: occurrence)
            if !taken.contains(id) { return id }
            occurrence += 1
        }
    }
}

struct LineError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
