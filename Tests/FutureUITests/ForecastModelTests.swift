import Foundation
import Testing
import FutureEngine
import FutureFormula
@testable import FutureUI

/// The Forecast models (docs/DESIGN.md, 8.4): written around any value, fitted from a first guess.
@Suite("Forecast models")
struct ForecastModelTests {
    let monthlyValue = ForecastModels.Value(name: "value", label: "Value", format: .number, step: .months(1))

    /// Noise between -1 and 1 that's the same every run.
    static func noise(_ index: Int) -> Double {
        let x = sin(Double(index) * 12.9898) * 43_758.5453
        return 2 * (x - x.rounded(.down)) - 1
    }

    /// Monthly readings of `variable` from `first`, with each one's fractional year.
    static func monthly(_ variable: String = "value", from first: Date, count: Int,
                        _ value: (Int, Double) -> Double) -> [Reading] {
        (0..<count).map { index in
            let time = Calendar.utcGregorian.date(byAdding: .month, value: index, to: first)!
            return Reading(time: time, variable: variable, value: value(index, ForecastModels.fractionalYear(time)))
        }
    }

    /// Scores a Forecast model on a slot holding the readings, fitted from its first guess.
    static func score(_ kind: ForecastModels.Kind, value: ForecastModels.Value, readings: [Reading],
                      start: Date = utc(2020, 1, 1)) throws -> ScoreOutcome {
        let scenario = Scenario(start: start)
        let template = ForecastModels.template(.holdTheLatest, for: value)
        let id = try scenario.addSlot("Data", model: FormulaModel(template.formula, name: "Data"))
        scenario.setReadings(readings, for: id)
        let copy = try scenario.copyForFitting(id)
        let model = try FormulaModel(ForecastModels.template(kind, for: value).formula, name: "Data",
                                     values: ForecastModels.guess(kind, readings: readings))
        let candidate = copy.replacingModel(model)
        return try candidate.score(value.name, FitSettings(values: candidate.markedValues))
    }

    @Test("Every Forecast model reads, for any value, format and step, and marks what it fits")
    func formulas() throws {
        let fitted: [ForecastModels.Kind: [String]] = [
            .holdTheLatest: [], .steadyChange: ["perYear"], .steadyGrowth: ["growth"], .recentChange: ["smoothing"],
            .recentGrowth: ["smoothing"], .trendLine: ["level", "perYear"], .sCurve: ["rate", "capacity"],
            .seasonal: ["level", "perYear", "swing", "peak"],
        ]
        for value in [monthlyValue,
                      ForecastModels.Value(name: "temp", label: "Europe \"land\"", format: .temperature, step: .weeks(1)),
                      ForecastModels.Value(name: "debt", label: "Debt", format: .currency, step: .days(1))] {
            for kind in ForecastModels.Kind.allCases {
                let template = ForecastModels.template(kind, for: value)
                let model = try FormulaModel(template.formula, name: "Data")
                #expect(model.descriptor.stepRate == value.step)
                #expect(model.descriptor.variable(named: value.name)?.causality == .output)
                let marked = model.descriptor.variables.filter(\.fittable).map(\.name)
                #expect(marked == fitted[kind], "\(kind)")
            }
        }
        #expect(ModelLibrary.all.filter { $0.category == .forecast }.count == ForecastModels.Kind.allCases.count)
        #expect(ForecastModels.template(.holdTheLatest, for: monthlyValue).formula
                == ScenarioStore.dataSeriesFormula(label: "Value", format: .number, step: .months(1)))
    }

    @Test("Models in ratios need readings above zero, Seasonal a step under a year, and the value its own name")
    func suitable() {
        func kinds(_ value: ForecastModels.Value, _ readings: [Double]) -> Set<ForecastModels.Kind> {
            let list = readings.enumerated().map { Reading(time: utc(2000 + $0.offset, 1, 1), variable: value.name, value: $0.element) }
            return Set(ForecastModels.templates(for: value, readings: list).compactMap(ForecastModels.kind(of:)))
        }
        #expect(kinds(monthlyValue, [1, 2, 3]) == Set(ForecastModels.Kind.allCases))
        #expect(kinds(monthlyValue, [1, -2, 3]) == [.holdTheLatest, .steadyChange, .recentChange, .trendLine, .seasonal])
        var yearly = monthlyValue
        yearly.step = .years(1)
        #expect(!kinds(yearly, [1, 2, 3]).contains(.seasonal))
        var rate = monthlyValue
        rate.name = "rate"
        #expect(!kinds(rate, [1, 2, 3]).contains(.recentGrowth))
        #expect(!kinds(rate, [1, 2, 3]).contains(.sCurve))
    }

    @Test("A trend line and a seasonal wave are found from their first guesses")
    func lineAndWave() throws {
        let temp = ForecastModels.Value(name: "temp", label: "Temperature", format: .temperature, step: .months(1))
        // 11 °C on average in 2000, warming 0.03 °C a year, 9 °C either side, warmest in July.
        let readings = Self.monthly("temp", from: utc(2000, 1, 1), count: 180) { index, year in
            11 + 0.03 * (year - 2000) + 9 * cos(2 * .pi * (year - 0.5)) + 0.5 * Self.noise(index)
        }
        let seasonal = try Self.score(.seasonal, value: temp, readings: readings)
        #expect(abs(seasonal.values["level"]! - 11) < 0.1)
        #expect(abs(seasonal.values["perYear"]! - 0.03) < 0.01)
        #expect(abs(seasonal.values["swing"]! - 9) < 0.1)
        #expect(abs(seasonal.values["peak"]! - 7) < 0.1)
        // Temperatures are measured in degrees, not ratios, though these are all above zero.
        #expect(!seasonal.miss.isRatio)
        #expect(seasonal.miss.typical < 0.4)

        let trend = try Self.score(.trendLine, value: temp, readings: readings)
        #expect(trend.miss.typical > 5)
    }

    @Test("Steady growth, Recent change and an S-curve find their values")
    func others() throws {
        let growthReadings = Self.monthly(from: utc(2000, 1, 1), count: 120) { index, _ in
            100 * pow(1.05, Double(index) / 12) * (1 + 0.002 * Self.noise(index))
        }
        let growth = try Self.score(.steadyGrowth, value: monthlyValue, readings: growthReadings)
        #expect(abs(growth.values["growth"]! - 0.05) < 0.002)
        let recent = try Self.score(.recentGrowth, value: monthlyValue, readings: growthReadings)
        #expect(recent.miss.typical < 0.02)

        // Rising 3 a year from 100, with small wobbles: Recent change learns the 3.
        let rising = Self.monthly(from: utc(2000, 1, 1), count: 120) { index, _ in 100 + 3 * Double(index) / 12 + 0.05 * Self.noise(index) }
        let change = try Self.score(.recentChange, value: monthlyValue, readings: rising)
        #expect(change.miss.typical < 0.01)

        // Levels off at 5,000, growing at 80% a year at first.
        let curve = Self.monthly(from: utc(2000, 1, 1), count: 120) { index, _ in
            5000 / (1 + (5000 / 50 - 1) * exp(-0.8 * Double(index) / 12))
        }
        let sCurve = try Self.score(.sCurve, value: monthlyValue, readings: curve)
        #expect(abs(sCurve.values["capacity"]! - 5000) < 50)
        #expect(abs(sCurve.values["rate"]! - 0.8) < 0.02)
    }
}
