import Foundation
import FutureDocument
import FutureEngine

/// A source of exchange rates (docs/DESIGN.md, 5.11): how many of each currency one US dollar buys.
public protocol RateProvider: Sendable {
    var source: ExchangeRateSource { get }
    /// "European Central Bank".
    var name: String { get }
    var summary: String { get }
    var website: URL { get }
    var signIn: FeedSignIn { get }
    /// The hosts a sign-in for it may be sent to.
    var hosts: [String] { get }
    /// Whether it gives only the latest rates, rather than their history.
    var isLive: Bool { get }
    /// How often to fetch.
    var refresh: TimeInterval { get }
    /// The currencies it has rates for, or nil when it has nearly all.
    var currencies: Set<Currency>? { get }

    /// The requests for these currencies' rates since a date, or all of them when nil.
    func requests(for currencies: [Currency], since: Date?, credential: FeedCredential?) throws -> [URLRequest]
    func parse(_ data: Data) throws -> ExchangeRates
    func errorMessage(_ data: Data, status: Int) -> String?
}

extension RateProvider {
    public func errorMessage(_ data: Data, status: Int) -> String? { FeedProviders.commonErrorMessage(data) }

    /// The name its sign-in is saved under in the Keychain.
    public var credentialName: String { source.rawValue }

    /// Whether it has rates for a currency.
    public func has(_ currency: Currency) -> Bool { currency == .usd || currencies?.contains(currency) ?? true }
}

public enum RateProviders {
    public static let ecb = FrankfurterRates()
    public static let openExchangeRates = OpenExchangeRates()

    /// Where a scenario's daily rates come from, and its live ones when it has them.
    public static func providers(for source: ExchangeRateSource) -> (daily: (any RateProvider)?, live: (any RateProvider)?) {
        switch source {
        case .ecb: return (ecb, nil)
        case .openexchangerates: return (ecb, openExchangeRates)
        case .none: return (nil, nil)
        }
    }
}

/// The European Central Bank's reference rates, published each working day at about 16:00 in
/// Frankfurt, from 4 January 1999, through Frankfurter (frankfurter.dev), which is free and needs
/// no key. About 30 currencies.
public struct FrankfurterRates: RateProvider {
    public let source = ExchangeRateSource.ecb
    public let name = "European Central Bank"
    public let summary = "Daily reference rates for about 30 currencies since 1999, through Frankfurter. Free, with no key."
    public let website = URL(string: "https://frankfurter.dev")!
    public let signIn = FeedSignIn.open
    public let hosts = ["api.frankfurter.dev"]
    public let isLive = false
    public let refresh: TimeInterval = 6 * 3_600
    /// The first day it has.
    public static let first = CivilDate.date(year: 1999, month: 1, day: 4)

    public let currencies: Set<Currency>? = Set(["AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF",
                                                 "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP",
                                                 "PLN", "RON", "SEK", "SGD", "THB", "TRY", "ZAR"].compactMap(Currency.init(code:)))

    public init() {}

    public func requests(for currencies: [Currency], since: Date?, credential: FeedCredential?) throws -> [URLRequest] {
        let wanted = currencies.filter { $0 != .usd && has($0) }.map(\.code).sorted()
        guard !wanted.isEmpty else { return [] }
        let from = FeedDate.day(max(since ?? Self.first, Self.first))
        return [try FeedProviders.request("https://api.frankfurter.dev/v1/\(from)..", [
            ("base", "USD"), ("symbols", wanted.joined(separator: ",")),
        ])]
    }

    public func parse(_ data: Data) throws -> ExchangeRates {
        guard let json = try JSONPath.decode(data) as? [String: Any], let days = json["rates"] as? [String: Any] else {
            throw FeedError("Frankfurter said: " + (FeedProviders.commonErrorMessage(data) ?? "something unexpected."))
        }
        var rates: [Currency: [(time: Date, rate: Double)]] = [:]
        for (day, values) in days {
            guard let date = FeedDate.parse(day), let values = values as? [String: Any] else { continue }
            for (code, value) in values {
                guard let currency = Currency(code: code), let rate = FeedNumber.parse(value) else { continue }
                rates[currency, default: []].append((date, rate))
            }
        }
        return ExchangeRates(perDollar: rates)
    }
}

/// Open Exchange Rates' latest rates for about 170 currencies (openexchangerates.org). It needs
/// an App ID; how often its rates change depends on the plan, from hourly to every minute. The
/// App ID goes in a header, never in the web address.
public struct OpenExchangeRates: RateProvider {
    public let source = ExchangeRateSource.openexchangerates
    public let name = "Open Exchange Rates"
    public let summary = "The latest rates for about 170 currencies, hourly to every minute depending on the plan. Needs an App ID."
    public let website = URL(string: "https://openexchangerates.org")!
    public let signIn = FeedSignIn(.required, signUp: URL(string: "https://openexchangerates.org/signup"),
                                   note: "Needs an App ID. The free plan updates hourly and allows 1,000 requests a month; "
                                       + "checking every 10 minutes needs a paid plan.")
    public let hosts = ["openexchangerates.org"]
    public let isLive = true
    public let refresh: TimeInterval = 600
    public let currencies: Set<Currency>? = nil

    public init() {}

    public func requests(for currencies: [Currency], since: Date?, credential: FeedCredential?) throws -> [URLRequest] {
        let wanted = currencies.filter { $0 != .usd }.map(\.code).sorted()
        guard !wanted.isEmpty else { return [] }
        var request = try FeedProviders.request("https://openexchangerates.org/api/latest.json", [
            ("symbols", wanted.joined(separator: ",")),
        ])
        if let credential { request.setValue("Token " + credential.secret, forHTTPHeaderField: "Authorization") }
        return [request]
    }

    public func parse(_ data: Data) throws -> ExchangeRates {
        guard let json = try JSONPath.decode(data) as? [String: Any], let values = json["rates"] as? [String: Any],
              let stamp = FeedNumber.parse(json["timestamp"]) else {
            throw FeedError("Open Exchange Rates said: " + (errorMessage(data, status: 200) ?? "something unexpected."))
        }
        let time = Date(timeIntervalSince1970: stamp)
        var rates: [Currency: [(time: Date, rate: Double)]] = [:]
        for (code, value) in values {
            guard let currency = Currency(code: code), let rate = FeedNumber.parse(value) else { continue }
            rates[currency] = [(time, rate)]
        }
        return ExchangeRates(perDollar: rates)
    }

    /// Its errors say what's wrong in `description`: "Invalid App ID provided…".
    public func errorMessage(_ data: Data, status: Int) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["description"] as? String).map(FeedProviders.trimmed) ?? FeedProviders.commonErrorMessage(data)
    }
}

/// Fetches exchange rates, with a source's sign-in, the way feeds are fetched (docs/DESIGN.md, 15.8):
/// the sign-in goes only to the source's hosts, over HTTPS.
public struct RateFetcher: Sendable {
    public let feeds: FeedFetcher

    public init(transport: any FeedTransport = URLSessionTransport(), credentials: any CredentialStore = KeychainCredentialStore()) {
        feeds = FeedFetcher(transport: transport, credentials: credentials)
    }

    /// The currencies' rates since `since` (all of them when nil). Currencies the source doesn't
    /// have are left out.
    public func fetch(_ provider: any RateProvider, currencies: [Currency], since: Date? = nil) async throws -> ExchangeRates {
        var credential: FeedCredential?
        if provider.signIn.need != .none {
            do {
                credential = try feeds.credentials.credential(named: provider.credentialName)
            } catch {
                throw FeedError("Couldn't read the sign-in for \(provider.name): \(error)")
            }
            if let found = credential, !found.isComplete { credential = nil }
        }
        if provider.signIn.need == .required && credential == nil {
            throw FeedError("\(provider.name) needs an App ID. Add one in the scenario's settings.")
        }
        // The sign-in is the source's own, so it may go only to the source's hosts.
        let signIn = credential.map { FeedCredential(kind: $0.kind, secret: $0.secret, username: $0.username, name: $0.name,
                                                     hosts: provider.hosts) }
        var rates = ExchangeRates.none
        for request in try provider.requests(for: currencies, since: since, credential: signIn) {
            if let signIn, !signIn.allows(request.url) {
                throw FeedError("The sign-in for \(provider.name) can only be sent to \(provider.hosts.joined(separator: ", ")) over HTTPS.")
            }
            let (data, response) = try await feeds.send(request, credential: signIn)
            guard (200..<300).contains(response.statusCode) else {
                throw FeedError(FeedFetcher.statusMessage(response.statusCode, provider: provider.name,
                                                          reason: provider.errorMessage(data, status: response.statusCode)))
            }
            rates = rates.merged(with: try provider.parse(data))
        }
        return rates
    }
}
