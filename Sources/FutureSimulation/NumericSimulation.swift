import Foundation
import FutureEngine

/// A simulation whose state is a row of numbers: its parameters, starting values, outputs and any
/// hidden numbers it keeps, in that order (docs/DESIGN.md, 6.5). `NumericModel` wraps it for the
/// engine, so a module only writes its maths: parameters changed by `set` events, readings,
/// checkpoints and the cache are taken care of, as they are for scripts.
public protocol NumericSimulation: Sendable {
    var shape: SimulationShape { get }

    /// Works out the outputs at the start, from the parameters and starting values.
    func start(_ s: inout Numbers, _ t: StepTime)

    /// One step. `set` events have already changed the parameters, and readings of them are in;
    /// `events` are the slot's other events this step, in order. Returns the events it emits.
    func step(_ s: inout Numbers, _ t: StepTime, events: [Event]) -> [GeneratedEvent]

    /// A field from `shape.fields`, worked out from the numbers: one value per key, in order
    /// (docs/DESIGN.md, 4.10). The default has none.
    func field(_ name: String, of s: Numbers) -> [Double]?

    /// Whether a step with no events or readings would change nothing (docs/DESIGN.md, 4.11), so the
    /// engine can skip ahead. Asked only when `shape.settles`. The default is never.
    func isSettled(_ s: Numbers) -> Bool
}

extension NumericSimulation {
    public func field(_ name: String, of s: Numbers) -> [Double]? { nil }

    public func isSettled(_ s: Numbers) -> Bool { false }
}

/// What a numeric simulation declares: the order of its numbers, and what it handles and emits.
public struct SimulationShape: Sendable {
    public var step: StepRate
    /// The unit `StepTime.dt` is in.
    public var timeUnit: StepRate
    /// Values the Slot tab shows and `set` events change.
    public var parameters: [Variable]
    /// Values that carry from step to step, with their starting values.
    public var state: [Variable]
    /// Values worked out each step.
    public var outputs: [Variable]
    /// Numbers kept between steps but never shown, such as whether an event was emitted.
    public var hidden: [String]
    /// The slot's own event kinds it handles, besides `set`.
    public var handles: [String]
    public var emits: [String]
    public var stochastic: Bool
    /// Values per key it works out when asked, such as each country's share infected (docs/DESIGN.md, 4.10).
    public var fields: [FieldDescriptor]
    /// Whether it can settle (`NumericSimulation.isSettled`, docs/DESIGN.md 4.11).
    public var settles: Bool

    public init(step: StepRate, timeUnit: StepRate? = nil, parameters: [Variable], state: [Variable], outputs: [Variable] = [],
                hidden: [String] = [], handles: [String] = [], emits: [String] = [], stochastic: Bool = false,
                fields: [FieldDescriptor] = [], settles: Bool = false) {
        self.step = step
        self.timeUnit = timeUnit ?? step
        self.parameters = parameters.map { var v = $0; v.causality = .parameter; return v }
        self.state = state.map { var v = $0; v.causality = .output; return v }
        self.outputs = outputs.map { var v = $0; v.causality = .output; return v }
        self.hidden = hidden
        self.handles = handles
        self.emits = emits
        self.stochastic = stochastic
        self.fields = fields
        self.settles = settles
    }

    /// Every number's name, in the order of `Numbers`.
    public var names: [String] { (parameters + state + outputs).map(\.name) + hidden }
}

extension Variable {
    /// A parameter, as a formula's `param r0 = 2.5 range 0.1..20 by 0.1 label "R₀"` declares it.
    public static func parameter(_ name: String, _ value: Double, range: ClosedRange<Double>? = nil, by step: Double? = nil,
                                 label: String, as quantity: Quantity? = nil, fit: Bool = false) -> Variable {
        Variable(name: name, causality: .parameter, start: value, label: label, minimum: range?.lowerBound,
                 maximum: range?.upperBound, increment: step, quantity: quantity, fittable: fit)
    }

    /// A value: a starting value in `state`, or an output.
    public static func value(_ name: String, _ start: Double = 0, label: String, as quantity: Quantity? = nil,
                             fit: Bool = false) -> Variable {
        Variable(name: name, causality: .output, start: start, label: label, quantity: quantity, fittable: fit)
    }
}

/// A numeric simulation's numbers. Read and write them by position, or with an `Int` enum whose
/// cases follow `SimulationShape.names`.
public struct Numbers: Sendable, Equatable {
    public var values: [Double]

    public init(_ values: [Double]) {
        self.values = values
    }

    public subscript(_ index: Int) -> Double {
        get { values[index] }
        set { values[index] = newValue }
    }

    public subscript<Key: RawRepresentable>(_ key: Key) -> Double where Key.RawValue == Int {
        get { values[key.rawValue] }
        set { values[key.rawValue] = newValue }
    }

    /// True once each time `condition` turns from false to true, like a formula's `when`. The hidden
    /// number at `flag` remembers it between steps, so checkpoints keep it.
    public mutating func turnedTrue<Key: RawRepresentable>(_ condition: Bool, flag: Key) -> Bool where Key.RawValue == Int {
        let was = values[flag.rawValue] != 0
        values[flag.rawValue] = condition ? 1 : 0
        return condition && !was
    }
}

/// When a step is.
public struct StepTime: Sendable {
    /// 0 is the start.
    public let index: Int
    /// The end of the step.
    public let date: Date
    /// The step's length in the shape's time unit; 0 at the start.
    public let dt: Double
    /// Days since the scenario's start.
    public let days: Double
    let seed: UInt64

    /// A random generator for this slot and step, so computing it again gives the same numbers.
    public func makeRandom() -> SeededRandom { SeededRandom(seed: seed, stream: UInt64(index)) }

    init(_ context: StepContext, timeUnit: StepRate) {
        index = context.index
        date = context.to
        dt = context.index == 0 ? 0 : context.to.timeIntervalSince(context.from) / timeUnit.approximateSeconds
        days = context.to.timeIntervalSince(context.scenarioStart) / 86_400
        seed = context.seed
    }
}

/// A numeric simulation as the engine runs it in a slot.
public struct NumericModel<Simulation: NumericSimulation>: AuthoredModel {
    public struct State: Sendable {
        var numbers: Numbers
    }

    public let simulation: Simulation
    /// The module it came from, e.g. `epidemic@1`: it has no text of its own.
    public let source: String
    public let descriptor: ModelDescriptor
    public let overrides: [String: Double]
    public let declaredDefaults: [String: Double]
    public let startingValues: [String: Double]
    public let parameterNames: [String]
    public let startingValueNames: [String]
    public let handledEventKinds: [String]

    private let shape: SimulationShape
    private let initial: [Double]
    private let readableNames: [String]
    private let parameterIndex: [String: Int]
    private let readableIndex: [String: Int]

    /// - Parameter values: the slot's own values for parameters and starting values, by name.
    ///   Other names are ignored.
    public init(_ simulation: Simulation, source: String, name: String, values: [String: Double] = [:]) {
        let shape = simulation.shape
        self.simulation = simulation
        self.shape = shape
        self.source = source
        parameterNames = shape.parameters.map(\.name)
        startingValueNames = shape.state.map(\.name)
        handledEventKinds = shape.handles
        let settable = Set(shape.parameters.map(\.name) + shape.state.map(\.name))
        let overrides = values.filter { settable.contains($0.key) }
        self.overrides = overrides

        var defaults: [String: Double] = [:]
        for variable in shape.parameters + shape.state where variable.start.isFinite { defaults[variable.name] = variable.start }
        declaredDefaults = defaults
        startingValues = defaults.merging(overrides) { $1 }

        let readable = shape.parameters + shape.state + shape.outputs
        let readableNames = readable.map(\.name)
        self.readableNames = readableNames
        initial = readable.map { overrides[$0.name] ?? $0.start } + shape.hidden.map { _ in 0 }
        parameterIndex = Dictionary(shape.parameters.enumerated().map { ($0.element.name, $0.offset) }) { first, _ in first }
        readableIndex = Dictionary(readableNames.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        var capabilities: Set<Capability> = []
        if shape.stochastic { capabilities.insert(.stochastic) }
        if shape.settles { capabilities.insert(.settles) }
        descriptor = ModelDescriptor(name: name, stepRate: shape.step, variables: readable, emits: shape.emits,
                                     capabilities: capabilities, fields: shape.fields)
    }

    public func start(_ context: StepContext) throws -> State {
        var numbers = Numbers(initial)
        var ignored: [Prediction] = []
        applyReadings(context.readings, to: &numbers, parameters: true, replaced: &ignored)
        simulation.start(&numbers, StepTime(context, timeUnit: shape.timeUnit))
        applyReadings(context.readings, to: &numbers, parameters: false, replaced: &ignored)
        return State(numbers: numbers)
    }

    public func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        var ignored: [Prediction] = []
        return try doStep(&state, context, replaced: &ignored)
    }

    public func doStep(_ state: inout State, _ context: StepContext, replaced: inout [Prediction]) throws -> [GeneratedEvent] {
        var events: [Event] = []
        for event in context.events {
            if event.kind == Event.setKind && event.originSlot == nil {
                for (name, value) in event.values {
                    if let index = parameterIndex[name] { state.numbers[index] = value }
                }
            } else {
                events.append(event)
            }
        }
        var ignored: [Prediction] = []
        applyReadings(context.readings, to: &state.numbers, parameters: true, replaced: &ignored)
        let generated = simulation.step(&state.numbers, StepTime(context, timeUnit: shape.timeUnit), events: events)
        applyReadings(context.readings, to: &state.numbers, parameters: false, replaced: &replaced)
        return generated
    }

    public func replacingValues(_ values: [String: Double]) throws -> NumericModel {
        NumericModel(simulation, source: source, name: descriptor.name, values: overrides.merging(values) { $1 })
    }

    public func values(of state: State) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(readableNames, state.numbers.values))
    }

    public func readableValues(of state: State) -> [Double] {
        Array(state.numbers.values.prefix(readableNames.count))
    }

    public func savedNumbers(of state: State) -> [Double]? {
        state.numbers.values
    }

    public func restoredState(from numbers: [Double]) -> State? {
        numbers.count == initial.count ? State(numbers: Numbers(numbers)) : nil
    }

    public func field(_ name: String, of state: State) -> [Double]? {
        simulation.field(name, of: state.numbers)
    }

    public func isSettled(_ state: State) -> Bool {
        simulation.isSettled(state.numbers)
    }

    /// Readings correct the model, as they do for formulas and scripts (docs/DESIGN.md, 4.6): a
    /// reading of a parameter sets it before the step, and a reading of a value replaces it after.
    private func applyReadings(_ readings: [Reading], to numbers: inout Numbers, parameters: Bool,
                               replaced: inout [Prediction]) {
        for reading in readings {
            guard let index = readableIndex[reading.variable], (parameterIndex[reading.variable] != nil) == parameters else { continue }
            if !parameters, !replaced.contains(where: { $0.variable == reading.variable }) {
                replaced.append(Prediction(variable: reading.variable, value: numbers[index]))
            }
            numbers[index] = reading.value
        }
    }
}
