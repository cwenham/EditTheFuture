import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Ranges, labels and kinds of value on params and inits, and a slot's own values for them
/// (docs/DESIGN.md, 6.2).
@Suite("Parameter options and slot values")
struct DeclarationOptionTests {
    let start = utc(2026, 1, 1)

    let source = """
        step 1 month
        param rate = 4.5% range 0%..15% by 0.1% label "Interest rate"
        param monthly = 400 range 0..5000 by 50 label "Monthly deposit" as currency
        param years = 2
        init balance = 18000 label "Balance" as currency
        init doubled = balance * 2
        balance[t] = balance[t-1] * (1 + rate / 12) + monthly
        """

    @Test("Options end up in the descriptor")
    func descriptor() throws {
        let model = try FormulaModel(source)
        let rate = try #require(model.descriptor.variable(named: "rate"))
        #expect(rate.label == "Interest rate")
        #expect(rate.minimum == 0)
        #expect(rate.maximum == 0.15)
        #expect(abs((rate.increment ?? 0) - 0.001) < 1e-12)
        #expect(rate.quantity == .percent)  // written with %, so a percent without saying so

        let monthly = try #require(model.descriptor.variable(named: "monthly"))
        #expect(monthly.quantity == .currency)
        #expect(monthly.increment == 50)
        #expect(model.descriptor.variable(named: "years")?.quantity == nil)

        let balance = try #require(model.descriptor.variable(named: "balance"))
        #expect(balance.causality == .output)
        #expect(balance.label == "Balance")
        #expect(balance.quantity == .currency)
        #expect(model.startingValueNames == ["balance", "doubled"])
    }

    @Test("Options are optional, in any order, and checked")
    func checking() throws {
        _ = try FormulaModel("param a = 1 as number label \"A\" by 1 range -5..5\ninit x = a\nx[t] = x[t-1]")
        #expect(throws: FormulaError.invalid(line: 1, message: "The range of a must go from a smaller number to a larger one.")) {
            try FormulaModel("param a = 1 range 5..1")
        }
        #expect(throws: FormulaError.invalid(line: 1, message: "The step of a must be more than 0.")) {
            try FormulaModel("param a = 1 by 0")
        }
        #expect(throws: FormulaError.syntax(line: 1, message: "a has more than one label.")) {
            try FormulaModel("param a = 1 label \"A\" label \"B\"")
        }
        #expect(throws: FormulaError.syntax(line: 1, message: "dollars isn't a kind of value. Use number, percent, currency or temperature.")) {
            try FormulaModel("param a = 1 as dollars")
        }
        #expect(throws: FormulaError.syntax(line: 1, message: "This text needs a closing \".")) {
            try FormulaModel("param a = 1 label \"Rate")
        }
        // An option word can still be a name in the value itself.
        _ = try FormulaModel("param range = 2\nparam b = range * 2 range 0..10")
    }

    @Test("Defaults that are constants can be read without running the model")
    func defaults() throws {
        let model = try FormulaModel(source + "\nparam later = year")
        #expect(model.declaredDefaults["rate"] == 0.045)
        #expect(model.declaredDefaults["balance"] == 18000)
        #expect(model.declaredDefaults["doubled"] == 36000)
        #expect(model.declaredDefaults["later"] == nil)  // depends on the date
    }

    @Test("A slot's own values replace the defaults at the start, and set events still apply")
    func overrides() throws {
        let model = try FormulaModel(source, values: ["rate": 0.12, "balance": 1000, "unknown": 5])
        #expect(model.overrides == ["rate": 0.12, "balance": 1000])
        #expect(model.startingValues["doubled"] == 2000)  // follows the overridden balance
        #expect(model.declaredDefaults["doubled"] == 36000)

        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Savings", model: model)
        #expect(try scenario.value("balance", of: slot, at: start) == 1000)
        #expect(try scenario.value("rate", of: slot, at: start) == 0.12)
        let oneMonth = try scenario.value("balance", of: slot, at: utc(2026, 2, 1))
        #expect(abs(oneMonth - (1000 * 1.01 + 400)) < 1e-9)

        scenario.add(Event.set(["rate": 0.03], at: utc(2026, 6, 1)), to: slot)
        #expect(try scenario.value("rate", of: slot, at: utc(2026, 7, 1)) == 0.03)
    }
}
