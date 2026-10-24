import Foundation

public enum URLSchemeError: Error, Equatable, CustomStringConvertible {
    case wrongScheme(String?)
    case unknownAction(String)
    case missingParameter(String)
    case invalidParameter(name: String, value: String)

    public var description: String {
        switch self {
        case .wrongScheme(let scheme): return "Expected an etf:// link, got \(scheme ?? "no scheme")."
        case .unknownAction(let action): return "etf://\(action) isn't a known action."
        case .missingParameter(let name): return "The link needs a \(name) parameter."
        case .invalidParameter(let name, let value): return "\"\(value)\" isn't a valid \(name)."
        }
    }
}

/// The `etf://` URL scheme, e.g. `etf://show?timeline=savings&at=2030-01`.
///
/// Links can only produce navigation and clipboard commands. Clipboard commands still need
/// confirmation when they arrive by link (see `Command.requiresConfirmation(from:)`).
public enum URLScheme {
    public static let scheme = "etf"
    public static let maxTimelineNameLength = 128
    public static let maxTicks = 10_000

    public static func command(from url: URL) throws -> Command {
        guard url.scheme?.lowercased() == scheme else { throw URLSchemeError.wrongScheme(url.scheme) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (components?.host ?? components?.path ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }

        switch action {
        case "show":
            var timeline: String?
            if let name = query["timeline"] {
                guard isValidTimelineName(name) else { throw URLSchemeError.invalidParameter(name: "timeline", value: name) }
                timeline = name
            }
            var at: PartialDate?
            if let text = query["at"] {
                guard let date = PartialDate(text) else { throw URLSchemeError.invalidParameter(name: "at", value: text) }
                at = date
            }
            return .show(timeline: timeline, at: at)
        case "toggle":
            return .toggleWindow
        case "now":
            return .jumpToNow
        case "select":
            guard let text = query["slot"] else { throw URLSchemeError.missingParameter("slot") }
            guard let slot = Int(text), (1...8).contains(slot) else {
                throw URLSchemeError.invalidParameter(name: "slot", value: text)
            }
            return .selectSlot(slot)
        case "scroll":
            return .scroll(ticks: try ticks(query))
        case "zoom":
            return .zoom(ticks: try ticks(query))
        case "copy":
            let text = query["format"] ?? "all"
            if text == "data" { return .copyData }
            guard let format = SnapshotFormat(rawValue: text) else {
                throw URLSchemeError.invalidParameter(name: "format", value: text)
            }
            return .copySnapshot(format)
        default:
            throw URLSchemeError.unknownAction(action)
        }
    }

    /// The link for a command, when it has one.
    public static func url(for command: Command) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch command {
        case .show(let timeline, let at):
            components.host = "show"
            var items: [URLQueryItem] = []
            if let timeline { items.append(URLQueryItem(name: "timeline", value: timeline)) }
            if let at { items.append(URLQueryItem(name: "at", value: at.description)) }
            components.queryItems = items.isEmpty ? nil : items
        case .toggleWindow:
            components.host = "toggle"
        case .jumpToNow:
            components.host = "now"
        case .selectSlot(let slot):
            components.host = "select"
            components.queryItems = [URLQueryItem(name: "slot", value: String(slot))]
        case .scroll(let ticks):
            components.host = "scroll"
            components.queryItems = [URLQueryItem(name: "ticks", value: String(ticks))]
        case .zoom(let ticks):
            components.host = "zoom"
            components.queryItems = [URLQueryItem(name: "ticks", value: String(ticks))]
        case .copySnapshot(let format):
            components.host = "copy"
            components.queryItems = [URLQueryItem(name: "format", value: format.rawValue)]
        case .copyData:
            components.host = "copy"
            components.queryItems = [URLQueryItem(name: "format", value: "data")]
        default:
            return nil
        }
        return components.url
    }

    static func isValidTimelineName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxTimelineNameLength else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || " -_.".contains($0) }
    }

    private static func ticks(_ query: [String: String]) throws -> Int {
        guard let text = query["ticks"] else { throw URLSchemeError.missingParameter("ticks") }
        guard let value = Int(text), abs(value) <= maxTicks else {
            throw URLSchemeError.invalidParameter(name: "ticks", value: text)
        }
        return value
    }
}
