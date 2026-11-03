import Foundation
import Testing
import FutureTestSupport
import FutureEngine
import FutureFeeds
import FutureSimulation
import FutureVisuals
@testable import FutureKit

/// What an app that embeds FutureKit can give a scenario (docs/DESIGN.md, 2.1): its own modules,
/// backdrops, models and sign-ins, used in place of the app's.
@MainActor
@Suite("Scenario configuration")
struct ConfigurationTests {
    let now = utc(2026, 10, 25)

    func makeStore(_ configuration: ScenarioConfiguration) async throws -> ScenarioStore {
        let definition = ScenarioDefinition(name: "Outbreak", start: utc(2026, 1, 1),
                                            slots: [ModelLibrary.epidemic.slot(position: 0)])
        let store = try ScenarioStore(definition: definition, now: now, configuration: configuration)
        await store.waitUntilIdle()
        return store
    }

    @Test("The standard configuration is the app's: its modules, backdrops and every library model")
    func standard() async throws {
        let store = try await makeStore(.standard)
        #expect(!store.slots[0].isPaused)
        #expect(store.configuration.templates.map(\.id) == ModelLibrary.all.map(\.id))
        #expect(!store.backdropChoices(forSlotAt: 0).isEmpty)
    }

    @Test("Modules come from the configuration: a slot whose module isn't there pauses, and the picker doesn't offer it")
    func modules() async throws {
        let store = try await makeStore(ScenarioConfiguration(modules: ModuleCatalog(modules: [])))
        #expect(store.slots[0].isPaused)
        #expect(!store.configuration.templates.contains { if case .module = $0.kind { true } else { false } })
        #expect(store.configuration.templates.contains { $0.id == "savings-account" })
    }

    @Test("Backdrops come from the configuration")
    func backdrops() async throws {
        let store = try await makeStore(ScenarioConfiguration(backdrops: BackdropCatalog([])))
        #expect(!store.slots[0].isPaused)
        #expect(store.backdropChoices(forSlotAt: 0).isEmpty)
        store.setBackdrop(BackdropBinding(id: "parts", field: "groups"), inSlotAt: 0)
        await store.waitUntilIdle()
        #expect(store.backdropState() == nil)
    }

    @Test("Sign-ins are kept where the configuration says")
    func credentials() async throws {
        let keys = MemoryCredentialStore(["fred": FeedCredential(kind: .key, secret: "abc", hosts: ["api.stlouisfed.org"])])
        let store = try await makeStore(ScenarioConfiguration(credentials: keys))
        #expect(store.credentials.hasCredential(named: "fred"))
    }
}
