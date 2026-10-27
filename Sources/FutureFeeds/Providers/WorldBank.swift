import Foundation
import FutureDocument
import FutureEngine

/// The World Bank's indicators for every country: inflation, migration, government debt,
/// population, and disease such as tuberculosis and malaria. Mostly yearly. Open to everyone.
public struct WorldBankProvider: FeedProvider {
    public let id = "worldbank"
    public let name = "World Bank"
    public let summary = "Indicators for every country: inflation, migration, debt, population, health. Mostly yearly."
    public let website = URL(string: "https://data.worldbank.org")!
    public let refresh = StepRate.days(7)
    public let signIn = FeedSignIn.open

    public let fields = [
        FeedField("indicator", "Indicator", placeholder: "FP.CPI.TOTL.ZG",
                  help: "The indicator's code, from its page on data.worldbank.org."),
        FeedField("country", "Country", placeholder: "USA",
                  help: "A three-letter country code (USA, GBR, DEU, IND), or WLD for the world.", choices: [
            .init("WLD", "World"), .init("USA", "United States"), .init("GBR", "United Kingdom"), .init("DEU", "Germany"),
            .init("FRA", "France"), .init("JPN", "Japan"), .init("CHN", "China"), .init("IND", "India"),
            .init("BRA", "Brazil"), .init("CAN", "Canada"), .init("AUS", "Australia"), .init("MEX", "Mexico"),
            .init("NGA", "Nigeria"), .init("ZAF", "South Africa"), .init("EUU", "European Union"),
        ]),
    ]

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["api.worldbank.org"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let country = try context.required("country")
        let indicator = try context.required("indicator")
        guard country.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ";" }),
              indicator.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else {
            throw FeedError("Country and indicator codes are letters, digits and dots, like USA and FP.CPI.TOTL.ZG.")
        }
        let years = context.earliest.map { "\(FeedDate.year($0)):\(FeedDate.year(context.now) + 1)" }
        return [try FeedProviders.request("https://api.worldbank.org/v2/country/\(country)/indicator/\(indicator)", [
            ("format", "json"), ("per_page", "20000"), ("date", years),
        ])]
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        guard let list = json as? [Any] else { throw FeedError("The World Bank's answer wasn't a list.") }
        if let message = JSONPath.value("0.message.0.value", in: list) as? String {
            throw FeedError("The World Bank said: \(message). Check the country and indicator codes.")
        }
        guard list.count >= 2 else { return FeedPage(points: []) }
        guard let rows = list[1] as? [[String: Any]] else { return FeedPage(points: []) }
        // "2024", "2024M03" or "2024Q2".
        return FeedPage(points: rows.compactMap { row in
            guard let date = (row["date"] as? String).flatMap(FeedDate.parse), let value = FeedNumber.parse(row["value"]) else { return nil }
            return FeedPoint(time: date, value: value)
        })
    }
}
