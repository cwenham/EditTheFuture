import Foundation
import Testing
@testable import FutureEngine

@Suite("Time grids and events")
struct TimeAndEventTests {
    @Test("Monthly points are computed from the start, so month ends don't drift")
    func monthEndClamping() {
        let grid = TimeGrid(start: utc(2025, 1, 31), rate: .monthly)
        #expect(grid.point(1) == utc(2025, 2, 28))
        #expect(grid.point(2) == utc(2025, 3, 31))
        #expect(grid.point(13) == utc(2026, 2, 28))
    }

    @Test("Finding points around a date")
    func pointLookup() {
        let grid = TimeGrid(start: utc(2025, 1, 31), rate: .monthly)
        #expect(grid.lastIndex(atOrBefore: utc(2025, 3, 15)) == 1)
        #expect(grid.lastIndex(atOrBefore: utc(2025, 3, 31)) == 2)
        #expect(grid.lastIndex(atOrBefore: utc(2024, 12, 1)) == nil)
        #expect(grid.firstIndex(atOrAfter: utc(2025, 3, 15)) == 2)
        #expect(grid.firstIndex(atOrAfter: utc(2025, 3, 31)) == 2)

        let daily = TimeGrid(start: utc(2026, 1, 1), rate: .daily)
        #expect(daily.lastIndex(atOrBefore: utc(2036, 1, 1)) == 3652)
    }

    @Test("Step windows exclude their start, except the first step")
    func stepWindows() {
        let grid = TimeGrid(start: utc(2026, 1, 1), rate: .monthly)
        let first = StepWindow.forStep(1, on: grid)
        #expect(first.contains(utc(2026, 1, 1)))
        #expect(first.contains(utc(2026, 2, 1)))
        let second = StepWindow.forStep(2, on: grid)
        #expect(!second.contains(utc(2026, 2, 1)))
        #expect(second.contains(utc(2026, 3, 1)))
    }

    @Test("Recurring events produce stable occurrences inside a window")
    func recurringOccurrences() {
        let rule = RecurringEvent(kind: "deposit", values: ["amount": 50], first: utc(2026, 1, 1), every: .monthly, count: 3)
        let window = StepWindow(lower: utc(2025, 12, 1), upper: utc(2026, 12, 31), includesLower: false)
        let occurrences = rule.occurrences(in: window)
        #expect(occurrences.map(\.time) == [utc(2026, 1, 1), utc(2026, 2, 1), utc(2026, 3, 1)])
        #expect(occurrences.allSatisfy { $0.values["amount"] == 50 })
        #expect(rule.occurrences(in: window).map(\.id) == occurrences.map(\.id))
        #expect(Set(occurrences.map(\.id)).count == 3)

        let narrow = StepWindow(lower: utc(2026, 1, 1), upper: utc(2026, 2, 1), includesLower: false)
        #expect(rule.occurrences(in: narrow).map(\.time) == [utc(2026, 2, 1)])
    }

    @Test("Seeded randomness is reproducible per stream")
    func seededRandom() {
        var a = SeededRandom(seed: 42, stream: 7)
        var b = SeededRandom(seed: 42, stream: 7)
        var c = SeededRandom(seed: 42, stream: 8)
        let first = (0..<5).map { _ in a.uniform() }
        #expect(first == (0..<5).map { _ in b.uniform() })
        #expect(first != (0..<5).map { _ in c.uniform() })
        #expect(first.allSatisfy { $0 >= 0 && $0 < 1 })
    }
}
