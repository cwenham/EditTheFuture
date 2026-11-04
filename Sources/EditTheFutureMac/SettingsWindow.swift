#if os(macOS)
import AppKit
import SwiftUI
import FutureUI

/// The Settings window (docs/UI.md, 7), opened from the menu bar item or with ⌘, while the panel
/// is in front. It floats with the panel, so it isn't hidden behind it.
@MainActor
final class SettingsWindow {
    private let pages: () -> [SettingsPage]
    private var window: NSWindow?

    init(pages: @escaping () -> [SettingsPage]) {
        self.pages = pages
    }

    /// Shows the window, at a group when `page` names one (its id: "general", "privacy").
    func show(page: String? = nil) {
        if let page, !page.isEmpty { UserDefaults.standard.set(page.lowercased(), forKey: SettingsView.groupKey) }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(pages: pages())))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.setFrameAutosaveName("EditTheFutureSettings")
        if !window.setFrameUsingName("EditTheFutureSettings") { window.center() }
        return window
    }
}
#endif
