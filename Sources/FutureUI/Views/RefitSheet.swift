import SwiftUI
import FutureKit

/// Refit, in the side pane over the Slot tab (docs/UI.md, 5.11): which values may change, which
/// readings count, what the fit found, and Apply. The graph shows the fitted line dashed.
struct RefitSheet: View {
    @Bindable var store: ScenarioStore
    let slot: ScenarioStore.SlotInfo
    let state: RefitState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Refit \(slot.title)").futureFont(15, weight: .semibold)
                Text("Fits values to \(slot.title)'s readings. Nothing changes until you apply them.")
                    .futureFont(11).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("What may change") {
                ForEach(state.choices) { choice in
                    Toggle(isOn: Binding(get: { choice.ticked },
                                         set: { store.setRefitChoice(choice.name, ticked: $0) })) {
                        HStack(spacing: 6) {
                            Text(choice.label).futureFont(13).lineLimit(1).help(choice.help)
                            Spacer(minLength: 4)
                            Text(choice.current).futureFont(12).monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                    }
                    .accessibilityLabel("Fit \(choice.label)")
                }
                if state.noneMarked {
                    Text("Tick the values to fit.").futureFont(11).foregroundStyle(Theme.secondary)
                }
            }
            section("Which readings") {
                Picker("Which readings", selection: Binding(get: { state.window }, set: { store.setRefitWindow($0) })) {
                    ForEach(RefitState.Window.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            result
            HStack {
                Button("Cancel") { store.closeRefit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { store.applyRefit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.applicable == nil)
                    .help(state.applicable == nil ? "Nothing to apply" : "Make these \(slot.title)'s own values  ⌘↩")
            }
            .controlSize(.small)
        }
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .fitting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fitting…").futureFont(12).foregroundStyle(Theme.secondary)
                }
            case .nothingTicked:
                Text("Tick at least one value to fit.").futureFont(12).foregroundStyle(Theme.secondary)
            case .failed(let message):
                Text(message).futureFont(12).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            case .fitted(let found):
                if found.improved {
                    ForEach(found.changes) { change in
                        HStack(spacing: 6) {
                            Text(change.label).futureFont(13).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(change.from).foregroundStyle(Theme.secondary)
                            Image(systemName: "arrow.right").futureFont(9, weight: .semibold).foregroundStyle(Theme.secondary)
                            Text(change.to).foregroundStyle(Theme.proposal)
                        }
                        .futureFont(12)
                        .monospacedDigit()
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text("These values already fit best.").futureFont(12)
                }
                Text(found.summary).futureFont(11).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).futureFont(11).foregroundStyle(Theme.secondary)
            content()
        }
    }
}
