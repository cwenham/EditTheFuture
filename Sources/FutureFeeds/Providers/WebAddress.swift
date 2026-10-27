import Foundation
import FutureDocument
import FutureEngine

/// The kinds of sign-in a source at any web address can take.
private let anySignIn = FeedSignIn(
    .optional, kinds: [.key, .header, .bearer, .basic],
    note: "Only if the source asks for one. It's sent only to this address's host, over HTTPS.")

/// The web address of a feed at any address, checked: HTTPS, or plain HTTP without a sign-in.
private func address(_ context: FeedRequestContext) throws -> URLRequest {
    let text = try context.required("url")
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
        throw FeedError("“\(text)” isn't a web address. It starts with https://.")
    }
    var request = try FeedProviders.request(text)
    context.credential?.apply(to: &request)
    return request
}

private func host(_ spec: FeedSpec) -> [String] {
    (spec["url"].flatMap(URL.init(string:))?.host?.lowercased()).map { [$0] } ?? []
}

/// A CSV file at a web address: a header row naming the columns, then a date and a value per
/// row. The date can be one column, or a year column and a month column, as NOAA's CO₂ file has.
public struct CSVProvider: FeedProvider {
    public let id = "csv"
    public let signsInByHost = true
    public let name = "CSV at a web address"
    public let summary = "Any CSV file on the web, with a date column and a value column."
    public let website = URL(string: "https://en.wikipedia.org/wiki/Comma-separated_values")!
    public let refresh = StepRate.days(1)
    public let signIn = anySignIn

    public let fields = [
        FeedField("url", "Web address", placeholder: "https://example.com/data.csv"),
        FeedField("date", "Date column", placeholder: "date", help: "Its name, or its number from 1. The first column by default.",
                  required: false),
        FeedField("value", "Value column", placeholder: "value", help: "Its name, or its number from 1. The second column by default.",
                  required: false),
        FeedField("year", "Year column", placeholder: "year", help: "Instead of a date column, a year column…", required: false),
        FeedField("month", "Month column", placeholder: "month", help: "…and a month column.", required: false),
        FeedField("missing", "Missing value", placeholder: "-99.99", help: "A value that means there's no reading.", required: false),
    ]

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { host(spec) }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] { [try address(context)] }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let table = try FeedTable(String(decoding: data, as: UTF8.self))
        func column(_ key: String, default index: Int?) throws -> Int? {
            guard let name = context[key] else { return index }
            guard let found = table.column(name) else {
                throw FeedError("The CSV has no column “\(name)”. Its columns: \(table.columns.joined(separator: ", ")).")
            }
            return found
        }
        let yearColumn = try column("year", default: nil)
        let monthColumn = try column("month", default: nil)
        let dateColumn = yearColumn == nil ? try column("date", default: 0) : nil
        guard let valueColumn = try column("value", default: table.columns.count > 1 ? 1 : nil) else {
            throw FeedError("The CSV needs a value column.")
        }
        let missing = context["missing"].flatMap(FeedNumber.parse)
        return FeedPage(points: table.rows.compactMap { row in
            let date: Date?
            if let yearColumn {
                guard let year = table.field(row, yearColumn).flatMap({ Int($0) }) else { return nil }
                let month = monthColumn.flatMap { table.field(row, $0) }.flatMap { Int($0) } ?? 1
                date = (1...12).contains(month) ? CivilDate.date(year: year, month: month, day: 1) : nil
            } else {
                date = dateColumn.flatMap { table.field(row, $0) }.flatMap(FeedDate.parse)
            }
            guard let date, let value = table.field(row, valueColumn).flatMap(FeedNumber.parse), value != missing else { return nil }
            return FeedPoint(time: date, value: value)
        })
    }
}

/// JSON at a web address. `rows` says where the list of readings is (`data`, `observations`);
/// `date` and `value` say where each reading's date and value are in it. The list can also be an
/// object keyed by date, as NOAA's is, or `date` and `value` can be two lists side by side, as
/// Open-Meteo's are (`daily.time`, `daily.temperature_2m_mean`).
public struct JSONProvider: FeedProvider {
    public let id = "json"
    public let signsInByHost = true
    public let name = "JSON at a web address"
    public let summary = "Any JSON on the web: a list of readings, an object keyed by date, or two lists side by side."
    public let website = URL(string: "https://www.json.org")!
    public let refresh = StepRate.days(1)
    public let signIn = anySignIn

    public let fields = [
        FeedField("url", "Web address", placeholder: "https://example.com/data.json"),
        FeedField("rows", "Readings at", placeholder: "data", help: "The path to the list, such as data or Results.series.0.data. "
                      + "Leave it empty when the whole answer is the list.", required: false),
        FeedField("date", "Date at", placeholder: "date", help: "Each reading's date, such as date or attributes.day.", required: false),
        FeedField("value", "Value at", placeholder: "value", help: "Each reading's value, such as value or close.", required: false),
    ]

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { host(spec) }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] { [try address(context)] }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        let datePath = context["date"] ?? "date", valuePath = context["value"] ?? "value"
        let list: Any? = context["rows"].map { JSONPath.value($0, in: json) } ?? json
        func point(_ date: Any?, _ value: Any?) -> FeedPoint? {
            guard let time = date.flatMap(Self.date), let number = FeedNumber.parse(value) else { return nil }
            return FeedPoint(time: time, value: number)
        }
        switch list {
        case let rows as [Any]:
            return FeedPage(points: rows.compactMap { point(JSONPath.value(datePath, in: $0), JSONPath.value(valuePath, in: $0)) })
        case let keyed as [String: Any] where context["rows"] != nil || keyed.keys.contains(where: { FeedDate.parse($0) != nil }):
            // Keyed by date: {"202609": {"value": 1.3}} or {"2026-09-01": 1.3}.
            if let dates = JSONPath.value(datePath, in: keyed) as? [Any], let values = JSONPath.value(valuePath, in: keyed) as? [Any] {
                return FeedPage(points: zip(dates, values).compactMap(point))
            }
            return FeedPage(points: keyed.compactMap { key, entry in
                point(key, entry is [String: Any] || entry is [Any] ? JSONPath.value(valuePath, in: entry) : entry as Any?)
            })
        default:
            // Two lists side by side, from the top.
            if let dates = JSONPath.value(datePath, in: json) as? [Any], let values = JSONPath.value(valuePath, in: json) as? [Any] {
                return FeedPage(points: zip(dates, values).compactMap(point))
            }
            throw FeedError("Couldn't find the readings in the JSON. Say where they are with rows, date and value.")
        }
    }

    static func date(_ value: Any) -> Date? {
        if let text = value as? String { return FeedDate.parse(text) }
        // Seconds or milliseconds since 1970, or a number like 202609. Checked before it becomes a
        // whole number, which a huge value would overflow.
        if let number = FeedNumber.parse(value), number.isFinite, abs(number) < 1e15 {
            return FeedDate.parse(String(Int64(number.rounded())))
        }
        return nil
    }
}
