#if os(macOS)
import AppKit

// A menu bar utility: no Dock icon, a floating panel and a status item.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
#endif
