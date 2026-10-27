import Foundation
import FutureEngine

/// Which readings Refit and Predict with fit to, counted back from the latest reading.
public enum ReadingsWindow: String, CaseIterable, Identifiable, Sendable {
    case all, year, fiveYears, tenYears, twentyFiveYears, fiftyYears

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All readings"
        case .year: return "The last year"
        case .fiveYears: return "The last 5 years"
        case .tenYears: return "The last 10 years"
        case .twentyFiveYears: return "The last 25 years"
        case .fiftyYears: return "The last 50 years"
        }
    }

    var years: Int? {
        switch self {
        case .all: return nil
        case .year: return 1
        case .fiveYears: return 5
        case .tenYears: return 10
        case .twentyFiveYears: return 25
        case .fiftyYears: return 50
        }
    }
}

/// The Predict with menu (docs/UI.md, 5.11): the models that could make a slot's projection, each
/// fitted to its readings and scored on readings it didn't see.
public struct PredictState: Equatable, Sendable {
    /// A model in the menu.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let summary: String
        /// Its heading in the menu: "This slot", "Forecast", or the library's category.
        public let group: String
        /// The slot uses this model now.
        public let isCurrent: Bool
        /// How many values it fits. When scores are close, the model that fits fewer wins.
        public let fittedCount: Int
        public var phase: Phase

        public var score: Score? {
            if case .scored(let score) = phase { return score }
            return nil
        }
    }

    public enum Phase: Equatable, Sendable {
        case waiting
        case scored(Score)
        case failed(String)
    }

    public struct Score: Equatable, Sendable {
        /// The typical miss on readings it didn't see: a fraction when the misses are ratios, else
        /// in the value's own units. Lower is better.
        public let typical: Double
        /// "off by 2.1%", "off by 0.75 °C".
        public let text: String
        /// The fitted values, rounded as choosing the model writes them.
        public let values: [String: Double]
        /// Each fitted value as the card shows it.
        public let fitted: [Fitted]
        /// Where the drawn projection starts: the last cut-off.
        public let cutoff: Date
        /// The projection from the cut-off over the readings it didn't see.
        public let line: [Sample]
        /// How many hidden readings it was compared with.
        public let compared: Int
    }

    /// "Growth per year 4.1%".
    public struct Fitted: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let label: String
        public let text: String
    }

    public let slot: UUID
    /// The value the readings are of, which every model is scored on.
    public let variable: String
    public var window: ReadingsWindow
    public var rows: [Row]
    /// The row the graph previews and ↩ chooses: hovered, or moved to with ↑ and ↓.
    public var selection: String?
    /// Why the models can't be compared, such as too few readings.
    public var problem: String?
    /// Asked for the best before the scores were in: it's selected once they are.
    public var wantsBest = false

    /// Still scoring some models.
    public var isComparing: Bool { problem == nil && rows.contains { $0.phase == .waiting } }

    /// "Comparing 7 models…", or why they can't be compared.
    public var status: String? {
        if let problem { return problem }
        guard isComparing else { return nil }
        return "Comparing \(rows.count) models…"
    }

    /// The row with the lowest score, except that among scores within a tenth of it, the one that
    /// fits fewest values wins, since it's less likely to be fitting noise. Nil until every model
    /// is scored.
    public var best: String? {
        guard !isComparing else { return nil }
        return Self.best(of: rows)
    }

    static func best(of rows: [Row]) -> String? {
        let scored = rows.compactMap { row in row.score.map { (row: row, score: $0) } }
        guard let lowest = scored.map(\.score.typical).min() else { return nil }
        let close = scored.filter { $0.score.typical <= lowest * 1.1 }
        return close.min { a, b in
            a.row.fittedCount != b.row.fittedCount ? a.row.fittedCount < b.row.fittedCount : a.score.typical < b.score.typical
        }?.row.id
    }

    public var selectedRow: Row? { rows.first { $0.id == selection } }
}

/// The dotted line the graph draws for the selected model's held-back test (docs/UI.md, 2.4): its
/// projection from the cut-off over the readings it didn't see.
public struct HeldBackLine: Equatable, Sendable {
    public let slot: UUID
    public let cutoff: Date
    public let line: [Sample]
}

/// What scoring and choosing a model in the menu needs, kept off the observed state.
struct PredictCandidate: Sendable {
    let id: String
    let name: String
    let kind: ModelKind
    let formula: String
    /// The values the slot starts the model with: the guess for a Forecast model, the slot's own for its current one.
    let values: [String: Double]
    /// The values to fit, in order.
    let fit: [String]
    /// How each fitted value is labelled and written.
    let shown: [String: SlotValue]
    let isCurrent: Bool
    /// Identifies the model, its values and the slot's readings, for keeping scores.
    let key: String
}

/// Predict with in the panel (docs/UI.md, 5.11): fits and scores each model on a copy of the slot,
/// off the main thread and the engine's, one at a time, cheapest first (docs/DESIGN.md, 8.4).
extension ScenarioStore {
    private enum Answer: Sendable {
        case scored(ScoreOutcome)
        case failed(String, everyModel: Bool)
        case cancelled
    }

    /// Opens Predict with for a slot. `with` names a model to select ("trend line"), or "best".
    /// Returns whether it opened.
    @discardableResult
    public func openPredict(slotAt index: Int, with wanted: String? = nil) -> Bool {
        guard isSlot(index) else { return false }
        let slot = slots[index], config = configs[index]
        guard canRefit(slot: slot.id) else {
            say(slot.isPaused ? "\(slot.title) is paused, so it can't be predicted from its readings."
                : "\(slot.title) has no readings of its values to predict from. Add a feed first.", isError: true)
            return false
        }
        guard let model = try? config.makeModel() else { return false }
        let withReadings = Set(config.readings.set.readings.map(\.variable))
        let values = model.descriptor.variables.filter { $0.causality == .output && withReadings.contains($0.name) }.map(\.name)
        guard let variable = values.contains(slot.variable) ? slot.variable : values.first else { return false }

        let candidates = makePredictCandidates(slotAt: index, model: model, variable: variable, valuesWithReadings: values,
                                               window: .all)
        var rows = candidates.map { candidate in
            PredictState.Row(id: candidate.id, name: candidate.name, summary: summary(of: candidate),
                             group: group(of: candidate), isCurrent: candidate.isCurrent,
                             fittedCount: candidate.fit.count, phase: .waiting)
        }
        // The slot's own model goes first; it may also be one of the Forecast models.
        rows.sort { ($0.isCurrent ? 0 : 1) < ($1.isCurrent ? 0 : 1) }
        var selection = rows.first { $0.isCurrent }?.id
        var wantsBest = false
        if let wanted {
            let text = wanted.lowercased().trimmingCharacters(in: .whitespaces)
            if text == "best" || text == "the best" {
                wantsBest = true
            } else if let row = rows.first(where: { $0.name.lowercased() == text })
                        ?? rows.first(where: { $0.name.lowercased().hasPrefix(text) }) {
                selection = row.id
            } else {
                say("\(slot.title) can't predict with “\(wanted)”. Try \(rows.map(\.name).joined(separator: ", ")).", isError: true)
                return false
            }
        }

        closeRefit()
        closePredict()
        showSlotSettings(forSlotAt: index)
        cancelRemoval()
        predictCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        predict = PredictState(slot: slot.id, variable: variable, window: .all, rows: rows, selection: selection,
                               problem: nil, wantsBest: wantsBest)
        runPredict()
        return true
    }

    /// The models the menu offers: the slot's own, the Forecast models written around the value
    /// the readings are of, and library models that have that value, of the same kind, and read
    /// no other slot.
    private func makePredictCandidates(slotAt index: Int, model: any AuthoredModel, variable: String,
                                       valuesWithReadings: [String], window: ReadingsWindow) -> [PredictCandidate] {
        let slot = slots[index], config = configs[index]
        let readings = config.readings.set.readings
        let descriptor = model.descriptor
        let quantity = descriptor.variable(named: variable)?.quantity
        let base = [slot.id.uuidString, start.description, config.readings.set.digest].joined(separator: "|")
        var list: [PredictCandidate] = []

        func shown(_ model: any AuthoredModel, _ names: [String]) -> [String: SlotValue] {
            var result: [String: SlotValue] = [:]
            for name in names {
                guard let variable = model.descriptor.variable(named: name) else { continue }
                result[name] = SlotValue(name: name, label: variable.label ?? name, quantity: variable.quantity ?? .number,
                                         minimum: variable.minimum, maximum: variable.maximum, increment: variable.increment,
                                         value: nil, defaultValue: nil, isChanged: false)
            }
            return result
        }
        let withReadings = Set(readings.map(\.variable))
        func candidate(_ template: ModelTemplate, values: [String: Double]) -> PredictCandidate? {
            guard let made = Self.libraryModel(template) else { return nil }
            let fit = made.descriptor.variables.filter { $0.fittable && !withReadings.contains($0.name) }.map(\.name)
            // The slot's own model starts from the slot's own values.
            let isCurrent = template.formula == config.formula
            let start = isCurrent ? values.merging(config.values) { $1 } : values
            return PredictCandidate(id: template.id, name: template.name, kind: template.kind, formula: template.formula,
                                    values: start, fit: fit, shown: shown(made, fit), isCurrent: isCurrent,
                                    key: [base, template.formula, Self.describe(start)].joined(separator: "|"))
        }

        // Forecast models, when the readings are of one value.
        if valuesWithReadings.count == 1 {
            let label = descriptor.variable(named: variable)?.label ?? slot.outputs.first { $0.name == variable }?.label ?? variable
            let format = Self.format(of: quantity) ?? (variable == slot.variable ? slot.format : .number)
            let value = ForecastModels.Value(name: variable, label: label, format: format, step: descriptor.stepRate)
            let ofValue = readings.filter { $0.variable == variable }
            // As the engine measures misses (DESIGN.md, 8.4): ratios for amounts and numbers above zero.
            let inRatios = quantity != .temperature && quantity != .percent && ofValue.allSatisfy { $0.value > 0 }
            for template in ForecastModels.templates(for: value, readings: ofValue) {
                guard let kind = ForecastModels.kind(of: template),
                      let made = candidate(template, values: ForecastModels.guess(kind, readings: since(window, ofValue),
                                                                                  inRatios: inRatios))
                else { continue }
                list.append(made)
            }
        }

        // Library models with the same values, of the same kind, that read nothing.
        for template in ModelLibrary.all where template.category != .forecast && template.category != .blank {
            guard let made = Self.libraryModel(template),
                  made.descriptor.inputs.isEmpty, made.descriptor.subscriptions.isEmpty,
                  valuesWithReadings.allSatisfy({ name in
                      made.descriptor.variable(named: name).map { $0.causality == .output && $0.quantity == descriptor.variable(named: name)?.quantity } ?? false
                  }),
                  let entry = candidate(template, values: [:]) else { continue }
            list.append(entry)
        }

        // The slot's own model, as it is, unless it's one of those.
        if !list.contains(where: \.isCurrent) {
            let marked = descriptor.variables.filter { $0.fittable && !withReadings.contains($0.name) }.map(\.name)
            list.insert(PredictCandidate(id: "current", name: slot.model, kind: config.kind, formula: config.formula,
                                         values: config.values, fit: marked, shown: shown(model, marked), isCurrent: true,
                                         key: [base, config.formula, Self.describe(config.values)].joined(separator: "|")), at: 0)
        }
        return list
    }

    private func summary(of candidate: PredictCandidate) -> String {
        if candidate.id == "current" {
            return candidate.fit.isEmpty ? "This slot's model, with its own values" : "This slot's model, refitted"
        }
        return ModelLibrary.all.first { $0.id == candidate.id }?.summary
            ?? ForecastModels.Kind.allCases.first { "forecast-" + $0.rawValue == candidate.id }?.summary ?? ""
    }

    private func group(of candidate: PredictCandidate) -> String {
        if candidate.id == "current" { return "This slot" }
        if candidate.id.hasPrefix("forecast-") { return ModelTemplate.Category.forecast.title }
        return ModelLibrary.all.first { $0.id == candidate.id }?.category.title ?? ""
    }

    /// Library models as read from their source, kept: reading a script runs it, which shouldn't
    /// happen on the main thread each time the menu opens. Forecast models written around other
    /// values are kept too; there are a few per slot.
    private static var libraryModels: [String: any AuthoredModel] = [:]

    private static func libraryModel(_ template: ModelTemplate) -> (any AuthoredModel)? {
        let key = template.id + "|" + template.formula
        if let model = libraryModels[key] { return model }
        guard let model = try? SlotConfig.model(kind: template.kind, source: template.formula, name: template.slotName) else { return nil }
        if libraryModels.count > 200 { libraryModels.removeAll() }
        libraryModels[key] = model
        return model
    }

    /// A score to three significant figures, so close ones can be told apart: "2.13%",
    /// "0.753 °C", "$1,240". Larger amounts are written out as the slot writes them.
    static func scoreAmount(_ value: Double, isRatio: Bool, format: ValueFormat) -> String {
        guard value.isFinite else { return format.full(value) }
        if isRatio { return value < 0.0005 ? "less than 0.1%" : String(format: "%.3g%%", value * 100) }
        let short = String(format: "%.3g", value)
        switch format {
        case .percent: return String(format: "%.3g%%", value * 100)
        case .temperature: return abs(value) < 1000 ? short + " °C" : format.full(value)
        case .currency: return abs(value) < 1000 ? "$" + short : format.full(value)
        case .number: return abs(value) < 1000 ? short : format.full(value)
        }
    }

    /// Values in name order, so the same values always read the same.
    private static func describe(_ values: [String: Double]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static func format(of quantity: Quantity?) -> ValueFormat? {
        switch quantity {
        case .currency: return .currency
        case .temperature: return .temperature
        case .percent: return .percent
        case .number, nil: return nil
        }
    }

    /// Identifies the slot and its readings, for remembering that its models can't be compared.
    private func predictProblemKey(slotAt index: Int) -> String {
        [slots[index].id.uuidString, start.description, configs[index].readings.set.digest].joined(separator: "|")
    }

    /// The readings from the window's first date on.
    private func since(_ window: ReadingsWindow, _ readings: [Reading]) -> [Reading] {
        guard let years = window.years, let last = readings.last,
              let first = Calendar.utcGregorian.date(byAdding: .year, value: -years, to: last.time) else { return readings }
        return readings.filter { $0.time >= first }
    }

    // MARK: Scoring

    /// Scores every model not scored already: copies the slot through the engine's queue, so the
    /// copy follows every edit before it, then scores one model at a time on a thread of its own.
    func runPredict() {
        guard var state = predict, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        stopPredictWork()
        let windowKey = "|" + state.window.rawValue
        let problemKey = predictProblemKey(slotAt: index) + windowKey
        state.problem = predictProblems[problemKey]
        for position in state.rows.indices {
            let key = (predictCandidates[state.rows[position].id]?.key ?? "") + windowKey
            state.rows[position].phase = predictScores[key] ?? .waiting
        }
        if state.wantsBest, let best = state.best {
            state.selection = best
            state.wantsBest = false
        }
        if predict != state { predict = state }
        showPredictSelection()
        let jobs = state.rows.filter { $0.phase == .waiting }.compactMap { predictCandidates[$0.id] }
        guard state.problem == nil, !jobs.isEmpty else { return }

        predictSequence += 1
        let sequence = predictSequence
        let flag = CancelFlag()
        predictFlag = flag
        let variable = state.variable
        let since = readingsSince(state.window, slotAt: index)
        predictTask = Task { [weak self] in
            guard let self else { return }
            switch await self.copyForFitting(slotAt: index) {
            case .failed(let message):
                self.finishPredict(jobs[0].id, .failed(message, everyModel: true), window: windowKey, problemKey: problemKey,
                                   sequence: sequence)
            case .copy(let copy):
                for job in jobs {
                    if flag.isCancelled { return }
                    let answer = await Task.detached(priority: .userInitiated) { () -> Answer in
                        do {
                            let candidate: SlotCopy
                            if job.isCurrent && job.id == "current" {
                                candidate = copy
                            } else {
                                candidate = copy.replacingModel(try SlotConfig.model(kind: job.kind, source: job.formula,
                                                                                     name: copy.name, values: job.values))
                            }
                            let outcome = try candidate.score(variable, .comparing(job.fit, since: since),
                                                              isCancelled: { flag.isCancelled })
                            return .scored(outcome)
                        } catch is CancellationError {
                            return .cancelled
                        } catch let error as FitError {
                            if case .tooFewToCompare = error { return .failed(String(describing: error), everyModel: true) }
                            return .failed(String(describing: error), everyModel: false)
                        } catch {
                            return .failed(String(describing: error), everyModel: false)
                        }
                    }.value
                    guard self.finishPredict(job.id, answer, window: windowKey, problemKey: problemKey,
                                             sequence: sequence) else { return }
                }
            }
        }
    }

    /// Waits for the scoring that's running, if there is any. Previews then go to the engine like
    /// any other, so tests wait for those with `waitUntilIdle()`.
    public func waitForPredict() async {
        await predictTask?.value
    }

    /// Puts one model's score in the menu. Returns whether scoring should go on.
    @discardableResult
    private func finishPredict(_ id: String, _ answer: Answer, window: String, problemKey: String, sequence: Int) -> Bool {
        guard sequence == predictSequence, var state = predict, let candidate = predictCandidates[id],
              let position = state.rows.firstIndex(where: { $0.id == id }), let index = slotIndex(id: state.slot) else { return false }
        var goOn = true
        switch answer {
        case .cancelled:
            return false
        case .failed(let message, let everyModel):
            if everyModel {
                state.problem = Self.sentence(message)
                predictProblems[problemKey] = state.problem
                goOn = false
            } else {
                state.rows[position].phase = .failed(Self.sentence(message))
            }
        case .scored(let outcome):
            state.rows[position].phase = .scored(score(outcome, candidate: candidate, slotAt: index))
        }
        if case .waiting = state.rows[position].phase {} else {
            // Kept until the model, its values or the readings change; a bound keeps the memory small.
            if predictScores.count > 500 { predictScores.removeAll() }
            predictScores[candidate.key + window] = state.rows[position].phase
        }
        if !goOn || !state.isComparing {
            predictTask = nil
            predictFlag = nil
        }
        if state.wantsBest, let best = state.best {
            state.selection = best
            state.wantsBest = false
        }
        if predict != state { predict = state }
        if state.selection == id || state.selection == state.best { showPredictSelection() }
        return goOn
    }

    private func score(_ outcome: ScoreOutcome, candidate: PredictCandidate, slotAt index: Int) -> PredictState.Score {
        let slot = slots[index]
        var values: [String: Double] = [:]
        var fitted: [PredictState.Fitted] = []
        for name in candidate.fit {
            guard let found = outcome.values[name] else { continue }
            // Six significant figures, as Refit writes them.
            let rounded = Double(String(format: "%.6g", found)) ?? found
            values[name] = rounded
            let shown = candidate.shown[name]
            fitted.append(PredictState.Fitted(name: name, label: shown?.label ?? name,
                                              text: shown?.text(rounded) ?? SlotValue.number(rounded)))
        }
        let miss = outcome.miss
        let format = miss.variable == slot.variable ? slot.format : Self.format(of: candidate.shown.values.first?.quantity) ?? .number
        let amount = Self.scoreAmount(miss.typical, isRatio: miss.isRatio, format: format)
        return PredictState.Score(typical: miss.typical, text: "off by \(amount)", values: values, fitted: fitted,
                                  cutoff: outcome.cutoff, line: outcome.line, compared: miss.count)
    }

    // MARK: Choosing

    /// Selects a row, by hovering or with ↑ and ↓: the graph shows its fitted line dashed and its
    /// held-back test dotted.
    public func selectPredict(_ id: String?) {
        guard var state = predict, state.selection != id else { return }
        state.selection = id
        state.wantsBest = false
        predict = state
        showPredictSelection()
    }

    /// Moves the selection up or down the list.
    public func movePredictSelection(by offset: Int) {
        guard let state = predict, !state.rows.isEmpty else { return }
        let position = state.rows.firstIndex { $0.id == state.selection } ?? (offset > 0 ? -1 : state.rows.count)
        selectPredict(state.rows[min(max(position + offset, 0), state.rows.count - 1)].id)
    }

    /// Chooses the selected row, or another: the slot gets that model with its fitted values, as
    /// one change that undo takes back.
    public func choosePredict(_ id: String? = nil) {
        guard let state = predict, let id = id ?? state.selection, let row = state.rows.first(where: { $0.id == id }),
              let candidate = predictCandidates[id], let index = slotIndex(id: state.slot), isSlot(index) else { return }
        let title = slots[index].title
        var config = configs[index]
        let fitted = row.score?.values ?? [:]
        let described = row.score?.fitted.map { "\($0.label) \($0.text)" }.joined(separator: ", ") ?? ""
        if candidate.isCurrent {
            closePredict()
            guard !fitted.isEmpty else {
                say("\(title) already predicts with \(row.name).")
                return
            }
            for (name, value) in fitted { config.values[name] = value }
            applySlotChange(configs.replacing(index, with: config), focus: config.id)
            say("Refitted \(title): \(described)")
            return
        }
        guard let model = try? SlotConfig.model(kind: candidate.kind, source: candidate.formula, name: config.name) else { return }
        let declared = Set(model.parameterNames + model.startingValueNames)
        config.model = row.name
        config.kind = candidate.kind
        config.formula = candidate.formula
        config.variable = state.variable
        config.values = config.values.filter { declared.contains($0.key) }
            .merging(candidate.values.filter { declared.contains($0.key) }) { $1 }
            .merging(fitted) { $1 }
        closePredict()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        say("\(title) now predicts with \(row.name)" + (described.isEmpty ? "" : ": \(described)"))
    }

    /// Chooses the model tagged Best.
    public func usePredictBest() {
        guard let best = predict?.best else { return }
        choosePredict(best)
    }

    /// Chooses which readings the models are fitted to and compared on, and scores them again.
    public func setPredictWindow(_ window: ReadingsWindow) {
        guard var state = predict, state.window != window, let index = slotIndex(id: state.slot) else { return }
        state.window = window
        predict = state
        // Forecast models start from a guess made from the chosen readings.
        if let model = try? configs[index].makeModel() {
            let withReadings = Set(configs[index].readings.set.readings.map(\.variable))
            let values = model.descriptor.variables.filter { $0.causality == .output && withReadings.contains($0.name) }.map(\.name)
            let candidates = makePredictCandidates(slotAt: index, model: model, variable: state.variable, valuesWithReadings: values,
                                                   window: window)
            predictCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        }
        runPredict()
    }

    /// Closes the menu and drops its previews, changing nothing.
    public func closePredict() {
        stopPredictWork()
        predictSequence += 1
        clearPredictPreview()
        if predict != nil { predict = nil }
    }

    private func stopPredictWork() {
        predictFlag?.cancel()
        predictTask?.cancel()
        predictFlag = nil
        predictTask = nil
    }

    /// After slots change: closes the menu if its slot is gone or can't be predicted any more.
    func predictSlotsChanged() {
        guard let state = predict else { return }
        guard slotIndex(id: state.slot) != nil, canRefit(slot: state.slot) else {
            closePredict()
            return
        }
        showPredictSelection()
    }

    // MARK: The previews

    /// Shows the selected model's fitted line dashed, and its held-back test dotted.
    private func showPredictSelection() {
        guard let state = predict, let row = state.selectedRow, let score = row.score,
              let candidate = predictCandidates[row.id] else {
            clearPredictPreview()
            return
        }
        let held = HeldBackLine(slot: state.slot, cutoff: score.cutoff, line: score.line)
        if heldBack != held { heldBack = held }
        requestPredictPreview(candidate, values: score.values)
    }

    private func requestPredictPreview(_ candidate: PredictCandidate, values: [String: Double]) {
        guard let state = predict, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        let config = configs[index]
        let start = candidate.isCurrent ? config.values : candidate.values
        guard let model = try? SlotConfig.model(kind: candidate.kind, source: candidate.formula, name: config.name,
                                                values: start.merging(values) { $1 }) else { return }
        previewSlot = config.id
        parameterPreviewSequence += 1
        let from = max(self.start, frame.start.addingTimeInterval(-frame.span))
        let through = frame.end.addingTimeInterval(frame.span)
        predictPreview = (candidate.id, values, from, through)
        let setup = ScenarioEngine.SlotSetup(name: config.name, variable: state.variable, model: model, key: "predict")
        requestPreview(ScenarioEngine.PreviewRequest(version: revision, sequence: parameterPreviewSequence, slot: index,
                                                     change: .model(setup), from: from, through: through))
    }

    /// After the view moves: asks again once it nears the edge of what the preview covers.
    func extendPredictPreviewIfNeeded() {
        guard let preview = predictPreview, let candidate = predictCandidates[preview.id] else { return }
        let margin = frame.span * 0.25
        let needsEarlier = preview.from > start && frame.start.addingTimeInterval(-margin) < preview.from
        if needsEarlier || frame.end.addingTimeInterval(margin) > preview.through {
            requestPredictPreview(candidate, values: preview.values)
        }
    }

    private func clearPredictPreview() {
        if heldBack != nil { heldBack = nil }
        guard predictPreview != nil else { return }
        predictPreview = nil
        clearSlotPreview()
    }
}
