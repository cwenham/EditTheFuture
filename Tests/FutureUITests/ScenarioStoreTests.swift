import Foundation
import Testing
import AppKit
import FutureEngine
@testable import FutureUI

/// The engine runs on its own thread, so these tests wait for it (`waitUntilIdle`) before
/// reading results.
@MainActor
@Suite("Scenario store")
struct ScenarioStoreTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    @Test("The demo scenario loads with five slots and a link")
    func loads() async throws {
        let store = try await makeStore()
        #expect(store.slots.map(\.title) == ["Savings", "Index fund", "Mortgage", "Climate", "Energy bill"])
        #expect(store.slots[4].reads == "← Climate.temp")
        #expect(store.linkCount == 1)
        let state = store.panelState()
        #expect(state.lanes.count == 4)
        #expect(state.focus.name == "Savings")
        #expect(!state.focus.samples.isEmpty)
        #expect(state.status.contains("5 of 8 slots"))
        #expect(state.status.contains("Computed through"))
        #expect(state.focus.events.contains { $0.label == "−$6,000" })
    }

    @Test("The main thread never computes: the panel shows what's ready and fills in")
    func backgroundComputation() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        #expect(store.isEngineIdle == false)
        #expect(store.panelState().focus.samples.isEmpty)
        #expect(store.statusText().hasPrefix("Computing"))
        await store.waitUntilIdle()
        #expect(!store.panelState().focus.samples.isEmpty)

        // Jumping far past what's computed shows "…" until the engine catches up.
        store.show(utc(2095, 6))
        let waiting = store.cursorState()
        #expect(waiting.readoutValue == "…")
        #expect(waiting.readoutNote == "Computing")
        await store.waitUntilIdle()
        let ready = store.cursorState()
        #expect(ready.readoutValue.hasPrefix("$"))
        #expect(ready.laneValues.values.allSatisfy { $0 != "…" })
    }

    @Test("Edits reach the engine before the fetches that follow them")
    func editsStayInOrder() async throws {
        let store = try await makeStore()
        store.show(utc(2040, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)
        store.add(Event(time: utc(2030, 1), kind: "deposit", values: ["amount": 10_000]), toSlotAt: 0)
        store.pan(by: 0.3)
        store.pan(by: -0.3)
        await store.waitUntilIdle()
        #expect(try #require(store.cursorState().focusValue) > before + 10_000)
    }

    @Test("Generated events appear on the slot that emits them")
    func generatedEvents() async throws {
        let store = try await makeStore()
        store.focus(named: "climate")
        store.zoom(by: 2)
        await store.waitUntilIdle()
        #expect(store.panelState().focus.events.contains { $0.kind == .generated && $0.label == "Heatwave" })
    }

    @Test("Focus by number or name")
    func focus() async throws {
        let store = try await makeStore()
        #expect(store.focus(named: "3"))
        #expect(store.focused.title == "Mortgage")
        #expect(store.focus(named: "index fund"))
        #expect(store.focused.title == "Index fund")
        #expect(!store.focus(named: "weather"))
    }

    @Test("Panning and zooming stay within limits")
    func panAndZoom() async throws {
        let store = try await makeStore()
        store.pan(by: -10)
        #expect(store.frame.start == store.start)
        let span = store.frame.span
        store.zoom(by: 0.0001)
        #expect(store.frame.span == ScenarioStore.minimumSpan)
        store.zoom(by: 1e6)
        #expect(store.frame.span == ScenarioStore.maximumSpan)
        #expect(span > 0)
        await store.waitUntilIdle()
    }

    @Test("The cursor follows the pointer and jumps to dates")
    func cursor() async throws {
        let store = try await makeStore()
        store.setCursor(fraction: 0)
        #expect(store.cursor == store.frame.start)
        store.show(utc(2060, 1))
        #expect(store.frame.contains(store.cursor))
        store.jumpToNow()
        #expect(store.cursor == now)
        await store.waitUntilIdle()
    }

    @Test("Scrolling carries the cursor along, so the readout follows the pointer far into the future")
    func cursorFollowsScrolling() async throws {
        let store = try await makeStore()
        store.zoom(by: 1e6)
        store.setCursor(fraction: 0.5)
        for _ in 0..<40 { store.pan(by: 0.25) }
        #expect(abs(store.frame.x(store.cursor, width: 1) - 0.5) < 1e-6)
        await store.waitUntilIdle()
        #expect(store.cursorState().readoutValue.hasPrefix("$"))
        #expect(DateText.year(store.cursor) > 2700)
    }

    @Test("Command bar events change the future and can be undone")
    func commandsAndUndo() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)

        store.commandText = "+500 monthly from 2027-01"
        #expect(store.runCommand() == nil)
        #expect(store.commandText.isEmpty)
        #expect(store.message?.contains("every month") == true)
        await store.waitUntilIdle()
        let after = try #require(store.cursorState().focusValue)
        #expect(after > before + 500 * 96)

        store.undo()
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == before)
        store.redo()
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == after)
    }

    @Test("The add-event pane starts at now, on the focused slot, with what that slot can handle")
    func draftDefaults() async throws {
        let store = try await makeStore()
        #expect(store.eventDraft.date == now)
        #expect(store.eventDateIsNow)
        #expect(store.eventDraft.slotIndex == 0)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.parameter == "rate")
        #expect(store.currentValue(ofParameter: "rate") == 0.045)
        #expect(store.panelState().eventPreview == nil)
    }

    @Test("Clicking the graph picks the date; a lane also switches the pane's slot")
    func pickingDates() async throws {
        let store = try await makeStore()
        let clicked = utc(2030, 3, 14)
        store.beginEvent(at: clicked)
        #expect(store.eventDraft.date == Calendar.current.startOfDay(for: clicked))
        #expect(!store.eventDateIsNow)
        #expect(store.eventFieldFocusRequest == 1)

        store.pickEventDate(utc(2031, 1, 1), slotIndex: 3)
        #expect(store.focused.title == "Climate")
        #expect(store.eventDraft.slotIndex == 3)
        #expect(store.eventDraft.kind == .setParameter)
        #expect(store.eventDraft.parameter == "mean")  // Climate's first parameter
        await store.waitUntilIdle()
        #expect(store.currentValue(ofParameter: "warming") == 0.03)

        store.resetEventDate()
        #expect(store.eventDateIsNow)
    }

    @Test("Switching slots keeps the amount when the new slot handles the same kind")
    func retargeting() async throws {
        let store = try await makeStore()
        store.eventDraft.amountText = "750"
        store.focus(index: 1)
        #expect(store.eventDraft.slotIndex == 1)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.amountText == "750")
        #expect(store.eventDraft.parameter == "growth")
        await store.waitUntilIdle()
    }

    @Test("Adding a deposit from the pane changes the future, clears the pane, and can be undone")
    func commitDeposit() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)

        store.pickEventDate(utc(2030, 1, 15))
        store.eventDraft.amountText = "$1,000"
        #expect(store.draftIsComplete)
        await store.waitUntilIdle()
        let preview = try #require(store.panelState().eventPreview)
        #expect(preview.atCursor.hasPrefix("+$1,"))
        #expect(!store.panelState().focus.preview.isEmpty)

        #expect(store.commitEvent())
        #expect(store.eventDraft.amountText.isEmpty)
        #expect(store.eventDateIsNow)
        #expect(store.panelState().eventPreview == nil)
        await store.waitUntilIdle()
        let after = try #require(store.cursorState().focusValue)
        #expect(after > before + 1000)
        #expect(store.panelState().focus.events.contains { $0.label == "+$1,000" })

        store.undo()
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == before)
    }

    @Test("The preview keeps up when scrolling far into the future")
    func previewFollowsScrolling() async throws {
        let store = try await makeStore()
        store.eventDraft.amountText = "200"
        store.eventDraft.repeats = .monthly
        for _ in 0..<12 { store.pan(by: 0.9) }
        await store.waitUntilIdle()
        let state = store.panelState()
        let last = try #require(state.focus.preview.last)
        #expect(last.time >= state.frame.end)
        let preview = try #require(state.eventPreview)
        #expect(preview.atEdge.hasPrefix("+$"))
        #expect(preview.edgeDate == DateText.monthYear(state.frame.end))
    }

    @Test("A recurring deposit and a parameter change from the pane")
    func commitRecurringAndParameter() async throws {
        let store = try await makeStore()
        store.show(utc(2040, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)

        store.pickEventDate(utc(2030, 1, 1))
        store.eventDraft.amountText = "200"
        store.eventDraft.repeats = .monthly
        #expect(store.commitEvent())
        await store.waitUntilIdle()
        let withDeposits = try #require(store.cursorState().focusValue)
        #expect(withDeposits > before + 200 * 119)

        store.pickEventDate(utc(2030, 1, 1))
        store.eventDraft.kind = .setParameter
        store.eventDraft.parameter = "rate"
        store.eventDraft.valueText = "6%"
        #expect(store.commitEvent())
        await store.waitUntilIdle()
        #expect(try #require(store.cursorState().focusValue) > withDeposits)
    }

    @Test("The pane explains what's missing, and clearing leaves the scenario alone")
    func draftErrorsAndClear() async throws {
        let store = try await makeStore()
        store.show(utc(2035, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)

        store.pickEventDate(utc(2030, 1, 1))
        #expect(!store.commitEvent())
        #expect(store.draftError == "Enter an amount, e.g. 500 or 1.2k")
        store.eventDraft.amountText = "lots"
        #expect(!store.commitEvent())
        #expect(store.draftError?.contains("isn't a number") == true)
        store.eventDraft.amountText = "5000"
        #expect(store.draftError == nil)
        store.clearEvent()
        #expect(store.eventDraft.amountText.isEmpty)
        #expect(store.eventDateIsNow)
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == before)
    }

    @Test("goto finds where a line reaches a value, computing as far ahead as it takes")
    func gotoValue() async throws {
        let store = try await makeStore()
        store.commandText = "goto 100°C"
        #expect(store.runCommand() == nil)
        #expect(store.focused.title == "Climate")  // the only slot in °C
        await store.waitUntilIdle()
        #expect(store.messageIsError == false)
        #expect(store.message?.hasPrefix("Climate reaches 100.0 °C in ") == true)
        // July and August average 19.7 °C, plus 0.03 °C a year since 2022: 100 °C comes in July 4699.
        #expect(DateText.monthYear(store.cursor) == "Jul 4699")
        #expect(store.frame.contains(store.cursor))
        let reading = try #require(store.cursorState().focusValue)
        #expect(reading >= 100 && reading < 101)
    }

    @Test("Readouts land on the step at the cursor, even thousands of years out")
    func heldFarAhead() {
        // Far from 2001 a Date can't hold a microsecond's difference; lookups must not rely on one.
        let june = utc(4699, 6), july = utc(4699, 7), august = utc(4699, 8)
        let samples = [Sample(time: june, value: 1), Sample(time: july, value: 2), Sample(time: august, value: 3)]
        #expect(ScenarioStore.held(samples, at: july) == 2)
        #expect(ScenarioStore.held(samples, at: july.addingTimeInterval(-60)) == 1)
        #expect(ScenarioStore.held(samples, at: august.addingTimeInterval(86_400)) == 3)
        #expect(ScenarioStore.held(samples, at: june.addingTimeInterval(-60)) == nil)
    }

    @Test("goto follows a falling line too, and respects edits made just before")
    func gotoFalling() async throws {
        let store = try await makeStore()
        store.commandText = "goto mortgage $0"
        store.runCommand()
        await store.waitUntilIdle()
        #expect(store.focused.title == "Mortgage")
        #expect(store.message?.hasPrefix("Mortgage falls to $0 in ") == true)
        let paidOff = store.cursor
        #expect(try #require(store.cursorState().focusValue) <= 0)

        // An overpayment queued just before the search is counted: the mortgage ends sooner.
        store.add(Event(time: utc(2027, 1), kind: "overpay", values: ["amount": 50_000]), toSlotAt: 2)
        store.commandText = "goto $0"  // Mortgage is focused and in dollars
        store.runCommand()
        await store.waitUntilIdle()
        #expect(store.cursor < paidOff)
    }

    @Test("goto explains a slot it can't pick, a wrong unit, and a value never reached")
    func gotoProblems() async throws {
        let store = try await makeStore()
        store.focus(named: "climate")
        store.commandText = "goto $1M"
        store.runCommand()
        #expect(store.messageIsError)
        #expect(store.message?.hasPrefix("Which slot? Savings, Index fund, Mortgage and Energy bill are in US dollars.") == true)

        store.commandText = "goto climate $5"
        store.runCommand()
        #expect(store.message == "Climate is in °C, not US dollars.")

        store.commandText = "goto weather 5°C"
        store.runCommand()
        #expect(store.message?.hasPrefix("There's no slot called “weather”.") == true)

        let cursor = store.cursor
        store.commandText = "goto savings $1"
        store.runCommand()
        await store.waitUntilIdle()
        #expect(store.message == "Savings doesn't fall to $1 in the next 10,000 years.")
        #expect(store.messageIsError)
        #expect(store.cursor == cursor)
    }

    @Test("Setting an unknown parameter explains what exists")
    func unknownParameter() async throws {
        let store = try await makeStore()
        store.commandText = "set interest 5%"
        store.runCommand()
        #expect(store.messageIsError)
        #expect(store.message?.contains("rate, monthly") == true)
    }

    @Test("Copy commands are handed to the app")
    func copyHandOff() async throws {
        let store = try await makeStore()
        var received: CommandBarAction?
        store.onAppAction = { received = $0 }
        store.commandText = "copy data"
        store.runCommandFromPanel()
        #expect(received == .copyData)
    }

    @Test("Snapshots put the focused slot first and cover the visible range")
    func snapshot() async throws {
        let store = try await makeStore()
        store.focus(named: "Mortgage")
        await store.waitUntilIdle()
        let data = store.snapshotData()
        #expect(data.slots.first?.name == "Mortgage")
        #expect(data.slots.count == 5)
        #expect(data.slots.allSatisfy { !$0.points.isEmpty })
        #expect(data.slots.allSatisfy { $0.points.allSatisfy { $0.t >= data.start && $0.t <= data.end } })
        #expect(data.tsv().split(separator: "\n").count == data.slots[0].points.count + 1)
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
