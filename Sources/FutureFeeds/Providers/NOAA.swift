import Foundation
import FutureDocument
import FutureEngine

/// NOAA's Climate at a Glance: monthly temperature for the globe, the hemispheres and continents
/// (as departures from the 1901–2000 average, in °C), and for the US and each state (in °F).
/// Open to everyone.
public struct NOAAProvider: FeedProvider {
    public let id = "noaa"
    public let name = "NOAA Climate at a Glance"
    public let summary = "Monthly temperatures: the globe and continents since 1850, the US and its states since 1895."
    public let website = URL(string: "https://www.ncei.noaa.gov/access/monitoring/climate-at-a-glance/")!
    public let refresh = StepRate.days(7)
    public let signIn = FeedSignIn.open

    public let fields = [
        FeedField("series", "Series", placeholder: "global/time-series/globe/land_ocean/1/0",
                  help: "The part of a Climate at a Glance time series' address before the years. "
                      + "For a US state, statewide/time-series/4/tavg/1/0, where 4 is California's number.", choices: [
            .init("global/time-series/globe/land_ocean/1/0", "Globe, land and ocean"),
            .init("global/time-series/globe/land/1/0", "Globe, land"),
            .init("global/time-series/globe/ocean/1/0", "Globe, ocean"),
            .init("global/time-series/nhem/land_ocean/1/0", "Northern Hemisphere"),
            .init("global/time-series/shem/land_ocean/1/0", "Southern Hemisphere"),
            .init("global/time-series/arctic/land_ocean/1/0", "Arctic"),
            .init("global/time-series/europe/land/1/0", "Europe, land"),
            .init("global/time-series/asia/land/1/0", "Asia, land"),
            .init("global/time-series/africa/land/1/0", "Africa, land"),
            .init("global/time-series/northAmerica/land/1/0", "North America, land"),
            .init("global/time-series/southAmerica/land/1/0", "South America, land"),
            .init("global/time-series/oceania/land/1/0", "Oceania, land"),
            .init("national/time-series/110/tavg/1/0", "Contiguous US, average (°F)"),
            .init("national/time-series/110/pcp/1/0", "Contiguous US, precipitation (inches)"),
            .init("statewide/time-series/4/tavg/1/0", "California, average (°F)"),
            .init("statewide/time-series/41/tavg/1/0", "Texas, average (°F)"),
            .init("statewide/time-series/30/tavg/1/0", "New York, average (°F)"),
        ]),
    ]

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["www.ncei.noaa.gov"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let series = try context.required("series").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard series.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-" }) else {
            throw FeedError("“\(series)” isn't a Climate at a Glance series.")
        }
        // The years must start within the series: 1850 for the globe, 1895 for the US.
        let first = series.hasPrefix("global") ? 1850 : 1895
        let from = max(first, context.earliest.map(FeedDate.year) ?? first)
        let to = FeedDate.year(context.now)
        return [try FeedProviders.request(
            "https://www.ncei.noaa.gov/access/monitoring/climate-at-a-glance/\(series)/\(from)-\(max(from, to))/data.json")]
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        guard let rows = JSONPath.value("data", in: json) as? [String: Any] else {
            throw FeedError("NOAA's answer had no data.")
        }
        // {"202609": {"departure": 1.33}}, or "value" or "anomaly" for other series.
        return FeedPage(points: rows.compactMap { key, entry in
            guard let date = FeedDate.parse(key) else { return nil }
            let value: Double?
            if let object = entry as? [String: Any] {
                value = ["departure", "anomaly", "value"].lazy.compactMap { FeedNumber.parse(object[$0]) }.first
            } else {
                value = FeedNumber.parse(entry)
            }
            return value.map { FeedPoint(time: date, value: $0) }
        })
    }

    public func errorMessage(_ data: Data, status: Int) -> String? {
        status == 404 ? "there's no series at that address, or not for those years" : nil
    }
}
