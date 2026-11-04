import SwiftUI
#if os(macOS)
import AppKit
#endif
import FutureKit

/// A scenario's graph, for any app that embeds it (docs/DESIGN.md, 2.1): the focused slot's graph
/// with its time axis, the events strip and the other slots' lanes, with the cursor following the
/// pointer. It fills the frame it's given, and moves through time with the wheel and the trackpad
/// over it (docs/UI.md, 4.1). The panel shows one beside its side pane.
///
/// Clicks pick dates and events for the editors (`EventEditor`, `ScenarioEditor`); a graph made with
/// `interactive: false` only shows the cursor.
public struct ScenarioGraph: View {
    @Environment(\.timelineLayout) private var layout
    /// What shows besides the focused graph and its time axis.
    public struct Parts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The focused slot's name and model above the graph.
        public static let title = Parts(rawValue: 1)
        /// The events strip under the time axis.
        public static let events = Parts(rawValue: 2)
        /// A lane for each of the other slots.
        public static let lanes = Parts(rawValue: 4)
        public static let all: Parts = [.title, .events, .lanes]
    }

    let store: ScenarioStore
    let parts: Parts
    let interactive: Bool
    let wheel: TimelineWheel?
    let drawsBackground: Bool
    @State private var ownWheel = TimelineWheel()

    /// The graph's coordinate space, which drags inside it measure in.
    static let space = "scenarioGraph"

    /// - Parameters:
    ///   - interactive: whether clicks pick dates, edit events, set targets and select slots.
    ///   - wheel: shared by graphs that should agree on what the wheels do; nil gives this graph its own.
    ///   - drawsBackground: false leaves the background to what's behind, as the panel does with its own.
    public init(store: ScenarioStore, parts: Parts = .all, interactive: Bool = true, wheel: TimelineWheel? = nil,
                drawsBackground: Bool = true) {
        self.store = store
        self.parts = parts
        self.interactive = interactive
        self.wheel = wheel
        self.drawsBackground = drawsBackground
    }

    public var body: some View {
        // Reads only the timeline state, so moving the pointer doesn't redraw it; the cursor views
        // inside read the cursor themselves.
        let timeline = store.timelineState()
        VStack(alignment: .leading, spacing: 8) {
            if parts.contains(.title) {
                FocusTitle(focus: timeline.focus, overlays: timeline.overlays)
            }
            GeometryReader { geometry in
                let plotWidth = layout.plotWidth(forTotal: geometry.size.width)
                let showsLanes = parts.contains(.lanes), showsEvents = parts.contains(.events)
                let focusHeight = layout.focusHeight(forTotal: geometry.size.height,
                                                             laneCount: showsLanes ? timeline.lanes.count : 0,
                                                             events: showsEvents, lanes: showsLanes)
                TimelineRows(timeline: timeline, cursor: .live(store), backdrop: .live(store), plotWidth: plotWidth,
                             focusHeight: focusHeight, interactions: interactions(timeline),
                             showsEvents: showsEvents, showsLanes: showsLanes)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase else { return }
                        let x = location.x - layout.plotLeading
                        store.pointerHovered(at: Self.pointerOnScreen(else: location), fraction: Double(x / plotWidth))
                    }
                    // With large text in a small window, the lanes can need more room than there is:
                    // the last are cut off rather than drawn over what's below.
                    .frame(height: geometry.size.height, alignment: .top)
                    .clipped()
            }
            #if os(macOS)
            // The wheel and trackpad move time only over the graphs and lanes; elsewhere they
            // scroll what's under the pointer.
            .background { TimelineGestureCatcher(store: store, wheel: wheel ?? ownWheel) }
            #endif
        }
        .coordinateSpace(name: Self.space)
        .foregroundStyle(Theme.text)
        .background(drawsBackground ? Theme.panel : .clear)
        .futureAppearance()
    }

    /// What clicks on the graph do, or nil when it isn't interactive.
    func interactions(_ timeline: TimelineState) -> TimelineInteractions? {
        guard interactive else { return nil }
        return TimelineInteractions(
            selectSlot: { store.select(index: $0, click: $1) },
            pickDate: { store.beginEvent(at: timeline.frame.date(atFraction: $0)) },
            pickDateOnLane: { index, fraction in
                store.beginEvent(at: timeline.frame.date(atFraction: fraction), slotIndex: index)
            },
            editEvent: { store.editEvent(id: $0) },
            openDrift: { store.openDriftRefit(slot: store.focused.id) },
            canSetGoal: { store.canSetGoal(at: $0) },
            beginGoal: { store.beginGoal(at: $0, value: $1) },
            dragGoal: { store.dragGoal(to: $0) },
            endGoal: { store.endGoalDrag() })
    }

    /// Where the pointer is on screen, which changes only when the pointer moves. The hover's own
    /// location also changes when the graph shifts under a still pointer (a wider side pane).
    static func pointerOnScreen(else local: CGPoint) -> CGPoint {
        #if os(macOS)
        NSEvent.mouseLocation
        #else
        local
        #endif
    }
}

/// What the wheels do over a graph (`ScrollMapper`): with a horizontal wheel, the vertical wheel
/// zooms and the horizontal one moves through time; with one wheel, it moves through time and Shift
/// zooms. Left to itself (`.automatic`), it finds a horizontal wheel the first time one turns;
/// Settings can say which the mouse has instead (docs/UI.md, 7). Graphs given the same one agree.
@MainActor
@Observable
public final class TimelineWheel {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Find a horizontal wheel the first time it turns.
        case automatic
        /// The mouse has a horizontal wheel as well as the vertical one.
        case twoWheels
        /// The mouse has only a vertical wheel.
        case oneWheel

        public var id: String { rawValue }
    }

    @ObservationIgnored var mapper: ScrollMapper
    @ObservationIgnored private let key: String?
    @ObservationIgnored private let defaults: UserDefaults

    /// Which wheels the mouse has, or `.automatic` to find out.
    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            if let key { defaults.set(mode.rawValue, forKey: Self.modeKey(key)) }
            updateMapper()
        }
    }

    /// Whether a horizontal wheel has turned since it was last forgotten, for `.automatic`.
    public private(set) var foundHorizontalWheel: Bool

    /// The speeds offered, as multiples of the designed ones.
    public static let speeds: ClosedRange<Double> = 0.25...4

    /// How far a wheel turn or swipe moves through time, as a multiple of the designed speed.
    public var panSpeed: Double {
        didSet { speedChanged(panSpeed, oldValue, name: "panSpeed") }
    }

    /// How much a wheel turn or swipe zooms, as a multiple of the designed speed. Pinches follow the fingers.
    public var zoomSpeed: Double {
        didSet { speedChanged(zoomSpeed, oldValue, name: "zoomSpeed") }
    }

    /// Turns a mouse's horizontal wheel the other way.
    public var reversesHorizontalWheel: Bool {
        didSet {
            guard reversesHorizontalWheel != oldValue else { return }
            if let key { defaults.set(reversesHorizontalWheel, forKey: key + ".reversesHorizontal") }
            updateMapper()
        }
    }

    private func speedChanged(_ speed: Double, _ old: Double, name: String) {
        guard speed != old else { return }
        if let key { defaults.set(speed, forKey: key + "." + name) }
        updateMapper()
    }

    /// A stored speed, or 1 when there's none or it's out of range.
    private static func speed(_ defaults: UserDefaults, _ key: String?, _ name: String) -> Double {
        guard let key, let value = defaults.object(forKey: key + "." + name) as? Double, speeds.contains(value) else { return 1 }
        return value
    }

    /// - Parameters:
    ///   - key: where to remember what was found and chosen in `defaults`, or nil to find it again
    ///     each time the app runs. The mode is kept under the key followed by `.mode`.
    public init(rememberingUnder key: String? = nil, in defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        foundHorizontalWheel = key.map { defaults.bool(forKey: $0) } ?? false
        mode = key.flatMap { defaults.string(forKey: Self.modeKey($0)) }.flatMap(Mode.init(rawValue:)) ?? .automatic
        panSpeed = Self.speed(defaults, key, "panSpeed")
        zoomSpeed = Self.speed(defaults, key, "zoomSpeed")
        reversesHorizontalWheel = key.map { defaults.bool(forKey: $0 + ".reversesHorizontal") } ?? false
        mapper = ScrollMapper()
        updateMapper()
    }

    static func modeKey(_ key: String) -> String { key + ".mode" }

    /// Whether the vertical wheel zooms because there's a horizontal one to move through time.
    public var hasHorizontalWheel: Bool {
        switch mode {
        case .automatic: foundHorizontalWheel
        case .twoWheels: true
        case .oneWheel: false
        }
    }

    /// Records that a horizontal wheel turned (or, with false, forgets it), for `.automatic`.
    public func noteHorizontalWheel(_ found: Bool = true) {
        if foundHorizontalWheel != found { foundHorizontalWheel = found }
        if let key { defaults.set(found, forKey: key) }
        updateMapper()
    }

    private func updateMapper() {
        mapper.hasHorizontalWheel = hasHorizontalWheel
        mapper.findsHorizontalWheel = mode == .automatic
        mapper.panSpeed = min(max(panSpeed, Self.speeds.lowerBound), Self.speeds.upperBound)
        mapper.zoomSpeed = min(max(zoomSpeed, Self.speeds.lowerBound), Self.speeds.upperBound)
        mapper.reversesHorizontalWheel = reversesHorizontalWheel
    }

    /// The designed speeds, and the horizontal wheel the way macOS turns it.
    public func resetFeel() {
        if panSpeed != 1 { panSpeed = 1 }
        if zoomSpeed != 1 { zoomSpeed = 1 }
        if reversesHorizontalWheel { reversesHorizontalWheel = false }
    }
}

#if os(macOS)
/// The keys a graph answers to (docs/UI.md, 4.1): ← → move the cursor (⇧ a year), T jumps to now,
/// E adds an event at the cursor, + and − zoom, 1–8 focus a slot, and ↑ ↓ choose among Drag the
/// future's fixes while they show. The panel calls it for keys no text field took; an app that
/// embeds a graph can call it from its own key handling.
public enum TimelineKeys {
    /// Whether the key was used.
    @MainActor public static func handle(_ event: NSEvent, store: ScenarioStore) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if store.goal != nil, flags.subtracting(.numericPad).subtracting(.function).isEmpty {
            switch event.keyCode {
            case 126: store.moveGoalSelection(by: -1); return true  // ↑
            case 125: store.moveGoalSelection(by: 1); return true   // ↓
            default: break
            }
        }
        switch event.keyCode {
        case 123: store.moveCursor(by: -1, years: flags.contains(.shift)); return true  // ←
        case 124: store.moveCursor(by: 1, years: flags.contains(.shift)); return true   // →
        default: break
        }
        guard flags.subtracting(.shift).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "t": store.jumpToNow(); return true
        case "e": store.beginEvent(at: store.cursor); return true
        case "=", "+": store.zoom(by: 0.8); return true
        case "-": store.zoom(by: 1.25); return true
        default:
            if let number = Int(key), (1...ScenarioStore.bankSize).contains(number) {
                store.focus(key: number)
                return true
            }
            return false
        }
    }
}

/// Turns wheel, trackpad and pinch events over a graph into moving and zooming through time.
enum TimelineGestures {
    /// Whether the event was used.
    @MainActor static func handle(_ event: NSEvent, store: ScenarioStore, wheel: TimelineWheel) -> Bool {
        switch event.type {
        case .magnify:
            store.zoom(by: 1 - event.magnification)
            return true
        case .scrollWheel:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let (action, found) = wheel.mapper.map(ScrollMapper.Input(
                dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas,
                shift: flags.contains(.shift), command: flags.contains(.command),
                inverted: event.isDirectionInvertedFromDevice))
            if found {
                wheel.noteHorizontalWheel()
                store.say("Horizontal wheel found: the vertical wheel now zooms and the horizontal wheel scrolls through time.")
            }
            switch action {
            case .pan(let fraction): store.pan(by: fraction)
            case .zoom(let factor): store.zoom(by: factor)
            case .none: return false
            }
            return true
        default:
            return false
        }
    }
}

/// Sits behind the graph and takes the wheel, trackpad and pinch events over it. SwiftUI has no
/// wheel events on macOS 14, so it watches the window's events and takes those inside its bounds.
/// It never takes clicks.
struct TimelineGestureCatcher: NSViewRepresentable {
    let store: ScenarioStore
    let wheel: TimelineWheel

    func makeNSView(context: Context) -> TimelineGestureView { TimelineGestureView() }

    func updateNSView(_ view: TimelineGestureView, context: Context) {
        view.handler = { [store, wheel] event in TimelineGestures.handle(event, store: store, wheel: wheel) }
    }
}

final class TimelineGestureView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.covers(event) else { return event }
            return self.handler?(event) == true ? nil : event
        }
    }

    /// Whether the event happened over this view, in its window.
    func covers(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }
}
#endif
