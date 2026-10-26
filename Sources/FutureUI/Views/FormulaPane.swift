#if os(macOS)
import SwiftUI
import FutureFormula

/// The side pane's Formula tab (docs/UI.md, 5.7): the focused slot's formula, checked as you
/// type, with fixes for its mistakes and a palette of functions and other slots' values.
struct FormulaPane: View {
    @Bindable var store: ScenarioStore
    @State private var insertRequest: FormulaInsertRequest?
    @State private var insertCount = 0

    var body: some View {
        let slot = store.focused
        let index = store.focusedIndex
        let text = store.formulaText(forSlotAt: index)
        let check = store.formulaChecks[slot.id]
        // A check of earlier text says nothing about this text yet.
        let current = check?.text == text ? check : nil
        let drafted = store.hasFormulaDraft(forSlotAt: index)
        let summaries = store.formulaSlotSummaries(excludingSlotAt: index)
        let titles = Dictionary(uniqueKeysWithValues: store.slots.map { ($0.name, ($0.title, $0.color, $0.key)) })

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(slot.color).frame(width: 10, height: 10)
                Text(slot.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(slot.summary).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if drafted {
                    Text("Not applied")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.proposal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.proposal.opacity(0.5)))
                }
            }

            FormulaEditor(
                text: text, diagnosedText: check?.text, diagnoses: check?.diagnoses ?? [],
                completions: { source, cursor in FormulaCompleter.complete(source, at: cursor, slots: summaries, ownName: slot.name) },
                insertRequest: insertRequest,
                onChange: { new in act(slot.id) { store.editFormula(new, forSlotAt: $0) } },
                onApply: { act(slot.id) { store.applyFormula(forSlotAt: $0) } })
                .id(slot.id)
                .frame(minHeight: 160, maxHeight: .infinity)

            problems(current, slot: slot, drafted: drafted)

            HStack {
                Button("Revert") { act(slot.id) { store.revertFormula(forSlotAt: $0) } }
                    .disabled(!drafted)
                    .help("Put back the slot's formula")
                Spacer()
                Button("Apply") { act(slot.id) { store.applyFormula(forSlotAt: $0) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.proposal.opacity(0.85))
                    .foregroundStyle(Color(hex: "#14161B"))
                    .disabled(!drafted || current?.compiles == false)
                    .help("Use this formula (Command-Return). Undo puts the old one back.")
            }
            .controlSize(.small)

            InsertPalette(text: text, slots: summaries, titles: titles) { insertText, caretBack in
                insertCount += 1
                insertRequest = FormulaInsertRequest(id: insertCount, text: insertText, caretBack: caretBack)
            }
            .frame(height: 200)
        }
        .onAppear { store.updateFormulaCheck(forSlotAt: index) }
        .onChange(of: slot.id) { act(slot.id) { store.updateFormulaCheck(forSlotAt: $0) } }
    }

    /// Runs an action on the slot wherever it is now (never an index kept from an earlier drawing).
    private func act(_ id: UUID, _ action: (Int) -> Void) {
        if let index = store.slotIndex(id: id) { action(index) }
    }

    @ViewBuilder
    private func problems(_ check: FormulaCheck?, slot: ScenarioStore.SlotInfo, drafted: Bool) -> some View {
        let diagnoses = check?.diagnoses ?? []
        if diagnoses.isEmpty {
            Text(drafted
                 ? (check?.compiles == true ? "No mistakes. The dashed line shows the new formula; ⌘↩ applies it." : "Checking…")
                 : "Type to change the formula. The graph previews it as you go, and nothing changes until you apply it.")
                .font(.system(size: 11))
                .foregroundStyle(drafted && check?.compiles == true ? Theme.success : Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(diagnoses.prefix(3).enumerated()), id: \.offset) { _, diagnosis in
                    ProblemBox(diagnosis: diagnosis) { fix in act(slot.id) { store.useFormulaFix(fix, forSlotAt: $0) } }
                }
                if diagnoses.count > 3 {
                    Text("And \(diagnoses.count - 3) more").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// One mistake or warning, with buttons for its fixes.
private struct ProblemBox: View {
    let diagnosis: FormulaDiagnosis
    let useFix: (FormulaFix) -> Void

    var body: some View {
        let isError = diagnosis.severity == .error
        let tint = isError ? Theme.error : Theme.warning
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnosis.title).font(.system(size: 12, weight: .semibold))
                    if let detail = diagnosis.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let line = diagnosis.line {
                    Text("Line \(line)").font(.system(size: 11)).monospacedDigit().foregroundStyle(tint)
                }
            }
            if !diagnosis.fixes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(diagnosis.fixes.enumerated()), id: \.offset) { offset, fix in
                        Button(fix.title) { useFix(fix) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help("Change the formula: \(fix.title)")
                    }
                }
                .padding(.leading, 21)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

/// Functions, values, and other slots' values, each a click away from the caret.
private struct InsertPalette: View {
    let text: String
    let slots: [FormulaSlotSummary]
    let titles: [String: (title: String, color: Color, key: Int)]
    let insert: (String, Int) -> Void

    var body: some View {
        let declared = FormulaCompleter.declaredNames(in: text)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Functions") {
                    ForEach(FormulaVocabulary.functions) { entry in
                        chip(entry.name, color: FormulaColors.color(.function), help: "\(entry.usage): \(entry.summary)") {
                            insert(entry.name + "()", 1)
                        }
                    }
                }
                section("Time and constants") {
                    ForEach(FormulaVocabulary.builtins) { entry in
                        chip(entry.name, color: FormulaColors.color(.builtin), help: entry.summary) { insert(entry.name, 0) }
                    }
                }
                if !declared.parameters.isEmpty || !declared.variables.isEmpty {
                    section("This formula") {
                        ForEach(declared.parameters + declared.variables, id: \.self) { name in
                            chip(name, color: FormulaColors.plain,
                                 help: declared.parameters.contains(name) ? "Parameter" : "Value in this formula") { insert(name, 0) }
                        }
                    }
                }
                ForEach(slots, id: \.name) { slot in
                    let info = titles[slot.name]
                    section(info.map { "\($0.title) · slot \($0.key)" } ?? slot.name, color: info?.color) {
                        ForEach(slot.values, id: \.name) { value in
                            chip(value.name, color: FormulaColors.color(.reference),
                                 help: "\(slot.name).\(value.name): \(value.label). Same step; add [t-1] for the step before.") {
                                insert("\(slot.name).\(value.name)", 0)
                            }
                        }
                        ForEach(slot.events, id: \.self) { event in
                            chip(event, color: FormulaColors.color(.keyword), help: "An event \(slot.name) sends. Use it in on \(slot.name).\(event): …") {
                                insert("\(slot.name).\(event)", 0)
                            }
                        }
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .accessibilityLabel("Insert")
    }

    private func section<Content: View>(_ title: String, color: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            FlowLayout(spacing: 4) { content() }
        }
    }

    private func chip(_ label: String, color: NSColor, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Insert \(label)")
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
