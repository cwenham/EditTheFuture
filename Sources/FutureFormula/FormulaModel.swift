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
    public struct State: Sendable {
        var params: [String: Double]
        var values: [String: Double]
        /// Whether each `when` condition was true at the previous point (triggers fire on rising edges).
        var triggerStates: [Bool]
    }

    /// RK4 substeps per communication step for differential equations.
    public static let odeSubsteps = 8

    public let source: String
    public let descriptor: ModelDescriptor
    private let program: CompiledProgram

    public init(_ source: String, name: String = "Formula") throws {
        self.source = source
        let program = try Analyzer.compile(Parser.parse(source))
        self.program = program

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
        var evaluator = Evaluator(params: [:], current: [:], previous: [:], inputs: context.inputs,
                                  builtins: builtins(for: context), random: context.makeRandom())
        for param in program.params {
            evaluator.params[param.name] = try evaluator.evaluate(param.expr)
        }
        for initial in program.inits {
            evaluator.current[initial.name] = try evaluator.evaluate(initial.expr)
        }
        // At the start, x[t-1] means the starting value (or 0).
        evaluator.previous = evaluator.current
        for definition in program.definitionOrder where evaluator.current[definition.name] == nil {
            evaluator.current[definition.name] = try evaluator.evaluate(definition.expr)
        }
        return State(params: evaluator.params, values: evaluator.current,
                     triggerStates: Array(repeating: false, count: program.triggers.count))
    }

    public func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        var evaluator = Evaluator(params: state.params, current: state.values, previous: state.values,
                                  inputs: context.inputs, builtins: builtins(for: context), random: context.makeRandom())

        // 1. Parameter changes.
        for event in context.events where event.kind == Event.setKind && event.originSlot == nil {
            for (name, value) in event.values where evaluator.params[name] != nil {
                evaluator.params[name] = value
            }
        }

        // 2. Differential equations (RK4).
        if !program.odes.isEmpty {
            try integrate(&evaluator, over: stepLength(context))
        }

        // 3. Definitions.
        for definition in program.definitionOrder {
            evaluator.current[definition.name] = try evaluator.evaluate(definition.expr)
        }

        // 4. Event handlers.
        for event in context.events where !(event.kind == Event.setKind && event.originSlot == nil) {
            for handler in program.handlers where handler.kind == event.kind && handler.origin == event.originSlot {
                evaluator.event = event
                for action in handler.actions {
                    let value = try evaluator.evaluate(action.expr)
                    let isParameter = evaluator.params[action.target] != nil
                    let old = (isParameter ? evaluator.params[action.target] : evaluator.current[action.target]) ?? 0
                    let new: Double
                    switch action.op {
                    case .set: new = value
                    case .add: new = old + value
                    case .subtract: new = old - value
                    case .multiply: new = old * value
                    case .divide: new = old / value
                    }
                    if isParameter {
                        evaluator.params[action.target] = new
                    } else {
                        evaluator.current[action.target] = new
                    }
                }
                evaluator.event = nil
            }
        }

        // 5. Triggers fire when their condition turns true.
        var generated: [GeneratedEvent] = []
        for (index, trigger) in program.triggers.enumerated() {
            let isTrue = try evaluator.evaluate(trigger.condition) != 0
            if isTrue && !state.triggerStates[index] {
                generated.append(GeneratedEvent(kind: trigger.kind))
            }
            state.triggerStates[index] = isTrue
        }

        state.params = evaluator.params
        state.values = evaluator.current
        return generated
    }

    public func values(of state: State) -> [String: Double] {
        state.params.merging(state.values) { _, variable in variable }
    }

    // MARK: Helpers

    /// Length of the step in the program's time unit (the step's own unit unless `timeunit` says otherwise).
    private func stepLength(_ context: StepContext) -> Double {
        context.to.timeIntervalSince(context.from) / program.timeUnit.approximateSeconds
    }

    private func integrate(_ evaluator: inout Evaluator, over length: Double) throws {
        let odes = program.odes
        var y = odes.map { evaluator.current[$0.name] ?? 0 }
        let h = length / Double(Self.odeSubsteps)
        func offset(_ y: [Double], _ k: [Double], _ factor: Double) -> [Double] {
            zip(y, k).map { $0 + factor * $1 }
        }
        for _ in 0..<Self.odeSubsteps {
            let k1 = try evaluator.derivatives(odes, at: y)
            let k2 = try evaluator.derivatives(odes, at: offset(y, k1, h / 2))
            let k3 = try evaluator.derivatives(odes, at: offset(y, k2, h / 2))
            let k4 = try evaluator.derivatives(odes, at: offset(y, k3, h))
            for i in y.indices {
                y[i] += h / 6 * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i])
            }
        }
        evaluator.stage = [:]
        for (ode, value) in zip(odes, y) { evaluator.current[ode.name] = value }
    }

    private func builtins(for context: StepContext) -> [String: Double] {
        let time = context.to
        let calendar = context.calendar
        let parts = calendar.dateComponents([.year, .month, .day], from: time)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: time) ?? 1
        let daysInYear = calendar.range(of: .day, in: .year, for: time)?.count ?? 365
        let startOfDay = calendar.startOfDay(for: time)
        let fractionOfDay = time.timeIntervalSince(startOfDay) / 86_400
        let year = Double(parts.year ?? 0) + (Double(dayOfYear - 1) + fractionOfDay) / Double(daysInYear)
        return [
            "pi": Double.pi,
            "step": Double(context.index),
            "year": year,
            "month": Double(parts.month ?? 1),
            "day": Double(parts.day ?? 1),
            "dayOfYear": Double(dayOfYear),
            "days": time.timeIntervalSince(context.scenarioStart) / 86_400,
            "dt": context.index == 0 ? 0 : stepLength(context),
        ]
    }
}
