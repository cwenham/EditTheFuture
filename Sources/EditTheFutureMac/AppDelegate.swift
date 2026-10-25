#if os(macOS)
import AppKit
import Carbon
import FutureCommands
import FutureUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var store: ScenarioStore?
    private var panel: PanelController?
    private var router: CommandRouter?
    private let hotKeys = HotKeyCenter()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try ScenarioStore(definition: .homeAndMoney)
            let panel = PanelController(store: store)
            self.store = store
            self.panel = panel
            self.router = CommandRouter(panel: panel)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Edit The Future couldn’t load its scenario"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()
        registerHotKeys()
        panel?.showFully()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                router?.perform(try URLScheme.command(from: url), from: .urlScheme)
            } catch {
                store?.say(String(describing: error), isError: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Hot-keys (docs/UI.md, 4.2)

    private func registerHotKeys() {
        guard let panel else { return }
        let space = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_Space), modifiers: HotKeyCenter.Shortcut.controlOption)
        hotKeys.register(space, pressed: { panel.summonPressed() }, released: { panel.summonReleased() })
        hotKeys.register(HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: HotKeyCenter.Shortcut.controlOption)) {
            panel.copy(.everything)
        }
        hotKeys.register(HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: HotKeyCenter.Shortcut.controlOption)) {
            panel.store.jumpToNow()
            panel.addEvent(at: panel.store.now)
        }
    }

    // MARK: Menu bar item (docs/UI.md, section 6)

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Edit The Future")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Panel   ⌃⌥Space", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Event at Now…   ⌃⌥E", action: #selector(addEventAtNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Snapshot   ⌃⌥C", action: #selector(copySnapshot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Data", action: #selector(copyData), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Jump to Now", action: #selector(jumpToNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Mouse Has a Horizontal Wheel", action: #selector(toggleHorizontalWheel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Edit The Future", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() { panel?.showFully() }
    @objc private func addEventAtNow() {
        guard let panel else { return }
        panel.store.jumpToNow()
        panel.addEvent(at: panel.store.now)
    }
    @objc private func copySnapshot() { panel?.copy(.everything) }

    /// Overrides the automatic detection: with a horizontal wheel, the vertical wheel zooms.
    @objc private func toggleHorizontalWheel() {
        guard let panel else { return }
        panel.rememberHorizontalWheel(!panel.hasHorizontalWheel)
        panel.store.say(panel.hasHorizontalWheel
            ? "Vertical wheel zooms; horizontal wheel scrolls through time."
            : "Wheel scrolls through time; Shift + wheel zooms.")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHorizontalWheel) {
            menuItem.state = panel?.hasHorizontalWheel == true ? .on : .off
        }
        return true
    }
    @objc private func copyData() { panel?.copy(.dataOnly) }
    @objc private func jumpToNow() {
        store?.jumpToNow()
        panel?.showFully()
    }

    // MARK: Main menu
    //
    // Not shown (the app has no Dock icon), but it supplies the key equivalents that text fields need.

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Edit The Future", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        return main
    }
}
#endif
