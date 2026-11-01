import SwiftUI

/// Importing readings, in the side pane over the Slot tab (docs/UI.md, 5.10): which columns are
/// the dates and the values, which of the slot's values they're readings of, what they'll be
/// called, and what importing brings.
struct ImportSheet: View {
    @Bindable var store: ScenarioStore
    let slot: ScenarioStore.SlotInfo
    let state: ReadingImportState
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import readings into \(slot.title)").font(.system(size: 15, weight: .semibold))
                Text("From \(state.origin). Readings correct the model up to now, and show on the graph.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("Dates") {
                columnPicker("Dates", selection: Binding(get: { state.dateColumn },
                                                         set: { store.setImportColumns(date: $0, value: state.valueColumn) }))
            }
            section("Values") {
                columnPicker("Values", selection: Binding(get: { state.valueColumn },
                                                          set: { store.setImportColumns(date: state.dateColumn, value: $0) }))
            }
            if state.targets.count > 1 {
                section("Readings of") {
                    Picker("Readings of", selection: Binding(get: { state.variable }, set: { store.setImportVariable($0) })) {
                        ForEach(state.targets) { Text($0.label).tag($0.name) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            section("Called") {
                TextField("Statements", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { store.setImportTitle(title) }
                    .onChange(of: title) { store.setImportTitle(title) }
                    .accessibilityLabel("What the readings are called")
            }
            preview
            HStack {
                Button("Cancel") { store.cancelReadingImport() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") { store.applyReadingImport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!state.canImport)
                    .help(state.canImport ? "Add these readings to \(slot.title)  ⌘↩" : "Nothing to import")
            }
            .controlSize(.small)
        }
        .padding(.trailing, 4)
        .onAppear { title = state.title }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = state.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            } else if let preview = state.preview {
                Text(preview.summary).font(.system(size: 12)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                if let notes = preview.notes {
                    Text(notes).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                Text(preview.destination).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A menu of the table's columns, by name.
    private func columnPicker(_ label: String, selection: Binding<Int?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose a column").tag(Int?.none)
            ForEach(Array(state.columns.enumerated()), id: \.offset) { index, name in
                Text(name).tag(Int?.some(index))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
        }
    }
}
