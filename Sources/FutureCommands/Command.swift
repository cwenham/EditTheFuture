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
    case setWheelMode(WheelMode)
    case cycleWheelMode

    // Editing
    case insertEventAtCursor
    case adjustParameter(name: String, ticks: Int)
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
             .scroll, .zoom, .jumpToNow, .show, .setWheelMode, .cycleWheelMode:
            return .navigation
        case .copySnapshot, .copyData:
            return .clipboard
        case .insertEventAtCursor, .adjustParameter, .undo, .redo:
            return .editing
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

/// A date given to year, month or day precision, like `2030`, `2030-01` or `2030-01-15`.
public struct PartialDate: Hashable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int?
    public let day: Int?

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
