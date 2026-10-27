import Foundation
import FutureEngine

/// A model written in the formula language and typed into the app.
///
/// ```
/// step 1 month
/// param rate = 5%
/// param deposit = 200
/// init balance = 1000
/// balance[t] = balance[t-1] * (1 + rate / 12) + deposit
/// ```
///
/// Each step: `set` events and readings of parameters update parameters, differential equations
/// are integrated, definitions are evaluated in dependency order, `on` handlers run, readings of
/// values replace them, then `when` triggers fire.
public struct FormulaModel: AuthoredModel {
    /// Parameter and variable values by position (see `Executable`), so steps use arrays, not dictionaries.
    public struct State: Sendable {
        var parameters: [Double]
        var values: [Double]
        /// Whether each `when` condition was true at the previous point (triggers fire on rising edges).
        var triggerStates: [Bool]
    }

    /// RK4 substeps per communication step for differential equations.
    public static let odeSubsteps = 8

    public let source: String
    public let descriptor: ModelDescriptor
    private let program: CompiledProgram
    private let executable: Executable

    /// Kinds of this slot's own events that the formula handles with `on kind:`, in order.
    /// `set` events are always handled (they change parameters) and aren't listed.
    public var handledEventKinds: [String] {
        var kinds: [String] = []
        for handler in program.handlers where handler.origin == nil && !kinds.contains(handler.kind) {
            kinds.append(handler.kind)
        }
        return kinds
    }

    /// Parameter names in declaration order.
    public var parameterNames: [String] { program.params.map(\.name) }

    /// Variables with an `init` line, in declaration order: the values a slot can set at its start.
    public var startingValueNames: [String] { program.inits.map(\.name) }

    /// The slot's own values for parameters and starting values, which replace the formula's
    /// defaults at the start (like an SSP parameter binding). `set` events still change parameters later.
    public let overrides: [String: Double]

    /// Each parameter's and starting value's default as the formula writes it, when it can be worked
    /// out without running the model: numbers, `pi`, and earlier parameters and starting values.
    public let declaredDefaults: [String: Double]

    /// The same with `overrides` applied: what the slot starts with. A default that depends on an
    /// overridden parameter (`init P = K / 10`) follows it.
    public let startingValues: [String: Double]

    private let parameterOverrides: [Int: Double]
    private let initOverrides: [Int: Double]
    /// Each variable's position in `State.values`, for readings.
    private let variableIndex: [String: Int]

    /// - Parameter values: the slot's own values for parameters and starting values, by name.
    ///   Names the formula doesn't declare are ignored.
    public init(_ source: String, name: String = "Formula", values: [String: Double] = [:]) throws {
        self.source = source
        let program = try Analyzer.compile(Parser.parse(source))
        self.program = program
        let executable = program.makeExecutable()
        self.executable = executable

        let declared = Set(program.params.map(\.name) + program.inits.map(\.name))
        overrides = values.filter { declared.contains($0.key) }
        var parameterOverrides: [Int: Double] = [:]
        for (index, param) in program.params.enumerated() { parameterOverrides[index] = overrides[param.name] }
        var initOverrides: [Int: Double] = [:]
        for (position, initial) in program.inits.enumerated() { initOverrides[executable.inits[position].index] = overrides[initial.name] }
        self.parameterOverrides = parameterOverrides
        self.initOverrides = initOverrides
        variableIndex = Dictionary(program.variableNames.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        declaredDefaults = Self.constantValues(program, executable, overrides: [:])
        startingValues = Self.constantValues(program, executable, overrides: overrides)

        func describe(_ name: String, _ causality: Causality, _ options: DeclarationOptions?) -> Variable {
            Variable(name: name, causality: causality, label: options?.label, minimum: options?.minimum,
                     maximum: options?.maximum, increment: options?.increment, quantity: options?.quantity)
        }
        // A variable's options can be on its init line or the line that defines it; the init line wins.
        var outputOptions: [String: DeclarationOptions] = [:]
        for assignment in program.inits + program.definitionOrder + program.odes {
            var options = outputOptions[assignment.name] ?? DeclarationOptions()
            options.label = options.label ?? assignment.options.label
            options.minimum = options.minimum ?? assignment.options.minimum
            options.maximum = options.maximum ?? assignment.options.maximum
            options.increment = options.increment ?? assignment.options.increment
            options.quantity = options.quantity ?? assignment.options.quantity
            outputOptions[assignment.name] = options
        }
        var variables = program.params.map { describe($0.name, .parameter, $0.options) }
        variables += program.variableNames.map { describe($0, .output, outputOptions[$0]) }
        variables += program.references.map { Variable(name: $0.text, causality: .input, source: $0) }

        var emits: [String] = []
        for trigger in program.triggers where !emits.contains(trigger.kind) { emits.append(trigger.kind) }

        var subscriptions: [EventSubscription] = []
        for handler in program.handlers {
            guard let origin = handler.origin else { continue }
            let subscription = EventSubscription(slot: origin, kind: handler.kind, timing: handler.timing)
            if !subscriptions.contains(subscription) { subscriptions.append(subscription) }
        }

        descriptor = ModelDescriptor(name: name, stepRate: program.stepRate, variables: variables, emits: emits,
                                     subscriptions: subscriptions,
                                     capabilities: program.isStochastic ? [.stochastic] : [])
    }

    public func start(_ context: StepContext) throws -> State {
        let zeros = [Double](repeating: 0, count: executable.variableCount)
        var evaluator = Evaluator(parameters: [Double](repeating: 0, count: executable.parameterCount),
                                  current: zeros, previous: zeros, inputs: inputs(from: context),
                                  builtins: builtins(for: context), random: context.makeRandom())
        for parameter in executable.parameters {
            if let value = parameterOverrides[parameter.index] {
                evaluator.parameters[parameter.index] = value
            } else {
                evaluator.parameters[parameter.index] = try evaluator.evaluate(parameter.expr)
            }
        }
        applyParameterReadings(context.readings, to: &evaluator.parameters)
        for initial in executable.inits {
            if let value = initOverrides[initial.index] {
                evaluator.current[initial.index] = value
            } else {
                evaluator.current[initial.index] = try evaluator.evaluate(initial.expr)
            }
        }
        // At the start, x[t-1] means the starting value (or 0).
        evaluator.previous = evaluator.current
        for definition in executable.definitions where !executable.variableHasInit[definition.index] {
            evaluator.current[definition.index] = try evaluator.evaluate(definition.expr)
        }
        applyValueReadings(context.readings, to: &evaluator.current)
        return State(parameters: evaluator.parameters, values: evaluator.current,
                     triggerStates: Array(repeating: false, count: executable.triggers.count))
    }

    public func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        var evaluator = Evaluator(parameters: state.parameters, current: state.values, previous: state.values,
                                  inputs: inputs(from: context), builtins: builtins(for: context),
                                  random: context.makeRandom())

        // 1. Parameter changes, then readings of parameters.
        for event in context.events where event.kind == Event.setKind && event.originSlot == nil {
            for (name, value) in event.values {
                if let index = executable.parameterIndex[name] { evaluator.parameters[index] = value }
            }
        }
        applyParameterReadings(context.readings, to: &evaluator.parameters)

        // 2. Differential equations (RK4).
        if !executable.odes.isEmpty {
            try integrate(&evaluator, over: stepLength(context))
        }

        // 3. Definitions.
        for definition in executable.definitions {
            evaluator.current[definition.index] = try evaluator.evaluate(definition.expr)
        }

        // 4. Event handlers.
        if !context.events.isEmpty {
            for event in context.events where !(event.kind == Event.setKind && event.originSlot == nil) {
                for handler in executable.handlers where handler.kind == event.kind && handler.origin == event.originSlot {
                    evaluator.event = event
                    for action in handler.actions {
                        let value = try evaluator.evaluate(action.expr)
                        let old: Double
                        switch action.target {
                        case .variable(let index): old = evaluator.current[index]
                        case .parameter(let index): old = evaluator.parameters[index]
                        }
                        let new: Double
                        switch action.op {
                        case .set: new = value
                        case .add: new = old + value
                        case .subtract: new = old - value
                        case .multiply: new = old * value
                        case .divide: new = old / value
                        }
                        switch action.target {
                        case .variable(let index): evaluator.current[index] = new
                        case .parameter(let index): evaluator.parameters[index] = new
                        }
                    }
                    evaluator.event = nil
                }
            }
        }

        // 5. Readings replace the values they're readings of (docs/DESIGN.md, 4.6).
        applyValueReadings(context.readings, to: &evaluator.current)

        // 6. Triggers fire when their condition turns true.
        var generated: [GeneratedEvent] = []
        for (index, trigger) in executable.triggers.enumerated() {
            let isTrue = try evaluator.evaluate(trigger.condition) != 0
            if isTrue && !state.triggerStates[index] {
                generated.append(GeneratedEvent(kind: trigger.kind))
            }
            state.triggerStates[index] = isTrue
        }

        state.parameters = evaluator.parameters
        state.values = evaluator.current
        return generated
    }

    public func values(of state: State) -> [String: Double] {
        var values: [String: Double] = [:]
        for (name, index) in executable.parameterIndex { values[name] = state.parameters[index] }
        for (index, name) in program.variableNames.enumerated() { values[name] = state.values[index] }
        return values
    }

    /// Parameters then variables: the same order as `descriptor.readable`.
    public func readableValues(of state: State) -> [Double] {
        state.parameters + state.values
    }

    /// Parameters, variables, then each `when` condition as 1 or 0.
    public func savedNumbers(of state: State) -> [Double]? {
        state.parameters + state.values + state.triggerStates.map { $0 ? 1 : 0 }
    }

    public func restoredState(from numbers: [Double]) -> State? {
        let parameters = executable.parameterCount, variables = executable.variableCount
        guard numbers.count == parameters + variables + executable.triggers.count else { return nil }
        return State(parameters: Array(numbers[..<parameters]),
                     values: Array(numbers[parameters..<(parameters + variables)]),
                     triggerStates: numbers[(parameters + variables)...].map { $0 != 0 })
    }

    // MARK: Helpers

    /// Readings correct the model (docs/DESIGN.md, 4.6). The latest reading of a parameter in a
    /// step sets it, as a `set` event would.
    private func applyParameterReadings(_ readings: [Reading], to parameters: inout [Double]) {
        for reading in readings {
            if let index = executable.parameterIndex[reading.variable] { parameters[index] = reading.value }
        }
    }

    /// The latest reading of a value in a step replaces what the step worked out, so the next step
    /// carries on from what was observed.
    private func applyValueReadings(_ readings: [Reading], to values: inout [Double]) {
        for reading in readings {
            if let index = variableIndex[reading.variable] { values[index] = reading.value }
        }
    }

    /// Params and inits that are constants (numbers, `pi`, earlier constants), worked out without a
    /// step context. Ones that read the date, another slot or randomness are left out.
    private static func constantValues(_ program: CompiledProgram, _ executable: Executable,
                                       overrides: [String: Double]) -> [String: Double] {
        var builtins = [Double](repeating: 0, count: Builtin.allCases.count)
        builtins[Builtin.pi.index] = Double.pi
        var evaluator = Evaluator(parameters: [Double](repeating: 0, count: executable.parameterCount),
                                  current: [Double](repeating: 0, count: executable.variableCount),
                                  previous: [Double](repeating: 0, count: executable.variableCount),
                                  inputs: [Double](repeating: 0, count: executable.inputNames.count),
                                  builtins: builtins, random: SeededRandom(seed: 0))
        var known: [String: Double] = [:]
        func isConstant(_ expr: Expr) -> Bool {
            var constant = true
            expr.visit { node in
                switch node {
                case .name(let name, let lagged):
                    if lagged || !(known[name] != nil || name == "pi") { constant = false }
                case .input, .eventField:
                    constant = false
                case .call(let function, _):
                    if function == "random" || function == "normal" { constant = false }
                case .number, .unary, .binary:
                    break
                }
            }
            return constant
        }
        for (param, resolved) in zip(program.params, executable.parameters) {
            if let value = overrides[param.name] {
                known[param.name] = value
            } else if isConstant(param.expr), let value = try? evaluator.evaluate(resolved.expr) {
                known[param.name] = value
            } else {
                continue
            }
            evaluator.parameters[resolved.index] = known[param.name]!
        }
        for (initial, resolved) in zip(program.inits, executable.inits) {
            if let value = overrides[initial.name] {
                known[initial.name] = value
            } else if isConstant(initial.expr), let value = try? evaluator.evaluate(resolved.expr) {
                known[initial.name] = value
            } else {
                continue
            }
            evaluator.current[resolved.index] = known[initial.name]!
        }
        return known
    }

    private func inputs(from context: StepContext) -> [Double] {
        executable.inputNames.map { context.inputs[$0] ?? 0 }
    }

    /// Length of the step in the program's time unit (the step's own unit unless `timeunit` says otherwise).
    private func stepLength(_ context: StepContext) -> Double {
        context.to.timeIntervalSince(context.from) / program.timeUnit.approximateSeconds
    }

    /// RK4 over the step. Stage values of the ODE variables are written into `current`; every
    /// other variable still holds the previous step's value while derivatives are evaluated.
    private func integrate(_ evaluator: inout Evaluator, over length: Double) throws {
        let odes = executable.odes
        var y = odes.map { evaluator.current[$0.index] }
        let h = length / Double(Self.odeSubsteps)
        func derivatives(at values: [Double]) throws -> [Double] {
            for (ode, value) in zip(odes, values) { evaluator.current[ode.index] = value }
            var result: [Double] = []
            result.reserveCapacity(odes.count)
            for ode in odes { result.append(try evaluator.evaluate(ode.expr)) }
            return result
        }
        func offset(_ y: [Double], _ k: [Double], _ factor: Double) -> [Double] {
            zip(y, k).map { $0 + factor * $1 }
        }
        for _ in 0..<Self.odeSubsteps {
            let k1 = try derivatives(at: y)
            let k2 = try derivatives(at: offset(y, k1, h / 2))
            let k3 = try derivatives(at: offset(y, k2, h / 2))
            let k4 = try derivatives(at: offset(y, k3, h))
            for i in y.indices {
                y[i] += h / 6 * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i])
            }
        }
        for (ode, value) in zip(odes, y) { evaluator.current[ode.index] = value }
    }

    /// Values of the built-ins this formula uses (and only those) at the end of the step, by `Builtin` position.
    private func builtins(for context: StepContext) -> [Double] {
        var values = [Double](repeating: 0, count: Builtin.allCases.count)
        let used = executable.usedBuiltins
        guard !used.isEmpty else { return values }
        if used.contains(.pi) { values[Builtin.pi.index] = Double.pi }
        if used.contains(.step) { values[Builtin.step.index] = Double(context.index) }
        if used.contains(.days) { values[Builtin.days.index] = context.to.timeIntervalSince(context.scenarioStart) / 86_400 }
        if used.contains(.dt) { values[Builtin.dt.index] = context.index == 0 ? 0 : stepLength(context) }
        guard used.contains(.year) || used.contains(.month) || used.contains(.day) || used.contains(.dayOfYear) else {
            return values
        }

        let time = context.to
        let year: Int, month: Int, day: Int, dayOfYear: Int, daysInYear: Int
        let fractionOfDay: Double
        if context.calendar.isUTCGregorian {
            let civil = CivilDate(time)
            (year, month, day) = (civil.year, civil.month, civil.day)
            dayOfYear = civil.dayOfYear
            daysInYear = civil.daysInYear
            fractionOfDay = civil.secondsIntoDay / 86_400
        } else {
            let calendar = context.calendar
            let parts = calendar.dateComponents([.year, .month, .day], from: time)
            (year, month, day) = (parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
            dayOfYear = calendar.ordinality(of: .day, in: .year, for: time) ?? 1
            daysInYear = calendar.range(of: .day, in: .year, for: time)?.count ?? 365
            fractionOfDay = time.timeIntervalSince(calendar.startOfDay(for: time)) / 86_400
        }
        values[Builtin.year.index] = Double(year) + (Double(dayOfYear - 1) + fractionOfDay) / Double(daysInYear)
        values[Builtin.month.index] = Double(month)
        values[Builtin.day.index] = Double(day)
        values[Builtin.dayOfYear.index] = Double(dayOfYear)
        return values
    }
}
