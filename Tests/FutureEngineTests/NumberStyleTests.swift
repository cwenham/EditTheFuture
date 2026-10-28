import Foundation
import Testing
@testable import FutureEngine

@Suite("Number styles")
struct NumberStyleTests {
    let nbsp = "\u{00A0}", narrow = "\u{202F}"

    @Test("Numbers written in each style")
    func localize() {
        #expect(NumberStyle.commaPoint.localize("1,234,567.89") == "1,234,567.89")
        #expect(NumberStyle.pointComma.localize("1,234,567.89") == "1.234.567,89")
        #expect(NumberStyle.spaceComma.localize("1,234,567.89") == "1\(narrow)234\(narrow)567,89")
        #expect(NumberStyle.apostrophePoint.localize("1,234,567.89") == "1’234’567.89")
        #expect(NumberStyle.indian.localize("1,234,567.89") == "12,34,567.89")
        #expect(NumberStyle.indian.localize("123,456,789") == "12,34,56,789")
        #expect(NumberStyle.indian.localize("999") == "999")
        #expect(NumberStyle.indian.localize("0.12345") == "0.12345")
        #expect(NumberStyle.pointComma.localize("2.5e18") == "2,5e18")
        #expect(NumberStyle.pointComma.localize("1.25M") == "1,25M")
        #expect(NumberStyle.pointComma.example == "1.234.567,89")
    }

    @Test("Typed numbers read in each style")
    func normalize() {
        let german = NumberStyle.pointComma
        #expect(german.normalize("1.234,5") == "1234.5")
        #expect(german.normalize("1.234") == "1234")
        #expect(german.normalize("12.500 €") == "12500 €")
        #expect(german.normalize("1.234.567") == "1234567")
        // A point that isn't before thousands is a decimal point, as typed.
        #expect(german.normalize("1.5") == "1.5")
        #expect(german.normalize("0.045") == "0.045")
        #expect(german.normalize("4,5%") == "4.5%")
        #expect(german.normalize(",5") == ".5")
        #expect(NumberStyle.spaceComma.normalize("1 234,5 kr") == "1234.5 kr")
        #expect(NumberStyle.spaceComma.normalize("1\(narrow)234,5") == "1234.5")
        #expect(NumberStyle.apostrophePoint.normalize("CHF 1’234.50") == "CHF 1234.50")
        #expect(NumberStyle.apostrophePoint.normalize("1'234.50") == "1234.50")
        #expect(NumberStyle.commaPoint.normalize("$1,250,000") == "$1250000")
        #expect(NumberStyle.indian.normalize("₹12,34,567") == "₹1234567")
        #expect(NumberStyle.commaPoint.normalize("2027-03") == "2027-03")
        #expect(NumberStyle.commaPoint.normalize("1e+20") == "1e+20")
    }

    @Test("Each currency's own style, and the style a scenario chooses for it")
    func writings() throws {
        #expect(Currency.usd.regional.amount("1,234") == "$1,234")
        #expect(Currency.eur.regional.amount(Currency.eur.regional.numbers.localize("1,234"), negative: true) == "−1.234\(nbsp)€")
        let francs = try #require(Currency(code: "CHF")).regional
        #expect(francs.amount(francs.numbers.localize("1,234.5")) == "CHF\(nbsp)1’234.5")
        let kronor = try #require(Currency(code: "SEK")).regional
        #expect(kronor.amount(kronor.numbers.localize("1,234")) == "1\(narrow)234\(nbsp)kr")
        let reais = try #require(Currency(code: "BRL")).regional
        #expect(reais.amount(reais.numbers.localize("1,234.5")) == "R$\(nbsp)1.234,5")
        #expect(try #require(Currency(code: "CAD")).regional.symbol == "$")
        #expect(try #require(Currency(code: "INR")).regional.numbers == .indian)
        // In a style of the scenario's choosing, the symbol that tells it apart, placed that style's way.
        let canadian = try #require(Currency(code: "CAD")).writing(.pointComma)
        #expect(canadian.amount("1.234") == "1.234\(nbsp)CA$")
        #expect(Currency.eur.writing(.commaPoint).amount("1,234") == "€1,234")
        #expect(Currency.gbp.writing(nil) == Currency.gbp.regional)
        // Local symbols are typed too.
        #expect(try #require(Currency(code: "SEK")).answers(to: "kr"))
        #expect(Currency.split("500kr")?.unit == "kr")
    }
}
