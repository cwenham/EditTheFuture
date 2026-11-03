import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// A settled slot's line runs to the edge of the view, though its next point is decades away.
@MainActor
@Suite("Held lines")
struct HeldLineTests {
    @Test("A worm that settled at 20:27 still draws its line to the edge")
    func reachesTheEdge() async throws {
        var worm = try #require(ModelLibrary.template(id: "worm")).slot(position: 0)
        worm.values = ["patching": 0.2]
        let store = try ScenarioStore(definition: ScenarioDefinition(name: "W", start: utc(2026, 1, 1), slots: [worm]),
                                      now: utc(2026, 11, 3))
        await store.waitUntilIdle()
        store.show(utc(2026, 1, 1).addingTimeInterval(12 * 3_600))
        store.zoom(by: 1e-12)
        store.zoom(by: 16)
        await store.waitUntilIdle()
        let samples = store.timelineState().focus.samples
        let last = try #require(samples.last)
        #expect(last.time >= store.frame.end)
        #expect(store.statusText().hasPrefix("Every slot has settled"))
    }
}
