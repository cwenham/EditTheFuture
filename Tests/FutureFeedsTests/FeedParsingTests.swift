import Foundation
import Testing
@testable import FutureFeeds
import FutureDocument
import FutureEngine

func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
    CivilDate.date(year: year, month: month, day: day)
}

/// A network that answers from fixtures, and remembers what it was asked.
final class FakeTransport: FeedTransport, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body: String
    }

    private let lock = NSLock()
    private var answers: [(match: String, answer: Answer)]
    private(set) var requests: [URLRequest] = []
    private(set) var redirectHosts: [Set<String>?] = []

    /// Answers the first request whose address contains `match`.
    init(_ answers: [(String, Answer)]) {
        self.answers = answers.map { (match: $0.0, answer: $0.1) }
    }

    convenience init(_ body: String, status: Int = 200) {
        self.init([("", Answer(status: status, body: body))])
    }

    func data(for request: URLRequest, redirectHosts: Set<String>?) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer = lock.withLock {
            requests.append(request)
            self.redirectHosts.append(redirectHosts)
            let address = request.url?.absoluteString ?? ""
            guard let index = answers.firstIndex(where: { $0.match.isEmpty || address.contains($0.match) }) else {
                return Answer(status: 404, body: "")
            }
            // Each answer is used once, unless it's the last for its match.
            let found = answers[index]
            if answers.filter({ $0.match == found.match }).count > 1 { answers.remove(at: index) }
            return found.answer
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(answer.body.utf8), response)
    }

    var urls: [String] { lock.withLock { requests.map { $0.url?.absoluteString ?? "" } } }
}

/// The query items of a request, by name.
func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { $1 }
}

func feed(_ provider: String, _ settings: KeyValuePairs<String, String>) -> FeedSpec {
    FeedSpec(title: "Test", provider: provider, settings: settings.map { FeedSetting($0.key, $0.value) })
}

func fetcher(_ transport: FakeTransport, credentials: [String: FeedCredential] = [:]) -> FeedFetcher {
    FeedFetcher(transport: transport, credentials: MemoryCredentialStore(credentials))
}

let now = utc(2026, 10, 27)

@Suite("Reading what sources send")
struct FeedParsingTests {
    @Test("Dates in the forms sources write them")
    func dates() {
        #expect(FeedDate.parse("2026") == utc(2026, 1))
        #expect(FeedDate.parse("2026-09") == utc(2026, 9))
        #expect(FeedDate.parse("202609") == utc(2026, 9))
        #expect(FeedDate.parse("20260905") == utc(2026, 9, 5))
        #expect(FeedDate.parse("2026M09") == utc(2026, 9))
        #expect(FeedDate.parse("2026Q3") == utc(2026, 7))
        #expect(FeedDate.parse("09/05/2026") == utc(2026, 9, 5))
        #expect(FeedDate.parse("2026-09-05T00:00:00.000Z") == utc(2026, 9, 5))
        #expect(FeedDate.parse("2026-09-05T00:00:00.000") == utc(2026, 9, 5))
        #expect(FeedDate.parse("2026-09-05T00:00:00+00:00") == utc(2026, 9, 5))
        #expect(FeedDate.parse("2026-10-23 11:03") == utc(2026, 10, 23).addingTimeInterval(11 * 3600 + 180))
        #expect(FeedDate.parse("1788220800") == utc(2026, 9, 1))
        #expect(FeedDate.parse("1788220800000") == utc(2026, 9, 1))
        #expect(FeedDate.parse("202613") == nil)
        #expect(FeedDate.parse("someday") == nil)
        #expect(FeedDate.parse("") == nil)
    }

    @Test("Numbers as text or JSON; markers of a missing value are nil")
    func numbers() {
        #expect(FeedNumber.parse("4.79") == 4.79)
        #expect(FeedNumber.parse("40463151897249.19") == 40_463_151_897_249.19)
        #expect(FeedNumber.parse("1,234.5") == 1234.5)
        #expect(FeedNumber.parse(NSNumber(value: 3)) == 3)
        #expect(FeedNumber.parse(NSNumber(value: true)) == nil)
        for missing in [".", "-", "NA", "null", "", "nan", "(NA)"] { #expect(FeedNumber.parse(missing) == nil) }
        #expect(FeedNumber.parse(nil as Any?) == nil)
    }

    @Test("Paths into JSON")
    func paths() throws {
        let json = try JSONPath.decode(Data(#"{"Results": {"series": [{"data": [1, 2]}]}}"#.utf8))
        #expect(JSONPath.value("Results.series.0.data.1", in: json) as? Int == 2)
        #expect(JSONPath.value("Results.series.3", in: json) == nil)
        #expect(throws: FeedError.self) { try JSONPath.decode(Data("<html>".utf8)) }
    }

    @Test("CSV tables skip notes and find columns by name or number")
    func table() throws {
        let table = try FeedTable("# a note\n# another\nyear,month,average\n2026,9,426.07\n")
        #expect(table.columns == ["year", "month", "average"])
        #expect(table.column("Average") == 2)
        #expect(table.column("2") == 1)
        #expect(table.column("nope") == nil)
        #expect(throws: FeedError.self) { try FeedTable("<!DOCTYPE html><html>") }
    }
}

@Suite("Sign-ins")
struct CredentialTests {
    @Test("Each kind of sign-in goes where it should")
    func applies() throws {
        func applied(_ credential: FeedCredential) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://data.example.com/x?a=1")!)
            credential.apply(to: &request)
            return request
        }
        let key = applied(FeedCredential(kind: .key, secret: "s3cret", name: "token", hosts: ["data.example.com"]))
        #expect(query(key) == ["a": "1", "token": "s3cret"])
        let header = applied(FeedCredential(kind: .header, secret: "s3cret", name: "X-App-Token", hosts: []))
        #expect(header.value(forHTTPHeaderField: "X-App-Token") == "s3cret")
        let bearer = applied(FeedCredential(kind: .bearer, secret: "abc", hosts: []))
        #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let basic = applied(FeedCredential(kind: .basic, secret: "pw", username: "me", hosts: []))
        #expect(basic.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me:pw".utf8).base64EncodedString())
    }

    @Test("A sign-in goes only to its hosts, and only over HTTPS")
    func hosts() {
        let credential = FeedCredential(kind: .key, secret: "k", hosts: ["API.stlouisfed.org"])
        #expect(credential.allows(URL(string: "https://api.stlouisfed.org/fred")))
        #expect(!credential.allows(URL(string: "http://api.stlouisfed.org/fred")))
        #expect(!credential.allows(URL(string: "https://evil.example/fred")))
        #expect(!credential.allows(URL(string: "https://api.stlouisfed.org.evil.example/")))
    }

    @Test("Sign-ins kept in memory, for tests")
    func memory() throws {
        let store = MemoryCredentialStore()
        #expect(!store.hasCredential(named: "fred"))
        try store.save(FeedCredential(kind: .key, secret: "k", hosts: ["api.stlouisfed.org"]), named: "fred")
        #expect(store.hasCredential(named: "fred"))
        #expect(try store.credential(named: "fred")?.secret == "k")
        try store.remove(named: "fred")
        #expect(try store.credential(named: "fred") == nil)
    }

    @Test("Sign-ins round-trip as JSON, as the Keychain keeps them")
    func codable() throws {
        let credential = FeedCredential(kind: .basic, secret: "pw", username: "me", name: "", hosts: ["data.example.com"])
        let data = try JSONEncoder().encode(credential)
        #expect(try JSONDecoder().decode(FeedCredential.self, from: data) == credential)
    }
}

@Suite("Fetching")
struct FetcherTests {
    @Test("A sign-in named by a feed is refused for any host but its own, before anything is sent")
    func refusesOtherHosts() async throws {
        let transport = FakeTransport("[]")
        let fred = FeedCredential(kind: .key, secret: "k", hosts: ["api.stlouisfed.org"])
        let spec = feed("json", ["url": "https://evil.example/collect", "credential": "fred"])
        await #expect(throws: FeedError.self) {
            _ = try await fetcher(transport, credentials: ["fred": fred]).fetch(spec, now: now)
        }
        #expect(transport.requests.isEmpty)

        // Nor over plain HTTP, even to its own host.
        let plain = feed("json", ["url": "http://data.example.com/x"])
        let own = FeedCredential(kind: .bearer, secret: "t", hosts: ["data.example.com"])
        await #expect(throws: FeedError.self) {
            _ = try await fetcher(transport, credentials: ["data.example.com": own]).fetch(plain, now: now)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("A sign-in limits where redirects may lead")
    func redirects() async throws {
        let transport = FakeTransport(#"[{"date": "2026-09-01", "value": 1}]"#)
        let spec = feed("json", ["url": "https://data.example.com/x"])
        let credential = FeedCredential(kind: .bearer, secret: "t", hosts: ["data.example.com"])
        let points = try await fetcher(transport, credentials: ["data.example.com": credential]).fetch(spec, now: now)
        #expect(points == [FeedPoint(time: utc(2026, 9), value: 1)])
        #expect(transport.redirectHosts == [["data.example.com"]])
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer t")
        // Without one, redirects go anywhere.
        _ = try await fetcher(transport).fetch(spec, now: now)
        #expect(transport.redirectHosts.last == .some(nil))
    }

    @Test("A source that needs a key says so, without sending anything")
    func needsKey() async throws {
        let transport = FakeTransport("[]")
        await #expect(throws: FeedError("Tiingo needs an API key. Add one in the feed's settings.")) {
            _ = try await fetcher(transport).fetch(feed("tiingo", ["symbol": "SPY"]), now: now)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Missing settings and unknown sources are named")
    func missing() async throws {
        let transport = FakeTransport("")
        await #expect(throws: FeedError("FRED needs “Series” (series).")) {
            _ = try await fetcher(transport).fetch(feed("fred", ["series": " "]), now: now)
        }
        await #expect(throws: FeedError("There's no source called “nowhere”.")) {
            _ = try await fetcher(transport).fetch(feed("nowhere", [:]), now: now)
        }
    }

    @Test("Error answers say what the source said")
    func errors() async throws {
        let transport = FakeTransport(#"{"error_code": 400, "error_message": "Bad Request. The series does not exist."}"#, status: 400)
        let credential = FeedCredential(kind: .key, secret: "k", hosts: ["api.stlouisfed.org"])
        await #expect(throws: FeedError("FRED didn't accept the request: Bad Request. The series does not exist.")) {
            _ = try await fetcher(transport, credentials: ["fred": credential]).fetch(feed("fred", ["series": "NOPE"]), now: now)
        }
        let missing = FakeTransport("<!DOCTYPE html>", status: 404)
        await #expect(throws: FeedError("FRED has nothing at that address: there's no series with that ID")) {
            _ = try await fetcher(missing).fetch(feed("fred", ["series": "NOPE"]), now: now)
        }
    }
}
