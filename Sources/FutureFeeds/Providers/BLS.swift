import Foundation
import FutureDocument
import FutureEngine

/// The US Bureau of Labor Statistics: consumer prices (CPI), wages, jobs and producer prices.
///
/// Without a key it uses version 1 of the API: 10 years a request and 25 requests a day. A free
/// key uses version 2: 20 years a request and 500 a day. The key goes in the request's body.
public struct BLSProvider: FeedProvider {
    public let id = "bls"
    public let name = "US Bureau of Labor Statistics"
    public let summary = "Consumer prices (CPI), wages, jobs and producer prices, mostly monthly."
    public let website = URL(string: "https://www.bls.gov/data/")!
    public let refresh = StepRate.days(1)

    public let fields = [
        FeedField("series", "Series", placeholder: "CUUR0000SA0",
                  help: "The series ID from data.bls.gov, such as CUUR0000SA0 for all-items CPI.", choices: [
            .init("CUUR0000SA0", "CPI, all items (CPI-U)"),
            .init("CUUR0000SA0L1E", "CPI, all items less food and energy"),
            .init("CUUR0000SAF1", "CPI, food"),
            .init("CUUR0000SA0E", "CPI, energy"),
            .init("CUUR0000SEHA", "CPI, rent of primary residence"),
            .init("LNS14000000", "Unemployment rate"),
        ]),
    ]

    public let signIn = FeedSignIn(
        .optional, signUp: URL(string: "https://data.bls.gov/registrationEngine/"),
        note: "Works without a key, 10 years a request and 25 requests a day. A free key allows 20 years a request and 500 a day.")

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["api.bls.gov"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let series = try context.required("series")
        let last = FeedDate.year(context.now)
        // Without a date, the last 30 years: three requests without a key.
        let first = context.earliest.map(FeedDate.year) ?? last - 29
        let span = context.credential == nil ? 10 : 20
        var requests: [URLRequest] = []
        var year = max(first, 1913)
        while year <= last {
            let end = min(year + span - 1, last)
            if let credential = context.credential {
                var request = try FeedProviders.request("https://api.bls.gov/publicAPI/v2/timeseries/data/")
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "seriesid": [series], "startyear": String(year), "endyear": String(end), "registrationkey": credential.secret,
                ])
                requests.append(request)
            } else {
                requests.append(try FeedProviders.request("https://api.bls.gov/publicAPI/v1/timeseries/data/\(series)", [
                    ("startyear", String(year)), ("endyear", String(end)),
                ]))
            }
            year = end + 1
        }
        return requests
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        let status = JSONPath.value("status", in: json) as? String
        if status != "REQUEST_SUCCEEDED" {
            let messages = (JSONPath.value("message", in: json) as? [String]) ?? []
            throw FeedError("BLS said: " + (messages.first ?? status ?? "the request failed."))
        }
        guard let rows = JSONPath.value("Results.series.0.data", in: json) as? [[String: Any]] else {
            throw FeedError("BLS's answer had no data.")
        }
        return FeedPage(points: rows.compactMap { row in
            guard let year = (row["year"] as? String).flatMap(Int.init), let period = row["period"] as? String,
                  let month = Self.month(period), let value = FeedNumber.parse(row["value"]) else { return nil }
            return FeedPoint(time: CivilDate.date(year: year, month: month, day: 1), value: value)
        })
    }

    /// The first month of a BLS period: M01–M12, Q01–Q04, S01–S02 or A01. M13, the yearly
    /// average, is left out.
    static func month(_ period: String) -> Int? {
        guard period.count == 3, let number = Int(period.dropFirst()) else { return nil }
        switch period.first {
        case "M": return (1...12).contains(number) ? number : nil
        case "Q": return (1...4).contains(number) ? (number - 1) * 3 + 1 : nil
        case "S": return (1...2).contains(number) ? (number - 1) * 6 + 1 : nil
        case "A": return number == 1 ? 1 : nil
        default: return nil
        }
    }
}
