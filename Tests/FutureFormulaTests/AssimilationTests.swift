import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Readings correct a model (docs/DESIGN.md, 4.6): a reading of a value replaces what its step
/// worked out, and a reading of a parameter sets it, as a `set` event would.
@Suite("Readings correct formulas")
struct AssimilationTests {
    let start = utc(2026, 1, 1)

    func balances(_ readings: [Reading], through end: Date = utc(2026, 9, 1)) throws -> (balance: [Double], rate: [Double]) {
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot("Savings", model: FormulaModel(savingsSource, name: "Savings"))
        scenario.setReadings(readings, for: id)
        let balance = try scenario.series("balance", of: id, from: start, through: end).map(\.value)
        let rate = try scenario.series("rate", of: id, from: start, through: end).map(\.value)
        return (balance, rate)
    }

    @Test("A reading of a value replaces it at its step, and the model carries on from it")
    func values() throws {
        let plain = try balances([])
        // Step 3 covers March: after Mar 1, up to Apr 1.
        let read = try balances([Reading(time: utc(2026, 3, 10), variable: "balance", value: 5000),
                                 Reading(time: utc(2026, 3, 20), variable: "balance", value: 5100)])
        #expect(Array(read.balance[0..<3]) == Array(plain.balance[0..<3]))
        #expect(read.balance[3] == 5100)
        #expect(abs(read.balance[4] - (5100 * (1 + 0.06 / 12) + 200)) < 1e-9)
    }

    @Test("A reading of a parameter sets it from its step on")
    func parameters() throws {
        let read = try balances([Reading(time: utc(2026, 6, 15), variable: "rate", value: 0.03)])
        #expect(read.rate[5] == 0.06)
        #expect(read.rate[6] == 0.03)
        #expect(read.rate[8] == 0.03)
    }

    @Test("The start takes the latest readings before it")
    func startTakesLatest() throws {
        let read = try balances([Reading(time: utc(2025, 6, 1), variable: "balance", value: 1500),
                                 Reading(time: utc(2025, 12, 1), variable: "balance", value: 2000),
                                 Reading(time: utc(2025, 11, 1), variable: "rate", value: 0.12)])
        #expect(read.balance[0] == 2000)
        #expect(read.rate[0] == 0.12)
        #expect(abs(read.balance[1] - (2000 * (1 + 0.12 / 12) + 200)) < 1e-9)
    }

    @Test("Readings of names the model doesn't have change nothing")
    func unknown() throws {
        #expect(try balances([Reading(time: utc(2026, 3, 10), variable: "price", value: 1)]).balance == balances([]).balance)
    }
}
