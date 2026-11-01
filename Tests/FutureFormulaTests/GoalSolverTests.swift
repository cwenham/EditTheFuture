import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Drag the future's solver: the value of one change that brings a line to a target
/// (docs/DESIGN.md, 8.1).
@Suite("Goal solver")
struct GoalSolverTests {
    let start = utc(2026, 1, 1)

    func savings(range: Bool = false) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: start)
        let source = range ? savingsSource.replacingOccurrences(of: "param rate = 6%", with: "param rate = 6% range 0%..10%") : savingsSource
        let id = try scenario.addSlot("Savings", model: FormulaModel(source))
        return (scenario, id)
    }

    @Test("A parameter from a date: the monthly deposit that reaches a target, rounded, with the scenario left as it was")
    func parameter() throws {
        let (scenario, id) = try savings()
        let date = utc(2036, 1, 1)
        let before = try scenario.value("balance", of: id, at: date)
        let target = 100_000.0
        let solution = try #require(try scenario.solve("balance", of: id, at: date, target: target,
                                                       lever: .parameter("deposit", from: utc(2027, 1, 1))))
        #expect(solution.before == 200)
        #expect(solution.input > 200)
        // Four significant figures, and close to the target.
        #expect(solution.input == (solution.input * 1).rounded(toPlaces: 4 - Int(log10(solution.input).rounded(.down)) - 1))
        #expect(abs(solution.achieved - target) / target < 0.001)
        #expect(solution.event == Event.set(["deposit": solution.input], at: utc(2027, 1, 1)).withID(solution.event.id))
        #expect(scenario.events(in: id).isEmpty)
        #expect(try scenario.value("balance", of: id, at: date) == before)
    }

    @Test("A lower target lowers the parameter, and below zero is allowed without a range")
    func parameterDown() throws {
        let (scenario, id) = try savings()
        let date = utc(2036, 1, 1)
        let solution = try #require(try scenario.solve("balance", of: id, at: date, target: 1_000,
                                                       lever: .parameter("deposit", from: utc(2027, 1, 1))))
        #expect(solution.input < 200)
        #expect(abs(solution.achieved - 1_000) < 50)
    }

    @Test("A one-off amount: the bonus that reaches a target")
    func amount() throws {
        let (scenario, id) = try savings()
        let date = utc(2036, 1, 1)
        let current = try scenario.value("balance", of: id, at: date)
        let solution = try #require(try scenario.solve("balance", of: id, at: date, target: current + 10_000,
                                                       lever: .amount(kind: "bonus", at: utc(2027, 1, 1))))
        // Growing at 6% a year for 9 years, about 10,000 / 1.71.
        #expect(solution.input > 5_000 && solution.input < 6_500)
        #expect(solution.input == solution.input.rounded())
        #expect(abs(solution.achieved - current - 10_000) < 5)
        // An amount can't take a line lower.
        #expect(try scenario.solve("balance", of: id, at: date, target: current - 10_000,
                                   lever: .amount(kind: "bonus", at: utc(2027, 1, 1))) == nil)
    }

    @Test("A parameter's range limits the search, and a target out of reach within it has no solution")
    func bounds() throws {
        let (scenario, id) = try savings(range: true)
        let date = utc(2036, 1, 1)
        #expect(try scenario.solve("balance", of: id, at: date, target: 1e9, lever: .parameter("rate", from: utc(2027, 1, 1)),
                                   bounds: 0...0.10) == nil)
        let current = try scenario.value("balance", of: id, at: date)
        let solution = try #require(try scenario.solve("balance", of: id, at: date, target: current + 2_000,
                                                       lever: .parameter("rate", from: utc(2027, 1, 1)), bounds: 0...0.10, step: 0.001))
        #expect(solution.input > 0.06 && solution.input <= 0.10)
        #expect(abs(solution.input * 1000 - (solution.input * 1000).rounded()) < 1e-9)
    }

    @Test("Stopping part-way throws, and leaves no trial event behind")
    func cancelling() throws {
        let (scenario, id) = try savings()
        var tries = 0
        #expect(throws: CancellationError.self) {
            try scenario.solve("balance", of: id, at: utc(2036, 1, 1), target: 100_000, lever: .parameter("deposit", from: utc(2027, 1, 1)),
                               isCancelled: { tries += 1; return tries > 3 })
        }
        #expect(scenario.events(in: id).isEmpty)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

private extension Event {
    func withID(_ id: UUID) -> Event {
        var copy = self
        copy.id = id
        return copy
    }
}
