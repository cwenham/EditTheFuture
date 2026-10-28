import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

// Exchange rates and the way money is written, as the store works them out for its slots
// (docs/DESIGN.md, 5.11; docs/UI.md, 5.7).

/// What the scenario says about money, for building its slots.
struct ScenarioMoney: Sendable {
    /// Its currency, for slots without one of their own.
    var currency: Currency
    /// How numbers are written: nil for each currency in its own style.
    var numbers: NumberStyle?
    /// Whether money read from a slot in another currency is converted (`rates:` isn't `none`).
    var converts: Bool
    var rates: ExchangeRates

    static let plain = ScenarioMoney(currency: .usd, numbers: nil, converts: true, rates: .none)
}

/// Money a slot reads from a slot in another currency, converted as it's read.
public struct SlotConversion: Sendable, Equatable {
    /// The slot it's read from, and the value: "IndexFund", "value".
    public let slot: String
    public let variable: String
    public let pair: CurrencyPair

    /// "IndexFund.value".
    public var reading: String { slot + "." + variable }
}

/// Where the scenario's rates are: fetching, when they were last checked, and what went wrong.
public struct RateStatus: Sendable, Equatable {
    public var isFetching = false
    /// When the daily rates, and the live ones, were last fetched or found up to date.
    public var checked: Date?
    public var liveChecked: Date?
    /// Why the last fetch failed.
    public var error: String?

    public init() {}
}

extension ScenarioStore {
    /// What each slot reads in another currency (docs/DESIGN.md, 5.11): an input that reads a
    /// value marked as currency from a slot whose currency isn't the reading slot's. The engine
    /// works this out the same way.
    nonisolated static func conversions(_ configs: [SlotConfig], descriptors: [ModelDescriptor?],
                                        currencies: [Currency]) -> [[SlotConversion]] {
        let index = Dictionary(configs.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return configs.indices.map { reader in
            guard let descriptor = descriptors[reader] else { return [] }
            var list: [SlotConversion] = []
            for input in descriptor.inputs {
                guard let source = input.source, let from = index[source.slot], from != reader,
                      currencies[from] != currencies[reader],
                      descriptors[from]?.variable(named: source.variable)?.quantity == .currency else { continue }
                let conversion = SlotConversion(slot: source.slot, variable: source.variable,
                                                pair: CurrencyPair(from: currencies[from], to: currencies[reader]))
                if !list.contains(conversion) { list.append(conversion) }
            }
            return list
        }
    }

    /// How each currency in use is written. In each currency's own style, a symbol two of them
    /// share ("$" for US and Canadian dollars, "kr" for Swedish and Norwegian kronor) gives way to
    /// the one that tells them apart ("CA$", "SEK").
    nonisolated static func writings(for currencies: Set<Currency>, numbers: NumberStyle?) -> [Currency: MoneyWriting] {
        var writings: [Currency: MoneyWriting] = [:]
        for currency in currencies { writings[currency] = currency.writing(numbers) }
        guard numbers == nil else { return writings }
        let bySymbol = Dictionary(grouping: currencies) { $0.localSymbol.lowercased() }
        for (_, sharing) in bySymbol where sharing.count > 1 {
            for currency in sharing { writings[currency] = currency.regional.withSymbol(currency.symbol) }
        }
        return writings
    }

    /// Why a slot waits, when it needs rates the scenario doesn't have yet.
    nonisolated static func waitingReason(_ conversions: [SlotConversion], rates: ExchangeRates) -> String? {
        guard let missing = conversions.first(where: { !rates.covers($0.pair.from) || !rates.covers($0.pair.to) }) else {
            return nil
        }
        return "Waiting for exchange rates from \(missing.pair.from.plural) to \(missing.pair.to.plural), "
            + "to convert \(missing.reading)."
    }

    // MARK: Rates

    /// The currencies the slots convert between, US dollars left out: what needs rates.
    public var neededCurrencies: Set<Currency> {
        Set(slots.flatMap { $0.conversions.flatMap { [$0.pair.from, $0.pair.to] } }).subtracting([.usd])
    }

    /// New exchange rates, from the copy in `readings/` or a fetch. Slots that convert are
    /// computed again from where their rates changed. A slot waiting for rates it now has runs.
    public func receiveExchangeRates(_ rates: ExchangeRates) {
        guard rates != exchangeRates else { return }
        let needed = neededCurrencies
        let coverageChanged = needed.contains { rates.covers($0) != exchangeRates.covers($0) }
        exchangeRates = rates
        sendExchangeRates(rates, rebuildingSlots: coverageChanged)
    }

    public func setRateStatus(_ status: RateStatus) {
        if rateStatus != status { rateStatus = status }
    }

    /// What the Slot tab says about a slot's conversions: "Reads IndexFund.value in US dollars,
    /// converted to British pounds at the ECB's daily rates. $1 = £0.7526 on 28 Oct 2026."
    public func conversionNote(forSlotAt index: Int) -> String? {
        guard slots.indices.contains(index) else { return nil }
        let slot = slots[index]
        guard let first = slot.conversions.first else { return nil }
        let readings = slot.conversions.map(\.reading)
        let what = readings.count == 1 ? readings[0] : readings.dropLast().joined(separator: ", ") + " and " + readings.last!
        let froms = Set(slot.conversions.map(\.pair.from))
        let source = rateSource.isLive ? "the latest rates from Open Exchange Rates, and the ECB's before them"
            : "the European Central Bank's daily rates"
        var note = "Reads \(what) in \(froms.count == 1 ? first.pair.from.plural : "other currencies"), converted to "
            + "\(slot.currency.plural) at \(source)."
        for pair in Set(slot.conversions.map(\.pair)).sorted(by: { $0.from.code < $1.from.code }) {
            guard let latest = latestRate(pair) else { continue }
            let one = slots.first { $0.currency == pair.from }?.money ?? ValueStyle.money(pair.from)
            // Spaces that don't break, so the rate stays on one line.
            note += " \(one.with(.currency).amountText(1))\u{00A0}=\u{00A0}\(slot.money.amountText(latest.rate, digits: 4)) on \(DateText.dayMonthYear(latest.time))."
            if let history = exchangeRates.series[pair.from == .usd ? pair.to : pair.from], history.times.count == 1 {
                note += " There are no earlier rates, so this one is used for every date."
            }
        }
        return note
    }

    /// The latest rate between two currencies, and when it's from.
    func latestRate(_ pair: CurrencyPair) -> (rate: Double, time: Date)? {
        let times = [pair.from, pair.to].filter { $0 != .usd }.compactMap { exchangeRates.latest($0)?.time }
        guard let time = times.max(), let rate = exchangeRates.rate(from: pair.from, to: pair.to, at: time) else { return nil }
        return (rate, time)
    }
}

extension ValueStyle {
    /// An amount of money with decimals, for rates and examples: "£0.7526", "1.234,56 €".
    func amountText(_ value: Double, digits: Int = 0) -> String {
        let fixed = String(format: "%.\(max(digits, 0))f", abs(value))
        let parts = fixed.split(separator: ".", maxSplits: 1)
        var number = ValueFormat.grouped(Double(parts[0]) ?? 0)
        if parts.count > 1 { number += "." + parts[1] }
        return writing.amount(writing.numbers.localize(number), negative: value < 0)
    }
}
