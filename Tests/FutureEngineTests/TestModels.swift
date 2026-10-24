import Foundation
import FutureEngine

func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.utcGregorian.date(from: components)!
}

/// Counts steps. Output `count` equals the step index.
struct CounterModel: TimelineModel {
    var rate: StepRate = .monthly
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Counter", stepRate: rate, variables: [Variable(name: "count", causality: .output)])
    }
    func start(_ context: StepContext) throws -> Int { 0 }
    func doStep(_ state: inout Int, _ context: StepContext) throws -> [GeneratedEvent] {
        state += 1
        return []
    }
    func values(of state: Int) -> [String: Double] { ["count": Double(state)] }
}

/// A random walk. `shock` events add their `amount`.
struct RandomWalk: TimelineModel {
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "RandomWalk", stepRate: .monthly, variables: [Variable(name: "x", causality: .output)],
                        capabilities: [.stochastic])
    }
    func start(_ context: StepContext) throws -> Double { 100 }
    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] {
        var random = context.makeRandom()
        state += random.normal(mean: 0, sd: 5)
        for event in context.events where event.kind == "shock" {
            state += event.values["amount"] ?? 0
        }
        return []
    }
    func values(of state: Double) -> [String: Double] { ["x": state] }
}

/// A daily temperature curve. Emits `Hot` when it rises above `threshold`.
struct DailyTemperature: TimelineModel {
    var threshold = 20.0
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Temperature", stepRate: .daily, variables: [Variable(name: "temp", causality: .output)],
                        emits: ["Hot"])
    }
    static func temperature(at date: Date) -> Double {
        let dayOfYear = Double(Calendar.utcGregorian.ordinality(of: .day, in: .year, for: date)!)
        return 12 + 10 * sin(2 * .pi * (dayOfYear - 105) / 365)
    }
    struct State: Sendable { var temp: Double; var wasHot: Bool }
    func start(_ context: StepContext) throws -> State {
        let temp = Self.temperature(at: context.to)
        return State(temp: temp, wasHot: temp > threshold)
    }
    func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        state.temp = Self.temperature(at: context.to)
        let isHot = state.temp > threshold
        defer { state.wasHot = isHot }
        return isHot && !state.wasHot ? [GeneratedEvent(kind: "Hot")] : []
    }
    func values(of state: State) -> [String: Double] { ["temp": state.temp] }
}

/// Reads one input by name and counts `Hot` events. Outputs `seen` and `hotEvents`.
struct Observer: TimelineModel {
    var source: Reference
    var rate: StepRate = .monthly
    var subscription: EventSubscription?
    var extraOutputs: [String] = []

    var descriptor: ModelDescriptor {
        var variables = [
            Variable(name: "seen", causality: .output),
            Variable(name: "hotEvents", causality: .output),
            Variable(name: "input", causality: .input, source: source),
        ]
        variables += extraOutputs.map { Variable(name: $0, causality: .output) }
        return ModelDescriptor(name: "Observer", stepRate: rate, variables: variables,
                               subscriptions: subscription.map { [$0] } ?? [])
    }
    struct State: Sendable { var seen: Double; var hotEvents: Double }
    func start(_ context: StepContext) throws -> State {
        State(seen: context.inputs["input"] ?? .nan, hotEvents: 0)
    }
    func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        state.seen = context.inputs["input"] ?? .nan
        state.hotEvents += Double(context.events.filter { $0.kind == "Hot" }.count)
        return []
    }
    func values(of state: State) -> [String: Double] {
        var values = ["seen": state.seen, "hotEvents": state.hotEvents]
        for name in extraOutputs { values[name] = state.seen }
        return values
    }
}
