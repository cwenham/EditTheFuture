import Foundation
import Testing
@testable import FutureEngine

@Suite("Fast paths")
struct FastPathTests {
    /// A grid that uses `Calendar` for everything, to compare against the `CivilDate` fast path.
    func calendarPoint(_ start: Date, _ rate: StepRate, _ index: Int) -> Date {
        let step = rate.calendarStep
        return Calendar.utcGregorian.date(byAdding: step.component, value: step.count * index, to: start)!
    }

    @Test("Grid points from civil arithmetic match Calendar exactly", arguments: [
        StepRate.monthly, .months(3), .quarters(1), .yearly, .years(4), .daily, .weeks(2), .hours(6), .minutes(15), .seconds(90),
    ])
    func gridMatchesCalendar(rate: StepRate) {
        for start in [utc(2025, 1, 31), utc(2024, 2, 29), utc(1999, 12, 31), utc(2026, 10, 25)] {
            let grid = TimeGrid(start: start.addingTimeInterval(3_723), rate: rate)
            for index in [0, 1, 2, 3, 11, 12, 13, 59, 600, 2_399] {
                #expect(grid.point(index) == calendarPoint(grid.start, rate, index), "\(rate) from \(start) at \(index)")
            }
        }
    }

    @Test("Civil dates match Calendar components across centuries")
    func civilDates() {
        var date = utc(1899, 12, 25)
        let end = utc(2101, 1, 5)
        while date < end {
            let civil = CivilDate(date)
            let parts = Calendar.utcGregorian.dateComponents([.year, .month, .day], from: date)
            #expect(civil.year == parts.year && civil.month == parts.month && civil.day == parts.day)
            #expect(civil.dayOfYear == Calendar.utcGregorian.ordinality(of: .day, in: .year, for: date))
            date = date.addingTimeInterval(86_400 * 7 + 3_600 * 5)
        }
    }

    @Test("Computing groups in parallel gives the same results as one at a time")
    func parallelMatchesSequential() throws {
        func make() throws -> (Scenario, [SlotID]) {
            let scenario = Scenario(start: utc(2026, 1, 1))
            var ids: [SlotID] = []
            ids.append(try scenario.addSlot("Walk", model: RandomWalk()))
            ids.append(try scenario.addSlot("Counter", model: CounterModel()))
            ids.append(try scenario.addSlot("Weather", model: DailyTemperature()))
            ids.append(try scenario.addSlot("Monthly", model: Observer(source: Reference(slot: "Weather", variable: "temp", resampling: .mean),
                                                                        subscription: EventSubscription(slot: "Weather", kind: "Hot"))))
            return (scenario, ids)
        }
        let horizon = utc(2060, 1, 1)
        let (sequential, ids) = try make()
        for id in ids { try sequential.ensure(id, through: horizon) }
        let (parallel, _) = try make()
        try parallel.ensureAll(through: horizon)
        for (id, variable) in zip(ids, ["x", "count", "temp", "seen"]) {
            #expect(try parallel.series(variable, of: id, from: utc(2026, 1, 1), through: horizon)
                    == sequential.series(variable, of: id, from: utc(2026, 1, 1), through: horizon))
        }
        #expect(try parallel.value("hotEvents", of: ids[3], at: horizon) == sequential.value("hotEvents", of: ids[3], at: horizon))
    }

    @Test("Linked slots form one group; unlinked slots form their own")
    func grouping() {
        let groups = Scenario.groups(slotCount: 5, links: [(SlotID(rawValue: 3), SlotID(rawValue: 4)), (SlotID(rawValue: 1), SlotID(rawValue: 3))])
        #expect(groups.map { $0.map(\.rawValue) } == [[0], [1, 3, 4], [2]])
    }
}
