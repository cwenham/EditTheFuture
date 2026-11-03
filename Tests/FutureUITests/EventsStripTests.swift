import Foundation
import Testing
import FutureEngine
import FutureTestSupport
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Events strip")
struct EventsStripTests {
    @Test("A click lands on the nearest diamond within a few points, or a repeating event's bar or label, never a generated event")
    func hitTesting() {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind, end: Date? = nil) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: end, label: "", kind: kind)
        }
        let first = marker(utc(2028, 8), .oneOff), second = marker(utc(2028, 9), .oneOff)
        let rule = marker(utc(2030, 1), .recurring, end: utc(2033, 1)), generated = marker(utc(2032, 1), .generated)
        let early = marker(utc(2020, 1), .oneOff)
        let items = EventsStrip.layout(markers: [early, first, second, rule, generated], frame: frame, width: width) { _, _ in 40 }
        func hit(_ date: Date, nudge: CGFloat = 0, y: CGFloat = EventsStrip.markerY) -> UUID? {
            EventsStrip.editableEvent(at: CGPoint(x: frame.x(date, width: width) + nudge, y: y), in: items)
        }
        #expect(hit(utc(2028, 8)) == first.id)
        #expect(hit(utc(2028, 8), nudge: -7) == first.id)
        #expect(hit(utc(2028, 9), nudge: 2) == second.id)
        #expect(hit(utc(2028, 8), nudge: -9) == nil)
        // A repeating event's bar, anywhere along it, but not above or past it.
        #expect(hit(utc(2031, 6), y: EventsStrip.barY(row: 0)) == rule.id)
        #expect(hit(utc(2031, 6), y: EventsStrip.labelY) == nil)
        #expect(hit(utc(2034, 1), y: EventsStrip.barY(row: 0)) == nil)
        #expect(hit(utc(2032, 1)) == nil)
        #expect(hit(frame.start) == nil)
        // Only events in view are laid out.
        #expect(items.map(\.id) == [first.id, second.id, rule.id, generated.id])
    }

    @Test("Labels never overlap: the edited event's goes first, then one-off, repeating and generated ones")
    func labelsDontOverlap() throws {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind, _ label: String, end: Date? = nil) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: end, label: label, kind: kind)
        }
        // A year is 100 points; each label is 80.
        let peak = marker(utc(2028, 1), .generated, "Peak"), herd = marker(utc(2028, 2), .generated, "HerdImmunity")
        let set = marker(utc(2028, 6), .oneOff, "R₀ → 1.1"), later = marker(utc(2031, 1), .oneOff, "R₀ → 2.5")
        let first = marker(utc(2027, 1), .recurring, "Vaccinate 6,000 every week")
        let second = marker(utc(2027, 3), .recurring, "Vaccinate 250 every week")
        let markers = [first, second, peak, herd, set, later]
        let items = EventsStrip.layout(markers: markers, frame: frame, width: width) { _, _ in 80 }
        let rects = items.compactMap(\.labelRect)
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) { #expect(!a.insetBy(dx: -EventsStrip.labelGap / 2 + 0.01, dy: 0).intersects(b)) }
            #expect(a.minX >= 0 && a.maxX <= width)
        }
        func shown(_ marker: EventMarker) -> Bool { items.first { $0.id == marker.id }?.labelRect != nil }
        #expect(shown(set) && shown(later) && shown(first))
        #expect(!shown(second) && !shown(peak) && !shown(herd))
        // Overlapping repeating events get rows of their own.
        #expect(items.first { $0.id == first.id }?.row == 0)
        #expect(items.first { $0.id == second.id }?.row == 1)

        // The event being edited wins its place over a one-off event's.
        let editing = EventsStrip.layout(markers: markers, frame: frame, width: width, editingID: second.id) { _, _ in 80 }
        #expect(editing.first { $0.id == second.id }?.labelRect != nil)
        #expect(editing.first { $0.id == first.id }?.labelRect == nil)

        // Labels are measured in the strip's font.
        #expect(EventsStrip.labelWidth("HerdImmunity", italic: true) > EventsStrip.labelWidth("Peak", italic: true))
        #expect(EventsStrip.labelWidth("Peak", italic: false) > 15)
    }

    @Test func eventLinesAreForAddedEventsOnly() {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        func marker(_ date: Date, _ kind: EventMarker.Kind) -> EventMarker {
            EventMarker(id: UUID(), date: date, endDate: nil, label: "", kind: kind)
        }
        let oneOff = marker(utc(2028, 8), .oneOff), rule = marker(utc(2030, 1), .recurring)
        let generated = marker(utc(2032, 1), .generated), early = marker(utc(2020, 1), .oneOff)
        let dates = FocusChart.eventLineDates([early, oneOff, rule, generated])
        #expect(dates == [early.date, oneOff.date, rule.date])
        // Only the ones in view get a line.
        #expect(PlotEventLines.xs(dates: dates, frame: frame, width: width)
                == [frame.x(oneOff.date, width: width), frame.x(rule.date, width: width)])
        // A day apart over ten years is well under 4 points: one line, not two.
        let nextDay = oneOff.date.addingTimeInterval(86_400)
        #expect(PlotEventLines.xs(dates: [nextDay, oneOff.date], frame: frame, width: width).count == 1)
    }
}
