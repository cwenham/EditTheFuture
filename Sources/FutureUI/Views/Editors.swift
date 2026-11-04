import SwiftUI
import FutureKit

// The panes for editing a scenario, for any app that embeds them (docs/DESIGN.md, 2.1). Each fills
// the frame it's given, down to its minimum width, and brings its own popovers and sheets. They draw
// in the current `FutureStyle`, on its panel colour.

/// The side pane's tabs and what they show: Event, Slot and Formula, or Drag the future's ways to
/// get there while a target is set (docs/UI.md, 3 and 5.2). It follows the graph: clicking a date
/// on a `ScenarioGraph` opens its Event tab there.
public struct ScenarioEditor: View {
    let store: ScenarioStore

    /// The narrowest it works at, at the standard text size. The Formula tab wants `FormulaEditorPane.minimumWidth`.
    public static let minimumWidth = SidePane.minimumWidth

    public init(store: ScenarioStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SidePaneTabs(store: store)
                Spacer()
            }
            SidePaneContent(store: store)
        }
        .modifier(EditorChrome(minimumWidth: Self.minimumWidth))
    }
}

/// Adding and changing events on the focused slot: deposits, withdrawals and parameter changes,
/// once or repeating, with a preview of their effect (docs/UI.md, 5.3 and 5.4).
public struct EventEditor: View {
    let store: ScenarioStore

    public static let minimumWidth = SidePane.minimumWidth

    public init(store: ScenarioStore) {
        self.store = store
    }

    public var body: some View {
        AddEventPane(store: store)
            .modifier(EditorChrome(minimumWidth: Self.minimumWidth))
    }
}

/// The focused slot's model, values, currency, backdrop and readings, with Refit and Predict with
/// (docs/UI.md, 5.7, 5.10 and 5.11).
public struct SlotEditor: View {
    let store: ScenarioStore

    public static let minimumWidth = SidePane.minimumWidth

    public init(store: ScenarioStore) {
        self.store = store
    }

    public var body: some View {
        SlotPane(store: store)
            .modifier(EditorChrome(minimumWidth: Self.minimumWidth))
    }
}

#if os(macOS)
/// The focused slot's formula or script, checked as it's typed, with fixes, a palette and a preview
/// on the graph (docs/UI.md, 5.7). Mac only for now: the editor is an `NSTextView`.
public struct FormulaEditorPane: View {
    let store: ScenarioStore

    public static let minimumWidth = SidePane.minimumFormulaWidth

    public init(store: ScenarioStore) {
        self.store = store
    }

    public var body: some View {
        FormulaPane(store: store)
            .modifier(EditorChrome(minimumWidth: Self.minimumWidth))
            // Outside the side pane, nothing else asks for the focused slot's formula to be checked.
            .onAppear { store.formulaEditorsShown += 1 }
            .onDisappear { store.formulaEditorsShown -= 1 }
            .onChange(of: store.focused.id, initial: true) { store.updateFormulaCheck(forSlotAt: store.focusedIndex) }
    }
}
#endif

/// What the panes have in the panel around them: its padding, colours and appearance, from the style.
struct EditorChrome: ViewModifier {
    let minimumWidth: CGFloat
    @Environment(\.futureStyle.panePadding) private var padding
    @Environment(\.futureStyle.fonts) private var fonts

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(minWidth: fonts.scaled(minimumWidth), maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Theme.text)
            .background(Theme.panel)
            .futureAppearance()
    }
}
