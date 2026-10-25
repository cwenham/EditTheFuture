import FutureEngine

/// Built-in values, stored by position so evaluation needs no string lookups.
enum Builtin: String, CaseIterable, Sendable {
    case pi, step, year, month, day, dayOfYear, days, dt

    var index: Int { Builtin.allCases.firstIndex(of: self)! }
}

/// Built-in functions, resolved from their names at compile time.
enum Function: String, Sendable {
    case min, max, abs, sqrt, exp, log, log10, sin, cos, tan, floor, ceil, round, pow, mod, clamp, `if`, random, normal
}

/// An expression with every name resolved to an array position.
indirect enum ResolvedExpr: Sendable {
    case number(Double)
    case variable(Int)
    /// A variable's previous-step value, `x[t-1]`.
    case lagged(Int)
    case parameter(Int)
    case builtin(Int)
    case input(Int)
    case eventField(String)
    case unary(UnaryOperator, ResolvedExpr)
    case binary(BinaryOperator, ResolvedExpr, ResolvedExpr)
    case call(Function, [ResolvedExpr])
}

/// What an `on` handler assigns to.
enum ResolvedTarget: Sendable {
    case variable(Int)
    case parameter(Int)
}

/// A formula ready to run: arrays and positions instead of names.
struct Executable: Sendable {
    struct Assign: Sendable {
        let index: Int
        let expr: ResolvedExpr
    }
    struct ResolvedTrigger: Sendable {
        let condition: ResolvedExpr
        let kind: String
    }
    struct ResolvedAction: Sendable {
        let target: ResolvedTarget
        let op: AssignmentOperator
        let expr: ResolvedExpr
    }
    struct ResolvedHandler: Sendable {
        let origin: String?
        let kind: String
        let actions: [ResolvedAction]
    }

    let parameterCount: Int
    let variableCount: Int
    let parameters: [Assign]
    let inits: [Assign]
    /// Definitions in dependency order.
    let definitions: [Assign]
    let odes: [Assign]
    let triggers: [ResolvedTrigger]
    let handlers: [ResolvedHandler]
    let parameterIndex: [String: Int]
    let variableHasInit: [Bool]
    /// Input variable names (reference texts), by input position.
    let inputNames: [String]
    let usedBuiltins: Set<Builtin>
}

extension CompiledProgram {
    func makeExecutable() -> Executable {
        let parameterIndex = Dictionary(uniqueKeysWithValues: params.enumerated().map { ($0.element.name, $0.offset) })
        let variableIndex = Dictionary(uniqueKeysWithValues: variableNames.enumerated().map { ($0.element, $0.offset) })
        let inputNames = references.map(\.text)
        let inputIndex = Dictionary(uniqueKeysWithValues: inputNames.enumerated().map { ($0.element, $0.offset) })

        func resolve(_ expr: Expr) -> ResolvedExpr {
            switch expr {
            case .number(let value):
                return .number(value)
            case .name(let name, let lagged):
                if lagged { return .lagged(variableIndex[name]!) }
                if let index = variableIndex[name] { return .variable(index) }
                if let index = parameterIndex[name] { return .parameter(index) }
                return .builtin(Builtin(rawValue: name)!.index)
            case .eventField(let field):
                return .eventField(field)
            case .input(let key):
                return .input(inputIndex[key]!)
            case .unary(let op, let operand):
                return .unary(op, resolve(operand))
            case .binary(let op, let left, let right):
                return .binary(op, resolve(left), resolve(right))
            case .call(let name, let arguments):
                return .call(Function(rawValue: name)!, arguments.map(resolve))
            }
        }
        func assign(_ assignment: Assignment, in index: [String: Int]) -> Executable.Assign {
            Executable.Assign(index: index[assignment.name]!, expr: resolve(assignment.expr))
        }

        let initNames = Set(inits.map(\.name))
        return Executable(
            parameterCount: params.count,
            variableCount: variableNames.count,
            parameters: params.map { assign($0, in: parameterIndex) },
            inits: inits.map { assign($0, in: variableIndex) },
            definitions: definitionOrder.map { assign($0, in: variableIndex) },
            odes: odes.map { assign($0, in: variableIndex) },
            triggers: triggers.map { Executable.ResolvedTrigger(condition: resolve($0.condition), kind: $0.kind) },
            handlers: handlers.map { handler in
                Executable.ResolvedHandler(origin: handler.origin, kind: handler.kind, actions: handler.actions.map { action in
                    let target: ResolvedTarget = variableIndex[action.target].map(ResolvedTarget.variable)
                        ?? .parameter(parameterIndex[action.target]!)
                    return Executable.ResolvedAction(target: target, op: action.op, expr: resolve(action.expr))
                })
            },
            parameterIndex: parameterIndex,
            variableHasInit: variableNames.map(initNames.contains),
            inputNames: inputNames,
            usedBuiltins: Set(usedBuiltins.compactMap(Builtin.init(rawValue:)))
        )
    }
}
