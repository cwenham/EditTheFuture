import Foundation

public enum FormulaError: Error, Equatable, CustomStringConvertible {
    case syntax(line: Int, message: String)
    case unknownName(String, line: Int)
    case duplicateName(String, line: Int)
    case reservedName(String, line: Int)
    case unknownFunction(String, line: Int)
    case wrongArgumentCount(function: String, expected: String, line: Int)
    case sameStepLoop([String])
    case invalid(line: Int, message: String)
    case missingEventField(kind: String, field: String)

    public var description: String {
        switch self {
        case .syntax(let line, let message):
            return "Line \(line): \(message)"
        case .unknownName(let name, let line):
            return "Line \(line): \(name) isn't defined."
        case .duplicateName(let name, let line):
            return "Line \(line): \(name) is already defined."
        case .reservedName(let name, let line):
            return "Line \(line): \(name) is a reserved word and can't be used as a name."
        case .unknownFunction(let name, let line):
            return "Line \(line): there's no function called \(name)."
        case .wrongArgumentCount(let function, let expected, let line):
            return "Line \(line): \(function) takes \(expected)."
        case .sameStepLoop(let names):
            return "These variables depend on each other within the same step: \(names.joined(separator: " → ")). "
                + "Use the previous step's value for one of them, e.g. \(names.first ?? "x")[t-1]."
        case .invalid(let line, let message):
            return "Line \(line): \(message)"
        case .missingEventField(let kind, let field):
            return "A \(kind) event has no value called \(field)."
        }
    }
}

extension FormulaError {
    /// The line the mistake is on, when there is one.
    public var line: Int? {
        switch self {
        case .syntax(let line, _), .unknownName(_, let line), .duplicateName(_, let line), .reservedName(_, let line),
             .unknownFunction(_, let line), .wrongArgumentCount(_, _, let line), .invalid(let line, _):
            return line
        case .sameStepLoop, .missingEventField:
            return nil
        }
    }

    /// The description without its "Line 3: " prefix, for showing next to the line.
    public var message: String {
        let text = description
        guard let line, text.hasPrefix("Line \(line): ") else { return text }
        return String(text.dropFirst("Line \(line): ".count))
    }
}
