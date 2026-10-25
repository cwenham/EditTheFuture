import Foundation
import FutureEngine

/// Evaluates resolved expressions for one step, using arrays only.
/// `x[t-1]` reads `previous`; during differential-equation integration the ODE variables'
/// stage values are written into `current` (all other variables still hold last step's values).
struct Evaluator {
    var parameters: [Double]
    var current: [Double]
    var previous: [Double]
    let inputs: [Double]
    let builtins: [Double]
    var event: Event?
    var random: SeededRandom

    mutating func evaluate(_ expr: ResolvedExpr) throws -> Double {
        switch expr {
        case .number(let value): return value
        case .variable(let index): return current[index]
        case .lagged(let index): return previous[index]
        case .parameter(let index): return parameters[index]
        case .builtin(let index): return builtins[index]
        case .input(let index): return inputs[index]
        case .eventField(let field):
            guard let event else { throw FormulaError.invalid(line: 0, message: "event.\(field) used outside a handler.") }
            guard let value = event.values[field] else { throw FormulaError.missingEventField(kind: event.kind, field: field) }
            return value
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

    private mutating func call(_ function: Function, _ arguments: [ResolvedExpr]) throws -> Double {
        switch function {
        case .if:
            return try evaluate(arguments[0]) != 0 ? evaluate(arguments[1]) : evaluate(arguments[2])
        case .random:
            return random.uniform()
        case .normal:
            let mean = try evaluate(arguments[0]), sd = try evaluate(arguments[1])
            return random.normal(mean: mean, sd: sd)
        case .min:
            var result = try evaluate(arguments[0])
            for argument in arguments.dropFirst() { result = Swift.min(result, try evaluate(argument)) }
            return result
        case .max:
            var result = try evaluate(arguments[0])
            for argument in arguments.dropFirst() { result = Swift.max(result, try evaluate(argument)) }
            return result
        case .abs: return Swift.abs(try evaluate(arguments[0]))
        case .sqrt: return try evaluate(arguments[0]).squareRoot()
        case .exp: return Foundation.exp(try evaluate(arguments[0]))
        case .log: return Foundation.log(try evaluate(arguments[0]))
        case .log10: return Foundation.log10(try evaluate(arguments[0]))
        case .sin: return Foundation.sin(try evaluate(arguments[0]))
        case .cos: return Foundation.cos(try evaluate(arguments[0]))
        case .tan: return Foundation.tan(try evaluate(arguments[0]))
        case .floor: return try evaluate(arguments[0]).rounded(.down)
        case .ceil: return try evaluate(arguments[0]).rounded(.up)
        case .round: return try evaluate(arguments[0]).rounded()
        case .pow:
            let a = try evaluate(arguments[0]), b = try evaluate(arguments[1])
            return Foundation.pow(a, b)
        case .mod:
            let a = try evaluate(arguments[0]), b = try evaluate(arguments[1])
            return a.truncatingRemainder(dividingBy: b)
        case .clamp:
            let value = try evaluate(arguments[0]), low = try evaluate(arguments[1]), high = try evaluate(arguments[2])
            return Swift.min(Swift.max(value, low), high)
        }
    }
}
