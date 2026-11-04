import SwiftUI
import FutureKit

/// Things the panel asks the app to do (they need AppKit or the window).
public struct PanelActions {
    public var hide: () -> Void
    public var copySnapshot: () -> Void
    /// The scenario menu's, or nil for a title that isn't a menu.
    public var scenarios: ScenarioMenuActions?

    public init(hide: @escaping () -> Void, copySnapshot: @escaping () -> Void, scenarios: ScenarioMenuActions? = nil) {
        self.hide = hide
        self.copySnapshot = copySnapshot
        self.scenarios = scenarios
    }
}

/// The floating panel's content (docs/UI.md, section 3).
public struct PanelView: View {
    @Bindable var store: ScenarioStore
    let actions: PanelActions
    let wheel: TimelineWheel?
    @FocusState private var commandFocused: Bool
    @AppStorage(PanelView.sideKey) private var paneSideName = PaneSide.right.rawValue
    @State private var paneOffset = CGSize.zero
    @State private var paneDragLocation: CGPoint?
    /// The widths the side pane was dragged to (SidePane.width(for:) until it is), at the standard
    /// text size: it's shown wider or narrower with the text, so it keeps its share of the panel.
    @AppStorage(PanelView.widthKey) private var slotPaneWidth = Double(SidePane.width)
    @AppStorage(PanelView.formulaWidthKey) private var formulaPaneWidth = Double(SidePane.formulaWidth)
    /// While its edge is dragged: the width it had when the drag began.
    @State private var resizeStart: CGFloat?
    @Environment(\.futureStyle.fonts.layoutScale) private var scale

    /// Coordinate space of the area under the header, used to drag the add-event pane.
    static let bodySpace = "panelBody"
    /// The whole panel, top left at 0, 0: the hosting view's own coordinates. (SwiftUI's global
    /// space starts at the window's top, which is lower down when the window has a title bar.)
    static let panelSpace = "panel"
    static let paneGap: CGFloat = 16

    /// Where the side pane's side and widths are remembered, in `UserDefaults.standard`.
    public static let sideKey = "EditTheFuture.panel.side"
    public static let widthKey = "EditTheFuture.panel.sidePaneWidth"
    public static let formulaWidthKey = "EditTheFuture.panel.formulaPaneWidth"
    /// Where the panel's opacity and blur are remembered.
    public static let opacityKey = "EditTheFuture.panel.opacity"
    public static let blurKey = "EditTheFuture.panel.blur"

    /// Puts back the opacity and blur the panel had last time, before it's first drawn. The panel
    /// remembers them itself whenever they change.
    @MainActor public static func restoreLook(of store: ScenarioStore, from defaults: UserDefaults = .standard) {
        if let opacity = defaults.object(forKey: opacityKey) as? Double, opacity.isFinite {
            let kept = min(max(opacity, 0.6), 1)
            if store.opacity != kept { store.opacity = kept }
        }
        if let blurs = defaults.object(forKey: blurKey) as? Bool, store.blursBehind != blurs { store.blursBehind = blurs }
    }

    /// - Parameter wheel: what the wheels do over the graph, shared with the app's menu; nil for the graph's own.
    public init(store: ScenarioStore, actions: PanelActions, wheel: TimelineWheel? = nil) {
        self.store = store
        self.actions = actions
        self.wheel = wheel
    }

    public var body: some View {
        let side = PaneSide(rawValue: paneSideName) ?? .right
        VStack(spacing: 0) {
            PanelHeader(store: store, actions: actions)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let request = store.trustRequest {
                TrustBanner(request: request, allow: store.allowHeldScenario, dismiss: store.dismissTrustRequest)
            }

            GeometryReader { area in
                HStack(alignment: .top, spacing: Self.paneGap) {
                    if side == .left { pane(side: side, areaWidth: area.size.width) }
                    ScenarioGraph(store: store, wheel: wheel, drawsBackground: false)
                    if side == .right { pane(side: side, areaWidth: area.size.width) }
                }
                .overlay {
                    if let location = paneDragLocation {
                        DockZones(highlighted: location.x < area.size.width / 2 ? .left : .right,
                                  width: paneWidth(areaWidth: area.size.width))
                    }
                }
            }
            .coordinateSpace(name: Self.bodySpace)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            PanelFooter(store: store, commandFocused: $commandFocused)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.panel.opacity(store.opacity))
        .coordinateSpace(name: Self.panelSpace)
        .futureAppearance()
        .onChange(of: store.commandBarFocusRequest) { commandFocused = true }
        .onChange(of: store.opacity) { UserDefaults.standard.set(store.opacity, forKey: Self.opacityKey) }
        .onChange(of: store.blursBehind) { UserDefaults.standard.set(store.blursBehind, forKey: Self.blurKey) }
    }

    /// The side pane's width for the tab it shows, kept within what fits.
    private func paneWidth(areaWidth: CGFloat) -> CGFloat {
        let stored = store.sidePane == .formula ? formulaPaneWidth : slotPaneWidth
        return SidePane.clamped(CGFloat(stored) * scale, for: store.sidePane, area: areaWidth, scale: scale)
    }

    /// Dragging the pane's inner edge: toward the timeline widens it.
    private func resize(side: PaneSide, areaWidth: CGFloat, by moved: CGFloat?) {
        guard let moved else {
            resizeStart = nil
            return
        }
        let start = resizeStart ?? paneWidth(areaWidth: areaWidth)
        if resizeStart == nil { resizeStart = start }
        let shown = SidePane.clamped(start + (side == .right ? -moved : moved), for: store.sidePane, area: areaWidth, scale: scale)
        let width = Double((shown / scale).rounded())
        if store.sidePane == .formula {
            if formulaPaneWidth != width { formulaPaneWidth = width }
        } else if slotPaneWidth != width {
            slotPaneWidth = width
        }
    }

    private func pane(side: PaneSide, areaWidth: CGFloat) -> some View {
        SidePane(
            store: store,
            side: side,
            onMoveToOtherSide: {
                withAnimation(.snappy) { paneSideName = side.other.rawValue }
            },
            onDragChanged: { value in
                paneOffset = value.translation
                paneDragLocation = value.location
            },
            onDragEnded: { value in
                let dropped: PaneSide = value.location.x < areaWidth / 2 ? .left : .right
                withAnimation(.snappy) {
                    paneSideName = dropped.rawValue
                    paneOffset = .zero
                }
                paneDragLocation = nil
            },
            width: paneWidth(areaWidth: areaWidth),
            onResize: { resize(side: side, areaWidth: areaWidth, by: $0) },
            onResetWidth: {
                withAnimation(.snappy) {
                    if store.sidePane == .formula { formulaPaneWidth = Double(SidePane.formulaWidth) }
                    else { slotPaneWidth = Double(SidePane.width) }
                }
            })
            .offset(paneOffset)
            .shadow(color: .black.opacity(paneDragLocation == nil ? 0 : 0.5), radius: 24, y: 12)
            .zIndex(1)
    }
}

struct PanelHeader: View {
    @Bindable var store: ScenarioStore
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 14) {
            ScenarioTitle(store: store, actions: actions.scenarios)

            HStack(spacing: 6) {
                ForEach(0..<ScenarioStore.bankSize, id: \.self) { position in
                    if let index = store.slotIndex(atPosition: position) {
                        SlotChip(store: store, slot: store.slots[index], selected: index == store.focusedIndex,
                                 overlaid: store.isOverlaid(store.slots[index].id))
                    } else {
                        EmptySlotChip(store: store, position: position)
                    }
                }
            }
            Spacer(minLength: 0)

            HStack(spacing: 2) {
                NowButton { store.jumpToNow() }
                    .padding(.trailing, 6)
                IconButton(systemName: "doc.on.doc", label: "Copy snapshot (Command-C)", action: actions.copySnapshot)
                HStack(spacing: 6) {
                    Text("Opacity").futureFont(12).foregroundStyle(Theme.secondary).fixedSize()
                    Slider(value: $store.opacity, in: 0.6...1)
                        .scaledFrame(width: 80)
                        .futureControlSize(.mini)
                        .accessibilityLabel("Panel opacity")
                    #if os(macOS)
                    Toggle("Blur", isOn: $store.blursBehind)
                        .toggleStyle(.checkbox)
                        .futureControlSize(.small)
                        .futureFont(12)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .help("Blur what's behind the panel. Off, the panel is clear, so you can read the windows beneath it.")
                        .accessibilityLabel("Blur behind panel")
                    #endif
                }
                .padding(.horizontal, 8)
                IconButton(systemName: "xmark", label: "Hide panel (Escape)", action: actions.hide)
            }
        }
        .padding(.horizontal, 14)
        .scaledFrame(height: 56)
        .background {
            #if os(macOS)
            WindowDragArea()
            #endif
        }
    }
}

#if os(macOS)
/// Asks before a scenario from elsewhere runs its scripts and fetches its feeds (docs/UI.md, 7).
struct TrustBanner: View {
    let request: TrustRequest
    let allow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "hand.raised.fill").futureFont(13).foregroundStyle(Theme.warning)
            // A floor on its width, or the panel's least height is worked out with the text a word wide.
            Text(request.text)
                .futureFont(12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
            Button("Not Now", action: dismiss)
                .help("Keep them waiting. The scenario menu can allow them later.")
            Button("Allow", action: allow)
                .buttonStyle(.borderedProminent)
                .tint(Theme.proposal.opacity(0.85))
                .foregroundStyle(Theme.onAccent)
                .help("Run its scripts and fetch its feeds, now and whenever it opens")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.warningFill)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// Lets the panel be moved by dragging its top bar, and only there.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
#endif

/// A slot's chip in the header: click to focus, ⌘- or ⇧-click to draw it over the graph too
/// (docs/UI.md, 5.12), right-click for its menu, drag onto another number to move it (docs/UI.md, 5.7).
///
/// It keeps the slot itself, not its index in `store.slots`: after a slot is removed, SwiftUI can
/// draw a chip once more with what it was given before, and an old index can be past the end.
struct SlotChip: View {
    let store: ScenarioStore
    let slot: ScenarioStore.SlotInfo
    let selected: Bool
    /// Drawn over the focused graph in its own colour.
    var overlaid = false

    var body: some View {
        Button {
            if let index = store.slotIndex(id: slot.id), let click = SlotClick.current { store.select(index: index, click: click) }
        } label: {
            HStack(spacing: 7) {
                Text("\(slot.key)").futureFont(11).monospacedDigit().foregroundStyle(Theme.secondary)
                Circle().fill(Color(slot.color)).frame(width: 8, height: 8)
                Text(slot.title).futureFont(13, weight: .medium).lineLimit(1)
                if slot.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .futureFont(11)
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Paused")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .scaledFrame(height: 30)
            .background(selected ? Theme.ink.opacity(0.10) : overlaid ? Theme.ink.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? AnyShapeStyle(Theme.ink.opacity(0.22)) : overlaid ? AnyShapeStyle(Color(slot.color).opacity(0.6))
                        : AnyShapeStyle(Theme.hairline)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected || overlaid ? .isSelected : [])
        .accessibilityAction(named: overlaid ? "Take off the graph" : "Overlay on the graph") {
            if let index = store.slotIndex(id: slot.id) { store.select(index: index, click: .toggle) }
        }
        .help(slot.pausedReason.map { "\(slot.title) is paused: \($0)" }
              ?? "Focus \(slot.title)  \(slot.key). ⌘-click to \(overlaid ? "take it off" : "draw it over") the graph, ⇧-click for a range.")
        .contextMenu { SlotMenu(store: store, slot: slot) }
        .draggable(slot.id.uuidString) {
            Text(slot.title).futureFont(13, weight: .medium).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            store.dropSlot(items.first, atPosition: slot.key - 1)
        }
    }
}

/// The chip menu: settings, model, duplicate, move and remove.
struct SlotMenu: View {
    let store: ScenarioStore
    let slot: ScenarioStore.SlotInfo

    var body: some View {
        // What ⌘-click does, for those who'd rather use the menu (docs/UI.md, 5.12).
        if store.focused.id != slot.id {
            Button(store.isOverlaid(slot.id) ? "Take Off the Graph" : "Overlay on the Graph") {
                act { store.select(index: $0, click: .toggle) }
            }
        } else if !store.overlaidIDs.isEmpty {
            Button("Show Only This Slot") { act { store.select(index: $0, click: .only) } }
        }
        Divider()
        Button("Slot settings") { act { store.showSlotSettings(forSlotAt: $0) } }
        Button("Change model…") { store.openPicker(.change(slot: slot.id)) }
        Button("Duplicate") { act { store.duplicateSlot(at: $0) } }
            .disabled(store.freePositions.isEmpty)
        Menu("Move to slot") {
            ForEach(0..<ScenarioStore.bankSize, id: \.self) { position in
                let other = store.slotIndex(atPosition: position).map { store.slots[$0].title }
                Button("\(position + 1)" + (other.map { " (swap with \($0))" } ?? "")) {
                    act { store.moveSlot(at: $0, toPosition: position) }
                }
                .disabled(position == slot.key - 1)
            }
        }
        Divider()
        Button("Remove…", role: .destructive) { act { store.requestRemoval(ofSlotAt: $0) } }
            .disabled(!store.canRemoveSlot)
    }

    /// Runs an action on the slot wherever it is now.
    private func act(_ action: (Int) -> Void) {
        if let index = store.slotIndex(id: slot.id) { action(index) }
    }
}

/// An empty position: click to add a model there.
struct EmptySlotChip: View {
    let store: ScenarioStore
    let position: Int

    var body: some View {
        let key = position + 1
        Button {
            store.openPicker(.add(position: position))
        } label: {
            HStack(spacing: 6) {
                Text("\(key)").futureFont(11).monospacedDigit()
                Image(systemName: "plus").futureFont(9, weight: .semibold)
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .scaledFrame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Add a model to slot \(key)")
        .accessibilityLabel("Slot \(key) is empty. Add a model")
        .contextMenu {
            Button("Add a model…") { store.openPicker(.add(position: position)) }
            Button("Add a data feed…") { store.openFeedSetup(.newSlot(position: position)) }
        }
        .popover(isPresented: Binding(get: { store.picker == .add(position: position) },
                                      set: { if !$0 { store.closePicker() } }),
                 arrowEdge: .bottom) {
            ModelPicker(store: store, request: .add(position: position))
        }
        // A second popover on the same view doesn't show, so this one hangs from a background.
        .background(Color.clear.popover(isPresented: Binding(get: { store.feedSetup == .newSlot(position: position) },
                                                             set: { if !$0 { store.closeFeedSetup() } }),
                                        arrowEdge: .bottom) {
            FeedSetup(store: store, request: .newSlot(position: position))
        })
        .dropDestination(for: String.self) { items, _ in
            store.dropSlot(items.first, atPosition: position)
        }
    }
}

/// Puts the cursor on now and scrolls back to it if it's out of view.
struct NowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").futureFont(11, weight: .semibold)
                Text("Now").futureFont(13, weight: .medium)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .scaledFrame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipBorder))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to now")
        .help("Jump to now  T")
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .futureFont(13)
                .scaledFrame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct FocusTitle: View {
    let focus: FocusedSlotState
    var overlays: [OverlayState] = []

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(Color(focus.color)).frame(width: 10, height: 10)
            Text(focus.name).futureFont(18, weight: .semibold)
            OverlayLegend(overlays: overlays)
            // The summary gives way first when the slots drawn over the graph need the room.
            Text(focus.summary).futureFont(12).foregroundStyle(Theme.secondary).lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 0)
        }
        .scaledFrame(height: 32)
    }
}

/// The slots drawn over the focused graph, each in its colour, after the focused slot's name
/// (docs/UI.md, 5.12). A slot on its own scale says so, and its help gives the scale.
struct OverlayLegend: View {
    let overlays: [OverlayState]

    var body: some View {
        if !overlays.isEmpty {
            HStack(spacing: 10) {
                ForEach(overlays) { overlay in
                    HStack(spacing: 5) {
                        Capsule().fill(Color(overlay.color)).frame(width: 12, height: 3)
                        Text(overlay.name).futureFont(13, weight: .medium).lineLimit(1)
                        if overlay.ownScale {
                            Text("own scale").futureFont(11).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    .fixedSize()
                    .help(Self.help(overlay))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    static func help(_ overlay: OverlayState) -> String {
        guard overlay.ownScale else { return "\(overlay.name), on the same axis" }
        return "\(overlay.name) is a different kind of value, so it has its own scale: "
            + "\(overlay.style.axis(overlay.yDomain.lowerBound)) at the bottom to \(overlay.style.axis(overlay.yDomain.upperBound)) at the top"
    }
}

struct PanelFooter: View {
    @Bindable var store: ScenarioStore
    var commandFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").futureFont(12)
                TextField("Add an event or run a command, e.g. +500 monthly from 2027-03", text: $store.commandText)
                    .textFieldStyle(.plain)
                    .futureFont(13)
                    .focused(commandFocused)
                    .onSubmit { store.runCommandFromPanel() }
                    .accessibilityLabel("Command")
                Text("⌘K")
                    .futureFont(11)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.ink.opacity(0.16)))
            }
            .padding(.horizontal, 12)
            .scaledFrame(height: 34)
            .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))

            Text(store.message ?? store.statusText())
                .futureFont(12)
                .foregroundStyle(store.messageIsError ? Theme.error : Theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: 420, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .scaledFrame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
