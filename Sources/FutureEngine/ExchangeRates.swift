import Foundation

/// Where a scenario's exchange rates come from (docs/DESIGN.md, 5.11): what `rates:` in its
/// heading says.
public enum ExchangeRateSource: String, Sendable, Hashable, CaseIterable {
    /// The European Central Bank's daily reference rates, from 1999, through Frankfurter. Free.
    case ecb
    /// The ECB's for the past, with the latest from Open Exchange Rates, which needs a key.
    case openexchangerates
    /// Nothing is converted: money passes between slots as it is.
    case none

    /// Whether it brings the latest rates, as well as the daily ones.
    public var isLive: Bool { self == .openexchangerates }
}

/// Two currencies, for converting money that one slot reads from another.
public struct CurrencyPair: Hashable, Sendable, CustomStringConvertible {
    public let from: Currency
    public let to: Currency

    public init(from: Currency, to: Currency) {
        self.from = from
        self.to = to
    }

    public var description: String { "\(from.code)→\(to.code)" }
}

/// Exchange rates over time: for each currency, how many of it one US dollar buys, at the times
/// the source gave (docs/DESIGN.md, 5.11). Between those times a rate holds; before the first
/// one the first is used, and after the last one, the last.
public struct ExchangeRates: Sendable, Equatable {
    /// One currency's rates, in time order.
    public struct Series: Sendable, Equatable {
        public let times: [Date]
        /// How many of the currency one US dollar buys, at each time.
        public let perDollar: [Double]

        /// The rate at a time, held from the latest one at or before it.
        func value(at date: Date) -> Double {
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] <= date { low = mid + 1 } else { high = mid }
            }
            return perDollar[max(low - 1, 0)]
        }
    }

    /// By currency. US dollars aren't listed: one dollar is always one dollar.
    public let series: [Currency: Series]

    public static let none = ExchangeRates(series: [:])

    private init(series: [Currency: Series]) {
        self.series = series
    }

    /// Rates by currency, in any order. Rates that aren't finite and above zero are left out, and
    /// of two at the same time the later in the list wins. US dollars are ignored.
    public init(perDollar rates: [Currency: [(time: Date, rate: Double)]]) {
        var series: [Currency: Series] = [:]
        for (currency, points) in rates where currency != .usd {
            var byTime: [Date: Double] = [:]
            for point in points where point.rate.isFinite && point.rate > 0 { byTime[point.time] = point.rate }
            guard !byTime.isEmpty else { continue }
            let times = byTime.keys.sorted()
            series[currency] = Series(times: times, perDollar: times.map { byTime[$0]! })
        }
        self.init(series: series)
    }

    /// The currencies it has rates for, US dollars included.
    public var currencies: Set<Currency> { Set(series.keys).union([.usd]) }

    /// Whether it can convert to and from a currency.
    public func covers(_ currency: Currency) -> Bool { currency == .usd || series[currency] != nil }

    /// How many of `currency` one US dollar bought at `date`.
    public func perDollar(_ currency: Currency, at date: Date) -> Double? {
        if currency == .usd { return 1 }
        return series[currency]?.value(at: date)
    }

    /// How many of `to` one of `from` bought at `date`, through US dollars. nil without rates for both.
    public func rate(from: Currency, to: Currency, at date: Date) -> Double? {
        if from == to { return 1 }
        guard let toRate = perDollar(to, at: date), let fromRate = perDollar(from, at: date) else { return nil }
        return toRate / fromRate
    }

    /// The latest time there's a rate for a currency, with the rate.
    public func latest(_ currency: Currency) -> (time: Date, perDollar: Double)? {
        guard let series = series[currency], let time = series.times.last else { return nil }
        return (time, series.perDollar.last!)
    }

    /// These rates with `newer`'s added: where both have a rate at the same time, `newer`'s wins.
    public func merged(with newer: ExchangeRates) -> ExchangeRates {
        var rates: [Currency: [(time: Date, rate: Double)]] = [:]
        for (currency, series) in series { rates[currency] = Array(zip(series.times, series.perDollar)).map { ($0, $1) } }
        for (currency, series) in newer.series {
            rates[currency, default: []] += Array(zip(series.times, series.perDollar)).map { ($0, $1) }
        }
        return ExchangeRates(perDollar: rates)
    }

    /// Only these currencies' rates.
    public func only(_ currencies: Set<Currency>) -> ExchangeRates {
        ExchangeRates(series: series.filter { currencies.contains($0.key) })
    }

    /// The first time any of `currencies` converts differently here than in `old`: from then on,
    /// slots that convert with them need computing again. `distantPast` when the change reaches
    /// back before every rate, nil when nothing changed.
    public func firstDifference(from old: ExchangeRates, in currencies: Set<Currency>) -> Date? {
        var earliest: Date?
        for currency in currencies where currency != .usd {
            let a = old.series[currency], b = series[currency]
            guard a != b else { continue }
            guard let a, let b else { return .distantPast }
            var index = 0
            while index < a.times.count, index < b.times.count, a.times[index] == b.times[index], a.perDollar[index] == b.perDollar[index] {
                index += 1
            }
            // The first rate also covers everything before it.
            guard index > 0 else { return .distantPast }
            let changed = [a.times.indices.contains(index) ? a.times[index] : nil,
                           b.times.indices.contains(index) ? b.times[index] : nil].compactMap { $0 }.min()
            if let changed { earliest = min(earliest ?? changed, changed) }
        }
        return earliest
    }
}
