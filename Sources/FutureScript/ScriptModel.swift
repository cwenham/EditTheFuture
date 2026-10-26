import Foundation
import FutureEngine

/// A model written as a Lua or Python script (docs/DESIGN.md, 6.4).
///
/// The script declares its parameters, state and inputs, and a `step(s, t)` function. The app keeps
/// the state as numbers and hands them to the script for each step, so checkpoints, undo and
/// previews work as they do for formulas.
public struct ScriptModel: AuthoredModel {
    /// Parameters, then state variables and outputs: the order of `descriptor.readable`.
    public struct State: Sendable {
        var values: [Double]
    }

    public let source: String
    public let language: ScriptLanguage
    public let descriptor: ModelDescriptor
    public let overrides: [String: Double]
    public let declaredDefaults: [String: Double]
    public let startingValues: [String: Double]
    public let parameterNames: [String]
    public let startingValueNames: [String]
    public let handledEventKinds: [String]

    let program: ScriptProgram
    private let initial: [Double]
    private let parameterIndex: [String: Int]
    private let readableNames: [String]
    /// The engine's name for each input, in the order the script declared them.
    private let inputKeys: [String]

    /// - Parameter values: the slot's own values for parameters and starting values, by name.
    ///   Names the script doesn't declare are ignored.
    public init(_ source: String, language: ScriptLanguage, name: String = "Script", values: [String: Double] = [:]) throws {
        let program = try ScriptPrograms.program(source, language: language)
        let shape = program.shape
        self.source = source
        self.language = language
        self.program = program

        parameterNames = shape.params.map(\.name)
        startingValueNames = shape.vars.filter(\.isInit).map(\.name)
        handledEventKinds = shape.ownKinds
        let settable = Set(parameterNames + startingValueNames)
        let overrides = values.filter { settable.contains($0.key) }
        self.overrides = overrides

        var defaults: [String: Double] = [:]
        for value in shape.params + shape.vars.filter(\.isInit) where value.start.isFinite {
            defaults[value.name] = value.start
        }
        declaredDefaults = defaults
        startingValues = defaults.merging(overrides) { $1 }

        let ordered = shape.params + shape.vars
        readableNames = ordered.map(\.name)
        initial = ordered.map { overrides[$0.name] ?? $0.start }
        var parameterIndex: [String: Int] = [:]
        for (index, param) in shape.params.enumerated() { parameterIndex[param.name] = index }
        self.parameterIndex = parameterIndex
        inputKeys = shape.inputs.map(\.reference.text)

        let stochastic = ["random", "normal", "gauss"].contains { source.contains($0) }
        descriptor = shape.descriptor(name: name, stochastic: stochastic)
    }

    public func start(_ context: StepContext) throws -> State {
        var values = initial
        if program.shape.hasStart {
            try failing {
                try program.start(&values, inputs: inputs(from: context), time: time(for: context))
            }
        }
        return State(values: values)
    }

    public func doStep(_ state: inout State, _ context: StepContext) throws -> [GeneratedEvent] {
        var events: [Event] = []
        for event in context.events {
            if event.kind == Event.setKind && event.originSlot == nil {
                for (name, value) in event.values {
                    if let index = parameterIndex[name] { state.values[index] = value }
                }
            } else {
                events.append(event)
            }
        }
        var values = state.values
        let generated = try failing {
            try program.step(&values, inputs: inputs(from: context), time: time(for: context), events: events)
        }
        state.values = values
        return generated
    }

    public func values(of state: State) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(readableNames, state.values))
    }

    public func readableValues(of state: State) -> [Double] {
        state.values
    }

    /// The script's state is already numbers (docs/DESIGN.md, 6.4).
    public func savedNumbers(of state: State) -> [Double]? {
        state.values
    }

    public func restoredState(from numbers: [Double]) -> State? {
        numbers.count == initial.count ? State(values: numbers) : nil
    }

    // MARK: Helpers

    /// Names the slot in errors the script raises.
    private func failing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch var error as ScriptError {
            error.slot = descriptor.name
            throw error
        }
    }

    private func inputs(from context: StepContext) -> [Double] {
        inputKeys.map { context.inputs[$0] ?? 0 }
    }

    private func time(for context: StepContext) -> ScriptTime {
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
        let fractionalYear = Double(year) + (Double(dayOfYear - 1) + fractionOfDay) / Double(daysInYear)
        let days = time.timeIntervalSince(context.scenarioStart) / 86_400
        let dt = context.index == 0 ? 0 : context.to.timeIntervalSince(context.from) / program.shape.timeUnit.approximateSeconds
        let date = ScriptEvents.dateText(year: year, month: month, day: day)
        return ScriptTime(numbers: [Double(context.index), fractionalYear, Double(month), Double(day), Double(dayOfYear), days, dt],
                          date: date, seed: context.seed, index: context.index)
    }
}
