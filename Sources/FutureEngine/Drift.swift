import Foundation

/// A slot's latest readings, checked against what its model projected before they came
/// (docs/DESIGN.md, 8.2).
///
/// The latest stretch of readings (the last year, usually) is hidden from the model, which is
/// projected from the point before it with its own values. Earlier stretches of the same length
/// are projected the same way, and how far those missed sizes a band around the projection: the
/// range 10–90% of misses fell in, widening with the distance ahead. The readings drift when the
/// latest of them fall outside that band.
public struct DriftOutcome: Hashable, Sendable {
    /// The band's edges at one of the projection's points.
    public struct BandPoint: Hashable, Sendable {
        public var time: Date
        public var low: Double
        public var high: Double

        public init(time: Date, low: Double, high: Double) {
            self.time = time
            self.low = low
            self.high = high
        }
    }

    public var variable: String
    /// The last point the projection saw: later readings were hidden from it.
    public var cutoff: Date
    /// The projection from the cut-off through the last reading.
    public var line: [Sample]
    /// The band around `line`, point by point.
    public var band: [BandPoint]
    /// How many readings came after the cut-off, and how many of those were outside the band.
    public var checked: Int
    public var outside: Int
    /// Whether the latest readings left the band.
    public var isDrifting: Bool
    /// How far the latest reading is from the projection: a share of the projection when
    /// `isRatio` (0.12 is 12% above), otherwise in the value's own units. Below zero is below.
    public var offset: Double
    public var isRatio: Bool
    /// The latest reading's time and value, and what the projection worked out there.
    public var lastReading: Date
    public var lastValue: Double
    public var projected: Double
    /// How many earlier projections sized the band.
    public var earlier: Int
}

extension SlotCopy {
    /// How long the latest stretch is, when the readings span at least five times as long. Shorter
    /// series use a fifth of their span, so there are earlier stretches to size the band from.
    public static let driftStretch: TimeInterval = 365.2425 * 86_400
    /// The most earlier stretches the band is sized from, and the fewest it needs.
    public static let driftEarlierLimit = 20
    public static let driftEarlierMinimum = 3
    /// The fewest readings after the cut-off that can show drift.
    public static let driftReadingsMinimum = 3
    /// The band's half-width in typical misses: 10–90% of a normal spread.
    static let driftWidth = 1.2816
    /// The band widens in this many steps across the stretch.
    static let driftBuckets = 4

    /// Checks whether the latest readings of `variable` have left the range the slot's model
    /// projected for them, with the slot's own values. Nil when there are too few readings, or too
    /// little history before them, to tell. Runs on the calling thread.
    public func drift(_ variable: String, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> DriftOutcome? {
        try Self.drift(model, copy: self, variable: variable, isCancelled: isCancelled)
    }

    fileprivate static func drift<Model: AuthoredModel>(_ model: Model, copy: SlotCopy, variable: String,
                                                        isCancelled: @escaping () -> Bool) throws -> DriftOutcome? {
        let all = copy.readings.filter { $0.variable == variable && $0.value.isFinite }
        guard all.count >= driftReadingsMinimum + 2, let first = all.first, let last = all.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span > 0 else { return nil }
        // Long enough to hold the last few readings, so yearly readings still have something to check.
        let base = span >= 5 * driftStretch ? driftStretch : span / 5
        let wanted = max(base, last.time.timeIntervalSince(all[all.count - driftReadingsMinimum - 1].time))

        let runStart = runStart(model, copy: copy, fitting: [])
        let grid = TimeGrid(start: runStart, rate: model.descriptor.stepRate, calendar: copy.calendar)
        /// The slot's point at or before a time, so no step has readings from both sides of it.
        func point(atOrBefore time: Date) -> Date? {
            grid.lastIndex(atOrBefore: time).map(grid.point)
        }
        let isRatio = !Scoring.differences(model.descriptor).contains(variable) && all.allSatisfy { $0.value > 0 }
        func residual(_ reading: Double, _ predicted: Double) -> Double {
            isRatio ? (predicted > 0 ? Foundation.log(reading / predicted) : .nan) : reading - predicted
        }

        guard let cutoff = point(atOrBefore: last.time.addingTimeInterval(-wanted)),
              all.filter({ $0.time <= cutoff }).count >= 2 else { return nil }
        // From the cut-off through the last reading. Earlier stretches are as long.
        let stretch = last.time.timeIntervalSince(cutoff)

        /// The projection from `origin`, knowing only the readings up to it, and how far it missed
        /// each reading in the stretch after it, with each one's share of the way through the stretch.
        func project(from origin: Date) throws -> (line: [Sample], misses: [(reading: Reading, fraction: Double, value: Double)])? {
            let hidden = all.filter { $0.time > origin && $0.time <= origin.addingTimeInterval(stretch) }
            guard let end = hidden.last else { return nil }
            let trial = try Trial(copy: copy, model: model, readings: copy.readings.filter { $0.time <= origin },
                                  runStart: runStart, isCancelled: isCancelled)
            let through = grid.point(grid.firstIndex(atOrAfter: end.time))
            guard let line = try trial.series(variable, [:], from: origin, through: through) else { return nil }
            var misses: [(reading: Reading, fraction: Double, value: Double)] = []
            for reading in hidden {
                // The point whose step takes the reading.
                var low = 0, high = line.count
                while low < high {
                    let middle = (low + high) / 2
                    if line[middle].time < reading.time { low = middle + 1 } else { high = middle }
                }
                guard line.indices.contains(low) else { return nil }
                let value = residual(reading.value, line[low].value)
                guard value.isFinite else { return nil }
                misses.append((reading, reading.time.timeIntervalSince(origin) / stretch, value))
            }
            return (line, misses)
        }

        guard let latest = try project(from: cutoff), latest.misses.count >= driftReadingsMinimum else { return nil }

        // Earlier stretches of the same length, each projected from the point before it.
        var squares = [Double](repeating: 0, count: driftBuckets)
        var counts = [Int](repeating: 0, count: driftBuckets)
        func bucket(_ fraction: Double) -> Int { min(driftBuckets - 1, max(0, Int((fraction * Double(driftBuckets)).rounded(.down)))) }
        var earlier = 0
        for k in 1...driftEarlierLimit {
            guard let origin = point(atOrBefore: cutoff.addingTimeInterval(-Double(k) * stretch)),
                  all.filter({ $0.time <= origin }).count >= 2 else { break }
            guard let found = try project(from: origin), !found.misses.isEmpty else { continue }
            earlier += 1
            for miss in found.misses {
                squares[bucket(miss.fraction)] += miss.value * miss.value
                counts[bucket(miss.fraction)] += 1
            }
        }
        guard earlier >= driftEarlierMinimum else { return nil }

        // The typical miss at each distance ahead. A distance with no misses takes the next one's,
        // and the band never narrows further ahead.
        var typical = (0..<driftBuckets).map { counts[$0] > 0 ? (squares[$0] / Double(counts[$0])).squareRoot() : Double.nan }
        for index in stride(from: driftBuckets - 2, through: 0, by: -1) where typical[index].isNaN { typical[index] = typical[index + 1] }
        for index in 1..<driftBuckets where typical[index].isNaN { typical[index] = typical[index - 1] }
        let scale = all.map { abs($0.value) }.max() ?? 1
        let floor = isRatio ? 1e-6 : max(scale * 1e-9, 1e-12)
        for index in 1..<driftBuckets { typical[index] = max(typical[index], typical[index - 1]) }
        typical = typical.map { max($0, floor) }
        func halfWidth(_ fraction: Double) -> Double { driftWidth * typical[bucket(fraction)] }

        let band = latest.line.map { sample -> DriftOutcome.BandPoint in
            let width = sample.time <= cutoff ? 0 : halfWidth(sample.time.timeIntervalSince(cutoff) / stretch)
            if isRatio {
                return DriftOutcome.BandPoint(time: sample.time, low: sample.value * Foundation.exp(-width),
                                              high: sample.value * Foundation.exp(width))
            }
            return DriftOutcome.BandPoint(time: sample.time, low: sample.value - width, high: sample.value + width)
        }
        let outside = latest.misses.map { abs($0.value) > halfWidth($0.fraction) }
        let lastMiss = latest.misses.last!
        // The last reading is outside, and so are most of the last few, on the same side.
        let recent = latest.misses.suffix(driftReadingsMinimum)
        let sameSide = recent.filter { abs($0.value) > halfWidth($0.fraction) && ($0.value > 0) == (lastMiss.value > 0) }.count
        let isDrifting = outside.last! && sameSide * 2 > recent.count
        let projected = isRatio ? lastMiss.reading.value / Foundation.exp(lastMiss.value) : lastMiss.reading.value - lastMiss.value
        return DriftOutcome(variable: variable, cutoff: cutoff, line: latest.line, band: band,
                            checked: latest.misses.count, outside: outside.filter { $0 }.count, isDrifting: isDrifting,
                            offset: isRatio ? Foundation.exp(lastMiss.value) - 1 : lastMiss.value, isRatio: isRatio,
                            lastReading: lastMiss.reading.time, lastValue: lastMiss.reading.value, projected: projected,
                            earlier: earlier)
    }
}
