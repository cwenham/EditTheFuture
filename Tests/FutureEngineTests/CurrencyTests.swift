import Foundation
import Testing
@testable import FutureEngine

@Suite("Currencies")
struct CurrencyTests {
    @Test("Currencies by code, with symbols, names and what goes before an amount")
    func codes() throws {
        #expect(Currency(code: "gbp") == .gbp)
        #expect(Currency(code: " EUR ") == .eur)
        #expect(Currency.gbp.symbol == "£" && Currency.gbp.prefix == "£")
        #expect(Currency(code: "CHF")?.prefix == "CHF ")
        #expect(Currency(code: "CAD")?.symbol == "CA$")
        #expect(Currency.gbp.plural == "British pounds")
        #expect(Currency.gbp.menuTitle == "British pound (£)")
        #expect(Currency(code: "CHF")?.menuTitle == "Swiss franc (CHF)")
        // Any ISO 4217 code works, written with its code.
        let lempira = try #require(Currency(code: "HNL"))
        #expect(lempira.symbol == "HNL" && lempira.prefix == "HNL ")
        #expect(!lempira.name.isEmpty)
        for text in ["XYZ", "pounds", "", "GB", "GBPX", "12A"] { #expect(Currency(code: text) == nil) }
    }

    @Test("Symbols, codes and words name currencies; a shared one means the most used")
    func named() {
        #expect(Currency.named("£") == .gbp)
        #expect(Currency.named("$") == .usd)
        #expect(Currency.named("euros") == .eur)
        #expect(Currency.named("quid") == .gbp)
        #expect(Currency.named("¥") == .jpy)
        #expect(Currency.named("CN¥")?.code == "CNY")
        #expect(Currency.named("dollars") == .usd)
        #expect(Currency.named("kes")?.code == "KES")
        #expect(Currency.named("lots") == nil)
    }

    @Test("A symbol answers for every currency written with it")
    func answers() throws {
        let canadian = try #require(Currency(code: "CAD"))
        for typed in ["$", "ca$", "CAD", "dollars", "dollar"] { #expect(canadian.answers(to: typed), "\(typed)") }
        for typed in ["£", "euros", "usd", ""] { #expect(!canadian.answers(to: typed), "\(typed)") }
        #expect(Currency.gbp.answers(to: "pounds") && Currency.gbp.answers(to: "GBP") && !Currency.gbp.answers(to: "$"))
        #expect(Currency(code: "CNY")!.answers(to: "¥"))
    }

    @Test("Typed text gives up its currency: symbols before or after, codes and words after")
    func split() {
        func check(_ text: String, _ rest: String, _ unit: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let found = Currency.split(text)
            #expect(found?.rest == rest && found?.unit == unit, "\(text) gave \(String(describing: found))", sourceLocation: sourceLocation)
        }
        check("£1200", "1200", "£")
        check("-$5k", "-5k", "$")
        check("$-5k", "-5k", "$")
        check("ca$5", "5", "ca$")
        check("500€", "500", "€")
        check("500euros", "500", "euros")
        check("2.5bnusd", "2.5bn", "usd")
        check("500chf", "500", "chf")
        check("1200zł", "1200", "zł")
        // A word in front, such as a slot's name, is never taken for a currency.
        for text in ["savings500", "gbp500", "25c", "212°f", "1.5m", "4%", "inf", "lots", "-5degrees"] {
            #expect(Currency.split(text) == nil, "\(text)")
        }
    }
}
