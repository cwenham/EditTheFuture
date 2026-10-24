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
