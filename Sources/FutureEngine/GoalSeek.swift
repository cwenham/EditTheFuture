import Foundation

public struct GoalSeekResult: Sendable {
    /// The value passed to the trial-event builder that hits the target.
    public let input: Double
    /// What the variable reached with that input.
    public let achieved: Double
    public let iterations: Int
    /// The event to propose to the user. It is not left in the scenario.
    public let event: Event
}

extension Scenario {
    /// "Drag the future": finds the input that makes `variable` reach `target` at `date`.
    ///
    /// `trialEvent` builds the change being solved for, e.g. `{ Event.set(["deposit": $0], at: january) }`.
    /// Each try inserts that event, so only the time after it is recomputed. The scenario is left
    /// unchanged; add `result.event` if the user accepts it.
    ///
    /// Uses bisection, so the result must change monotonically with the input across `range`.
    public func goalSeek(_ variable: String, of slot: SlotID, at date: Date, target: Double,
                         eventSlot: SlotID? = nil, within range: ClosedRange<Double>,
                         tolerance: Double = 1e-9, maxIterations: Int = 200,
                         trialEvent: (Double) -> Event) throws -> GoalSeekResult {
        let trialSlot = eventSlot ?? slot
        let trialID = UUID()
        defer { removeEvent(id: trialID, from: trialSlot) }

        func attempt(_ input: Double) throws -> (achieved: Double, event: Event) {
            var event = trialEvent(input)
            event.id = trialID
            upsert(event, in: trialSlot)
            return (try value(variable, of: slot, at: date), event)
        }

        let scale = Swift.max(1, abs(target))
        func closeEnough(_ achieved: Double) -> Bool { abs(achieved - target) <= tolerance * scale }

        var low = range.lowerBound, high = range.upperBound
        let atLow = try attempt(low)
        if closeEnough(atLow.achieved) {
            return GoalSeekResult(input: low, achieved: atLow.achieved, iterations: 1, event: atLow.event)
        }
        let atHigh = try attempt(high)
        if closeEnough(atHigh.achieved) {
            return GoalSeekResult(input: high, achieved: atHigh.achieved, iterations: 2, event: atHigh.event)
        }
        let lowIsBelow = atLow.achieved < target
        guard lowIsBelow != (atHigh.achieved < target) else {
            throw EngineError.goalNotBracketed(lowResult: atLow.achieved, highResult: atHigh.achieved, target: target)
        }

        var iterations = 2
        var best = (input: high, achieved: atHigh.achieved, event: atHigh.event)
        while iterations < maxIterations {
            let middle = (low + high) / 2
            let result = try attempt(middle)
            iterations += 1
            best = (middle, result.achieved, result.event)
            if closeEnough(result.achieved) || middle == low || middle == high { break }
            if (result.achieved < target) == lowIsBelow {
                low = middle
            } else {
                high = middle
            }
        }
        return GoalSeekResult(input: best.input, achieved: best.achieved, iterations: iterations, event: best.event)
    }
}

/// A change Drag the future may make to bring a slot's line to a target (docs/DESIGN.md, 8.1).
public enum GoalLever: Hashable, Sendable {
    /// Sets a parameter from a date on, as a `set` event.
    case parameter(String, from: Date)
    /// A one-off event of a kind that takes an amount, such as a deposit, on a date.
    case amount(kind: String, at: Date)

    /// When the change happens.
    public var date: Date {
        switch self {
        case .parameter(_, let date), .amount(_, let date): return date
        }
    }
}

/// The value of a change that reaches a target.
public struct GoalSolution: Sendable {
    public let lever: GoalLever
    /// The parameter's new value, or the amount, rounded to a tidy number.
    public let input: Double
    /// The parameter's value at the change's date before it, or 0 for an amount.
    public let before: Double
    /// What the line reaches at the target's date with `input`.
    public let achieved: Double
    /// The event that makes the change. It isn't left in the scenario.
    public let event: Event
}

extension Scenario {
    /// Finds the value of one change that brings `variable` to `target` at `date`, or nil when no
    /// value does: none within `bounds`, or none at all when the line doesn't move that way. A
    /// parameter without bounds, and an amount (from zero up), widen their search until the target
    /// is passed. Each try inserts the change as an event, so only the time after it is computed
    /// again. The answer is rounded to a multiple of `step`, or to whole units from 100 up and four
    /// significant figures below, and checked again. The scenario is left as it was.
    public func solve(_ variable: String, of slot: SlotID, at date: Date, target: Double, lever: GoalLever,
                      bounds: ClosedRange<Double>? = nil, step: Double? = nil,
                      isCancelled: () -> Bool = { false }) throws -> GoalSolution? {
        let trialID = UUID()
        defer { removeEvent(id: trialID, from: slot) }
        func event(_ input: Double) -> Event {
            switch lever {
            case .parameter(let name, let from): return Event.set([name: input], at: from)
            case .amount(let kind, let at): return Event(time: at, kind: kind, values: ["amount": input])
            }
        }
        /// The line's value at `date` with the change set to `input`, or nil when it isn't finite.
        func reach(_ input: Double) throws -> Double? {
            if isCancelled() { throw CancellationError() }
            var trial = event(input)
            trial.id = trialID
            upsert(trial, in: slot)
            let value = try value(variable, of: slot, at: date)
            return value.isFinite ? value : nil
        }

        let before: Double
        switch lever {
        case .parameter(let name, let from): before = try value(name, of: slot, at: from)
        case .amount: before = 0
        }
        guard before.isFinite, let start = try reach(before) else { return nil }
        let scale = Swift.max(abs(target), abs(start), 1e-12)
        func closeEnough(_ value: Double) -> Bool { abs(value - target) <= 1e-9 * scale }
        let rising = target > start

        // A bracket: one input on each side of the target.
        var low = before, lowValue = start
        var high: Double, highValue: Double
        if closeEnough(start) {
            high = before
            highValue = start
        } else if let bounds {
            guard let atLow = try reach(bounds.lowerBound), let atHigh = try reach(bounds.upperBound),
                  (atLow - target).sign != (atHigh - target).sign || closeEnough(atLow) || closeEnough(atHigh) else { return nil }
            (low, lowValue, high, highValue) = (bounds.lowerBound, atLow, bounds.upperBound, atHigh)
        } else {
            // Which way moves the line towards the target, then further that way until it's passed.
            var size: Double
            switch lever {
            case .parameter: size = Swift.max(abs(before) * 0.25, 1e-3)
            case .amount: size = Swift.max(abs(target - start), 1e-9 * scale)
            }
            var direction = 1.0
            if case .parameter = lever, let up = try reach(before + size), (up > start) != rising || up == start {
                direction = -1
            }
            var found: (Double, Double)?
            for _ in 0..<60 {
                let input = before + direction * size
                if case .amount = lever, input < 0 { break }
                guard let value = try reach(input) else { break }
                if (value - target).sign != (start - target).sign || closeEnough(value) {
                    found = (input, value)
                    break
                }
                size *= 2
            }
            guard let found else { return nil }
            (high, highValue) = found
        }

        // Bisection, keeping one input on each side.
        var best = abs(lowValue - target) < abs(highValue - target) ? low : high
        for _ in 0..<80 where !closeEnough(lowValue) && !closeEnough(highValue) {
            let middle = (low + high) / 2
            guard middle != low, middle != high, let value = try reach(middle) else { break }
            best = middle
            if closeEnough(value) { break }
            if (value - target).sign == (lowValue - target).sign { (low, lowValue) = (middle, value) } else { (high, highValue) = (middle, value) }
        }
        if closeEnough(lowValue) { best = low } else if closeEnough(highValue) { best = high }

        let rounded = Self.tidy(best, step: step, bounds: bounds)
        guard let achieved = try reach(rounded) else { return nil }
        return GoalSolution(lever: lever, input: rounded, before: before, achieved: achieved, event: event(rounded))
    }

    /// A tidy number near `value`: a multiple of `step`, or whole units from 100 up, or four
    /// significant figures below; kept within `bounds`.
    static func tidy(_ value: Double, step: Double?, bounds: ClosedRange<Double>?) -> Double {
        var result: Double
        if let step, step > 0, step.isFinite {
            let base = bounds?.lowerBound ?? 0
            result = base + ((value - base) / step).rounded() * step
        } else if abs(value) >= 100, abs(value) < 1e15 {
            result = value.rounded()
        } else if value == 0 || !value.isFinite || abs(value) < 1e-290 || abs(value) > 1e290 {
            result = value
        } else {
            let digits = 4 - Int(Foundation.log10(abs(value)).rounded(.down)) - 1
            let factor = Foundation.pow(10, Double(digits))
            result = (value * factor).rounded() / factor
        }
        if let bounds { result = Swift.min(Swift.max(result, bounds.lowerBound), bounds.upperBound) }
        return result
    }
}
