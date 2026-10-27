import Foundation
import FutureDocument
import FutureEngine

/// Open-Meteo's historical weather: daily temperature, rain, snow, wind and sunshine for any place
/// since 1940, from weather reanalysis. Free without a key for non-commercial use; a commercial
/// key uses its customer servers.
public struct OpenMeteoProvider: FeedProvider {
    public let id = "openmeteo"
    public let name = "Open-Meteo"
    public let summary = "Daily weather for any place since 1940: temperature, rain, snow, wind, sunshine."
    public let website = URL(string: "https://open-meteo.com/en/docs/historical-weather-api")!
    public let refresh = StepRate.days(1)

    public let fields = [
        FeedField("latitude", "Latitude", placeholder: "51.51", help: "North is positive: London is 51.51."),
        FeedField("longitude", "Longitude", placeholder: "-0.13", help: "East is positive: London is −0.13."),
        FeedField("variable", "Value", placeholder: "temperature_2m_mean", choices: [
            .init("temperature_2m_mean", "Mean temperature (°C)"),
            .init("temperature_2m_max", "Highest temperature (°C)"),
            .init("temperature_2m_min", "Lowest temperature (°C)"),
            .init("precipitation_sum", "Rain and snow (mm)"),
            .init("snowfall_sum", "Snowfall (cm)"),
            .init("wind_speed_10m_max", "Strongest wind (km/h)"),
            .init("sunshine_duration", "Sunshine (seconds)"),
        ]),
    ]

    public let signIn = FeedSignIn(
        .optional, signUp: URL(string: "https://open-meteo.com/en/pricing"),
        note: "Free without a key for non-commercial use. A commercial key uses Open-Meteo's customer servers.")

    /// The first day it has.
    public static let firstDay = CivilDate.date(year: 1940, month: 1, day: 1)

    public init() {}

    public func hosts(for spec: FeedSpec) -> [String] { ["customer-archive-api.open-meteo.com"] }

    public func requests(_ context: FeedRequestContext) throws -> [URLRequest] {
        let latitude = try context.required("latitude"), longitude = try context.required("longitude")
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw FeedError("Latitude is −90 to 90 and longitude −180 to 180, like 51.51 and −0.13.")
        }
        let variable = context["variable"] ?? "temperature_2m_mean"
        let start = max(context.earliest ?? Self.firstDay, Self.firstDay)
        let host = context.credential == nil ? "archive-api.open-meteo.com" : "customer-archive-api.open-meteo.com"
        return [try FeedProviders.request("https://\(host)/v1/archive", [
            ("latitude", latitude), ("longitude", longitude), ("daily", variable),
            ("start_date", FeedDate.day(min(start, context.now))), ("end_date", FeedDate.day(context.now)),
            ("timezone", "UTC"), ("apikey", context.credential?.secret),
        ])]
    }

    public func parse(_ data: Data, request: URLRequest, context: FeedRequestContext) throws -> FeedPage {
        let json = try JSONPath.decode(data)
        let variable = context["variable"] ?? "temperature_2m_mean"
        guard let times = JSONPath.value("daily.time", in: json) as? [Any],
              let values = JSONPath.value("daily.\(variable)", in: json) as? [Any] else {
            throw FeedError("Open-Meteo's answer had no daily \(variable).")
        }
        return FeedPage(points: zip(times, values).compactMap { time, value in
            guard let date = (time as? String).flatMap(FeedDate.parse), let number = FeedNumber.parse(value) else { return nil }
            return FeedPoint(time: date, value: number)
        })
    }
}
