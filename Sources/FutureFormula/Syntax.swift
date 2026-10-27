import FutureEngine

enum UnaryOperator: Sendable {
    case negate
    case not
}

enum BinaryOperator: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", power = "^"
    case less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">=", equal = "==", notEqual = "!="
    case and, or
}

indirect enum Expr: Sendable {
    case number(Double)
    /// A local variable, parameter or built-in. `lagged` means `name[t-1]`.
    case name(String, lagged: Bool)
    /// A field of the event being handled, e.g. `event.amount`.
    case eventField(String)
    /// Another slot's variable, by the canonical text of its reference (also the input's name).
    case input(String)
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case call(String, [Expr])

    /// Calls `body` on this expression and every expression inside it.
    func visit(_ body: (Expr) throws -> Void) rethrows {
        try body(self)
        switch self {
        case .unary(_, let operand):
            try operand.visit(body)
        case .binary(_, let left, let right):
            try left.visit(body)
            try right.visit(body)
        case .call(_, let arguments):
            for argument in arguments { try argument.visit(body) }
        case .number, .name, .eventField, .input:
            break
        }
    }
}

/// `name = expression`, as used by params, inits, definitions and differential equations.
struct Assignment: Sendable {
    let name: String
    let expr: Expr
    let line: Int
    /// How people see and set a param or init: `range 0%..15% by 0.1% label "Interest rate" as percent`.
    var options = DeclarationOptions()
}

/// The options after a param's or init's value (docs/DESIGN.md, 6.2).
struct DeclarationOptions: Sendable, Equatable {
    var label: String?
    var minimum: Double?
    var maximum: Double?
    var increment: Double?
    var quantity: Quantity?
    /// `fit`: Refit may change it (docs/DESIGN.md, 8.4). Only on params and inits.
    var fit = false
}

/// `when condition emit Kind`
struct Trigger: Sendable {
    let condition: Expr
    let kind: String
    let line: Int
}

enum AssignmentOperator: String, Sendable {
    case set = "=", add = "+=", subtract = "-=", multiply = "*=", divide = "/="
}

/// One `target op expression` inside an `on` handler.
struct Action: Sendable {
    let target: String
    let op: AssignmentOperator
    let expr: Expr
    let line: Int
}

/// `on Kind: actions` or `on Slot.Kind[t-1]: actions`
struct Handler: Sendable {
    /// Slot that generates the event, or nil for this slot's own authored and recurring events.
    let origin: String?
    let kind: String
    let timing: Timing
    let actions: [Action]
    let line: Int
}

/// A parsed formula, before validation.
struct Program: Sendable {
    var stepRate: StepRate = .months(1)
    var timeUnit: StepRate?
    var params: [Assignment] = []
    var inits: [Assignment] = []
    var definitions: [Assignment] = []
    var odes: [Assignment] = []
    var triggers: [Trigger] = []
    var handlers: [Handler] = []
    /// References to other slots, keyed by their canonical text.
    var references: [String: Reference] = [:]
}
