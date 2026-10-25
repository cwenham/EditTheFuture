import SwiftUI

/// Things the panel asks the app to do (they need AppKit or the window).
public struct PanelActions {
    public var hide: () -> Void
    public var copySnapshot: () -> Void

    public init(hide: @escaping () -> Void, copySnapshot: @escaping () -> Void) {
        self.hide = hide
        self.copySnapshot = copySnapshot
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
                        DockZones(highlighted: location.x < area.size.width / 2 ? .left : .right)
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
        .environment(\.colorScheme, .dark)
        .onChange(of: store.commandBarFocusRequest) { commandFocused = true }
    }

    private func pane(side: PaneSide, areaWidth: CGFloat) -> some View {
        AddEventPane(
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
                                }))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase else { return }
                        let x = location.x - TimelineLayout.plotLeading
                        if x >= 0 && x <= plotWidth {
                            store.setCursor(fraction: Double(x / plotWidth))
                        }
                    }
            }
        }
    }
}

struct PanelHeader: View {
    @Bindable var store: ScenarioStore
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .semibold))
                Text(store.name).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .allowsHitTesting(false)

            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { index in
                    if index < store.slots.count {
                        SlotChip(slot: store.slots[index], selected: index == store.focusedIndex) {
                            store.focus(index: index)
                        }
                    } else {
                        EmptySlotChip(key: index + 1)
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

struct SlotChip: View {
    let slot: ScenarioStore.SlotInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("\(slot.key)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                Circle().fill(slot.color).frame(width: 8, height: 8)
                Text(slot.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
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
        .help("Focus \(slot.title)  \(slot.key)")
    }
}

struct EmptySlotChip: View {
    let key: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(key)").font(.system(size: 11)).monospacedDigit()
            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityLabel("Slot \(key) is empty")
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
