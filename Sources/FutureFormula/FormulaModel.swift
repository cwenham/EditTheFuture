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
/// Each step: `set` events update parameters, differential equations are integrated,
/// definitions are evaluated in dependency order, `on` handlers run, then `when` triggers fire.
public struct FormulaModel: TimelineModel {
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

    public init(_ source: String, name: String = "Formula") throws {
        self.source = source
        let program = try Analyzer.compile(Parser.parse(source))
        self.program = program
        self.executable = program.makeExecutable()

        var variables = program.params.map { Variable(name: $0.name, causality: .parameter) }
        variables += program.variableNames.map { Variable(name: $0, causality: .output) }
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
            evaluator.parameters[parameter.index] = try evaluator.evaluate(parameter.expr)
        }
        for initial in executable.inits {
            evaluator.current[initial.index] = try evaluator.evaluate(initial.expr)
        }
        // At the start, x[t-1] means the starting value (or 0).
        evaluator.previous = evaluator.current
        for definition in executable.definitions where !executable.variableHasInit[definition.index] {
            evaluator.current[definition.index] = try evaluator.evaluate(definition.expr)
        }
        return State(parameters: evaluator.parameters, values: evaluator.current,
                     triggerStates: Array(repeating: false, count: executable.triggers.count))
    }

    public func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        var evaluator = Evaluator(parameters: state.parameters, current: state.values, previous: state.values,
                                  inputs: inputs(from: context), builtins: builtins(for: context),
                                  random: context.makeRandom())

        // 1. Parameter changes.
        for event in context.events where event.kind == Event.setKind && event.originSlot == nil {
            for (name, value) in event.values {
                if let index = executable.parameterIndex[name] { evaluator.parameters[index] = value }
            }
        }

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

        // 5. Triggers fire when their condition turns true.
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

    // MARK: Helpers

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
