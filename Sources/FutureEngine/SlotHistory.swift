import Foundation

/// Everything a slot has computed, as plain numbers, so it can be saved and loaded again instead of
/// computed again (docs/DESIGN.md, 15.5).
///
/// Times aren't kept: point *i* is always the slot's grid point *i* (4.2).
public struct SlotHistory: Sendable, Equatable {
    /// The readable variables, in the order of each row of `values`.
    public var columns: [String]
    /// How many points were computed, from the start.
    public var count: Int
    /// One row per point, one column per readable variable.
    public var values: [Double]
    /// How many numbers each saved state has.
    public var stateWidth: Int
    /// The points with a checkpoint, in order. The first is always 0, the start.
    public var checkpointIndices: [Int]
    /// The checkpoints' states, `stateWidth` numbers each.
    public var checkpointStates: [Double]
    /// The state at the last point, to carry on from.
    public var currentState: [Double]
    /// The events the slot generated, in time order.
    public var generated: [Event]
    /// How long a step took to compute, on average. Decides whether the slot is worth caching.
    public var secondsPerStep: Double

    public init(columns: [String], count: Int, values: [Double], stateWidth: Int, checkpointIndices: [Int],
                checkpointStates: [Double], currentState: [Double], generated: [Event], secondsPerStep: Double) {
        self.columns = columns
        self.count = count
        self.values = values
        self.stateWidth = stateWidth
        self.checkpointIndices = checkpointIndices
        self.checkpointStates = checkpointStates
        self.currentState = currentState
        self.generated = generated
        self.secondsPerStep = secondsPerStep
    }

    /// Whether the parts fit together: rows, checkpoints and states of the right sizes.
    public var isWellFormed: Bool {
        guard count > 0, stateWidth >= 0, values.count == count * columns.count,
              currentState.count == stateWidth,
              checkpointStates.count == checkpointIndices.count * stateWidth,
              checkpointIndices.first == 0,
              zip(checkpointIndices, checkpointIndices.dropFirst()).allSatisfy({ $0 < $1 }),
              let last = checkpointIndices.last, last < count else { return false }
        return true
    }
}
