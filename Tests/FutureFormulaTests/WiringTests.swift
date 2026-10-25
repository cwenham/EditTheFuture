import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Which slots can run, checked before a scenario is built (docs/UI.md, 5.7).
@Suite("Slot wiring")
struct WiringTests {
    func check(_ slots: [(String, String?)]) throws -> Wiring.Report {
        try Wiring.check(slots.map { name, formula in (name, try formula.map { try FormulaModel($0, name: name).descriptor }) })
    }

    let climate = "step 1 month\ntemp[t] = 10 + month\nwhen temp > 20 emit Heatwave"
    let bill = "step 1 month\nbill[t] = 70 + Climate.temp"

    @Test("Slots that read each other properly all run, and their links are counted")
    func allRun() throws {
        let report = try check([("Climate", climate), ("Bill", bill), ("Fans", "on Climate.Heatwave: x = 1\ninit x = 0\nx[t] = x[t-1]")])
        #expect(report.problems.isEmpty)
        #expect(report.linkCount == 2)
    }

    @Test("A missing slot, value or event pauses the reader, and whatever reads it")
    func missing() throws {
        var report = try check([("Bill", bill), ("Budget", "step 1 month\nleft[t] = 1000 - Bill.bill")])
        #expect(report.problems[0] == .missingSlot("Climate", reading: "Climate.temp"))
        #expect(report.problems[0]?.description == "Reads Climate.temp, but there's no slot called Climate.")
        #expect(report.problems[1] == .waitsFor("Bill"))
        #expect(report.linkCount == 0)

        report = try check([("Climate", climate), ("Bill", "bill[t] = Climate.rain")])
        #expect(report.problems[1] == .missingValue(slot: "Climate", variable: "rain"))

        report = try check([("Climate", climate), ("Fans", "on Climate.Frost: x = 1\ninit x = 0\nx[t] = x[t-1]")])
        #expect(report.problems[1] == .missingEvents(slot: "Climate", kind: "Frost"))
        #expect(report.problems[0] == nil)
    }

    @Test("A slot whose model failed pauses the slots that read it")
    func brokenModel() throws {
        let report = try check([("Climate", nil), ("Bill", bill)])
        #expect(report.problems[0] == nil)  // the caller knows why it failed
        #expect(report.problems[1] == .waitsFor("Climate"))
    }

    @Test("Slots that read each other in the same step pause; a [t-1] link lets them run")
    func loops() throws {
        var report = try check([("A", "a[t] = B.b + 1"), ("B", "b[t] = A.a * 2"), ("C", "c[t] = A.a")])
        #expect(report.problems[0] == .loop(["A", "B", "A"]))
        #expect(report.problems[1] == .loop(["A", "B", "A"]))
        #expect(report.problems[2] == .waitsFor("A"))

        report = try check([("A", "a[t] = B.b[t-1] + 1"), ("B", "b[t] = A.a * 2")])
        #expect(report.problems.isEmpty)
        #expect(report.linkCount == 2)
    }

    @Test("Swapping one slot's model recomputes it and what reads it, and leaves the rest")
    func replaceKeepsOthers() throws {
        let scenario = Scenario(start: utc(2026, 1, 1))
        let a = try scenario.addSlot("A", model: try FormulaModel("init x = 0\nx[t] = x[t-1] + 1"))
        let b = try scenario.addSlot("B", model: try FormulaModel("y[t] = A.x * 2"))
        let c = try scenario.addSlot("C", model: try FormulaModel("init z = 0\nz[t] = z[t-1] + 5"))
        try scenario.ensureAll(through: utc(2030, 1, 1))
        let kept = try #require(scenario.computedThrough(c))

        try scenario.replaceModel(of: a, with: try FormulaModel("init x = 100\nx[t] = x[t-1] + 1"))
        #expect(scenario.computedThrough(a) == nil)
        #expect(scenario.computedThrough(b) == nil)
        #expect(scenario.computedThrough(c) == kept)
        #expect(try scenario.value("y", of: b, at: utc(2026, 1, 1)) == 200)
    }
}
