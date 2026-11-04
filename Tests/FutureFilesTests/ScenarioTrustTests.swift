import Foundation
import Testing
import FutureTestSupport
import FutureDocument
import FutureEngine
@testable import FutureKit
@testable import FutureFiles

/// Scenarios from elsewhere wait for the person before running scripts or fetching feeds (docs/UI.md, 7).
@MainActor
@Suite("Scenario trust")
struct ScenarioTrustTests {
    let now = utc(2026, 10, 25)

    /// "Home & money" with a Lua slot, written to a scratch folder, and marked downloaded if asked.
    func makeScenario(downloaded: Bool) throws -> ScenarioPackage {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-trust-" + UUID().uuidString, isDirectory: true)
        let package = ScenarioPackage(url: folder.appendingPathComponent("Shared.etf"))
        var definition = ScenarioDefinition.homeAndMoney
        var script = SlotSpec(name: "Swings", model: ModelLibrary.blankLua.name, kind: .script(.lua),
                              formula: ModelLibrary.blankLua.formula, variable: ModelLibrary.blankLua.variable, format: .number)
        script.position = 6
        definition.slots.append(script)
        try ScenarioDocument.create(definition, at: package)
        if downloaded {
            var values = URLResourceValues()
            values.quarantineProperties = ["LSQuarantineAgentName": "Safari", "LSQuarantineType": "LSQuarantineTypeWebDownload"]
            var url = package.url
            try url.setResourceValues(values)
        }
        return package
    }

    func freshTrust() -> ScenarioTrust {
        ScenarioTrust(defaults: UserDefaults(suiteName: "EditTheFutureTests.trust.\(UUID().uuidString)")!)
    }

    @Test("A downloaded scenario's scripts wait, unbuilt, until they're allowed, and it's remembered")
    func heldUntilAllowed() async throws {
        let package = try makeScenario(downloaded: true)
        #expect(ScenarioTrust.cameFromElsewhere(package))
        let trust = freshTrust()
        #expect(!trust.allows(package))

        let document = try await ScenarioDocument.open(package, now: now, watch: false, trust: trust)
        let store = document.store
        await store.waitUntilIdle()
        let request = try #require(store.trustRequest)
        #expect(request.scripts == 1 && request.feeds == 0)
        #expect(request.waiting == "1 script")
        #expect(store.isHeld)
        let script = try #require(store.slots.first { $0.name == "Swings" })
        #expect(script.pausedReason == TrustRequest.heldReason)
        // Formulas run as usual.
        #expect(store.slots.first { $0.name == "Savings" }?.pausedReason == nil)

        store.allowHeldScenario()
        await store.waitUntilIdle()
        #expect(store.trustRequest == nil && !store.isHeld)
        #expect(store.slots.first { $0.name == "Swings" }?.pausedReason == nil)
        #expect(trust.allowed == [package.url.standardizedFileURL.path])
        await document.close()

        let again = try await ScenarioDocument.open(package, now: now, watch: false, trust: trust)
        #expect(again.store.trustRequest == nil)
        await again.close()
        trust.forget(package.url.standardizedFileURL.path)
        #expect(!trust.allows(package))
    }

    @Test("Scenarios made here, or with asking turned off, run straight away; Not Now leaves them waiting")
    func notHeld() async throws {
        let mine = try makeScenario(downloaded: false)
        #expect(!ScenarioTrust.cameFromElsewhere(mine))
        let trust = freshTrust()
        #expect(trust.allows(mine))
        let document = try await ScenarioDocument.open(mine, now: now, watch: false, trust: trust)
        #expect(document.store.trustRequest == nil && !document.store.isHeld)
        await document.close()

        let downloaded = try makeScenario(downloaded: true)
        let held = try await ScenarioDocument.open(downloaded, now: now, watch: false, trust: trust)
        held.store.dismissTrustRequest()
        #expect(held.store.trustRequest == nil && held.store.isHeld)
        #expect(held.store.slots.first { $0.name == "Swings" }?.pausedReason == TrustRequest.heldReason)
        await held.close()

        trust.asksFirst = false
        #expect(trust.allows(downloaded))
        // Asking is on to start with.
        #expect(freshTrust().asksFirst)
    }

    @Test("Live rates are checked as often as Settings says")
    func liveRateInterval() {
        let before = RateCenter.liveRefresh
        defer { RateCenter.liveRefresh = before }
        #expect(before == 600)
        RateCenter.liveRefresh = 3_600
        #expect(RateCenter.liveRefresh == 3_600)
    }
}
