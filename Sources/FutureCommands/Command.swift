import Foundation

public enum PeekPhase: String, Hashable, Sendable, Codable {
    case begin
    case end
}

/// What the main wheel does when turned.
public enum WheelMode: Hashable, Sendable, Codable {
    case scroll
    case zoom
    /// Adjusts the named parameter of the selected slot, live.
    case parameter(String)
}

public enum SnapshotFormat: String, Hashable, Sendable, Codable, CaseIterable {
    /// Every representation at once: PNG, PDF, tab-separated data and the app's own format.
    case all
    case png
    case pdf
    case tsv
}

/// Where a command came from. Decides whether it needs confirmation (docs/DESIGN.md, section 13).
public enum CommandSource: String, Hashable, Sendable, Codable {
    case keyboard
    case menu
    case peripheral
    case commandLine
    case appIntent
    case urlScheme
    case pairedDevice
}

/// The one vocabulary shared by menus, hot-keys, the URL scheme, the CLI, App Intents and hardware.
public enum Command: Hashable, Sendable, Codable {
    // Window
    case toggleWindow
    case peek(PeekPhase)

    // Slots (numbered 1...8 within the current bank)
    case selectSlot(Int)
    case toggleSlotVisible(Int)
    case soloSlot(Int)
    case nextBank
    case previousBank

    // Timeline
    case scroll(ticks: Int)
    case zoom(ticks: Int)
    case jumpToNow
    case show(timeline: String?, at: PartialDate?)
    /// The command bar's `goto`: a date, or a value with its unit or slot (`2035`, `savings 1m`, `25°C`).
    case goto(String)
    case setWheelMode(WheelMode)
    case cycleWheelMode

    // Editing
    case insertEventAtCursor
    case adjustParameter(name: String, ticks: Int)
    /// Adds an event to a slot, from the command line or Shortcuts.
    case addEvent(EventRequest)
    /// Adds a reading of one of a slot's values, from the command line or Shortcuts (docs/DESIGN.md, 14).
    case addReading(ReadingRequest)
    /// Adds a library model by name, to a slot number (1...8) or the first free one.
    case addModel(name: String, slot: Int?)
    /// Asks to remove a slot, by name or number. The panel always asks first (docs/DESIGN.md, 13).
    case removeSlot(String)
    case undo
    case redo

    // Clipboard
    case copySnapshot(SnapshotFormat)
    /// Copies the visible data only (tab-separated text and the app's own format).
    case copyData

    public enum Category: String, Hashable, Sendable, Codable {
        case navigation
        case clipboard
        case editing
    }

    public var category: Category {
        switch self {
        case .toggleWindow, .peek, .selectSlot, .toggleSlotVisible, .soloSlot, .nextBank, .previousBank,
             .scroll, .zoom, .jumpToNow, .show, .goto, .setWheelMode, .cycleWheelMode:
            return .navigation
        case .copySnapshot, .copyData:
            return .clipboard
        case .insertEventAtCursor, .adjustParameter, .addEvent, .addReading, .addModel, .removeSlot, .undo, .redo:
            return .editing
        }
    }

    /// The longest name, kind or text a command may carry.
    public static let maxTextLength = 200

    /// Whether the command's values are in range: slots 1...8, ticks within the URL scheme's limit,
    /// short names, finite amounts. Commands decoded from outside the app are checked with this
    /// before they run.
    public var isWellFormed: Bool {
        func short(_ text: String) -> Bool { !text.isEmpty && text.count <= Self.maxTextLength }
        func ticks(_ value: Int) -> Bool { abs(value) <= URLScheme.maxTicks }
        switch self {
        case .toggleWindow, .peek, .nextBank, .previousBank, .jumpToNow, .cycleWheelMode, .insertEventAtCursor,
             .undo, .redo, .copySnapshot, .copyData:
            return true
        case .selectSlot(let slot), .toggleSlotVisible(let slot), .soloSlot(let slot):
            return (1...8).contains(slot)
        case .scroll(let value), .zoom(let value):
            return ticks(value)
        case .show(let timeline, _):
            return timeline.map(URLScheme.isValidTimelineName) ?? true
        case .goto(let text), .removeSlot(let text):
            return short(text)
        case .setWheelMode(let mode):
            if case .parameter(let name) = mode { return short(name) }
            return true
        case .adjustParameter(let name, let value):
            return short(name) && ticks(value)
        case .addEvent(let request):
            return request.isWellFormed
        case .addReading(let request):
            return request.isWellFormed
        case .addModel(let name, let slot):
            return short(name) && (slot.map { (1...8).contains($0) } ?? true)
        }
    }

    /// Whether the app should ask before running this command from `source`.
    ///
    /// Any web page can open an `etf://` link, so links may navigate but must not edit data
    /// or overwrite the clipboard without asking. Paired devices and Siri may not edit silently.
    public func requiresConfirmation(from source: CommandSource) -> Bool {
        switch (source, category) {
        case (_, .navigation):
            return false
        case (.keyboard, _), (.menu, _), (.peripheral, _), (.commandLine, _):
            return false
        case (.urlScheme, _):
            return true
        case (.appIntent, .editing), (.pairedDevice, .editing):
            return true
        case (.appIntent, .clipboard), (.pairedDevice, .clipboard):
            return false
        }
    }
}

/// How often an event repeats.
public enum Repetition: String, Hashable, Sendable, Codable, CaseIterable {
    case daily, weekly, fortnightly, monthly, quarterly, yearly

    /// "monthly", "month", "annually", "biweekly".
    public init?(word: String) {
        switch word.lowercased() {
        case "daily", "day": self = .daily
        case "weekly", "week": self = .weekly
        case "fortnightly", "biweekly", "fortnight": self = .fortnightly
        case "monthly", "month": self = .monthly
        case "quarterly", "quarter": self = .quarterly
        case "yearly", "annually", "year": self = .yearly
        default: return nil
        }
    }
}

/// A number for an event, as it was given.
public struct Amount: Hashable, Sendable, Codable {
    public var value: Double
    /// Given with a percent sign, so `value` is already a fraction: "4.5%" is 0.045. A plain number
    /// for a percent is read in percent, as the Slot tab reads it: 4.5 means 4.5%.
    public var isFraction: Bool

    public init(_ value: Double, isFraction: Bool = false) {
        self.value = value
        self.isFraction = isFraction
    }
}

/// An event to add to a slot from outside the panel: the command line or Shortcuts.
public struct EventRequest: Hashable, Sendable, Codable {
    /// The slot's name or number; nil for the focused slot.
    public var slot: String?
    /// "deposit", "withdraw", "set" for parameters, or another kind the slot handles.
    public var kind: String
    /// The event's values by name: `amount` for deposits and withdrawals, parameter names for `set`.
    public var values: [String: Amount]
    /// The currency given with the amounts, as given ("£", "eur"). It must be the slot's.
    public var currency: String?
    /// When it happens, or first happens; nil for now.
    public var at: PartialDate?
    /// How often it repeats; nil for once.
    public var every: Repetition?

    public init(slot: String?, kind: String, values: [String: Amount], currency: String? = nil, at: PartialDate? = nil,
                every: Repetition? = nil) {
        self.slot = slot
        self.kind = kind
        self.values = values
        self.currency = currency
        self.at = at
        self.every = every
    }

    /// A deposit (or a withdrawal, for a negative amount) of `amount`.
    public static func money(_ amount: Double, slot: String?, currency: String? = nil, at: PartialDate? = nil,
                             every: Repetition? = nil) -> EventRequest {
        EventRequest(slot: slot, kind: amount < 0 ? "withdraw" : "deposit", values: ["amount": Amount(abs(amount))],
                     currency: currency, at: at, every: every)
    }

    public var isWellFormed: Bool {
        func short(_ text: String, _ limit: Int = Command.maxTextLength) -> Bool { !text.isEmpty && text.count <= limit }
        guard short(kind, 64), kind.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        if let slot, !short(slot) { return false }
        if let currency, !short(currency, 32) { return false }
        return !values.isEmpty && values.count <= 16
            && values.allSatisfy { short($0.key, 64) && $0.value.value.isFinite }
    }
}

/// A reading of a slot's value to add from outside the panel: the command line or Shortcuts.
public struct ReadingRequest: Hashable, Sendable, Codable {
    /// The slot's name or number; nil for the focused slot.
    public var slot: String?
    /// Which of its values (or parameters) it's a reading of; nil for the one its graph shows.
    public var variable: String?
    public var value: Amount
    /// The currency given with the value, as given ("£", "eur"). It must be the slot's.
    public var currency: String?
    /// When it was read; nil for today.
    public var at: PartialDate?

    public init(slot: String?, variable: String? = nil, value: Amount, currency: String? = nil, at: PartialDate? = nil) {
        self.slot = slot
        self.variable = variable
        self.value = value
        self.currency = currency
        self.at = at
    }

    public var isWellFormed: Bool {
        func short(_ text: String, _ limit: Int = Command.maxTextLength) -> Bool { !text.isEmpty && text.count <= limit }
        if let slot, !short(slot) { return false }
        if let variable, !short(variable, 64) { return false }
        if let currency, !short(currency, 32) { return false }
        return value.value.isFinite
    }
}

/// A date given to year, month or day precision, like `2030`, `2030-01` or `2030-01-15`.
public struct PartialDate: Hashable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int?
    public let day: Int?

    /// Decodes and checks a date sent from outside the app: one that isn't a real date is refused,
    /// rather than becoming one later.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decodeIfPresent(Int.self, forKey: .month)
        let day = try container.decodeIfPresent(Int.self, forKey: .day)
        guard let date = PartialDate(year: year, month: month, day: day) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(year)-\(month ?? 0)-\(day ?? 0)"))
        }
        self = date
    }

    /// The day a date falls on in `calendar` (the Mac's own, for a date picked in Shortcuts), as a
    /// date in the engine's UTC calendar.
    public init?(day date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init?(year: Int, month: Int? = nil, day: Int? = nil) {
        guard (1...9999).contains(year) else { return nil }
        if let month, !(1...12).contains(month) { return nil }
        if day != nil && month == nil { return nil }
        if let day, let month {
            var components = DateComponents()
            components.year = year
            components.month = month
            let calendar = Calendar.utcGregorianForCommands
            guard let firstOfMonth = calendar.date(from: components),
                  let days = calendar.range(of: .day, in: .month, for: firstOfMonth),
                  days.contains(day) else { return nil }
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY`, `YYYY-MM` or `YYYY-MM-DD`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts[0].count == 4, parts.dropFirst().allSatisfy({ $0.count == 2 }),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        self.init(year: numbers[0], month: numbers.count > 1 ? numbers[1] : nil, day: numbers.count > 2 ? numbers[2] : nil)
    }

    public var description: String {
        var text = String(format: "%04d", year)
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        return text
    }

    /// The first instant of the period, in UTC.
    public var date: Date {
        var components = DateComponents()
        components.year = year
        components.month = month ?? 1
        components.day = day ?? 1
        return Calendar.utcGregorianForCommands.date(from: components)!
    }
}

extension Calendar {
    static let utcGregorianForCommands: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
