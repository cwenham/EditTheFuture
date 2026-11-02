import Foundation
import Testing
import AppKit
import SwiftUI
@testable import FutureUI

/// Drawing other slots over the focused graph (docs/UI.md, 5.12).
@MainActor
@Suite("Overlaid slots")
struct OverlayTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    func index(_ store: ScenarioStore, _ name: String) throws -> Int {
        try #require(store.slots.firstIndex { $0.name == name })
    }

    func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func names(_ store: ScenarioStore) -> [String] {
        store.overlaidIDs.compactMap { id in store.slots.first { $0.id == id }?.name }
    }

    @Test("Keys held choose the click, as in Finder, and ⌃ leaves it to the right-click")
    func clicks() {
        #expect(SlotClick(command: false, shift: false, control: false) == .only)
        #expect(SlotClick(command: true, shift: false, control: false) == .toggle)
        // ⌃-click is a right-click.
        #expect(SlotClick(command: false, shift: false, control: true) == nil)
        #expect(SlotClick(command: true, shift: false, control: true) == nil)
        #expect(SlotClick(command: false, shift: true, control: false) == .range)
        #expect(SlotClick(command: true, shift: true, control: false) == .toggle)
    }

    @Test("⌘-click adds and removes a slot, a plain click shows one alone")
    func toggling() async throws {
        let store = try await makeStore()
        let fund = try index(store, "IndexFund"), climate = try index(store, "Climate")
        store.select(index: fund, click: .toggle)
        store.select(index: climate, click: .toggle)
        #expect(names(store) == ["IndexFund", "Climate"])
        #expect(store.focusedIndex == 0)

        store.select(index: fund, click: .toggle)
        #expect(names(store) == ["Climate"])

        store.select(index: fund, click: .only)
        #expect(store.overlaidIDs.isEmpty)
        #expect(store.focusedIndex == fund)
    }

    @Test("⇧-click adds every slot from the focused one to the clicked one, keeping the rest")
    func ranges() async throws {
        let store = try await makeStore()
        let bill = try index(store, "EnergyBill")
        store.select(index: bill, click: .toggle)
        store.select(index: try index(store, "Mortgage"), click: .range)
        #expect(names(store) == ["EnergyBill", "IndexFund", "Mortgage"])
        #expect(store.focusedIndex == 0)

        // Backwards from the focused slot works too, and nothing is added twice.
        store.select(index: bill, click: .only)
        store.select(index: try index(store, "Mortgage"), click: .range)
        #expect(names(store) == ["Mortgage", "Climate"])
    }

    @Test("⌘-click on the focused slot passes the focus to the slot added last")
    func togglingFocus() async throws {
        let store = try await makeStore()
        store.select(index: 0, click: .toggle)  // alone: stays
        #expect(store.focusedIndex == 0)

        store.select(index: try index(store, "IndexFund"), click: .toggle)
        store.select(index: try index(store, "Mortgage"), click: .toggle)
        store.select(index: 0, click: .toggle)
        #expect(store.focused.name == "Mortgage")
        #expect(names(store) == ["IndexFund"])
    }

    @Test("Focusing a slot on the graph swaps it with the focused one")
    func focusingSwaps() async throws {
        let store = try await makeStore()
        store.select(index: try index(store, "IndexFund"), click: .toggle)
        store.select(index: try index(store, "Climate"), click: .toggle)
        store.focus(key: 2)  // IndexFund
        #expect(store.focused.name == "IndexFund")
        #expect(names(store) == ["Savings", "Climate"])

        // Focusing one that isn't shown keeps the others.
        store.focus(index: try index(store, "Mortgage"))
        #expect(names(store) == ["Savings", "Climate"])
    }

    @Test("Removing a slot takes it off the graph")
    func removing() async throws {
        let store = try await makeStore()
        store.select(index: try index(store, "Climate"), click: .toggle)
        store.select(index: try index(store, "EnergyBill"), click: .toggle)
        store.removeSlot(at: try index(store, "Climate"))
        await store.waitUntilIdle()
        #expect(names(store) == ["EnergyBill"])
        #expect(store.timelineState().overlays.map(\.name) == [store.slots[try index(store, "EnergyBill")].title])
    }

    @Test("Money in the same currency shares the axis; other kinds of value get their own scale")
    func scales() async throws {
        let store = try await makeStore()
        let alone = store.timelineState().focus.yDomain
        store.select(index: try index(store, "Mortgage"), click: .toggle)
        store.select(index: try index(store, "Climate"), click: .toggle)
        await store.waitUntilIdle()
        let timeline = store.timelineState()
        #expect(timeline.overlays.count == 2)

        let mortgage = try #require(timeline.overlays.first)
        #expect(!mortgage.ownScale)
        #expect(mortgage.yDomain == timeline.focus.yDomain)
        #expect(!mortgage.samples.isEmpty)
        for sample in mortgage.samples where sample.value.isFinite && timeline.frame.contains(sample.time) {
            #expect(timeline.focus.yDomain.contains(sample.value))
        }
        #expect(timeline.focus.yDomain.upperBound >= alone.upperBound)

        let climate = try #require(timeline.overlays.last)
        #expect(climate.ownScale)
        #expect(climate.yDomain != timeline.focus.yDomain)
        for sample in climate.samples where sample.value.isFinite && timeline.frame.contains(sample.time) {
            #expect(climate.yDomain.contains(sample.value))
        }

        // Their lanes stay, picked out, and the cursor has a value for each line.
        let lanes = timeline.lanes.filter(\.overlaid).map(\.id)
        #expect(Set(lanes) == Set(timeline.overlays.map(\.id)))
        store.setCursor(utc(2030, 1))
        await store.waitUntilIdle()
        #expect(Set(store.cursorState().overlayValues.keys) == Set(lanes))
    }

    @Test("The panel draws overlays, with huge and infinite values too, without crashing")
    func drawing() async throws {
        for definition in [ScenarioDefinition.homeAndMoney, .runaway] {
            let store = try ScenarioStore(definition: definition, now: now)
            let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            await store.waitUntilIdle()
            for other in store.slots.indices.dropFirst() { store.select(index: other, click: .toggle) }
            for year in [2024, 2060, 2120] {
                store.show(utc(year, 1))
                await store.waitUntilIdle()
                settle(view)
            }
            store.select(index: 0, click: .only)
            view.display()
            #expect(store.overlaidIDs.isEmpty)
        }
    }
}
