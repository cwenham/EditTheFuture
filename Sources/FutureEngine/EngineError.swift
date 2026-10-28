import Foundation

public enum EngineError: Error, Equatable, CustomStringConvertible {
    case invalidSlotName(String)
    case duplicateSlotName(String)
    case invalidStepRate(slot: String)
    case unknownSlot(String, referencedBy: String)
    case unknownVariable(slot: String, variable: String)
    case unknownInput(slot: String, input: String)
    case unknownEventKind(slot: String, kind: String)
    case dateBeforeStart
    case selfConnection(slot: String)
    case unitMismatch(from: String, to: String)
    case sameStepLoop([String])
    case reentrantStep(slot: String)
    case modelFailed(slot: String, message: String)
    case goalNotBracketed(lowResult: Double, highResult: Double, target: Double)
    /// A slot reads money in another currency, and there's no rate between them.
    case noExchangeRate(slot: String, from: String, to: String)

    public var description: String {
        switch self {
        case .invalidSlotName(let name):
            return "\"\(name)\" isn't a valid slot name. Use letters, digits and underscores, starting with a letter."
        case .duplicateSlotName(let name):
            return "There is already a slot named \(name)."
        case .invalidStepRate(let slot):
            return "\(slot) has a step rate of zero or less."
        case .unknownSlot(let name, let referencedBy):
            return "\(referencedBy) refers to a slot named \(name), but there isn't one."
        case .unknownVariable(let slot, let variable):
            return "\(slot) has no readable variable named \(variable)."
        case .unknownInput(let slot, let input):
            return "\(slot) has no input named \(input)."
        case .unknownEventKind(let slot, let kind):
            return "\(slot) never emits an event called \(kind)."
        case .dateBeforeStart:
            return "That date is before the scenario starts."
        case .selfConnection(let slot):
            return "\(slot) can't be connected to itself. Use its own state instead."
        case .unitMismatch(let from, let to):
            return "Units don't match: \(from) is connected to \(to)."
        case .sameStepLoop(let names):
            return "These slots depend on each other within the same step: \(names.joined(separator: " → ")). "
                + "Read one of the links from the previous step instead, e.g. Slot.value[t-1]."
        case .reentrantStep(let slot):
            return "\(slot) was asked to step while it was already stepping (a same-step loop)."
        case .modelFailed(let slot, let message):
            return "\(slot) failed: \(message)"
        case .noExchangeRate(let slot, let from, let to):
            return "\(slot) reads money in \(from) but is in \(to), and there's no exchange rate between them yet."
        case .goalNotBracketed(let low, let high, let target):
            return "The target \(target) isn't between the results at the ends of the range (\(low) and \(high))."
        }
    }
}
