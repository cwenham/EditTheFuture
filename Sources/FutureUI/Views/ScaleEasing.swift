import Foundation
import SwiftUI

/// Which graph a value range belongs to. A range only eases between values of the same kind:
/// focusing a slot with another kind of value (degrees after dollars) changes the scale at once,
/// since there's no sense in moving between the two.
struct ScaleKey: Hashable {
    enum Role: Hashable {
        case focus
        /// A slot drawn over the focused graph on its own scale, by its position.
        case overlay(Int)
        /// A lane, by its slot's position.
        case lane(Int)
    }
    let role: Role
    let style: ValueStyle
}

/// Graphs' value ranges, eased to new ones over a second instead of jumping, so a change of
/// scale while scrolling or choosing slots is easy to follow (docs/UI.md, 2.4).
///
/// Each new target starts from where the range is drawn now, and the motion starts fast and
/// slows down (ease-out), so ranges that change on every scroll step follow smoothly rather
/// than stalling at the start of each one.
///
/// `time` is the frame being drawn, advanced once a frame while anything eases. It's the only
/// observed property, and only the views that draw a range read it (`Eased`), so only they
/// redraw on each frame, as only the cursor's views redraw when the pointer moves.
@MainActor
@Observable
final class ScaleEasing {
    nonisolated static let duration: TimeInterval = 1

    struct Motion: Equatable {
        var from: ClosedRange<Double>
        var to: ClosedRange<Double>
        var start: Date

        /// The range drawn at `time`.
        func range(at time: Date) -> ClosedRange<Double> {
            let elapsed = time.timeIntervalSince(start) / ScaleEasing.duration
            guard elapsed < 1 else { return to }
            let t = max(0, elapsed)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            let low = from.lowerBound + (to.lowerBound - from.lowerBound) * eased
            let high = from.upperBound + (to.upperBound - from.upperBound) * eased
            // Ranges are kept finite by niceTicks, but a range is never built from unchecked numbers.
            guard low.isFinite, high.isFinite, low <= high else { return to }
            return low...high
        }

        func isMoving(at time: Date) -> Bool { from != to && time < end }
        var end: Date { start.addingTimeInterval(ScaleEasing.duration) }
    }

    @ObservationIgnored private(set) var motions: [ScaleKey: Motion] = [:]
    /// The frame being drawn.
    private(set) var time = Date.distantPast
    /// The same, unobserved, for working out where a range is drawn without redrawing for it.
    @ObservationIgnored private var drawnTime = Date.distantPast

    /// Moves to the next frame.
    func advance(to date: Date) {
        guard date > drawnTime else { return }
        drawnTime = date
        time = date
    }

    /// Sets each graph's target range, as of `time`. A changed target starts a new motion from
    /// where the range is drawn now; a graph seen for the first time starts at its target. Graphs
    /// no longer drawn are forgotten. Calling it again with the same targets changes nothing.
    func retarget(_ targets: [ScaleKey: ClosedRange<Double>], at time: Date) {
        var next: [ScaleKey: Motion] = [:]
        for (key, target) in targets {
            if let motion = motions[key], motion.to == target {
                next[key] = motion
            } else if let motion = motions[key] {
                next[key] = Motion(from: motion.range(at: drawnTime), to: target, start: time)
            } else {
                next[key] = Motion(from: target, to: target, start: time)
            }
        }
        if next != motions { motions = next }
    }

    /// The range to draw for a graph at `time`: its target, unless it's still easing towards it.
    func range(_ key: ScaleKey, target: ClosedRange<Double>, at time: Date) -> ClosedRange<Double> {
        guard let motion = motions[key], motion.to == target else { return target }
        return motion.range(at: time)
    }

    /// The range to draw for a graph in the frame being drawn. A graph that has eased reads the
    /// frame's time, so it redraws on each frame of its next change.
    func range(_ key: ScaleKey, target: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let motion = motions[key], motion.to == target, motion.from != motion.to else { return target }
        return motion.range(at: time)
    }

    func isMoving(at time: Date) -> Bool { motions.values.contains { $0.isMoving(at: time) } }

    /// When the last motion ends, or nil when nothing is moving.
    func end(after time: Date) -> Date? {
        motions.values.filter { $0.isMoving(at: time) }.map(\.end).max()
    }
}

extension TimelineState {
    /// The ranges its graphs are drawn over, by graph.
    var scaleTargets: [ScaleKey: ClosedRange<Double>] {
        var targets = [ScaleKey(role: .focus, style: focus.style): focus.yDomain]
        for overlay in overlays where overlay.ownScale {
            targets[ScaleKey(role: .overlay(overlay.key), style: overlay.style)] = overlay.yDomain
        }
        for lane in lanes {
            targets[ScaleKey(role: .lane(lane.key), style: lane.style)] = lane.yDomain
        }
        return targets
    }

    /// This state with each graph's range where `easing` has it at `time`, or in the frame being
    /// drawn with nil.
    @MainActor func eased(by easing: ScaleEasing, at time: Date? = nil) -> TimelineState {
        func range(_ key: ScaleKey, _ target: ClosedRange<Double>) -> ClosedRange<Double> {
            time.map { easing.range(key, target: target, at: $0) } ?? easing.range(key, target: target)
        }
        var copy = self
        copy.focus.yDomain = range(ScaleKey(role: .focus, style: focus.style), focus.yDomain)
        for index in copy.overlays.indices {
            let overlay = copy.overlays[index]
            copy.overlays[index].yDomain = overlay.ownScale
                ? range(ScaleKey(role: .overlay(overlay.key), style: overlay.style), overlay.yDomain)
                : copy.focus.yDomain
        }
        for index in copy.lanes.indices {
            let lane = copy.lanes[index]
            copy.lanes[index].yDomain = range(ScaleKey(role: .lane(lane.key), style: lane.style), lane.yDomain)
        }
        return copy
    }
}

extension LaneState {
    /// Where its range is drawn in the frame being drawn.
    @MainActor func easedDomain(by easing: ScaleEasing?) -> ClosedRange<Double> {
        easing?.range(ScaleKey(role: .lane(key), style: style), target: yDomain) ?? yDomain
    }
}

/// Builds its content from the timeline with each graph's range part-way through any change of
/// scale. Only views inside one redraw on each frame of a change; put just what draws a range in it.
struct Eased<Content: View>: View {
    let timeline: TimelineState
    let scales: ScaleEasing?
    @ViewBuilder let content: (TimelineState) -> Content

    var body: some View {
        content(scales.map { timeline.eased(by: $0) } ?? timeline)
    }
}
