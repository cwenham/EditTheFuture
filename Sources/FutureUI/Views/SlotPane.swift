import SwiftUI
import FutureDocument
import FutureEngine
import FutureFeeds

/// The side pane's Slot tab (docs/UI.md, 5.7): the focused slot's name, model, parameters,
/// starting values and display settings.
struct SlotPane: View {
    @Bindable var store: ScenarioStore

    var body: some View {
        let slot = store.focused
        ScrollView {
            if let refit = store.refit, refit.slot == slot.id {
                RefitSheet(store: store, slot: slot, state: refit)
            } else {
                SlotSettings(store: store, saved: slot)
                    // Fields start afresh for each slot.
                    .id(slot.id)
            }
        }
        .scrollIndicators(.automatic)
    }
}

/// Keeps the slot's id and looks up where it is each time, never an index from an earlier
/// drawing: removing a slot moves the ones after it, and SwiftUI can draw this view once more
/// before its parent has caught up.
private struct SlotSettings: View {
    @Bindable var store: ScenarioStore
    /// The slot as it was when the parent last drew, used only once it's gone.
    let saved: ScenarioStore.SlotInfo

    /// Where the slot is now, or -1 once it's gone; the store ignores an index with no slot.
    private var index: Int { store.slotIndex(id: saved.id) ?? -1 }
    private var slot: ScenarioStore.SlotInfo { store.slotIndex(id: saved.id).map { store.slots[$0] } ?? saved }

    @State private var nameText = ""
    @State private var nameError: String?
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nameRow
            // At the top, so it's in view however far the pane has scrolled.
            if store.pendingRemoval == slot.id { removalQuestion }
            if let reason = slot.pausedReason {
                Label {
                    Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "pause.circle")
                }
                .foregroundStyle(Theme.warning)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            modelRow
            if !slot.parameterValues.isEmpty {
                section("Parameters") {
                    ForEach(slot.parameterValues) { value in
                        ValueRow(store: store, slotID: slot.id, value: value, isParameter: true,
                                 changes: store.scheduledChanges(of: value, inSlotAt: index))
                    }
                }
            }
            if !slot.startingValues.isEmpty {
                section("Starting values · \(DateText.monthYear(store.start))") {
                    ForEach(slot.startingValues) { value in
                        ValueRow(store: store, slotID: slot.id, value: value, isParameter: false, changes: [])
                    }
                }
            }
            ReadingsSection(store: store, slot: slot)
            display
            actions
        }
        .padding(.trailing, 4)
        .onAppear { nameText = slot.title }
        .onChange(of: slot.title) { if !editingName { nameText = slot.title } }
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(slot.key)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                Circle().fill(slot.color).frame(width: 10, height: 10)
                TextField("Name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($editingName)
                    .onSubmit(rename)
                    .accessibilityLabel("Slot name")
            }
            if let nameError {
                Text(nameError).font(.system(size: 11)).foregroundStyle(Theme.error)
            } else if editingName {
                Text("Formulas call it \(formulaName(fromTitle: nameText) ?? "…") · ↩ to rename")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .onChange(of: editingName) {
            if !editingName {
                nameText = slot.title
                nameError = nil
            }
        }
    }

    private func rename() {
        nameError = store.renameSlot(at: index, to: nameText)
        if nameError == nil { editingName = false }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if store.canRefit(slot: slot.id) {
                    // Predict with (docs/UI.md, 5.11): a slot with readings chooses its model by how
                    // well each one predicts them. The pane is narrow, so the kind badge gives way.
                    Text("Predict with").font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize()
                    Button {
                        store.openPredict(slotAt: index)
                    } label: {
                        HStack(spacing: 3) {
                            Text(slot.model).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Compare models by how well each predicts \(slot.title)'s readings")
                    .popover(isPresented: Binding(
                        get: { store.predict?.slot == slot.id },
                        set: { if !$0 { store.closePredict() } }), arrowEdge: .leading) {
                        if let state = store.predict { PredictMenu(store: store, state: state) }
                    }
                } else {
                    Text(slot.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.chipBorder))
                    Text(slot.model).font(.system(size: 13)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Change…") { store.openPicker(.change(slot: slot.id)) }
                    .controlSize(.small)
                    .popover(isPresented: Binding(
                        get: { store.picker == .change(slot: slot.id) },
                        set: { if !$0 { store.closePicker() } }), arrowEdge: .leading) {
                        ModelPicker(store: store, request: .change(slot: slot.id))
                    }
            }
            HStack {
                if let reads = slot.reads {
                    Text(reads).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if store.canRefit(slot: slot.id) {
                    Button("Refit…") { store.openRefit(slotAt: index) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.proposal)
                        .help("Fit \(slot.title)'s values to its readings")
                }
                if slot.kind == .formula || slot.isScript {
                    Button(slot.isScript ? "Edit script…" : "Edit formula…") { store.showFormulaEditor() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.proposal)
                        .help("Open the Formula tab  ⌥⌘I")
                }
            }
        }
    }

    private var display: some View {
        section("Display") {
            VStack(alignment: .leading, spacing: 8) {
                labelled("Graph") {
                    Picker("Graph", selection: Binding(get: { slot.variable },
                                                       set: { store.setDisplayedVariable($0, inSlotAt: index) })) {
                        ForEach(slot.outputs) { Text($0.label).tag($0.name) }
                    }
                    .labelsHidden()
                }
                labelled("Format") {
                    Picker("Format", selection: Binding(get: { slot.format }, set: { store.setFormat($0, inSlotAt: index) })) {
                        Text("Currency").tag(ValueFormat.currency)
                        Text("Temperature").tag(ValueFormat.temperature)
                        Text("Percent").tag(ValueFormat.percent)
                        Text("Number").tag(ValueFormat.number)
                    }
                    .labelsHidden()
                }
                if slot.hasMoney {
                    labelled("Currency") {
                        Picker("Currency", selection: Binding(get: { slot.ownCurrency?.code ?? "" },
                                                              set: { store.setCurrency(Currency(code: $0), inSlotAt: index) })) {
                            Text("Scenario's (\(store.currency.symbol))").tag("")
                            Divider()
                            ForEach(ScenarioStore.currencyChoices(including: [slot.currency]), id: \.code) {
                                Text($0.menuTitle).tag($0.code)
                            }
                        }
                        .labelsHidden()
                        .help("What this slot's money is in. Its own amounts keep their numbers; money it reads from slots in other currencies is converted.")
                    }
                    conversionNote
                }
                labelled("Color") {
                    HStack(spacing: 3) {
                        ForEach(SlotPalette.colors, id: \.self) { hex in
                            swatch(hex, selected: slot.colorHex == hex) {
                                store.setColor(hex, inSlotAt: index)
                            }
                        }
                        if slot.hasOwnColor {
                            Button {
                                store.setColor(nil, inSlotAt: index)
                            } label: {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondary)
                            .help("Use slot \(slot.key)'s own color again")
                            .accessibilityLabel("Reset color")
                        }
                    }
                }
            }
        }
    }

    private func swatch(_ hex: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Theme.text, lineWidth: selected ? 2 : 0).padding(-3))
                .padding(3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var removalQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
                Text(store.removalQuestion(forSlotAt: index))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { store.cancelRemoval() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Remove", role: .destructive) { store.removeSlot(at: index) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(Theme.error.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.error.opacity(0.4)))
    }

    private var actions: some View {
            HStack {
                Button("Duplicate") { store.duplicateSlot(at: index) }
                    .disabled(store.freePositions.isEmpty)
                    .help(store.freePositions.isEmpty ? "All slots are full" : "Copy this slot, with its events, to the next free slot")
                Spacer()
                Button("Remove…") { store.requestRemoval(ofSlotAt: index) }
                    .disabled(!store.canRemoveSlot)
                    .foregroundStyle(store.canRemoveSlot ? Theme.error : Theme.secondary)
                    .help(store.canRemoveSlot ? "Remove this slot and its events" : "A scenario needs at least one slot")
            }
            .controlSize(.small)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    /// What the slot converts, at which rate, and how fetching the rates is going (docs/UI.md, 5.7).
    @ViewBuilder
    private var conversionNote: some View {
        if let note = store.conversionNote(forSlotAt: index) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let status = store.rateStatus
                if status.isFetching {
                    Text("Fetching exchange rates…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                } else if let error = status.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                }
                Button("Exchange rates…") { store.openScenarioForm(.edit) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.proposal)
                    .help("Choose where the scenario's exchange rates come from")
            }
            .padding(.leading, 60)
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// One parameter or starting value: its label, a field to type it, and a slider when the model
/// gives a range. Dragging shows a dashed preview; letting go applies it.
private struct ValueRow: View {
    let store: ScenarioStore
    let slotID: UUID
    let value: SlotValue
    let isParameter: Bool
    let changes: [String]

    @State private var text = ""
    @State private var dragValue: Double?
    @State private var error: String?
    @FocusState private var editing: Bool

    private var shown: Double? { dragValue ?? value.value }
    /// Where the slot is now, or -1 once it's gone (see `SlotSettings`).
    private var slotIndex: Int { store.slotIndex(id: slotID) ?? -1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(value.label).font(.system(size: 13)).lineLimit(1).help(value.name)
                Spacer(minLength: 4)
                if value.isChanged {
                    Button {
                        store.setStartingValue(value.name, to: nil, inSlotAt: slotIndex)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Put back the model's default" + (value.defaultValue.map { " (\(value.text($0)))" } ?? ""))
                    .accessibilityLabel("Reset \(value.label)")
                }
                TextField(value.value == nil ? "From formula" : "", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .foregroundStyle(dragValue == nil ? Theme.text : Theme.proposal)
                    .focused($editing)
                    .onSubmit(commitText)
                    .accessibilityLabel(value.label)
            }
            if let range = value.sliderRange {
                slider(range)
                HStack {
                    Text(value.text(range.lowerBound))
                    Spacer()
                    Text(value.text(range.upperBound))
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            }
            if value.value == nil && !value.isChanged {
                Text("Worked out by the formula as it runs").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            ForEach(changes, id: \.self) { change in
                Text(change).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            if isParameter {
                Button("Change from a date…") { store.beginParameterChange(value.name) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.proposal)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { text = shown.map(value.text) ?? "" }
        .onChange(of: value.value) { if !editing { text = shown.map(value.text) ?? "" } }
        .onChange(of: editing) {
            if !editing {
                text = shown.map(value.text) ?? ""
                error = nil
            }
        }
    }

    @ViewBuilder
    private func slider(_ range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(
            get: { min(max(shown ?? range.lowerBound, range.lowerBound), range.upperBound) },
            set: { new in
                let snapped = value.snapped(new)
                guard snapped != dragValue else { return }
                dragValue = snapped
                text = value.text(snapped)
                store.previewStartingValue(value.name, snapped, inSlotAt: slotIndex)
            })
        let changed: (Bool) -> Void = { began in
            guard !began else { return }
            store.endStartingValuePreview(commit: dragValue != nil && dragValue != value.value)
            dragValue = nil
            text = value.value.map(value.text) ?? ""
        }
        // Not Slider's own step: on the Mac it draws a tick mark per step, and a range of 10,000
        // steps took seconds to draw. The value is snapped to the step instead.
        Slider(value: binding, in: range, onEditingChanged: changed)
            .controlSize(.small)
            .accessibilityLabel(value.label)
    }

    private func commitText() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            text = shown.map(value.text) ?? ""
            return
        }
        guard let parsed = value.parse(typed), parsed.isFinite else {
            error = "“\(typed)” isn't a number. Try 4.5%, $1,200, 1.5k or 21°C."
            return
        }
        error = nil
        store.setStartingValue(value.name, to: parsed, inSlotAt: slotIndex)
        text = value.text(parsed)
    }
}

/// Where the slot's readings come from (docs/UI.md, 5.10): its feeds, each with how many readings
/// it has, how recent they are and when it was checked, and its files and databases.
private struct ReadingsSection: View {
    let store: ScenarioStore
    let slot: ScenarioStore.SlotInfo

    private var index: Int? { store.slotIndex(id: slot.id) }

    var body: some View {
        let sources = index.map { store.readingSources(ofSlotAt: $0) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Readings").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                if sources.contains(where: { $0.feed != nil }) {
                    Button {
                        store.refreshFeeds(slot: slot.id)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Check \(slot.title)'s feeds for new readings now")
                    .accessibilityLabel("Refresh feeds")
                }
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { offset, source in
                if let spec = source.feed {
                    FeedRow(store: store, slot: slot, source: offset, spec: spec)
                } else {
                    Label(Self.describe(source), systemImage: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .help("Edit it in scenario.md")
                }
            }
            if sources.isEmpty {
                Text("Real-world values that correct the model: market prices, rates, debt, climate, disease…")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Add a feed…") { store.openFeedSetup(.add(slot: slot.id)) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.proposal)
                .popover(isPresented: Binding(get: { store.feedSetup == .add(slot: slot.id) },
                                              set: { if !$0 { store.closeFeedSetup() } }), arrowEdge: .leading) {
                    FeedSetup(store: store, request: .add(slot: slot.id))
                }
        }
    }

    static func describe(_ source: ReadingSource) -> String {
        switch source {
        case .inline: return "Readings written in scenario.md"
        case .csvFile(let title, let path): return "\(title) (\(path))"
        case .database(let title, let path, _): return "\(title) (\(path), read through a query)"
        case .feed(let spec): return spec.title
        }
    }
}

/// One feed in the Slot tab.
private struct FeedRow: View {
    let store: ScenarioStore
    let slot: ScenarioStore.SlotInfo
    let source: Int
    let spec: FeedSpec

    private var status: FeedStatus? { store.feedStatuses[FeedKey(slot: slot.id, identity: spec.identity)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Text(spec.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Button("Edit…") { store.openFeedSetup(.edit(slot: slot.id, source: source)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.proposal)
                    .popover(isPresented: Binding(get: { store.feedSetup == .edit(slot: slot.id, source: source) },
                                                  set: { if !$0 { store.closeFeedSetup() } }), arrowEdge: .leading) {
                        FeedSetup(store: store, request: .edit(slot: slot.id, source: source))
                    }
                Button {
                    if let index = store.slotIndex(id: slot.id) { store.removeFeed(at: source, inSlotAt: index) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Remove this feed. Undo brings it back.")
                .accessibilityLabel("Remove \(spec.title)")
            }
            Text(summary).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).help(details)
            statusLine
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "FRED · DGS10 → rate, as a percent". Settings too long for one line are in the tooltip.
    private var summary: String {
        let source = FeedProviders.named(spec.provider)?.name ?? spec.provider
        let short = spec.query.filter { $0.key != "from" && $0.value.count <= 12 && !$0.value.contains("/") }
        let what = short.map(\.value).prefix(2).joined(separator: " · ")
        var text = source + (what.isEmpty ? "" : " · " + what) + " → " + (spec.variable ?? slot.variable)
        if let conversion = spec.conversion { text += conversion == .percent ? ", as a percent" : ", in °C" }
        return text
    }

    private var details: String {
        spec.query.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let status, let error = status.error, !status.isFetching {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
        } else if status?.isFetching == true {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        } else if let status, status.count > 0, let last = status.last {
            let checked = status.checked.map { " · checked " + Self.ago($0) } ?? ""
            Text("\(SlotValue.number(Double(status.count))) readings to \(DateText.monthYear(last))\(checked)")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        } else if status != nil {
            Text("No readings yet").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    /// "just now", "5 min. ago", "yesterday".
    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
