#if os(macOS)
import AppKit
import Carbon

/// System-wide hot-keys with press and release callbacks, using Carbon's `RegisterEventHotKey`,
/// which needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    struct Shortcut: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32

        static let controlOption = UInt32(controlKey | optionKey)
    }

    private struct Handlers {
        let pressed: () -> Void
        let released: (() -> Void)?
    }

    private var handlers: [UInt32: Handlers] = [:]
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                center.handle(id: id, pressed: pressed)
            }
            return noErr
        }, eventTypes.count, &eventTypes, context, &eventHandler)
    }

    /// Registers a hot-key. Returns false if the system refused it (for example, it's taken).
    @discardableResult
    func register(_ shortcut: Shortcut, pressed: @escaping () -> Void, released: (() -> Void)? = nil) -> Bool {
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4554_4655), id: id)  // "ETFU"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else {
            NSLog("Edit The Future: couldn't register hot-key \(shortcut) (status \(status))")
            return false
        }
        references.append(reference)
        handlers[id] = Handlers(pressed: pressed, released: released)
        return true
    }

    private func handle(id: UInt32, pressed: Bool) {
        guard let handler = handlers[id] else { return }
        if pressed { handler.pressed() } else { handler.released?() }
    }
}
#endif
