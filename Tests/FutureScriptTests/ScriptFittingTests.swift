import Foundation
import Testing
import FutureEngine
@testable import FutureScript

let steadyGrowth = Scripts(lua: """
    every "1 month"
    param("growth", "3%", { range = {"-50%", "100%"}, label = "Growth per month", fit = true })
    param("fee", 0)
    init("value", 0, { fit = false })
    function step(s, t) s.value = s.value * (1 + s.growth) - s.fee end
    """, python: """
    every("1 month")
    param("growth", "3%", range=("-50%", "100%"), label="Growth per month", fit=True)
    param("fee", 0)
    init("value", 0, fit=False)
    def step(s, t):
        s.value = s.value * (1 + s.growth) - s.fee
    """)

/// Fails when growth is below zero, as some scripts do for values they can't take.
let fussyGrowth = Scripts(lua: """
    every "1 month"
    param("growth", "3%", { fit = true })
    init("value", 0)
    function step(s, t)
      if s.growth < 0 then error("growth can't be below zero") end
      s.value = s.value * (1 + s.growth)
    end
    """, python: """
    every("1 month")
    param("growth", "3%", fit=True)
    init("value", 0)
    def step(s, t):
        if s.growth < 0:
            raise ValueError("growth can't be below zero")
        s.value = s.value * (1 + s.growth)
    """)

let noisyGrowth = Scripts(lua: """
    every "1 month"
    param("growth", "0%", { range = {"-10%", "10%"}, fit = true })
    init("value", 100)
    function step(s, t) s.value = s.value * (1 + s.growth + t.normal(0, 0.02)) end
    """, python: """
    every("1 month")
    param("growth", "0%", range=("-10%", "10%"), fit=True)
    init("value", 100)
    def step(s, t):
        s.value = s.value * (1 + s.growth + t.normal(0, 0.02))
    """)

/// `fit`, misses and Refit with Lua and Python scripts (docs/DESIGN.md, 8.4).
@Suite("Fitting scripts to readings")
struct ScriptFittingTests {
    let start = utc(2020, 1, 1)

    func monthly(count: Int, _ value: (Int) -> Double) -> [Reading] {
        (0..<count).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: start)!, variable: "value",
                    value: value(index))
        }
    }

    func slot(_ scripts: Scripts, _ language: ScriptLanguage, values: [String: Double] = [:],
              readings: [Reading]) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot("Data", model: ScriptModel(scripts.source(language), language: language,
                                                                  name: "Data", values: values))
        scenario.setReadings(readings, for: id)
        return (scenario, id)
    }

    @Test("fit marks parameters and starting values as fittable", arguments: languages)
    func fitOption(_ language: ScriptLanguage) throws {
        let model = try ScriptModel(steadyGrowth.source(language), language: language)
        #expect(model.descriptor.variable(named: "growth")?.fittable == true)
        #expect(model.descriptor.variable(named: "growth")?.label == "Growth per month")
        #expect(model.descriptor.variable(named: "fee")?.fittable == false)
        #expect(model.descriptor.variable(named: "value")?.fittable == false)
    }

    @Test("fit is only for parameters and starting values, and must be true or false", arguments: languages)
    func fitMistakes(_ language: ScriptLanguage) throws {
        let onOutput = language == .lua
            ? "every \"1 month\"\noutput(\"x\", { fit = true })\nfunction step(s, t) end"
            : "every(\"1 month\")\noutput(\"x\", fit=True)\ndef step(s, t):\n    pass"
        #expect { try ScriptModel(onOutput, language: language) } throws: { error in
            (error as? ScriptError)?.message.contains("no option called \"fit\"") == true
        }
        let notBoolean = language == .lua
            ? "every \"1 month\"\nparam(\"a\", 1, { fit = \"yes\" })\nfunction step(s, t) end"
            : "every(\"1 month\")\nparam(\"a\", 1, fit=\"yes\")\ndef step(s, t):\n    pass"
        #expect { try ScriptModel(notBoolean, language: language) } throws: { error in
            (error as? ScriptError)?.message.contains("fit should be") == true
        }
    }

    @Test("Script steps report what they predicted before a reading replaced it", arguments: languages)
    func misses(_ language: ScriptLanguage) throws {
        let (scenario, id) = try slot(steadyGrowth, language, readings: [
            Reading(time: start, variable: "value", value: 1000),
            Reading(time: utc(2020, 3, 1), variable: "value", value: 1100),
        ])
        scenario.recordsMisses = true
        let misses = try scenario.misses(in: id, through: utc(2021, 1, 1))
        #expect(misses.count == 1)
        #expect(misses[0].time == utc(2020, 3, 1))
        #expect(abs(misses[0].predicted - 1000 * 1.03 * 1.03) < 1e-9)
        #expect(misses[0].reading == 1100)
    }

    @Test("Refit finds the growth that readings grew by", arguments: languages)
    func steady(_ language: ScriptLanguage) throws {
        let (scenario, id) = try slot(steadyGrowth, language, readings: monthly(count: 49) { 1000 * pow(1.01, Double($0)) })
        let copy = try scenario.copyForFitting(id)
        #expect(copy.markedValues == ["growth"])
        #expect(copy.fittableValues == ["growth", "fee"])
        let outcome = try copy.fit(FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.01) < 1e-7)
        #expect(outcome.improved)
        #expect(outcome.after[0].count == 48)
        #expect(outcome.after[0].typical < 1e-7)
    }

    @Test("Two values at once", arguments: languages)
    func twoValues(_ language: ScriptLanguage) throws {
        var level = 1000.0
        let readings = monthly(count: 37) { index in
            if index > 0 { level = level * 1.02 - 15 }
            return level
        }
        let (scenario, id) = try slot(steadyGrowth, language, readings: readings)
        let outcome = try scenario.refit(id, FitSettings(values: ["growth", "fee"]))
        #expect(abs(outcome.values["growth"]! - 0.02) < 1e-6)
        #expect(abs(outcome.values["fee"]! - 15) < 1e-3)
    }

    @Test("Seeded randomness comes back the same in each try", arguments: languages)
    func seeded(_ language: ScriptLanguage) throws {
        let truth = Scenario(start: start)
        let made = try truth.addSlot("Data", model: ScriptModel(noisyGrowth.source(language), language: language,
                                                                 name: "Data", values: ["growth": 0.007]))
        let samples = try truth.series("value", of: made, from: start, through: utc(2025, 1, 1))
        let (scenario, id) = try slot(noisyGrowth, language,
                                      readings: samples.map { Reading(time: $0.time, variable: "value", value: $0.value) })
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.007) < 1e-6)
    }

    @Test("A try the script fails on counts as worse; failing at the slot's own values is an error", arguments: languages)
    func failures(_ language: ScriptLanguage) throws {
        let readings = monthly(count: 25) { 1000 * pow(1.001, Double($0)) }
        let (scenario, id) = try slot(fussyGrowth, language, readings: readings)
        let outcome = try scenario.refit(id, FitSettings(values: ["growth"]))
        #expect(abs(outcome.values["growth"]! - 0.001) < 1e-7)

        let (failing, failingID) = try slot(fussyGrowth, language, values: ["growth": -0.01], readings: readings)
        #expect(throws: ScriptError.self) { try failing.refit(failingID, FitSettings(values: ["growth"])) }
    }

    @Test("A fit from readings before the start keeps t.days counting from the scenario's start", arguments: languages)
    func fromFirstReading(_ language: ScriptLanguage) throws {
        let line = Scripts(lua: """
            every "1 month"
            param("level", 0, { fit = true })
            param("perYear", 0, { fit = true })
            output("value")
            function step(s, t) s.value = s.level + s.perYear * t.days / 365.2425 end
            """, python: """
            every("1 month")
            param("level", 0, fit=True)
            param("perYear", 0, fit=True)
            output("value")
            def step(s, t):
                s.value = s.level + s.perYear * t.days / 365.2425
            """)
        // From 2012, eight years before the start, rising 0.5 a year through 5 at the start.
        let readings = (0..<120).map { index in
            Reading(time: Calendar.utcGregorian.date(byAdding: .month, value: index, to: utc(2012, 1, 1))!,
                    variable: "value", value: 5 + 0.5 * Double(index - 96) / 12)
        }
        // The readings are all above zero, so the line starts above zero to be compared with them.
        let (scenario, id) = try slot(line, language, values: ["level": 3], readings: readings)
        let outcome = try scenario.refit(id, FitSettings(values: ["level", "perYear"]))
        #expect(outcome.after.first?.count == 119)
        #expect(abs(outcome.values["level"]! - 5) < 0.01)
        #expect(abs(outcome.values["perYear"]! - 0.5) < 0.01)
    }
}
