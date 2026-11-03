import Foundation
import FutureDocument
import FutureEngine
import FutureKit

// What the tests of FutureKit, FutureFiles and FutureUI share.

/// A date at midnight UTC.
public func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

extension ScenarioDefinition {
    /// Slots that outgrow every number: ×10 a month (overflows to infinity in 2047), ×−3 a month,
    /// one that turns into NaN once it overflows, and one that starts near the largest Double.
    public static let runaway = ScenarioDefinition(
        name: "Runaway",
        start: utc(2022, 1),
        slots: [
            SlotSpec(name: "Rocket", formula: """
                step 1 month
                param growth = 10
                init balance = 1000
                balance[t] = balance[t-1] * growth
                on deposit: balance += event.amount
                """, variable: "balance", format: .currency),
            SlotSpec(name: "Sinker", formula: """
                step 1 month
                init n = -1
                n[t] = n[t-1] * 3
                """, variable: "n", format: .number),
            SlotSpec(name: "Furnace", formula: """
                step 1 month
                init temp = 1
                temp[t] = temp[t-1] * 100 - temp[t-1] * 90
                """, variable: "temp", format: .temperature),
            // Every value it ever shows is beyond the ±1e300 plots are clamped to.
            SlotSpec(name: "Giant", formula: """
                step 1 month
                init size = 1e301
                size[t] = size[t-1] * 1.001
                """, variable: "size", format: .currency),
        ])
}

/// A scenario that starts in 2020, with a slot whose readings go back to 2000: the view reaching back
/// before the start, where there are only readings (docs/UI.md, 2.4 and 5.1).
public struct HistoryScenario: Sendable {
    public let now = utc(2026, 10, 25)
    public let start = utc(2020, 1, 1)
    public let firstReading = utc(2000, 1, 1)

    public static let growth = """
        step 1 month
        param growth = 0.5%
        init value = 1000
        value[t] = value[t-1] * (1 + growth)
        """

    /// Monthly readings from 2000 through 2024: 1000 plus the month's number.
    public func readings(from first: Date) -> SlotReadings {
        let list = (0..<300).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: first)!, variable: "value",
                    value: 1000 + Double(index))
        }
        return SlotReadings(sources: [.inline(csv: "")], parts: [ReadingSet(list)])
    }

    @MainActor
    public func makeStore(readingsFrom first: Date? = nil) async throws -> ScenarioStore {
        let definition = ScenarioDefinition(name: "History", start: start, slots: [
            SlotSpec(name: "Data", formula: Self.growth, variable: "value", format: .number,
                     readings: readings(from: first ?? firstReading)),
            SlotSpec(name: "Plain", formula: Self.growth, variable: "value", format: .number),
        ])
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    public init() {}
}
