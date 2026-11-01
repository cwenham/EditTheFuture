import SwiftUI
import FutureEngine

/// One line on a plot.
struct PlotSeries {
    var samples: [Sample]
    var color: Color
    var lineWidth: CGFloat
    var dash: [CGFloat] = []
}

/// A vertical line at a date (now, the cursor, a new event's date).
struct PlotRule {
    var date: Date
    var color: Color
    var lineWidth: CGFloat = 1
    var dash: [CGFloat] = []
}

/// Dim lines down the graph at the events a person added, so the eye can match a diamond in
/// the events strip to where the line changes (docs/UI.md, 2.4). Drawn behind the lines.
struct PlotEventLines {
    var dates: [Date]
    var color: Color

    /// Lines closer than this to the last one drawn are skipped, so dense events don't fill the graph.
    static let minSpacing: CGFloat = 4

    /// Where the lines go in a plot `width` points wide: the dates in view, thinned to `minSpacing`.
    static func xs(dates: [Date], frame: TimeFrame, width: CGFloat) -> [CGFloat] {
        var xs: [CGFloat] = []
        for date in dates.sorted() where frame.contains(date) {
            let x = frame.x(date, width: width)
            if let last = xs.last, x - last < minSpacing { continue }
            xs.append(x)
        }
        return xs
    }
}

/// Readings: dots on a thin line, at 85% opacity (docs/UI.md, 2.4). The dots are drawn only
/// while there's room between them.
struct PlotReadings {
    var samples: [Sample]
    var color: Color
}

/// A range around a line, filled: drift's 10–90% band (docs/UI.md, 2.4).
struct PlotBand {
    var points: [DriftOutcome.BandPoint]
    var color: Color
}

/// A dot on a line (the cursor's value).
struct PlotMarker {
    var date: Date
    var value: Double
    var color: Color
    var diameter: CGFloat = 8
}

/// Draws lines over a time frame with a single `Canvas` pass.
///
/// This replaced Swift Charts, which built one mark per data point and spent most of each
/// frame in generic view-graph work: a few thousand marks took 40–100 ms per frame. A path
/// per line takes well under a millisecond. Points that would land in the same pixel column
/// are reduced to that column's first, lowest, highest and last values, so even a daily model
/// over a century draws only a few thousand points.
struct PlotCanvas: View {
    let frame: TimeFrame
    let domain: ClosedRange<Double>
    let now: Date
    var gridValues: [Double] = []
    var bands: [PlotBand] = []
    let series: [PlotSeries]
    var rules: [PlotRule] = []
    var eventLines: PlotEventLines?
    var readings: PlotReadings?
    var marker: PlotMarker?
    /// The scenario's start, where the models' lines begin. When the frame reaches back before it,
    /// that part is shaded and a dashed line marks the start (docs/UI.md, 2.4).
    var modelStart: Date?

    var body: some View {
        Canvas { context, size in
            let span = domain.upperBound - domain.lowerBound
            let x = { (date: Date) in frame.x(date, width: size.width) }
            // Clamped so a value far outside the range still gives a point CoreGraphics can draw.
            let y = { (value: Double) -> CGFloat in
                let y = size.height * (1 - CGFloat((value - domain.lowerBound) / (span == 0 ? 1 : span)))
                return min(max(y, -size.height * 100), size.height * 101)
            }
            context.clip(to: Path(CGRect(origin: .zero, size: size)))

            if now < frame.end {
                let start = max(0, x(now))
                context.fill(Path(CGRect(x: start, y: 0, width: size.width - start, height: size.height)), with: .color(Theme.futureTint))
            }
            let startX = modelStart.flatMap { $0 > frame.start ? min(x($0), size.width) : nil }
            if let startX {
                context.fill(Path(CGRect(x: 0, y: 0, width: startX, height: size.height)), with: .color(Theme.beforeStart))
            }
            if !gridValues.isEmpty {
                var grid = Path()
                for value in gridValues {
                    let lineY = y(value)
                    grid.move(to: CGPoint(x: 0, y: lineY))
                    grid.addLine(to: CGPoint(x: size.width, y: lineY))
                }
                context.stroke(grid, with: .color(Theme.grid), lineWidth: 1)
            }
            if let eventLines, !eventLines.dates.isEmpty {
                var path = Path()
                for lineX in PlotEventLines.xs(dates: eventLines.dates, frame: frame, width: size.width) {
                    path.move(to: CGPoint(x: lineX, y: 0))
                    path.addLine(to: CGPoint(x: lineX, y: size.height))
                }
                context.stroke(path, with: .color(eventLines.color), lineWidth: 1)
            }
            for band in bands {
                context.fill(Self.path(for: band.points, x: x, y: y), with: .color(band.color))
            }
            for line in series {
                let path = Self.path(for: line.samples, frame: frame, size: size, x: x, y: y)
                context.stroke(path, with: .color(line.color),
                               style: StrokeStyle(lineWidth: line.lineWidth, lineCap: .round, lineJoin: .round, dash: line.dash))
            }
            if let readings, !readings.samples.isEmpty {
                let color = readings.color.opacity(0.85)
                let path = Self.path(for: readings.samples, frame: frame, size: size, x: x, y: y)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                let low = Self.firstIndex(in: readings.samples, atOrAfter: frame.start)
                let high = Self.firstIndex(in: readings.samples, atOrAfter: frame.end)
                // A dot for each reading, while they're at least 6 points apart on average.
                if high > low, CGFloat(high - low) <= size.width / 6 {
                    var dots = Path()
                    for sample in readings.samples[low..<min(high + 1, readings.samples.count)] where sample.value.isFinite {
                        let center = CGPoint(x: x(sample.time), y: y(sample.value))
                        dots.addEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
                    }
                    context.fill(dots, with: .color(color))
                    context.stroke(dots, with: .color(Theme.panel.opacity(0.6)), lineWidth: 0.75)
                }
            }
            if let startX, startX < size.width {
                var path = Path()
                path.move(to: CGPoint(x: startX, y: 0))
                path.addLine(to: CGPoint(x: startX, y: size.height))
                context.stroke(path, with: .color(Theme.startLine), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            for rule in rules where frame.contains(rule.date) {
                var path = Path()
                let ruleX = x(rule.date)
                path.move(to: CGPoint(x: ruleX, y: 0))
                path.addLine(to: CGPoint(x: ruleX, y: size.height))
                context.stroke(path, with: .color(rule.color), style: StrokeStyle(lineWidth: rule.lineWidth, dash: rule.dash))
            }
            if let marker, frame.contains(marker.date) {
                let center = CGPoint(x: x(marker.date), y: y(marker.value))
                let d = marker.diameter
                context.fill(Path(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)), with: .color(marker.color))
            }
        }
    }

    /// The line through the samples inside the frame (plus one either side so it reaches the edges),
    /// thinned to at most four points per pixel column.
    nonisolated static func path(for samples: [Sample], frame: TimeFrame, size: CGSize,
                     x: (Date) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        var low = firstIndex(in: samples, atOrAfter: frame.start)
        if low > 0 { low -= 1 }
        var high = firstIndex(in: samples, atOrAfter: frame.end)
        if high >= samples.count { high = samples.count - 1 }
        guard low <= high else { return path }

        let count = high - low + 1
        // Values that overflowed (infinite or NaN) can't be drawn: the line breaks there.
        if count <= Int(size.width) * 2 {
            var penDown = false
            for index in low...high {
                let sample = samples[index]
                guard sample.value.isFinite else { penDown = false; continue }
                let point = CGPoint(x: x(sample.time), y: y(sample.value))
                if penDown { path.addLine(to: point) } else { path.move(to: point); penDown = true }
            }
            return path
        }

        // Min/max per pixel column, keeping the order the extremes occurred in.
        var column = Int.min
        var first = 0.0, last = 0.0, minimum = 0.0, maximum = 0.0
        var minIndex = 0, maxIndex = 0
        var started = false
        func flush() {
            guard column != Int.min else { return }
            let columnX = CGFloat(column)
            let points = minIndex <= maxIndex ? [first, minimum, maximum, last] : [first, maximum, minimum, last]
            for value in points {
                let point = CGPoint(x: columnX, y: y(value))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
        }
        for index in low...high {
            let sample = samples[index]
            guard sample.value.isFinite else {
                flush()
                column = Int.min
                started = false
                continue
            }
            let sampleColumn = Int(x(sample.time).rounded(.down))
            if sampleColumn != column {
                flush()
                column = sampleColumn
                first = sample.value
                minimum = sample.value
                maximum = sample.value
                minIndex = index
                maxIndex = index
            }
            if sample.value < minimum { minimum = sample.value; minIndex = index }
            if sample.value > maximum { maximum = sample.value; maxIndex = index }
            last = sample.value
        }
        flush()
        return path
    }

    /// The band's outline: along its top, then back along its bottom. A band covers a stretch of
    /// readings, so it's never long enough to need thinning. Points that can't be drawn are left out.
    nonisolated static func path(for points: [DriftOutcome.BandPoint], x: (Date) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        let drawable = points.filter { $0.low.isFinite && $0.high.isFinite }
        var path = Path()
        guard drawable.count > 1 else { return path }
        path.move(to: CGPoint(x: x(drawable[0].time), y: y(drawable[0].high)))
        for point in drawable.dropFirst() { path.addLine(to: CGPoint(x: x(point.time), y: y(point.high))) }
        for point in drawable.reversed() { path.addLine(to: CGPoint(x: x(point.time), y: y(point.low))) }
        path.closeSubpath()
        return path
    }

    nonisolated static func firstIndex(in samples: [Sample], atOrAfter date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < date { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
