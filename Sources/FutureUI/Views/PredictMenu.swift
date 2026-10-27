import SwiftUI
import FutureEngine

/// Predict with (docs/UI.md, 5.11): the models that could make the slot's projection, each fitted
/// to its readings and scored on readings it didn't see. Hovering a model, or moving to it with ↑
/// and ↓, shows its fitted line dashed and its held-back test dotted; ↩ or a click chooses it.
struct PredictMenu: View {
    let store: ScenarioStore
    let state: PredictState

    @FocusState private var focused: Bool

    static let size = CGSize(width: 700, height: 460)

    private var title: String {
        store.slotIndex(id: state.slot).map { store.slots[$0].title } ?? "the slot"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 340)
                Divider()
                card.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .presentationBackground(Theme.panel)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) {
            store.movePredictSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            store.movePredictSelection(by: 1)
            return .handled
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Predict \(title) with").font(.system(size: 15, weight: .semibold))
            Spacer()
            Picker("Which readings", selection: Binding(get: { state.window }, set: { store.setPredictWindow($0) })) {
                ForEach(ReadingsWindow.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which readings the models are fitted to and compared on")
            Button("Use the best") { store.usePredictBest() }
                .disabled(state.best == nil)
                .help(state.best == nil ? "Waiting for every score" : "Choose the model tagged Best")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var groups: [(title: String, rows: [PredictState.Row])] {
        var result: [(title: String, rows: [PredictState.Row])] = []
        for row in state.rows {
            if let position = result.firstIndex(where: { $0.title == row.group }) {
                result[position].rows.append(row)
            } else {
                result.append((row.group, [row]))
            }
        }
        return result
    }

    private var list: some View {
        let best = state.best
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                        ForEach(group.rows) { row in
                            PredictRow(row: row, isBest: row.id == best, isSelected: row.id == state.selection,
                                       waitingText: state.problem == nil ? "…" : "—")
                                .id(row.id)
                                .onHover { inside in if inside { store.selectPredict(row.id) } }
                                .onTapGesture { store.choosePredict(row.id) }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: state.selection) {
                if let selection = state.selection { proxy.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        if let row = state.selectedRow {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 16, weight: .semibold))
                        if row.id == state.best { BestTag() }
                    }
                    Text(row.summary).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch row.phase {
                case .waiting:
                    if let problem = state.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fitting and scoring…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                    }
                case .failed(let message):
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                case .scored(let score):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(score.text.prefix(1).uppercased() + score.text.dropFirst())
                            .font(.system(size: 14, weight: .medium)).monospacedDigit()
                        Text("How far its projections missed \(ValueFormat.number.full(Double(score.compared))) readings they "
                             + "didn't see, made at three cut-offs and the points after them. "
                             + "The dotted line is its projection from \(DateText.monthYear(score.cutoff)).")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !score.fitted.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fitted to every reading").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            ForEach(score.fitted) { value in
                                HStack {
                                    Text(value.label).font(.system(size: 12)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(value.text).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Cancel") { store.closePredict() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(row.isCurrent && row.score?.values.isEmpty != false ? "Keep \(row.name)" : "Use \(row.name)") {
                        store.choosePredict(row.id)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isFailed(row))
                }
                .controlSize(.small)
            }
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hover over a model to see its fitted line and how it did on readings it didn't see.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel") { store.closePredict() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
    }

    private func isFailed(_ row: PredictState.Row) -> Bool {
        if case .failed = row.phase { return true }
        return false
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.isComparing { ProgressView().controlSize(.mini) }
            Text(state.status ?? "Lowest miss wins; within a tenth of it, the model that fits fewer values.")
                .font(.system(size: 11))
                .foregroundStyle(state.problem == nil ? Theme.secondary : Theme.warning)
                .lineLimit(2)
            Spacer()
            Button("Other model…") {
                let id = state.slot
                store.closePredict()
                store.openPicker(.change(slot: id))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.proposal)
            Button("Edit formula…") { store.showFormulaEditor() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.proposal)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

/// One model in the menu: its name and tags, its summary, and its score once it's in.
private struct PredictRow: View {
    let row: PredictState.Row
    let isBest: Bool
    let isSelected: Bool
    let waitingText: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if isBest { BestTag() }
                    if row.isCurrent {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .help("This slot's model now")
                    }
                }
                Text(row.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 6)
            Group {
                switch row.phase {
                case .waiting: Text(waitingText).foregroundStyle(Theme.secondary)
                case .failed: Text("can't compare").foregroundStyle(Theme.secondary)
                case .scored(let score): Text(score.text)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.proposal.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.proposal.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BestTag: View {
    var body: some View {
        Text("Best")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.proposal)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.proposal.opacity(0.6)))
    }
}
