import Foundation
import SwiftUI
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
    public let format: ValueFormat
    public let samples: [Sample]
    /// The line with the event being added, drawn dashed. Empty when nothing is being added.
    public let preview: [Sample]
    /// Where the event being added would go.
    public let draftDate: Date?
    public let yDomain: ClosedRange<Double>
    public let yTicks: [Double]
    public let cursorValue: Double?
    public let readoutDate: String
    public let readoutValue: String
    public let readoutNote: String
    public let events: [EventMarker]
}

public struct LaneState: Identifiable, Sendable {
    public let id: Int
    public let key: Int
    public let name: String
    public let color: Color
    public let samples: [Sample]
    public let yDomain: ClosedRange<Double>
    public let valueText: String
    /// What the slot reads from other slots, e.g. "← Climate.temp".
    public let reads: String?
}

public struct YearTick: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let label: String
}

/// Everything the timeline views draw, computed from the store in one place
/// so the live panel and the clipboard snapshot draw the same thing.
public struct PanelState: Sendable {
    public let scenarioName: String
    public let frame: TimeFrame
    public let now: Date
    public let cursor: Date
    public let focus: FocusedSlotState
    public let lanes: [LaneState]
    public let yearTicks: [YearTick]
    public let status: String
    /// What the add-event pane's draft would change, or nil until the draft is complete.
    public let eventPreview: EventPreviewState?

    public var nowText: String { "Now · " + DateText.monthYear(now) }
}

/// The draft event's effect at the cursor and at the right edge of the view, so scrolling
/// further out shows how the effect plays out.
public struct EventPreviewState: Sendable, Equatable {
    public let cursorDate: String
    public let atCursor: String
    public let edgeDate: String
    public let atEdge: String
}

extension PanelState {
    static func yearTicks(for frame: TimeFrame) -> [YearTick] {
        let years = frame.span / (365.2425 * 86_400)
        let step = years <= 6 ? 1 : years <= 15 ? 2 : years <= 30 ? 5 : 10
        var year = DateText.year(frame.start)
        year = Int((Double(year) / Double(step)).rounded(.up)) * step
        var ticks: [YearTick] = []
        while true {
            let date = DateText.startOfYear(year)
            if date > frame.end { break }
            if date >= frame.start { ticks.append(YearTick(date: date, label: String(year))) }
            year += step
        }
        return ticks
    }
}
