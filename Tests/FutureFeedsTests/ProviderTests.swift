import Foundation
import Testing
@testable import FutureFeeds
import FutureDocument
import FutureEngine

/// Each source's requests, and its answers as the source sent them in October 2026, cut short.
@Suite("Sources")
struct ProviderTests {
    @Test("FRED without a key: its CSV download, from a date, with missing days left out")
    func fredCSV() async throws {
        let transport = FakeTransport("observation_date,DGS10\n2026-09-01,4.79\n2026-09-02,.\n2026-09-03,4.77\n")
        let points = try await fetcher(transport).fetch(feed("fred", ["series": "DGS10", "units": "lin"]), since: utc(2026, 9), now: now)
        #expect(points.map(\.value) == [4.79, 4.77])
        let request = transport.requests[0]
        #expect(request.url?.host == "fred.stlouisfed.org")
        #expect(query(request) == ["id": "DGS10", "cosd": "2026-09-01"])
    }

    @Test("FRED with a key: its API, with the key and the units")
    func fredAPI() async throws {
        let transport = FakeTransport(#"{"observations": [{"date": "2026-01-01", "value": "2.39"}, {"date": "2026-02-01", "value": "."}]}"#)
        let credential = FeedCredential(kind: .key, secret: "abc", hosts: ["api.stlouisfed.org"])
        let points = try await fetcher(transport, credentials: ["fred": credential])
            .fetch(feed("fred", ["series": "CPIAUCSL", "units": "pc1"]), now: now)
        #expect(points == [FeedPoint(time: utc(2026, 1), value: 2.39)])
        #expect(query(transport.requests[0]) == ["series_id": "CPIAUCSL", "api_key": "abc", "file_type": "json", "units": "pc1"])
    }

    @Test("Treasury: fields, filters and sorting, and every page")
    func treasury() async throws {
        let page1 = #"{"data": [{"record_date": "2026-10-22", "tot_pub_debt_out_amt": "40444342709389.15"}], "meta": {"total-pages": 2}}"#
        let page2 = #"{"data": [{"record_date": "2026-10-23", "tot_pub_debt_out_amt": "40463151897249.19"}], "meta": {"total-pages": 2}}"#
        let transport = FakeTransport([("page%5Bnumber%5D=1", .init(body: page1)), ("page%5Bnumber%5D=2", .init(body: page2))])
        let spec = feed("treasury", ["dataset": "v2/accounting/od/debt_to_penny", "field": "tot_pub_debt_out_amt",
                                     "filter": "security_desc:eq:Treasury Bonds"])
        let points = try await fetcher(transport).fetch(spec, since: utc(2026, 10, 1), now: now)
        #expect(points.map(\.value) == [40_444_342_709_389.15, 40_463_151_897_249.19])
        #expect(transport.requests.count == 2)
        let first = query(transport.requests[0])
        #expect(first["fields"] == "record_date,tot_pub_debt_out_amt")
        #expect(first["filter"] == "security_desc:eq:Treasury Bonds,record_date:gte:2026-10-01")
        #expect(first["sort"] == "record_date")
        #expect(transport.requests[0].url?.path == "/services/api/fiscal_service/v2/accounting/od/debt_to_penny")

        let wrong = FakeTransport(#"{"data": [{"record_date": "2026-10-22", "other": "1"}], "meta": {"total-pages": 1}}"#)
        await #expect(throws: FeedError("The dataset has no field called “tot_pub_debt_out_amt”.")) {
            _ = try await fetcher(wrong).fetch(spec, now: now)
        }
    }

    @Test("World Bank: years as dates, empty years skipped, and its own error messages")
    func worldBank() async throws {
        let body = """
            [{"page":1,"pages":1,"total":3},[{"date":"2025","value":null},{"date":"2024","value":2.94952520485207},\
            {"date":"2023","value":4.1}]]
            """
        let transport = FakeTransport(body)
        let spec = feed("worldbank", ["indicator": "FP.CPI.TOTL.ZG", "country": "USA"])
        let points = try await fetcher(transport).fetch(spec, since: utc(2020, 1), now: now)
        #expect(points == [FeedPoint(time: utc(2023, 1), value: 4.1), FeedPoint(time: utc(2024, 1), value: 2.94952520485207)])
        #expect(transport.requests[0].url?.path == "/v2/country/USA/indicator/FP.CPI.TOTL.ZG")
        #expect(query(transport.requests[0])["date"] == "2020:2027")

        let bad = FakeTransport(#"[{"message":[{"id":"120","key":"Invalid value","value":"The provided parameter value is not valid"}]}]"#)
        await #expect(throws: FeedError.self) { _ = try await fetcher(bad).fetch(spec, now: now) }
        await #expect(throws: FeedError.self) {
            _ = try await fetcher(bad).fetch(feed("worldbank", ["indicator": "X&Y", "country": "USA"]), now: now)
        }
    }

    @Test("BLS: 10 years a request without a key, 20 with one in the body; yearly averages left out")
    func bls() async throws {
        let body = """
            {"status":"REQUEST_SUCCEEDED","Results":{"series":[{"seriesID":"CUUR0000SA0","data":[\
            {"year":"2026","period":"M09","value":"336.940"},{"year":"2025","period":"M13","value":"320.1"},\
            {"year":"2025","period":"M12","value":"-"}]}]}}
            """
        let transport = FakeTransport(body)
        let spec = feed("bls", ["series": "CUUR0000SA0"])
        let points = try await fetcher(transport).fetch(spec, since: utc(2000, 1), now: now)
        #expect(points == [FeedPoint(time: utc(2026, 9), value: 336.94)])
        #expect(transport.requests.map { query($0)["startyear"] } == ["2000", "2010", "2020"])
        #expect(transport.requests.map { query($0)["endyear"] } == ["2009", "2019", "2026"])

        let keyed = FakeTransport(body)
        let credential = FeedCredential(kind: .key, secret: "k", hosts: ["api.bls.gov"])
        _ = try await fetcher(keyed, credentials: ["bls": credential]).fetch(spec, since: utc(2000, 1), now: now)
        #expect(keyed.requests.count == 2)
        let sent = try #require(keyed.requests[0].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["registrationkey"] as? String == "k")
        #expect(json["startyear"] as? String == "2000")
        #expect(json["endyear"] as? String == "2019")
        #expect(keyed.requests[0].httpMethod == "POST")

        let refused = FakeTransport(#"{"status":"REQUEST_NOT_PROCESSED","message":["Daily threshold for total number of requests allocated has been reached."]}"#)
        await #expect(throws: FeedError("BLS said: Daily threshold for total number of requests allocated has been reached.")) {
            _ = try await fetcher(refused).fetch(spec, since: utc(2020, 1), now: now)
        }
        #expect(BLSProvider.month("Q03") == 7)
        #expect(BLSProvider.month("S02") == 7)
        #expect(BLSProvider.month("A01") == 1)
    }

    @Test("NOAA: months keyed by date, with the years kept within the series")
    func noaa() async throws {
        let body = #"{"description":{"units":"Degrees Celsius"},"data":{"202608":{"departure":1.31},"202609":{"departure":1.33}}}"#
        let transport = FakeTransport(body)
        let points = try await fetcher(transport).fetch(feed("noaa", ["series": "global/time-series/globe/land_ocean/1/0"]), now: now)
        #expect(points == [FeedPoint(time: utc(2026, 8), value: 1.31), FeedPoint(time: utc(2026, 9), value: 1.33)])
        #expect(transport.urls[0].hasSuffix("/global/time-series/globe/land_ocean/1/0/1850-2026/data.json"))

        let us = FakeTransport(#"{"data":{"202609":{"value":69.42}}}"#)
        let fahrenheit = try await fetcher(us).fetch(feed("noaa", ["series": "national/time-series/110/tavg/1/0"]), now: now)
        #expect(fahrenheit.first?.value == 69.42)
        #expect(us.urls[0].contains("/1895-2026/"))
    }

    @Test("Open-Meteo: two lists side by side; a commercial key uses its customer servers")
    func openMeteo() async throws {
        let body = #"{"daily":{"time":["2026-10-25","2026-10-26","2026-10-27"],"temperature_2m_mean":[10.7,12.3,null]}}"#
        let transport = FakeTransport(body)
        let spec = feed("openmeteo", ["latitude": "51.51", "longitude": "-0.13", "variable": "temperature_2m_mean", "from": "1990-01-01"])
        let points = try await fetcher(transport).fetch(spec, now: now)
        #expect(points.map(\.value) == [10.7, 12.3])
        let sent = query(transport.requests[0])
        #expect(sent["start_date"] == "1990-01-01")
        #expect(sent["end_date"] == "2026-10-27")
        #expect(transport.requests[0].url?.host == "archive-api.open-meteo.com")

        let keyed = FakeTransport(body)
        let credential = FeedCredential(kind: .key, secret: "k", hosts: ["customer-archive-api.open-meteo.com"])
        _ = try await fetcher(keyed, credentials: ["openmeteo": credential]).fetch(spec, now: now)
        #expect(keyed.requests[0].url?.host == "customer-archive-api.open-meteo.com")
        #expect(query(keyed.requests[0])["apikey"] == "k")

        await #expect(throws: FeedError.self) {
            _ = try await fetcher(transport).fetch(feed("openmeteo", ["latitude": "123", "longitude": "0"]), now: now)
        }
    }

    @Test("Open data portals: a query that adds up rows, an app token, and pages")
    func socrata() async throws {
        let rows = (0..<SocrataProvider.pageSize).map { #"{"date":"2026-08-01","value":"\#($0)"}"# }
        let page1 = "[" + rows.joined(separator: ",") + "]"
        let page2 = #"[{"date":"2026-08-08T00:00:00.000","value":"1.1167901234567901"}]"#
        let transport = FakeTransport([("offset", .init(body: page2)), ("resource", .init(body: page1))])
        let spec = feed("socrata", ["dataset": "atcp-73re", "date": "week_end", "value": "avg(site_wval)",
                                    "where": "state_territory = 'California'"])
        let credential = FeedCredential(kind: .header, secret: "tok", name: "X-App-Token", hosts: ["data.cdc.gov"])
        let points = try await fetcher(transport, credentials: ["socrata": credential]).fetch(spec, since: utc(2026, 8), now: now)
        #expect(points.count == 2)
        #expect(points.last?.value == 1.1167901234567901)
        let first = query(transport.requests[0])
        #expect(first["$select"] == "week_end AS date, avg(site_wval) AS value")
        #expect(first["$where"] == "(state_territory = 'California') AND week_end >= '2026-08-01'")
        #expect(first["$group"] == "week_end")
        #expect(first["$offset"] == nil)
        #expect(query(transport.requests[1])["$offset"] == String(SocrataProvider.pageSize))
        #expect(transport.requests[0].value(forHTTPHeaderField: "X-App-Token") == "tok")

        await #expect(throws: FeedError.self) {
            _ = try await fetcher(transport).fetch(feed("socrata", ["dataset": "atcp-73re", "date": "week_end; drop", "value": "x"]), now: now)
        }
        let refused = FakeTransport(#"{"message":"Query coordinator error: query.soql.no-such-column; No such column: nosuchcol"}"#, status: 400)
        await #expect(throws: FeedError.self) { _ = try await fetcher(refused).fetch(spec, now: now) }
    }

    @Test("Tiingo: the key in its own header, and the price asked for")
    func tiingo() async throws {
        let transport = FakeTransport(#"[{"date":"2026-10-01T00:00:00.000Z","close":668.45,"adjClose":667.9}]"#)
        let credential = FeedCredential(kind: .key, secret: "k", hosts: ["api.tiingo.com"])
        let points = try await fetcher(transport, credentials: ["tiingo": credential])
            .fetch(feed("tiingo", ["symbol": "SPY", "price": "adjClose"]), now: now)
        #expect(points == [FeedPoint(time: utc(2026, 10), value: 667.9)])
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Token k")
        #expect(transport.requests[0].url?.path == "/tiingo/daily/spy/prices")
    }

    @Test("CSV at a web address: notes skipped, a year and a month column, and a missing-value marker")
    func csv() async throws {
        let body = """
            # NOAA's notes
            year,month,decimal date,average
            1958,3,1958.2027,315.71
            1958,4,1958.2877,-99.99
            2026,9,2026.7083,426.07
            """
        let transport = FakeTransport(body)
        let spec = feed("csv", ["url": "https://gml.noaa.gov/co2.csv", "year": "year", "month": "month", "value": "average",
                                "missing": "-99.99"])
        let points = try await fetcher(transport).fetch(spec, now: now)
        #expect(points == [FeedPoint(time: utc(1958, 3), value: 315.71), FeedPoint(time: utc(2026, 9), value: 426.07)])

        let plain = FakeTransport("Date,Close\n2026-10-01,1.5\n")
        #expect(try await fetcher(plain).fetch(feed("csv", ["url": "https://x.example/a.csv"]), now: now).count == 1)
        await #expect(throws: FeedError.self) {
            _ = try await fetcher(plain).fetch(feed("csv", ["url": "https://x.example/a.csv", "value": "Open"]), now: now)
        }
        await #expect(throws: FeedError.self) { _ = try await fetcher(plain).fetch(feed("csv", ["url": "ftp://x"]), now: now) }
    }

    @Test("JSON at a web address: a list, an object keyed by date, or two lists")
    func json() async throws {
        let list = FakeTransport(#"{"observations":[{"day":{"on":"2026-09-01"},"close":"5"}]}"#)
        #expect(try await fetcher(list).fetch(feed("json", ["url": "https://x.example/a", "rows": "observations",
                                                            "date": "day.on", "value": "close"]), now: now)
            == [FeedPoint(time: utc(2026, 9), value: 5)])

        let keyed = FakeTransport(#"{"data":{"202609":{"value":1.5},"202610":{"value":2}}}"#)
        #expect(try await fetcher(keyed).fetch(feed("json", ["url": "https://x.example/a", "rows": "data"]), now: now).count == 2)

        let plainKeyed = FakeTransport(#"{"2026-09-01": 3, "2026-10-01": 4}"#)
        #expect(try await fetcher(plainKeyed).fetch(feed("json", ["url": "https://x.example/a"]), now: now).map(\.value) == [3, 4])

        let sideBySide = FakeTransport(#"{"daily":{"time":["2026-09-01","2026-09-02"],"t":[1,2]}}"#)
        #expect(try await fetcher(sideBySide).fetch(feed("json", ["url": "https://x.example/a", "date": "daily.time",
                                                                  "value": "daily.t"]), now: now).count == 2)

        let epoch = FakeTransport(#"[{"date": 1788220800, "value": 7}, {"date": 1e300, "value": 8}]"#)
        #expect(try await fetcher(epoch).fetch(feed("json", ["url": "https://x.example/a"]), now: now)
            == [FeedPoint(time: utc(2026, 9), value: 7)])
    }
}

@Suite("Ready-made feeds")
struct CatalogTests {
    @Test("Each ready-made feed names a source, and every one that's filled in builds its requests")
    func presets() throws {
        #expect(Set(FeedCatalog.all.map(\.id)).count == FeedCatalog.all.count)
        for category in FeedPreset.Category.allCases { #expect(!FeedCatalog.presets(in: category).isEmpty) }
        for preset in FeedCatalog.all {
            let provider = try #require(preset.provider, "\(preset.id)")
            #expect(preset.spec.settings.allSatisfy { setting in
                provider.fields.contains { $0.key == setting.key } || setting.key == "from"
            }, "\(preset.id) has a setting its source doesn't take")
            guard preset.spec.query.allSatisfy({ !$0.value.isEmpty }) else { continue }
            let credential = FeedCredential(kind: provider.signIn.kinds.first ?? .key, secret: "k", name: "X-App-Token",
                                            hosts: provider.hosts(for: preset.spec))
            let context = FeedRequestContext(spec: preset.spec, credential: provider.signIn.need == .none ? nil : credential, now: now)
            let requests = try provider.requests(context)
            #expect(!requests.isEmpty, "\(preset.id)")
            #expect(requests.allSatisfy { $0.url?.scheme == "https" }, "\(preset.id)")
            #expect(requests.allSatisfy { credential.allows($0.url) || context.credential == nil }, "\(preset.id)")
        }
    }

    @Test("Percent points become fractions for a percent, and °F becomes °C for a temperature")
    func conversions() throws {
        let yield = try #require(FeedCatalog.preset(id: "treasury10"))
        #expect(yield.conversion(forFormat: "percent") == .percent)
        #expect(yield.conversion(forFormat: "number") == nil)
        let us = try #require(FeedCatalog.preset(id: "ustemp"))
        #expect(us.conversion(forFormat: "temperature") == .fahrenheit)
    }

    @Test("Search finds feeds by words in their names, sources and settings")
    func search() {
        #expect(FeedCatalog.search("debt").map(\.id).contains("debt"))
        #expect(FeedCatalog.search("DGS10").map(\.id) == ["treasury10"])
        #expect(FeedCatalog.search("flu emergency").map(\.id) == ["edflu"])
        #expect(FeedCatalog.search("").count == FeedCatalog.all.count)
    }
}
