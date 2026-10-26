import Foundation
import FutureEngine

/// What a script declared when it loaded, as its runtime reports it in JSON. Both languages
/// report the same thing.
struct ScriptDescription: Decodable, Sendable {
    struct Value: Decodable, Sendable {
        var name: String
        /// nil when the value isn't finite (JSON has no infinity or NaN).
        var value: Double?
        var label: String?
        var min: Double?
        var max: Double?
        var by: Double?
        var `as`: String?
        /// For state variables: declared with `init` rather than `output`.
        var isInit: Bool?
    }

    struct Input: Decodable, Sendable {
        var name: String
        var ref: String
    }

    var every: String?
    var timeunit: String?
    var params: [Value]
    var vars: [Value]
    var inputs: [Input]
    var emits: [String]
    /// Each `on` handler's kind as written: "deposit", "FireRisk.OverCapacity[t-1]".
    var handlers: [String]
    var hasStep: Bool
    var hasStart: Bool
}

/// A script's declarations, checked and turned into what the engine needs.
struct ScriptShape: Sendable {
    struct Value: Sendable {
        var name: String
        var start: Double
        var isInit: Bool
        var label: String?
        var minimum: Double?
        var maximum: Double?
        var increment: Double?
        var quantity: Quantity?
    }

    var stepRate: StepRate
    var timeUnit: StepRate
    var params: [Value]
    /// State variables and outputs, in declaration order.
    var vars: [Value]
    /// Each input's name in the script, and the reference it reads.
    var inputs: [(name: String, reference: Reference)]
    var emits: [String]
    /// Own event kinds handled with `on`, in order.
    var ownKinds: [String]
    var subscriptions: [EventSubscription]
    var hasStart: Bool

    init(_ description: ScriptDescription, language: ScriptLanguage) throws {
        guard let every = description.every else {
            throw ScriptError("Say how often the script steps, for example \(language.call("every", "1 month")).")
        }
        guard let rate = Self.stepRate(every) else {
            throw ScriptError("\"\(every)\" isn't a step rate. Write a number and a unit, like \"1 month\" or \"2 weeks\".")
        }
        stepRate = rate
        if let text = description.timeunit {
            guard let unit = Self.stepRate(text), unit == unit.unit else {
                throw ScriptError("\"\(text)\" isn't a time unit. Use second, minute, hour, day, week, month, quarter or year.")
            }
            timeUnit = unit
        } else {
            timeUnit = rate.unit
        }

        func value(_ value: ScriptDescription.Value, isInit: Bool) throws -> Value {
            var quantity: Quantity?
            if let text = value.as {
                guard let known = Quantity(rawValue: text) else {
                    throw ScriptError("\(value.name): \"\(text)\" isn't a way to show a value. Use number, percent, currency or temperature.")
                }
                quantity = known
            }
            return Value(name: value.name, start: value.value ?? .nan, isInit: isInit, label: value.label,
                         minimum: value.min, maximum: value.max, increment: value.by, quantity: quantity)
        }
        params = try description.params.map { try value($0, isInit: true) }
        vars = try description.vars.map { try value($0, isInit: $0.isInit ?? false) }

        inputs = try description.inputs.map { input in
            guard let reference = Self.reference(input.ref) else {
                throw ScriptError("input \"\(input.name)\": \"\(input.ref)\" isn't a reference to another slot. "
                                  + "Write it like \"Climate.temp\", \"Climate.temp.mean\" or \"Climate.temp[t-1]\".")
            }
            return (input.name, reference)
        }
        emits = description.emits

        var ownKinds: [String] = []
        var subscriptions: [EventSubscription] = []
        for text in description.handlers {
            if let subscription = Self.subscription(text) {
                if !subscriptions.contains(subscription) { subscriptions.append(subscription) }
            } else if Self.isName(text) {
                if text != Event.setKind && !ownKinds.contains(text) { ownKinds.append(text) }
            } else {
                throw ScriptError("on \"\(text)\": write an event kind like \"deposit\", or another slot's like \"FireRisk.OverCapacity\".")
            }
        }
        self.ownKinds = ownKinds
        self.subscriptions = subscriptions

        guard description.hasStep || !description.handlers.isEmpty else {
            throw ScriptError("Define a step function, starting \(language.stepFunctionExample), that works out each step.")
        }
        hasStart = description.hasStart
    }

    /// The model's descriptor: parameters, then state variables and outputs, then inputs.
    func descriptor(name: String, stochastic: Bool) -> ModelDescriptor {
        func describe(_ value: Value, _ causality: Causality) -> Variable {
            Variable(name: value.name, causality: causality, start: value.start.isFinite ? value.start : 0,
                     label: value.label, minimum: value.minimum, maximum: value.maximum,
                     increment: value.increment, quantity: value.quantity)
        }
        var variables = params.map { describe($0, .parameter) } + vars.map { describe($0, .output) }
        var seen = Set<String>()
        for input in inputs where seen.insert(input.reference.text).inserted {
            variables.append(Variable(name: input.reference.text, causality: .input, source: input.reference))
        }
        return ModelDescriptor(name: name, stepRate: stepRate, variables: variables, emits: emits,
                               subscriptions: subscriptions, capabilities: stochastic ? [.stochastic] : [])
    }

    // MARK: Parsing

    static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// "1 month", "month", "2 weeks", "monthly".
    static func stepRate(_ text: String) -> StepRate? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let adverbs: [String: StepRate] = ["hourly": .hours(1), "daily": .days(1), "weekly": .weeks(1), "monthly": .months(1),
                                           "quarterly": .quarters(1), "yearly": .years(1), "annually": .years(1)]
        if words.count == 1, let rate = adverbs[words[0]] { return rate }
        let count: Int, unit: String
        switch words.count {
        case 1: (count, unit) = (1, words[0])
        case 2:
            guard let number = Int(words[0]), number > 0 else { return nil }
            (count, unit) = (number, words[1])
        default: return nil
        }
        let singular = unit.hasSuffix("s") ? String(unit.dropLast()) : unit
        switch singular {
        case "second": return .seconds(count)
        case "minute": return .minutes(count)
        case "hour": return .hours(count)
        case "day": return .days(count)
        case "week": return .weeks(count)
        case "month": return .months(count)
        case "quarter": return .quarters(count)
        case "year": return .years(count)
        default: return nil
        }
    }

    /// "Climate.temp", "Climate.temp.mean", "Climate.temp[t-1]", "Climate.temp.mean[t-1]".
    static func reference(_ text: String) -> Reference? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var timing = Timing.sameStep
        if body.hasSuffix("[t-1]") {
            body.removeLast(5)
            timing = .previousStep
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy(isName) else { return nil }
        var resampling = Resampling.hold
        if parts.count == 3 {
            guard let known = Resampling(rawValue: parts[2]) else { return nil }
            resampling = known
        }
        return Reference(slot: parts[0], variable: parts[1], resampling: resampling, timing: timing)
    }

    /// "FireRisk.OverCapacity" or "FireRisk.OverCapacity[t-1]".
    static func subscription(_ text: String) -> EventSubscription? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var timing = Timing.sameStep
        if body.hasSuffix("[t-1]") {
            body.removeLast(5)
            timing = .previousStep
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(isName) else { return nil }
        return EventSubscription(slot: parts[0], kind: parts[1], timing: timing)
    }
}
