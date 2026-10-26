#if os(macOS)
import AppKit
import SwiftUI
import FutureUI

/// Owns the floating panel: showing, hiding, peeking, adding events, scrolling and keys.
@MainActor
final class PanelController {
    let store: ScenarioStore
    let panel: FloatingPanel
    /// The panel's SwiftUI content, for placing the pointer in the panel's top-left coordinates.
    private weak var hosting: NSView?
    private var peekGesture = PeekGesture()
    private(set) var isPeeking = false
    private var eventMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(store: ScenarioStore) {
        self.store = store
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820))

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let actions = PanelActions(
            hide: { [weak self] in self?.hide() },
            copySnapshot: { [weak self] in self?.copy(.everything) }
        )
        let hosting = NSHostingView(rootView: PanelView(store: store, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        self.hosting = hosting
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
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        store.onAppAction = { [weak self] action in
            switch action {
            case .copySnapshot: self?.copy(.everything)
            case .copyData: self?.copy(.dataOnly)
            default: break
            }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleGesture(event) ? nil : event
        }
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
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
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
    func addEvent(at date: Date? = nil) {
        showFully()
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

    // MARK: Input

    private func handleGesture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .magnify:
            store.zoom(by: 1 - event.magnification)
            return true
        case .scrollWheel:
            // Over anything but the graphs and lanes, the wheel scrolls what's under the pointer:
            // the formula editor, the insert palette, the Slot tab.
            guard let hosting, store.isOverTimeline(hosting.convert(event.locationInWindow, from: nil)) else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let (action, found) = scrollMapper.map(ScrollMapper.Input(
                dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas,
                shift: flags.contains(.shift), command: flags.contains(.command),
                inverted: event.isDirectionInvertedFromDevice))
            if found { rememberHorizontalWheel(true, announce: true) }
            switch action {
            case .pan(let fraction): store.pan(by: fraction)
            case .zoom(let factor): store.zoom(by: factor)
            case .none: return false
            }
            return true
        default:
            return false
        }
    }

    // MARK: Mouse wheels

    static let horizontalWheelKey = "mouse.hasHorizontalWheel"
    private var scrollMapper = ScrollMapper(hasHorizontalWheel: UserDefaults.standard.bool(forKey: horizontalWheelKey))

    var hasHorizontalWheel: Bool { scrollMapper.hasHorizontalWheel }

    /// Records whether the mouse has a horizontal wheel (found automatically, or set from the menu).
    func rememberHorizontalWheel(_ has: Bool, announce: Bool = false) {
        scrollMapper.hasHorizontalWheel = has
        UserDefaults.standard.set(has, forKey: Self.horizontalWheelKey)
        if announce {
            store.say("Horizontal wheel found: the vertical wheel now zooms and the horizontal wheel scrolls through time.")
        }
    }

    /// Keys from docs/UI.md, 4.1, when the command bar isn't being edited.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 123: store.moveCursor(by: -1, years: flags.contains(.shift)); return true  // ←
        case 124: store.moveCursor(by: 1, years: flags.contains(.shift)); return true   // →
        default: break
        }
        guard flags.subtracting(.shift).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "t": store.jumpToNow(); return true
        case "e": store.beginEvent(at: store.cursor); return true
        case "=", "+": store.zoom(by: 0.8); return true
        case "-": store.zoom(by: 1.25); return true
        default:
            if let number = Int(key), (1...ScenarioStore.bankSize).contains(number) {
                store.focus(key: number)
                return true
            }
            return false
        }
    }
}
#endif
