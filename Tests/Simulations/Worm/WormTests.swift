import Foundation
import Testing
import FutureEngine
import FutureSimulation
@testable import WormSimulation

/// The Internet worm module, against what's known about random-scanning worms, with nothing but the engine.
@Suite("Internet worm module")
struct WormTests {
    static let start = Calendar.utcGregorian.date(from: DateComponents(year: 2001, month: 7, day: 19))!

    static func after(hours: Double) -> Date { start.addingTimeInterval(hours * 3_600) }

    func worm(_ values: [String: Double] = [:]) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: Self.start)
        let model = try WormModule().makeModel(name: "Worm", values: values, data: .none)
        return (scenario, try scenario.addSlot("Worm", model: model))
    }

    /// The simple scanning worm with nothing in its way: I(t) = N ÷ (1 + (N ÷ I₀ − 1) e^(−Kt)),
    /// with K = scans × N ÷ 2³² a second.
    static func logistic(n: Double, first: Double, scans: Double, seconds: Double) -> Double {
        let k = scans * n / 4_294_967_296
        return n / (1 + (n / first - 1) * exp(-k * seconds))
    }

    @Test("Code Red's defaults grow at the 1.8 an hour fitted to its spread, and follow the logistic curve")
    func codeRed() throws {
        let (scenario, slot) = try worm()
        let k = 6 * 360_000 / 4_294_967_296 * 3_600.0
        #expect(abs(k - 1.81) < 0.01)
        for hours in [1.0, 3, 6, 8, 10, 14] {
            let expected = Self.logistic(n: 360_000, first: 10, scans: 6, seconds: hours * 3_600)
            let infected = try scenario.value("infected", of: slot, at: Self.after(hours: hours))
            #expect(abs(infected - expected) / expected < 0.002, "\(hours) h: \(infected) against \(expected)")
        }
        #expect(try scenario.value("everInfected", of: slot, at: Self.after(hours: 24)) > 359_999)
    }

    @Test("Slammer's numbers double in about ten seconds and fill the Internet in minutes")
    func slammer() throws {
        let (scenario, slot) = try worm(["vulnerable": 75_000, "scanRate": 4_000, "infected": 1])
        let early = try scenario.value("infected", of: slot, at: Self.after(hours: 1.0 / 60))
        // e^(0.07 × 60) ≈ 66 times in the first minute.
        #expect(early > 50 && early < 80)
        #expect(try scenario.value("everInfected", of: slot, at: Self.after(hours: 10.0 / 60)) > 0.9 * 75_000)
    }

    @Test("Once every host is infected it settles, and a century takes no time")
    func settles() throws {
        let (scenario, slot) = try worm()
        let began = Date()
        // The last millionth of a host is counted as patched when it settles.
        #expect(abs(try scenario.value("infected", of: slot, at: Self.after(hours: 24 * 365 * 100)) - 360_000) < 1e-5)
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(scenario.computedThrough(slot) == .distantFuture)
    }

    @Test("Congestion slows it; cleanup makes it peak and die out; patching leaves hosts it never reaches")
    func twoFactor() throws {
        let (plain, plainSlot) = try worm()
        let (congested, congestedSlot) = try worm(["congestion": 3])
        let at = Self.after(hours: 7)
        let slowed = try congested.value("infected", of: congestedSlot, at: at), unslowed = try plain.value("infected", of: plainSlot, at: at)
        #expect(slowed < unslowed)

        let (cleaned, cleanedSlot) = try worm(["cleanup": 0.1])
        let peaks = try cleaned.generatedEvents(in: cleanedSlot, through: Self.after(hours: 24 * 30)).filter { $0.kind == "Peak" }
        #expect(peaks.count == 1)
        #expect(try cleaned.value("infected", of: cleanedSlot, at: Self.after(hours: 24 * 365)) == 0)

        let (patched, patchedSlot) = try worm(["patching": 0.5])
        let end = Self.after(hours: 24 * 60)
        let ever = try patched.value("everInfected", of: patchedSlot, at: end)
        let safe = try patched.value("patched", of: patchedSlot, at: end)
        #expect(ever < 359_000 && safe > 1_000)
        #expect(abs(ever + safe - 360_000) < 1e-3)
        #expect(try patched.value("susceptible", of: patchedSlot, at: end) == 0)
    }

    @Test("Everyone is counted once, minute by minute")
    func conserved() throws {
        let (scenario, slot) = try worm(["cleanup": 0.2, "patching": 0.3, "congestion": 2])
        for hours in stride(from: 0.5, through: 30, by: 2.5) {
            let date = Self.after(hours: hours)
            let total = try ["susceptible", "infected", "cleaned", "patched"].map { try scenario.value($0, of: slot, at: date) }.reduce(0, +)
            #expect(abs(total - 360_000) < 1e-6 * 360_000, "\(hours) h")
            let groups = try #require(try scenario.field("groups", of: slot, at: date))
            #expect(abs(groups.values.reduce(0, +) - 1) < 1e-9)
        }
    }

    @Test("Events: an outbreak years later wakes it, and patches and cleanups take effect at their minute")
    func events() throws {
        let (scenario, slot) = try worm(["infected": 0])
        let release = Calendar.utcGregorian.date(from: DateComponents(year: 2030, month: 3, day: 1, hour: 9))!
        scenario.add(Event(time: release, kind: "infect", values: ["amount": 50]), to: slot)
        scenario.add(Event(time: release.addingTimeInterval(-60), kind: "patch", values: ["amount": 60_000]), to: slot)
        #expect(try scenario.value("infected", of: slot, at: release.addingTimeInterval(-120)) == 0)
        #expect(try scenario.value("patched", of: slot, at: release.addingTimeInterval(-60)) == 60_000)
        #expect(try scenario.value("infected", of: slot, at: release) == 50)
        #expect(try scenario.value("everInfected", of: slot, at: release.addingTimeInterval(24 * 3_600)) > 299_000)
        let settledLater = try scenario.value("infected", of: slot, at: Self.after(hours: 1e6))
        #expect(abs(settledLater - 300_000) < 1e-5)
        #expect(scenario.computedThrough(slot) == .distantFuture)
    }

    @Test("Extreme values stay finite and in bounds")
    func extremes() throws {
        for values in [["scanRate": 100_000.0, "vulnerable": 100_000_000], ["vulnerable": 1, "infected": 5], ["scanRate": 0]] {
            let (scenario, slot) = try worm(values)
            for name in ["infected", "susceptible", "everInfected", "scans"] {
                let value = try scenario.value(name, of: slot, at: Self.after(hours: 3))
                #expect(value.isFinite && value >= 0, "\(values) \(name) = \(value)")
            }
        }
    }

    @Test("The numbers' names follow the shape")
    func layout() {
        #expect(Worm().shape.names == Worm.N.allCases.map { String(describing: $0) })
    }
}
