import Foundation

/// Turns presses of the summon key (hot-key or hardware button) into panel actions.
///
/// - A tap (released within `holdThreshold`) toggles the panel.
/// - A hold peeks: the panel shows on press and hides on release.
public struct PeekGesture: Sendable {
    public enum Action: Equatable, Sendable {
        /// Show the panel for peeking, without taking keyboard focus.
        case beginPeek
        /// Hide the panel.
        case hide
        /// Keep the panel and make it the focused, interactive panel.
        case showFully
        case nothing
    }

    public var holdThreshold: TimeInterval
    private var pressedAt: Date?
    private var wasVisible = false

    public init(holdThreshold: TimeInterval = 0.25) {
        self.holdThreshold = holdThreshold
    }

    public mutating func press(at time: Date, panelVisible: Bool) -> Action {
        guard pressedAt == nil else { return .nothing }  // ignore key repeat
        pressedAt = time
        wasVisible = panelVisible
        return panelVisible ? .nothing : .beginPeek
    }

    public mutating func release(at time: Date) -> Action {
        guard let pressedAt else { return .nothing }
        self.pressedAt = nil
        let held = time.timeIntervalSince(pressedAt) >= holdThreshold
        switch (wasVisible, held) {
        case (false, true): return .hide        // peek ends
        case (false, false): return .showFully  // tap while hidden: open
        case (true, false): return .hide        // tap while open: close
        case (true, true): return .nothing      // held while already open: leave it
        }
    }
}
