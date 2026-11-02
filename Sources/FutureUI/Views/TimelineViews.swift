import SwiftUI
import CoreText
import FutureEngine

/// Click handlers for the timeline. Fractions are 0...1 across the plot width.
struct TimelineInteractions {
    /// A click on a lane's name, or a ⌘- or ⇧-click on its graph (docs/UI.md, 5.12).
    var selectSlot: (Int, SlotClick) -> Void
    /// A click on the focused graph or events strip picks the add-event pane's date.
    var pickDate: (Double) -> Void
    /// A click on a lane picks the date and switches the pane to that lane's slot.
    var pickDateOnLane: (Int, Double) -> Void
    /// A click on a one-off event's diamond, or a repeating event's bar or label, loads it into the
    /// add-event pane (docs/UI.md, 5.4).
    var editEvent: (UUID) -> Void
    /// A click on the drift pill opens Refit on the last year of readings (docs/UI.md, 5.6).
    var openDrift: () -> Void = {}
    /// Drag the future (docs/UI.md, 5.2): whether a target can be set at a date, starting a drag
    /// at a date and value, moving the target, and letting go.
    var canSetGoal: (Date) -> Bool = { _ in false }
    var beginGoal: (Date, Double) -> Void = { _, _ in }
    var dragGoal: (Double) -> Void = { _ in }
    var endGoal: () -> Void = {}
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

/// The focused graph, time axis, events strip and lanes, with each graph's value range eased to
/// a new one over a second rather than jumping (docs/UI.md, 2.4).
///
/// While a range eases, a clock ticks once a frame (`ScaleEasing.time`), and only the views that
/// draw a range read it. A new view starts at its targets, so a snapshot is never caught part-way.
struct TimelineRows: View {
    let timeline: TimelineState
    let cursor: CursorSource
    let plotWidth: CGFloat
    var focusHeight: CGFloat = TimelineLayout.focusHeight
    var interactions: TimelineInteractions?
    @State private var easing = ScaleEasing()
    /// Bumped when the last range arrives, so the clock stops.
    @State private var settled = 0

    var body: some View {
        let _ = settled
        let now = Date()
        let _ = easing.retarget(timeline.scaleTargets, at: now)
        let end = easing.end(after: now)
        TimelineRowsContent(timeline: timeline, scales: easing, cursor: cursor, plotWidth: plotWidth,
                            focusHeight: focusHeight, interactions: interactions)
            .background {
                if end != nil {
                    TimelineView(.animation) { context in
                        Color.clear.onChange(of: context.date, initial: true) { _, date in easing.advance(to: date) }
                    }
                }
            }
            .task(id: end) {
                guard let end else { return }
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)) + .milliseconds(20))
                guard !Task.isCancelled else { return }
                easing.advance(to: Date())  // the last frame, at the targets
                settled += 1
            }
    }
}

/// The focused graph, time axis, events strip and lanes, laid out in aligned columns, with the
/// cursor drawn on top by its own small views.
struct TimelineRowsContent: View {
    let timeline: TimelineState
    /// Where each graph's range is part-way through a change of scale; read only inside `Eased`.
    var scales: ScaleEasing?
    let cursor: CursorSource
    let plotWidth: CGFloat
    var focusHeight: CGFloat = TimelineLayout.focusHeight
    var interactions: TimelineInteractions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TimelineLayout.gap) {
                Eased(timeline: timeline, scales: scales) { shown in
                    YAxisLabels(ticks: shown.focus.yTicks, domain: shown.focus.yDomain, style: shown.focus.style)
                }
                .frame(width: TimelineLayout.labelWidth, height: focusHeight)
                Eased(timeline: timeline, scales: scales) { FocusChart(timeline: $0) }
                    .frame(width: plotWidth, height: focusHeight)
                    .overlay(alignment: .topLeading) { NowLabel(timeline: timeline, width: plotWidth) }
                    .overlay {
                        if timeline.focus.goal != nil {
                            Eased(timeline: timeline, scales: scales) { shown in
                                if let goal = shown.focus.goal {
                                    GoalOverlay(goal: goal, frame: shown.frame, domain: shown.focus.yDomain, color: shown.focus.color)
                                }
                            }
                        }
                    }
                    .overlay {
                        if let interactions {
                            Eased(timeline: timeline, scales: scales) { GoalHandle(cursor: cursor, timeline: $0, interactions: interactions) }
                        }
                    }
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
                let strip = EventsStrip.layout(markers: timeline.focus.events, frame: timeline.frame, width: plotWidth,
                                               editingID: timeline.focus.editingEventID)
                EventsStrip(markers: timeline.focus.events, frame: timeline.frame, color: timeline.focus.color,
                            draftDate: timeline.focus.draftDate, editingID: timeline.focus.editingEventID)
                    .frame(width: plotWidth, height: TimelineLayout.eventsHeight)
                    .overlay(alignment: .topLeading) {
                        if interactions != nil { EventHotspots(items: strip) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        if let id = EventsStrip.editableEvent(at: location, in: strip) {
                            interactions?.editEvent(id)
                        } else {
                            interactions?.pickDate(Double(location.x / plotWidth))
                        }
                    }
                    .accessibilityActions {
                        if let interactions {
                            ForEach(strip.filter { $0.kind != .generated }) { item in
                                Button("Edit \(item.label), \(DateText.monthYear(item.date))") { interactions.editEvent(item.id) }
                            }
                        }
                    }
                Color.clear.frame(width: TimelineLayout.valueWidth)
            }
            .frame(height: TimelineLayout.eventsHeight)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 10)

            VStack(spacing: TimelineLayout.laneSpacing) {
                ForEach(timeline.lanes) { lane in
                    LaneRow(lane: lane, timeline: timeline, scales: scales, cursor: cursor, plotWidth: plotWidth, interactions: interactions)
                }
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .topLeading) {
            Eased(timeline: timeline, scales: scales) { shown in
                CursorOverlay(cursor: cursor, frame: shown.frame, plotWidth: plotWidth, focusHeight: focusHeight,
                              focusDomain: shown.focus.yDomain, focusColor: shown.focus.color, overlays: shown.overlays)
            }
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
            // While the range eases to a new one, ticks for the new range can be outside it.
            let slack = span * 0.01
            for tick in ticks where tick >= domain.lowerBound - slack && tick <= domain.upperBound + slack {
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

    /// The dates of the events a person added: one-off events and where recurring ones start.
    /// Not the ones a model generates, and not readings.
    static func eventLineDates(_ markers: [EventMarker]) -> [Date] {
        markers.filter { $0.kind != .generated }.map(\.date)
    }

    var body: some View {
        let focus = timeline.focus
        // Other slots drawn over the graph go underneath, a little thinner (docs/UI.md, 5.12).
        var series = timeline.overlays.map { overlay in
            PlotSeries(samples: overlay.samples, color: overlay.color.opacity(focus.goal == nil ? 0.9 : 0.35), lineWidth: 1.75,
                       domain: overlay.ownScale ? overlay.yDomain : nil)
        }
        // While a target is set, the line as it is fades, so the proposed path stands out.
        series.append(PlotSeries(samples: focus.samples, color: focus.color.opacity(focus.goal == nil ? 1 : 0.45), lineWidth: 2))
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
        if let goal = focus.goal {
            rules.append(PlotRule(date: goal.date, color: Color.white.opacity(0.35), dash: [3, 4]))
        }
        if let cutoff = focus.cutoff {
            rules.append(PlotRule(date: cutoff, color: Theme.proposal.opacity(0.45), dash: [1.5, 3]))
        }
        if let draftDate = focus.draftDate {
            rules.append(PlotRule(date: draftDate, color: Theme.proposal, dash: [3, 3]))
        }
        return PlotCanvas(frame: timeline.frame, domain: focus.yDomain, now: timeline.now, gridValues: focus.yTicks,
                          bands: bands, series: series, rules: rules,
                          eventLines: PlotEventLines(dates: Self.eventLineDates(focus.events), color: focus.color.opacity(0.22)),
                          readings: focus.readings.isEmpty ? nil : PlotReadings(samples: focus.readings, color: Theme.reading),
                          modelStart: timeline.start)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityName(timeline)
                                + " from \(DateText.monthYear(timeline.frame.start)) to \(DateText.monthYear(timeline.frame.end))")
            .accessibilityHint("Click to pick this date for a new event")
    }

    /// "Savings", or "Savings, with Index fund and Climate".
    static func accessibilityName(_ timeline: TimelineState) -> String {
        let others = timeline.overlays.map(\.name)
        guard !others.isEmpty else { return timeline.focus.name }
        let list = others.count == 1 ? others[0] : others.dropLast().joined(separator: ", ") + " and " + others.last!
        return timeline.focus.name + ", with " + list
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
    var overlays: [OverlayState] = []

    var body: some View {
        let state = cursor.state
        let x = TimelineLayout.plotLeading + frame.x(state.date, width: plotWidth)
        GeometryReader { geometry in
            if frame.contains(state.date) {
                Rectangle()
                    .fill(Theme.cursorLine)
                    .frame(width: 1, height: geometry.size.height)
                    .offset(x: x - 0.5)
                ForEach(overlays) { overlay in
                    if let value = state.overlayValues[overlay.id], let y = dotY(value, domain: overlay.yDomain) {
                        Circle()
                            .fill(overlay.color)
                            .frame(width: 7, height: 7)
                            .offset(x: x - 3.5, y: y - 3.5)
                    }
                }
                if let value = state.focusValue, let y = dotY(value, domain: focusDomain) {
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

    private func dotY(_ value: Double, domain: ClosedRange<Double>) -> CGFloat? {
        let span = domain.upperBound - domain.lowerBound
        let y = focusHeight * (1 - CGFloat((value - domain.lowerBound) / (span == 0 ? 1 : span)))
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
    /// The event or repeating event being edited in the add-event pane.
    var editingID: UUID?

    /// How far from a diamond's centre a click still lands on it, in points.
    static let hitSlop: CGFloat = 8
    /// The middle of the label row, and of the row of diamonds and circles.
    static let labelY: CGFloat = 10
    static let markerY: CGFloat = 25
    static let labelHeight: CGFloat = 14
    /// Space kept clear between two labels.
    static let labelGap: CGFloat = 8
    /// Repeating events that overlap in time get rows of their own, up to three.
    static let barRows = 3

    nonisolated static func barY(row: Int) -> CGFloat { 22 + CGFloat(row) * 5 }

    /// A marker in view, where it's drawn, and where its label went.
    struct Item: Identifiable, Equatable {
        let id: UUID
        let kind: EventMarker.Kind
        let label: String
        let date: Date
        /// A diamond or circle's centre, or where a repeating event's bar starts in view.
        let x: CGFloat
        /// Where a repeating event's bar ends in view, and its row.
        var barEnd: CGFloat = 0
        var row = 0
        /// Where the label is drawn, or nil when there was no room for it: its help still says it.
        var labelRect: CGRect?
    }

    /// Lays out the strip `width` points wide: rows for repeating events that overlap, and labels
    /// that never cover each other. Labels go in order of importance: the event being edited, then
    /// one-off events, repeating events and generated ones, each from the left. One that would touch
    /// a label already placed is left out (docs/UI.md, 5.4). Drawing and clicks use the same layout.
    nonisolated static func layout(markers: [EventMarker], frame: TimeFrame, width: CGFloat, editingID: UUID? = nil,
                       measure: (String, Bool) -> CGFloat = EventsStrip.labelWidth) -> [Item] {
        var items: [Item] = []
        var rowEnds = [CGFloat](repeating: -.infinity, count: barRows)
        for marker in markers {
            let x = frame.x(marker.date, width: width)
            switch marker.kind {
            case .recurring:
                let start = max(0, x), end = min(width, frame.x(marker.endDate ?? frame.end, width: width))
                guard end > start else { continue }
                // The first row free by then, or else the one that frees up soonest.
                let row = rowEnds.firstIndex { $0 + 4 < start } ?? rowEnds.indices.min { rowEnds[$0] < rowEnds[$1] } ?? 0
                rowEnds[row] = end
                items.append(Item(id: marker.id, kind: .recurring, label: marker.label, date: marker.date, x: start, barEnd: end, row: row))
            case .oneOff, .generated:
                guard x >= 0 && x <= width else { continue }
                items.append(Item(id: marker.id, kind: marker.kind, label: marker.label, date: marker.date, x: x))
            }
        }

        func rank(_ item: Item) -> Int {
            if item.id == editingID { return 0 }
            switch item.kind {
            case .oneOff: return 1
            case .recurring: return 2
            case .generated: return 3
            }
        }
        var widths: [String: CGFloat] = [:]
        var placed: [CGRect] = []
        let order = items.indices.sorted { (rank(items[$0]), items[$0].x) < (rank(items[$1]), items[$1].x) }
        for index in order where !items[index].label.isEmpty {
            let item = items[index]
            let key = (item.kind == .generated ? "i:" : "r:") + item.label
            let labelWidth = widths[key] ?? measure(item.label, item.kind == .generated)
            widths[key] = labelWidth
            guard labelWidth <= width else { continue }
            // Repeating events' labels start at their bar; the others are centred on their marker.
            let left = item.kind == .recurring ? item.x : item.x - labelWidth / 2
            let rect = CGRect(x: min(max(0, left), width - labelWidth), y: labelY - labelHeight / 2,
                              width: labelWidth, height: labelHeight)
            let clearance = rect.insetBy(dx: -labelGap / 2, dy: 0)
            guard !placed.contains(where: { $0.intersects(clearance) }) else { continue }
            placed.append(clearance)
            items[index].labelRect = rect
        }
        return items
    }

    /// The one-off event or repeating event a click at `point` means: the nearest diamond within
    /// `hitSlop` across, then a label, then a bar. Generated events can't be edited, so a click on
    /// one's circle picks a date.
    nonisolated static func editableEvent(at point: CGPoint, in items: [Item]) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for item in items where item.kind == .oneOff {
            let distance = abs(item.x - point.x)
            if distance <= hitSlop, distance < (best?.distance ?? .infinity) { best = (item.id, distance) }
        }
        if let best { return best.id }
        // A generated event's circle isn't editable, even where it sits on a repeating event's bar.
        let onCircle = items.contains {
            $0.kind == .generated && abs($0.x - point.x) <= 5 && abs(markerY - point.y) <= 5
        }
        if onCircle { return nil }
        for item in items where item.kind != .generated {
            if let rect = item.labelRect, rect.insetBy(dx: -2, dy: -2).contains(point) { return item.id }
        }
        let bars = items.filter { $0.kind == .recurring && point.x >= $0.x - 2 && point.x <= $0.barEnd + 2 }
        return bars.map { (id: $0.id, distance: abs(barY(row: $0.row) - point.y)) }
            .filter { $0.distance <= 3 }
            .min { $0.distance < $1.distance }?.id
    }

    /// A label's width in the strip's 11-point font, italic for generated events.
    nonisolated static func labelWidth(_ text: String, italic: Bool) -> CGFloat {
        let font = italic ? italicFont : regularFont
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    nonisolated(unsafe) private static let regularFont = CTFontCreateUIFontForLanguage(.system, 11, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    nonisolated(unsafe) private static let italicFont = CTFontCreateCopyWithSymbolicTraits(regularFont, 0, nil, .traitItalic, .traitItalic)
        ?? regularFont

    /// Drawn in one Canvas instead of a few views per marker, which kept SwiftUI busy on every scroll.
    var body: some View {
        Canvas { context, size in
            let width = size.width
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            let items = Self.layout(markers: markers, frame: frame, width: width, editingID: editingID)
            // Bars first, so diamonds and circles sit on top of them.
            for item in items where item.kind == .recurring {
                let editing = item.id == editingID
                let thickness: CGFloat = editing ? 3 : 2
                let bar = CGRect(x: item.x, y: Self.barY(row: item.row) - thickness / 2, width: item.barEnd - item.x, height: thickness)
                context.fill(Path(bar), with: .color(editing ? Theme.proposal : color.opacity(0.45)))
            }
            for item in items {
                let center = CGPoint(x: item.x, y: Self.markerY)
                switch item.kind {
                case .recurring:
                    break
                case .oneOff:
                    let editing = item.id == editingID
                    // Being edited: ringed, and faint once the draft moves it to another date.
                    let moved = editing && draftDate != item.date
                    context.fill(Self.diamond(at: center, size: 9), with: .color(color.opacity(moved ? 0.35 : 1)))
                    if editing {
                        context.stroke(Self.diamond(at: center, size: 12), with: .color(Theme.proposal), lineWidth: 1.5)
                    }
                case .generated:
                    context.stroke(Path(ellipseIn: CGRect(x: item.x - 4, y: Self.markerY - 4, width: 8, height: 8)),
                                   with: .color(color), lineWidth: 1.5)
                }
                if let rect = item.labelRect {
                    let font: Font = item.kind == .generated ? .system(size: 11).italic() : .system(size: 11)
                    let label = context.resolve(Text(item.label).font(font)
                        .foregroundStyle(item.kind == .generated ? Theme.secondary : Theme.text))
                    context.draw(label, at: CGPoint(x: rect.minX, y: Self.labelY), anchor: .leading)
                }
            }
            let editedDate = markers.first { $0.id == editingID }?.date
            if let draftDate, frame.contains(draftDate), draftDate != editedDate {
                context.stroke(Self.diamond(at: CGPoint(x: frame.x(draftDate, width: width), y: Self.markerY), size: 10),
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

/// Where the pointer turns into a hand over the strip: one-off events' diamonds, and repeating
/// events' bars and labels. Each says its event in its help, which matters when its label had no room.
struct EventHotspots: View {
    let items: [EventsStrip.Item]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(items.filter { $0.kind != .generated }) { item in
                if item.kind == .oneOff {
                    spot(CGRect(x: item.x - EventsStrip.hitSlop, y: 0, width: EventsStrip.hitSlop * 2,
                                height: TimelineLayout.eventsHeight), help: item.label)
                } else {
                    spot(CGRect(x: item.x, y: EventsStrip.barY(row: item.row) - 3, width: item.barEnd - item.x, height: 6),
                         help: item.label)
                    if let rect = item.labelRect { spot(rect, help: item.label) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func spot(_ rect: CGRect, help: String) -> some View {
        Color.clear
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .contentShape(Rectangle())
            .linkPointer()
            .help(help)
            .offset(x: rect.minX, y: rect.minY)
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
    var scales: ScaleEasing?
    let cursor: CursorSource
    let plotWidth: CGFloat
    var interactions: TimelineInteractions?

    var body: some View {
        HStack(spacing: TimelineLayout.gap) {
            Button {
                if let click = SlotClick.current { interactions?.selectSlot(lane.id, click) }
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
                // Picked out while the slot is drawn over the graph, as a selected file is in Finder.
                .background {
                    if lane.overlaid {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)).padding(-4)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: TimelineLayout.labelWidth)
            .help("Focus \(lane.name). ⌘-click to \(lane.overlaid ? "take it off" : "draw it over") the graph, ⇧-click for a range.")
            .accessibilityLabel("Focus \(lane.name)")
            .accessibilityAddTraits(lane.overlaid ? .isSelected : [])
            .accessibilityAction(named: lane.overlaid ? "Take off the graph" : "Overlay on the graph") {
                interactions?.selectSlot(lane.id, .toggle)
            }

            LanePlot(lane: lane, timeline: timeline, scales: scales)
                .frame(width: plotWidth, height: 36)
                .overlay(alignment: .leading) {
                    if let reason = lane.pausedReason { PausedNote(reason: reason, large: false) }
                }
                .overlay(alignment: .trailing) {
                    if lane.pausedReason == nil, let reason = lane.stoppedReason { PausedNote(reason: reason, large: false, stopped: true) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    // ⌘ and ⇧ choose what the graph shows, as on the lane's name. ⌃ is a right-click.
                    switch SlotClick.current {
                    case .only: interactions?.pickDateOnLane(lane.id, Double(location.x / plotWidth))
                    case let click?: interactions?.selectSlot(lane.id, click)
                    case nil: break
                    }
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

/// A lane's sparkline, on its range part-way through any change of scale. On its own so only it
/// redraws on each frame of a change.
struct LanePlot: View {
    let lane: LaneState
    let timeline: TimelineState
    let scales: ScaleEasing?

    var body: some View {
        PlotCanvas(frame: timeline.frame, domain: lane.easedDomain(by: scales), now: timeline.now,
                   series: [PlotSeries(samples: lane.samples, color: lane.color, lineWidth: 1.6)],
                   rules: [PlotRule(date: timeline.now, color: Theme.nowLine)], modelStart: timeline.start)
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
