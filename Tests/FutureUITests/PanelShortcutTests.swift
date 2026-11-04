import Foundation
import Testing
import FutureTestSupport
import AppKit
import FutureEngine
@testable import FutureKit
@testable import FutureUI

/// The panel's and the graph's shortcuts, chosen in Settings (docs/UI.md, 4.1).
@MainActor
@Suite("Panel shortcuts")
struct PanelShortcutTests {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EditTheFutureTests.shortcuts.\(UUID().uuidString)")!
    }

    /// A key press as a US keyboard makes it: `characters` is what the key types with ⇧ but no other modifier.
    func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test("The standard keys find their actions, ⌘+ and ⌘= both make the text larger, and ⇧ counts for letters and arrows")
    func standards() throws {
        let shortcuts = ShortcutSettings(defaults: freshDefaults())
        #expect(shortcuts.action(for: try press("k", code: 40, .command), in: .panel) == .commandBar)
        #expect(shortcuts.action(for: try press("i", code: 34, [.option, .command]), in: .panel) == .formulaTab)
        // ⌘C, ⌘Z and ⌘, are the Mac's own, handled by the panel itself.
        #expect(shortcuts.action(for: try press("c", code: 8, .command), in: .panel) == nil)
        #expect(shortcuts.action(for: try press("z", code: 6, .command), in: .panel) == nil)
        #expect(shortcuts.action(for: try press("C", code: 8, [.shift, .command]), in: .panel) == .copyData)
        #expect(shortcuts.action(for: try press("+", code: 24, [.shift, .command]), in: .panel) == .largerText)
        #expect(shortcuts.action(for: try press("=", code: 24, .command), in: .panel) == .largerText)
        #expect(shortcuts.action(for: try press(")", code: 29, [.shift, .command]), in: .panel) == nil)
        #expect(shortcuts.action(for: try press("\u{F702}", code: 123), in: .graph) == .cursorBack)
        #expect(shortcuts.action(for: try press("\u{F702}", code: 123, .shift), in: .graph) == .yearBack)
        #expect(shortcuts.action(for: try press("+", code: 69, .numericPad), in: .graph) == .zoomIn)
        #expect(shortcuts.action(for: try press("t", code: 17), in: .graph) == .jumpToNow)
        // Graph keys aren't panel keys.
        #expect(shortcuts.action(for: try press("t", code: 17), in: .panel) == nil)
        #expect(ShortcutSettings.standardAction(for: try press("e", code: 14), in: .graph) == .addEventAtCursor)
    }

    @Test("A panel or graph shortcut can be any key, takes its keys from another action, and is remembered")
    func changing() throws {
        let defaults = freshDefaults()
        let shortcuts = ShortcutSettings(defaults: defaults)
        // In the panel a plain key will do; from any app it won't.
        let slash = try #require(KeyShortcut(event: try press("/", code: 44), for: .panel))
        #expect(KeyShortcut(event: try press("/", code: 44), for: .anywhere) == nil)
        shortcuts.setShortcut(slash, for: .commandBar)
        #expect(shortcuts.action(for: try press("/", code: 44), in: .panel) == .commandBar)
        #expect(shortcuts.action(for: try press("k", code: 40, .command), in: .panel) == nil)
        #expect(!shortcuts.isStandard(in: .panel) && shortcuts.isStandard(in: .graph))

        // Giving "=" to Jump to now stops it zooming in, though + still does.
        let equals = try #require(KeyShortcut(event: try press("=", code: 24), for: .graph))
        shortcuts.setShortcut(equals, for: .jumpToNow)
        #expect(shortcuts.action(for: try press("=", code: 24), in: .graph) == .jumpToNow)
        #expect(shortcuts.action(for: try press("+", code: 24, .shift), in: .graph) == .zoomIn)
        // Changing Zoom in drops its second key.
        let z = try #require(KeyShortcut(event: try press("z", code: 6), for: .graph))
        shortcuts.setShortcut(z, for: .zoomIn)
        #expect(shortcuts.action(for: try press("+", code: 24, .shift), in: .graph) == nil)
        // Taking T from nothing, and E from Add an event.
        let e = try #require(KeyShortcut(event: try press("e", code: 14), for: .graph))
        shortcuts.setShortcut(e, for: .zoomOut)
        #expect(shortcuts.shortcut(for: .addEventAtCursor) == nil)
        #expect(shortcuts.labels.addEvent == nil && shortcuts.labels.jumpToNow == "=" && shortcuts.labels.commandBar == "/")

        let again = ShortcutSettings(defaults: defaults)
        #expect(again.action(for: try press("e", code: 14), in: .graph) == .zoomOut)
        #expect(again.action(for: try press("/", code: 44), in: .panel) == .commandBar)
        again.reset(.graph)
        #expect(again.isStandard(in: .graph) && !again.isStandard(in: .panel))
        #expect(again.action(for: try press("e", code: 14), in: .graph) == .addEventAtCursor)
    }

    @Test("The Mac's own keys can't be given to anything else")
    func macKeys() throws {
        #expect(KeyShortcut(event: try press("c", code: 8, .command), for: .panel)?.macAction == "Copy")
        #expect(KeyShortcut(event: try press("Z", code: 6, [.shift, .command]), for: .panel)?.macAction == "Redo")
        #expect(KeyShortcut(event: try press(",", code: 43, .command), for: .anywhere)?.macAction == "Settings")
        #expect(KeyShortcut(event: try press("C", code: 8, [.shift, .command]), for: .panel)?.macAction == nil)
        #expect(KeyShortcut(event: try press("c", code: 8, [.control, .option]), for: .anywhere)?.macAction == nil)
    }

    @Test("While text is typed, only shortcuts with ⌘ or ⌃ that a text field doesn't use itself are taken")
    func whileTyping() throws {
        #expect(ShortcutSettings.takesWhileTyping(.commandBar, try press("k", code: 40, .command)))
        #expect(!ShortcutSettings.takesWhileTyping(.copyData, try press("C", code: 8, [.shift, .command])))
        #expect(!ShortcutSettings.takesWhileTyping(.commandBar, try press("/", code: 44)))
        #expect(!ShortcutSettings.takesWhileTyping(.commandBar, try press("v", code: 9, .command)))
        #expect(!ShortcutSettings.takesWhileTyping(.slotTab, try press("\u{F702}", code: 123, .command)))
        #expect(ShortcutSettings.takesWhileTyping(.largerText, try press("+", code: 24, [.shift, .command])))
    }

    @Test("The graph follows the chosen keys, and 1–8 always focus a slot")
    func graph() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        await store.waitUntilIdle()
        let shortcuts = ShortcutSettings(defaults: freshDefaults())
        let j = try #require(KeyShortcut(event: try press("j", code: 38), for: .graph))
        shortcuts.setShortcut(j, for: .zoomOut)
        let span = store.frame.span
        #expect(!TimelineKeys.handle(try press("-", code: 27), store: store, shortcuts: shortcuts))
        #expect(store.frame.span == span)
        #expect(TimelineKeys.handle(try press("j", code: 38), store: store, shortcuts: shortcuts))
        #expect(store.frame.span > span)
        #expect(TimelineKeys.handle(try press("2", code: 19), store: store, shortcuts: shortcuts))
        #expect(store.focusedIndex == store.slots.firstIndex { $0.key == 2 })
    }
}
