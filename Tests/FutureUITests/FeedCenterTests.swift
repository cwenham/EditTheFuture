import Foundation
import Testing
import FutureDocument
import FutureEngine
import FutureFeeds
@testable import FutureUI

/// A network that answers each request with the next answer in line, and remembers what it was asked.
final class QueuedTransport: FeedTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String)]) {
        self.answers = answers.map { (status: $0.0, body: $0.1) }
    }

    func data(for request: URLRequest, redirectHosts: Set<String>?) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { () -> (status: Int, body: String) in
            requests.append(request)
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? (500, "")
        }
        return (Data(answer.body.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!)
    }

    /// From now on, answers with this.
    func answer(_ status: Int, _ body: String) {
        lock.withLock { answers = [(status: status, body: body)] }
    }

    var queries: [[String: String]] {
        lock.withLock {
            requests.map { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                return Dictionary(items.map { ($0.name, $0.value ?? "") }) { $1 }
            }
        }
    }
}

/// Feeds fetched into a scenario's `readings/` folder (docs/DESIGN.md, 15.8).
@MainActor
@Suite("Feeds in the app", .serialized)
struct FeedCenterTests {
    let now = utc(2026, 10, 25)

    static let yields = """
        observation_date,DGS10
        2026-10-21,4.95
        2026-10-22,4.98
        2026-10-23,5.00
        """

    static let treasuryYield = FeedSpec(title: "10-year Treasury yield", provider: "fred", settings: [
        FeedSetting("series", "DGS10"), FeedSetting("into", "rate"), FeedSetting("convert", "percent"),
    ])

    func makeDocument(_ transport: QueuedTransport) async throws -> ScenarioDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-feeds-" + UUID().uuidString, isDirectory: true)
        let package = ScenarioPackage(url: folder.appendingPathComponent("Test.etf"))
        try ScenarioDocument.create(.homeAndMoney, at: package)
        return try await open(package, transport)
    }

    func open(_ package: ScenarioPackage, _ transport: QueuedTransport) async throws -> ScenarioDocument {
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        document.store.feedTransport = transport
        document.store.credentials = MemoryCredentialStore()
        document.feeds.now = { self.now }
        document.feeds.start(watch: false)
        await settle(document)
        return document
    }

    func settle(_ document: ScenarioDocument) async {
        await document.feeds.waitUntilIdle()
        await document.store.waitUntilIdle()
    }

    func balance(_ store: ScenarioStore, at date: Date) -> Double? {
        guard let series = store.computed?.series[0] else { return nil }
        return ScenarioStore.held(series, at: date)
    }

    @Test("Adding a feed saves its line, fetches into its copy, and its readings correct the slot")
    func addsAndFetches() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        let store = document.store
        store.setCursor(utc(2036, 1))
        await store.waitUntilIdle()
        let before = try #require(balance(store, at: utc(2036, 1)))

        store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        #expect(document.save())
        let text = try document.package.readText()
        #expect(text.contains("- 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent]"))

        let copy = document.package.url.appendingPathComponent("readings/Savings-fred-DGS10.csv")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "date,value\n2026-10-21,4.95\n2026-10-22,4.98\n2026-10-23,5\n")
        #expect(store.configs[0].readings.set.readings.map(\.value) == [0.0495, 0.0498, 0.05])

        let status = try #require(store.feedStatuses[FeedKey(slot: store.configs[0].id, identity: Self.treasuryYield.identity)])
        #expect(status.count == 3)
        #expect(status.last == utc(2026, 10, 23))
        #expect(status.error == nil)
        #expect(!status.isFetching)
        #expect(status.checked == now)

        // 5% from October 2026 on, instead of 4.5%, so the balance grows faster.
        let after = try #require(balance(store, at: utc(2036, 1)))
        #expect(after > before)
        #expect(store.slots[0].parameterValues.first { $0.name == "rate" }?.value == 0.045)
        await document.close()
    }

    @Test("A refresh asks for the readings since a little before the latest, and merges them")
    func refreshes() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        let store = document.store
        store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        #expect(transport.queries.last?["cosd"] == nil)

        transport.answer(200, "observation_date,DGS10\n2026-10-23,5.01\n2026-10-24,5.02\n")
        store.refreshFeeds(slot: store.configs[0].id)
        await settle(document)
        let since = utc(2026, 10, 23).addingTimeInterval(-FeedCenter.overlap)
        #expect(transport.queries.last?["cosd"] == FeedDate.day(since))
        #expect(store.configs[0].readings.set.readings.map(\.value) == [0.0495, 0.0498, 0.0501, 0.0502])
        await document.close()
    }

    @Test("New readings aren't an edit: undoing another change keeps them")
    func undoKeepsReadings() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        let store = document.store
        store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        store.setStartingValue("monthly", to: 900, inSlotAt: 0)
        store.undo()
        await settle(document)
        #expect(store.configs[0].readings.set.readings.count == 3)

        // Undoing the feed takes it away; redoing brings it back with its readings.
        store.undo()
        await settle(document)
        #expect(store.configs[0].readings.sources.isEmpty)
        #expect(store.feedStatuses.isEmpty)
        store.redo()
        await settle(document)
        #expect(store.configs[0].readings.set.readings.count == 3)
        #expect(transport.requests.count == 1)
        await document.close()
    }

    @Test("Opened again offline, a scenario uses its copies, and a failed fetch says why and keeps them")
    func offline() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        document.store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        await document.close()

        let offline = QueuedTransport([(503, #"{"message": "Down for maintenance"}"#)])
        let again = try await ScenarioDocument.open(document.package, now: now, watch: false)
        #expect(again.store.configs[0].readings.set.readings.count == 3)
        again.store.feedTransport = offline
        again.store.credentials = MemoryCredentialStore()
        // Two days after the copy was written, it's due again.
        again.feeds.now = { Date().addingTimeInterval(2 * 86_400) }
        again.feeds.start(watch: false)
        await settle(again)
        #expect(offline.requests.count == 1)
        let key = FeedKey(slot: again.store.configs[0].id, identity: Self.treasuryYield.identity)
        let status = try #require(again.store.feedStatuses[key])
        #expect(status.error == "FRED had a problem of its own: Down for maintenance")
        #expect(status.count == 3)
        #expect(again.store.configs[0].readings.set.readings.count == 3)
        #expect(again.store.message?.contains("Couldn't fetch") == true)
        await again.close()
    }

    @Test("A copy that's still fresh isn't fetched again when the scenario opens")
    func freshCopy() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        document.store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        await document.close()
        let again = try await open(document.package, transport)
        #expect(transport.requests.count == 1)
        #expect(again.store.feedStatuses.values.first?.count == 3)
        await again.close()
    }

    @Test("A feed in a slot of its own: a data series that follows the readings, drawn as dots")
    func feedSlot() async throws {
        let body = """
            {"data": [{"record_date": "2026-10-21", "tot_pub_debt_out_amt": "40413639012305.97"},
                      {"record_date": "2026-10-22", "tot_pub_debt_out_amt": "40444342709389.15"},
                      {"record_date": "2026-10-23", "tot_pub_debt_out_amt": "40463151897249.19"}],
             "meta": {"total-pages": 1}}
            """
        let transport = QueuedTransport([(200, body)])
        let document = try await makeDocument(transport)
        let store = document.store
        let preset = try #require(FeedCatalog.preset(id: "debt"))
        #expect(store.addFeedSlot(preset.spec, name: preset.slotName, format: .currency, step: preset.step, atPosition: 5))
        await settle(document)
        let index = try #require(store.slotIndex(atPosition: 5))
        #expect(store.slots[index].name == "NationalDebt")
        #expect(store.slots[index].model == "Data series")
        #expect(store.configs[index].formula.hasPrefix("step 1 day\ninit value = 0 label \"US national debt\" as currency"))
        #expect(store.configs[index].readings.sources.first?.feed?.variable == "value")
        #expect(store.focusedIndex == index)

        let timeline = store.timelineState()
        #expect(timeline.focus.readings.map(\.value) == [40_413_639_012_305.97, 40_444_342_709_389.15, 40_463_151_897_249.19])
        #expect(timeline.focus.yDomain.contains(40_463_151_897_249.19))
        let series = try #require(store.computed?.series[index])
        #expect(ScenarioStore.held(series, at: utc(2026, 10, 23)) == 40_463_151_897_249.19)
        // It holds the latest reading after it.
        #expect(ScenarioStore.held(series, at: utc(2027, 6, 1)) == 40_463_151_897_249.19)
        store.setCursor(utc(2026, 10, 22))
        #expect(store.cursorState().readoutNote == "Reading")
        store.setCursor(utc(2030, 1))
        #expect(store.cursorState().readoutNote == "Projection")

        #expect(document.save())
        let text = try document.package.readText()
        #expect(text.contains("## 6. NationalDebt [Data series, shows: value]"))
        #expect(text.contains("- US national debt [feed: treasury, dataset: v2/accounting/od/debt_to_penny, field: tot_pub_debt_out_amt, into: value]"))
        await document.close()
    }

    @Test("Renaming a slot takes its feed's copy along, without fetching again")
    func rename() async throws {
        let transport = QueuedTransport([(200, Self.yields)])
        let document = try await makeDocument(transport)
        let store = document.store
        store.addFeed(Self.treasuryYield, toSlotAt: 0)
        await settle(document)
        #expect(store.renameSlot(at: 0, to: "Rainy day") == nil)
        await settle(document)
        let folder = document.package.url
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("readings/RainyDay-fred-DGS10.csv").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("readings/Savings-fred-DGS10.csv").path))
        #expect(transport.requests.count == 1)
        await document.close()
    }

    @Test("A source that needs a key isn't asked without one, and says so")
    func needsKey() async throws {
        let transport = QueuedTransport([(200, "[]")])
        let document = try await makeDocument(transport)
        let store = document.store
        store.addFeed(FeedSpec(title: "SPY", provider: "tiingo", settings: [FeedSetting("symbol", "SPY"), FeedSetting("into", "balance")]),
                      toSlotAt: 0)
        await settle(document)
        #expect(transport.requests.isEmpty)
        #expect(store.feedStatuses.values.first?.error == "Tiingo needs an API key. Add one in the feed's settings.")

        try store.credentials.save(FeedCredential(kind: .key, secret: "k", hosts: ["api.tiingo.com"]), named: "tiingo")
        store.refreshFeeds()
        await settle(document)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Token k")
        #expect(store.feedStatuses.values.first?.error == nil)
        await document.close()
    }
}
