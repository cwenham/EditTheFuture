import Foundation
import FutureDocument
import FutureEngine

/// Tiingo's end-of-day prices for US and Chinese stocks, ETFs and mutual funds, back decades.
/// Needs a key, which is free for personal use.
public struct TiingoProvider: FeedProvider {
    public let id = "tiingo"
    public let name = "Tiingo"
    public let summary = "Daily closing prices for stocks, ETFs and mutual funds. A free key for personal use."
    public let website = URL(string: "https://www.tiingo.com")!
    public let refresh = StepRate.days(1)

    public let fields = [
        FeedField("symbol", "Symbol", placeholder: "SPY", help: "The ticker, such as SPY, VTI or AAPL."),
        FeedField("price", "Price", placeholder: "close", required: false, choices: [
            .init("close", "Close"),
            .init("adjClose", "Close, adjusted for splits and dividends"),
        ]),
    ]

    public let signIn = FeedSignIn(
        .required, signUp: URL(string: "https://www.tiingo.com/account/api/token"),
        note: "Needs a key. It's free for personal use.")

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["api.tiingo.com"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let symbol = try context.required("symbol")
        guard symbol.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            throw FeedError("“\(symbol)” isn't a ticker symbol.")
        }
        let start = context.earliest ?? CivilDate.date(year: 1950, month: 1, day: 1)
        var request = try FeedProviders.request("https://api.tiingo.com/tiingo/daily/\(symbol.lowercased())/prices", [
            ("startDate", FeedDate.day(start)), ("format", "json"),
        ])
        if let credential = context.credential {
            request.setValue("Token " + credential.secret, forHTTPHeaderField: "Authorization")
        }
        return [request]
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        guard let rows = json as? [[String: Any]] else {
            throw FeedError("Tiingo said: " + (FeedProviders.commonErrorMessage(data) ?? "something unexpected."))
        }
        let price = context["price"] ?? "close"
        return FeedPage(points: rows.compactMap { row in
            guard let date = (row["date"] as? String).flatMap(FeedDate.parse), let value = FeedNumber.parse(row[price]) else { return nil }
            return FeedPoint(time: date, value: value)
        })
    }
}
