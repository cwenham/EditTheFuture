#if os(macOS)
import AppKit
import Carbon
import FutureCommands
import FutureDocument
import FutureScript
import FutureUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The scenario that's open, saved in its folder (docs/DESIGN.md, 15).
    private var document: ScenarioDocument?
    private var store: ScenarioStore? { document?.store }
    private var panel: PanelController?
    private var router: CommandRouter?
    private let hotKeys = HotKeyCenter()
    private var statusItem: NSStatusItem?
    private var hasLaunched = false
    /// A scenario the app was asked to open before it finished launching.
    private var openAtLaunch: ScenarioPackage?
    private var isOpening = false
    private var isTerminating = false

    static let lastScenarioKey = "scenario.lastOpened"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Python takes a moment to start, so it starts now, off the main thread (docs/DESIGN.md, 6.4).
        DispatchQueue.global(qos: .utility).async { ScriptPrograms.prepare(.python) }
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()
        registerHotKeys()
        hasLaunched = true
        Task { await openFirstScenario() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                let package = ScenarioPackage(url: url.lastPathComponent == ScenarioFormat.fileName ? url.deletingLastPathComponent() : url)
                if hasLaunched && !isOpening { Task { await open(package) } } else { openAtLaunch = package }
                continue
            }
            do {
                router?.perform(try URLScheme.command(from: url), from: .urlScheme)
            } catch {
                store?.say(String(describing: error), isError: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Saves the scenario and its cache before quitting, giving the cache a few seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document, !isTerminating else { return .terminateNow }
        isTerminating = true
        Task {
            let closing = Task { await document.close() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await closing.value }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Scenarios (docs/DESIGN.md, 15)

    /// The scenario asked for at launch, else the one used last, else a new copy of "Home & money".
    private func openFirstScenario() async {
        if let openAtLaunch {
            await open(openAtLaunch)
            if document != nil { return }
        }
        do {
            let last = UserDefaults.standard.string(forKey: Self.lastScenarioKey).map { URL(fileURLWithPath: $0) }
            await open(try ScenarioLibrary.initial(lastOpened: last))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Edit The Future couldn’t set up its Scenarios folder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// Opens a scenario in place of the one open now. When it can't be read, says why and offers
    /// to edit it.
    private func open(_ package: ScenarioPackage) async {
        guard !isOpening else { return }
        if package == document?.package {
            panel?.showFully()
            return
        }
        isOpening = true
        defer { isOpening = false }
        while true {
            do {
                let opened = try await ScenarioDocument.open(package)
                await show(opened)
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "“\(package.name)” can’t be opened"
                alert.informativeText = "\(error)\n\nFix \(ScenarioFormat.fileName) in any editor, then choose Try Again."
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Edit \(ScenarioFormat.fileName)")
                alert.addButton(withTitle: document == nil ? "Quit" : "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    continue
                case .alertSecondButtonReturn:
                    edit(package.scenarioURL)
                    continue
                default:
                    if document == nil { NSApp.terminate(nil) }
                    return
                }
            }
        }
    }

    /// Closes the scenario that's open, then shows `opened` in a new panel.
    private func show(_ opened: ScenarioDocument) async {
        let wasVisible = panel?.isVisible ?? true
        panel?.tearDown()
        panel = nil
        router = nil
        if let old = document {
            document = nil
            await old.close()
        }
        document = opened
        let panel = PanelController(store: opened.store)
        self.panel = panel
        router = CommandRouter(panel: panel)
        UserDefaults.standard.set(opened.package.url.path, forKey: Self.lastScenarioKey)
        if wasVisible { panel.showFully() }
    }

    /// Opens a text file in the app the Mac uses for it, or TextEdit when there isn't one.
    private func edit(_ url: URL) {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: url) != nil {
            workspace.open(url)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func editScenario() {
        guard let document else { return }
        document.save()
        edit(document.package.scenarioURL)
    }

    @objc private func showScenarioInFinder() {
        guard let document else { return }
        NSWorkspace.shared.activateFileViewerSelecting([document.package.url])
    }

    @objc private func openScenarioFolder() {
        do {
            try FileManager.default.createDirectory(at: ScenarioLibrary.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ScenarioLibrary.folder)
        } catch {
            store?.say("Couldn't make the Scenarios folder: \(error.localizedDescription)", isError: true)
        }
    }

    /// Picks a scenario folder (or its scenario.md) to open.
    @objc private func chooseScenario() {
        let chooser = NSOpenPanel()
        chooser.title = "Open Scenario"
        chooser.message = "Choose a scenario’s .etf folder, or the scenario.md inside it."
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = ScenarioLibrary.folder
        NSApp.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        let folder = url.lastPathComponent == ScenarioFormat.fileName ? url.deletingLastPathComponent() : url
        let package = ScenarioPackage(url: folder)
        guard FileManager.default.fileExists(atPath: package.scenarioURL.path) else {
            let alert = NSAlert()
            alert.messageText = "There’s no \(ScenarioFormat.fileName) in “\(folder.lastPathComponent)”"
            alert.informativeText = "A scenario is a folder holding a \(ScenarioFormat.fileName) file."
            alert.runModal()
            return
        }
        Task { await open(package) }
    }

    // MARK: Hot-keys (docs/UI.md, 4.2)

    private func registerHotKeys() {
        let space = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_Space), modifiers: HotKeyCenter.Shortcut.controlOption)
        hotKeys.register(space, pressed: { [weak self] in self?.panel?.summonPressed() },
                         released: { [weak self] in self?.panel?.summonReleased() })
        hotKeys.register(HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: HotKeyCenter.Shortcut.controlOption)) { [weak self] in
            self?.panel?.copy(.everything)
        }
        hotKeys.register(HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: HotKeyCenter.Shortcut.controlOption)) { [weak self] in
            self?.addEventAtNow()
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
        menu.addItem(withTitle: "Open Scenario…", action: #selector(chooseScenario), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit scenario.md", action: #selector(editScenario), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Scenario in Finder", action: #selector(showScenarioInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Scenarios Folder", action: #selector(openScenarioFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Data Feeds", action: #selector(refreshFeeds), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Mouse Has a Horizontal Wheel", action: #selector(toggleHorizontalWheel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Script Libraries Folder", action: #selector(openLibraries), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Script Libraries", action: #selector(reloadLibraries), keyEquivalent: "").target = self
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

    /// Where people put Lua and Python files that scripts can import.
    @objc private func openLibraries() {
        do {
            try ScriptPrograms.createLibrariesFolders()
            NSWorkspace.shared.open(ScriptPrograms.librariesFolder)
        } catch {
            store?.say("Couldn't make the Libraries folder: \(error.localizedDescription)", isError: true)
        }
    }

    @objc private func reloadLibraries() { store?.reloadScripts() }
    /// Checks every feed in the scenario for new readings now (docs/DESIGN.md, 15.8).
    @objc private func refreshFeeds() { store?.refreshFeeds() }

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
        if menuItem.action == #selector(editScenario) || menuItem.action == #selector(showScenarioInFinder) {
            return document != nil
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
