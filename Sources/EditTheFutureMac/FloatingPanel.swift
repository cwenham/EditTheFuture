#if os(macOS)
import AppKit

/// A translucent panel that floats over other apps without activating this one
/// (docs/UI.md, section 3). Keyboard shortcuts that aren't text editing are handled here.
final class FloatingPanel: NSPanel {
    var onCopySnapshot: (() -> Void)?
    var onCopyData: (() -> Void)?
    var onFocusCommandBar: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onToggleSlotSettings: (() -> Void)?
    var onHide: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

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
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && key == "k" {
            onFocusCommandBar?()
            return true
        }
        if flags == .command && key == "i" {
            onToggleSlotSettings?()
            return true
        }
        if !isEditingText {
            switch (flags, key) {
            case (.command, "c"): onCopySnapshot?(); return true
            case ([.command, .shift], "c"): onCopyData?(); return true
            case (.command, "z"): onUndo?(); return true
            case ([.command, .shift], "z"): onRedo?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !isEditingText, onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Escape leaves the command bar first, then hides the panel.
    override func cancelOperation(_ sender: Any?) {
        if isEditingText {
            makeFirstResponder(contentView)
        } else {
            onHide?()
        }
    }
}
#endif
