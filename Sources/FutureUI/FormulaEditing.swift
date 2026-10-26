import Foundation
import FutureEngine
import FutureFormula

/// What's wrong with a formula being edited (docs/UI.md, 5.7).
public struct FormulaCheck: Sendable, Equatable {
    /// The text that was checked.
    public let text: String
    /// Mistakes in the formula first, then problems with how it reads other slots, then slots it
    /// would stop from running.
    public let diagnoses: [FormulaDiagnosis]
    /// Whether the formula language accepts it. Only then can it be applied.
    public let compiles: Bool
    /// Whether the slot would run with it, rather than pause.
    public let runs: Bool


}

/// The formula editor's side of the store: drafts, checks, the dashed preview, and applying.
/// A draft is kept per slot until it's applied or reverted, so switching tabs or slots loses nothing.
extension ScenarioStore {
    /// How long after the last keystroke a formula is checked and previewed.
    public static let formulaCheckDelay: Duration = .milliseconds(300)

    /// The text the editor shows: the draft, or the slot's formula.
    public func formulaText(forSlotAt index: Int) -> String {
        guard isSlot(index) else { return "" }
        return formulaDrafts[configs[index].id] ?? configs[index].formula
    }

    /// Whether the slot has edits that aren't applied yet.
    public func hasFormulaDraft(forSlotAt index: Int) -> Bool {
        guard isSlot(index) else { return false }
        return formulaDrafts[configs[index].id] != nil
    }

    /// Opens the Formula tab for a slot (the focused one by default).
    public func showFormulaEditor(forSlotAt index: Int? = nil) {
        if let index { focus(index: index) }
        if sidePane != .formula { sidePane = .formula }
        updateFormulaCheck(forSlotAt: focusedIndex)
    }

    /// Records what's typed. The check and preview follow once typing pauses.
    public func editFormula(_ text: String, forSlotAt index: Int) {
        guard isSlot(index) else { return }
        let id = configs[index].id
        let draft: String? = text == configs[index].formula ? nil : text
        if formulaDrafts[id] != draft { formulaDrafts[id] = draft }
        formulaCheckTask?.cancel()
        formulaCheckTask = Task { [weak self] in
            try? await Task.sleep(for: Self.formulaCheckDelay)
            guard !Task.isCancelled, let self, let index = self.slotIndex(id: id) else { return }
            self.updateFormulaCheck(forSlotAt: index)
        }
    }

    /// Checks the slot's draft (or formula) now and previews it. Typing does this after a pause.
    public func updateFormulaCheck(forSlotAt index: Int) {
        guard isSlot(index) else { return }
        let id = configs[index].id
        let text = formulaText(forSlotAt: index)
        let check = checkFormula(text, forSlotAt: index)
        if formulaChecks[id] != check { formulaChecks[id] = check }
        previewFormula(text, forSlotAt: index, check: check)
    }

    /// Makes a fix's change to the formula, and checks it straight away.
    public func useFormulaFix(_ fix: FormulaFix, forSlotAt index: Int) {
        editFormula(fix.source, forSlotAt: index)
        formulaCheckTask?.cancel()
        updateFormulaCheck(forSlotAt: index)
    }

    /// Puts the slot's own formula back and drops the draft.
    public func revertFormula(forSlotAt index: Int) {
        guard isSlot(index) else { return }
        let id = configs[index].id
        formulaCheckTask?.cancel()
        if formulaDrafts[id] != nil { formulaDrafts[id] = nil }
        if previewSlot == id { clearSlotPreview() }
        updateFormulaCheck(forSlotAt: index)
    }

    /// Makes the draft the slot's formula (undoable). Refused while the formula has mistakes.
    @discardableResult
    public func applyFormula(forSlotAt index: Int) -> Bool {
        guard isSlot(index), let draft = formulaDrafts[configs[index].id] else { return false }
        let model: FormulaModel
        do {
            model = try FormulaModel(draft, name: configs[index].name)
        } catch {
            updateFormulaCheck(forSlotAt: index)
            say("Fix the formula's mistakes first.", isError: true)
            return false
        }
        var config = configs[index]
        config.formula = draft
        let outputs = model.descriptor.variables.filter { $0.causality == .output }.map(\.name)
        if !outputs.contains(config.variable) { config.variable = outputs.first ?? model.parameterNames.first ?? config.variable }
        let declared = Set(model.parameterNames + model.startingValueNames)
        config.values = config.values.filter { declared.contains($0.key) }
        if config.model != "Custom formula" && !config.model.hasSuffix(" (edited)") { config.model += " (edited)" }
        formulaCheckTask?.cancel()
        formulaDrafts[config.id] = nil
        if previewSlot == config.id { clearSlotPreview() }
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        updateFormulaCheck(forSlotAt: index)
        say("Applied the new formula to \(slots[index].title)")
        return true
    }

    // MARK: Checking

    /// The formula's mistakes, how it reads other slots, and slots it would stop from running.
    public func checkFormula(_ text: String, forSlotAt index: Int) -> FormulaCheck {
        guard isSlot(index) else { return FormulaCheck(text: text, diagnoses: [], compiles: true, runs: true) }
        let config = configs[index]
        let model: FormulaModel
        do {
            model = try FormulaModel(text, name: config.name, values: config.values)
        } catch let error as FormulaError {
            return FormulaCheck(text: text, diagnoses: [FormulaDiagnoser.diagnose(error, in: text)], compiles: false, runs: false)
        } catch {
            return FormulaCheck(text: text, diagnoses: [FormulaDiagnosis(severity: .error, title: String(describing: error))],
                                compiles: false, runs: false)
        }

        var list = configs.indices.map { (name: configs[$0].name, descriptor: descriptors.indices.contains($0) ? descriptors[$0] : nil) }
        let before = Wiring.check(list)
        list[index].descriptor = model.descriptor
        let after = Wiring.check(list)

        var diagnoses: [FormulaDiagnosis] = []
        if let problem = after.problems[index] {
            diagnoses.append(diagnose(problem, in: text, slotAt: index))
        }
        // Slots that read this one and would stop running.
        for (other, problem) in after.problems.sorted(by: { $0.key < $1.key }) where other != index && before.problems[other] == nil {
            diagnoses.append(FormulaDiagnosis(
                severity: .warning, title: "\(slots[other].title) would pause",
                detail: problem.description.replacingOccurrences(of: "Reads ", with: "It reads ", options: .anchored)))
        }
        return FormulaCheck(text: text, diagnoses: diagnoses, compiles: true, runs: after.problems[index] == nil)
    }

    /// Explains a problem with how the slot reads others, with a fix where there's an obvious one.
    private func diagnose(_ problem: SlotProblem, in text: String, slotAt index: Int) -> FormulaDiagnosis {
        let others = configs.indices.filter { $0 != index }
        func descriptor(named name: String) -> ModelDescriptor? {
            guard let other = configs.firstIndex(where: { $0.name == name }), descriptors.indices.contains(other) else { return nil }
            return descriptors[other]
        }
        func fixReferences(from old: String, to new: String, title: String) -> FormulaFix {
            let tokens = FormulaDiagnoser.references(toSlot: old.components(separatedBy: ".")[0], in: text)
                .filter { $0.text == old || $0.text.hasPrefix(old + ".") }
            var source = text
            for token in tokens.sorted(by: { $0.range.location > $1.range.location }) {
                source = FormulaDiagnoser.replacing([NSRange(location: token.range.location, length: (old as NSString).length)],
                                                    with: new, in: source)
            }
            return FormulaFix(title: title, source: source)
        }
        func firstReference(to slot: String) -> NSRange? {
            FormulaDiagnoser.references(toSlot: slot, in: text).first?.range
        }

        switch problem {
        case .missingSlot(let slot, let reading):
            var fixes: [FormulaFix] = []
            if let better = FormulaDiagnoser.closest(to: slot, in: others.map { configs[$0].name }) {
                fixes.append(fixReferences(from: slot, to: better, title: "Use \(better)"))
            }
            return FormulaDiagnosis(severity: .warning, title: "There's no slot called \(slot)",
                                    detail: "It reads \(reading), so it would pause.", range: firstReference(to: slot), fixes: fixes)
        case .missingValue(let slot, let variable):
            let readable = descriptor(named: slot)?.readable.map(\.name) ?? []
            var fixes: [FormulaFix] = []
            if let better = FormulaDiagnoser.closest(to: variable, in: readable) {
                fixes.append(fixReferences(from: "\(slot).\(variable)", to: "\(slot).\(better)", title: "Use \(slot).\(better)"))
            }
            return FormulaDiagnosis(severity: .warning, title: "\(slot) has no value called \(variable)",
                                    detail: readable.isEmpty ? nil : "Its values: \(readable.joined(separator: ", ")).",
                                    range: firstReference(to: slot), fixes: fixes)
        case .missingEvents(let slot, let kind):
            let emits = descriptor(named: slot)?.emits ?? []
            var fixes: [FormulaFix] = []
            if let better = FormulaDiagnoser.closest(to: kind, in: emits) {
                fixes.append(fixReferences(from: "\(slot).\(kind)", to: "\(slot).\(better)", title: "Use \(slot).\(better)"))
            }
            return FormulaDiagnosis(severity: .warning, title: "\(slot) never sends \(kind)",
                                    detail: emits.isEmpty ? "\(slot) sends no events." : "It sends \(emits.joined(separator: ", ")).",
                                    range: firstReference(to: slot), fixes: fixes)
        case .loop(let names):
            // Read the next slot in the loop from the previous step.
            let own = configs[index].name
            let position = names.firstIndex(of: own) ?? 0
            let next = names.indices.contains(position + 1) ? names[position + 1] : names.first ?? own
            let references = FormulaDiagnoser.references(toSlot: next, in: text)
                .filter { !text.utf16.dropFirst(NSMaxRange($0.range)).starts(with: "[".utf16) }
            var fixes: [FormulaFix] = []
            if let reference = references.first {
                let source = references.sorted { $0.range.location > $1.range.location }
                    .reduce(text) { FormulaDiagnoser.inserting("[t-1]", at: NSMaxRange($1.range), in: $0) }
                fixes.append(FormulaFix(title: "Use \(reference.text)[t-1]", source: source))
            }
            return FormulaDiagnosis(severity: .warning, title: "\(displayName(own)) and \(displayName(next)) depend on each other within the same step",
                                    detail: "\(names.joined(separator: " → ")). Read one of them from the previous step, so each step can finish.",
                                    range: references.first?.range, fixes: fixes)
        case .readsItself(let reading):
            return FormulaDiagnosis(severity: .warning, title: "It reads its own value as \(reading)",
                                    detail: "Use the value's own name, with [t-1] for the previous step.",
                                    range: firstReference(to: configs[index].name))
        case .waitsFor(let slot):
            return FormulaDiagnosis(severity: .warning, title: "\(displayName(slot)) is paused",
                                    detail: "This slot reads from it, so it would pause too.", range: firstReference(to: slot))
        case .model(let message):
            return FormulaDiagnosis(severity: .error, title: message)
        }
    }

    // MARK: Preview

    /// Shows the slot's line with the draft, dashed, when it can run.
    private func previewFormula(_ text: String, forSlotAt index: Int, check: FormulaCheck) {
        let config = configs[index]
        guard formulaDrafts[config.id] != nil, check.runs,
              let model = try? FormulaModel(text, name: config.name, values: config.values) else {
            if previewSlot == config.id { clearSlotPreview() }
            return
        }
        let outputs = model.descriptor.variables.filter { $0.causality == .output }.map(\.name)
        let variable = outputs.contains(config.variable) ? config.variable : outputs.first ?? config.variable
        previewSlot = config.id
        parameterPreviewSequence += 1
        let margin: TimeInterval = 62 * 86_400
        let setup = ScenarioEngine.SlotSetup(name: config.name, variable: variable, model: model, key: "preview")
        requestPreview(ScenarioEngine.PreviewRequest(
            version: revision, sequence: parameterPreviewSequence, slot: index, change: .model(setup),
            from: max(start, frame.start.addingTimeInterval(-margin)), through: frame.end.addingTimeInterval(margin)))
    }

    /// Stops showing a slider's or formula's dashed preview.
    func clearSlotPreview() {
        previewSlot = nil
        parameterPreviewSequence += 1
        if !parameterPreview.isEmpty { parameterPreview = [] }
    }

    // MARK: The insert palette and completion

    /// The other slots, for completion and the insert palette: their formula names, readable
    /// values with labels, and the events they send.
    public func formulaSlotSummaries(excludingSlotAt index: Int) -> [FormulaSlotSummary] {
        configs.indices.filter { $0 != index && slots.indices.contains($0) }.map { other in
            let descriptor = descriptors.indices.contains(other) ? descriptors[other] : nil
            let values = descriptor?.readable.map { (name: $0.name, label: $0.label ?? $0.name) } ?? []
            return FormulaSlotSummary(name: configs[other].name, values: values, events: descriptor?.emits ?? [])
        }
    }
}
