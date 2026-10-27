import SwiftUI

/// The side pane (docs/UI.md, section 3): docked on one side of the timeline, with an Event tab
/// for adding events and a Slot tab for the focused slot's model and values.
struct SidePane: View {
    @Bindable var store: ScenarioStore
    let side: PaneSide
    var onMoveToOtherSide: () -> Void
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: (DragGesture.Value) -> Void

    static let width: CGFloat = 300
    /// The Formula tab is wider, so lines of formula fit.
    static let formulaWidth: CGFloat = 480

    static func width(for tab: ScenarioStore.SidePaneTab) -> CGFloat {
        tab == .formula ? formulaWidth : width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
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
        .padding(16)
        .frame(width: Self.width(for: store.sidePane))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    /// The pane's title bar: the tabs, and a drag handle for docking it on the other side.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .help("Drag to dock on the other side")
            HStack(spacing: 2) {
                tab(.event, "Event", help: "Add an event  E")
                tab(.slot, "Slot", help: "The focused slot's model and values  ⌘I")
                tab(.formula, "Formula", help: "Edit the focused slot's formula  ⌥⌘I")
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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

    private func tab(_ tab: ScenarioStore.SidePaneTab, _ title: String, help: String) -> some View {
        let selected = store.sidePane == tab
        return Button {
            if tab != .slot {
                store.closeRefit()
                store.closePredict()
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
