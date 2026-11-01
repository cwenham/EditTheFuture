import SwiftUI
import FutureEngine

/// Click handlers for the timeline. Fractions are 0...1 across the plot width.
struct TimelineInteractions {
    var focusLane: (Int) -> Void
    /// A click on the focused graph or events strip picks the add-event pane's date.
    var pickDate: (Double) -> Void
    /// A click on a lane picks the date and switches the pane to that lane's slot.
    var pickDateOnLane: (Int, Double) -> Void
    /// A click on a one-off event's diamond loads it into the add-event pane (docs/UI.md, 5.4).
    var editEvent: (UUID) -> Void
    /// A click on the drift pill opens Refit on the last year of readings (docs/UI.md, 5.6).
    var openDrift: () -> Void = {}
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
                YAxisLabels(ticks: timeline.focus.yTicks, domain: timeline.focus.yDomain, style: timeline.focus.style)
                    .frame(width: TimelineLayout.labelWidth, height: focusHeight)
                FocusChart(timeline: timeline)
                    .frame(width: plotWidth, height: focusHeight)
                    .overlay(alignment: .topLeading) { NowLabel(timeline: timeline, width: plotWidth) }
                    .overlay(alignment: .topLeading) {
                        if let drift = timeline.focus.drift {
                            DriftPill(drift: drift, timeline: timeline, width: plotWidth, action: interactions?.openDrift)
                        }
                    }
                    .overlay { if timeline.showsStart { StartLabel(timeline: timeline) } }
                    .overlay {
                        if let reason = timeline.focus.pausedReason { PausedNote(reason: reason, large: true) }
                    }
                    .overlay(alignment: .top) {
                        if timeline.focus.pausedReason == nil, let reason = timeline.focus.stoppedReason {
                            PausedNote(reason: reason, large: true, stopped: true).padding(.top, 8)
                        }
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
                        Text("click a date or an event").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: TimelineLayout.labelWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 2)
                EventsStrip(markers: timeline.focus.events, frame: timeline.frame, color: timeline.focus.color,
                            draftDate: timeline.focus.draftDate, editingID: timeline.focus.editingEventID)
                    .frame(width: plotWidth, height: TimelineLayout.eventsHeight)
                    .overlay(alignment: .topLeading) {
                        if interactions != nil {
                            DiamondHotspots(diamonds: EventsStrip.diamonds(markers: timeline.focus.events, frame: timeline.frame,
                                                                           width: plotWidth))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        if let id = EventsStrip.editableEvent(atX: location.x, markers: timeline.focus.events,
                                                              frame: timeline.frame, width: plotWidth) {
                            interactions?.editEvent(id)
                        } else {
                            interactions?.pickDate(Double(location.x / plotWidth))
                        }
                    }
                    .accessibilityActions {
                        if let interactions {
                            ForEach(timeline.focus.events.filter { $0.kind == .oneOff && timeline.frame.contains($0.date) }) { marker in
                                Button("Edit \(marker.label), \(DateText.monthYear(marker.date))") { interactions.editEvent(marker.id) }
                            }
                        }
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
    let style: ValueStyle

    var body: some View {
        Canvas { context, size in
            let span = domain.upperBound - domain.lowerBound
            for tick in ticks {
                let y = size.height * (1 - (tick - domain.lowerBound) / (span == 0 ? 1 : span))
                let label = context.resolve(Text(style.axis(tick)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.secondary))
                // Keep the top and bottom labels inside the canvas instead of half-clipped.
                let clampedY = min(max(y, 7), size.height - 7)
                context.draw(label, at: CGPoint(x: size.width - 8, y: clampedY), anchor: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Values from \(style.axis(domain.lowerBound)) to \(style.axis(domain.upperBound))")
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
        if !focus.heldBack.isEmpty {
            series.append(PlotSeries(samples: focus.heldBack, color: Theme.proposal, lineWidth: 1.25, dash: [1.5, 3]))
        }
        var bands: [PlotBand] = []
        if let drift = focus.drift {
            bands.append(PlotBand(points: drift.band, color: Theme.warning.opacity(0.12)))
            series.append(PlotSeries(samples: drift.line, color: Theme.warning.opacity(0.8), lineWidth: 1.25, dash: [1.5, 3]))
        }
        var rules = [PlotRule(date: timeline.now, color: Theme.nowLine)]
        if let cutoff = focus.cutoff {
            rules.append(PlotRule(date: cutoff, color: Theme.proposal.opacity(0.45), dash: [1.5, 3]))
        }
        if let draftDate = focus.draftDate {
            rules.append(PlotRule(date: draftDate, color: Theme.proposal, dash: [3, 3]))
        }
        return PlotCanvas(frame: timeline.frame, domain: focus.yDomain, now: timeline.now, gridValues: focus.yTicks,
                          bands: bands, series: series, rules: rules,
                          readings: focus.readings.isEmpty ? nil : PlotReadings(samples: focus.readings, color: Theme.reading),
                          modelStart: timeline.start)
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

/// The drift pill (docs/UI.md, 5.6): just left of the now line, at the Now label's height, or right
/// of the label when there isn't room on the left. Clicking it opens Refit on the last year.
struct DriftPill: View {
    let drift: DriftMark
    let timeline: TimelineState
    let width: CGFloat
    let action: (() -> Void)?

    /// About as wide as the pill gets; enough to tell which side of the now line it fits.
    static let roomNeeded: CGFloat = 250

    var body: some View {
        let nowX = timeline.frame.x(timeline.now, width: width)
        let pill = Button { action?() } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text("Drift · " + drift.text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.warningFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(drift.detail + (action == nil ? "" : " Click to refit to the last year of readings."))
        .accessibilityLabel("Drift: " + drift.detail)
        .accessibilityHint("Opens Refit on the last year of readings")
        let onLeft = nowX >= Self.roomNeeded && nowX <= width
        HStack(spacing: 0) {
            if onLeft {
                Spacer(minLength: 0)
                pill.padding(.trailing, max(8, width - nowX + 8))
            } else {
                // Past the Now label, or at the left edge when now is off to the left.
                pill.padding(.leading, nowX > width ? 8 : max(8, nowX + 120))
                Spacer(minLength: 0)
            }
        }
        .frame(width: width)
        .padding(.top, 2)
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

/// "Start · Jan 2022", just left of the dashed line where the models' lines begin, while the view
/// reaches back before the start (docs/UI.md, 2.4). Left out when there isn't room for it there, or
/// where it would cover the Now label.
struct StartLabel: View {
    let timeline: TimelineState

    var body: some View {
        Canvas { context, size in
            let font = Font.system(size: 11, weight: .semibold)
            let label = context.resolve(Text(timeline.startText).font(font).foregroundStyle(Theme.secondary))
            let startX = timeline.frame.x(timeline.start, width: size.width)
            var nowLabel: (from: CGFloat, to: CGFloat)?
            if timeline.frame.contains(timeline.now) {
                let nowX = timeline.frame.x(timeline.now, width: size.width) + 6
                nowLabel = (nowX, nowX + context.resolve(Text(timeline.nowText).font(font)).measure(in: size).width)
            }
            guard let edge = Self.trailingEdge(startX: startX, labelWidth: label.measure(in: size).width, nowLabel: nowLabel)
            else { return }
            context.draw(label, at: CGPoint(x: edge, y: 4), anchor: .topTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeline.startText)
    }

    /// Where the label ends: 6 points left of the start line. Nil when it would run off the left
    /// edge, or come within 8 points of the Now label.
    static func trailingEdge(startX: CGFloat, labelWidth: CGFloat, nowLabel: (from: CGFloat, to: CGFloat)?) -> CGFloat? {
        let edge = startX - 6, left = edge - labelWidth
        guard left >= 0 else { return nil }
        if let nowLabel, nowLabel.from - 8 < edge, nowLabel.to + 8 > left { return nil }
        return edge
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
                // Small enough for a national debt written out in full: $40,463,151,897,249.
                .minimumScaleFactor(0.45)
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
    /// The one-off event being edited in the add-event pane.
    var editingID: UUID?

    /// How far from a diamond's centre a click still lands on it, in points.
    static let hitSlop: CGFloat = 8

    /// Where the one-off events' diamonds are in a strip `width` points wide: the ones a click can edit.
    static func diamonds(markers: [EventMarker], frame: TimeFrame, width: CGFloat) -> [Diamond] {
        markers.filter { $0.kind == .oneOff && frame.contains($0.date) }
            .map { Diamond(id: $0.id, x: frame.x($0.date, width: width)) }
    }

    struct Diamond: Identifiable, Equatable {
        let id: UUID
        let x: CGFloat
    }

    /// The one-off event whose diamond is at `x` in a strip `width` points wide: the nearest within
    /// `hitSlop`, so the small diamonds are easy to hit.
    static func editableEvent(atX x: CGFloat, markers: [EventMarker], frame: TimeFrame, width: CGFloat) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for diamond in diamonds(markers: markers, frame: frame, width: width) {
            let distance = abs(diamond.x - x)
            if distance <= hitSlop, distance < (best?.distance ?? .infinity) { best = (diamond.id, distance) }
        }
        return best?.id
    }

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
                    let editing = marker.id == editingID
                    // Being edited: ringed, and faint once the draft moves it to another date.
                    let moved = editing && draftDate != marker.date
                    context.fill(Self.diamond(at: CGPoint(x: x, y: 25), size: 9), with: .color(color.opacity(moved ? 0.35 : 1)))
                    if editing {
                        context.stroke(Self.diamond(at: CGPoint(x: x, y: 25), size: 12), with: .color(Theme.proposal), lineWidth: 1.5)
                    }
                    let label = context.resolve(Text(marker.label).font(.system(size: 11)).foregroundStyle(Theme.text))
                    context.draw(label, at: CGPoint(x: x, y: 10), anchor: .center)
                case .generated:
                    guard x >= 0 && x <= width else { continue }
                    context.stroke(Path(ellipseIn: CGRect(x: x - 4, y: 21, width: 8, height: 8)), with: .color(color), lineWidth: 1.5)
                    let label = context.resolve(Text(marker.label).font(.system(size: 11).italic()).foregroundStyle(Theme.secondary))
                    context.draw(label, at: CGPoint(x: x, y: 10), anchor: .center)
                }
            }
            let editedDate = markers.first { $0.id == editingID }?.date
            if let draftDate, frame.contains(draftDate), draftDate != editedDate {
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

/// Clear areas over the diamonds, so the pointer turns into a hand over them as it does over a
/// link. Clicks go on to the strip's own tap.
///
/// SwiftUI's hosting view sets the pointer itself as the mouse moves, so setting `NSCursor`
/// from a hover handler flickered between the hand and the arrow. A pointer style on a view is
/// SwiftUI's own way, and stays steady.
struct DiamondHotspots: View {
    let diamonds: [EventsStrip.Diamond]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(diamonds) { diamond in
                Color.clear
                    .frame(width: EventsStrip.hitSlop * 2, height: TimelineLayout.eventsHeight)
                    .contentShape(Rectangle())
                    .linkPointer()
                    .offset(x: diamond.x - EventsStrip.hitSlop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// The pointing hand while the pointer is over this view.
    @ViewBuilder func linkPointer() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        #else
        self
        #endif
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
                        HStack(spacing: 4) {
                            Text(lane.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if let drift = lane.drift {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.warning)
                                    .help(drift)
                                    .accessibilityLabel("Drift: " + drift)
                            }
                        }
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
                       rules: [PlotRule(date: timeline.now, color: Theme.nowLine)], modelStart: timeline.start)
                .frame(width: plotWidth, height: 36)
                .overlay(alignment: .leading) {
                    if let reason = lane.pausedReason { PausedNote(reason: reason, large: false) }
                }
                .overlay(alignment: .trailing) {
                    if lane.pausedReason == nil, let reason = lane.stoppedReason { PausedNote(reason: reason, large: false, stopped: true) }
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
    /// Stopped partway by an error, rather than paused.
    var stopped = false

    var body: some View {
        let title = stopped ? "Stopped" : "Paused"
        HStack(spacing: 8) {
            Image(systemName: stopped ? "exclamationmark.octagon" : "pause.circle")
                .font(.system(size: large ? 15 : 12))
            Text(large ? title : title + " · " + reason)
                .font(.system(size: large ? 15 : 12, weight: .semibold))
                .lineLimit(1)
            if large {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(stopped ? Theme.error : Theme.warning)
        .padding(.horizontal, large ? 14 : 8)
        .padding(.vertical, large ? 10 : 3)
        .background((stopped ? Theme.error : Theme.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            .minimumScaleFactor(0.7)
    }
}
