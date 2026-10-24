import Foundation

/// What a hardware device should show for one slot.
public struct SlotFeedback: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case empty
        case idle
        case computing
        case error
    }

    public var name: String
    /// Palette index matching the slot's line color. 0 means off.
    public var colorIndex: UInt8
    public var status: Status
    public var isSelected: Bool
    public var isSoloed: Bool
    public var isVisible: Bool

    public init(name: String, colorIndex: UInt8, status: Status = .idle, isSelected: Bool = false,
                isSoloed: Bool = false, isVisible: Bool = true) {
        self.name = name
        self.colorIndex = colorIndex
        self.status = status
        self.isSelected = isSelected
        self.isSoloed = isSoloed
        self.isVisible = isVisible
    }

    public static let empty = SlotFeedback(name: "", colorIndex: 0, status: .empty, isVisible: false)
}

/// The app's state as a device sees it. Sent whenever it changes.
public struct DeviceFeedback: Hashable, Sendable, Codable {
    /// Zero-based bank number.
    public var bank: Int
    /// Up to 8 slots for the current bank.
    public var slots: [SlotFeedback]
    /// Short text for a display, e.g. "2030-01  41,223".
    public var cursorText: String
    public var wheelMode: WheelMode
    public var isPeeking: Bool

    public init(bank: Int = 0, slots: [SlotFeedback] = [], cursorText: String = "", wheelMode: WheelMode = .scroll,
                isPeeking: Bool = false) {
        self.bank = bank
        self.slots = slots
        self.cursorText = cursorText
        self.wheelMode = wheelMode
        self.isPeeking = isPeeking
    }
}
