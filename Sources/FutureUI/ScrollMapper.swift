import Foundation

/// Turns scroll events into panning and zooming the timeline (docs/UI.md, 4.1).
///
/// macOS doesn't say how many wheels a mouse has, so this watches for one: a wheel event with
/// a horizontal delta and no Shift held can only come from a horizontal wheel. (macOS turns
/// Shift + vertical wheel into a horizontal delta, so Shift events don't count.)
///
/// - Mouse with two wheels: vertical wheel zooms, horizontal wheel scrolls through time.
/// - Mouse with one wheel: the wheel scrolls through time; Shift + wheel zooms.
/// - Trackpad or Magic Mouse: swipes scroll through time; Shift or ⌘ + swipe, or pinch, zooms.
public struct ScrollMapper: Sendable {
    public struct Input: Sendable {
        public var dx: Double
        public var dy: Double
        /// True for trackpads and the Magic Mouse; false for notched wheels.
        public var precise: Bool
        public var shift: Bool
        public var command: Bool
        /// The system's natural-scrolling setting flipped the deltas.
        public var inverted: Bool

        public init(dx: Double, dy: Double, precise: Bool, shift: Bool = false, command: Bool = false, inverted: Bool = false) {
            self.dx = dx
            self.dy = dy
            self.precise = precise
            self.shift = shift
            self.command = command
            self.inverted = inverted
        }
    }

    public enum Action: Equatable, Sendable {
        /// Pan by a fraction of the visible span; positive is later.
        case pan(Double)
        /// Multiply the visible span; below 1 zooms in.
        case zoom(Double)
        case none
    }

    public var hasHorizontalWheel: Bool
    /// Whether a horizontal delta reveals a horizontal wheel. Off when the wheels were chosen in
    /// Settings rather than left to be found.
    public var findsHorizontalWheel: Bool
    /// How far a wheel turn or swipe moves through time, and how much it zooms: 1 as designed.
    public var panSpeed: Double = 1
    public var zoomSpeed: Double = 1
    /// Turns a horizontal wheel the other way, for a mouse whose wheel feels backwards.
    public var reversesHorizontalWheel = false

    public init(hasHorizontalWheel: Bool = false, findsHorizontalWheel: Bool = true) {
        self.hasHorizontalWheel = hasHorizontalWheel
        self.findsHorizontalWheel = findsHorizontalWheel
    }

    private var pan: Double { panSpeed.isFinite && panSpeed > 0 ? panSpeed : 1 }
    private var zoom: Double { zoomSpeed.isFinite && zoomSpeed > 0 ? zoomSpeed : 1 }

    /// Returns what to do, and whether this event revealed a horizontal wheel for the first time.
    public mutating func map(_ input: Input) -> (action: Action, foundHorizontalWheel: Bool) {
        if input.precise { return (mapPrecise(input), false) }

        if input.shift || input.command {
            // Shift + vertical wheel arrives as a horizontal delta.
            let amount = input.dy != 0 ? input.dy : input.dx
            return (amount == 0 ? .none : .zoom(Self.wheelZoom(amount * zoom, inverted: input.inverted)), false)
        }
        if input.dx != 0 {
            let moved = Action.pan(-input.dx * 0.04 * pan * (reversesHorizontalWheel ? -1 : 1))
            guard findsHorizontalWheel else { return (moved, false) }
            let found = !hasHorizontalWheel
            hasHorizontalWheel = true
            return (moved, found)
        }
        if input.dy != 0 {
            return (hasHorizontalWheel ? .zoom(Self.wheelZoom(input.dy * zoom, inverted: input.inverted)) : .pan(-input.dy * 0.04 * pan), false)
        }
        return (.none, false)
    }

    private func mapPrecise(_ input: Input) -> Action {
        let amount = abs(input.dx) >= abs(input.dy) ? input.dx : input.dy
        guard amount != 0 else { return .none }
        if input.shift || input.command {
            let up = input.inverted ? -amount : amount
            return .zoom(min(max(1 - up * 0.004 * zoom, 0.5), 2))
        }
        return .pan(-amount * 0.0015 * pan)
    }

    /// Wheel turned away from you (up) zooms in, whatever the natural-scrolling setting.
    static func wheelZoom(_ amount: Double, inverted: Bool) -> Double {
        let up = inverted ? -amount : amount
        return pow(0.88, up)
    }
}
