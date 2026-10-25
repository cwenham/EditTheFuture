import FutureEngine

/// A validated program, with definitions in the order they must be evaluated.
struct CompiledProgram: Sendable {
    let stepRate: StepRate
    let timeUnit: StepRate
    let params: [Assignment]
    let inits: [Assignment]
    let definitionOrder: [Assignment]
    let odes: [Assignment]
    let triggers: [Trigger]
    let handlers: [Handler]
    let references: [Reference]
    /// Local variables in declaration order.
    let variableNames: [String]
    let isStochastic: Bool
    /// Built-ins the formula refers to, so the model only computes those each step.
    let usedBuiltins: Set<String>
}

enum Analyzer {
    static let keywords: Set<String> = ["step", "timeunit", "param", "init", "when", "emit", "on", "and", "or", "not", "event", "t"]
    static let builtins: Set<String> = ["pi", "step", "year", "month", "day", "dayOfYear", "days", "dt"]

    /// Allowed argument counts. `nil` as the upper bound means any number.
    static let functions: [String: (min: Int, max: Int?)] = [
        "min": (1, nil), "max": (1, nil),
        "abs": (1, 1), "sqrt": (1, 1), "exp": (1, 1), "log": (1, 1), "log10": (1, 1),
        "sin": (1, 1), "cos": (1, 1), "tan": (1, 1), "floor": (1, 1), "ceil": (1, 1), "round": (1, 1),
        "pow": (2, 2), "mod": (2, 2), "clamp": (3, 3), "if": (3, 3),
        "random": (0, 0), "normal": (2, 2),
    ]

    private enum Scope {
        /// Parameters: earlier parameters and built-ins only.
        case parameter(earlier: Set<String>)
        /// Initial values: parameters, built-ins, earlier inits and other slots.
        case initial(earlier: Set<String>)
        /// Definitions, differential equations, triggers and handlers: everything.
        case body
    }

    static func compile(_ program: Program) throws -> CompiledProgram {
        // Names and duplicates.
        var declared: Set<String> = []
        func declare(_ name: String, line: Int) throws {
            if keywords.contains(name) || builtins.contains(name) || functions[name] != nil {
                throw FormulaError.reservedName(name, line: line)
            }
            guard declared.insert(name).inserted else { throw FormulaError.duplicateName(name, line: line) }
        }
        let paramNames = Set(program.params.map(\.name))
        for param in program.params { try declare(param.name, line: param.line) }
        for declaration in program.params + program.inits + program.definitions + program.odes {
            let options = declaration.options
            if let low = options.minimum, let high = options.maximum, !(low.isFinite && high.isFinite && low < high) {
                throw FormulaError.invalid(line: declaration.line, message: "The range of \(declaration.name) must go from a smaller number to a larger one.")
            }
            if let step = options.increment, !(step.isFinite && step > 0) {
                throw FormulaError.invalid(line: declaration.line, message: "The step of \(declaration.name) must be more than 0.")
            }
        }

        var variableNames: [String] = []
        var initNames: Set<String> = []
        for initial in program.inits {
            try declare(initial.name, line: initial.line)
            initNames.insert(initial.name)
            variableNames.append(initial.name)
        }
        var definitionNames: Set<String> = []
        var odeNames: Set<String> = []
        for ode in program.odes {
            guard initNames.contains(ode.name) else {
                throw FormulaError.invalid(line: ode.line, message: "d\(ode.name)/dt needs a starting value: add init \(ode.name) = …")
            }
            guard odeNames.insert(ode.name).inserted else { throw FormulaError.duplicateName("d\(ode.name)/dt", line: ode.line) }
        }
        for definition in program.definitions {
            if odeNames.contains(definition.name) {
                throw FormulaError.invalid(line: definition.line, message: "\(definition.name) already has a differential equation.")
            }
            if paramNames.contains(definition.name) {
                throw FormulaError.duplicateName(definition.name, line: definition.line)
            }
            guard definitionNames.insert(definition.name).inserted else {
                throw FormulaError.duplicateName(definition.name, line: definition.line)
            }
            if !initNames.contains(definition.name) {
                try declare(definition.name, line: definition.line)
                variableNames.append(definition.name)
            }
        }
        let variables = Set(variableNames)

        // References in every expression.
        var usedBuiltins: Set<String> = []
        func check(_ expr: Expr, line: Int, scope: Scope) throws {
            try expr.visit { node in
                switch node {
                case .name(let name, let lagged):
                    if builtins.contains(name) { usedBuiltins.insert(name) }
                    if lagged {
                        guard variables.contains(name) else {
                            throw FormulaError.invalid(line: line, message: "Only variables have a previous value; \(name)[t-1] isn't allowed.")
                        }
                        if case .body = scope { return }
                        throw FormulaError.invalid(line: line, message: "\(name)[t-1] can't be used here.")
                    }
                    switch scope {
                    case .parameter(let earlier):
                        guard earlier.contains(name) || builtins.contains(name) else {
                            throw paramNames.contains(name) || variables.contains(name)
                                ? FormulaError.invalid(line: line, message: "A parameter can only use earlier parameters, not \(name).")
                                : FormulaError.unknownName(name, line: line)
                        }
                    case .initial(let earlier):
                        guard paramNames.contains(name) || builtins.contains(name) || earlier.contains(name) else {
                            throw variables.contains(name)
                                ? FormulaError.invalid(line: line, message: "A starting value can only use parameters and earlier starting values, not \(name).")
                                : FormulaError.unknownName(name, line: line)
                        }
                    case .body:
                        guard variables.contains(name) || paramNames.contains(name) || builtins.contains(name) else {
                            throw FormulaError.unknownName(name, line: line)
                        }
                    }
                case .input(let key):
                    if case .parameter = scope {
                        throw FormulaError.invalid(line: line, message: "A parameter can't read another slot (\(key)).")
                    }
                case .call(let function, let arguments):
                    guard let arity = functions[function] else { throw FormulaError.unknownFunction(function, line: line) }
                    if arguments.count < arity.min || arguments.count > (arity.max ?? Int.max) {
                        let expected: String
                        if arity.max == nil {
                            expected = "at least \(arity.min) argument\(arity.min == 1 ? "" : "s")"
                        } else if arity.min == arity.max {
                            expected = "\(arity.min) argument\(arity.min == 1 ? "" : "s")"
                        } else {
                            expected = "\(arity.min) to \(arity.max!) arguments"
                        }
                        throw FormulaError.wrongArgumentCount(function: function, expected: expected, line: line)
                    }
                case .number, .eventField, .unary, .binary:
                    break
                }
            }
        }

        var earlierParams: Set<String> = []
        for param in program.params {
            try check(param.expr, line: param.line, scope: .parameter(earlier: earlierParams))
            earlierParams.insert(param.name)
        }
        var earlierInits: Set<String> = []
        for initial in program.inits {
            try check(initial.expr, line: initial.line, scope: .initial(earlier: earlierInits))
            earlierInits.insert(initial.name)
        }
        for assignment in program.definitions + program.odes {
            try check(assignment.expr, line: assignment.line, scope: .body)
        }
        for trigger in program.triggers {
            try check(trigger.condition, line: trigger.line, scope: .body)
        }
        var subscriptions: [String: Timing] = [:]
        for handler in program.handlers {
            if let origin = handler.origin {
                let key = "\(origin).\(handler.kind)"
                if let existing = subscriptions[key], existing != handler.timing {
                    throw FormulaError.invalid(line: handler.line, message: "\(key) is handled both now and from the previous step. Pick one.")
                }
                subscriptions[key] = handler.timing
            } else if handler.kind == Event.setKind {
                throw FormulaError.invalid(line: handler.line, message: "set events change parameters automatically and can't have a handler.")
            }
            for action in handler.actions {
                guard variables.contains(action.target) || paramNames.contains(action.target) else {
                    throw FormulaError.unknownName(action.target, line: action.line)
                }
                try check(action.expr, line: action.line, scope: .body)
            }
        }

        // Definitions in dependency order; a same-step loop is an error.
        let definitionsByName = Dictionary(uniqueKeysWithValues: program.definitions.map { ($0.name, $0) })
        func sameStepDependencies(_ expr: Expr) -> [String] {
            var names: [String] = []
            expr.visit { node in
                if case .name(let name, false) = node, definitionsByName[name] != nil, !names.contains(name) {
                    names.append(name)
                }
            }
            return names
        }
        var order: [Assignment] = []
        var marks: [String: Int] = [:]  // 1 = on the current path, 2 = done
        var path: [String] = []
        func visit(_ name: String) throws {
            if marks[name] == 2 { return }
            if marks[name] == 1 {
                let loopStart = path.lastIndex(of: name)!
                throw FormulaError.sameStepLoop(Array(path[loopStart...]) + [name])
            }
            marks[name] = 1
            path.append(name)
            let definition = definitionsByName[name]!
            for dependency in sameStepDependencies(definition.expr) { try visit(dependency) }
            path.removeLast()
            marks[name] = 2
            order.append(definition)
        }
        for definition in program.definitions { try visit(definition.name) }

        // Randomness makes a model stochastic.
        var isStochastic = false
        var allExpressions: [Expr] = []
        allExpressions += program.params.map(\.expr)
        allExpressions += program.inits.map(\.expr)
        allExpressions += program.definitions.map(\.expr)
        allExpressions += program.odes.map(\.expr)
        allExpressions += program.triggers.map(\.condition)
        for handler in program.handlers {
            allExpressions += handler.actions.map(\.expr)
        }
        for expr in allExpressions {
            expr.visit { node in
                if case .call(let function, _) = node, function == "random" || function == "normal" { isStochastic = true }
            }
        }

        return CompiledProgram(
            stepRate: program.stepRate,
            timeUnit: program.timeUnit ?? program.stepRate.unit,
            params: program.params,
            inits: program.inits,
            definitionOrder: order,
            odes: program.odes,
            triggers: program.triggers,
            handlers: program.handlers,
            references: program.references.values.sorted { $0.text < $1.text },
            variableNames: variableNames,
            isStochastic: isStochastic,
            usedBuiltins: usedBuiltins
        )
    }
}
