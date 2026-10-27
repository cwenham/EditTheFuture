import Foundation
import Testing
@testable import FutureEngine

/// The solver behind Refit (docs/DESIGN.md, 8.4), on problems with known answers.
@Suite("Least squares")
struct LeastSquaresTests {
    /// Points on y = 3x − 2, so a line through them fits exactly.
    let xs = (0..<20).map { Double($0) / 2 }

    func line(_ values: [Double]) -> [Double] {
        xs.map { values[0] * $0 + values[1] - (3 * $0 - 2) }
    }

    func solver(lower: [Double] = [-.infinity, -.infinity], upper: [Double] = [.infinity, .infinity],
                residuals: @escaping ([Double]) throws -> [Double]?) -> LeastSquares {
        LeastSquares(lower: lower, upper: upper, scales: [1, 1], maxRounds: 100, residuals: residuals)
    }

    @Test("Finds a line's slope and intercept")
    func fitsALine() throws {
        let result = try #require(try solver(residuals: line).minimize(from: [0, 0]))
        #expect(abs(result.values[0] - 3) < 1e-6)
        #expect(abs(result.values[1] + 2) < 1e-6)
        #expect(result.cost < 1e-10)
    }

    @Test("Finds the rate of exponential growth, starting far from it")
    func fitsGrowth() throws {
        let ys = (0..<30).map { 100 * pow(1.05, Double($0)) }
        let result = try #require(try LeastSquares(lower: [-0.5], upper: [1], scales: [1.5], maxRounds: 100) { values in
            ys.indices.map { log(ys[$0] / (100 * pow(1 + values[0], Double($0)))) }
        }.minimize(from: [0.4]))
        #expect(abs(result.values[0] - 0.05) < 1e-6)
    }

    @Test("Stays within the bounds, stopping at the one nearest the best answer")
    func bounds() throws {
        let result = try #require(try solver(lower: [0, -10], upper: [2, 10], residuals: line).minimize(from: [1, 0]))
        #expect(result.values[0] == 2)
        #expect(result.values[1] >= -10 && result.values[1] <= 10)
        // With the slope held at 2, the best intercept is the mean gap.
        let gap = xs.map { 3 * $0 - 2 - 2 * $0 }.reduce(0, +) / Double(xs.count)
        #expect(abs(result.values[1] - gap) < 1e-6)
    }

    @Test("Residuals that can't be worked out count as worse, so the solver steps back")
    func unworkable() throws {
        // Only slopes below 2.5 can be worked out, so the best is just under it.
        let result = try #require(try solver(residuals: { values in values[0] < 2.5 ? line(values) : nil }).minimize(from: [0, 0]))
        #expect(result.values[0] < 2.5)
        #expect(result.values[0] > 2.4)
    }

    @Test("Nothing to start from gives nil")
    func noStart() throws {
        #expect(try solver(residuals: { _ in nil }).minimize(from: [0, 0]) == nil)
    }

    @Test("A value that changes nothing stays where it was")
    func inert() throws {
        let result = try #require(try solver(residuals: { values in xs.map { values[0] * $0 - 3 * $0 } }).minimize(from: [0, 7]))
        #expect(abs(result.values[0] - 3) < 1e-6)
        #expect(result.values[1] == 7)
    }

    @Test("Small systems solve, and ones without a single answer don't")
    func linearSystems() throws {
        let x = try #require(LeastSquares.solve([[2, 1], [1, 3]], [3, 5]))
        #expect(abs(x[0] - 0.8) < 1e-12 && abs(x[1] - 1.4) < 1e-12)
        #expect(LeastSquares.solve([[1, 2], [2, 4]], [1, 2]) == nil)
        #expect(LeastSquares.solve([[.nan]], [1]) == nil)
    }
}
