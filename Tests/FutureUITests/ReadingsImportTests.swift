import Foundation
import Testing
import FutureCommands
import FutureDocument
import FutureEngine
@testable import FutureUI

/// Importing readings from files and the clipboard, and adding single readings from the command
/// bar, the etf tool and Shortcuts (docs/DESIGN.md, 14; docs/UI.md, 5.10).
@MainActor
@Suite("Importing readings", .serialized)
struct ReadingsImportTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    /// Monthly balances as a spreadsheet would copy them: tab-separated, with a header.
    func spreadsheet(months: Int, from year: Int = 2020) -> String {
        var lines = ["Month\tBalance"]
        for index in 0..<months {
            let balance: Double = 10_000 + 100 * Double(index)
            lines.append(String(format: "%04d-%02d-01\t%.2f", year + index / 12, index % 12 + 1, balance))
        }
        return lines.joined(separator: "\n")
    }

    func readings(_ store: ScenarioStore, slot index: Int = 0) -> [Reading] {
        store.configs[index].readings.set.readings
    }

    @Test("Pasting opens the import sheet with the columns guessed, and importing adds the readings in scenario.md")
    func pasteSmall() async throws {
        let store = try await makeStore()
        store.pasteReadings(spreadsheet(months: 24), slotAt: 0)
        let state = try #require(store.readingImport)
        #expect(store.sidePane == .slot)
        #expect(state.origin == "the clipboard")
        #expect(state.columns == ["Month", "Balance"])
        #expect(state.dateColumn == 0 && state.valueColumn == 1)
        // A column named like one of the slot's values is a reading of it.
        #expect(state.variable == "balance")
        let preview = try #require(state.preview)
        #expect(preview.count == 24)
        #expect(preview.summary == "24 readings from Jan 2020 to Dec 2021. The latest: $12,300.")
        #expect(preview.destination == "They'll be kept in scenario.md, under Savings.")
        #expect(preview.notes == nil)

        store.applyReadingImport()
        #expect(store.readingImport == nil)
        #expect(readings(store).count == 24)
        #expect(readings(store).first == Reading(time: utc(2020, 1, 1), variable: "balance", value: 10_000))
        guard case .inline(let csv) = store.configs[0].readings.sources.last else {
            Issue.record("Expected readings written in scenario.md")
            return
        }
        #expect(csv.hasPrefix("date,balance\n2020-01-01,10000\n"))
        #expect(store.message == "Imported 24 readings of balance into Savings. ⌘Z takes them out.")
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.readings.isEmpty || store.frame.start > utc(2021, 12, 1))

        store.undo()
        #expect(readings(store).isEmpty)
        store.redo()
        #expect(readings(store).count == 24)
    }

    @Test("A large file is saved in readings/ and linked, and reads back the same after saving")
    func importLargeFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-import-" + UUID().uuidString, isDirectory: true)
        let package = ScenarioPackage(url: folder.appendingPathComponent("Test.etf"))
        try ScenarioDocument.create(.homeAndMoney, at: package)
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        let store = document.store
        await store.waitUntilIdle()

        let file = folder.appendingPathComponent("bank_statements.csv")
        try spreadsheet(months: 150).replacingOccurrences(of: "\t", with: ",").write(to: file, atomically: true, encoding: .utf8)
        store.importReadings(from: file, slotAt: 0)
        await store.waitForImport()
        let state = try #require(store.readingImport)
        #expect(state.title == "Bank statements")
        #expect(state.preview?.destination == "They'll be saved as readings/Savings-Bank-statements.csv.")
        store.setImportTitle("Statements")
        #expect(store.readingImport?.preview?.destination == "They'll be saved as readings/Savings-Statements.csv.")
        store.applyReadingImport()
        #expect(store.configs[0].readings.sources.last == .csvFile(title: "Statements", path: "readings/Savings-Statements.csv"))
        let saved = try String(contentsOf: package.url.appendingPathComponent("readings/Savings-Statements.csv"), encoding: .utf8)
        #expect(try CSVReadings.parse(saved).count == 150)

        #expect(document.save())
        #expect(try package.readText().contains("- [Statements](readings/Savings-Statements.csv)"))
        let again = try await ScenarioDocument.open(package, now: now, watch: false)
        #expect(again.store.configs[0].readings.set.readings.count == 150)
        #expect(again.problems.isEmpty)

        // A second import with the same title gets a file of its own.
        store.pasteReadings(spreadsheet(months: 120, from: 2010), slotAt: 0)
        store.setImportTitle("Statements")
        #expect(store.readingImport?.preview?.destination == "They'll be saved as readings/Savings-Statements-2.csv.")
        store.cancelReadingImport()
        await document.close()
        await again.close()
    }

    @Test("The sheet explains choices that give no readings, and closes when another slot is focused")
    func choices() async throws {
        let store = try await makeStore()
        store.pasteReadings("Date,Note,Amount\n2026-01-01,hello,5\n2026-01-02,,x\n", slotAt: 0)
        #expect(store.readingImport?.preview?.notes == "1 row has no date or number there, and is left out.")
        store.setImportColumns(date: 0, value: 0)
        #expect(store.readingImport?.problem == "The dates and the values need different columns.")
        store.setImportColumns(date: 0, value: 1)
        #expect(store.readingImport?.problem == "No row has both a date and a number in those columns.")
        #expect(store.readingImport?.canImport == false)
        store.setImportColumns(date: nil, value: 2)
        #expect(store.readingImport?.problem == "Choose the column with the dates.")
        store.focus(index: 1)
        #expect(store.readingImport == nil)

        store.pasteReadings("   ", slotAt: 0)
        #expect(store.readingImport == nil)
        #expect(store.messageIsError)
    }

    @Test("Removing an imported source takes its readings away, and undo brings them back")
    func removeSource() async throws {
        let store = try await makeStore()
        store.pasteReadings(spreadsheet(months: 12), slotAt: 0)
        store.applyReadingImport()
        let position = store.configs[0].readings.sources.count - 1
        store.removeReadingSource(at: position, inSlotAt: 0)
        #expect(readings(store).isEmpty)
        #expect(store.message == "Removed the readings written in scenario.md. ⌘Z brings it back.")
        store.undo()
        #expect(readings(store).count == 12)
    }

    @Test("The command bar adds single readings, today unless dated, and a second one for a date replaces the first")
    func commandBar() async throws {
        let store = try await makeStore()
        store.commandText = "reading 41,200 on 2026-10-01"
        store.runCommand()
        #expect(readings(store) == [Reading(time: utc(2026, 10, 1), variable: "balance", value: 41_200)])
        #expect(store.message == "Added a reading of balance, $41,200, on 1 Oct 2026 in Savings")

        store.commandText = "reading savings $41,300 on 2026-10-01"
        store.runCommand()
        #expect(readings(store).map(\.value) == [41_300])
        #expect(store.message?.hasPrefix("Replaced a reading") == true)

        store.commandText = "reading climate 21.5°C"
        store.runCommand()
        let climate = try #require(store.slotIndex(named: "climate"))
        #expect(readings(store, slot: climate).map(\.value) == [21.5])
        #expect(readings(store, slot: climate).first?.time == ScenarioStore.today())

        store.commandText = "reading climate $5"
        store.runCommand()
        #expect(store.messageIsError)
        #expect(store.message == "Climate isn't in money. Type the reading without a unit, or choose another slot.")
        store.commandText = "reading savings €5"
        store.runCommand()
        #expect(store.message == "Savings is in US dollars. Type the reading in $, or without a currency.")

        store.undo()
        #expect(readings(store, slot: climate).isEmpty)
    }

    @Test("A typed reading reads back from scenario.md as the same source, and saving again changes nothing")
    func readingRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-reading-" + UUID().uuidString, isDirectory: true)
        let package = ScenarioPackage(url: folder.appendingPathComponent("Test.etf"))
        try ScenarioDocument.create(.homeAndMoney, at: package)
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        document.store.commandText = "reading 41,200 on 2026-10-01"
        document.store.runCommand()
        #expect(document.save())
        let text = try package.readText()
        #expect(text.contains("### Readings\n```csv\ndate,balance\n2026-10-01,41200\n```"))

        let again = try await ScenarioDocument.open(package, now: now, watch: false)
        #expect(again.store.configs[0].readings.sources == document.store.configs[0].readings.sources)
        #expect(again.save())
        #expect(try package.readText() == text)
        await document.close()
        await again.close()
    }

    @Test("Readings from the etf tool and Shortcuts are checked like the panel's, and say what they'd add first")
    func outside() async throws {
        let store = try await makeStore()
        let request = ReadingRequest(slot: "savings", value: Amount(41_200), at: PartialDate(year: 2026, month: 10, day: 1))
        #expect(store.describe(request) == .success("Add a reading of balance, $41,200, on 1 Oct 2026 in Savings"))
        #expect(readings(store).isEmpty)
        let reply = store.addReading(request)
        #expect(reply.ok)
        #expect(readings(store).count == 1)

        // Another of its values, by name, with a plain number for a percent read in percent.
        let rate = store.addReading(ReadingRequest(slot: "savings", variable: "rate", value: Amount(4.5),
                                                   at: PartialDate(year: 2026, month: 10, day: 1)))
        #expect(rate.ok)
        #expect(readings(store).contains(Reading(time: utc(2026, 10, 1), variable: "rate", value: 0.045)))

        #expect(!store.addReading(ReadingRequest(slot: "savings", variable: "colour", value: Amount(1))).ok)
        #expect(!store.addReading(ReadingRequest(slot: "savings", value: Amount(1), currency: "£")).ok)
        #expect(!store.addReading(ReadingRequest(slot: "nowhere", value: Amount(1))).ok)
    }
}
