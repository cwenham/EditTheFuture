import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Drift: the latest readings checked against the range the model projected for them
/// (docs/DESIGN.md, 8.2).
@Suite("Drift")
struct DriftTests {
    let start = utc(2022, 1, 1)

    let steadyGrowth = """
        step 1 month
        timeunit year
        param growth = 3% range -50%..100% fit
        init value = 0
        value[t] = value[t-1] * (1 + growth) ^ dt
        """

    let trendLine = """
        step 1 month
        param level = 14 fit
        param perYear = 0.02
        value[t] = level + perYear * (year - 2000) as temperature
        """

    /// Noise between -1 and 1 that's the same every run.
    func noise(_ index: Int) -> Double {
        let x = sin(Double(index) * 12.9898) * 43_758.5453
        return 2 * (x - x.rounded(.down)) - 1
    }

    /// One reading a month from `first`, with its index and how many years it is after `first`.
    func monthly(from first: Date, count: Int, _ value: (Int, Double) -> Double) -> [Reading] {
        (0..<count).map { index in
            let time = Calendar.utcGregorian.date(byAdding: .month, value: index, to: first)!
            return Reading(time: time, variable: "value", value: value(index, Double(index) / 12))
        }
    }

    func copy(_ source: String, readings: [Reading]) throws -> SlotCopy {
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot("Data", model: FormulaModel(source, name: "Data"))
        scenario.setReadings(readings, for: id)
        return try scenario.copyForFitting(id)
    }

    @Test("Readings that follow the model, with some noise, don't drift")
    func noDrift() throws {
        let readings = monthly(from: utc(2000, 1, 1), count: 300) { index, years in
            1000 * pow(1.03, years) * (1 + 0.01 * noise(index))
        }
        let outcome = try #require(try copy(steadyGrowth, readings: readings).drift("value"))
        #expect(!outcome.isDrifting)
        #expect(outcome.isRatio)
        #expect(outcome.checked == 12)
        #expect(outcome.earlier == SlotCopy.driftEarlierLimit)
        // The band surrounds the projection, and widens further ahead.
        let widths = outcome.band.map { $0.high / $0.low }
        #expect(widths.first == 1)
        #expect(widths.last! >= widths[1])
        #expect(outcome.band.allSatisfy { $0.low <= $0.high })
        #expect(outcome.line.first?.time == outcome.cutoff)
    }

    @Test("Readings that jump above the model's projection in the last year drift, and say how far")
    func driftsAbove() throws {
        let readings = monthly(from: utc(2000, 1, 1), count: 300) { index, years in
            let jump = index >= 292 ? 1.15 : 1
            return 1000 * pow(1.03, years) * (1 + 0.01 * noise(index)) * jump
        }
        let outcome = try #require(try copy(steadyGrowth, readings: readings).drift("value"))
        #expect(outcome.isDrifting)
        #expect(outcome.offset > 0.12 && outcome.offset < 0.18)
        #expect(outcome.outside >= 8)
        #expect(outcome.lastReading == readings.last!.time)
        #expect(outcome.lastValue == readings.last!.value)
        #expect(abs(outcome.projected * (1 + outcome.offset) - outcome.lastValue) < 1e-6 * outcome.lastValue)
    }

    @Test("A temperature's drift is a difference, below the projection")
    func driftsBelowInUnits() throws {
        let readings = monthly(from: utc(1990, 1, 1), count: 420) { index, years in
            let drop = index >= 414 ? -2.0 : 0
            return 14 + 0.02 * (years - 10) + 0.3 * noise(index) + drop
        }
        let outcome = try #require(try copy(trendLine, readings: readings).drift("value"))
        #expect(!outcome.isRatio)
        #expect(outcome.isDrifting)
        #expect(outcome.offset < -1.5 && outcome.offset > -2.6)
    }

    @Test("A single odd reading at the end isn't drift")
    func oneOddReading() throws {
        let readings = monthly(from: utc(2000, 1, 1), count: 300) { index, years in
            let jump = index == 299 ? 1.2 : 1
            return 1000 * pow(1.03, years) * (1 + 0.01 * noise(index)) * jump
        }
        let outcome = try #require(try copy(steadyGrowth, readings: readings).drift("value"))
        #expect(outcome.outside >= 1)
        #expect(!outcome.isDrifting)
    }

    @Test("Short series check their last fifth, and too little history can't tell")
    func shortSeries() throws {
        // Two years of monthly readings: the last fifth is about five months.
        let short = monthly(from: utc(2020, 1, 1), count: 25) { index, years in
            1000 * pow(1.03, years) * (index >= 20 ? 1.3 : 1)
        }
        let outcome = try #require(try copy(steadyGrowth, readings: short).drift("value"))
        #expect(outcome.checked >= 3 && outcome.checked <= 6)
        #expect(outcome.isDrifting)

        let tooFew = monthly(from: utc(2020, 1, 1), count: 4) { _, years in 1000 * pow(1.03, years) }
        #expect(try copy(steadyGrowth, readings: tooFew).drift("value") == nil)
    }

    @Test("Yearly readings check their last three")
    func yearly() throws {
        let readings = (0..<30).map { index in
            Reading(time: utc(1995 + index, 1, 1), variable: "value",
                    value: 1000 * pow(1.03, Double(index)) * (index >= 27 ? 1.25 : 1) * (1 + 0.005 * noise(index)))
        }
        let outcome = try #require(try copy(steadyGrowth, readings: readings).drift("value"))
        #expect(outcome.checked == 3)
        #expect(outcome.isDrifting)
    }
}
