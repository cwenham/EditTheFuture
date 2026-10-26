import Foundation
import Testing
import FutureEngine
@testable import FutureFormula

/// Colouring, completion and fixes for the formula editor (docs/UI.md, 5.7).
@Suite("Formula editing tools")
struct FormulaToolsTests {
    func kinds(_ source: String) -> [String: FormulaTokenKind] {
        var result: [String: FormulaTokenKind] = [:]
        for token in FormulaHighlighter.tokens(in: source) where result[token.text] == nil { result[token.text] = token.kind }
        return result
    }

    @Test("Tokens are coloured by what they are, valid or not")
    func highlighting() {
        let source = """
            step 1 month   # monthly
            param rate = 4.5% range 0%..15% label "Interest rate"
            init balance = 18000 as currency
            balance[t] = balance[t-1] * (1 + rate / 12) + max(0, Climate.temp.mean[t-1]) + step
            on Building.OverCapacity: balance += event.amount
            when balance > 1e6 emit Rich
            x = range * 2 +
            """
        let found = kinds(source)
        #expect(found["step"] == .keyword)  // a statement here; `step` later is the built-in
        #expect(found["month"] == .name)
        #expect(found["# monthly"] == .comment)
        #expect(found["4.5%"] == .number)
        #expect(found["0%"] == .number)
        #expect(found["range"] == .keyword)
        #expect(found["\"Interest rate\""] == .string)
        #expect(found["[t-1]"] == .lag)
        #expect(found["[t]"] == .lag)
        #expect(found["max"] == .function)
        #expect(found["Climate.temp.mean"] == .reference)
        #expect(found["Building.OverCapacity"] == .reference)
        #expect(found["event.amount"] == .eventField)
        #expect(found["1e6"] == .number)
        #expect(found["emit"] == .keyword)
        let tokens = FormulaHighlighter.tokens(in: source)
        #expect(tokens.last { $0.text == "step" }?.kind == .builtin)
        #expect(tokens.last { $0.text == "range" }?.kind == .name)  // a name in an expression
        // Ranges are UTF-16, so text after an emoji or accent still lines up.
        let accented = "param café = 1 # ☕️ note\nx[t] = café"
        let last = FormulaHighlighter.tokens(in: accented).last!
        #expect((accented as NSString).substring(with: last.range) == "café")
    }

    let slots = [
        FormulaSlotSummary(name: "Climate", values: [("temp", "Temperature"), ("warming", "Warming per year")], events: ["Heatwave"]),
        FormulaSlotSummary(name: "Savings", values: [("balance", "Balance")], events: []),
    ]

    func complete(_ source: String, own: String? = "Savings") -> [String] {
        FormulaCompleter.complete(source, at: source.utf16.count, slots: slots, ownName: own).items.map(\.text)
    }

    @Test("Completion offers what fits where the caret is")
    func completion() {
        let formula = "step 1 month\nparam rate = 5%\ninit balance = 100\nbalance[t] = balance[t-1] * (1 + "
        #expect(complete(formula + "ra") == ["rate", "random()"])
        #expect(complete(formula + "b") == ["balance"])
        #expect(complete(formula + "Cl") == ["Climate.", "clamp()"])  // never this slot itself
        #expect(complete(formula + "cl") == ["clamp()", "Climate."])  // matching case first
        #expect(complete(formula + "Climate.") == ["temp", "warming"])
        #expect(complete(formula + "Climate.t") == ["temp"])
        #expect(complete(formula + "Climate.temp.m") == ["max", "mean", "min"])
        #expect(complete(formula + "mon") == ["month"])
        #expect(complete("step 1 mo") == ["month"])
        #expect(complete("param a = 1 as cu") == ["currency"])
        #expect(complete("on Climate.") == ["temp", "warming", "Heatwave"])
        #expect(complete("on deposit: x += ev") == ["event."])
        #expect(complete("on deposit: x += event.") == ["amount"])
        #expect(complete("pa") == ["param "])
        #expect(complete(formula + "rate # ra").isEmpty)  // in a comment
        #expect(complete("param a = 1 label \"ra").isEmpty)  // in a label
        #expect(complete(formula + "12").isEmpty)
        #expect(complete(formula + "rate").isEmpty)  // already complete

        let result = FormulaCompleter.complete(formula + "cla", at: (formula + "cla").utf16.count, slots: slots)
        #expect(result.range == NSRange(location: formula.utf16.count, length: 3))
        let clamp = result.items.first { $0.text == "clamp()" }
        #expect(clamp?.caretBack == 1)
        #expect(clamp?.label == "clamp(x, low, high)")
    }

    @Test("Names are found in a half-written formula")
    func declaredNames() {
        let names = FormulaCompleter.declaredNames(in: "param r = 0.5\ninit P = 10\ndP/dt = r * P\nload[t] = P *\nwhen P > 3 emit X\nlimit = 4")
        #expect(names.parameters == ["r"])
        #expect(names.variables == ["P", "load", "limit"])
    }

    func diagnose(_ source: String) -> FormulaDiagnosis? {
        do {
            _ = try FormulaModel(source)
            return nil
        } catch let error as FormulaError {
            return FormulaDiagnoser.diagnose(error, in: source)
        } catch {
            return nil
        }
    }

    @Test("Misspellings get a one-click fix")
    func misspellings() throws {
        let source = "param rate = 5%\ninit balance = 1\nbalance[t] = balance[t-1] * (1 + rat) + balanse"
        let diagnosis = try #require(diagnose(source))
        #expect(diagnosis.title == "rat isn't defined")
        #expect(diagnosis.line == 3)
        #expect((source as NSString).substring(with: diagnosis.range!) == "rat")
        #expect(diagnosis.fixes.map(\.title) == ["Use rate"])
        let fixed = diagnosis.fixes[0].source
        let next = try #require(diagnose(fixed))
        #expect(next.fixes.map(\.title) == ["Use balance"])
        // Now it reads its own value in the same step.
        let own = try #require(diagnose(next.fixes[0].source))
        #expect(own.title == "balance uses its own value from the same step")
        #expect(own.fixes.map(\.title) == ["Use balance[t-1]"])
        #expect(diagnose(own.fixes[0].source) == nil)

        let function = try #require(diagnose("x[t] = mx(1, 2)"))
        #expect(function.fixes.map(\.source) == ["x[t] = max(1, 2)"])
        let unknown = try #require(diagnose("x[t] = zebra"))
        #expect(unknown.fixes.isEmpty)
        #expect(unknown.detail != nil)
        let arguments = try #require(diagnose("x[t] = clamp(1, 2)"))
        #expect(arguments.detail == "Write it as clamp(x, low, high).")
    }

    @Test("A same-step loop inside a formula gets a [t-1] fix")
    func loopFix() throws {
        let source = "a[t] = b + 1\nb[t] = a * 2"
        let diagnosis = try #require(diagnose(source))
        #expect(diagnosis.title == "a and b depend on each other within the same step")
        #expect(diagnosis.line == 1)
        #expect(diagnosis.fixes.map(\.title) == ["Use b[t-1]"])
        #expect(diagnosis.fixes[0].source == "a[t] = b[t-1] + 1\nb[t] = a * 2")
        #expect(diagnose(diagnosis.fixes[0].source) == nil)
    }

    @Test("Syntax errors point at their line")
    func syntax() throws {
        let source = "step 1 month\n  param rate = \ninit x = 1"
        let diagnosis = try #require(diagnose(source))
        #expect(diagnosis.line == 2)
        #expect((source as NSString).substring(with: diagnosis.range!) == "param rate =")
        #expect(FormulaError.unknownName("q", line: 4).message == "q isn't defined.")
    }

    @Test("The vocabulary matches what the language accepts")
    func vocabulary() {
        #expect(Set(FormulaVocabulary.functions.map(\.name)) == Set(Analyzer.functions.keys))
        #expect(Set(FormulaVocabulary.builtins.map(\.name)) == Analyzer.builtins)
        #expect(FormulaDiagnoser.closest(to: "Temp", in: ["temp", "time"]) == "temp")
        #expect(FormulaDiagnoser.closest(to: "warmng", in: ["warming", "mean"]) == "warming")
        #expect(FormulaDiagnoser.closest(to: "abc", in: ["xyz"]) == nil)
    }
}
