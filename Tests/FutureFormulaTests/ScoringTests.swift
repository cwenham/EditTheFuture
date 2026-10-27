import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Fitting from readings before the scenario's start, and scoring models on readings they didn't
/// see (docs/DESIGN.md, 8.4).
@Suite("Scoring models on held-back readings")
struct ScoringTests {
    let start = utc(2022, 1, 1)

    /// A straight line through the readings, measured from the start of 2000.
    let trendLine = """
        step 1 month
        param level = 0 fit
        param perYear = 0 fit
        value[t] = level + perYear * (year - 2000)
        """

    /// Carries on from the latest reading by the same amount each year.
    let steadyChange = """
        step 1 month
        timeunit year
        param perYear = 0 fit
        init value = 0
        value[t] = value[t-1] + perYear * dt
        """

    let holdTheLatest = """
        step 1 month
        init value = 0
        value[t] = value[t-1]
        """

    let steadyGrowth = """
        step 1 month
        timeunit year
        param growth = 3% range -50%..100% fit
        init value = 0
        value[t] = value[t-1] * (1 + growth) ^ dt
        """

    /// Noise between -1 and 1 that's the same every run.
    func noise(_ index: Int) -> Double {
        let x = sin(Double(index) * 12.9898) * 43_758.5453
        return 2 * (x - x.rounded(.down)) - 1
    }

    /// One reading a month from `first`.
    func monthly(from first: Date, count: Int, _ value: (Int, Double) -> Double) -> [Reading] {
        (0..<count).map { index in
            let time = Calendar.utcGregorian.date(byAdding: .month, value: index, to: first)!
            let year = 1970 + time.timeIntervalSince1970 / (365.2425 * 86_400)
            return Reading(time: time, variable: "value", value: value(index, year))
        }
    }

    func copy(_ source: String, readings: [Reading], start: Date? = nil) throws -> SlotCopy {
        let scenario = Scenario(start: start ?? self.start)
        let id = try scenario.addSlot("Data", model: FormulaModel(source, name: "Data"))
        scenario.setReadings(readings, for: id)
        return try scenario.copyForFitting(id)
    }

    // MARK: Before the start

    @Test("A fit uses readings from before the scenario's start, and days still counts from the start")
    func fitsFromFirstReading() throws {
        // A line through 5 at the scenario's start, rising 0.5 a year, from 2000 to the end of 2024.
        let readings = monthly(from: utc(2000, 1, 1), count: 300) { index, _ in
            5 + 0.5 * Double(index - 264) / 12
        }
        let copy = try copy("""
            step 1 month
            param level = 0 fit
            param perYear = 0 fit
            value[t] = level + perYear * days / 365.2425
            """, readings: readings)
        let outcome = try copy.fit(FitSettings(values: ["level", "perYear"]))
        // Every reading after the first counts, not just the 36 since the start.
        #expect(outcome.after.first?.count == 299)
        #expect(abs(outcome.values["level"]! - 5) < 0.01)
        #expect(abs(outcome.values["perYear"]! - 0.5) < 0.01)
    }

    @Test("Fitting a starting value, or a slot that reads another, runs from the scenario's start")
    func startingValuesFromStart() throws {
        let source = """
            step 1 month
            param growth = 1% range 0%..10% fit
            init offset = 0 fit
            init value = 0
            value[t] = value[t-1] * (1 + growth) + offset
            """
        let readings = monthly(from: utc(2010, 1, 1), count: 180) { index, _ in 100 * pow(1.01, Double(index)) }
        let copy = try copy(source, readings: readings)
        #expect(try copy.fit(FitSettings(values: ["growth"])).after.first?.count == 179)
        // The readings from 2022 on, after the one the start takes.
        #expect(try copy.fit(FitSettings(values: ["growth", "offset"])).after.first?.count == 35)

        let scenario = Scenario(start: start)
        try scenario.addSlot("Source", model: FormulaModel("step 1 month\nx[t] = 1"))
        let id = try scenario.addSlot("Data", model: FormulaModel("""
            step 1 month
            param growth = 1% range 0%..10% fit
            init value = 0
            value[t] = value[t-1] * (1 + growth) * Source.x
            """, name: "Data"))
        scenario.setReadings(readings, for: id)
        #expect(try scenario.refit(id, FitSettings(values: ["growth"])).after.first?.count == 35)
    }

    // MARK: Scoring

    @Test("A noisy series is scored best by a line through its readings")
    func noisyLine() throws {
        // Swings of up to 1 around a line rising 0.03 a year, from 1990 to 2025.
        let readings = monthly(from: utc(1990, 1, 1), count: 432) { index, year in 0.03 * (year - 2000) + noise(index) }
        let data = try copy(holdTheLatest, readings: readings)
        let trend = try data.replacingModel(FormulaModel(trendLine, name: "Data"))
            .score("value", FitSettings(values: ["level", "perYear"]))
        let steady = try data.replacingModel(FormulaModel(steadyChange, name: "Data"))
            .score("value", FitSettings(values: ["perYear"]))
        let hold = try data.score("value", FitSettings(values: []))

        #expect(!trend.miss.isRatio)
        #expect(trend.miss.typical < steady.miss.typical)
        #expect(trend.miss.typical < hold.miss.typical)
        // About what the noise alone gives: an even spread over -1...1 has a root mean square of 0.58.
        #expect(trend.miss.typical < 0.7)
        #expect(abs(trend.values["perYear"]! - 0.03) < 0.01)
        #expect(hold.values.isEmpty)

        // Cut-offs at 60%, 70% and 80% of 1990–2025, each scored on the next fifth: from about 2018 for the last.
        #expect(trend.cutoffs.count == 3)
        #expect(trend.cutoffs[0] >= utc(2011, 1, 1) && trend.cutoffs[0] < utc(2012, 1, 1))
        #expect(trend.cutoff >= utc(2018, 1, 1) && trend.cutoff < utc(2019, 1, 1))
        #expect(trend.miss.count > 3 * 80)
        #expect(trend.line.first?.time == trend.cutoff)
        #expect(trend.line.last!.time >= readings.last!.time)
    }

    @Test("A series that grows by a steady percent is scored as a percent, and steady growth wins")
    func growth() throws {
        let readings = monthly(from: utc(2000, 1, 1), count: 300) { index, _ in
            100 * pow(1.05, Double(index) / 12) * (1 + 0.002 * noise(index))
        }
        let data = try copy(holdTheLatest, readings: readings)
        let growth = try data.replacingModel(FormulaModel(steadyGrowth, name: "Data"))
            .score("value", FitSettings(values: ["growth"]))
        // A line from 0 can't be compared with readings above zero, so it starts from a first guess.
        let trend = try data.replacingModel(FormulaModel(trendLine, name: "Data").replacingValues(["level": 100, "perYear": 5]))
            .score("value", FitSettings(values: ["level", "perYear"]))
        #expect(growth.miss.isRatio)
        #expect(growth.miss.typical < 0.01)
        #expect(growth.miss.typical < trend.miss.typical)
        #expect(abs(growth.values["growth"]! - 0.05) < 0.002)
    }

    @Test("Only the chosen readings are compared, and too few says how many there are")
    func window() throws {
        let readings = monthly(from: utc(1990, 1, 1), count: 432) { index, year in 0.03 * (year - 2000) + noise(index) }
        let data = try copy(trendLine, readings: readings)
        let recent = try data.score("value", FitSettings(values: ["level", "perYear"], since: utc(2015, 1, 1)))
        #expect(recent.cutoffs[0] >= utc(2021, 1, 1))
        #expect(recent.cutoff >= utc(2022, 1, 1))

        #expect(throws: FitError.tooFewToCompare(slot: "Data", have: 10)) {
            try data.score("value", FitSettings(values: [], since: utc(2025, 3, 1)))
        }
    }

    @Test("A projection that goes to zero or below can't be compared with readings above zero")
    func cantCompare() throws {
        let readings = monthly(from: utc(2000, 1, 1), count: 120) { index, _ in 100 + Double(index) }
        let data = try copy(holdTheLatest, readings: readings)
        let falling = try FormulaModel("""
            step 1 month
            init value = 0
            value[t] = value[t-1] - 1000
            """, name: "Data")
        #expect(throws: FitError.cantCompare(slot: "Data")) {
            try data.replacingModel(falling).score("value", FitSettings(values: []))
        }
    }

    @Test("Another model leaves out the connections and events it has no use for")
    func replacingModel() throws {
        let scenario = Scenario(start: utc(2000, 1, 1))
        try scenario.addSlot("Source", model: FormulaModel("step 1 month\nx[t] = 1"))
        let id = try scenario.addSlot("Data", model: FormulaModel("""
            step 1 month
            param growth = 1% range 0%..10% fit
            init value = 0
            value[t] = value[t-1] * (1 + growth) * Source.x
            on deposit: value += event.amount
            """, name: "Data"))
        scenario.setReadings(monthly(from: utc(2000, 1, 1), count: 120) { index, _ in 100 * pow(1.01, Double(index)) }, for: id)
        scenario.add(Event(time: utc(2003, 1, 15), kind: "deposit", values: ["amount": 50]), to: id)
        let data = try scenario.copyForFitting(id)
        let growth = try data.replacingModel(FormulaModel(steadyGrowth, name: "Data"))
            .score("value", FitSettings(values: ["growth"]))
        #expect(growth.miss.typical < 0.01)
    }
}
