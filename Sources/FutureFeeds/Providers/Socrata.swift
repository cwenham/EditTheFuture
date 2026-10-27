import Foundation
import FutureDocument
import FutureEngine

/// Open data portals built on Socrata, such as the CDC's data.cdc.gov and many cities' and states'.
/// A feed names a dataset, its date column and its value column, which can add up rows, such as
/// `avg(site_wval)` for an average across sites. Open to everyone; an app token raises the limits.
public struct SocrataProvider: FeedProvider {
    public let id = "socrata"
    public let name = "Open data portal (Socrata)"
    public let summary = "Datasets on open data portals such as the CDC's data.cdc.gov, and many cities' and states'."
    public let website = URL(string: "https://data.cdc.gov")!
    public let refresh = StepRate.days(1)
    public static let pageSize = 50_000

    public let fields = [
        FeedField("domain", "Portal", placeholder: "data.cdc.gov", required: false),
        FeedField("dataset", "Dataset", placeholder: "vutn-jzwm",
                  help: "The dataset's ID: the nine characters like vutn-jzwm in its address."),
        FeedField("date", "Date column", placeholder: "week_end"),
        FeedField("value", "Value column", placeholder: "percent_visits",
                  help: "A column, or a sum across rows, such as avg(site_wval) or sum(cases)."),
        FeedField("where", "Filter", placeholder: "geography = 'California'",
                  help: "Which rows, in SoQL: pathogen = 'Influenza' AND geography = 'United States'.", required: false),
    ]

    public let signIn = FeedSignIn(
        .optional, kinds: [.header], signUp: URL(string: "https://support.socrata.com/hc/en-us/articles/210138558"),
        note: "Works without one. An app token, sent in the X-App-Token header, raises the limits.")

    public init() {}

    func domain(_ spec: FeedSpec) -> String {
        let value = spec["domain"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "data.cdc.gov" : value.lowercased()
    }

    public func hosts(for spec: FeedSpec) -> [String] { [domain(spec)] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        [try request(context, offset: 0)]
    }

    func request(_ context: FeedRequestContext, offset: Int) throws -> URLRequest {
        let domain = self.domain(context.spec)
        guard domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }), domain.contains(".") else {
            throw FeedError("“\(domain)” isn't a portal's address, like data.cdc.gov.")
        }
        let dataset = try context.required("dataset")
        guard dataset.count == 9, dataset.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw FeedError("“\(dataset)” isn't a dataset ID. It looks like vutn-jzwm.")
        }
        let date = try Self.column(context.required("date"))
        let value = try context.required("value")
        var conditions: [String] = []
        if let filter = context["where"] { conditions.append("(\(filter))") }
        if let earliest = context.earliest { conditions.append("\(date) >= '\(FeedDate.day(earliest))'") }
        let adds = value.contains("(")
        var request = try FeedProviders.request("https://\(domain)/resource/\(dataset).json", [
            ("$select", "\(date) AS date, \(value) AS value"),
            ("$where", conditions.isEmpty ? nil : conditions.joined(separator: " AND ")),
            ("$group", adds ? date : nil),
            ("$order", date),
            ("$limit", String(Self.pageSize)),
            ("$offset", offset > 0 ? String(offset) : nil),
        ])
        if let credential = context.credential {
            request.setValue(credential.secret, forHTTPHeaderField: credential.kind == .header && !credential.name.isEmpty
                             ? credential.name : "X-App-Token")
        }
        return request
    }

    /// A column's name: letters, digits and underscores, so it can't change the query.
    static func column(_ name: String) throws -> String {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw FeedError("“\(name)” isn't a column's name.")
        }
        return name
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        guard let rows = json as? [[String: Any]] else {
            throw FeedError("The portal said: " + (FeedProviders.commonErrorMessage(data) ?? "something unexpected."))
        }
        let points = rows.compactMap { row -> FeedPoint? in
            guard let date = (row["date"] as? String).flatMap(FeedDate.parse), let value = FeedNumber.parse(row["value"]) else { return nil }
            return FeedPoint(time: date, value: value)
        }
        guard rows.count == Self.pageSize else { return FeedPage(points: points) }
        let offset = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "$offset" }?.value.flatMap(Int.init) ?? 0
        return FeedPage(points: points, next: try self.request(context, offset: offset + Self.pageSize))
    }
}
