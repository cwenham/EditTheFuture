import Foundation
import Testing
@testable import FutureUI

/// The time axis and cursor dates at every zoom, from 80 years down to an hour (docs/UI.md, 2.3).
@Suite("Time axis")
struct TimeAxisTests {
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc(year, month, day).addingTimeInterval(Double(hour * 3_600 + minute * 60))
    }

    func ticks(from start: Date, hours: Double) -> [TimeTick] {
        TimelineState.timeTicks(for: TimeFrame(start: start, end: start.addingTimeInterval(hours * 3_600)))
    }

    @Test("Each zoom gets ten marks or fewer, in its own unit, inside the view and in order")
    func everyZoom() {
        let start = at(2026, 3, 14, 9, 47)
        let spans: [Double] = [1, 3, 8, 30, 70, 144, 480, 1_080, 2_400, 9_600, 16_800, 43_800, 700_800]
        for hours in spans {
            let marks = ticks(from: start, hours: hours)
            #expect(marks.count >= 2 && marks.count <= 11, "\(hours) h: \(marks.map(\.label))")
            #expect(marks.allSatisfy { $0.date >= start && $0.date <= start.addingTimeInterval(hours * 3_600) })
            #expect(zip(marks, marks.dropFirst()).allSatisfy { $0.date < $1.date })
        }
    }

    @Test("Marks say what they mark: years, months with the year at January, days, hours, and the day at midnight")
    func labels() {
        #expect(ticks(from: at(2026, 3, 14), hours: 24 * 365 * 5).map(\.label) == ["2027", "2028", "2029", "2030", "2031"])
        let months = ticks(from: at(2026, 10, 20), hours: 24 * 200).map(\.label)
        #expect(months.first == "Nov 2026" && months.contains("Jan 2027") && months.contains("Feb"))
        let days = ticks(from: at(2026, 3, 14, 9), hours: 24 * 6).map(\.label)
        #expect(days == ["15 Mar", "16 Mar", "17 Mar", "18 Mar", "19 Mar", "20 Mar"])
        let hours = ticks(from: at(2026, 3, 14, 20, 10), hours: 8).map(\.label)
        #expect(hours == ["21:00", "22:00", "23:00", "15 Mar", "01:00", "02:00", "03:00", "04:00"])
        #expect(ticks(from: at(2026, 3, 14, 9, 47), hours: 1).map(\.label) == ["09:50", "10:00", "10:10", "10:20", "10:30", "10:40"])
        // Mondays, when the view is a few weeks.
        let weeks = ticks(from: at(2026, 3, 1), hours: 24 * 45)
        #expect(weeks.allSatisfy { Calendar.utcGregorian.component(.weekday, from: $0.date) == 2 })
    }

    @Test("The cursor's date is as precise as the view")
    func cursorDates() {
        let date = at(2026, 3, 14, 9, 5)
        #expect(DateText.precise(date, span: 30 * 365 * 86_400) == "Mar 2026")
        #expect(DateText.precise(date, span: 60 * 86_400) == "14 Mar 2026")
        #expect(DateText.precise(date, span: 6 * 3_600) == "14 Mar 2026, 09:05")
        #expect(DateText.time(at(2026, 1, 1, 23, 59)) == "23:59")
    }

    @MainActor
    @Test("The panel zooms in to an hour, and its readout says the time")
    func zoomsToAnHour() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        store.setCursor(at(2026, 10, 25, 14, 30))
        store.zoom(by: 1e-9)
        #expect(store.frame.span == 3_600)
        #expect(store.cursorState().readoutDate == "25 Oct 2026, 14:30")
        #expect(store.timelineState().timeTicks.count >= 2)
        await store.waitUntilIdle()
        #expect(store.cursorState().readoutValue != "…")
    }
}
