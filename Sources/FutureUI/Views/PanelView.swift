import SwiftUI

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
    @FocusState private var commandFocused: Bool
    @AppStorage("eventPaneSide") private var paneSideName = PaneSide.right.rawValue
    @State private var paneOffset = CGSize.zero
    @State private var paneDragLocation: CGPoint?

    /// Coordinate space of the area under the header, used to drag the add-event pane.
    static let bodySpace = "panelBody"
    /// The whole panel, top left at 0, 0: the hosting view's own coordinates. (SwiftUI's global
    /// space starts at the window's top, which is lower down when the window has a title bar.)
    static let panelSpace = "panel"
    static let paneGap: CGFloat = 16

    public init(store: ScenarioStore, actions: PanelActions) {
        self.store = store
        self.actions = actions
    }

    public var body: some View {
        let side = PaneSide(rawValue: paneSideName) ?? .right
        VStack(spacing: 0) {
            PanelHeader(store: store, actions: actions)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            GeometryReader { area in
                HStack(alignment: .top, spacing: Self.paneGap) {
                    if side == .left { pane(side: side, areaWidth: area.size.width) }
                    TimelineArea(store: store)
                    if side == .right { pane(side: side, areaWidth: area.size.width) }
                }
                .overlay {
                    if let location = paneDragLocation {
                        DockZones(highlighted: location.x < area.size.width / 2 ? .left : .right,
                                  width: SidePane.width(for: store.sidePane))
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
        .environment(\.colorScheme, .dark)
        .onChange(of: store.commandBarFocusRequest) { commandFocused = true }
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
            })
            .offset(paneOffset)
            .shadow(color: .black.opacity(paneDragLocation == nil ? 0 : 0.5), radius: 24, y: 12)
            .zIndex(1)
    }
}

/// The focus title, timeline rows and hover handling. It reads only the timeline state, so
/// moving the pointer doesn't redraw it; the cursor views inside read the cursor themselves.
struct TimelineArea: View {
    let store: ScenarioStore

    var body: some View {
        let timeline = store.timelineState()
        VStack(alignment: .leading, spacing: 8) {
            FocusTitle(focus: timeline.focus)
            GeometryReader { geometry in
                let plotWidth = TimelineLayout.plotWidth(forTotal: geometry.size.width)
                let focusHeight = TimelineLayout.focusHeight(forTotal: geometry.size.height, laneCount: timeline.lanes.count)
                TimelineRows(timeline: timeline, cursor: .live(store), plotWidth: plotWidth, focusHeight: focusHeight,
                             interactions: TimelineInteractions(
                                focusLane: { store.focus(index: $0) },
                                pickDate: { store.beginEvent(at: timeline.frame.date(atFraction: $0)) },
                                pickDateOnLane: { index, fraction in
                                    store.beginEvent(at: timeline.frame.date(atFraction: fraction), slotIndex: index)
                                },
                                editEvent: { store.editEvent(id: $0) }))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase else { return }
                        let x = location.x - TimelineLayout.plotLeading
                        if x >= 0 && x <= plotWidth {
                            store.setCursor(fraction: Double(x / plotWidth))
                        }
                    }
            }
            // The app sends the mouse wheel to time only over this area.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelView.panelSpace)) } action: { store.timelineFrame = $0 }
        }
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
                        SlotChip(store: store, slot: store.slots[index], selected: index == store.focusedIndex)
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
                    Text("Opacity").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Slider(value: $store.opacity, in: 0.6...1)
                        .frame(width: 80)
                        .controlSize(.mini)
                        .accessibilityLabel("Panel opacity")
                }
                .padding(.horizontal, 8)
                IconButton(systemName: "xmark", label: "Hide panel (Escape)", action: actions.hide)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background {
            #if os(macOS)
            WindowDragArea()
            #endif
        }
    }
}

#if os(macOS)
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

/// A slot's chip in the header: click to focus, right-click for its menu, drag onto another
/// number to move it (docs/UI.md, 5.7).
///
/// It keeps the slot itself, not its index in `store.slots`: after a slot is removed, SwiftUI can
/// draw a chip once more with what it was given before, and an old index can be past the end.
struct SlotChip: View {
    let store: ScenarioStore
    let slot: ScenarioStore.SlotInfo
    let selected: Bool

    var body: some View {
        Button {
            if let index = store.slotIndex(id: slot.id) { store.focus(index: index) }
        } label: {
            HStack(spacing: 7) {
                Text("\(slot.key)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                Circle().fill(slot.color).frame(width: 8, height: 8)
                Text(slot.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if slot.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Paused")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(selected ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.white.opacity(0.22) : Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(slot.pausedReason.map { "\(slot.title) is paused: \($0)" } ?? "Focus \(slot.title)  \(slot.key)")
        .contextMenu { SlotMenu(store: store, slot: slot) }
        .draggable(slot.id.uuidString) {
            Text(slot.title).font(.system(size: 13, weight: .medium)).padding(6)
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
                Text("\(key)").font(.system(size: 11)).monospacedDigit()
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
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
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                Text("Now").font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
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
                .font(.system(size: 13))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct FocusTitle: View {
    let focus: FocusedSlotState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(focus.color).frame(width: 10, height: 10)
            Text(focus.name).font(.system(size: 18, weight: .semibold))
            Text(focus.summary).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }
}

struct PanelFooter: View {
    @Bindable var store: ScenarioStore
    var commandFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 12))
                TextField("Add an event or run a command, e.g. +500 monthly from 2027-03", text: $store.commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(commandFocused)
                    .onSubmit { store.runCommandFromPanel() }
                    .accessibilityLabel("Command")
                Text("⌘K")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.16)))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))

            Text(store.message ?? store.statusText())
                .font(.system(size: 12))
                .foregroundStyle(store.messageIsError ? Theme.error : Theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: 420, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
