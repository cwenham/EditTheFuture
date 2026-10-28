import Foundation
import Testing
@testable import FutureFeeds
import FutureDocument
import FutureEngine

/// Exchange rates' sources (docs/DESIGN.md, 5.11), answered from fixtures.
@Suite("Exchange rate sources")
struct RateSourceTests {
    let frankfurter = """
        {"amount":1.0,"base":"USD","start_date":"2026-10-26","end_date":"2026-10-28",
         "rates":{"2026-10-26":{"EUR":0.89381,"GBP":0.7492},"2026-10-27":{"EUR":0.89686,"GBP":0.7503},
                  "2026-10-28":{"EUR":0.89823,"GBP":0.75258}}}
        """
    let latest = """
        {"disclaimer":"Usage subject to terms","license":"https://openexchangerates.org/license",
         "timestamp":1793195400,"base":"USD","rates":{"AED":3.6725,"GBP":0.7531}}
        """

    @Test("The ECB's rates through Frankfurter: every day since a date, for the currencies it has")
    func ecb() async throws {
        let transport = FakeTransport(frankfurter)
        let fetcher = RateFetcher(transport: transport, credentials: MemoryCredentialStore())
        let rates = try await fetcher.fetch(RateProviders.ecb, currencies: [.gbp, .eur, .usd, Currency(code: "AED")!],
                                            since: utc(2026, 10, 26))
        let request = try #require(transport.requests.first)
        #expect(request.url?.host == "api.frankfurter.dev")
        #expect(request.url?.path == "/v1/2026-10-26..")
        #expect(query(request) == ["base": "USD", "symbols": "EUR,GBP"])  // it has no dirhams
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(rates.series[.gbp]?.times == [utc(2026, 10, 26), utc(2026, 10, 27), utc(2026, 10, 28)])
        #expect(rates.series[.gbp]?.perDollar == [0.7492, 0.7503, 0.75258])
        #expect(rates.perDollar(.eur, at: utc(2026, 10, 28)) == 0.89823)

        // From the start when there's no date; and nothing to ask for, no request.
        _ = try await fetcher.fetch(RateProviders.ecb, currencies: [.gbp])
        #expect(transport.requests.last?.url?.path == "/v1/1999-01-04..")
        let none = try await fetcher.fetch(RateProviders.ecb, currencies: [.usd, Currency(code: "AED")!])
        #expect(none == .none && transport.requests.count == 2)
        #expect(RateProviders.ecb.has(.gbp) && !RateProviders.ecb.has(Currency(code: "AED")!))
    }

    @Test("Open Exchange Rates' latest, with the App ID in a header and only for its own host")
    func live() async throws {
        let transport = FakeTransport(latest)
        let credentials = MemoryCredentialStore([
            "openexchangerates": FeedCredential(kind: .key, secret: "app-123", hosts: ["example.com"]),
        ])
        let rates = try await RateFetcher(transport: transport, credentials: credentials)
            .fetch(RateProviders.openExchangeRates, currencies: [.gbp, Currency(code: "AED")!])
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://openexchangerates.org/api/latest.json?symbols=AED,GBP")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token app-123")
        #expect(!(request.url?.absoluteString.contains("app-123") ?? true))
        // Redirects may lead only to its own host, whatever hosts the saved sign-in named.
        #expect(transport.redirectHosts.first == ["openexchangerates.org"])
        let time = Date(timeIntervalSince1970: 1_793_195_400)
        #expect(rates.latest(.gbp)?.time == time && rates.latest(.gbp)?.perDollar == 0.7531)
        #expect(rates.perDollar(Currency(code: "AED")!, at: utc(2000, 1, 1)) == 3.6725)
    }

    @Test("Live rates need an App ID, and say what the source said when it's refused")
    func refused() async throws {
        let none = RateFetcher(transport: FakeTransport(latest), credentials: MemoryCredentialStore())
        await #expect(throws: FeedError("Open Exchange Rates needs an App ID. Add one in the scenario's settings.")) {
            try await none.fetch(RateProviders.openExchangeRates, currencies: [.gbp])
        }
        let refusal = """
            {"error": true, "status": 401, "message": "invalid_app_id", "description": "Invalid App ID provided."}
            """
        let wrong = RateFetcher(transport: FakeTransport(refusal, status: 401), credentials: MemoryCredentialStore([
            "openexchangerates": FeedCredential(kind: .key, secret: "nope", hosts: ["openexchangerates.org"]),
        ]))
        await #expect(throws: FeedError("Open Exchange Rates refused the sign-in, or needs one: Invalid App ID provided.")) {
            try await wrong.fetch(RateProviders.openExchangeRates, currencies: [.gbp])
        }
        let broken = RateFetcher(transport: FakeTransport("{\"message\": \"not found\"}", status: 404), credentials: MemoryCredentialStore())
        await #expect(throws: FeedError("European Central Bank has nothing at that address: not found")) {
            try await broken.fetch(RateProviders.ecb, currencies: [.gbp])
        }
    }

    @Test("The rates' copy is CSV with a column for each currency, and reads back the same")
    func copy() throws {
        let rates = ExchangeRates(perDollar: [
            .gbp: [(utc(2026, 10, 27), 0.7503), (utc(2026, 10, 28), 0.75258)],
            .eur: [(utc(2026, 10, 28), 0.89823)],
        ])
        let text = RateCopy.text(rates)
        #expect(text == "date,EUR,GBP\n2026-10-27,,0.7503\n2026-10-28,0.89823,0.75258\n")
        #expect(try RateCopy.parse(text) == rates)
        #expect(try RateCopy.parse("date,GBP,notes\n2026-10-28,0.75,7\n").currencies == [.usd, .gbp])
        #expect(RateCopy.text(.none) == "date\n")
    }
}
