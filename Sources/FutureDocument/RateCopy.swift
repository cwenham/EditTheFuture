import Foundation
import FutureEngine

/// The copy of a scenario's exchange rates kept in `readings/` (docs/DESIGN.md, 5.11), so the
/// scenario opens with them offline: CSV with a date column and a column for each currency,
/// holding how many of it one US dollar bought. An empty cell means no rate then.
public enum RateCopy {
    /// The daily rates' copy, and the latest live rates' copy, in the scenario folder.
    public static let path = "readings/exchange-rates.csv"
    public static let livePath = "readings/exchange-rates-live.csv"

    public static func text(_ rates: ExchangeRates) -> String {
        let currencies = rates.series.keys.sorted { $0.code < $1.code }
        var byTime: [Date: [Currency: Double]] = [:]
        for (currency, series) in rates.series {
            for (time, rate) in zip(series.times, series.perDollar) { byTime[time, default: [:]][currency] = rate }
        }
        var lines = [(["date"] + currencies.map(\.code)).joined(separator: ",")]
        for time in byTime.keys.sorted() {
            let row = byTime[time]!
            lines.append(([FileDate.text(time)] + currencies.map { row[$0].map { FileNumber.text($0) } ?? "" })
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a copy. Columns that aren't currency codes are left out.
    public static func parse(_ text: String) throws -> ExchangeRates {
        var rates: [Currency: [(time: Date, rate: Double)]] = [:]
        for reading in try CSVReadings.parse(text) {
            guard let currency = Currency(code: reading.variable) else { continue }
            rates[currency, default: []].append((reading.time, reading.value))
        }
        return ExchangeRates(perDollar: rates)
    }
}
