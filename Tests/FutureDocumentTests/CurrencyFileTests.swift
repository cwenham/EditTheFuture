import Foundation
import Testing
import FutureEngine
@testable import FutureDocument

/// Currencies in `scenario.md` (docs/DESIGN.md, 15.2).
@Suite("Currencies in scenario.md")
struct CurrencyFileTests {
    let text = """
        # Budget [start: 2024-01-01, currency: GBP]

        ## 1. Savings [Savings account, shows: balance]

        ```etf
        step 1 month
        init balance = 18000 as currency
        balance[t] = balance[t-1]
        ```

        ## 2. Oil [Hold the latest, currency: usd]

        ```etf
        step 1 day
        init value = 80 as currency
        value[t] = value[t-1]
        ```

        """

    @Test("The scenario's heading and a slot's name currencies, in any case")
    func reads() throws {
        let parsed = try ScenarioFormat.parse(text)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.file.currency == .gbp)
        #expect(parsed.file.slots.map(\.currency) == [nil, .usd])
    }

    @Test("Without a currency the file says nothing, and writing it back adds nothing")
    func unsaid() throws {
        let plain = text.replacingOccurrences(of: ", currency: GBP", with: "")
        let parsed = try ScenarioFormat.parse(plain)
        #expect(parsed.file.currency == nil)
        #expect(ScenarioFormat.text(for: parsed.file, over: parsed) == plain)
    }

    @Test("Currencies are written with their codes, and only the headings that changed are rewritten")
    func writes() throws {
        let parsed = try ScenarioFormat.parse(text)
        var file = parsed.file
        file.currency = .eur
        var written = ScenarioFormat.text(for: file, over: parsed)
        #expect(written.hasPrefix("# Budget [start: 2024-01-01, currency: EUR]\n"))
        #expect(written.contains("## 2. Oil [Hold the latest, currency: usd]"))  // unchanged, so as written

        file = parsed.file
        file.slots[0].currency = .jpy
        file.slots[1].currency = nil
        written = ScenarioFormat.text(for: file, over: parsed)
        #expect(written.contains("## 1. Savings [Savings account, shows: balance, currency: JPY]"))
        #expect(written.contains("## 2. Oil [Hold the latest]\n"))
        #expect(try ScenarioFormat.parse(written).file == file)

        let fresh = ScenarioFormat.text(for: ScenarioFile(name: "New", start: utc(2025, 1), currency: .gbp))
        #expect(fresh.hasPrefix("# New [start: 2025-01-01, currency: GBP]"))
    }

    @Test("A currency that can't be read is reported, kept as written, and US dollars or the scenario's are used")
    func mistakes() throws {
        let wrong = text.replacingOccurrences(of: "currency: GBP", with: "currency: pesetas")
            .replacingOccurrences(of: "currency: usd", with: "currency: doubloons")
        let parsed = try ScenarioFormat.parse(wrong)
        #expect(parsed.file.currency == nil)
        #expect(parsed.file.slots[1].currency == nil)
        #expect(parsed.problems.map(\.message) == [
            "“pesetas” isn't a currency: use its code, like GBP or EUR. US dollars are used.",
            "“doubloons” isn't a currency: use its code, like GBP or EUR. The scenario's is used.",
        ])
        var file = parsed.file
        file.slots[0].name = "Pot"
        let written = ScenarioFormat.text(for: file, over: parsed)
        #expect(written.contains("[start: 2024-01-01, currency: pesetas]"))
        #expect(written.contains("## 2. Oil [Hold the latest, currency: doubloons]"))
    }

    @Test("Values in the file can carry any currency's symbol or code")
    func numbers() {
        #expect(FileNumber.parse("£1,200") == 1200)
        #expect(FileNumber.parse("€6k") == 6000)
        #expect(FileNumber.parse("1200 EUR") == 1200)
        #expect(FileNumber.parse("-$50") == -50)
        #expect(FileNumber.parse("$1200", commas: false) == 1200)
        #expect(FileNumber.parse("£") == nil)
    }
}

@Suite("Exchange rates and number styles in scenario.md")
struct RatesFileTests {
    @Test("The heading names the source of rates and how numbers are written")
    func heading() throws {
        let text = "# Budget [start: 2024-01-01, currency: GBP, rates: openexchangerates, numbers: point-comma]\n"
        let parsed = try ScenarioFormat.parse(text)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.file.rates == .openexchangerates && parsed.file.numbers == .pointComma)
        #expect(ScenarioFormat.text(for: parsed.file, over: parsed) == text)

        var file = parsed.file
        file.rates = ExchangeRateSource.none
        file.numbers = nil
        #expect(ScenarioFormat.text(for: file, over: parsed) == "# Budget [start: 2024-01-01, currency: GBP, rates: none]\n")
        #expect(try ScenarioFormat.parse("# B [start: 2024-01-01, numbers: Regional]\n").file.numbers == nil)
        #expect(try ScenarioFormat.parse("# B [start: 2024-01-01]\n").file.rates == nil)
    }

    @Test("A source or style that can't be read is reported and kept as written")
    func mistakes() throws {
        let parsed = try ScenarioFormat.parse("# B [start: 2024-01-01, rates: fixer, numbers: roman]\n")
        #expect(parsed.file.rates == nil && parsed.file.numbers == nil)
        #expect(parsed.problems.map(\.message) == [
            "“fixer” isn't a source of exchange rates: use ecb, openexchangerates, none. The ECB's are used.",
            "“roman” isn't a way to write numbers: use regional, comma-point, point-comma, space-comma, apostrophe-point, indian. Each currency's own is used.",
        ])
        var file = parsed.file
        file.name = "C"
        #expect(ScenarioFormat.text(for: file, over: parsed) == "# C [start: 2024-01-01, rates: fixer, numbers: roman]\n")
    }
}
