import Foundation
import Testing
@testable import FutureEngine

/// A price that stays at `price`, marked as money.
struct PriceModel: TimelineModel {
    var price = 100.0
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Price", stepRate: .monthly,
                        variables: [Variable(name: "price", causality: .output, quantity: .currency)])
    }
    func start(_ context: StepContext) throws -> Double { price }
    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] { [] }
    func values(of state: Double) -> [String: Double] { ["price": state] }
}

@Suite("Exchange rates")
struct ExchangeRateTests {
    let pound = Currency.gbp, euro = Currency.eur

    /// Pounds per dollar: 0.8 from 2024, 0.75 from June. Euros per dollar: 0.9 throughout.
    var rates: ExchangeRates {
        ExchangeRates(perDollar: [
            pound: [(utc(2024, 6, 1), 0.75), (utc(2024, 1, 1), 0.8)],
            euro: [(utc(2024, 1, 1), 0.9)],
            .usd: [(utc(2024, 1, 1), 2)],  // ignored: a dollar is a dollar
        ])
    }

    @Test("Rates hold between their times, before the first and after the last, and cross through dollars")
    func holding() throws {
        let rates = self.rates
        #expect(rates.covers(.usd) && rates.covers(pound) && !rates.covers(.jpy))
        #expect(rates.currencies == [.usd, pound, euro])
        #expect(rates.perDollar(pound, at: utc(1990, 1, 1)) == 0.8)
        #expect(rates.perDollar(pound, at: utc(2024, 5, 31)) == 0.8)
        #expect(rates.perDollar(pound, at: utc(2024, 6, 1)) == 0.75)
        #expect(rates.perDollar(pound, at: utc(2100, 1, 1)) == 0.75)
        #expect(rates.rate(from: .usd, to: pound, at: utc(2025, 1, 1)) == 0.75)
        #expect(rates.rate(from: pound, to: .usd, at: utc(2025, 1, 1)) == 1 / 0.75)
        #expect(abs(try #require(rates.rate(from: pound, to: euro, at: utc(2024, 2, 1))) - 0.9 / 0.8) < 1e-12)
        #expect(rates.rate(from: pound, to: pound, at: utc(2024, 2, 1)) == 1)
        #expect(rates.rate(from: .jpy, to: pound, at: utc(2024, 2, 1)) == nil)
        #expect(rates.latest(pound)?.time == utc(2024, 6, 1))
        let odd = ExchangeRates(perDollar: [pound: [(utc(2024, 1, 1), .nan), (utc(2024, 2, 1), -1), (utc(2024, 3, 1), 0)]])
        #expect(!odd.covers(pound))
    }

    @Test("Merging keeps the newer rate at the same time; changes are found from where they start")
    func merging() {
        let rates = self.rates
        let newer = ExchangeRates(perDollar: [pound: [(utc(2024, 6, 1), 0.7), (utc(2024, 9, 1), 0.72)]])
        let merged = rates.merged(with: newer)
        #expect(merged.series[pound]?.times == [utc(2024, 1, 1), utc(2024, 6, 1), utc(2024, 9, 1)])
        #expect(merged.series[pound]?.perDollar == [0.8, 0.7, 0.72])
        #expect(merged.series[euro] == rates.series[euro])

        #expect(merged.firstDifference(from: rates, in: [pound]) == utc(2024, 6, 1))
        #expect(merged.firstDifference(from: rates, in: [euro, .usd]) == nil)
        // A new first rate reaches back before every date; a currency that's new too.
        let earlier = ExchangeRates(perDollar: [pound: [(utc(2023, 1, 1), 0.85), (utc(2024, 1, 1), 0.8), (utc(2024, 6, 1), 0.75)]])
        #expect(earlier.firstDifference(from: rates, in: [pound]) == .distantPast)
        #expect(rates.firstDifference(from: .none, in: [pound]) == .distantPast)
        // A rate added at the end changes things from then on.
        let longer = rates.merged(with: ExchangeRates(perDollar: [pound: [(utc(2025, 1, 1), 0.78)]]))
        #expect(longer.firstDifference(from: rates, in: [pound]) == utc(2025, 1, 1))
        #expect(rates.only([pound]).currencies == [.usd, pound])
    }

    func scenario(shop: Currency? = .usd, reader: Currency? = .gbp, price: Double = 100) throws -> (Scenario, SlotID, SlotID) {
        let scenario = Scenario(start: utc(2024, 1, 1))
        let shopID = try scenario.addSlot("Shop", model: PriceModel(price: price), currency: shop)
        let readerID = try scenario.addSlot("Wallet", model: Observer(source: Reference(slot: "Shop", variable: "price")),
                                            currency: reader)
        try scenario.validate()
        return (scenario, shopID, readerID)
    }

    @Test("Money read from a slot in another currency is converted at each step's rate")
    func converts() throws {
        let (scenario, _, reader) = try scenario()
        scenario.setExchangeRates(rates)
        #expect(try scenario.conversions(into: reader) == [CurrencyPair(from: .usd, to: pound)])
        #expect(try scenario.value("seen", of: reader, at: utc(2024, 3, 1)) == 80)
        #expect(try scenario.value("seen", of: reader, at: utc(2024, 7, 1)) == 75)
        #expect(try scenario.value("seen", of: reader, at: utc(2060, 1, 1)) == 75)  // the latest holds
        // The start converts too.
        #expect(try scenario.value("seen", of: reader, at: utc(2024, 1, 1)) == 80)
    }

    @Test("Nothing is converted between the same currency, without currencies, or for values that aren't money")
    func leavesAlone() throws {
        for (shop, reader) in [(Currency?.some(.gbp), Currency?.some(.gbp)), (nil, .gbp), (.usd, nil)] {
            let (scenario, _, id) = try scenario(shop: shop, reader: reader)
            scenario.setExchangeRates(rates)
            #expect(try scenario.conversions(into: id).isEmpty)
            #expect(try scenario.value("seen", of: id, at: utc(2024, 7, 1)) == 100)
        }
        let scenario = Scenario(start: utc(2024, 1, 1))
        try scenario.addSlot("Counter", model: CounterModel(), currency: .usd)
        let id = try scenario.addSlot("Wallet", model: Observer(source: Reference(slot: "Counter", variable: "count")), currency: pound)
        scenario.setExchangeRates(rates)
        #expect(try scenario.conversions(into: id).isEmpty)
        #expect(try scenario.value("seen", of: id, at: utc(2024, 4, 1)) == 3)
    }

    @Test("Without a rate, the step fails and says which")
    func missingRate() throws {
        let (scenario, _, reader) = try scenario(reader: .jpy)
        scenario.setExchangeRates(rates)
        #expect(throws: EngineError.noExchangeRate(slot: "Wallet", from: "USD", to: "JPY")) {
            try scenario.value("seen", of: reader, at: utc(2024, 3, 1))
        }
    }

    @Test("New rates compute again only the slots that convert, from where the rates changed")
    func newRates() throws {
        let (scenario, shop, reader) = try scenario()
        scenario.setExchangeRates(rates)
        try scenario.ensure(reader, through: utc(2028, 1, 1))
        #expect(scenario.computedThrough(shop) == utc(2028, 1, 1))

        scenario.setExchangeRates(rates.merged(with: ExchangeRates(perDollar: [pound: [(utc(2027, 3, 1), 0.7)]])))
        #expect(scenario.computedThrough(shop) == utc(2028, 1, 1))  // the producer keeps its results
        // Back to the last checkpoint before the change (every 32 steps), not the start.
        let kept = try #require(scenario.computedThrough(reader))
        #expect(kept < utc(2027, 3, 1) && kept >= utc(2026, 9, 1))
        #expect(try scenario.value("seen", of: reader, at: utc(2027, 2, 1)) == 75)
        #expect(abs(try scenario.value("seen", of: reader, at: utc(2027, 4, 1)) - 70) < 1e-9)

        // Rates for currencies it doesn't convert change nothing.
        try scenario.ensure(reader, through: utc(2028, 1, 1))
        scenario.setExchangeRates(scenario.exchangeRates.merged(with: ExchangeRates(perDollar: [.jpy: [(utc(2024, 1, 1), 150)]])))
        #expect(scenario.computedThrough(reader) == utc(2028, 1, 1))
    }

    @Test("A slot's new currency computes again the slots whose conversion changed")
    func newCurrency() throws {
        let (scenario, shop, reader) = try scenario()
        scenario.setExchangeRates(rates)
        try scenario.ensure(reader, through: utc(2025, 1, 1))
        scenario.setCurrency(pound, of: shop)
        #expect(scenario.computedThrough(shop) == utc(2025, 1, 1))
        #expect(try scenario.conversions(into: reader).isEmpty)
        #expect(try scenario.value("seen", of: reader, at: utc(2024, 7, 1)) == 100)
        scenario.setCurrency(euro, of: reader)
        #expect(try scenario.conversions(into: reader) == [CurrencyPair(from: pound, to: euro)])
        #expect(abs(try scenario.value("seen", of: reader, at: utc(2024, 7, 1)) - 100 * 0.9 / 0.75) < 1e-9)
    }
}
