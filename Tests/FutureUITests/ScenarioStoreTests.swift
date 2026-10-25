import Foundation
import Testing
import AppKit
import FutureEngine
@testable import FutureUI

@MainActor
@Suite("Scenario store")
struct ScenarioStoreTests {
    let now = utc(2026, 10, 25)

    func makeStore() throws -> ScenarioStore {
        try ScenarioStore(definition: .homeAndMoney, now: now)
    }

    @Test("The demo scenario loads with five slots and a link")
    func loads() throws {
        let store = try makeStore()
        #expect(store.slots.map(\.title) == ["Savings", "Index fund", "Mortgage", "Climate", "Energy bill"])
        #expect(store.slots[4].reads == "← Climate.temp")
        #expect(store.linkCount == 1)
        let state = store.panelState()
        #expect(state.lanes.count == 4)
        #expect(state.focus.name == "Savings")
        #expect(!state.focus.samples.isEmpty)
        #expect(state.status.contains("5 of 8 slots"))
        #expect(state.focus.events.contains { $0.label == "−$6,000" })
    }

    @Test("Generated events appear on the slot that emits them")
    func generatedEvents() throws {
        let store = try makeStore()
        store.focus(named: "climate")
        store.zoom(by: 2)
        #expect(store.panelState().focus.events.contains { $0.kind == .generated && $0.label == "Heatwave" })
    }

    @Test("Focus by number or name")
    func focus() throws {
        let store = try makeStore()
        #expect(store.focus(named: "3"))
        #expect(store.focused.title == "Mortgage")
        #expect(store.focus(named: "index fund"))
        #expect(store.focused.title == "Index fund")
        #expect(!store.focus(named: "weather"))
    }

    @Test("Panning and zooming stay within limits")
    func panAndZoom() throws {
        let store = try makeStore()
        store.pan(by: -10)
        #expect(store.frame.start == store.start)
        let span = store.frame.span
        store.zoom(by: 0.0001)
        #expect(store.frame.span == ScenarioStore.minimumSpan)
        store.zoom(by: 1e6)
        #expect(store.frame.span == ScenarioStore.maximumSpan)
        #expect(span > 0)
    }

    @Test("The cursor follows the pointer and jumps to dates")
    func cursor() throws {
        let store = try makeStore()
        store.setCursor(fraction: 0)
        #expect(store.cursor == store.frame.start)
        store.show(utc(2060, 1))
        #expect(store.frame.contains(store.cursor))
        store.jumpToNow()
        #expect(store.cursor == now)
    }

    @Test("Command bar events change the future and can be undone")
    func commandsAndUndo() throws {
        let store = try makeStore()
        let date = utc(2035, 1)
        store.show(date)
        let before = try #require(store.panelState().cursor.focusValue)

        store.commandText = "+500 monthly from 2027-01"
        #expect(store.runCommand() == nil)
        #expect(store.commandText.isEmpty)
        #expect(store.message?.contains("every month") == true)
        let after = try #require(store.panelState().cursor.focusValue)
        #expect(after > before + 500 * 96)

        store.undo()
        #expect(store.panelState().cursor.focusValue == before)
        store.redo()
        #expect(store.panelState().cursor.focusValue == after)
    }

    @Test("The add-event pane starts at now, on the focused slot, with what that slot can handle")
    func draftDefaults() throws {
        let store = try makeStore()
        #expect(store.eventDraft.date == now)
        #expect(store.eventDateIsNow)
        #expect(store.eventDraft.slotIndex == 0)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.parameter == "rate")
        #expect(store.eventDraft.valueText == "0.045")
        #expect(store.panelState().eventPreview == nil)
    }

    @Test("Clicking the graph picks the date; a lane also switches the pane's slot")
    func pickingDates() throws {
        let store = try makeStore()
        let clicked = utc(2030, 3, 14)
        store.beginEvent(at: clicked)
        #expect(store.eventDraft.date == Calendar.current.startOfDay(for: clicked))
        #expect(!store.eventDateIsNow)
        #expect(store.eventFieldFocusRequest == 1)

        store.pickEventDate(utc(2031, 1, 1), slotIndex: 3)
        #expect(store.focused.title == "Climate")
        #expect(store.eventDraft.slotIndex == 3)
        #expect(store.eventDraft.kind == .setParameter)
        #expect(store.eventDraft.parameter == "warming")

        store.resetEventDate()
        #expect(store.eventDateIsNow)
    }

    @Test("Switching slots keeps the amount when the new slot handles the same kind")
    func retargeting() throws {
        let store = try makeStore()
        store.eventDraft.amountText = "750"
        store.focus(index: 1)
        #expect(store.eventDraft.slotIndex == 1)
        #expect(store.eventDraft.kind == .event("deposit"))
        #expect(store.eventDraft.amountText == "750")
        #expect(store.eventDraft.parameter == "growth")
    }

    @Test("Adding a deposit from the pane changes the future, clears the pane, and can be undone")
    func commitDeposit() throws {
        let store = try makeStore()
        store.show(utc(2035, 1))
        let before = try #require(store.panelState().cursor.focusValue)

        store.pickEventDate(utc(2030, 1, 15))
        store.eventDraft.amountText = "$1,000"
        let preview = try #require(store.panelState().eventPreview)
        #expect(preview.atCursor.hasPrefix("+$1,"))
        #expect(!store.panelState().focus.preview.isEmpty)

        #expect(store.commitEvent())
        #expect(store.eventDraft.amountText.isEmpty)
        #expect(store.eventDateIsNow)
        #expect(store.panelState().eventPreview == nil)
        let after = try #require(store.panelState().cursor.focusValue)
        #expect(after > before + 1000)
        #expect(store.panelState().focus.events.contains { $0.label == "+$1,000" })

        store.undo()
        #expect(store.panelState().cursor.focusValue == before)
    }

    @Test("The preview keeps up when scrolling far into the future")
    func previewFollowsScrolling() throws {
        let store = try makeStore()
        store.eventDraft.amountText = "200"
        store.eventDraft.repeats = .monthly
        for _ in 0..<12 { store.pan(by: 0.9) }
        let state = store.panelState()
        let last = try #require(state.focus.preview.last)
        #expect(last.time >= state.frame.end)
        let preview = try #require(state.eventPreview)
        #expect(preview.atEdge.hasPrefix("+$"))
        #expect(preview.edgeDate == DateText.monthYear(state.frame.end))
    }

    @Test("A recurring deposit and a parameter change from the pane")
    func commitRecurringAndParameter() throws {
        let store = try makeStore()
        store.show(utc(2040, 1))
        let before = try #require(store.panelState().cursor.focusValue)

        store.pickEventDate(utc(2030, 1, 1))
        store.eventDraft.amountText = "200"
        store.eventDraft.repeats = .monthly
        #expect(store.commitEvent())
        let withDeposits = try #require(store.panelState().cursor.focusValue)
        #expect(withDeposits > before + 200 * 119)

        store.pickEventDate(utc(2030, 1, 1))
        store.eventDraft.kind = .setParameter
        store.eventDraft.parameter = "rate"
        store.eventDraft.valueText = "6%"
        #expect(store.commitEvent())
        #expect(try #require(store.panelState().cursor.focusValue) > withDeposits)
    }

    @Test("The pane explains what's missing, and clearing leaves the scenario alone")
    func draftErrorsAndClear() throws {
        let store = try makeStore()
        store.show(utc(2035, 1))
        let before = try #require(store.panelState().cursor.focusValue)

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
        #expect(store.panelState().cursor.focusValue == before)
    }

    @Test("Setting an unknown parameter explains what exists")
    func unknownParameter() throws {
        let store = try makeStore()
        store.commandText = "set interest 5%"
        store.runCommand()
        #expect(store.messageIsError)
        #expect(store.message?.contains("rate, monthly") == true)
    }

    @Test("Copy commands are handed to the app")
    func copyHandOff() throws {
        let store = try makeStore()
        var received: CommandBarAction?
        store.onAppAction = { received = $0 }
        store.commandText = "copy data"
        store.runCommandFromPanel()
        #expect(received == .copyData)
    }

    @Test("Snapshots put the focused slot first and cover the visible range")
    func snapshot() throws {
        let store = try makeStore()
        store.focus(named: "Mortgage")
        let data = store.snapshotData()
        #expect(data.slots.first?.name == "Mortgage")
        #expect(data.slots.count == 5)
        #expect(data.slots.allSatisfy { $0.points.allSatisfy { $0.t >= data.start && $0.t <= data.end } })
        #expect(data.tsv().split(separator: "\n").count == data.slots[0].points.count + 1)
    }

    @Test("The clipboard gets an image, a PDF, a table and the app's own format")
    func clipboard() throws {
        let store = try makeStore()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.editthefuture.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try SnapshotExporter.copy(state: store.panelState(), data: store.snapshotData(), contents: .everything, to: pasteboard)

        let png = try #require(pasteboard.data(forType: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let pdf = try #require(pasteboard.data(forType: .pdf))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        let table = try #require(pasteboard.string(forType: SnapshotExporter.tabularText))
        #expect(table.hasPrefix("Date\tSavings (balance)"))
        let json = try #require(pasteboard.data(forType: SnapshotExporter.snapshotType))
        #expect(try SnapshotData.decode(json).scenario == "Home & money")
    }
}
