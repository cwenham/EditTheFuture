import SwiftUI

/// Which side of the panel the add-event pane is docked on.
public enum PaneSide: String, Sendable {
    case left, right

    var other: PaneSide { self == .left ? .right : .left }
}

/// The side pane's Event tab (docs/UI.md, 5.3): always visible, docked on one side, so the
/// timeline can be scrolled freely to watch the draft's effect play out. Clicking an event's
/// diamond loads it here to be changed or deleted (5.4).
struct AddEventPane: View {
    @Bindable var store: ScenarioStore

    @FocusState private var focusedField: Field?
    enum Field { case amount, value }

    private var draft: EventDraft { store.eventDraft }
    private var slot: ScenarioStore.SlotInfo {
        store.slots.indices.contains(draft.slotIndex) ? store.slots[draft.slotIndex] : store.focused
    }
    private var isSetParameter: Bool { draft.kind == .setParameter }
    private var isEditing: Bool { store.editingEvent != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(slot.color).frame(width: 9, height: 9)
                Text(slot.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if isEditing {
                    Text("Editing an event")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.proposal)
                } else {
                    Text("1–8 or click a lane to change")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }

            if kindOptions.count > 1 {
                Picker("Kind", selection: $store.eventDraft.kind) {
                    ForEach(kindOptions, id: \.kind) { Text($0.title).tag($0.kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if isSetParameter {
                field("Parameter") {
                    Picker("Parameter", selection: $store.eventDraft.parameter) {
                        ForEach(parameterOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                field("New value") {
                    TextField(currentValueHint, text: $store.eventDraft.valueText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .value)
                        .onSubmit { store.commitEvent() }
                }
            } else {
                field("Amount") {
                    TextField("e.g. 500 or 1.2k", text: $store.eventDraft.amountText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .amount)
                        .onSubmit { store.commitEvent() }
                }
                field("Repeats") {
                    Picker("Repeats", selection: $store.eventDraft.repeats) {
                        ForEach(EventDraft.Repeat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            field(isSetParameter || draft.repeats == .never ? "When" : "Starting") {
                HStack(spacing: 8) {
                    DatePicker("When", selection: $store.eventDraft.date, in: store.start...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                    Button("Now") { store.resetEventDate() }
                        .disabled(store.eventDateIsNow)
                }
                Text(dateHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }

            EffectBox(store: store, isSetParameter: isSetParameter)

            if let error = store.draftError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.error)
            }

            if store.confirmingEventDeletion {
                deletionQuestion
            } else if isEditing {
                HStack {
                    Button("Delete…") { store.requestEventDeletion() }
                        .foregroundStyle(Theme.error)
                        .help("Delete this event")
                    Spacer()
                    Button("Cancel") { store.stopEditingEvent() }
                        .keyboardShortcut(.cancelAction)
                        .help("Leave the event as it was  Esc")
                    saveButton("Save")
                }
            } else {
                HStack {
                    Button("Clear") { store.clearEvent() }
                    Spacer()
                    saveButton("Add event")
                }
            }

            Spacer(minLength: 0)

            Text("Or type +500 monthly in the command bar")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Switching from the Slot tab to set a date or a parameter: the request came before this appeared.
            if store.focusEventFieldOnAppear {
                store.focusEventFieldOnAppear = false
                focusedField = isSetParameter ? .value : .amount
            }
        }
        .onChange(of: store.eventFieldFocusRequest) {
            focusedField = isSetParameter ? .value : .amount
        }
    }

    private func saveButton(_ title: String) -> some View {
        Button(title) { store.commitEvent() }
            .buttonStyle(.borderedProminent)
            .tint(Theme.proposal.opacity(0.85))
            .foregroundStyle(Color(hex: "#14161B"))
    }

    /// Asked before the event being edited is deleted (docs/DESIGN.md, 13).
    private var deletionQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.eventDeletionQuestion)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { store.cancelEventDeletion() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete", role: .destructive) { store.deleteEditedEvent() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Theme.error.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.error.opacity(0.4)))
    }

    private var dateHint: String {
        if isEditing { return "Click the graph to move it" }
        return store.eventDateIsNow ? "Click the graph to pick another date" : "Picked on the graph · Now resets it"
    }

    /// "Now 0.045", from the latest results, or an example until they arrive.
    private var currentValueHint: String {
        store.currentValue(ofParameter: draft.parameter).map { "Now " + String(format: "%g", $0) } ?? "e.g. 4% or 650"
    }

    private struct KindOption {
        let kind: EventDraft.Kind
        let title: String
    }

    private var kindOptions: [KindOption] {
        var kinds = slot.eventKinds
        // An event being edited keeps its kind, even one the slot's model no longer handles (or a paused slot's).
        if case .event(let kind) = draft.kind, !kinds.contains(kind) { kinds.append(kind) }
        var options = kinds.map { KindOption(kind: .event($0), title: EventDraft.title(forKind: $0)) }
        if !slot.parameters.isEmpty || isSetParameter { options.append(KindOption(kind: .setParameter, title: "Set parameter")) }
        return options
    }

    /// The slot's parameters, and the edited event's own when the slot no longer has it.
    private var parameterOptions: [String] {
        guard !draft.parameter.isEmpty, !slot.parameters.contains(draft.parameter) else { return slot.parameters }
        return slot.parameters + [draft.parameter]
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The draft's effect at the cursor and at the right edge. It's the only part of the pane that
/// follows the pointer, so it reads the store on its own.
struct EffectBox: View {
    let store: ScenarioStore
    let isSetParameter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if let preview = store.eventPreview() {
                row("At cursor · \(preview.cursorDate)", preview.atCursor)
                row("At right edge · \(preview.edgeDate)", preview.atEdge)
                Text("Scroll the timeline to watch it play out")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            } else if store.draftIsComplete {
                Text("Working out the effect…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(isSetParameter ? "Enter a value to see its effect over time" : "Enter an amount to see its effect over time")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.proposal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.proposal)
        }
    }
}

/// The two places the pane can be dropped while it's being dragged.
struct DockZones: View {
    let highlighted: PaneSide
    let width: CGFloat

    var body: some View {
        HStack {
            zone(.left)
            Spacer()
            zone(.right)
        }
        .allowsHitTesting(false)
    }

    private func zone(_ side: PaneSide) -> some View {
        let active = side == highlighted
        return RoundedRectangle(cornerRadius: 12)
            .fill(Theme.proposal.opacity(active ? 0.16 : 0.04))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.proposal.opacity(active ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay(Text("Dock \(side.rawValue)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.proposal))
            .frame(width: width)
    }
}
