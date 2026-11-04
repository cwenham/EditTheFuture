#if os(macOS)
import AppKit
import FutureUI

/// A translucent panel that floats over other apps without activating this one
/// (docs/UI.md, section 3). Keyboard shortcuts that aren't text editing are handled here.
final class FloatingPanel: NSPanel {
    /// The shortcuts chosen in Settings (docs/UI.md, 4.1).
    var shortcuts: ShortcutSettings?
    /// A panel shortcut was pressed.
    var onAction: ((ShortcutSettings.Action) -> Void)?
    var onHide: (() -> Void)?
    /// Keys no text field or panel shortcut took, for the graph.
    var onKey: ((NSEvent) -> Bool)?
    /// Esc before hiding: true when it dropped something, such as a Drag the future target.
    var onEscape: (() -> Bool)?
    /// ⌘↩: true when it was used.
    var onCommandReturn: (() -> Bool)?
    /// The Mac's own keys, which Settings doesn't change: ⌘C copies a snapshot and ⌘Z and ⇧⌘Z
    /// undo and redo when no text field is being typed in, and ⌘, opens Settings.
    var onCopySnapshot: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onShowSettings: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Only the top bar moves the panel; the timeline needs its drags for itself.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 1100, height: 600)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var isEditingText: Bool { firstResponder is NSTextView }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘↩ adds Drag the future's chosen fix, when one is showing.
        if flags == .command, event.keyCode == 36, onCommandReturn?() == true { return true }
        switch (flags, event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (.command, ","): onShowSettings?(); return true
        case (.command, "c") where !isEditingText: onCopySnapshot?(); return true
        case (.command, "z") where !isEditingText: onUndo?(); return true
        case ([.command, .shift], "z") where !isEditingText: onRedo?(); return true
        default: break
        }
        if let action = shortcuts?.action(for: event, in: .panel),
           !isEditingText || ShortcutSettings.takesWhileTyping(action, event) {
            onAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !isEditingText {
            if let action = shortcuts?.action(for: event, in: .panel) {
                onAction?(action)
                return
            }
            if onKey?(event) == true { return }
        }
        super.keyDown(with: event)
    }

    /// Escape leaves the command bar first, then drops what's being proposed (a Drag the future
    /// target), then hides the panel.
    override func cancelOperation(_ sender: Any?) {
        if isEditingText {
            makeFirstResponder(contentView)
        } else if onEscape?() == true {
            return
        } else {
            onHide?()
        }
    }
}
#endif
