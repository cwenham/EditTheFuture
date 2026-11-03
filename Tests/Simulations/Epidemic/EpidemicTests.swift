import Foundation
import Testing
import FutureEngine
import FutureSimulation
@testable import EpidemicSimulation

/// The Epidemic module (SEIR), checked against what's known about such outbreaks. It runs here with
/// nothing but the engine: no app, files or network.
@Suite("Epidemic module")
struct EpidemicTests {
    static let start = date(2026, 1, 1)

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func outbreak(_ values: [String: Double] = [:]) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: Self.start)
        let model = try EpidemicModule().makeModel(name: "Outbreak", values: values, data: .none)
        let slot = try scenario.addSlot("Outbreak", model: model)
        return (scenario, slot)
    }

    /// The share of people an unchecked outbreak reaches: z = 1 − e^(−R₀ z), the same for SEIR as for SIR.
    static func finalShare(r0: Double) -> Double {
        var z = 0.5
        for _ in 0..<200 { z = 1 - exp(-r0 * z) }
        return z
    }

    @Test("An unchecked outbreak reaches the share the final-size equation gives")
    func finalSize() throws {
        for r0 in [1.5, 2.5, 6.0] {
            let (scenario, slot) = try outbreak(["r0": r0])
            let reached = try scenario.value("cases", of: slot, at: Self.date(2029, 1, 1)) / 1_000_000
            #expect(abs(reached - Self.finalShare(r0: r0)) < 0.005, "R₀ \(r0): \(reached)")
            #expect(try scenario.value("infectious", of: slot, at: Self.date(2029, 1, 1)) < 1)
        }
    }

    @Test("Early on, cases grow at the rate R₀ and the two periods give")
    func earlyGrowth() throws {
        let (scenario, slot) = try outbreak(["population": 1e9])
        // Growth r per day solves (1 + r × incubation)(1 + r × illness) = R₀.
        let a = 5.0 * 7, b = 5.0 + 7, c = 1 - 2.5
        let r = (-b + (b * b - 4 * a * c).squareRoot()) / (2 * a)
        let first = try scenario.value("cases", of: slot, at: Self.date(2026, 3, 1))
        let later = try scenario.value("cases", of: slot, at: Self.date(2026, 3, 31))
        // A step a day grows a little slower than the continuous equations, which have no lag inside a day.
        #expect(abs(log(later / first) / 30 - r) / r < 0.1)
    }

    @Test("With R₀ below 1 the first cases die out")
    func fizzles() throws {
        let (scenario, slot) = try outbreak(["r0": 0.8])
        #expect(try scenario.value("cases", of: slot, at: Self.date(2027, 1, 1)) < 60)
        #expect(try scenario.value("infectious", of: slot, at: Self.date(2028, 1, 1)) < 0.01)
    }

    @Test("Vaccinating before the wave shrinks it, and can't vaccinate more people than there are")
    func vaccination() throws {
        let (plain, plainSlot) = try outbreak()
        let (vaccinated, slot) = try outbreak()
        vaccinated.add(Event(time: Self.date(2026, 1, 15), kind: "vaccinate", values: ["amount": 500_000]), to: slot)
        let end = Self.date(2028, 1, 1)
        let without = try plain.value("cases", of: plainSlot, at: end)
        let with = try vaccinated.value("cases", of: slot, at: end)
        #expect(with < without / 2)
        // Half vaccinated leaves R₀ × 0.5 = 1.25, so the wave reaches about 1 − e^(−1.25 z) of the rest.
        #expect(abs(with / 500_000 - Self.finalShare(r0: 1.25)) < 0.01)

        let (over, overSlot) = try outbreak()
        over.add(Event(time: Self.date(2026, 1, 2), kind: "vaccinate", values: ["amount": 5e9]), to: overSlot)
        #expect(try over.value("vaccinated", of: overSlot, at: end) <= 1_000_000)
        #expect(try over.value("susceptible", of: overSlot, at: end) >= 0)
    }

    @Test("Imported cases start an outbreak in a population that had none")
    func imported() throws {
        let (scenario, slot) = try outbreak(["exposed": 0])
        scenario.add(Event(time: Self.date(2027, 1, 1), kind: "imported", values: ["amount": 50]), to: slot)
        #expect(try scenario.value("cases", of: slot, at: Self.date(2026, 12, 1)) == 0)
        #expect(try scenario.value("cases", of: slot, at: Self.date(2028, 6, 1)) > 800_000)
    }

    @Test("The peak and herd immunity are marked once each, and herd immunity comes first")
    func events() throws {
        let (scenario, slot) = try outbreak()
        let generated = try scenario.generatedEvents(in: slot, through: Self.date(2030, 1, 1))
        let peaks = generated.filter { $0.kind == "Peak" }, herd = generated.filter { $0.kind == "HerdImmunity" }
        #expect(peaks.count == 1 && herd.count == 1)
        if let peak = peaks.first, let immune = herd.first {
            // In SEIR, cases still incubating keep the infectious count rising for a while after R drops below 1.
            #expect(immune.time < peak.time)
            #expect(peak.time.timeIntervalSince(immune.time) < 30 * 86_400)
            #expect(peak.time > Self.date(2026, 3, 1) && peak.time < Self.date(2026, 9, 1))
        }
    }

    @Test("Huge populations and extreme values stay finite")
    func extremes() throws {
        let (scenario, slot) = try outbreak(["population": 1e10, "r0": 20, "incubation": 0.5, "illness": 0.5])
        for variable in ["exposed", "infectious", "recovered", "susceptible", "cases", "rt"] {
            let value = try scenario.value(variable, of: slot, at: Self.date(2027, 1, 1))
            #expect(value.isFinite && value >= -1e-6, "\(variable) is \(value)")
        }
        // A population of nothing, and huge imported numbers, don't divide by zero or overflow.
        let (empty, emptySlot) = try outbreak(["population": 0, "exposed": 0])
        empty.add(Event(time: Self.date(2026, 2, 1), kind: "imported", values: ["amount": 1e300]), to: emptySlot)
        for variable in ["susceptible", "cases", "rt", "caught"] {
            #expect(try empty.value(variable, of: emptySlot, at: Self.date(2026, 6, 1)).isFinite, "\(variable)")
        }
    }

    @Test("Everyone is counted once: the groups always add up to the population")
    func conserved() throws {
        let (scenario, slot) = try outbreak(["r0": 4])
        scenario.add(Event(time: Self.date(2026, 3, 1), kind: "vaccinate", values: ["amount": 200_000]), to: slot)
        for month in 1...12 {
            let date = Self.date(2026, month, 15)
            let total = try ["susceptible", "exposed", "infectious", "recovered", "vaccinated"]
                .map { try scenario.value($0, of: slot, at: date) }.reduce(0, +)
            #expect(abs(total - 1_000_000) < 1e-6 * 1_000_000, "\(date): \(total)")
        }
    }

    @Test("The numbers' names follow the shape, so the enum reads the right ones")
    func layout() {
        let shape = Epidemic().shape
        #expect(shape.names == Epidemic.N.allCases.map { String(describing: $0) })
        #expect(EpidemicModule().reference.description == "epidemic@1")
    }

    @Test("Where everyone is: each group's share, adding up to 1, at any date")
    func groups() throws {
        let (scenario, slot) = try outbreak()
        scenario.add(Event(time: Self.date(2026, 2, 1), kind: "vaccinate", values: ["amount": 100_000]), to: slot)
        for date in [Self.start, Self.date(2026, 4, 20), Self.date(2026, 7, 3), Self.date(2028, 1, 1)] {
            let field = try #require(try scenario.field("groups", of: slot, at: date))
            #expect(field.keys == ["susceptible", "exposed", "infectious", "recovered", "vaccinated"])
            #expect(abs(field.values.reduce(0, +) - 1) < 1e-9)
            for key in field.keys {
                #expect(abs(field[key]! - (try scenario.value(key, of: slot, at: date)) / 1_000_000) < 1e-12, "\(key)")
            }
        }
        #expect(try scenario.field("groups", of: slot, at: Self.date(2028, 1, 1))?["vaccinated"] == 0.1)
    }
}
