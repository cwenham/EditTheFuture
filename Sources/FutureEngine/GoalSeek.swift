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
