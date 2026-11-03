import Foundation
import SwiftUI
import FutureVisuals
import FutureEngine

/// The visible slice of time.
public struct TimeFrame: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var span: TimeInterval { end.timeIntervalSince(start) }

    /// Horizontal position of `date` in a plot `width` points wide.
    public func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / span) * width
    }

    public func date(atFraction fraction: Double) -> Date {
        start.addingTimeInterval(span * fraction)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

public struct EventMarker: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case oneOff, recurring, generated }
    public let id: UUID
    public let date: Date
    /// End of a recurring rule's bar (the frame's end when open-ended).
    public let endDate: Date?
    public let label: String
    public let kind: Kind
}

public struct FocusedSlotState: Sendable {
    public let index: Int
    public let name: String
    public let summary: String
    public let color: Color
    /// How its values are written, in its currency when they're money.
    public let style: ValueStyle
    public let samples: [Sample]
    /// Readings of the value the graph shows, drawn as dots on a thin line (docs/UI.md, 2.4).
    public let readings: [Sample]
    /// The line with the add-event pane's draft applied, drawn dashed. Empty until the draft is complete.
    public let preview: [Sample]
    /// Predict with's held-back test for the selected model: its projection from the cut-off over
    /// the readings it didn't see, drawn dotted (docs/UI.md, 2.4).
    public let heldBack: [Sample]
    public let cutoff: Date?
    /// Where the draft event would go.
    public let draftDate: Date?
    public var yDomain: ClosedRange<Double>
    public let yTicks: [Double]
    public let events: [EventMarker]
    /// The one-off event the add-event pane is editing, drawn picked out (docs/UI.md, 5.4).
    public let editingEventID: UUID?
    /// Why the slot can't run, shown in place of its line.
    public let pausedReason: String?
    /// The error that stopped the slot partway, such as a script's.
    public let stoppedReason: String?
    /// The slot's drift, while its latest readings are outside the range its model projected.
    public var drift: DriftMark? = nil
    /// Drag the future's target, while one is set on this slot (docs/UI.md, 5.2).
    public var goal: GoalMark? = nil
}

/// A drift on the focused graph (docs/UI.md, 5.6): the projection from before the latest
/// readings, the range it allowed, and the pill by the now line.
public struct DriftMark: Sendable {
    /// "12% above the projection".
    public let text: String
    /// What the pill's help and VoiceOver say.
    public let detail: String
    public let line: [Sample]
    public let band: [DriftOutcome.BandPoint]
    public let cutoff: Date
}

public struct LaneState: Identifiable, Sendable {
    public let id: Int
    public let key: Int
    public let name: String
    public let color: Color
    public let samples: [Sample]
    public var yDomain: ClosedRange<Double>
    /// What the slot reads from other slots, e.g. "← Climate.temp".
    public let reads: String?
    /// Why the slot can't run, shown in place of its sparkline.
    public let pausedReason: String?
    /// The error that stopped the slot partway, such as a script's.
    public let stoppedReason: String?
    /// What the slot's drift alert says, while it's drifting.
    public var drift: String? = nil
    /// Whether the slot is drawn over the focused graph too (docs/UI.md, 5.12).
    public var overlaid = false
    /// How its values are written; a change of kind changes its scale at once rather than easing.
    public var style = ValueStyle.number
}

/// Another slot drawn over the focused graph in its own colour (docs/UI.md, 5.12).
public struct OverlayState: Identifiable, Sendable {
    /// The slot's index.
    public let id: Int
    public let key: Int
    public let name: String
    public let color: Color
    public let style: ValueStyle
    public let samples: [Sample]
    /// The range the line is drawn over: the focused graph's when they share an axis, else its own.
    public var yDomain: ClosedRange<Double>
    /// Whether its values are a different kind from the focused slot's (or money in another
    /// currency), so it's drawn on its own scale, not against the axis.
    public let ownScale: Bool
}

/// A mark on the time axis: a year, month, day, hour or minute, depending on the zoom (docs/UI.md, 2.5).
public struct TimeTick: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let label: String
}

/// Everything the timeline draws that doesn't depend on the cursor. Views that use only this
/// aren't redrawn when the pointer moves.
public struct TimelineState: Sendable {
    public let scenarioName: String
    public let frame: TimeFrame
    public let now: Date
    /// The scenario's start, where the models' lines begin. Before it the graph shows only
    /// readings, shaded, with a dashed line at the start (docs/UI.md, 2.4).
    public let start: Date
    public var focus: FocusedSlotState
    public var lanes: [LaneState]
    public let timeTicks: [TimeTick]
    /// Other slots drawn over the focused graph, in the order they were added.
    public var overlays: [OverlayState] = []

    public var nowText: String { "Now · " + DateText.monthYear(now) }
    public var startText: String { "Start · " + DateText.monthYear(start) }
    /// Whether the view reaches back before the start, so the start is marked.
    public var showsStart: Bool { frame.start < start && start <= frame.end }
}

/// Everything that follows the cursor: the readout, each lane's value and the dot on the line.
public struct CursorState: Sendable, Equatable {
    public let date: Date
    public let readoutDate: String
    public let readoutValue: String
    public let readoutNote: String
    /// The focused slot's value at the cursor, for the dot on its line.
    public let focusValue: Double?
    /// Each lane's value at the cursor, by slot index.
    public let laneValues: [Int: String]
    /// Each overlaid slot's value at the cursor, by slot index, for the dots on their lines.
    public var overlayValues: [Int: Double] = [:]
}

/// A complete picture of the panel, used for clipboard snapshots and tests.
public struct PanelState: Sendable {
    public let timeline: TimelineState
    public let cursor: CursorState
    public let status: String
    /// What the add-event pane's draft would change, or nil until the draft is complete.
    public let eventPreview: EventPreviewState?
    /// What's drawn behind the focused graph, or nil for nothing (docs/DESIGN.md, 9.6).
    public var backdrop: BackdropState? = nil

    public var scenarioName: String { timeline.scenarioName }
    public var frame: TimeFrame { timeline.frame }
    public var now: Date { timeline.now }
    public var focus: FocusedSlotState { timeline.focus }
    public var lanes: [LaneState] { timeline.lanes }
    public var nowText: String { timeline.nowText }
}

/// The draft event's effect at the cursor and at the right edge of the view, so scrolling
/// further out shows how the effect plays out.
public struct EventPreviewState: Sendable, Equatable {
    public let cursorDate: String
    public let atCursor: String
    public let edgeDate: String
    public let atEdge: String
}

extension TimelineState {
    /// Marks for the time axis, about ten at most: years over years, then months, days, hours and
    /// minutes as the view narrows (docs/UI.md, 2.5).
    static func timeTicks(for frame: TimeFrame) -> [TimeTick] {
        let span = frame.span, day = 86_400.0
        if span > 730 * day { return yearTicks(for: frame) }
        if span > 60 * day { return monthTicks(for: frame) }
        if span > 4 * day { return dayTicks(for: frame) }
        return clockTicks(for: frame)
    }

    static func yearTicks(for frame: TimeFrame) -> [TimeTick] {
        let years = frame.span / (365.2425 * 86_400)
        let step = years <= 6 ? 1 : years <= 15 ? 2 : years <= 30 ? 5 : 10
        var year = DateText.year(frame.start)
        year = Int((Double(year) / Double(step)).rounded(.up)) * step
        var ticks: [TimeTick] = []
        while true {
            let date = DateText.startOfYear(year)
            if date > frame.end { break }
            if date >= frame.start { ticks.append(TimeTick(date: date, label: String(year))) }
            year += step
        }
        return ticks
    }

    /// Every 1, 2, 3 or 6 months from January. January says its year, as does the first mark.
    static func monthTicks(for frame: TimeFrame) -> [TimeTick] {
        let months = frame.span / (30.44 * 86_400)
        let step = [1, 2, 3, 6].first { months / Double($0) <= 10 } ?? 6
        let first = CivilDate(frame.start)
        var year = first.year, month = first.month
        var ticks: [TimeTick] = []
        while true {
            let date = CivilDate.date(year: year, month: month, day: 1)
            if date > frame.end { break }
            if date >= frame.start, (month - 1) % step == 0 {
                let label = month == 1 || ticks.isEmpty ? DateText.monthYear(date) : DateText.monthNames[month - 1]
                ticks.append(TimeTick(date: date, label: label))
            }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return ticks
    }

    /// Every day, every other day, or each Monday: "15 Mar".
    static func dayTicks(for frame: TimeFrame) -> [TimeTick] {
        let days = frame.span / 86_400
        let step = [1, 2, 7].first { days / Double($0) <= 10 } ?? 7
        let first = CivilDate(frame.start)
        var date = CivilDate.date(year: first.year, month: first.month, day: first.day)
        if date < frame.start { date = date.addingTimeInterval(86_400) }
        var ticks: [TimeTick] = []
        while date <= frame.end {
            // Days since 1 Jan 1970, a Thursday: Mondays are 4 days on, in sevens.
            let dayNumber = Int((date.timeIntervalSince1970 / 86_400).rounded())
            let wanted = step == 7 ? (dayNumber - 4) % 7 == 0 : dayNumber % step == 0
            if wanted { ticks.append(TimeTick(date: date, label: DateText.dayMonth(date))) }
            date = date.addingTimeInterval(86_400)
        }
        return ticks
    }

    /// Hours or minutes, from midnight: "09:00", and "15 Mar" at midnight.
    static func clockTicks(for frame: TimeFrame) -> [TimeTick] {
        let minutes = [5.0, 10, 15, 30, 60, 120, 180, 360, 720]
        let step = (minutes.first { frame.span / ($0 * 60) <= 10 } ?? 720) * 60
        let first = CivilDate(frame.start)
        let midnight = CivilDate.date(year: first.year, month: first.month, day: first.day)
        var date = midnight.addingTimeInterval((frame.start.timeIntervalSince(midnight) / step).rounded(.up) * step)
        var ticks: [TimeTick] = []
        while date <= frame.end {
            let atMidnight = CivilDate(date).secondsIntoDay < 1
            ticks.append(TimeTick(date: date, label: atMidnight ? DateText.dayMonth(date) : DateText.time(date)))
            date = date.addingTimeInterval(step)
        }
        return ticks
    }
}

/// What's drawn behind the focused graph (docs/DESIGN.md, 9.6): which backdrop, and what it shows.
public struct BackdropState: Sendable, Equatable {
    public let id: String
    public let input: BackdropInput
}
