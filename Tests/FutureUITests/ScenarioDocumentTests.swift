import Foundation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// Scenarios saved in their folders (docs/DESIGN.md, 15).
@MainActor
@Suite("Scenario documents", .serialized)
struct ScenarioDocumentTests {
    let now = utc(2026, 10, 25)

    func makePackage(_ definition: ScenarioDefinition = .homeAndMoney) throws -> ScenarioPackage {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-doc-" + UUID().uuidString, isDirectory: true)
        let package = ScenarioPackage(url: folder.appendingPathComponent("Test.etf"))
        try ScenarioDocument.create(definition, at: package)
        return package
    }

    func open(_ package: ScenarioPackage) async throws -> ScenarioDocument {
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        await document.store.waitUntilIdle()
        return document
    }

    @Test("The built-in scenario saves, opens with the same slots and events, and saves again unchanged")
    func roundTrip() async throws {
        let package = try makePackage()
        let text = try package.readText()
        #expect(text.hasPrefix("# Home & money [start: 2022-01-01]\n\n## 1. Savings [Savings account, shows: balance]\n"))
        #expect(text.contains("- 2028-08-01 withdraw [amount: 6000]"))
        #expect(text.contains("- 2027-04-01 set [tariff: 1.12]"))

        let document = try await open(package)
        #expect(document.problems.isEmpty)
        let store = document.store
        #expect(store.slots.map(\.title) == ["Savings", "Index fund", "Mortgage", "Climate", "Energy bill"])
        #expect(store.linkCount == 1)
        #expect(store.focused.format == .currency)
        #expect(store.slots[3].format == .temperature)
        #expect(store.panelState().focus.events.contains { $0.label == "−$6,000" })
        // Nothing changed, so saving leaves the file as it was.
        #expect(document.save())
        #expect(try package.readText() == text)
    }

    @Test("Changes in the app are saved, and an added event keeps its id when the file is read again")
    func savesChanges() async throws {
        let package = try makePackage()
        let document = try await open(package)
        let store = document.store
        store.add(Event(time: utc(2030, 3), kind: "deposit", values: ["amount": 2500]), toSlotAt: 0)
        let added = try #require(store.configs[0].events.last)
        #expect(document.save())
        let text = try package.readText()
        #expect(text.contains("- 2030-03-01 deposit [amount: 2500]"))

        let again = try await open(package)
        #expect(again.store.configs[0].events.contains(added))
        await document.close()
        await again.close()
    }

    @Test("A change from another app is loaded, and undo takes it back")
    func outsideChange() async throws {
        let package = try makePackage()
        let document = try await open(package)
        let store = document.store
        let before = try #require(store.slots[0].parameterValues.first { $0.name == "monthly" }?.value)

        let original = try package.readText()
        let edited = original.replacingOccurrences(of: "## 1. Savings [Savings account, shows: balance]\n",
                                                   with: "## 1. Savings [Savings account, shows: balance]\n\nMy notes.\n\n### Values\n- monthly: 999\n")
        try package.write(text: edited)
        document.checkFile(force: true)
        await waitForReload(document)
        await store.waitUntilIdle()
        #expect(store.slots[0].parameterValues.first { $0.name == "monthly" }?.value == 999)
        #expect(store.message?.contains("Loaded the changes") == true)
        // The app doesn't write the file back after reading it.
        #expect(document.save())
        #expect(try package.readText() == edited)

        store.undo()
        await store.waitUntilIdle()
        #expect(store.slots[0].parameterValues.first { $0.name == "monthly" }?.value == before)
        #expect(document.save())
        let saved = try package.readText()
        #expect(!saved.contains("- monthly: 999"))
        #expect(saved.contains("My notes."))
    }

    @Test("While another app's change can't be read, the app doesn't save over it")
    func unreadableChange() async throws {
        let package = try makePackage()
        let document = try await open(package)
        let store = document.store
        let broken = try package.readText().replacingOccurrences(of: "[start: 2022-01-01]", with: "[start: soon]")
        try package.write(text: broken)
        document.checkFile(force: true)
        await waitForReload(document)
        #expect(document.unreadableReason != nil)
        #expect(store.messageIsError)

        store.add(Event(time: utc(2031, 1), kind: "deposit", values: ["amount": 1]), toSlotAt: 0)
        #expect(!document.save())
        #expect(try package.readText() == broken)

        // Fixed in the other app: it loads, and the app's own change goes after it.
        try package.write(text: broken.replacingOccurrences(of: "[start: soon]", with: "[start: 2022-01-01]"))
        document.checkFile(force: true)
        await waitForReload(document)
        #expect(document.unreadableReason == nil)
    }

    @Test("A new start date from another app builds the scenario again")
    func newStart() async throws {
        let package = try makePackage()
        let document = try await open(package)
        let store = document.store
        try package.write(text: try package.readText().replacingOccurrences(of: "[start: 2022-01-01]", with: "[start: 2024-01-01]"))
        document.checkFile(force: true)
        await waitForReload(document)
        await store.waitUntilIdle()
        #expect(store.start == utc(2024, 1))
        #expect(!store.canUndo)
        #expect(!store.panelState().focus.samples.isEmpty)
        #expect(store.panelState().focus.samples.first.map { $0.time >= utc(2024, 1) } == true)
    }

    @Test("Mistakes in the file are reported, and a slot without a model is paused")
    func mistakes() async throws {
        let package = try makePackage()
        try package.write(text: """
            # Plans [start: 2020-01-01]

            ## 1. Savings [Savings account]

            ```etf
            step 1 month
            param rate = 5%
            init balance = 100
            balance[t] = balance[t-1] * (1 + rate / 12)
            ```

            ### Values
            - rate: 4%
            - colour: 3

            ### Events
            - 2021-02-30 deposit [amount: 5]

            ## 2. Later

            Nothing yet.
            """)
        let document = try await open(package)
        let store = document.store
        #expect(document.problems.count == 3)
        #expect(document.problems.contains { $0.contains("Line 17") })
        #expect(document.problems.contains { $0.contains("colour, which its model doesn't have") })
        #expect(store.message?.hasPrefix("scenario.md: ") == true)
        #expect(store.slots.map(\.title) == ["Savings", "Later"])
        #expect(store.slots[1].isPaused)
        #expect(!store.slots[0].isPaused)
        #expect(store.slots[0].parameterValues.first { $0.name == "rate" }?.value == 0.04)
        // Saving keeps the file as written, mistakes and all.
        let text = try package.readText()
        #expect(document.save())
        #expect(try package.readText() == text)
    }

    @Test("Readings in the file reach the slot")
    func readings() async throws {
        let package = try makePackage()
        try package.write(text: """
            # Plans [start: 2020-01-01]

            ## 1. Savings

            ```etf
            step 1 month
            init balance = 100
            balance[t] = balance[t-1] + 1
            ```

            ### Readings

            ```csv
            date,balance
            2020-02-01,101.5
            2020-03-01,102
            ```

            - [Statements](readings/statements.csv)
            """)
        try FileManager.default.createDirectory(at: package.url.appendingPathComponent("readings"), withIntermediateDirectories: true)
        try "date,balance\n2020-04-01,104\n".write(to: package.url.appendingPathComponent("readings/statements.csv"),
                                                   atomically: true, encoding: .utf8)
        let document = try await open(package)
        #expect(document.problems.isEmpty)
        #expect(document.store.configs[0].readings.set.readings.map(\.value) == [101.5, 102, 104])
    }

    @Test("Slow slots' results are cached on closing, and used when the scenario opens again")
    func cache() async throws {
        let threshold = ScenarioDocument.cacheThreshold
        ScenarioDocument.cacheThreshold = 0
        defer { ScenarioDocument.cacheThreshold = threshold }

        let package = try makePackage()
        let document = try await open(package)
        document.store.show(utc(2090, 1))
        await document.store.waitUntilIdle()
        let values = document.store.cursorState().laneValues
        await document.close()
        let cached = package.cachedSlots()
        #expect(Set(cached.keys) == ["Savings", "IndexFund", "Mortgage", "Climate", "EnergyBill"])

        let loaded = try ScenarioDocument.load(package)
        #expect(loaded.results.count == 5)
        let reopened = try await open(package)
        reopened.store.show(utc(2090, 1))
        await reopened.store.waitUntilIdle()
        #expect(reopened.store.cursorState().laneValues == values)

        // A changed formula retires its slot's cache, and the cache of the slot that reads it.
        try package.write(text: try package.readText().replacingOccurrences(of: "param warming = 0.03", with: "param warming = 0.05"))
        let changed = try ScenarioDocument.load(package)
        #expect(Set(changed.results.keys) == ["Savings", "IndexFund", "Mortgage"])
        await reopened.close()
        // Closing removes the files that no longer match (nothing is slow enough to save this time).
        ScenarioDocument.cacheThreshold = .infinity
        let stale = try await open(package)
        await stale.close()
        #expect(Set(package.cachedSlots().keys) == ["Savings", "IndexFund", "Mortgage"])
    }

    @Test("A new library sets up the built-in scenario, then opens the one used last")
    func library() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-lib-" + UUID().uuidString, isDirectory: true)
        let first = try ScenarioLibrary.initial(lastOpened: nil, in: folder)
        #expect(first.url.lastPathComponent == "Home & money.etf")
        #expect(FileManager.default.fileExists(atPath: first.scenarioURL.path))
        let other = ScenarioPackage(url: folder.appendingPathComponent("Another.etf"))
        try ScenarioDocument.create(.homeAndMoney, at: other)
        #expect(ScenarioLibrary.scenarios(in: folder).map(\.name) == ["Another", "Home & money"])
        #expect(try ScenarioLibrary.initial(lastOpened: first.url, in: folder) == first)
        #expect(try ScenarioLibrary.initial(lastOpened: folder.appendingPathComponent("Gone.etf"), in: folder) == other)
    }

    /// Waits for a reload started by `checkFile` to finish.
    func waitForReload(_ document: ScenarioDocument) async {
        for _ in 0..<200 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
            if !document.isReloadingForTests { return }
        }
    }
}
