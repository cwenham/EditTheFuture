import Foundation
import FutureDocument
import FutureEngine

/// The US Treasury's Fiscal Data API: the debt to the penny, the debt since 1790, average interest
/// rates on Treasury securities, and auction prices and yields. Open to everyone.
public struct TreasuryProvider: FeedProvider {
    public let id = "treasury"
    public let name = "US Treasury Fiscal Data"
    public let summary = "The US national debt, interest rates on Treasury securities, and auction prices and yields."
    public let website = URL(string: "https://fiscaldata.treasury.gov")!
    public let refresh = StepRate.days(1)
    public let signIn = FeedSignIn.open

    public static let base = "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/"
    public static let pageSize = 10_000

    public let fields = [
        FeedField("dataset", "Dataset", placeholder: "v2/accounting/od/debt_to_penny",
                  help: "The endpoint's path, from the dataset's API page on fiscaldata.treasury.gov.", choices: [
            .init("v2/accounting/od/debt_to_penny", "Debt to the penny (daily, since 1993)"),
            .init("v2/accounting/od/debt_outstanding", "Historical debt outstanding (yearly, since 1790)"),
            .init("v2/accounting/od/avg_interest_rates", "Average interest rates on Treasury securities (monthly)"),
            .init("v1/accounting/od/auctions_query", "Treasury securities auctions"),
        ]),
        FeedField("field", "Value", placeholder: "tot_pub_debt_out_amt",
                  help: "The dataset's field with the values, such as tot_pub_debt_out_amt, avg_interest_rate_amt or high_price."),
        FeedField("date", "Date field", placeholder: "record_date", help: "auction_date for auctions.", required: false),
        FeedField("filter", "Filter", placeholder: "security_desc:eq:Treasury Bonds",
                  help: "Fiscal Data's filter: field:eq:value, with commas between several.", required: false),
    ]

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["api.fiscaldata.treasury.gov"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        [try request(context, page: 1)]
    }

    func request(_ context: FeedRequestContext, page: Int) throws -> URLRequest {
        let dataset = try context.required("dataset").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard dataset.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" }) else {
            throw FeedError("“\(dataset)” isn't one of Fiscal Data's endpoints.")
        }
        let field = try context.required("field")
        let date = context["date"] ?? "record_date"
        var filters = context["filter"].map { [$0] } ?? []
        if let earliest = context.earliest { filters.append("\(date):gte:\(FeedDate.day(earliest))") }
        return try FeedProviders.request(Self.base + dataset, [
            ("fields", "\(date),\(field)"),
            ("filter", filters.isEmpty ? nil : filters.joined(separator: ",")),
            ("sort", date),
            ("page[size]", String(Self.pageSize)),
            ("page[number]", String(page)),
        ])
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        guard let rows = JSONPath.value("data", in: json) as? [[String: Any]] else {
            throw FeedError("Fiscal Data's answer had no data.")
        }
        let field = try context.required("field")
        let date = context["date"] ?? "record_date"
        if let first = rows.first, first[field] == nil {
            throw FeedError("The dataset has no field called “\(field)”.")
        }
        let points = rows.compactMap { row -> FeedPoint? in
            guard let time = (row[date] as? String).flatMap(FeedDate.parse), let value = FeedNumber.parse(row[field]) else { return nil }
            return FeedPoint(time: time, value: value)
        }
        // Pages: meta.total-pages, and which page this was.
        let pages = FeedNumber.parse(JSONPath.value("meta.total-pages", in: json)) ?? 1
        let page = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "page[number]" }?.value.flatMap(Int.init) ?? 1
        let next = Double(page) < pages ? try self.request(context, page: page + 1) : nil
        return FeedPage(points: points, next: next)
    }
}
