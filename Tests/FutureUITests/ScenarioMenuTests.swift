import Foundation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// The scenario menu's store and document side (docs/UI.md, 3): settings, renaming, new scenarios.
@MainActor
@Suite("Scenario menu", .serialized)
struct ScenarioMenuTests {
    let now = utc(2026, 10, 25)

    func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("etf-menu-" + UUID().uuidString, isDirectory: true)
    }

    /// "Home & money" in its own folder, named after it as the app names folders.
    func makeScenario(in folder: URL, named name: String = "Home & money") throws -> ScenarioPackage {
        var definition = ScenarioDefinition.homeAndMoney
        definition.name = name
        let package = ScenarioLibrary.package(named: name, in: folder)
        try ScenarioDocument.create(definition, at: package)
        return package
    }

    func open(_ package: ScenarioPackage) async throws -> ScenarioDocument {
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        await document.store.waitUntilIdle()
        return document
    }

    func folderNames(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func actions(folder: URL, document: ScenarioDocument?, opened: @escaping (ScenarioPackage) -> Void = { _ in },
                 saved: @escaping () -> Void = {}) -> ScenarioMenuActions {
        ScenarioMenuActions(folder: folder, current: { document?.package },
                            save: { saved(); document?.save() }, open: opened, showInFinder: {}, openOther: {})
    }

    // MARK: Settings in the store

    @Test("A new start date builds the scenario again, and undo and redo take it back and forth")
    func startDate() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        #expect(store.panelState().focus.samples.first.map { $0.time < utc(2023, 1) } == true)

        store.openScenarioForm(.edit)
        store.scenarioForm?.start = utc(2024, 1)
        #expect(await store.submitScenarioForm(nil))
        #expect(store.scenarioForm == nil)
        #expect(store.start == utc(2024, 1))
        #expect(store.message?.contains("now starts 1 Jan 2024") == true)
        await store.waitUntilIdle()
        #expect(store.panelState().focus.samples.first.map { $0.time >= utc(2024, 1) } == true)
        #expect(store.canUndo)

        store.undo()
        store.show(utc(2022, 3))  // the view stays where it was, so go back to see the old start
        await store.waitUntilIdle()
        #expect(store.start == utc(2022, 1))
        #expect(store.panelState().focus.samples.first.map { $0.time < utc(2023, 1) } == true)
        store.redo()
        await store.waitUntilIdle()
        #expect(store.start == utc(2024, 1))
        #expect(store.panelState().focus.samples.first.map { $0.time >= utc(2024, 1) } == true)
    }

    @Test("A later start moves the cursor and the view along, and earlier edits can still be undone")
    func laterStart() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        store.add(Event(time: utc(2031, 5), kind: "deposit", values: ["amount": 900]), toSlotAt: 0)
        store.applySettingsChange(ScenarioSettings(name: store.name, start: utc(2040, 1), seed: store.seed))
        #expect(store.cursor >= utc(2040, 1))
        #expect(store.frame.start >= utc(2040, 1))
        store.undo()  // the start
        store.undo()  // the deposit
        await store.waitUntilIdle()
        #expect(store.start == utc(2022, 1))
        #expect(!store.configs[0].events.contains { $0.time == utc(2031, 5) })
    }

    @Test("A new name or seed is one change; settings that didn't change aren't one")
    func nameAndSeed() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        var changes = 0
        store.onScenarioChange = { changes += 1 }

        store.openScenarioForm(.edit)
        #expect(await store.submitScenarioForm(nil))
        #expect(!store.canUndo)
        #expect(changes == 0)

        store.openScenarioForm(.edit)
        store.scenarioForm?.name = "  Retirement "
        store.scenarioForm?.seedText = "0x2a"
        #expect(await store.submitScenarioForm(nil))
        #expect(store.name == "Retirement")
        #expect(store.seed == 42)
        #expect(store.scenarioFile().seed == 42)
        #expect(changes > 0)
        store.undo()
        #expect(store.name == "Home & money")
        #expect(store.seed == nil)
        #expect(!store.canUndo)

        // Clearing the seed goes back to the engine's own.
        store.applySettingsChange(ScenarioSettings(name: "Home & money", start: utc(2022, 1), seed: 7))
        store.openScenarioForm(.edit)
        #expect(store.scenarioForm?.seedText == "0x7")
        store.scenarioForm?.seedText = ""
        #expect(await store.submitScenarioForm(nil))
        #expect(store.seed == nil)
    }

    @Test("The form says what's wrong: no name, brackets, a name in use, a seed that isn't a number")
    func formProblems() throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        store.openScenarioForm(.edit, taken: ["retirement", "a-b"])
        var form = try #require(store.scenarioForm)
        #expect(form.name == "Home & money")
        #expect(form.start == utc(2022, 1))
        #expect(form.seedText.isEmpty)
        #expect(form.problem == nil)
        form.name = "   "
        #expect(form.problem == "Give the scenario a name.")
        form.name = "Plan [B]"
        #expect(form.problem == "A name can't have square brackets in it.")
        form.name = "RETIREMENT"
        #expect(form.problem == "There's already a scenario called “RETIREMENT”.")
        form.name = "a/b"  // its folder would be "a-b"
        #expect(form.problem != nil)
        form.name = "Fine"
        form.seedText = "lots"
        #expect(form.problem == "A seed is a whole number, like 0x5EEDF07E.")
        for (text, seed) in [("0x5EEDF07E", UInt64(0x5EEDF07E)), ("1_000", 1000), (" 42 ", 42)] {
            #expect(ScenarioForm.seed(from: text) == .some(seed))
        }
        #expect(ScenarioForm.seed(from: "") == .some(nil))
        #expect(ScenarioForm.seed(from: "-1") == nil)
        #expect(ScenarioForm.text(seed: 0x5EEDF07E) == "0x5EEDF07E")
        #expect(ScenarioForm.seed(from: ScenarioForm.text(seed: ScenarioForm.randomSeed())) != nil)
    }

    @Test("A new scenario starts this year with a name no other scenario uses; a copy keeps the start")
    func formDefaults() throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        store.openScenarioForm(.new, taken: ["new scenario"])
        #expect(store.scenarioForm?.name == "New scenario 2")
        #expect(store.scenarioForm?.start == utc(2026, 1))
        store.openScenarioForm(.duplicate, taken: ["home & money", "home & money copy"])
        #expect(store.scenarioForm?.name == "Home & money copy 2")
        #expect(store.scenarioForm?.start == utc(2022, 1))
        store.closeScenarioForm()
        #expect(store.scenarioForm == nil)
    }

    // MARK: The folder follows the name

    @Test("Renaming in the app renames the folder, and undo puts it back")
    func renameMovesFolder() async throws {
        let folder = makeFolder()
        let package = try makeScenario(in: folder)
        let document = try await open(package)
        var moves: [String] = []
        document.onMove = { moves.append($0.name) }
        let store = document.store

        store.openScenarioForm(.edit, actions: actions(folder: folder, document: document))
        store.scenarioForm?.name = "Retirement: plan/B"
        #expect(await store.submitScenarioForm(nil))
        #expect(document.save())
        #expect(document.package.name == "Retirement- plan-B")
        #expect(folderNames(folder) == ["Retirement- plan-B.etf"])
        #expect(try document.package.readText().hasPrefix("# Retirement: plan/B [start: 2022-01-01]\n"))
        #expect(document.feeds.folder == document.package.url)
        #expect(moves == ["Retirement- plan-B"])

        store.undo()
        #expect(document.save())
        #expect(folderNames(folder) == ["Home & money.etf"])
        #expect(document.package == package)
        #expect(moves.last == "Home & money")

        // A change of case alone renames the folder too.
        store.applySettingsChange(ScenarioSettings(name: "Home & Money", start: store.start, seed: nil))
        #expect(document.save())
        #expect(folderNames(folder) == ["Home & Money.etf"])
        await document.close()
    }

    @Test("A folder with another name, or a name already taken, keeps its name")
    func folderKeepsName() async throws {
        let folder = makeFolder()
        let package = ScenarioPackage(url: folder.appendingPathComponent("Mine.etf"))
        try ScenarioDocument.create(.homeAndMoney, at: package)
        let document = try await open(package)
        document.store.applySettingsChange(ScenarioSettings(name: "Retirement", start: utc(2022, 1), seed: nil))
        #expect(document.save())
        #expect(folderNames(folder) == ["Mine.etf"])
        #expect(try package.readText().hasPrefix("# Retirement [start: 2022-01-01]\n"))
        await document.close()

        let other = try makeScenario(in: folder)
        _ = try makeScenario(in: folder, named: "Taken")
        let second = try await open(other)
        second.store.applySettingsChange(ScenarioSettings(name: "Taken", start: utc(2022, 1), seed: nil))
        #expect(second.save())
        #expect(second.package == other)
        #expect(second.store.message?.contains("keeps its name") == true)
        await second.close()
    }

    @Test("A new name from another app doesn't move the folder")
    func outsideRename() async throws {
        let folder = makeFolder()
        let package = try makeScenario(in: folder)
        let document = try await open(package)
        try package.write(text: try package.readText().replacingOccurrences(of: "# Home & money [", with: "# Elsewhere ["))
        document.checkFile(force: true)
        for _ in 0..<200 where document.isReloadingForTests { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.store.name == "Elsewhere")
        #expect(document.save())
        #expect(folderNames(folder) == ["Home & money.etf"])
        await document.close()
    }

    @Test("A new start date is saved in the heading, and the file reads back with it")
    func savesStart() async throws {
        let folder = makeFolder()
        let package = try makeScenario(in: folder)
        let document = try await open(package)
        document.store.applySettingsChange(ScenarioSettings(name: "Home & money", start: utc(2024, 3), seed: 0x5EEDF07E))
        #expect(document.save())
        let text = try package.readText()
        #expect(text.hasPrefix("# Home & money [start: 2024-03-01, seed: 0x5EEDF07E]\n"))
        let again = try await open(package)
        #expect(again.store.start == utc(2024, 3))
        #expect(again.store.seed == 0x5EEDF07E)
        await document.close()
        await again.close()
    }

    // MARK: The library

    @Test("Folder names leave out slashes, colons and leading dots")
    func folderNamesForScenarios() {
        #expect(ScenarioLibrary.folderName(for: "Home & money") == "Home & money")
        #expect(ScenarioLibrary.folderName(for: " a/b:c ") == "a-b-c")
        #expect(ScenarioLibrary.folderName(for: "..hidden") == "hidden")
        #expect(ScenarioLibrary.folderName(for: "...") == "Untitled")
        #expect(ScenarioLibrary.folderName(for: String(repeating: "é", count: 300)).utf8.count <= 200)
        #expect(ScenarioLibrary.uniqueName("Plan", taken: ["plan", "plan 2"]) == "Plan 3")
    }

    @Test("The menu lists the folder's scenarios in Finder's order, with the open one wherever it is")
    func menuEntries() throws {
        let folder = makeFolder()
        let b = try makeScenario(in: folder, named: "b10")
        let a = try makeScenario(in: folder, named: "b9")
        let c = try makeScenario(in: folder, named: "A")
        let elsewhere = try makeScenario(in: makeFolder(), named: "Outside")
        #expect(ScenarioLibrary.menuEntries(current: b, in: folder) == [c, a, b])
        #expect(ScenarioLibrary.menuEntries(current: elsewhere, in: folder).map(\.name) == ["A", "b9", "b10", "Outside"])
        #expect(ScenarioLibrary.menuEntries(current: nil, in: makeFolder()).isEmpty)
    }

    @Test("New Scenario writes one blank formula and opens it")
    func newScenario() async throws {
        let folder = makeFolder()
        let package = try makeScenario(in: folder)
        let document = try await open(package)
        var opened: [ScenarioPackage] = []
        let menu = actions(folder: folder, document: document, opened: { opened.append($0) })
        let store = document.store

        store.openScenarioForm(.new, actions: menu)
        store.scenarioForm?.name = "Garden"
        store.scenarioForm?.start = utc(2025, 4)
        #expect(await store.submitScenarioForm(menu))
        #expect(store.scenarioForm == nil)
        let made = try #require(opened.first)
        #expect(made.url.lastPathComponent == "Garden.etf")
        #expect(try made.readText().hasPrefix("# Garden [start: 2025-04-01]\n\n## 1. Formula\n"))
        let garden = try await open(made)
        #expect(garden.problems.isEmpty)
        #expect(garden.store.slots.map(\.title) == ["Formula"])
        #expect(garden.store.start == utc(2025, 4))
        #expect(!garden.store.focused.isPaused)

        // A name already used can't be made again.
        store.openScenarioForm(.new, actions: menu)
        store.scenarioForm?.name = "garden"
        #expect(store.scenarioForm?.problem != nil)
        #expect(await !store.submitScenarioForm(menu))
        #expect(opened.count == 1)
        await document.close()
        await garden.close()
    }

    @Test("Duplicate saves the open scenario, then copies it with its readings, under a new name and start")
    func duplicate() async throws {
        let folder = makeFolder()
        let package = try makeScenario(in: folder)
        // Notes, a linked CSV and a cache file, to see what's copied.
        let text = try package.readText().replacingOccurrences(
            of: "## 1. Savings", with: "Notes stay.\n\n## 1. Savings")
            .replacingOccurrences(of: "## 2. IndexFund", with: "### Readings\n- [Statements](readings/statements.csv)\n\n## 2. IndexFund")
        try package.write(text: text)
        try package.write(copies: ["readings/statements.csv": "date,balance\n2023-01-01,19000\n"])
        try FileManager.default.createDirectory(at: package.cacheFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: package.cacheURL(slot: "Savings"))

        let document = try await open(package)
        #expect(document.problems.isEmpty)
        var opened: [ScenarioPackage] = []
        var saves = 0
        let menu = actions(folder: folder, document: document, opened: { opened.append($0) }, saved: { saves += 1 })
        let store = document.store
        store.add(Event(time: utc(2033, 1), kind: "deposit", values: ["amount": 123]), toSlotAt: 0)

        store.openScenarioForm(.duplicate, actions: menu)
        #expect(store.scenarioForm?.name == "Home & money copy")
        store.scenarioForm?.start = utc(2023, 1)
        #expect(await store.submitScenarioForm(menu))
        #expect(saves == 1)
        let copy = try #require(opened.first)
        #expect(copy.name == "Home & money copy")
        let copied = try copy.readText()
        #expect(copied.hasPrefix("# Home & money copy [start: 2023-01-01]\n"))
        #expect(copied.contains("Notes stay."))
        #expect(copied.contains("- 2033-01-01 deposit [amount: 123]"))
        #expect(FileManager.default.fileExists(atPath: copy.url.appendingPathComponent("readings/statements.csv").path))
        #expect(!FileManager.default.fileExists(atPath: copy.cacheFolder.path))
        // The original is as it was, apart from the saved deposit.
        #expect(try package.readText().hasPrefix("# Home & money [start: 2022-01-01]\n"))

        let again = try await open(copy)
        #expect(again.problems.isEmpty)
        #expect(again.store.configs[0].readings.set.variables.contains("balance"))
        await document.close()
        await again.close()
    }
}
