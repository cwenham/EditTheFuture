import Foundation

/// FMI-style causality: which way a variable's information flows relative to its model.
public enum Causality: String, Hashable, Sendable, Codable {
    /// Set before or during a run; other slots can read it. Changed by `set` events.
    case parameter
    /// Supplied by another slot through a connection.
    case input
    /// Computed by the model; other slots can read it.
    case output
    /// Internal; hidden from other slots.
    case local
}

/// How a consumer reads a producer whose steps don't line up with its own.
public enum Resampling: String, Hashable, Sendable, Codable, CaseIterable {
    /// The producer's value at its last point at or before the consumer's point.
    case hold
    /// Mean of producer points inside the consumer's step window (falls back to `hold`).
    case mean
    /// Total of producer points inside the window (0 when there are none).
    case sum
    /// Minimum inside the window (falls back to `hold`).
    case min
    /// Maximum inside the window (falls back to `hold`).
    case max
}

/// When a connection or event route is read.
/// Same-step links must flow one way; feedback loops need at least one `previousStep` link.
public enum Timing: String, Hashable, Sendable, Codable {
    case sameStep
    case previousStep
}

/// A by-name reference to another slot's variable, such as `Climate.temp.mean[t-1]`.
public struct Reference: Hashable, Sendable, Codable {
    public var slot: String
    public var variable: String
    public var resampling: Resampling
    public var timing: Timing

    public init(slot: String, variable: String, resampling: Resampling = .hold, timing: Timing = .sameStep) {
        self.slot = slot
        self.variable = variable
        self.resampling = resampling
        self.timing = timing
    }

    /// Canonical text form, also used as the input variable's name.
    public var text: String {
        var text = "\(slot).\(variable)"
        if resampling != .hold { text += ".\(resampling.rawValue)" }
        if timing == .previousStep { text += "[t-1]" }
        return text
    }
}

/// What kind of quantity a variable holds, so the app knows how to write it and which control to offer.
public enum Quantity: String, Hashable, Sendable, Codable, CaseIterable {
    case number
    /// A fraction shown as a percent: 0.045 is 4.5%.
    case percent
    case currency
    case temperature
}

/// A named value a model exposes or needs (FMI: model variable).
public struct Variable: Hashable, Sendable, Codable {
    public var name: String
    public var causality: Causality
    public var unit: String?
    /// FMI's `start`: the default for inputs before any value arrives, or a documented initial value.
    public var start: Double
    /// For inputs: which slot variable to connect, by name. Formula models fill this in.
    public var source: Reference?
    /// The name people see, e.g. "Interest rate" for `rate` (FMI: `description`).
    public var label: String?
    /// The range a slider covers (FMI: `min` and `max`). Values outside it can still be typed.
    public var minimum: Double?
    public var maximum: Double?
    /// A slider's step.
    public var increment: Double?
    public var quantity: Quantity?

    public init(name: String, causality: Causality, unit: String? = nil, start: Double = 0, source: Reference? = nil,
                label: String? = nil, minimum: Double? = nil, maximum: Double? = nil, increment: Double? = nil,
                quantity: Quantity? = nil) {
        self.name = name
        self.causality = causality
        self.unit = unit
        self.start = start
        self.source = source
        self.label = label
        self.minimum = minimum
        self.maximum = maximum
        self.increment = increment
        self.quantity = quantity
    }
}

/// A request to receive events of one kind from another slot.
public struct EventSubscription: Hashable, Sendable, Codable {
    public var slot: String
    public var kind: String
    public var timing: Timing

    public init(slot: String, kind: String, timing: Timing = .sameStep) {
        self.slot = slot
        self.kind = kind
        self.timing = timing
    }
}

/// Hints that let the engine take shortcuts.
public enum Capability: String, Hashable, Sendable, Codable {
    case closedForm
    case stochastic
    case assimilatesReadings
}

/// What a model tells the engine about itself (the `describe` message).
public struct ModelDescriptor: Hashable, Sendable, Codable {
    public var name: String
    public var stepRate: StepRate
    public var variables: [Variable]
    public var emits: [String]
    public var subscriptions: [EventSubscription]
    public var capabilities: Set<Capability>

    public init(name: String, stepRate: StepRate, variables: [Variable], emits: [String] = [],
                subscriptions: [EventSubscription] = [], capabilities: Set<Capability> = []) {
        self.name = name
        self.stepRate = stepRate
        self.variables = variables
        self.emits = emits
        self.subscriptions = subscriptions
        self.capabilities = capabilities
    }

    public var inputs: [Variable] { variables.filter { $0.causality == .input } }

    /// Variables other slots may read: outputs and parameters.
    public var readable: [Variable] {
        variables.filter { $0.causality == .output || $0.causality == .parameter }
    }

    public func variable(named name: String) -> Variable? {
        variables.first { $0.name == name }
    }
}

/// An event a model emits during a step. The engine stamps it with the step's end point.
public struct GeneratedEvent: Hashable, Sendable {
    public var kind: String
    public var values: [String: Double]

    public init(kind: String, values: [String: Double] = [:]) {
        self.kind = kind
        self.values = values
    }
}

/// Everything a model receives for one step.
public struct StepContext: Sendable {
    /// Index of the communication point being computed. 0 is the start.
    public let index: Int
    /// The time this step covers. For index 0 it is the start instant.
    public let window: StepWindow
    public let stepRate: StepRate
    /// The scenario's start date.
    public let scenarioStart: Date
    /// Input values by input variable name.
    public let inputs: [String: Double]
    /// Authored, recurring and delivered generated events, in deterministic order.
    public let events: [Event]
    public let readings: [Reading]
    public let seed: UInt64
    public let calendar: Calendar

    public var from: Date { window.lower }
    public var to: Date { window.upper }

    /// A random generator unique to this slot and step, so recomputation reproduces results.
    public func makeRandom() -> SeededRandom {
        SeededRandom(seed: seed, stream: UInt64(index))
    }

    public init(index: Int, window: StepWindow, stepRate: StepRate, scenarioStart: Date,
                inputs: [String: Double], events: [Event], readings: [Reading], seed: UInt64,
                calendar: Calendar = .utcGregorian) {
        self.index = index
        self.window = window
        self.stepRate = stepRate
        self.scenarioStart = scenarioStart
        self.inputs = inputs
        self.events = events
        self.readings = readings
        self.seed = seed
        self.calendar = calendar
    }
}

/// A calculation or simulation that can run in a slot.
///
/// The engine treats `State` as a value: it copies it to make checkpoints and restores copies
/// to recompute. Models must be deterministic given the same state and context.
public protocol TimelineModel: Sendable {
    associatedtype State: Sendable

    var descriptor: ModelDescriptor { get }

    /// The state at the first communication point.
    func start(_ context: StepContext) throws -> State

    /// Advances one communication step (FMI: `fmi3DoStep`) and returns any events it generated.
    func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent]

    /// Current values of readable variables (outputs and parameters), by name.
    func values(of state: State) -> [String: Double]

    /// The same values in `descriptor.readable` order. The engine stores history this way, which is
    /// much faster than a dictionary per step. The default builds it from `values(of:)`.
    func readableValues(of state: State) -> [Double]
}

extension TimelineModel {
    public func readableValues(of state: State) -> [Double] {
        let values = values(of: state)
        return descriptor.readable.map { values[$0.name] ?? .nan }
    }
}

/// A small, fast random generator (SplitMix64) seeded per slot and step.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64, stream: UInt64 = 0) {
        state = splitMix(seed ^ splitMix(stream))
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Normally distributed (Box-Muller).
    public mutating func normal(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = Swift.max(uniform(), .leastNonzeroMagnitude)
        let u2 = uniform()
        return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}
