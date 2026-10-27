import Foundation
import FutureDocument
import FutureEngine

/// FRED, the Federal Reserve Bank of St. Louis's economic data: market indexes, Treasury yields,
/// mortgage rates, consumer prices, federal debt and over 800,000 other series.
///
/// Without a key it reads the CSV download every series page offers. With a free key it uses the
/// API, which says more when something's wrong.
public struct FREDProvider: FeedProvider {
    public let id = "fred"
    public let name = "FRED"
    public let summary = "Federal Reserve Bank of St. Louis: markets, rates, prices, debt and 800,000 other US and world series."
    public let website = URL(string: "https://fred.stlouisfed.org")!
    public let refresh = StepRate.days(1)

    public let fields = [
        FeedField("series", "Series", placeholder: "DGS10",
                  help: "The series' ID, at the end of its page's address on fred.stlouisfed.org."),
        FeedField("units", "Units", placeholder: "As published", required: false, choices: [
            .init("lin", "As published"),
            .init("chg", "Change"),
            .init("ch1", "Change from a year ago"),
            .init("pch", "Percent change"),
            .init("pc1", "Percent change from a year ago"),
            .init("pca", "Compounded annual rate of change"),
        ]),
    ]

    public let signIn = FeedSignIn(
        .optional, signUp: URL(string: "https://fredaccount.stlouisfed.org/apikeys"),
        note: "Works without a key, through FRED's CSV download. A free key uses FRED's API instead.")

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["api.stlouisfed.org"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let series = try context.required("series")
        let units = context["units"].flatMap { $0 == "lin" ? nil : $0 }
        let start = context.earliest.map(FeedDate.day)
        if let credential = context.credential {
            return [try FeedProviders.request("https://api.stlouisfed.org/fred/series/observations", [
                ("series_id", series), ("api_key", credential.secret), ("file_type", "json"),
                ("observation_start", start), ("units", units),
            ])]
        }
        return [try FeedProviders.request("https://fred.stlouisfed.org/graph/fredgraph.csv", [
            ("id", series), ("cosd", start), ("transformation", units),
        ])]
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        if request.url?.host == "api.stlouisfed.org" {
            let json = try JSONPath.decode(data)
            guard let rows = JSONPath.value("observations", in: json) as? [[String: Any]] else {
                throw FeedError("FRED's answer had no observations.")
            }
            return FeedPage(points: rows.compactMap { row in
                guard let date = (row["date"] as? String).flatMap(FeedDate.parse), let value = FeedNumber.parse(row["value"])
                else { return nil }
                return FeedPoint(time: date, value: value)
            })
        }
        // observation_date,DGS10 (older downloads say DATE).
        let table = try FeedTable(String(decoding: data, as: UTF8.self))
        guard table.columns.count >= 2 else { throw FeedError("FRED's CSV had no values.") }
        return FeedPage(points: table.rows.compactMap { row in
            guard let date = table.field(row, 0).flatMap(FeedDate.parse), let value = table.field(row, 1).flatMap(FeedNumber.parse)
            else { return nil }
            return FeedPoint(time: date, value: value)
        })
    }

    public func errorMessage(_ data: Data, status: Int) -> String? {
        if status == 404 { return "there's no series with that ID" }
        return FeedProviders.commonErrorMessage(data)
    }
}
