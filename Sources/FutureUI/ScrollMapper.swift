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

    public init(hasHorizontalWheel: Bool = false) {
        self.hasHorizontalWheel = hasHorizontalWheel
    }

    /// Returns what to do, and whether this event revealed a horizontal wheel for the first time.
    public mutating func map(_ input: Input) -> (action: Action, foundHorizontalWheel: Bool) {
        if input.precise { return (mapPrecise(input), false) }

        if input.shift || input.command {
            // Shift + vertical wheel arrives as a horizontal delta.
            let amount = input.dy != 0 ? input.dy : input.dx
            return (amount == 0 ? .none : .zoom(Self.wheelZoom(amount, inverted: input.inverted)), false)
        }
        if input.dx != 0 {
            let found = !hasHorizontalWheel
            hasHorizontalWheel = true
            return (.pan(-input.dx * 0.04), found)
        }
        if input.dy != 0 {
            return (hasHorizontalWheel ? .zoom(Self.wheelZoom(input.dy, inverted: input.inverted)) : .pan(-input.dy * 0.04), false)
        }
        return (.none, false)
    }

    private func mapPrecise(_ input: Input) -> Action {
        let amount = abs(input.dx) >= abs(input.dy) ? input.dx : input.dy
        guard amount != 0 else { return .none }
        if input.shift || input.command {
            let up = input.inverted ? -amount : amount
            return .zoom(min(max(1 - up * 0.004, 0.5), 2))
        }
        return .pan(-amount * 0.0015)
    }

    /// Wheel turned away from you (up) zooms in, whatever the natural-scrolling setting.
    static func wheelZoom(_ amount: Double, inverted: Bool) -> Double {
        let up = inverted ? -amount : amount
        return pow(0.88, up)
    }
}
