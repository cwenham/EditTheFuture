import Foundation
import Testing
import AppKit
import FutureEngine
import FutureTestSupport
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Snapshot exporter")
struct SnapshotExporterTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    @Test("The clipboard gets an image, a PDF, a table and the app's own format")
    func clipboard() async throws {
        let store = try await makeStore()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.editthefuture.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try SnapshotExporter.copy(state: store.panelState(), data: store.snapshotData(), contents: .everything, to: pasteboard)

        let png = try #require(pasteboard.data(forType: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let pdf = try #require(pasteboard.data(forType: .pdf))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        let table = try #require(pasteboard.string(forType: SnapshotExporter.tabularText))
        #expect(table.hasPrefix("Date\tSavings (balance, USD)"))
        let json = try #require(pasteboard.data(forType: SnapshotExporter.snapshotType))
        #expect(try SnapshotData.decode(json).scenario == "Home & money")
    }
}
