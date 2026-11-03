import Foundation
#if os(macOS)
import AppKit
#endif
import FutureKit

extension SlotClick {
    /// From the keys held now: nil for a ⌃-click, which is a right-click. On a chip that opens
    /// its menu; on a lane it does nothing, as a right-click does there.
    @MainActor public static var current: SlotClick? {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return SlotClick(command: flags.contains(.command), shift: flags.contains(.shift), control: flags.contains(.control))
        #else
        return .only
        #endif
    }
}
