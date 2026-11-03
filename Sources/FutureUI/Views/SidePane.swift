import SwiftUI
import FutureKit

/// The side pane (docs/UI.md, section 3): docked on one side of the timeline, with an Event tab
/// for adding events and a Slot tab for the focused slot's model and values.
struct SidePane: View {
    @Bindable var store: ScenarioStore
    let side: PaneSide
    var onMoveToOtherSide: () -> Void
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: (DragGesture.Value) -> Void
    /// How wide it is: the Event and Slot tabs share one width, and the Formula tab has its own.
    var width: CGFloat = SidePane.width
    /// Dragging the edge that faces the timeline: how far the pointer has moved across, then nil when it's let go.
    var onResize: (CGFloat?) -> Void = { _ in }
    /// Double-clicking that edge.
    var onResetWidth: () -> Void = {}

    /// The widths it starts at. The Formula tab is wider, so lines of formula fit.
    static let width: CGFloat = 300
    static let formulaWidth: CGFloat = 480
    /// The narrowest each can be dragged to.
    static let minimumWidth: CGFloat = 260
    static let minimumFormulaWidth: CGFloat = 360
    /// How much room the timeline keeps beside it, however wide it's dragged.
    static let timelineRoom: CGFloat = 420

    static func width(for tab: ScenarioStore.SidePaneTab) -> CGFloat {
        tab == .formula ? formulaWidth : width
    }

    static func minimumWidth(for tab: ScenarioStore.SidePaneTab) -> CGFloat {
        tab == .formula ? minimumFormulaWidth : minimumWidth
    }

    /// A width kept between the tab's minimum and what leaves the timeline room in `area`.
    static func clamped(_ width: CGFloat, for tab: ScenarioStore.SidePaneTab, area: CGFloat) -> CGFloat {
        let low = minimumWidth(for: tab)
        let high = max(low, area - PanelView.paneGap - timelineRoom)
        guard width.isFinite else { return min(max(Self.width(for: tab), low), high) }
        return min(max(width, low), high)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SidePaneContent(store: store)
        }
        .padding(16)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .overlay(alignment: side == .right ? .leading : .trailing) { resizeEdge }
    }

    /// A strip along the edge that faces the timeline, half in the gap beside it: dragging it
    /// changes the pane's width, and double-clicking puts the width back.
    private var resizeEdge: some View {
        Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .offset(x: side == .right ? -5 : 5)
            .resizePointer()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(PanelView.panelSpace))
                    .onChanged { onResize($0.translation.width) }
                    .onEnded { _ in onResize(nil) })
            .simultaneousGesture(TapGesture(count: 2).onEnded(onResetWidth))
            .help("Drag to change the pane's width. Double-click to put it back.")
            .accessibilityHidden(true)
    }

    /// The pane's title bar: the tabs, and a drag handle for docking it on the other side.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .help("Drag to dock on the other side")
            SidePaneTabs(store: store)
            Spacer()
            Button(action: onMoveToOtherSide) {
                Image(systemName: side == .left ? "arrow.right.to.line" : "arrow.left.to.line")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move to the \(side.other.rawValue) side")
            .accessibilityLabel("Move the side pane to the \(side.other.rawValue) side")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(PanelView.bodySpace))
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}

/// The side pane's tabs: Event, Slot and Formula.
struct SidePaneTabs: View {
    @Bindable var store: ScenarioStore

    var body: some View {
        HStack(spacing: 2) {
            tab(.event, "Event", help: "Add an event  E")
            tab(.slot, "Slot", help: "The focused slot's model and values  ⌘I")
            tab(.formula, "Formula", help: "Edit the focused slot's formula  ⌥⌘I")
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tab(_ tab: ScenarioStore.SidePaneTab, _ title: String, help: String) -> some View {
        let selected = store.sidePane == tab
        return Button {
            if tab != .slot {
                store.closeRefit()
                store.closePredict()
                store.cancelReadingImport()
            }
            if tab == .formula {
                store.showFormulaEditor()
            } else if store.sidePane != tab {
                store.sidePane = tab
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the side pane shows under its tabs: the selected tab, or Drag the future's ways to get
/// there while a target is set on the focused slot (docs/UI.md, 5.2).
struct SidePaneContent: View {
    let store: ScenarioStore

    var body: some View {
        if let goal = store.goal, goal.slot == store.focused.id {
            GoalCard(store: store, state: goal)
        } else {
            switch store.sidePane {
            case .event: AddEventPane(store: store)
            case .slot: SlotPane(store: store)
            case .formula:
                #if os(macOS)
                FormulaPane(store: store)
                #else
                SlotPane(store: store)
                #endif
            }
        }
    }
}

extension View {
    /// The left-right resize pointer, over an edge that can be dragged.
    @ViewBuilder func resizePointer() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            pointerStyle(.columnResize)
        } else {
            onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
        #else
        self
        #endif
    }
}
