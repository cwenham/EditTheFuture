import Foundation
import FutureEngine

/// Refit's sheet over the Slot tab (docs/UI.md, 5.11): which values may change, which readings
/// count, and what the fit found.
public struct RefitState: Equatable, Sendable {
    /// A value Refit may change, with a box to tick.
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let label: String
        /// The slot's value now, as the Slot tab writes it: "3%".
        public let current: String
        public var ticked: Bool
    }

    /// Which readings count.
    public typealias Window = ReadingsWindow

    /// One value's change: "Growth per month 3% → 1.02%".
    public struct Change: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let label: String
        public let from: String
        public let to: String
    }

    public struct Found: Equatable, Sendable {
        /// The fitted values, by name, as Apply writes them.
        public let values: [String: Double]
        public let changes: [Change]
        public let improved: Bool
        /// "Misses the next reading by 1.8%, was 2.6%."
        public let summary: String
    }

    public enum Phase: Equatable, Sendable {
        case fitting
        case fitted(Found)
        case failed(String)
        case nothingTicked
    }

    public let slot: UUID
    public var choices: [Choice]
    public var window: Window
    public var phase: Phase
    /// The model marks nothing with `fit`, so every box starts unticked.
    public let noneMarked: Bool

    /// What Apply would write, when the fit did better than the slot's own values.
    public var applicable: Found? {
        if case .fitted(let found) = phase, found.improved { return found }
        return nil
    }
}

/// Lets a fit on another thread see that it's no longer wanted.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Refit in the panel (docs/UI.md, 5.11): fits a slot's values to its readings on a copy of the
/// slot, off the main thread and off the engine's (docs/DESIGN.md, 8.4), shows the result dashed,
/// and applies it as the slot's own values.
extension ScenarioStore {
    private enum Answer: Sendable {
        case fitted(FitOutcome)
        case failed(String)
        case cancelled
    }

    /// Whether Refit can run for a slot: one that runs, with readings of one of its values.
    public func canRefit(slot id: UUID) -> Bool {
        refittable.contains(id)
    }

    /// Keeps `refittable` up to date as slots and their readings change.
    func updateRefittable() {
        var ids = Set<UUID>()
        for (index, config) in configs.enumerated() where slots.indices.contains(index) && !slots[index].isPaused {
            let values = Set(slots[index].outputs.map(\.name))
            if config.readings.set.readings.contains(where: { values.contains($0.variable) }) { ids.insert(config.id) }
        }
        if ids != refittable { refittable = ids }
    }

    /// Opens Refit for a slot in the Slot tab, with the values its model marks `fit` ticked, and
    /// starts fitting them to the readings in `window`.
    public func openRefit(slotAt index: Int, window: RefitState.Window = .all) {
        guard isSlot(index) else { return }
        let slot = slots[index], config = configs[index]
        guard canRefit(slot: slot.id) else {
            say(slot.isPaused ? "\(slot.title) is paused, so it can't be refitted."
                : "\(slot.title) has no readings of its values to fit to. Add a feed first.", isError: true)
            return
        }
        guard let model = try? config.makeModel() else { return }
        let withReadings = Set(config.readings.set.readings.map(\.variable))
        let names = (model.parameterNames + model.startingValueNames).filter { !withReadings.contains($0) }
        guard !names.isEmpty else {
            say("\(slot.title) has no parameters or starting values to fit: its readings set them all.", isError: true)
            return
        }
        let marked = Set(names.filter { model.descriptor.variable(named: $0)?.fittable == true })
        let shown = slot.parameterValues + slot.startingValues
        let choices = names.map { name -> RefitState.Choice in
            let value = shown.first { $0.name == name }
            return RefitState.Choice(name: name, label: value?.label ?? name,
                                     current: value?.value.map { value!.text($0) } ?? "from the formula",
                                     ticked: marked.contains(name))
        }
        closeRefit()
        closePredict()
        showSlotSettings(forSlotAt: index)
        cancelRemoval()
        refit = RefitState(slot: slot.id, choices: choices, window: window, phase: .fitting, noneMarked: marked.isEmpty)
        runRefit()
    }

    /// Ticks or unticks a value, and fits again.
    public func setRefitChoice(_ name: String, ticked: Bool) {
        guard var state = refit, let position = state.choices.firstIndex(where: { $0.name == name }),
              state.choices[position].ticked != ticked else { return }
        state.choices[position].ticked = ticked
        refit = state
        runRefit()
    }

    /// Chooses which readings count, and fits again.
    public func setRefitWindow(_ window: RefitState.Window) {
        guard var state = refit, state.window != window else { return }
        state.window = window
        refit = state
        runRefit()
    }

    /// Fits the ticked values: copies the slot through the engine's queue, so the copy follows
    /// every edit before it, then fits on a thread of its own.
    func runRefit() {
        guard var state = refit, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        stopRefitWork()
        clearRefitPreview()
        let ticked = state.choices.filter(\.ticked).map(\.name)
        state.phase = ticked.isEmpty ? .nothingTicked : .fitting
        if refit != state { refit = state }
        guard !ticked.isEmpty else { return }

        refitSequence += 1
        let sequence = refitSequence
        let flag = CancelFlag()
        refitFlag = flag
        let settings = FitSettings(values: ticked, since: readingsSince(state.window, slotAt: index))
        refitTask = Task { [weak self] in
            guard let self else { return }
            let answer: Answer
            switch await self.copyForFitting(slotAt: index) {
            case .failed(let message):
                answer = .failed(message)
            case .copy(let copy):
                answer = await Task.detached(priority: .userInitiated) { () -> Answer in
                    do {
                        return .fitted(try copy.fit(settings, isCancelled: { flag.isCancelled }))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed(String(describing: error))
                    }
                }.value
            }
            self.finishRefit(answer, sequence: sequence)
        }
    }

    /// Waits for the fit that's running, if there is one. Its preview then goes to the engine like
    /// any other, so tests wait for that with `waitUntilIdle()`.
    public func waitForRefit() async {
        await refitTask?.value
    }

    private func finishRefit(_ answer: Answer, sequence: Int) {
        guard sequence == refitSequence, var state = refit, let index = slotIndex(id: state.slot) else { return }
        refitTask = nil
        refitFlag = nil
        switch answer {
        case .cancelled:
            return
        case .failed(let message):
            state.phase = .failed(Self.sentence(message))
        case .fitted(let outcome):
            let found = found(from: outcome, state: state, slotAt: index)
            state.phase = .fitted(found)
            if found.improved { requestRefitPreview(found.values) }
        }
        if refit != state { refit = state }
    }

    /// The fit as the sheet shows it: each value's change, and how far the slot misses its readings.
    private func found(from outcome: FitOutcome, state: RefitState, slotAt index: Int) -> RefitState.Found {
        let slot = slots[index]
        let shown = slot.parameterValues + slot.startingValues
        var values: [String: Double] = [:]
        var changes: [RefitState.Change] = []
        for choice in state.choices where choice.ticked {
            guard let fitted = outcome.values[choice.name] else { continue }
            // Six significant figures: the fit isn't more precise than that, and scenario.md stays readable.
            let rounded = Double(String(format: "%.6g", fitted)) ?? fitted
            values[choice.name] = rounded
            let value = shown.first { $0.name == choice.name }
            changes.append(RefitState.Change(name: choice.name, label: choice.label, from: choice.current,
                                             to: value?.text(rounded) ?? SlotValue.number(rounded)))
        }
        return RefitState.Found(values: values, changes: changes, improved: outcome.improved,
                                summary: missSummary(outcome, slot: slot))
    }

    /// "Misses the next reading by 1.8%, was 2.6%." For several values, one sentence each.
    private func missSummary(_ outcome: FitOutcome, slot: SlotInfo) -> String {
        func amount(_ summary: MissSummary) -> String {
            if summary.isRatio {
                return summary.typical < 0.0005 ? "less than " + slot.style.with(.percent).full(0.001) : slot.style.with(.percent).full(summary.typical)
            }
            return (summary.variable == slot.variable ? slot.style : .number).full(summary.typical)
        }
        let several = outcome.after.count > 1
        var sentences: [String] = []
        for after in outcome.after {
            let label = slot.outputs.first { $0.name == after.variable }?.label ?? after.variable
            var text = (several ? "\(label) misses" : "Misses") + " the next reading by \(amount(after))"
            if outcome.improved, let before = outcome.before?.first(where: { $0.variable == after.variable }) {
                text += ", was \(amount(before))"
            }
            sentences.append(text + ".")
        }
        if outcome.improved, outcome.before == nil {
            sentences.append("The slot's own values work out values that can't be compared with the readings.")
        }
        return sentences.joined(separator: " ")
    }

    /// Makes the fitted values the slot's own, as one change that undo takes back.
    public func applyRefit() {
        guard let state = refit, let found = state.applicable, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        var config = configs[index]
        for (name, value) in found.values { config.values[name] = value }
        let title = slots[index].title
        closeRefit()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        let changes = found.changes.map { "\($0.label) \($0.from) → \($0.to)" }.joined(separator: ", ")
        say("Refitted \(title): \(changes)")
    }

    /// Closes the sheet and drops the fit, changing nothing.
    public func closeRefit() {
        stopRefitWork()
        refitSequence += 1
        clearRefitPreview()
        if refit != nil { refit = nil }
    }

    private func stopRefitWork() {
        refitFlag?.cancel()
        refitTask?.cancel()
        refitFlag = nil
        refitTask = nil
    }

    /// After slots change: closes the sheet if its slot is gone or paused, or shows the preview again.
    func refitSlotsChanged() {
        guard let state = refit else { return }
        guard let index = slotIndex(id: state.slot), canRefit(slot: state.slot) else {
            closeRefit()
            return
        }
        if let found = state.applicable, isSlot(index) { requestRefitPreview(found.values) }
    }

    /// The first date whose misses count, for the readings chosen.
    func readingsSince(_ window: ReadingsWindow, slotAt index: Int) -> Date? {
        guard let years = window.years else { return nil }
        let values = Set(slots[index].outputs.map(\.name))
        guard let last = configs[index].readings.set.readings.last(where: { values.contains($0.variable) }) else { return nil }
        return Calendar.utcGregorian.date(byAdding: .year, value: -years, to: last.time)
    }

    // MARK: The dashed preview

    /// Shows the slot's line with the fitted values, dashed, a screen to each side of the view.
    private func requestRefitPreview(_ values: [String: Double]) {
        guard let state = refit, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        let config = configs[index]
        guard let model = try? config.makeModel(values: config.values.merging(values) { $1 }) else { return }
        previewSlot = config.id
        parameterPreviewSequence += 1
        let from = max(start, frame.start.addingTimeInterval(-frame.span))
        let through = frame.end.addingTimeInterval(frame.span)
        refitPreviewRange = (from, through)
        let setup = ScenarioEngine.SlotSetup(name: config.name, variable: config.variable, model: model, key: "refit")
        requestPreview(ScenarioEngine.PreviewRequest(version: revision, sequence: parameterPreviewSequence, slot: index,
                                                     change: .model(setup), from: from, through: through))
    }

    /// After the view moves: asks again once it nears the edge of what the preview covers.
    func extendRefitPreviewIfNeeded() {
        guard let range = refitPreviewRange, let found = refit?.applicable else { return }
        let margin = frame.span * 0.25
        let needsEarlier = range.from > start && frame.start.addingTimeInterval(-margin) < range.from
        if needsEarlier || frame.end.addingTimeInterval(margin) > range.through { requestRefitPreview(found.values) }
    }

    private func clearRefitPreview() {
        guard refitPreviewRange != nil else { return }
        refitPreviewRange = nil
        clearSlotPreview()
    }
}
