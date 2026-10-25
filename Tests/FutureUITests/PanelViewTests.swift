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
}
