import Foundation

/// Type-erased view of a slot's runner, so a scenario can hold different model types.
protocol AnySlotRunner: AnyObject {
    var descriptor: ModelDescriptor { get }
    /// The slot's model, for fitting (docs/DESIGN.md, 8.4).
    var anyModel: any TimelineModel { get }
    var grid: TimeGrid { get }
    /// Time of each computed communication point, by index.
    var times: [Date] { get }

    /// Column of a readable variable in the history, or nil if the model has no such variable.
    func column(of variable: String) -> Int?
    /// The value of a column at a computed point.
    func value(at index: Int, column: Int) -> Double

    func computeStart(_ context: StepContext) throws
    /// Computes the next step. `replaced` collects what it worked out for values its readings replaced.
    func computeStep(_ context: StepContext, replaced: inout [Prediction]) throws -> [GeneratedEvent]

    /// Discards every point at or after `date` and rewinds to the newest checkpoint before it.
    /// Returns the time of the last point kept, or nil if nothing is left.
    func truncate(from date: Date) -> Date?

    /// Everything computed so far, without generated events (the scenario keeps those). nil when
    /// nothing is computed, or the model can't save its state.
    func history() -> SlotHistory?

    /// Replaces what's computed with a saved history. False, changing nothing, when it doesn't
    /// fit this model.
    func restore(_ history: SlotHistory) -> Bool
}

extension AnySlotRunner {
    var computedCount: Int { times.count }

    /// Index of the last computed point at or before `date`.
    func lastComputedIndex(atOrBefore date: Date) -> Int? {
        var low = 0, high = times.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Indices of computed points inside `window`.
    func computedIndices(in window: StepWindow) -> Range<Int> {
        guard let upper = lastComputedIndex(atOrBefore: window.upper) else { return 0..<0 }
        var lower = upper + 1
        while lower > 0 && window.contains(times[lower - 1]) { lower -= 1 }
        return lower..<(upper + 1)
    }
}

final class SlotRunner<Model: TimelineModel>: AnySlotRunner {
    let model: Model
    let descriptor: ModelDescriptor
    let grid: TimeGrid
    let checkpointInterval: Int

    private(set) var times: [Date] = []
    /// Readable values, one row per computed point and one column per readable variable.
    private var values: [Double] = []
    private let columns: [String: Int]
    private let width: Int
    private var current: Model.State?
    private var checkpoints: [(index: Int, state: Model.State)] = []

    init(model: Model, grid: TimeGrid, checkpointInterval: Int) {
        self.model = model
        let descriptor = model.descriptor
        self.descriptor = descriptor
        self.grid = grid
        self.checkpointInterval = max(1, checkpointInterval)
        let readable = descriptor.readable
        self.columns = Dictionary(uniqueKeysWithValues: readable.enumerated().map { ($0.element.name, $0.offset) })
        self.width = readable.count
    }

    var anyModel: any TimelineModel { model }

    func column(of variable: String) -> Int? { columns[variable] }

    func value(at index: Int, column: Int) -> Double { values[index * width + column] }

    func computeStart(_ context: StepContext) throws {
        precondition(times.isEmpty, "start computed twice")
        let state = try model.start(context)
        current = state
        checkpoints = [(0, state)]
        record(state, at: context.to)
    }

    func computeStep(_ context: StepContext, replaced: inout [Prediction]) throws -> [GeneratedEvent] {
        precondition(context.index == times.count, "steps must be computed in order")
        guard var state = current else { preconditionFailure("step computed before start") }
        let generated = try model.doStep(&state, context, replaced: &replaced)
        record(state, at: context.to)
        if context.index % checkpointInterval == 0 {
            checkpoints.append((context.index, state))
        }
        current = state
        return generated
    }

    private func record(_ state: Model.State, at time: Date) {
        times.append(time)
        let row = model.readableValues(of: state)
        precondition(row.count == width, "\(descriptor.name) returned \(row.count) values for \(width) readable variables")
        values.append(contentsOf: row)
    }

    func truncate(from date: Date) -> Date? {
        let firstInvalid = grid.firstIndex(atOrAfter: date)
        guard firstInvalid < times.count else { return times.last }
        guard firstInvalid > 0 else {
            times = []
            values = []
            current = nil
            checkpoints = []
            return nil
        }
        checkpoints.removeAll { $0.index >= firstInvalid }
        let checkpoint = checkpoints[checkpoints.count - 1]
        current = checkpoint.state
        times.removeSubrange((checkpoint.index + 1)...)
        values.removeSubrange(((checkpoint.index + 1) * width)...)
        return times.last
    }

    func history() -> SlotHistory? {
        guard let current, !times.isEmpty, let currentNumbers = model.savedNumbers(of: current) else { return nil }
        let stateWidth = currentNumbers.count
        var states: [Double] = []
        states.reserveCapacity(checkpoints.count * stateWidth)
        for checkpoint in checkpoints {
            guard let numbers = model.savedNumbers(of: checkpoint.state), numbers.count == stateWidth else { return nil }
            states += numbers
        }
        return SlotHistory(columns: descriptor.readable.map(\.name), count: times.count, values: values,
                           stateWidth: stateWidth, checkpointIndices: checkpoints.map(\.index), checkpointStates: states,
                           currentState: currentNumbers, generated: [], secondsPerStep: 0)
    }

    func restore(_ history: SlotHistory) -> Bool {
        guard history.isWellFormed, history.columns == descriptor.readable.map(\.name),
              let restoredCurrent = model.restoredState(from: history.currentState) else { return false }
        let stateWidth = history.stateWidth
        var restoredCheckpoints: [(index: Int, state: Model.State)] = []
        restoredCheckpoints.reserveCapacity(history.checkpointIndices.count)
        for (offset, index) in history.checkpointIndices.enumerated() {
            let numbers = Array(history.checkpointStates[(offset * stateWidth)..<((offset + 1) * stateWidth)])
            guard let state = model.restoredState(from: numbers) else { return false }
            restoredCheckpoints.append((index, state))
        }
        times = (0..<history.count).map(grid.point)
        values = history.values
        checkpoints = restoredCheckpoints
        current = restoredCurrent
        return true
    }
}
