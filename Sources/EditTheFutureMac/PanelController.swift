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
    /// What the wheels do over the graph, remembered between launches. The menu bar item can change it.
    let wheel = TimelineWheel(rememberingUnder: PanelController.horizontalWheelKey)
    /// What's behind the panel, blurred; hidden when the panel is set to clear.
    private weak var blur: NSVisualEffectView?

    var isVisible: Bool { panel.isVisible }

    init(store: ScenarioStore, scenarios: ScenarioMenuActions? = nil) {
        self.store = store
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
        let hosting = NSHostingView(rootView: PanelView(store: store, actions: actions, wheel: wheel))
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

        panel.onCopySnapshot = { [weak self] in self?.copy(.everything) }
        panel.onCopyData = { [weak self] in self?.copy(.dataOnly) }
        panel.onFocusCommandBar = { [weak self] in self?.store.requestCommandBarFocus() }
        panel.onUndo = { [weak self] in self?.store.undo() }
        panel.onRedo = { [weak self] in self?.store.redo() }
        panel.onToggleSlotSettings = { [weak self] in self?.store.toggleSlotSettings() }
        panel.onShowFormula = { [weak self] in self?.store.showFormulaEditor() }
        panel.onHide = { [weak self] in self?.hide() }
        panel.onKey = { [weak self] event in self.map { TimelineKeys.handle(event, store: $0.store) } ?? false }
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

    // MARK: Mouse wheels

    static let horizontalWheelKey = "mouse.hasHorizontalWheel"

    var hasHorizontalWheel: Bool { wheel.hasHorizontalWheel }

    /// Records whether the mouse has a horizontal wheel, as set from the menu. The graph finds one
    /// itself the first time it's used.
    func rememberHorizontalWheel(_ has: Bool) {
        wheel.hasHorizontalWheel = has
    }
}
#endif
