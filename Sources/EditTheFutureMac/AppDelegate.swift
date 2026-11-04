#if os(macOS)
import AppKit
import Carbon
import FutureCommands
import FutureDocument
import FutureScript
import FutureFiles
import FutureUI
import FutureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The scenario that's open, saved in its folder (docs/DESIGN.md, 15).
    private var document: ScenarioDocument?
    private var store: ScenarioStore? { document?.store }
    private var panel: PanelController?
    private var router: CommandRouter?
    /// Takes commands from the etf tool (docs/DESIGN.md, 10.2).
    private var commandServer: CommandServer?
    private let hotKeys = HotKeyCenter()
    /// Notifies of drifting readings while the panel is hidden (docs/UI.md, 5.6).
    private lazy var driftNotifier: DriftNotifier = {
        let notifier = DriftNotifier()
        notifier.onOpen = { [weak self] folder, slot in
            guard let self, let document = self.document, document.package.url.path == folder,
                  let store = self.store, let index = store.slots.firstIndex(where: { $0.title == slot }) else { return }
            self.panel?.showFully()
            store.openDriftRefit(slot: store.slots[index].id)
        }
        return notifier
    }()
    private var statusItem: NSStatusItem?
    /// The panel's font and text size, and what the mouse wheels do, chosen in Settings (docs/UI.md, 7).
    private let appearance = AppearanceSettings()
    private let wheel = TimelineWheel(rememberingUnder: AppDelegate.horizontalWheelKey)
    private let shortcuts = ShortcutSettings()
    private let settings = AppSettings()
    /// Which scenarios from elsewhere may run their scripts and fetch their feeds.
    private let trust = ScenarioTrust()
    private let loginItem = LoginItem()
    private lazy var settingsWindow = SettingsWindow { [unowned self] in
        [
            SettingsPage(id: "general", title: "General", symbol: "gearshape") {
                GeneralSettingsPane(settings: self.settings, login: self.loginItem, redrawDates: { [weak self] in self?.store?.redrawDates() })
            },
            .appearance(appearance),
            .mouse(wheel),
            .shortcuts(shortcuts),
            SettingsPage(id: "notifications", title: "Notifications", symbol: "bell") {
                NotificationSettingsPane(settings: self.settings)
            },
            SettingsPage(id: "feeds", title: "Data Feeds", symbol: "antenna.radiowaves.left.and.right") {
                FeedSettingsPane(settings: self.settings, rescheduleRates: { [weak self] in self?.document?.rates.rescheduleLive() })
            },
            SettingsPage(id: "privacy", title: "Privacy and Security", symbol: "hand.raised") {
                PrivacySettingsPane(trust: self.trust)
            },
        ]
    }
    private var hasLaunched = false
    /// A scenario the app was asked to open before it finished launching.
    private var openAtLaunch: ScenarioPackage?
    private var isOpening = false
    private var isTerminating = false

    static let lastScenarioKey = "scenario.lastOpened"
    /// Whether a horizontal wheel was found; what the mouse has, if chosen in Settings, is kept under
    /// the same name followed by `.mode`.
    static let horizontalWheelKey = "mouse.hasHorizontalWheel"
    /// What the etf tool passes when it starts the app, so the panel doesn't pop up.
    static let backgroundArgument = "--background"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Python takes a moment to start, so it starts now, off the main thread (docs/DESIGN.md, 6.4).
        DispatchQueue.global(qos: .utility).async { ScriptPrograms.prepare(.python) }
        Self.movePanelSettings()
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()
        registerHotKeys()
        startCommandServer()
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
            // etf://settings?page=privacy opens Settings at a group. It only opens a window, so any link may.
            if url.host?.lowercased() == "settings" {
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
                settingsWindow.show(page: page)
                continue
            }
            do {
                let command = try URLScheme.command(from: url)
                if let router { Task { await router.perform(command, from: .urlScheme) } }
            } catch {
                store?.say(String(describing: error), isError: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Saves the scenario and its cache before quitting, giving the cache a few seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        commandServer?.stop()
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
                let opened = try await ScenarioDocument.open(package, trust: trust)
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
        // Started by the etf tool, the app stays out of the way until asked to show.
        let wasVisible = panel?.isVisible ?? !ProcessInfo.processInfo.arguments.contains(Self.backgroundArgument)
        panel?.tearDown()
        panel = nil
        router = nil
        Outside.shared.connect(nil)
        if let old = document {
            document = nil
            await old.close()
        }
        document = opened
        let panel = PanelController(store: opened.store, appearance: appearance, wheel: wheel, shortcuts: shortcuts, scenarios: scenarioMenuActions())
        panel.onShowSettings = { [weak self] in self?.showSettings() }
        self.panel = panel
        let router = CommandRouter(panel: panel)
        self.router = router
        Outside.shared.connect(router)
        // Siri's phrases and Spotlight follow the slots' names (Intents.swift).
        let saving = opened.store.onScenarioChange
        opened.store.onScenarioChange = {
            saving?()
            Outside.shared.slotsMayHaveChanged()
        }
        followNewScenarioSettings(opened.store)
        opened.store.onDrift = { [weak self, weak panel, weak opened] alert in
            guard let self, let panel, let opened, !panel.isVisible, self.settings.driftNotifications else { return }
            self.driftNotifier.notify(alert, scenario: opened.store.name, folder: opened.package.url.path)
        }
        UserDefaults.standard.set(opened.package.url.path, forKey: Self.lastScenarioKey)
        // Renaming the scenario in the panel can rename its folder (docs/DESIGN.md, 15.1).
        opened.onMove = { package in
            UserDefaults.standard.set(package.url.path, forKey: Self.lastScenarioKey)
        }
        if wasVisible { panel.showFully() }
    }

    /// Gives the open scenario what Settings says new scenarios start with, and again when it changes.
    private func followNewScenarioSettings(_ store: ScenarioStore) {
        let defaults = withObservationTracking { settings.newScenario } onChange: { [weak self, weak store] in
            Task { @MainActor in if let store { self?.followNewScenarioSettings(store) } }
        }
        if store.newScenarioDefaults != defaults { store.newScenarioDefaults = defaults }
    }

    /// What the scenario menu in the panel's header asks of the app (docs/UI.md, 3).
    private func scenarioMenuActions() -> ScenarioMenuActions {
        ScenarioMenuActions(
            folder: ScenarioLibrary.folder,
            current: { [weak self] in self?.document?.package },
            save: { [weak self] in self?.document?.save() },
            open: { [weak self] package in Task { await self?.open(package) } },
            showInFinder: { [weak self] in self?.showScenarioInFinder() },
            openOther: { [weak self] in self?.chooseScenario() })
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

    // MARK: The etf tool (docs/DESIGN.md, 10.2 and 13)

    /// Listens for the etf tool, which comes inside the app. Only that tool, or code from the same
    /// team once the app is signed with one, may connect. Without the tool (as with `swift run`)
    /// there's nothing to listen for.
    private func startCommandServer() {
        switch CallerCheck.forApp(at: Bundle.main.bundleURL) {
        case .failure(let problem):
            NSLog("Edit The Future: %@", problem.description)
        case .success(let check):
            let server = CommandServer(check: check) { request in
                await Outside.shared.handle(request, from: .commandLine)
            }
            do {
                try server.start()
                commandServer = server
            } catch {
                NSLog("Edit The Future takes no commands from the etf tool: %@", String(describing: error))
            }
        }
    }

    // MARK: Hot-keys (docs/UI.md, 4.2)

    /// Registers the shortcuts Settings has, and again whenever they change. While a new one is
    /// being typed in Settings, they're let go, so typing one records it rather than doing it.
    private func registerHotKeys() {
        let (recording, wanted) = withObservationTracking {
            (shortcuts.isRecording, ShortcutSettings.Action.all(in: .anywhere).map { ($0, shortcuts.shortcut(for: $0)) })
        } onChange: { [weak self] in
            Task { @MainActor in self?.registerHotKeys() }
        }
        hotKeys.unregisterAll()
        guard !recording else { return }
        var refused: Set<ShortcutSettings.Action> = []
        for (action, shortcut) in wanted {
            guard let shortcut else { continue }
            let key = HotKeyCenter.Shortcut(keyCode: UInt32(shortcut.keyCode), modifiers: Self.carbonModifiers(shortcut.flags))
            let registered: Bool
            switch action {
            case .showPanel:
                registered = hotKeys.register(key, pressed: { [weak self] in self?.panel?.summonPressed() },
                                              released: { [weak self] in self?.panel?.summonReleased() })
            case .copySnapshot:
                registered = hotKeys.register(key) { [weak self] in self?.panel?.copy(.everything) }
            case .addEvent:
                registered = hotKeys.register(key) { [weak self] in self?.addEventAtNow() }
            default:
                continue
            }
            if !registered { refused.insert(action) }
        }
        shortcuts.unavailable = refused
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return UInt32(modifiers)
    }

    /// A menu item's title with the shortcut that does the same from any app, if there is one.
    private func title(_ title: String, _ action: ShortcutSettings.Action) -> String {
        shortcuts.shortcut(for: action).map { title + "   " + $0.text } ?? title
    }

    // MARK: Menu bar item (docs/UI.md, section 6)

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Edit The Future")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Event at Now…", action: #selector(addEventAtNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Snapshot", action: #selector(copySnapshot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Data", action: #selector(copyData), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Jump to Now", action: #selector(jumpToNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Scenario…", action: #selector(chooseScenario), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit scenario.md", action: #selector(editScenario), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Scenario in Finder", action: #selector(showScenarioInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Scenarios Folder", action: #selector(openScenarioFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Data Feeds", action: #selector(refreshFeeds), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Script Libraries Folder", action: #selector(openLibraries), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Script Libraries", action: #selector(reloadLibraries), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
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

    /// The side pane's side and widths were kept under plain names before November 2026. They now
    /// have names of their own (`PanelView.sideKey`), so an app embedding the panel keeps them apart.
    private static func movePanelSettings() {
        let defaults = UserDefaults.standard
        for (old, new) in [("eventPaneSide", PanelView.sideKey), ("sidePaneWidth", PanelView.widthKey),
                           ("formulaPaneWidth", PanelView.formulaWidthKey)] {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
    }

    @objc private func reloadLibraries() { store?.reloadScripts() }
    /// Checks every feed in the scenario for new readings now (docs/DESIGN.md, 15.8).
    @objc private func refreshFeeds() { store?.refreshFeeds() }

    @objc private func showSettings() { settingsWindow.show() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // The shortcuts can change in Settings, so their titles are written as the menu opens.
        let titles: [Selector: (String, ShortcutSettings.Action)] = [
            #selector(showPanel): ("Show Panel", .showPanel),
            #selector(addEventAtNow): ("Add Event at Now…", .addEvent),
            #selector(copySnapshot): ("Copy Snapshot", .copySnapshot),
        ]
        if let action = menuItem.action, let (name, shortcut) = titles[action] {
            let wanted = title(name, shortcut)
            if menuItem.title != wanted { menuItem.title = wanted }
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
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
