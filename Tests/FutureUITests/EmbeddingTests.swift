import Foundation
import Testing
import FutureTestSupport
import AppKit
import SwiftUI
import FutureEngine
@testable import FutureKit
@testable import FutureUI

/// The graph and the editing panes on their own, as an app that embeds them shows them
/// (docs/DESIGN.md, 2.1): each in a window of its own size, with no panel around it.
@MainActor
@Suite("Embedding the views")
struct EmbeddingTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    func mount<V: View>(_ content: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

    @Test("A graph on its own fills its window and catches the wheel over all of it, at any size and with any parts")
    func graph() async throws {
        let store = try await makeStore()
        let shapes: [(ScenarioGraph.Parts, CGFloat, CGFloat)] = [
            (.all, 900, 600), ([], 500, 260), ([.lanes], 700, 400), ([.title, .events], 320, 200), (.all, 200, 120),
        ]
        for (parts, width, height) in shapes {
            let (window, view) = mount(ScenarioGraph(store: store, parts: parts), width: width, height: height)
            settle(view)
            let catcher = try #require(PanelViewTests.gestureView(in: view))
            let frame = catcher.convert(catcher.bounds, to: view)
            #expect(abs(frame.width - width) < 1, "\(parts.rawValue) at \(width)×\(height)")
            #expect(frame.maxY <= height + 1)
            window.close()
        }
    }

    @Test("A read-only graph does nothing when clicked; an interactive one opens the Event tab at the date")
    func readOnly() async throws {
        let store = try await makeStore()
        let timeline = store.timelineState()
        #expect(ScenarioGraph(store: store, interactive: false).interactions(timeline) == nil)
        let clicks = try #require(ScenarioGraph(store: store).interactions(timeline))
        store.sidePane = .slot
        clicks.pickDate(0.5)
        #expect(store.sidePane == .event)
        #expect(abs(store.eventDraft.date.timeIntervalSince(timeline.frame.date(atFraction: 0.5))) < 86_400 * 32)
    }

    @Test("Each editor works on its own, beside a graph, and Drag the future's card shows in the tabbed editor")
    func editors() async throws {
        let store = try await makeStore()
        let editors: [(String, AnyView, CGFloat)] = [
            ("tabs", AnyView(ScenarioEditor(store: store)), ScenarioEditor.minimumWidth),
            ("event", AnyView(EventEditor(store: store)), EventEditor.minimumWidth),
            ("slot", AnyView(SlotEditor(store: store)), SlotEditor.minimumWidth),
            ("formula", AnyView(FormulaEditorPane(store: store)), FormulaEditorPane.minimumWidth),
        ]
        for (name, editor, minimum) in editors {
            let page = HStack(spacing: 0) {
                ScenarioGraph(store: store)
                editor.frame(width: minimum + 40)
            }
            let (window, view) = mount(page, width: 1200, height: 760)
            settle(view)
            store.beginEvent(at: utc(2030, 1))
            store.eventDraft.amountText = "500"
            store.focus(index: 2)
            await store.waitUntilIdle()
            settle(view)
            store.focus(index: 0)
            settle(view)
            #expect(view.fittingSize.width > 0, "\(name)")
            window.close()
        }
    }

    @Test("A formula editor outside the side pane keeps the focused slot's formula checked")
    func formulaChecked() async throws {
        let store = try await makeStore()
        #expect(store.sidePane == .event)
        let (window, view) = mount(AnyView(FormulaEditorPane(store: store)), width: 480, height: 600)
        defer { window.close() }
        settle(view)
        #expect(store.formulaChecks[store.focused.id] != nil)
        store.focus(index: 1)
        settle(view)
        #expect(store.formulaChecks[store.focused.id] != nil)
        #expect(store.formulaEditorsShown == 1)
        view.rootView = AnyView(EmptyView())
        settle(view)
        #expect(store.formulaEditorsShown == 0)
    }

    @Test("The graph's keys move the cursor, zoom and focus slots")
    func keys() async throws {
        let store = try await makeStore()
        func press(_ characters: String, code: UInt16, shift: Bool = false) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return TimelineKeys.handle(event, store: store)
        }
        let cursor = store.cursor
        #expect(press("\u{F703}", code: 124))  // →
        #expect(store.cursor > cursor)
        let span = store.frame.span
        #expect(press("-", code: 27))
        #expect(store.frame.span > span)
        #expect(press("3", code: 20))
        #expect(store.focusedIndex == store.slots.firstIndex { $0.key == 3 })
        #expect(!press("q", code: 12))
    }

    @Test("A wheel remembers a horizontal wheel only when given somewhere to keep it")
    func wheelMemory() {
        let key = "EditTheFutureTests.wheel.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let remembering = TimelineWheel(rememberingUnder: key)
        #expect(!remembering.hasHorizontalWheel)
        remembering.noteHorizontalWheel()
        #expect(TimelineWheel(rememberingUnder: key).hasHorizontalWheel)
        #expect(!TimelineWheel().hasHorizontalWheel)
    }

    @Test("Choosing which wheels the mouse has overrides what was found, and is remembered")
    func wheelModes() {
        let defaults = UserDefaults(suiteName: "EditTheFutureTests.wheel.\(UUID().uuidString)")!
        let wheel = TimelineWheel(rememberingUnder: "wheel", in: defaults)
        #expect(wheel.mode == .automatic)
        #expect(wheel.mapper.findsHorizontalWheel)

        wheel.mode = .twoWheels
        #expect(wheel.hasHorizontalWheel)
        #expect(!wheel.mapper.findsHorizontalWheel)
        #expect(wheel.mapper.map(.init(dx: 0, dy: 1, precise: false)).action == .zoom(0.88))

        wheel.mode = .oneWheel
        #expect(!wheel.hasHorizontalWheel)
        // A horizontal delta still moves through time, but doesn't switch the vertical wheel to zooming.
        let turned = wheel.mapper.map(.init(dx: -1, dy: 0, precise: false))
        #expect(turned.action == .pan(0.04))
        #expect(!turned.foundHorizontalWheel)
        #expect(wheel.mapper.map(.init(dx: 0, dy: -1, precise: false)).action == .pan(0.04))
        #expect(TimelineWheel(rememberingUnder: "wheel", in: defaults).mode == .oneWheel)

        // Back to automatic: what was found counts again, and can be forgotten.
        wheel.noteHorizontalWheel()
        #expect(!wheel.hasHorizontalWheel)
        wheel.mode = .automatic
        #expect(wheel.hasHorizontalWheel)
        wheel.noteHorizontalWheel(false)
        #expect(!wheel.hasHorizontalWheel)
        #expect(!TimelineWheel(rememberingUnder: "wheel", in: defaults).hasHorizontalWheel)
    }
}
