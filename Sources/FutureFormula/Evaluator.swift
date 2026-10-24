import Foundation
import FutureEngine

/// Evaluates expressions for one step. Lookups go: ODE stage values, this step's values,
/// parameters, then built-ins. `name[t-1]` reads the previous step's values.
struct Evaluator {
    var params: [String: Double]
    var current: [String: Double]
    var previous: [String: Double]
    /// Values of ODE variables at the current integration stage.
    var stage: [String: Double] = [:]
    let inputs: [String: Double]
    let builtins: [String: Double]
    var event: Event?
    var random: SeededRandom

    mutating func evaluate(_ expr: Expr) throws -> Double {
        switch expr {
        case .number(let value):
            return value
        case .name(let name, let lagged):
            if lagged { return previous[name] ?? 0 }
            if let value = stage[name] ?? current[name] ?? params[name] ?? builtins[name] { return value }
            throw FormulaError.unknownName(name, line: 0)
        case .eventField(let field):
            guard let event else { throw FormulaError.invalid(line: 0, message: "event.\(field) used outside a handler.") }
            guard let value = event.values[field] else {
                throw FormulaError.missingEventField(kind: event.kind, field: field)
            }
            return value
        case .input(let key):
            return inputs[key] ?? 0
        case .unary(.negate, let operand):
            return -(try evaluate(operand))
        case .unary(.not, let operand):
            return try evaluate(operand) == 0 ? 1 : 0
        case .binary(.and, let left, let right):
            guard try evaluate(left) != 0 else { return 0 }
            return try evaluate(right) != 0 ? 1 : 0
        case .binary(.or, let left, let right):
            if try evaluate(left) != 0 { return 1 }
            return try evaluate(right) != 0 ? 1 : 0
        case .binary(let op, let left, let right):
            let a = try evaluate(left), b = try evaluate(right)
            switch op {
            case .add: return a + b
            case .subtract: return a - b
            case .multiply: return a * b
            case .divide: return a / b
            case .power: return Foundation.pow(a, b)
            case .less: return a < b ? 1 : 0
            case .lessOrEqual: return a <= b ? 1 : 0
            case .greater: return a > b ? 1 : 0
            case .greaterOrEqual: return a >= b ? 1 : 0
            case .equal: return a == b ? 1 : 0
            case .notEqual: return a != b ? 1 : 0
            case .and, .or: preconditionFailure("handled above")
            }
        case .call(let function, let arguments):
            return try call(function, arguments)
        }
    }

    private mutating func call(_ function: String, _ arguments: [Expr]) throws -> Double {
        switch function {
        case "if":
            return try evaluate(arguments[0]) != 0 ? evaluate(arguments[1]) : evaluate(arguments[2])
        case "random":
            return random.uniform()
        case "normal":
            let mean = try evaluate(arguments[0]), sd = try evaluate(arguments[1])
            return random.normal(mean: mean, sd: sd)
        default:
            break
        }
        var values: [Double] = []
        values.reserveCapacity(arguments.count)
        for argument in arguments { values.append(try evaluate(argument)) }
        switch function {
        case "min": return values.min()!
        case "max": return values.max()!
        case "abs": return Swift.abs(values[0])
        case "sqrt": return values[0].squareRoot()
        case "exp": return Foundation.exp(values[0])
        case "log": return Foundation.log(values[0])
        case "log10": return Foundation.log10(values[0])
        case "sin": return Foundation.sin(values[0])
        case "cos": return Foundation.cos(values[0])
        case "tan": return Foundation.tan(values[0])
        case "floor": return values[0].rounded(.down)
        case "ceil": return values[0].rounded(.up)
        case "round": return values[0].rounded()
        case "pow": return Foundation.pow(values[0], values[1])
        case "mod": return values[0].truncatingRemainder(dividingBy: values[1])
        case "clamp": return Swift.min(Swift.max(values[0], values[1]), values[2])
        default: throw FormulaError.unknownFunction(function, line: 0)
        }
    }

    /// Derivatives of the ODE variables at the given stage values.
    mutating func derivatives(_ odes: [Assignment], at values: [Double]) throws -> [Double] {
        for (ode, value) in zip(odes, values) { stage[ode.name] = value }
        var result: [Double] = []
        result.reserveCapacity(odes.count)
        for ode in odes { result.append(try evaluate(ode.expr)) }
        return result
    }
}
