import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// `fit`, misses and Refit with formulas (docs/DESIGN.md, 8.4).
@Suite("Fitting formulas to readings")
struct FittingTests {
    let start = utc(2020, 1, 1)

    let steadyGrowth = """
        step 1 month
        param growth = 3% range -50%..100% label "Growth per month" fit
        init value = 0
        value[t] = value[t-1] * (1 + growth)
        """

    /// One reading a month from `first`, on the slot's points.
    func monthly(_ variable: String = "value", from first: Date? = nil, count: Int, _ value: (Int) -> Double) -> [Reading] {
        (0..<count).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: first ?? start)!,
                    variable: variable, value: value(index))
        }
    }

    func slot(_ source: String, readings: [Reading], name: String = "Data") throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot(name, model: FormulaModel(source, name: name))
        scenario.setReadings(readings, for: id)
        return (scenario, id)
    }

    // MARK: fit

    @Test("fit marks params and inits as fittable, and nothing else")
    func fitOption() throws {
        let model = try FormulaModel("""
            step 1 month
            param growth = 3% range 0%..10% fit
            param fee = 5 label "Fee" fit
            param other = 1
            init level = 100 fit
            level[t] = level[t-1] * (1 + growth) - fee + other
            """)
        let descriptor = model.descriptor
        #expect(descriptor.variable(named: "growth")?.fittable == true)
        #expect(descriptor.variable(named: "growth")?.maximum == 0.1)
        #expect(descriptor.variable(named: "fee")?.fittable == true)
        #expect(descriptor.variable(named: "fee")?.label == "Fee")
        #expect(descriptor.variable(named: "other")?.fittable == false)
        #expect(descriptor.variable(named: "level")?.fittable == true)
    }

    @Test("fit on a definition, or twice, is a mistake")
    func fitOnlyOnDeclarations() {
        #expect(throws: FormulaError.self) { try FormulaModel("step 1 month\ninit x = 1\ny[t] = x * 2 fit") }
        #expect(throws: FormulaError.self) { try FormulaModel("step 1 month\ninit x = 1\ndx/dt = x fit") }
        #expect(throws: FormulaError.self) { try FormulaModel("step 1 month\nparam a = 1 fit fit") }
        // A value named fit still works.
        #expect(throws: Never.self) { try FormulaModel("step 1 month\nparam fit = 2\ninit x = fit") }
    }

    @Test("fit is coloured as an option on params and inits, and as a name elsewhere")
    func fitHighlighting() {
        func kind(of word: String, in source: String) -> FormulaTokenKind? {
            FormulaHighlighter.tokens(in: source).last { $0.text == word }?.kind
        }
        #expect(kind(of: "fit", in: "param growth = 3% range 0%..10% fit") == .keyword)
        #expect(kind(of: "fit", in: "init level = 100 fit # comment") == .keyword)
        #expect(kind(of: "fit", in: "param a = 1 fit label \"A\"") == .keyword)
        #expect(kind(of: "fit", in: "param a = 1 + fit") == .name)
        #expect(kind(of: "fit", in: "y[t] = fit") == .name)
    }

    // MARK: Misses

    @Test("A scenario that keeps misses records what each step predicted before a reading replaced it")
    func misses() throws {
        let (scenario, id) = try slot(steadyGrowth, readings: [
            Reading(time: start, variable: "value", value: 1000),
            Reading(time: utc(2020, 3, 1), variable: "value", value: 1100),
            Reading(time: utc(2020, 5, 10), variable: "value", value: 1200),
            Reading(time: utc(2020, 5, 20), variable: "value", value: 1250),
        ])
        #expect(try scenario.misses(in: id, through: utc(2021, 1, 1)).isEmpty)  // off unless asked for

        scenario.recordsMisses = true
        scenario.invalidate(id, from: start)
        let misses = try scenario.misses(in: id, through: utc(2021, 1, 1))
        #expect(misses.count == 2)
        #expect(misses[0].time == utc(2020, 3, 1))
        #expect(abs(misses[0].predicted - 1000 * 1.03 * 1.03) < 1e-9)
        #expect(misses[0].reading == 1100)
        // Two readings in one step: one miss, against the latest.
        #expect(misses[1].time == utc(2020, 6, 1))
        #expect(abs(misses[1].predicted - 1100 * pow(1.03, 3)) < 1e-9)
        #expect(misses[1].reading == 1250)

        // Misses after a change go with the results they came from.
        scenario.add(Event.set(["growth": 0.05], at: utc(2020, 4, 15)), to: id)
        let changed = try scenario.misses(in: id, through: utc(2021, 1, 1))
        #expect(changed[0] == misses[0])
        #expect(abs(changed[1].predicted - 1100 * 1.03 * 1.05 * 1.05) < 1e-9)
    }

    // MARK: Refit

    @Test("Refit finds the growth that readings grew by")
    func steady() throws {
        let (scenario, id) = try slot(steadyGrowth, readings: monthly(count: 49) { 1000 * pow(1.01, Double($0)) })
        let before = try scenario.series("value", of: id, from: start, through: utc(2030, 1, 1))

        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.01) < 1e-7)
        #expect(outcome.improved)
        let own = try #require(outcome.before?.first)
        #expect(own.variable == "value" && own.isRatio && own.count == 48)
        #expect(abs(own.typical - (1.03 / 1.01 - 1)) < 1e-9)
        #expect(outcome.after[0].typical < 1e-7)
        #expect(outcome.runs > 2)

        // The scenario is as it was.
        #expect(try scenario.series("value", of: id, from: start, through: utc(2030, 1, 1)) == before)
        #expect(try scenario.value("growth", of: id, at: start) == 0.03)
    }

    @Test("A value's first reading after the start isn't a miss: there was nothing observed before it")
    func firstReading() throws {
        let later = utc(2021, 1, 1)
        let (scenario, id) = try slot(steadyGrowth, readings: monthly(from: later, count: 25) { 500 * pow(1.02, Double($0)) })
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.02) < 1e-7)
        #expect(outcome.after[0].count == 24)
    }

    @Test("Noisy readings give the growth they average")
    func noisy() throws {
        let wobble = [1.004, 0.997, 0.999, 1.002, 0.998]
        let (scenario, id) = try slot(steadyGrowth, readings: monthly(count: 121) { 1000 * pow(1.01, Double($0)) * wobble[$0 % 5] })
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.01) < 5e-4)
        #expect(outcome.after[0].typical > 0)
        #expect(outcome.after[0].typical < outcome.before![0].typical)
    }

    @Test("Two values at once: an S-curve's rate and capacity, from a differential equation")
    func logistic() throws {
        let source = """
            step 1 month
            timeunit year
            param r = 0.5 range 0..3 fit
            param capacity = 10000 range 1..1000000 fit
            init population = 100
            dpopulation/dt = r * population * (1 - population / capacity)
            """
        let truth = Scenario(start: start)
        let made = try truth.addSlot("Yeast", model: FormulaModel(source, name: "Yeast", values: ["r": 0.8, "capacity": 5000]))
        let samples = try truth.series("population", of: made, from: start, through: utc(2030, 1, 1))
        let readings = samples.map { Reading(time: $0.time, variable: "population", value: $0.value) }

        let (scenario, id) = try slot(source, readings: readings, name: "Yeast")
        let copy = try scenario.copyForFitting(id)
        #expect(copy.markedValues == ["r", "capacity"])
        let outcome = try copy.fit(FitSettings(values: copy.markedValues))
        #expect(abs(outcome.values["r"]! - 0.8) < 1e-4)
        #expect(abs(outcome.values["capacity"]! / 5000 - 1) < 1e-4)
    }

    @Test("A range limits the fit")
    func range() throws {
        let source = steadyGrowth.replacingOccurrences(of: "3% range -50%..100%", with: "1% range 0%..2%")
        let (scenario, id) = try slot(source, readings: monthly(count: 25) { 1000 * pow(1.05, Double($0)) })
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(outcome.values["growth"] == 0.02)
        #expect(outcome.improved)
    }

    @Test("Only misses since a date count, for a series that changed")
    func since() throws {
        let readings = monthly(count: 49) { index in
            index <= 24 ? 1000 * pow(1.01, Double(index)) : 1000 * pow(1.01, 24) * pow(1.02, Double(index - 24))
        }
        let (scenario, id) = try slot(steadyGrowth, readings: readings)
        let recent = try scenario.refit(id, FitSettings(values: ["growth"], since: utc(2022, 2, 1)))
        #expect(abs(recent.values["growth"]! - 0.02) < 1e-7)
        #expect(recent.after[0].count == 24)
        let all = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(all.values["growth"]! > 0.014 && all.values["growth"]! < 0.016)
    }

    @Test("Readings that cross zero are measured as differences")
    func differences() throws {
        let source = """
            step 1 month
            param perMonth = 0 fit
            init level = 0
            level[t] = level[t-1] + perMonth
            """
        let (scenario, id) = try slot(source, readings: monthly("level", count: 25) { -6 + 0.5 * Double($0) })
        let outcome = try scenario.refit(id, FitSettings(values: ["perMonth"]))
        #expect(abs(outcome.values["perMonth"]! - 0.5) < 1e-7)
        #expect(outcome.before?[0].isRatio == false)
        #expect(abs(outcome.before![0].typical - 0.5) < 1e-9)
    }

    @Test("Stochastic models are fitted on their seeded run, so the same random numbers come back")
    func seeded() throws {
        let source = """
            step 1 month
            param growth = 0% range -10%..10% fit
            init value = 100
            value[t] = value[t-1] * (1 + growth + normal(0, 0.02))
            """
        let truth = Scenario(start: start)
        let made = try truth.addSlot("Market", model: FormulaModel(source, name: "Market", values: ["growth": 0.007]))
        let samples = try truth.series("value", of: made, from: start, through: utc(2025, 1, 1))
        let (scenario, id) = try slot(source, readings: samples.map { Reading(time: $0.time, variable: "value", value: $0.value) },
                                      name: "Market")
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.007) < 1e-6)
    }

    @Test("A slot that reads another slot, and hears its events, is fitted with what that slot computed")
    func upstream() throws {
        let climate = """
            step 1 month
            temp[t] = 12 + 6 * sin(2 * pi * (month - 4) / 12)
            when temp > 17 emit Warm
            """
        let bill = """
            step 1 month
            param rate = 1 fit
            param extra = 0 fit
            bill[t] = rate * Climate.temp
            on Climate.Warm: bill += extra
            """
        let truth = Scenario(start: start)
        try truth.addSlot("Climate", model: FormulaModel(climate, name: "Climate"))
        let made = try truth.addSlot("Bill", model: FormulaModel(bill, name: "Bill", values: ["rate": 2.5, "extra": 7]))
        let samples = try truth.series("bill", of: made, from: start, through: utc(2026, 1, 1))

        let scenario = Scenario(start: start)
        let climateID = try scenario.addSlot("Climate", model: FormulaModel(climate, name: "Climate"))
        let id = try scenario.addSlot("Bill", model: FormulaModel(bill, name: "Bill"))
        scenario.setReadings(samples.map { Reading(time: $0.time, variable: "bill", value: $0.value) }, for: id)
        let temps = try scenario.series("temp", of: climateID, from: start, through: utc(2026, 1, 1))

        let outcome = try scenario.refit(id, FitSettings(values: ["rate", "extra"]))
        #expect(abs(outcome.values["rate"]! - 2.5) < 1e-6)
        #expect(abs(outcome.values["extra"]! - 7) < 1e-4)
        #expect(try scenario.series("temp", of: climateID, from: start, through: utc(2026, 1, 1)) == temps)
    }

    @Test("Values with readings of their own can't be fitted, and the rest are offered")
    func offered() throws {
        let source = """
            step 1 month
            param rate = 5% fit
            param deposit = 100
            param fee = 2 fit
            init balance = 1000 fit
            balance[t] = balance[t-1] * (1 + rate / 12) + deposit - fee
            """
        let (scenario, id) = try slot(source, readings: monthly("balance", count: 12) { 1000 + 100 * Double($0) }
                                        + [Reading(time: utc(2020, 6, 1), variable: "fee", value: 3)])
        let copy = try scenario.copyForFitting(id)
        #expect(copy.markedValues == ["rate"])
        #expect(copy.fittableValues == ["rate", "deposit"])
        #expect(throws: FitError.setByReadings(name: "fee")) { try copy.fit(FitSettings(values: ["fee"])) }
        #expect(throws: FitError.setByReadings(name: "balance")) { try copy.fit(FitSettings(values: ["balance"])) }
        #expect(throws: FitError.unknownValue(slot: "Data", name: "nope")) { try copy.fit(FitSettings(values: ["nope"])) }
        #expect(throws: FitError.nothingToFit) { try copy.fit(FitSettings(values: [])) }
        let outcome = try copy.fit(FitSettings(values: ["deposit"]))
        #expect(outcome.improved)
    }

    @Test("Refit says why when there's nothing to fit to")
    func tooFew() throws {
        let (none, noneID) = try slot(steadyGrowth, readings: [])
        #expect(throws: FitError.noReadings(slot: "Data")) { try none.copyForFitting(noneID) }

        let (scenario, id) = try slot(steadyGrowth, readings: monthly(count: 2) { 100 + Double($0) })
        #expect(throws: FitError.tooFewReadings(slot: "Data", have: 1, need: 2)) {
            try scenario.refit(id, FitSettings(values: ["growth"]))
        }
    }

    @Test("A model that can't work out comparable values at any setting says so")
    func incomparable() throws {
        let source = """
            step 1 month
            param k = 1 fit
            init value = 1
            value[t] = -1 - abs(k * value[t-1])
            """
        let (scenario, id) = try slot(source, readings: monthly(count: 12) { 100 + Double($0) })
        #expect(throws: FitError.cantCompare(slot: "Data")) { try scenario.refit(id, FitSettings(values: ["k"])) }
    }

    @Test("Values that already fit best stay, and say so")
    func alreadyBest() throws {
        let (scenario, id) = try slot(steadyGrowth, readings: monthly(count: 13) { 1000 * pow(1.03, Double($0)) })
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(!outcome.improved)
        #expect(outcome.values["growth"] == 0.03)
        #expect(outcome.before == outcome.after)
    }

    @Test("A fit can be cancelled")
    func cancelling() throws {
        let (scenario, id) = try slot(steadyGrowth, readings: monthly(count: 49) { 1000 * pow(1.01, Double($0)) })
        let copy = try scenario.copyForFitting(id)
        #expect(throws: CancellationError.self) { try copy.fit(FitSettings(values: ["growth"]), isCancelled: { true }) }
    }
}

@Suite("Fitting with exchange rates")
struct ConvertedFittingTests {
    @Test("Refit's copy converts money from another currency as the scenario does")
    func converted() throws {
        let start = CivilDate.date(year: 2024, month: 1, day: 1)
        let scenario = Scenario(start: start)
        try scenario.addSlot("Shop", model: try FormulaModel("""
            step 1 month
            init price = 100 as currency
            price[t] = price[t-1]
            """, name: "Shop"), currency: .usd)
        let id = try scenario.addSlot("Wallet", model: try FormulaModel("""
            step 1 month
            param k = 0.5 range 0..2 fit
            init v = 0 as currency
            v[t] = Shop.price * k
            """, name: "Wallet"), currency: .gbp)
        scenario.setExchangeRates(ExchangeRates(perDollar: [.gbp: [(start, 0.8)]]))
        let grid = TimeGrid(start: start, rate: .months(1), calendar: .utcGregorian)
        scenario.setReadings((1...24).map { Reading(time: grid.point($0), variable: "v", value: 80) }, for: id)
        try scenario.validate()
        #expect(try scenario.value("v", of: id, at: grid.point(30)) == 40)  // 100 dollars × 0.8 × k

        // Without converting in the copy, k would come out as 0.8.
        let outcome = try scenario.refit(id, FitSettings(values: ["k"]))
        #expect(abs(outcome.values["k"]! - 1) < 1e-6)
    }
}
