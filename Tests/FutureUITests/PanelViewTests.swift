import Foundation
import Testing
import AppKit
import SwiftUI
@testable import FutureUI

/// Mounts the real panel in a window and drives it, to catch SwiftUI update crashes.
@MainActor
@Suite("Panel view")
struct PanelViewTests {
    func mount(_ store: ScenarioStore) -> (NSWindow, NSHostingView<PanelView>) {
        let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Swift owns it; AppKit releasing it on close would free it twice
        window.contentView = view
        return (window, view)
    }

    func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @Test("Adding, clearing and switching slots in the pane doesn't crash")
    func paneFlow() throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        settle(view)

        store.beginEvent(at: utc(2030, 1))
        store.eventDraft.amountText = "500"
        store.eventDraft.repeats = .monthly
        settle(view)
        store.pan(by: 3)
        settle(view)
        #expect(store.commitEvent())
        settle(view)

        store.pickEventDate(utc(2031, 1), slotIndex: 3)
        store.eventDraft.valueText = "0.05"
        settle(view)
        store.clearEvent()
        store.focus(index: 0)
        settle(view)
        #expect(store.eventDraft.amountText.isEmpty)
    }

    @Test("Editing, moving and deleting an event in the pane doesn't crash")
    func editFlow() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        settle(view)

        let event = try #require(store.configs[0].events.first)
        store.editEvent(id: event.id)
        settle(view)
        store.eventDraft.date = utc(2030, 2)
        store.eventDraft.amountText = "9000"
        await store.waitUntilIdle()
        settle(view)
        #expect(store.commitEvent())
        settle(view)

        let edited = try #require(store.configs[0].events.first)
        store.editEvent(id: edited.id)
        store.requestEventDeletion()
        settle(view)
        store.deleteEditedEvent()
        await store.waitUntilIdle()
        settle(view)
        store.undo()
        store.editEvent(id: edited.id)
        settle(view)
        store.focus(index: 2)
        settle(view)
        #expect(store.editingEvent == nil)
    }

    @Test("The Slot tab, picker and slot changes draw without crashing")
    func slotFlow() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        settle(view)

        store.showSlotSettings()
        settle(view)
        store.openPicker(.add(position: 5))
        settle(view)
        store.addModel(ModelLibrary.batteryCapacity, atPosition: 5)
        await store.waitUntilIdle()
        settle(view)
        store.previewStartingValue("cycles", 14, inSlotAt: store.focusedIndex)
        await store.waitUntilIdle()
        settle(view)
        store.endStartingValuePreview(commit: true)
        settle(view)
        store.openPicker(.change(slot: store.focused.id))
        settle(view)
        store.changeModel(ofSlotAt: store.focusedIndex, to: ModelLibrary.logisticGrowth)
        settle(view)

        store.requestRemoval(ofSlotAt: 3)
        settle(view)
        store.removeSlot(at: 3)
        await store.waitUntilIdle()
        store.focus(named: "energybill")
        settle(view)
        #expect(store.focused.isPaused)
        store.undo()
        await store.waitUntilIdle()
        settle(view)
        store.moveSlot(at: 0, toPosition: 7)
        store.toggleSlotSettings()
        settle(view)
        #expect(store.sidePane == .event)
    }

    @Test("Removing the last slot in the list, from its Slot tab, doesn't crash")
    func removeLastSlot() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        settle(view)
        // As in the app: add a model to an empty chip, ask to remove it, confirm.
        store.addModel(ModelLibrary.radioactiveDecay, atPosition: 5)
        await store.waitUntilIdle()
        settle(view)
        store.requestRemoval(ofSlotAt: store.focusedIndex)
        settle(view)
        store.removeSlot(at: store.focusedIndex)
        settle(view)
        await store.waitUntilIdle()
        settle(view)
        #expect(store.slots.count == 5)
        // And again from the end of a longer list, with the slot after it moved away first.
        store.addModel(ModelLibrary.prices, atPosition: 7)
        store.addModel(ModelLibrary.bodyWeight, atPosition: 6)
        settle(view)
        store.removeSlot(at: store.slots.count - 1)
        settle(view)
        store.undo()
        settle(view)
        store.removeSlot(at: 0)
        settle(view)
        #expect(store.slots.count == 6)
    }

    @Test("The Formula tab draws while editing, checking, fixing and applying")
    func formulaTab() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        store.showFormulaEditor()
        settle(view)
        let text = store.formulaText(forSlotAt: 0)
        store.editFormula(text.replacingOccurrences(of: "rate / 12", with: "rat / 12"), forSlotAt: 0)
        store.updateFormulaCheck(forSlotAt: 0)
        settle(view)
        let fix = try #require(store.formulaChecks[store.slots[0].id]?.diagnoses.first?.fixes.first)
        store.useFormulaFix(fix, forSlotAt: 0)
        settle(view)
        store.editFormula(text + "\n# more", forSlotAt: 0)
        store.updateFormulaCheck(forSlotAt: 0)
        await store.waitUntilIdle()
        settle(view)
        #expect(store.applyFormula(forSlotAt: 0))
        settle(view)
        store.focus(index: 4)
        settle(view)
        store.addModel(ModelLibrary.blankFormula, atPosition: 6)
        settle(view)
        store.removeSlot(at: store.focusedIndex)
        settle(view)
        #expect(store.slots.count == 5)
    }

    @Test("The mouse wheel moves time only over the graphs and lanes")
    func wheelArea() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        settle(view)
        // The app places the pointer in the hosting view's coordinates, which are top-left like SwiftUI's.
        #expect(view.isFlipped)
        let frame = store.timelineFrame
        #expect(abs(frame.minY - 110) < 6)  // below the header (56), padding (14) and slot title (40)
        #expect(frame.maxY > 600)           // down through the lanes
        #expect(frame.maxY < 820 - 52)      // above the command bar
        #expect(frame.width > 700 && frame.width < 1400 - 300)  // not the side pane
        #expect(store.isOverTimeline(CGPoint(x: frame.midX, y: frame.midY)))
        #expect(!store.isOverTimeline(CGPoint(x: 5, y: 400)) || !store.isOverTimeline(CGPoint(x: 1395, y: 400)))
        #expect(!store.isOverTimeline(CGPoint(x: frame.midX, y: 30)))

        // The wider Formula tab leaves less room for the graphs.
        store.showFormulaEditor()
        settle(view)
        #expect(abs((frame.width - store.timelineFrame.width) - (SidePane.formulaWidth - SidePane.width)) < 1)
    }

    @Test("Values too big for whole numbers, infinite or NaN still draw, focused or in a lane")
    func runawayValues() async throws {
        let store = try ScenarioStore(definition: .runaway, now: utc(2026, 10, 25))
        let (window, view) = mount(store)
        defer { window.close() }
        await store.waitUntilIdle()
        settle(view)
        for zoomed in [false, true] {
            if zoomed { store.zoom(by: 1e6) }  // the widest view
            for year in [2022, 2024, 2040, 2060, 2120] {
                store.show(utc(year, 1))
                await store.waitUntilIdle()
                for slot in store.slots.indices {
                    store.focus(index: slot)
                    settle(view)
                }
            }
        }
        // The cursor sits where Rocket has overflowed, and Giant is still finite.
        store.focus(index: 0)
        #expect(store.cursorState().readoutValue == "$∞")
        store.focus(index: 3)
        #expect(store.cursorState().readoutValue.hasSuffix("e301"))

        // Snapshots of overflowed values still copy, and read back.
        let data = store.snapshotData()
        #expect(data.slots.contains { $0.points.contains { $0.v.isInfinite } })
        #expect(data.slots.contains { $0.points.contains { $0.v.isNaN } })
        #expect(data.slots.contains { $0.points.contains { $0.v.isFinite && $0.v > 1e19 } } || data.start > utc(2048, 1))
        let decoded = try SnapshotData.decode(try data.json())
        #expect(decoded.slots.map(\.points.count) == data.slots.map(\.points.count))
    }
}

extension ScenarioDefinition {
    /// Slots that outgrow every number: ×10 a month (overflows to infinity in 2047), ×−3 a month,
    /// one that turns into NaN once it overflows, and one that starts near the largest Double.
    static let runaway = ScenarioDefinition(
        name: "Runaway",
        start: utc(2022, 1),
        slots: [
            SlotSpec(name: "Rocket", formula: """
                step 1 month
                param growth = 10
                init balance = 1000
                balance[t] = balance[t-1] * growth
                on deposit: balance += event.amount
                """, variable: "balance", format: .currency),
            SlotSpec(name: "Sinker", formula: """
                step 1 month
                init n = -1
                n[t] = n[t-1] * 3
                """, variable: "n", format: .number),
            SlotSpec(name: "Furnace", formula: """
                step 1 month
                init temp = 1
                temp[t] = temp[t-1] * 100 - temp[t-1] * 90
                """, variable: "temp", format: .temperature),
            // Every value it ever shows is beyond the ±1e300 plots are clamped to.
            SlotSpec(name: "Giant", formula: """
                step 1 month
                init size = 1e301
                size[t] = size[t-1] * 1.001
                """, variable: "size", format: .currency),
        ])
}
