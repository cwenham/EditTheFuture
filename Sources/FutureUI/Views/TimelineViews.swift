import SwiftUI
import Charts
import FutureEngine

/// Click handlers for the timeline. Fractions are 0...1 across the plot width.
struct TimelineInteractions {
    var focusLane: (Int) -> Void
    /// A click on the focused graph or events strip picks the add-event pane's date.
    var pickDate: (Double) -> Void
    /// A click on a lane picks the date and switches the pane to that lane's slot.
    var pickDateOnLane: (Int, Double) -> Void
}

/// The focused graph, time axis, events strip and lanes, laid out in aligned columns.
/// Used by the live panel (with interactions) and by the clipboard snapshot (without).
struct TimelineRows: View {
    let state: PanelState
    let plotWidth: CGFloat
    var focusHeight: CGFloat = TimelineLayout.focusHeight
    var interactions: TimelineInteractions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TimelineLayout.gap) {
                YAxisLabels(ticks: state.focus.yTicks, domain: state.focus.yDomain, format: state.focus.format)
                    .frame(width: TimelineLayout.labelWidth, height: focusHeight)
                FocusChart(state: state)
                    .frame(width: plotWidth, height: focusHeight)
                    .overlay(alignment: .topLeading) { NowLabel(state: state, width: plotWidth) }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        interactions?.pickDate(Double(location.x / plotWidth))
                    }
                Readout(focus: state.focus)
                    .frame(width: TimelineLayout.valueWidth, alignment: .topLeading)
            }

            HStack(spacing: TimelineLayout.gap) {
                Color.clear.frame(width: TimelineLayout.labelWidth)
                TimeAxis(state: state)
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
                EventsStrip(markers: state.focus.events, frame: state.frame, color: state.focus.color, draftDate: state.focus.draftDate)
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
                ForEach(state.lanes) { lane in
                    LaneRow(lane: lane, state: state, plotWidth: plotWidth, interactions: interactions)
                }
            }
            .padding(.top, 8)
        }
    }
}

struct YAxisLabels: View {
    let ticks: [Double]
    let domain: ClosedRange<Double>
    let format: ValueFormat

    var body: some View {
        GeometryReader { geometry in
            ForEach(ticks, id: \.self) { tick in
                let span = domain.upperBound - domain.lowerBound
                let y = geometry.size.height * (1 - (tick - domain.lowerBound) / (span == 0 ? 1 : span))
                Text(format.axis(tick))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .frame(width: geometry.size.width - 8, alignment: .trailing)
                    .position(x: (geometry.size.width - 8) / 2, y: y)
            }
        }
    }
}

struct FocusChart: View {
    let state: PanelState

    var body: some View {
        let focus = state.focus
        Chart {
            if state.now < state.frame.end {
                RectangleMark(xStart: .value("From", max(state.now, state.frame.start)), xEnd: .value("To", state.frame.end),
                              yStart: .value("Low", focus.yDomain.lowerBound), yEnd: .value("High", focus.yDomain.upperBound))
                    .foregroundStyle(Theme.futureTint)
            }
            ForEach(focus.yTicks, id: \.self) { tick in
                RuleMark(y: .value("Grid", tick))
                    .foregroundStyle(Theme.grid)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(focus.samples, id: \.time) { sample in
                LineMark(x: .value("Date", sample.time), y: .value(focus.name, sample.value), series: .value("Line", "model"))
                    .foregroundStyle(focus.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            ForEach(focus.preview, id: \.time) { sample in
                LineMark(x: .value("Date", sample.time), y: .value(focus.name, sample.value), series: .value("Line", "preview"))
                    .foregroundStyle(Theme.proposal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [6, 5]))
            }
            if let draftDate = focus.draftDate {
                RuleMark(x: .value("New event", draftDate))
                    .foregroundStyle(Theme.proposal)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            RuleMark(x: .value("Now", state.now))
                .foregroundStyle(Theme.nowLine)
                .lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(x: .value("Cursor", state.cursor))
                .foregroundStyle(Theme.cursorLine)
                .lineStyle(StrokeStyle(lineWidth: 1))
            if let value = focus.cursorValue {
                PointMark(x: .value("Cursor", state.cursor), y: .value(focus.name, value))
                    .foregroundStyle(focus.color)
                    .symbolSize(55)
            }
        }
        .chartXScale(domain: state.frame.start...state.frame.end)
        .chartYScale(domain: focus.yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .clipped()
        .accessibilityLabel("\(focus.name) from \(DateText.monthYear(state.frame.start)) to \(DateText.monthYear(state.frame.end))")
        .accessibilityValue("\(focus.readoutValue) at \(focus.readoutDate)")
        .accessibilityHint("Click to pick this date for a new event")
    }
}

struct NowLabel: View {
    let state: PanelState
    let width: CGFloat

    var body: some View {
        if state.frame.contains(state.now) {
            Text(state.nowText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize()
                .offset(x: state.frame.x(state.now, width: width) + 6, y: 4)
                .allowsHitTesting(false)
        }
    }
}

struct Readout: View {
    let focus: FocusedSlotState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(focus.readoutDate)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Text(focus.readoutValue)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(focus.readoutNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 4)
    }
}

struct TimeAxis: View {
    let state: PanelState

    var body: some View {
        GeometryReader { geometry in
            ForEach(state.yearTicks) { tick in
                Text(tick.label)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .position(x: state.frame.x(tick.date, width: geometry.size.width), y: 11)
            }
            if state.frame.contains(state.cursor) {
                Text(DateText.monthYear(state.cursor))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "#14161B"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .position(x: state.frame.x(state.cursor, width: geometry.size.width), y: 11)
            }
        }
    }
}

struct EventsStrip: View {
    let markers: [EventMarker]
    let frame: TimeFrame
    let color: Color
    var draftDate: Date?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ForEach(markers) { marker in
                let x = frame.x(marker.date, width: width)
                switch marker.kind {
                case .recurring:
                    let startX = max(0, x)
                    let endX = min(width, frame.x(marker.endDate ?? frame.end, width: width))
                    if endX > startX {
                        Rectangle()
                            .fill(color.opacity(0.45))
                            .frame(width: endX - startX, height: 2)
                            .position(x: (startX + endX) / 2, y: 26)
                        Text(marker.label)
                            .font(.system(size: 11))
                            .fixedSize()
                            .offset(x: startX, y: 4)
                    }
                case .oneOff:
                    if x >= 0 && x <= width {
                        Rectangle()
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .rotationEffect(.degrees(45))
                            .position(x: x, y: 25)
                        Text(marker.label)
                            .font(.system(size: 11))
                            .fixedSize()
                            .position(x: x, y: 10)
                    }
                case .generated:
                    if x >= 0 && x <= width {
                        Circle()
                            .stroke(color, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .position(x: x, y: 25)
                        Text(marker.label)
                            .font(.system(size: 11).italic())
                            .foregroundStyle(Theme.secondary)
                            .fixedSize()
                            .position(x: x, y: 10)
                    }
                }
            }
            if let draftDate, frame.contains(draftDate) {
                Rectangle()
                    .stroke(Theme.proposal, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
                    .position(x: frame.x(draftDate, width: width), y: 25)
            }
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Events")
    }
}

struct LaneRow: View {
    let lane: LaneState
    let state: PanelState
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

            LaneChart(lane: lane, state: state)
                .frame(width: plotWidth, height: 36)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    interactions?.pickDateOnLane(lane.id, Double(location.x / plotWidth))
                }

            Text(lane.valueText)
                .font(.system(size: 13))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: TimelineLayout.valueWidth, alignment: .trailing)
        }
        .frame(height: TimelineLayout.laneRowHeight)
    }
}

struct LaneChart: View {
    let lane: LaneState
    let state: PanelState

    var body: some View {
        Chart {
            if state.now < state.frame.end {
                RectangleMark(xStart: .value("From", max(state.now, state.frame.start)), xEnd: .value("To", state.frame.end),
                              yStart: .value("Low", lane.yDomain.lowerBound), yEnd: .value("High", lane.yDomain.upperBound))
                    .foregroundStyle(Theme.futureTint)
            }
            ForEach(lane.samples, id: \.time) { sample in
                LineMark(x: .value("Date", sample.time), y: .value(lane.name, sample.value))
                    .foregroundStyle(lane.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            RuleMark(x: .value("Now", state.now)).foregroundStyle(Theme.nowLine).lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(x: .value("Cursor", state.cursor)).foregroundStyle(Theme.cursorLine).lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: state.frame.start...state.frame.end)
        .chartYScale(domain: lane.yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .clipped()
        .accessibilityLabel("\(lane.name): \(lane.valueText) at \(DateText.monthYear(state.cursor))")
        .accessibilityHint("Click to pick this date for a new event in \(lane.name)")
    }
}
