import Foundation

/// A question asked from outside the app, by the command line or Shortcuts. Asking never changes
/// the scenario or the panel.
public enum Query: Hashable, Sendable, Codable {
    /// The scenario that's open: its name, start, slots, and where the panel's cursor is.
    case status
    /// Every slot, with its model and what it can show.
    case slots
    /// A slot's value at a date. `slot` nil is the focused slot; `variable` nil is the one its graph
    /// shows; `at` nil is now.
    case value(slot: String?, variable: String?, at: PartialDate?)
    /// A slot's values from `from` (now when nil) through `through` (ten years after `from` when nil):
    /// one row for each of the slot's steps, or one for each `every`.
    case series(slot: String?, variable: String?, from: PartialDate?, through: PartialDate?, every: Repetition?)
}

/// What the command line sends: a command to run, or a question.
public enum Request: Hashable, Sendable, Codable {
    case command(Command)
    case query(Query)

    /// Whether everything in it is in range (see `Command.isWellFormed`).
    public var isWellFormed: Bool {
        switch self {
        case .command(let command): return command.isWellFormed
        case .query(let query):
            func short(_ text: String?) -> Bool { text.map { !$0.isEmpty && $0.count <= Command.maxTextLength } ?? true }
            switch query {
            case .status, .slots: return true
            case .value(let slot, let variable, _), .series(let slot, let variable, _, _, _): return short(slot) && short(variable)
            }
        }
    }
}

/// The app's answer.
public struct Reply: Hashable, Sendable, Codable {
    /// Whether it worked. When it didn't, `message` says why.
    public var ok: Bool
    /// What happened, in the panel's words: "Added +£500 on Jan 2027 to Savings".
    public var message: String
    public var status: ScenarioStatus?
    public var slots: [SlotSummary]?
    public var value: ValueReading?
    public var series: SeriesReading?

    public init(ok: Bool, message: String, status: ScenarioStatus? = nil, slots: [SlotSummary]? = nil,
                value: ValueReading? = nil, series: SeriesReading? = nil) {
        self.ok = ok
        self.message = message
        self.status = status
        self.slots = slots
        self.value = value
        self.series = series
    }

    public static func done(_ message: String) -> Reply { Reply(ok: true, message: message) }
    public static func failed(_ message: String) -> Reply { Reply(ok: false, message: message) }
}

/// The scenario that's open.
public struct ScenarioStatus: Hashable, Sendable, Codable {
    public var name: String
    /// Dates are the day, written `2026-10-29`.
    public var start: String
    public var now: String
    public var cursor: String
    /// The focused slot's title.
    public var focused: String
    public var slotCount: Int
    /// The scenario's currency, as an ISO 4217 code.
    public var currency: String

    public init(name: String, start: String, now: String, cursor: String, focused: String, slotCount: Int, currency: String) {
        self.name = name
        self.start = start
        self.now = now
        self.cursor = cursor
        self.focused = focused
        self.slotCount = slotCount
        self.currency = currency
    }
}

/// A slot, as the command line lists it.
public struct SlotSummary: Hashable, Sendable, Codable {
    /// Its position, 1...8, as on the chips.
    public var number: Int
    /// The name formulas use: "IndexFund".
    public var name: String
    /// The name people see: "Index fund".
    public var title: String
    public var model: String
    /// The value its graph shows.
    public var shows: String
    /// Every value it can show.
    public var outputs: [String]
    public var parameters: [String]
    /// Kinds of event it handles, such as deposit and withdraw.
    public var events: [String]
    /// What its money is in, as an ISO 4217 code.
    public var currency: String
    /// Why it can't run, when it can't.
    public var paused: String?

    public init(number: Int, name: String, title: String, model: String, shows: String, outputs: [String],
                parameters: [String], events: [String], currency: String, paused: String?) {
        self.number = number
        self.name = name
        self.title = title
        self.model = model
        self.shows = shows
        self.outputs = outputs
        self.parameters = parameters
        self.events = events
        self.currency = currency
        self.paused = paused
    }
}

/// A slot's value at a date.
public struct ValueReading: Hashable, Sendable, Codable {
    /// The slot's title.
    public var slot: String
    public var variable: String
    /// The point the value is from: the slot's last step at or before the date asked for, written
    /// `2030-01-01`, or with the time for steps shorter than a day.
    public var date: String
    /// Can be huge, infinite or NaN.
    public var value: Double
    /// Written as the panel writes it: "£96,420".
    public var text: String
    /// An ISO 4217 code for money, "°C", "%" for a fraction shown as a percent, or "" for a plain number.
    public var unit: String

    public init(slot: String, variable: String, date: String, value: Double, text: String, unit: String) {
        self.slot = slot
        self.variable = variable
        self.date = date
        self.value = value
        self.text = text
        self.unit = unit
    }
}

/// A slot's values over a range of dates.
public struct SeriesReading: Hashable, Sendable, Codable {
    public struct Row: Hashable, Sendable, Codable {
        public var date: String
        public var value: Double

        public init(date: String, value: Double) {
            self.date = date
            self.value = value
        }
    }

    public var slot: String
    public var variable: String
    public var unit: String
    public var rows: [Row]

    public init(slot: String, variable: String, unit: String, rows: [Row]) {
        self.slot = slot
        self.variable = variable
        self.unit = unit
        self.rows = rows
    }
}

/// How requests and replies are written between the command line and the app: JSON, with a
/// version, each message preceded by its length.
public enum Wire {
    /// Changes when a request or reply changes in a way older tools can't read.
    public static let version = 1
    /// Requests are small; anything bigger isn't one.
    public static let maxRequestBytes = 64 * 1024
    /// A series of a few hundred thousand rows fits.
    public static let maxReplyBytes = 64 * 1024 * 1024

    struct Envelope<Body: Codable>: Codable {
        let version: Int
        let body: Body
    }

    /// JSON can't hold infinity or NaN, and model values can be either, so they're written as text.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    public static func encode<Body: Codable>(_ body: Body) throws -> Data {
        try encoder().encode(Envelope(version: version, body: body))
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case otherVersion(Int)
        case unreadable(String)

        public var description: String {
            switch self {
            case .otherVersion: return "This etf tool and the app are from different versions of Edit The Future."
            case .unreadable(let detail): return "The message couldn't be read: \(detail)"
            }
        }
    }

    private struct Versioned: Codable { let version: Int }

    public static func decode<Body: Codable>(_ type: Body.Type, from data: Data) throws -> Body {
        let versioned: Versioned
        do {
            versioned = try decoder().decode(Versioned.self, from: data)
        } catch {
            throw Problem.unreadable(String(describing: error))
        }
        guard versioned.version == version else { throw Problem.otherVersion(versioned.version) }
        do {
            return try decoder().decode(Envelope<Body>.self, from: data).body
        } catch {
            throw Problem.unreadable(String(describing: error))
        }
    }

    /// The JSON people see with `--json`: readable, with infinity and NaN as text.
    public static func pretty<Body: Encodable>(_ body: Body) -> String {
        let encoder = encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(body), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
