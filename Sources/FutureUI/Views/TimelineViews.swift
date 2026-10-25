import SwiftUI
import FutureEngine

/// Click handlers for the timeline. Fractions are 0...1 across the plot width.
struct TimelineInteractions {
    var focusLane: (Int) -> Void
    /// A click on the focused graph or events strip picks the add-event pane's date.
    var pickDate: (Double) -> Void
    /// A click on a lane picks the date and switches the pane to that lane's slot.
    var pickDateOnLane: (Int, Double) -> Void
}

/// Where cursor-dependent views get their values: the live store (so only they redraw when the
/// pointer moves) or a fixed snapshot (for the clipboard image).
enum CursorSource {
    case live(ScenarioStore)
    case fixed(CursorState)

    @MainActor var state: CursorState {
        switch self {
        case .live(let store): return store.cursorState()
        case .fixed(let state): return state
        }
    }
}

/// The focused graph, time axis, events strip and lanes, laid out in aligned columns, with the
/// cursor drawn on top by its own small views.
struct TimelineRows: View {
    let timeline: TimelineState
    let cursor: CursorSource
    let plotWidth: CGFloat
    var focusHeight: CGFloat = TimelineLayout.focusHeight
    var interactions: TimelineInteractions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TimelineLayout.gap) {
                YAxisLabels(ticks: timeline.focus.yTicks, domain: timeline.focus.yDomain, format: timeline.focus.format)
                    .frame(width: TimelineLayout.labelWidth, height: focusHeight)
                FocusChart(timeline: timeline)
                    .frame(width: plotWidth, height: focusHeight)
                    .overlay(alignment: .topLeading) { NowLabel(timeline: timeline, width: plotWidth) }
                    .overlay {
                        if let reason = timeline.focus.pausedReason { PausedNote(reason: reason, large: true) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        interactions?.pickDate(Double(location.x / plotWidth))
                    }
                Readout(cursor: cursor)
                    .frame(width: TimelineLayout.valueWidth, alignment: .topLeading)
            }

            HStack(spacing: TimelineLayout.gap) {
                Color.clear.frame(width: TimelineLayout.labelWidth)
                TimeAxis(timeline: timeline)
                    .frame(width: plotWidth, height: TimelineLayout.axisHeight)
                Color.clear.frame(width: TimelineLayout.valueWidth)
            }

            HStack(alignment: .top, spacing: TimelineLayout.gap) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Events").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if interactions != nil {
                        Text("click to pick a date").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: TimelineLayout.labelWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 2)
                EventsStrip(markers: timeline.focus.events, frame: timeline.frame, color: timeline.focus.color,
                            draftDate: timeline.focus.draftDate)
                    .frame(width: plotWidth, height: TimelineLayout.eventsHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        interactions?.pickDate(Double(location.x / plotWidth))
                    }
                Color.clear.frame(width: TimelineLayout.valueWidth)
            }
            .frame(height: TimelineLayout.eventsHeight)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 10)

            VStack(spacing: TimelineLayout.laneSpacing) {
                ForEach(timeline.lanes) { lane in
                    LaneRow(lane: lane, timeline: timeline, cursor: cursor, plotWidth: plotWidth, interactions: interactions)
                }
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .topLeading) {
            CursorOverlay(cursor: cursor, frame: timeline.frame, plotWidth: plotWidth, focusHeight: focusHeight,
                          focusDomain: timeline.focus.yDomain, focusColor: timeline.focus.color)
                .allowsHitTesting(false)
        }
    }
}

struct YAxisLabels: View {
    let ticks: [Double]
    let domain: ClosedRange<Double>
    let format: ValueFormat

    var body: some View {
        Canvas { context, size in
            let span = domain.upperBound - domain.lowerBound
            for tick in ticks {
                let y = size.height * (1 - (tick - domain.lowerBound) / (span == 0 ? 1 : span))
                let label = context.resolve(Text(format.axis(tick)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.secondary))
                // Keep the top and bottom labels inside the canvas instead of half-clipped.
                let clampedY = min(max(y, 7), size.height - 7)
                context.draw(label, at: CGPoint(x: size.width - 8, y: clampedY), anchor: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Values from \(format.axis(domain.lowerBound)) to \(format.axis(domain.upperBound))")
    }
}

struct FocusChart: View {
    let timeline: TimelineState

    var body: some View {
        let focus = timeline.focus
        var series = [PlotSeries(samples: focus.samples, color: focus.color, lineWidth: 2)]
        if !focus.preview.isEmpty {
            series.append(PlotSeries(samples: focus.preview, color: Theme.proposal, lineWidth: 2, dash: [6, 5]))
        }
        var rules = [PlotRule(date: timeline.now, color: Theme.nowLine)]
        if let draftDate = focus.draftDate {
            rules.append(PlotRule(date: draftDate, color: Theme.proposal, dash: [3, 3]))
        }
        return PlotCanvas(frame: timeline.frame, domain: focus.yDomain, now: timeline.now, gridValues: focus.yTicks,
                          series: series, rules: rules)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(focus.name) from \(DateText.monthYear(timeline.frame.start)) to \(DateText.monthYear(timeline.frame.end))")
            .accessibilityHint("Click to pick this date for a new event")
    }
}

/// The cursor line through every plot, the dot on the focused line and the date flag on the axis.
/// It's the only part of the timeline that redraws when the pointer moves. It uses plain shape
/// views rather than a Canvas: moving a 1-point line is a cheap layer move, while a full-height
/// Canvas had to be redrawn pixel by pixel on every pointer move.
struct CursorOverlay: View {
    let cursor: CursorSource
    let frame: TimeFrame
    let plotWidth: CGFloat
    let focusHeight: CGFloat
    let focusDomain: ClosedRange<Double>
    let focusColor: Color

    var body: some View {
        let state = cursor.state
        let x = TimelineLayout.plotLeading + frame.x(state.date, width: plotWidth)
        GeometryReader { geometry in
            if frame.contains(state.date) {
                Rectangle()
                    .fill(Theme.cursorLine)
                    .frame(width: 1, height: geometry.size.height)
                    .offset(x: x - 0.5)
                if let value = state.focusValue, let y = dotY(value) {
                    Circle()
                        .fill(focusColor)
                        .frame(width: 8, height: 8)
                        .offset(x: x - 4, y: y - 4)
                }
                Text(state.readoutDate)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "#14161B"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .position(x: x, y: focusHeight + TimelineLayout.axisHeight / 2)
            }
        }
    }

    private func dotY(_ value: Double) -> CGFloat? {
        let span = focusDomain.upperBound - focusDomain.lowerBound
        let y = focusHeight * (1 - CGFloat((value - focusDomain.lowerBound) / (span == 0 ? 1 : span)))
        return y >= 0 && y <= focusHeight ? y : nil
    }
}

struct NowLabel: View {
    let timeline: TimelineState
    let width: CGFloat

    var body: some View {
        if timeline.frame.contains(timeline.now) {
            Text(timeline.nowText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize()
                .offset(x: timeline.frame.x(timeline.now, width: width) + 6, y: 4)
                .allowsHitTesting(false)
        }
    }
}

struct Readout: View {
    let cursor: CursorSource

    var body: some View {
        let state = cursor.state
        VStack(alignment: .leading, spacing: 2) {
            Text(state.readoutDate)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Text(state.readoutValue)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(state.readoutNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

struct TimeAxis: View {
    let timeline: TimelineState

    var body: some View {
        Canvas { context, size in
            for tick in timeline.yearTicks {
                let label = context.resolve(Text(tick.label).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary))
                context.draw(label, at: CGPoint(x: timeline.frame.x(tick.date, width: size.width), y: size.height / 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Years " + timeline.yearTicks.map(\.label).joined(separator: ", "))
    }
}

struct EventsStrip: View {
    let markers: [EventMarker]
    let frame: TimeFrame
    let color: Color
    var draftDate: Date?

    /// Drawn in one Canvas instead of a few views per marker, which kept SwiftUI busy on every scroll.
    var body: some View {
        Canvas { context, size in
            let width = size.width
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            for marker in markers {
                let x = frame.x(marker.date, width: width)
                switch marker.kind {
                case .recurring:
                    let startX = max(0, x)
                    let endX = min(width, frame.x(marker.endDate ?? frame.end, width: width))
                    guard endX > startX else { continue }
                    context.fill(Path(CGRect(x: startX, y: 25, width: endX - startX, height: 2)), with: .color(color.opacity(0.45)))
                    let label = context.resolve(Text(marker.label).font(.system(size: 11)).foregroundStyle(Theme.text))
                    context.draw(label, at: CGPoint(x: startX, y: 10), anchor: .leading)
                case .oneOff:
                    guard x >= 0 && x <= width else { continue }
                    context.fill(Self.diamond(at: CGPoint(x: x, y: 25), size: 9), with: .color(color))
                    let label = context.resolve(Text(marker.label).font(.system(size: 11)).foregroundStyle(Theme.text))
                    context.draw(label, at: CGPoint(x: x, y: 10), anchor: .center)
                case .generated:
                    guard x >= 0 && x <= width else { continue }
                    context.stroke(Path(ellipseIn: CGRect(x: x - 4, y: 21, width: 8, height: 8)), with: .color(color), lineWidth: 1.5)
                    let label = context.resolve(Text(marker.label).font(.system(size: 11).italic()).foregroundStyle(Theme.secondary))
                    context.draw(label, at: CGPoint(x: x, y: 10), anchor: .center)
                }
            }
            if let draftDate, frame.contains(draftDate) {
                context.stroke(Self.diamond(at: CGPoint(x: frame.x(draftDate, width: width), y: 25), size: 10),
                               with: .color(Theme.proposal), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Events: " + markers.map(\.label).joined(separator: ", "))
    }

    static func diamond(at center: CGPoint, size: CGFloat) -> Path {
        let half = size * 0.7
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - half))
        path.addLine(to: CGPoint(x: center.x + half, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + half))
        path.addLine(to: CGPoint(x: center.x - half, y: center.y))
        path.closeSubpath()
        return path
    }
}

struct LaneRow: View {
    let lane: LaneState
    let timeline: TimelineState
    let cursor: CursorSource
    let plotWidth: CGFloat
    var interactions: TimelineInteractions?

    var body: some View {
        HStack(spacing: TimelineLayout.gap) {
            Button {
                interactions?.focusLane(lane.id)
            } label: {
                HStack(spacing: 8) {
                    Text("\(lane.key)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 10)
                    RoundedRectangle(cornerRadius: 2).fill(lane.color).frame(width: 3, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lane.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let reads = lane.reads {
                            Text(reads).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: TimelineLayout.labelWidth)
            .accessibilityLabel("Focus \(lane.name)")

            PlotCanvas(frame: timeline.frame, domain: lane.yDomain, now: timeline.now,
                       series: [PlotSeries(samples: lane.samples, color: lane.color, lineWidth: 1.6)],
                       rules: [PlotRule(date: timeline.now, color: Theme.nowLine)])
                .frame(width: plotWidth, height: 36)
                .overlay(alignment: .leading) {
                    if let reason = lane.pausedReason { PausedNote(reason: reason, large: false) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    interactions?.pickDateOnLane(lane.id, Double(location.x / plotWidth))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(lane.name)
                .accessibilityHint("Click to pick this date for a new event in \(lane.name)")

            LaneValue(cursor: cursor, slotIndex: lane.id)
                .frame(width: TimelineLayout.valueWidth, alignment: .trailing)
        }
        .frame(height: TimelineLayout.laneRowHeight)
    }
}

/// Shown in place of a paused slot's line (docs/UI.md, 5.7).
struct PausedNote: View {
    let reason: String
    let large: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.system(size: large ? 15 : 12))
            Text(large ? "Paused" : "Paused · " + reason)
                .font(.system(size: large ? 15 : 12, weight: .semibold))
                .lineLimit(1)
            if large {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, large ? 14 : 8)
        .padding(.vertical, large ? 10 : 3)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .help(reason)
        .accessibilityElement(children: .combine)
    }
}

/// A lane's value at the cursor; redraws on its own when the pointer moves.
struct LaneValue: View {
    let cursor: CursorSource
    let slotIndex: Int

    var body: some View {
        Text(cursor.state.laneValues[slotIndex] ?? "—")
            .font(.system(size: 13))
            .monospacedDigit()
            .lineLimit(1)
    }
}
