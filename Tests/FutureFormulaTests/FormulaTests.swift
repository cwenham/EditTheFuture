import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.utcGregorian.date(from: components)!
}

let savingsSource = """
    # A savings account
    step 1 month
    param rate = 6%
    param deposit = 200
    init balance = 1000
    balance[t] = balance[t-1] * (1 + rate / 12) + deposit
    on bonus: balance += event.amount
    """

@Suite("Formula language")
struct FormulaTests {
    let start = utc(2026, 1, 1)

    // MARK: Parsing and validation

    @Test("Syntax errors report their line")
    func syntaxErrorLine() {
        #expect(throws: FormulaError.syntax(line: 2, message: "Expected a value, found the end of the line.")) {
            try FormulaModel("step 1 month\nparam rate = \ninit x = 1")
        }
    }

    @Test("Unknown names are caught before running")
    func unknownName() {
        #expect(throws: FormulaError.unknownName("y", line: 1)) { try FormulaModel("x[t] = y + 1") }
        #expect(throws: FormulaError.unknownFunction("frobnicate", line: 1)) { try FormulaModel("x[t] = frobnicate(2)") }
        #expect(throws: FormulaError.wrongArgumentCount(function: "clamp", expected: "3 arguments", line: 1)) {
            try FormulaModel("x[t] = clamp(1, 2)")
        }
    }

    @Test("A same-step loop inside a model is an error")
    func loopInsideModel() {
        #expect(throws: FormulaError.sameStepLoop(["a", "b", "a"])) { try FormulaModel("a[t] = b + 1\nb[t] = a * 2") }
        #expect(throws: FormulaError.sameStepLoop(["balance", "balance"])) { try FormulaModel("init balance = 1\nbalance[t] = balance * 2") }
    }

    @Test("Reserved words can't be used as names")
    func reservedNames() {
        #expect(throws: FormulaError.reservedName("year", line: 1)) { try FormulaModel("param year = 2") }
        #expect(throws: FormulaError.reservedName("max", line: 1)) { try FormulaModel("max[t] = 2") }
    }

    @Test("The descriptor lists parameters, outputs, inputs and subscriptions")
    func descriptor() throws {
        let model = try FormulaModel("""
            step 1 day
            param base = 10
            demand[t] = base + Climate.temp.mean + Market.price[t-1]
            when demand > 100 emit Spike
            on Building.OverCapacity[t-1]: base = 0
            """)
        let descriptor = model.descriptor
        #expect(descriptor.stepRate == .days(1))
        #expect(descriptor.variable(named: "base")?.causality == .parameter)
        #expect(descriptor.variable(named: "demand")?.causality == .output)
        #expect(descriptor.inputs.map(\.name) == ["Climate.temp.mean", "Market.price[t-1]"])
        #expect(descriptor.inputs.first?.source == Reference(slot: "Climate", variable: "temp", resampling: .mean))
        #expect(descriptor.emits == ["Spike"])
        #expect(descriptor.subscriptions == [EventSubscription(slot: "Building", kind: "OverCapacity", timing: .previousStep)])
    }

    // MARK: Calculations

    @Test("Monthly compounding with deposits matches the closed form")
    func savingsClosedForm() throws {
        let scenario = Scenario(start: start)
        let savings = try scenario.addSlot("Savings", model: FormulaModel(savingsSource))
        let i = 0.06 / 12, n = 120.0
        let growth = pow(1 + i, n)
        let expected = 1000 * growth + 200 * (growth - 1) / i
        let balance = try scenario.value("balance", of: savings, at: utc(2036, 1, 1))
        #expect(abs(balance - expected) < 1e-6)
    }

    @Test("A set event changes a parameter from that step on")
    func setEvent() throws {
        let scenario = Scenario(start: start)
        let savings = try scenario.addSlot("Savings", model: FormulaModel(savingsSource))
        scenario.add(Event.set(["rate": 0], at: utc(2027, 1, 15)), to: savings)
        let february = try scenario.value("balance", of: savings, at: utc(2027, 2, 1))
        let march = try scenario.value("balance", of: savings, at: utc(2027, 3, 1))
        #expect(abs((march - february) - 200) < 1e-9)
        #expect(try scenario.value("rate", of: savings, at: utc(2027, 3, 1)) == 0)
        #expect(try scenario.value("rate", of: savings, at: utc(2026, 12, 1)) == 0.06)
    }

    @Test("Handlers apply event values after the step's definitions")
    func handler() throws {
        let plain = Scenario(start: start)
        let plainSlot = try plain.addSlot("Savings", model: FormulaModel(savingsSource))

        let withBonus = Scenario(start: start)
        let bonusSlot = try withBonus.addSlot("Savings", model: FormulaModel(savingsSource))
        withBonus.add(Event(time: utc(2026, 3, 10), kind: "bonus", values: ["amount": 500]), to: bonusSlot)

        func difference(_ date: Date) throws -> Double {
            try withBonus.value("balance", of: bonusSlot, at: date) - plain.value("balance", of: plainSlot, at: date)
        }
        #expect(try difference(utc(2026, 3, 1)) == 0)
        #expect(abs(try difference(utc(2026, 4, 1)) - 500) < 1e-9)
        #expect(abs(try difference(utc(2026, 5, 1)) - 500 * 1.005) < 1e-9)
    }

    @Test("Recurring events drive handlers")
    func recurringHandler() throws {
        let source = """
            param rate = 6%
            init balance = 1000
            balance[t] = balance[t-1] * (1 + rate / 12)
            on deposit: balance += event.amount
            """
        let byRule = Scenario(start: start)
        let ruleSlot = try byRule.addSlot("Savings", model: FormulaModel(source))
        byRule.add(RecurringEvent(kind: "deposit", values: ["amount": 200], first: utc(2026, 2, 1), every: .monthly), to: ruleSlot)

        let byParameter = Scenario(start: start)
        let parameterSlot = try byParameter.addSlot("Savings", model: FormulaModel(savingsSource))

        let date = utc(2030, 1, 1)
        let a = try byRule.value("balance", of: ruleSlot, at: date)
        let b = try byParameter.value("balance", of: parameterSlot, at: date)
        #expect(abs(a - b) < 1e-6)
    }

    @Test("Differential equations match the analytic logistic curve")
    func logisticGrowth() throws {
        let scenario = Scenario(start: start)
        let yeast = try scenario.addSlot("Yeast", model: FormulaModel("""
            step 1 day
            param r = 0.3
            param K = 1000
            init P = 10
            dP/dt = r * P * (1 - P / K)
            """))
        let days = 30.0
        let analytic = 1000 / (1 + ((1000 - 10) / 10) * exp(-0.3 * days))
        let simulated = try scenario.value("P", of: yeast, at: utc(2026, 1, 31))
        #expect(abs(simulated - analytic) / analytic < 1e-6)
    }

    @Test("Built-ins and percent literals")
    func builtins() throws {
        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Clock", model: FormulaModel("""
            step 1 day
            m[t] = month
            d[t] = dayOfYear
            p[t] = 25% + if(step > 2, 1, 0)
            """))
        let date = utc(2026, 3, 1)
        #expect(try scenario.value("m", of: slot, at: date) == 3)
        #expect(try scenario.value("d", of: slot, at: date) == 60)
        #expect(try scenario.value("p", of: slot, at: date) == 1.25)
        #expect(try scenario.value("p", of: slot, at: utc(2026, 1, 2)) == 0.25)
    }

    // MARK: Linked models

    static let climateSource = """
        step 1 day
        param warming = 0
        temp[t] = 12 + 10 * sin(2 * pi * (dayOfYear - 105) / 365) + warming
        """

    static let iceCreamSource = """
        step 1 month
        param base = 1000
        param price = 3
        demand[t] = base * max(0, 1 + 0.04 * (Climate.temp.mean - 18))
        revenue[t] = demand * price
        """

    @Test("Climate drives ice cream sales, and editing the climate only changes the future")
    func climateAndIceCream() throws {
        let scenario = Scenario(start: start)
        let climate = try scenario.addSlot("Climate", model: FormulaModel(Self.climateSource))
        let iceCream = try scenario.addSlot("IceCream", model: FormulaModel(Self.iceCreamSource))

        let january = try scenario.value("revenue", of: iceCream, at: utc(2026, 2, 1))
        let july = try scenario.value("revenue", of: iceCream, at: utc(2026, 8, 1))
        #expect(july > january * 3)

        let december2029 = try scenario.value("demand", of: iceCream, at: utc(2029, 12, 1))
        let february2030 = try scenario.value("demand", of: iceCream, at: utc(2030, 2, 1))

        scenario.add(Event.set(["warming": 3], at: utc(2030, 1, 1)), to: climate)
        #expect(try scenario.value("demand", of: iceCream, at: utc(2029, 12, 1)) == december2029)
        let warmer = try scenario.value("demand", of: iceCream, at: utc(2030, 2, 1))
        #expect(abs((warmer - february2030) - 1000 * 0.04 * 3) < 1e-9)
    }

    static let buildingSource = """
        step 1 month
        param capacity = 500
        param fireCodeLimit = 450
        init occupancy = 300
        occupancy[t] = min(capacity, occupancy[t-1] * 1.03)
        on FireRisk.OverCapacity[t-1]: occupancy = fireCodeLimit * 0.9
        """

    static let fireRiskSource = """
        step 1 month
        param baseline = 0.01
        risk[t] = baseline * (Building.occupancy / Building.capacity) ^ 1.5
        when Building.occupancy > Building.fireCodeLimit emit OverCapacity
        """

    @Test("Occupancy and fire risk form a feedback loop through the previous step")
    func buildingAndFireRisk() throws {
        let scenario = Scenario(start: start)
        let building = try scenario.addSlot("Building", model: FormulaModel(Self.buildingSource))
        let fireRisk = try scenario.addSlot("FireRisk", model: FormulaModel(Self.fireRiskSource))
        try scenario.validate()

        let end = utc(2036, 1, 1)
        let occupancy = try scenario.series("occupancy", of: building, from: start, through: end)
        let alarms = try scenario.generatedEvents(in: fireRisk, through: end)
        #expect(alarms.count >= 2)
        #expect(alarms.allSatisfy { $0.kind == "OverCapacity" && $0.originSlot == "FireRisk" })
        #expect(occupancy.map(\.value).max()! < 450 * 1.03 + 1)

        // The step after each alarm, occupancy is cut back to 90% of the limit.
        let grid = TimeGrid(start: start, rate: .monthly)
        for alarm in alarms {
            let next = grid.point(grid.firstIndex(atOrAfter: alarm.time) + 1)
            #expect(abs(try scenario.value("occupancy", of: building, at: next) - 405) < 1e-9)
        }
        #expect(try scenario.value("risk", of: fireRisk, at: end) > 0)
    }

    @Test("Closing the same loop within one step is rejected")
    func buildingLoopWithoutLag() throws {
        let scenario = Scenario(start: start)
        try scenario.addSlot("Building", model: FormulaModel(Self.buildingSource.replacingOccurrences(of: "[t-1]:", with: ":")))
        try scenario.addSlot("FireRisk", model: FormulaModel(Self.fireRiskSource))
        #expect(throws: EngineError.sameStepLoop(["Building", "FireRisk", "Building"])) { try scenario.validate() }
    }

    @Test("Random results don't depend on which slot is computed first")
    func orderIndependence() throws {
        let noisyClimate = Self.climateSource + "\nnoisy[t] = temp + normal(0, 2)"
        let noisyIceCream = Self.iceCreamSource.replacingOccurrences(of: "Climate.temp.mean", with: "Climate.noisy.mean")
        let date = utc(2028, 6, 1)

        let first = Scenario(start: start)
        let iceCreamFirst = try first.addSlot("IceCream", model: FormulaModel(noisyIceCream))
        try first.addSlot("Climate", model: FormulaModel(noisyClimate))
        let a = try first.series("demand", of: iceCreamFirst, from: start, through: date)

        let second = Scenario(start: start)
        let climateSecond = try second.addSlot("Climate", model: FormulaModel(noisyClimate))
        let iceCreamSecond = try second.addSlot("IceCream", model: FormulaModel(noisyIceCream))
        _ = try second.value("noisy", of: climateSecond, at: date)
        let b = try second.series("demand", of: iceCreamSecond, from: start, through: date)

        #expect(a == b)
        #expect(a.count == 30)
    }

    // MARK: Drag the future

    @Test("Goal seek finds the monthly deposit that reaches a target")
    func goalSeekDeposit() throws {
        let scenario = Scenario(start: start)
        let savings = try scenario.addSlot("Savings", model: FormulaModel(savingsSource.replacingOccurrences(of: "deposit = 200", with: "deposit = 0")))
        let target = 100_000.0
        let result = try scenario.goalSeek("balance", of: savings, at: utc(2036, 1, 1), target: target, within: 0...5_000) { amount in
            Event.set(["deposit": amount], at: utc(2026, 1, 15))
        }
        let i = 0.06 / 12, growth = pow(1 + i, 120)
        let expected = (target - 1000 * growth) * i / (growth - 1)
        #expect(abs(result.input - expected) < 1e-4)
        #expect(abs(result.achieved - target) < 1e-3)
        #expect(result.event.values["deposit"] == result.input)
        #expect(scenario.events(in: savings).isEmpty)
    }

    @Test("Goal seek explains when the target is out of reach")
    func goalSeekOutOfRange() throws {
        let scenario = Scenario(start: start)
        let savings = try scenario.addSlot("Savings", model: FormulaModel(savingsSource))
        #expect(throws: EngineError.self) {
            try scenario.goalSeek("balance", of: savings, at: utc(2027, 1, 1), target: 1e9, within: 0...10) { amount in
                Event.set(["deposit": amount], at: utc(2026, 1, 15))
            }
        }
    }
}
