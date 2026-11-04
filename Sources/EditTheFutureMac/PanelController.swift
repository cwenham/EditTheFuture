#if os(macOS)
import AppKit
import SwiftUI
import FutureUI
import FutureKit

/// Owns the floating panel: showing, hiding, peeking, adding events and copying. The graph in it
/// handles its own wheel and pinch; keys no text field took go to `TimelineKeys`.
@MainActor
final class PanelController {
    let store: ScenarioStore
    let panel: FloatingPanel
    private var peekGesture = PeekGesture()
    private(set) var isPeeking = false
    /// What the wheels do over the graph; the app keeps it, and Settings changes it.
    let wheel: TimelineWheel
    /// Opens the Settings window, for ⌘, in the panel.
    var onShowSettings: (() -> Void)?
    /// What's behind the panel, blurred; hidden when the panel is set to clear.
    private weak var blur: NSVisualEffectView?
    private let appearance: AppearanceSettings
    /// The keys the panel and its graph answer to.
    private let shortcuts: ShortcutSettings

    var isVisible: Bool { panel.isVisible }

    init(store: ScenarioStore, appearance: AppearanceSettings, wheel: TimelineWheel, shortcuts: ShortcutSettings,
         scenarios: ScenarioMenuActions? = nil) {
        self.store = store
        self.shortcuts = shortcuts
        self.wheel = wheel
        self.appearance = appearance
        PanelView.restoreLook(of: store)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820))

        // The blur sits behind the content in a rounded container, so it can be turned off and
        // leave the panel clear.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)
        self.blur = blur

        let actions = PanelActions(
            hide: { [weak self] in self?.hide() },
            copySnapshot: { [weak self] in self?.copy(.everything) },
            scenarios: scenarios
        )
        let hosting = NSHostingView(rootView: StyledPanel(appearance: appearance, shortcuts: shortcuts,
                                                          panel: PanelView(store: store, actions: actions, wheel: wheel),
                                                          onScheme: { [weak blur] scheme in
            // The HUD material is dark whatever the appearance; a light panel blurs with a light one.
            let material: NSVisualEffectView.Material = scheme == .light ? .popover : .hudWindow
            if blur?.material != material { blur?.material = material }
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        for view in [blur, hosting] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        panel.contentView = container
        panel.setFrameAutosaveName("EditTheFuturePanel")
        if !panel.setFrameUsingName("EditTheFuturePanel") { panel.center() }

        panel.shortcuts = shortcuts
        panel.onAction = { [weak self] action in self?.perform(action) }
        panel.onHide = { [weak self] in self?.hide() }
        panel.onCopySnapshot = { [weak self] in self?.copy(.everything) }
        panel.onUndo = { [weak self] in self?.store.undo() }
        panel.onRedo = { [weak self] in self?.store.redo() }
        panel.onShowSettings = { [weak self] in self?.onShowSettings?() }
        panel.onKey = { [weak self] event in
            self.map { TimelineKeys.handle(event, store: $0.store, shortcuts: $0.shortcuts) } ?? false
        }
        panel.onEscape = { [weak self] in
            guard let store = self?.store, store.goal != nil else { return false }
            store.cancelGoal()
            return true
        }
        panel.onCommandReturn = { [weak self] in
            guard let store = self?.store, store.goal?.selectedFix != nil else { return false }
            store.applyGoalFix()
            return true
        }

        store.onAppAction = { [weak self] action in
            switch action {
            case .copySnapshot: self?.copy(.everything)
            case .copyData: self?.copy(.dataOnly)
            default: break
            }
        }

        followBlurSetting()
        followTheme()
    }

    /// Does what a panel shortcut asks for (docs/UI.md, 4.1).
    private func perform(_ action: ShortcutSettings.Action) {
        switch action {
        case .commandBar: store.requestCommandBarFocus()
        case .slotTab: store.toggleSlotSettings()
        case .formulaTab: store.showFormulaEditor()
        case .copyData: copy(.dataOnly)
        case .largerText: stepTextSize(1)
        case .smallerText: stepTextSize(-1)
        case .standardText: stepTextSize(0)
        default: break
        }
    }

    /// ⌘+ and ⌘− make the text a point larger or smaller, and ⌘0 puts it back (docs/UI.md, 7).
    private func stepTextSize(_ steps: Int) {
        let size = appearance.stepTextSize(steps)
        store.say("Text size \(Int(size)) pt" + (size == AppearanceSettings.standardTextSize ? " (standard)" : ""))
    }

    /// Gives the window the theme's appearance, so what AppKit draws in it (the formula editor,
    /// menus, date fields) matches; with Match the Mac it follows the system.
    private func followTheme() {
        let theme = withObservationTracking { appearance.theme } onChange: { [weak self] in
            Task { @MainActor in self?.followTheme() }
        }
        let wanted: NSAppearance? = switch theme {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
        if panel.appearance?.name != wanted?.name { panel.appearance = wanted }
    }

    /// Shows or hides the blur to match the store, and again each time the setting changes.
    private func followBlurSetting() {
        let blurs = withObservationTracking { store.blursBehind } onChange: { [weak self] in
            Task { @MainActor in self?.followBlurSetting() }
        }
        if blur?.isHidden != !blurs { blur?.isHidden = !blurs }
    }

    // MARK: Showing and hiding

    func toggle() {
        if panel.isVisible && !isPeeking { hide() } else { showFully() }
    }

    func showFully() {
        isPeeking = false
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        isPeeking = false
        panel.orderOut(nil)
    }

    /// Puts the panel away for good, when another scenario opens in its place.
    func tearDown() {
        panel.orderOut(nil)
        // Frees the frame's name for the next panel, which remembers the same frame.
        panel.saveFrame(usingName: "EditTheFuturePanel")
        panel.setFrameAutosaveName("")
    }

    /// Shows the panel without taking keyboard focus from the app you're working in.
    func beginPeek() {
        isPeeking = true
        panel.orderFrontRegardless()
    }

    /// Opens the add-event card at `date` (the cursor by default) and brings the panel forward.
    /// An event being edited is left as it was.
    func addEvent(at date: Date? = nil) {
        showFully()
        store.stopEditingEvent()
        store.beginEvent(at: date ?? store.cursor)
    }

    /// The summon key (hot-key or hardware): tap toggles, hold peeks.
    func summonPressed() {
        apply(peekGesture.press(at: Date(), panelVisible: panel.isVisible && !isPeeking))
    }

    func summonReleased() {
        apply(peekGesture.release(at: Date()))
    }

    private func apply(_ action: PeekGesture.Action) {
        switch action {
        case .beginPeek: beginPeek()
        case .hide: hide()
        case .showFully: showFully()
        case .nothing: break
        }
    }

    // MARK: Copying

    enum CopyContents { case everything, dataOnly }

    func copy(_ contents: CopyContents) {
        do {
            let message = try SnapshotExporter.copy(state: store.panelState(), data: store.snapshotData(),
                                                    contents: contents == .everything ? .everything : .dataOnly)
            store.say(message)
        } catch {
            store.say("Couldn't copy: \(error.localizedDescription)", isError: true)
        }
    }
}

/// The panel in the look chosen in Settings, redrawn when it changes, or when the Mac changes
/// between light and dark or turns Increase Contrast on.
struct StyledPanel: View {
    let appearance: AppearanceSettings
    let shortcuts: ShortcutSettings
    let panel: PanelView
    /// Told whether the panel is light or dark, for what's behind it.
    var onScheme: (ColorScheme) -> Void = { _ in }
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let style = appearance.style(colorScheme: systemScheme, increasedContrast: contrast == .increased)
        panel.futureStyle(style)
            .environment(\.shortcutLabels, shortcuts.labels)
            .onChange(of: style.colorScheme, initial: true) { onScheme(style.colorScheme) }
    }
}
#endif
