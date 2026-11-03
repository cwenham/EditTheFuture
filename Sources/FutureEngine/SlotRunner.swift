import Foundation

/// Type-erased view of a slot's runner, so a scenario can hold different model types.
///
/// Points are the slot's grid points, by index. Each computed point is stored, except while the
/// model is settled (docs/DESIGN.md, 4.11): then later points are held at the last stored one,
/// until the next point with something in it, or for ever.
protocol AnySlotRunner: AnyObject {
    var descriptor: ModelDescriptor { get }
    /// The slot's model, for fitting (docs/DESIGN.md, 8.4).
    var anyModel: any TimelineModel { get }
    var grid: TimeGrid { get }

    /// The next point to compute, or nil when the slot holds for ever.
    var nextIndex: Int? { get }
    /// How many points were computed and stored (held ones aren't).
    var storedCount: Int { get }
    /// When the last computed point is: `Date.distantFuture` when the slot holds for ever, nil
    /// before anything is computed.
    var lastTime: Date? { get }
    /// Whether the model has settled at the last stored point, so steps can be skipped.
    var isSettled: Bool { get }

    /// Column of a readable variable in the history, or nil if the model has no such variable.
    func column(of variable: String) -> Int?
    /// The value of a column at a computed point, held or stored.
    func value(at index: Int, column: Int) -> Double
    /// The last computed point at or before `date`.
    func lastComputedIndex(atOrBefore date: Date) -> Int?
    /// A column at the points from `from` through `through`. Held points come as the first and last
    /// of each held stretch, which draws the same line with far fewer points.
    func samples(column: Int, from: Date, through: Date) -> [Sample]

    func computeStart(_ context: StepContext) throws
    /// Computes the next step. `replaced` collects what it worked out for values its readings replaced.
    func computeStep(_ context: StepContext, replaced: inout [Prediction]) throws -> [GeneratedEvent]
    /// Holds the settled model's last point until just before `index`, or for ever when nil.
    func hold(until index: Int?)

    /// Discards every point at or after `date` and rewinds to the newest checkpoint before it.
    /// Returns the time of the last point kept, or nil if nothing is left.
    func truncate(from date: Date) -> Date?

    /// Everything computed so far, without generated events (the scenario keeps those). nil when
    /// nothing is computed, the model can't save its state, or some points are held.
    func history() -> SlotHistory?

    /// Replaces what's computed with a saved history. False, changing nothing, when it doesn't
    /// fit this model.
    func restore(_ history: SlotHistory) -> Bool

    /// A field at a computed point (docs/DESIGN.md, 4.10): from the current state at the last
    /// point, else from a copy of the newest checkpoint at or before it, stepped forward with the
    /// contexts the steps had. nil when the model has no such field or the point isn't computed.
    func field(_ name: String, at index: Int, contexts: (Int) throws -> StepContext) throws -> [Double]?
}

extension AnySlotRunner {
    func time(at index: Int) -> Date { grid.point(index) }

    /// Indices of computed points inside `window`.
    func computedIndices(in window: StepWindow) -> Range<Int> {
        guard let upper = lastComputedIndex(atOrBefore: window.upper) else { return 0..<0 }
        var lower = upper + 1
        while lower > 0 && window.contains(grid.point(lower - 1)) { lower -= 1 }
        return lower..<(upper + 1)
    }
}

final class SlotRunner<Model: TimelineModel>: AnySlotRunner {
    let model: Model
    let descriptor: ModelDescriptor
    let grid: TimeGrid
    let checkpointInterval: Int

    /// Each stored point's time, and its index once some points are held (nil while every point is
    /// stored, when a row's index is the row).
    private var times: [Date] = []
    private var sparse: [Int]?
    /// Readable values, one row per stored point and one column per readable variable.
    private var values: [Double] = []
    private let columns: [String: Int]
    private let width: Int
    private var current: Model.State?
    private var checkpoints: [(index: Int, state: Model.State)] = []
    /// Points held after the last stored one: up to, not including, an index, or for ever.
    private enum Held { case until(Int), forever }
    private var held: Held?
    /// Whether every point is stored, so a point's row is its index.
    private var dense: Bool { sparse == nil }
    /// Whether the model can settle, so it's worth asking after each step.
    private let settles: Bool

    init(model: Model, grid: TimeGrid, checkpointInterval: Int) {
        self.model = model
        let descriptor = model.descriptor
        self.descriptor = descriptor
        self.grid = grid
        self.checkpointInterval = max(1, checkpointInterval)
        let readable = descriptor.readable
        self.columns = Dictionary(uniqueKeysWithValues: readable.enumerated().map { ($0.element.name, $0.offset) })
        self.width = readable.count
        self.settles = descriptor.capabilities.contains(.settles)
    }

    /// A stored row's point.
    private func index(ofRow row: Int) -> Int { sparse?[row] ?? row }

    /// The last stored point.
    private var lastStored: Int? { times.isEmpty ? nil : index(ofRow: times.count - 1) }

    var anyModel: any TimelineModel { model }

    func column(of variable: String) -> Int? { columns[variable] }

    var storedCount: Int { times.count }

    /// One past the last computed point; `Int.max` when held for ever.
    private var end: Int {
        switch held {
        case .until(let index)?: return index
        case .forever?: return .max
        case nil: return lastStored.map { $0 + 1 } ?? 0
        }
    }

    var nextIndex: Int? {
        let end = self.end
        return end == .max ? nil : end
    }

    var lastTime: Date? {
        let end = self.end
        if end == .max { return .distantFuture }
        guard end > 0 else { return nil }
        return held == nil ? times.last : grid.point(end - 1)
    }

    var isSettled: Bool {
        guard settles, let current, !times.isEmpty else { return false }
        return model.isSettled(current)
    }

    /// The stored row a point's value is in: its own, or the last stored before it while held.
    private func row(for index: Int) -> Int {
        guard let sparse else { return index }
        var low = 0, high = sparse.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if sparse[mid] <= index { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    func value(at index: Int, column: Int) -> Double { values[row(for: index) * width + column] }

    func lastComputedIndex(atOrBefore date: Date) -> Int? {
        let end = self.end
        guard end > 0 else { return nil }
        if dense {
            // Binary search on the stored times, as before settling existed.
            var low = 0, high = times.count - 1, found: Int?
            while low <= high {
                let mid = (low + high) / 2
                if times[mid] <= date { found = mid; low = mid + 1 } else { high = mid - 1 }
            }
            return found
        }
        guard let index = grid.lastIndex(atOrBefore: date) else { return nil }
        return min(index, end - 1)
    }

    func samples(column: Int, from: Date, through: Date) -> [Sample] {
        guard let high = lastComputedIndex(atOrBefore: through) else { return [] }
        var low = lastComputedIndex(atOrBefore: from) ?? 0
        if grid.point(low) < from { low += 1 }
        guard low <= high else { return [] }
        var samples: [Sample] = []
        if dense {
            samples.reserveCapacity(high - low + 1)
            for index in low...high { samples.append(Sample(time: times[index], value: values[index * width + column])) }
            return samples
        }
        // Each stored point, and the last of any held stretch after it.
        var r = row(for: low)
        while r < times.count {
            let point = index(ofRow: r)
            let first = max(point, low)
            guard first <= high else { break }
            let value = values[r * width + column]
            let stretchEnd = min(high, (r + 1 < times.count ? index(ofRow: r + 1) : end) - 1)
            samples.append(Sample(time: first == point ? times[r] : grid.point(first), value: value))
            if stretchEnd > first { samples.append(Sample(time: grid.point(stretchEnd), value: value)) }
            r += 1
        }
        return samples
    }

    func computeStart(_ context: StepContext) throws {
        precondition(times.isEmpty, "start computed twice")
        let state = try model.start(context)
        current = state
        checkpoints = [(0, state)]
        record(state, index: 0, at: context.to)
    }

    func computeStep(_ context: StepContext, replaced: inout [Prediction]) throws -> [GeneratedEvent] {
        precondition(context.index == nextIndex, "steps must be computed in order")
        guard var state = current else { preconditionFailure("step computed before start") }
        let generated = try model.doStep(&state, context, replaced: &replaced)
        held = nil
        record(state, index: context.index, at: context.to)
        if context.index % checkpointInterval == 0 {
            checkpoints.append((context.index, state))
        }
        current = state
        return generated
    }

    func hold(until index: Int?) {
        guard let last = lastStored, let current, index.map({ $0 > end }) ?? true else { return }
        // A checkpoint where it settled, so a field or a rewind inside the held stretch starts here.
        if checkpoints.last?.index != last { checkpoints.append((last, current)) }
        held = index.map(Held.until) ?? .forever
        if sparse == nil { sparse = Array(0..<times.count) }
    }

    private func record(_ state: Model.State, index: Int, at time: Date) {
        if sparse != nil {
            sparse?.append(index)
        } else if index != times.count {
            sparse = Array(0..<times.count) + [index]
        }
        times.append(time)
        let row = model.readableValues(of: state)
        precondition(row.count == width, "\(descriptor.name) returned \(row.count) values for \(width) readable variables")
        values.append(contentsOf: row)
    }

    func truncate(from date: Date) -> Date? {
        let firstInvalid = grid.firstIndex(atOrAfter: date)
        guard firstInvalid < end else { return lastTime }
        guard firstInvalid > 0 else {
            sparse = nil
            times = []
            values = []
            current = nil
            checkpoints = []
            held = nil
            return nil
        }
        // Inside a held stretch: the points before it still hold, and the model carries on from
        // where it settled.
        if held != nil, let last = lastStored, firstInvalid > last {
            held = firstInvalid > last + 1 ? .until(firstInvalid) : nil
            return grid.point(firstInvalid - 1)
        }
        checkpoints.removeAll { $0.index >= firstInvalid }
        let checkpoint = checkpoints[checkpoints.count - 1]
        current = checkpoint.state
        held = nil
        let keep = row(for: checkpoint.index) + 1
        sparse?.removeSubrange(keep...)
        times.removeSubrange(keep...)
        values.removeSubrange((keep * width)...)
        // Every point stored again, as it was before anything was held.
        if let sparse, sparse.last == sparse.count - 1 { self.sparse = nil }
        return times.last
    }

    func history() -> SlotHistory? {
        // Held points aren't saved; such a slot is quick to compute again anyway.
        guard dense, held == nil, let current, !times.isEmpty, let currentNumbers = model.savedNumbers(of: current) else { return nil }
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
        sparse = nil
        times = (0..<history.count).map(grid.point)
        values = history.values
        checkpoints = restoredCheckpoints
        current = restoredCurrent
        held = nil
        return true
    }

    func field(_ name: String, at index: Int, contexts: (Int) throws -> StepContext) throws -> [Double]? {
        guard index >= 0, index < end, !times.isEmpty else { return nil }
        // A held point is the stored one it's held at: the model was settled, so nothing changed.
        let target = self.index(ofRow: row(for: index))
        if target == lastStored, let current { return model.field(name, of: current) }
        // Checkpoints are in index order; the newest at or before the point.
        var low = 0, high = checkpoints.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if checkpoints[mid].index <= target { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard let found else { return nil }
        var state = checkpoints[found].state
        var ignored: [Prediction] = []
        // Only stored points were stepped; held ones changed nothing.
        var r = row(for: checkpoints[found].index) + 1
        while r < times.count, self.index(ofRow: r) <= target {
            _ = try model.doStep(&state, contexts(self.index(ofRow: r)), replaced: &ignored)
            r += 1
        }
        return model.field(name, of: state)
    }
}
