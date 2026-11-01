import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds
import FutureCommands

/// The import sheet over the Slot tab (docs/UI.md, 5.10): a table of readings from a file or the
/// clipboard, which of its columns are the dates and the values, and what importing would bring.
public struct ReadingImportState: Equatable, Sendable {
    /// What would be imported, as the sheet says it.
    public struct Preview: Equatable, Sendable {
        public let count: Int
        /// "312 readings from Jan 2000 to Dec 2025. The latest: £41,200."
        public let summary: String
        /// Rows left out, and dates that came twice, or nil.
        public let notes: String?
        /// "They'll be kept in scenario.md." or "They'll be saved as readings/Savings-Statements.csv."
        public let destination: String
    }

    public let slot: UUID
    /// "statements.csv", or "the clipboard".
    public let origin: String
    /// What the readings line says they are: "Statements".
    public var title: String
    public let columns: [String]
    public var dateColumn: Int?
    public var valueColumn: Int?
    /// The slot's values and parameters the readings can be of.
    public let targets: [SlotOutput]
    public var variable: String
    public var preview: Preview?
    /// Why nothing can be imported with these choices.
    public var problem: String?

    public var canImport: Bool { (preview?.count ?? 0) > 0 && !title.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Importing readings from files and the clipboard, and adding single readings (docs/DESIGN.md, 14
/// and 15.3; docs/UI.md, 5.10). Both are changes to the slot's readings that undo takes back.
extension ScenarioStore {
    /// Sets of up to this many readings go in `scenario.md`; larger ones in a file in `readings/`.
    nonisolated static let inlineLimit = 100

    // MARK: The import sheet

    /// Reads a file off the main thread, then opens the import sheet for it.
    public func importReadings(from url: URL, slotAt index: Int) {
        guard isSlot(index) else { return }
        let slot = slots[index].id
        let name = url.lastPathComponent
        importTask?.cancel()
        importTask = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { () -> Result<ImportTable, FeedError> in
                do {
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                        return .failure(FeedError("\(name) isn't text."))
                    }
                    return .success(try ImportTable(text))
                } catch let error as FeedError {
                    return .failure(error)
                } catch {
                    return .failure(FeedError("Couldn't read \(name): \(error.localizedDescription)"))
                }
            }.value
            guard let self, !Task.isCancelled, let index = self.slotIndex(id: slot) else { return }
            switch read {
            case .success(let table):
                self.openImport(table, origin: name, title: Self.title(fromFileName: name), slotAt: index)
            case .failure(let error):
                self.say("\(name): \(error.message)", isError: true)
            }
        }
    }

    /// Waits for a file being read for the import sheet.
    public func waitForImport() async {
        await importTask?.value
    }

    /// Opens the import sheet for text from the clipboard, such as rows copied from a spreadsheet.
    public func pasteReadings(_ text: String?, slotAt index: Int) {
        guard isSlot(index) else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("The clipboard has no text to import. Copy a date column and a value column from a spreadsheet first.",
                isError: true)
            return
        }
        do {
            openImport(try ImportTable(text), origin: "the clipboard", title: "Pasted readings", slotAt: index)
        } catch {
            say("The clipboard's text: \(error.message)", isError: true)
        }
    }

    private func openImport(_ table: ImportTable, origin: String, title: String, slotAt index: Int) {
        let slot = slots[index], targets = feedTargets(ofSlotAt: index)
        closeRefit()
        closePredict()
        closeFeedSetup()
        showSlotSettings(forSlotAt: index)
        importTable = table
        var state = ReadingImportState(slot: slot.id, origin: origin, title: title, columns: table.columns,
                                       dateColumn: table.dateColumn, valueColumn: table.valueColumns.first,
                                       targets: targets, variable: slot.variable)
        // A value column named after one of the slot's values is the one to import.
        if let named = table.valueColumns.first(where: { column in
            targets.contains { $0.name.lowercased() == table.columns[column].lowercased() || $0.label.lowercased() == table.columns[column].lowercased() }
        }) {
            state.valueColumn = named
            if let target = targets.first(where: {
                $0.name.lowercased() == table.columns[named].lowercased() || $0.label.lowercased() == table.columns[named].lowercased()
            }) {
                state.variable = target.name
            }
        }
        readingImport = updatedPreview(state)
    }

    public func setImportColumns(date: Int?, value: Int?) {
        guard var state = readingImport else { return }
        state.dateColumn = date
        state.valueColumn = value
        readingImport = updatedPreview(state)
    }

    public func setImportVariable(_ variable: String) {
        guard var state = readingImport, state.variable != variable else { return }
        state.variable = variable
        readingImport = updatedPreview(state)
    }

    public func setImportTitle(_ title: String) {
        guard var state = readingImport, state.title != title else { return }
        state.title = title
        readingImport = updatedPreview(state)
    }

    public func cancelReadingImport() {
        importTask?.cancel()
        importTable = nil
        if readingImport != nil { readingImport = nil }
    }

    /// The readings the sheet's choices give, or why there are none.
    private func importOutcome(_ state: ReadingImportState) -> Result<ImportTable.Outcome, FeedError> {
        guard let table = importTable else { return .failure(FeedError("There's nothing to import.")) }
        guard let date = state.dateColumn else { return .failure(FeedError("Choose the column with the dates.")) }
        guard let value = state.valueColumn else { return .failure(FeedError("Choose the column with the values.")) }
        guard date != value else { return .failure(FeedError("The dates and the values need different columns.")) }
        let outcome = table.readings(date: date, value: value, variable: state.variable)
        guard !outcome.readings.isEmpty else {
            return .failure(FeedError("No row has both a date and a number in those columns."))
        }
        return .success(outcome)
    }

    private func updatedPreview(_ state: ReadingImportState) -> ReadingImportState {
        var state = state
        guard let index = slotIndex(id: state.slot) else { return state }
        switch importOutcome(state) {
        case .failure(let error):
            state.preview = nil
            state.problem = error.message
        case .success(let outcome):
            state.problem = nil
            let readings = outcome.readings, slot = slots[index]
            let style = style(of: state.variable, inSlotAt: index)
            let count = readings.count
            var summary = count == 1 ? "1 reading, on \(DateText.dayMonthYear(readings[0].time))."
                : "\(SlotValue.number(Double(count))) readings from \(DateText.monthYear(readings.first!.time)) to \(DateText.monthYear(readings.last!.time))."
            summary += " The latest: \(style.full(readings.last!.value))."
            var notes: [String] = []
            if outcome.skipped > 0 {
                notes.append(outcome.skipped == 1 ? "1 row has no date or number there, and is left out."
                             : "\(outcome.skipped) rows have no date or number there, and are left out.")
            }
            if outcome.repeated > 0 {
                notes.append(outcome.repeated == 1 ? "1 date comes twice: the later row counts."
                             : "\(outcome.repeated) dates come more than once: the last row for each counts.")
            }
            let destination = count <= Self.inlineLimit || scenarioFolder == nil
                ? "They'll be kept in scenario.md, under \(slot.title)."
                : "They'll be saved as \(readingsPath(title: state.title, slotAt: index))."
            state.preview = ReadingImportState.Preview(count: count, summary: summary,
                                                       notes: notes.isEmpty ? nil : notes.joined(separator: " "),
                                                       destination: destination)
        }
        return state
    }

    /// Adds the readings to the slot, as one change that undo takes back.
    public func applyReadingImport() {
        guard let state = readingImport, state.canImport, let index = slotIndex(id: state.slot), isSlot(index),
              case .success(let outcome) = importOutcome(state) else { return }
        let readings = outcome.readings
        let title = state.title.trimmingCharacters(in: .whitespaces)
        let source: ReadingSource
        if readings.count > Self.inlineLimit, let folder = scenarioFolder {
            let path = readingsPath(title: title, slotAt: index)
            do {
                let url = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CSVReadings.text(readings).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                say("Couldn't save the readings in \(path): \(error.localizedDescription)", isError: true)
                return
            }
            source = .csvFile(title: title, path: path)
        } else {
            source = .inline(csv: Self.inlineCSV(readings))
        }
        var config = configs[index]
        config.readings = SlotReadings(sources: config.readings.sources + [source],
                                       parts: config.readings.parts + [ReadingSet(readings)])
        cancelReadingImport()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        let label = feedTargets(ofSlotAt: index).first { $0.name == state.variable }?.label ?? state.variable
        say("Imported \(SlotValue.number(Double(readings.count))) reading\(readings.count == 1 ? "" : "s") of \(label.lowercased()) "
            + "into \(slots[index].title). ⌘Z takes them out.")
    }

    /// Readings as a `csv` block's text, as reading scenario.md gives it back: without a last line
    /// break, so the block is the same source after the file is read again.
    nonisolated static func inlineCSV(_ readings: [Reading]) -> String {
        var text = CSVReadings.text(readings)
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Where a large import is saved: `readings/Savings-Statements.csv`, numbered when that's taken.
    func readingsPath(title: String, slotAt index: Int) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let base = "readings/" + ([configs[index].name] + (words.isEmpty ? ["readings"] : words)).joined(separator: "-")
        let taken = Set(configs.flatMap(\.readings.sources).compactMap { source -> String? in
            if case .csvFile(_, let path) = source { return path }
            return nil
        })
        func free(_ path: String) -> Bool {
            !taken.contains(path) && !(scenarioFolder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path) } ?? false)
        }
        var path = base + ".csv", number = 2
        while !free(path) {
            path = base + "-\(number).csv"
            number += 1
        }
        return path
    }

    /// "Statements" from "statements.csv", "Bank export 2026" from "bank_export_2026.csv".
    nonisolated static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = base.first else { return "Imported readings" }
        return first.uppercased() + base.dropFirst()
    }

    /// How one of a slot's values is written: the graph's style for the value it shows, else the
    /// value's own quantity in the slot's currency.
    func style(of variable: String, inSlotAt index: Int) -> ValueStyle {
        let slot = slots[index]
        if variable == slot.variable { return slot.style }
        if let value = (slot.parameterValues + slot.startingValues).first(where: { $0.name == variable }) {
            return slot.style.with(ValueFormat(value.quantity))
        }
        return ValueStyle.number
    }

    // MARK: Removing a source

    /// Takes a source of readings out of a slot: a feed, a file, a database or readings written in
    /// scenario.md. A file stays in `readings/`, so undo can bring it back.
    public func removeReadingSource(at source: Int, inSlotAt index: Int) {
        guard isSlot(index), configs[index].readings.sources.indices.contains(source) else { return }
        var config = configs[index]
        var sources = config.readings.sources
        let removed = sources.remove(at: source)
        config.readings = config.readings.with(sources: sources)
        closeFeedSetup()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        let name: String
        switch removed {
        case .feed(let spec): name = "the feed “\(spec.title)”"
        case .csvFile(let title, _), .database(let title, _, _): name = "“\(title)”"
        case .inline: name = "the readings written in scenario.md"
        }
        say("Removed \(name). ⌘Z brings it back.")
    }

    // MARK: Single readings

    /// A reading checked and ready to add.
    struct PreparedReading {
        let index: Int
        let variable: String
        let value: Double
        let time: Date
        /// "a reading of balance, £41,200, on 1 Nov 2026 in Savings".
        let summary: String
    }

    /// Checks a reading of one of a slot's values (the one its graph shows, by default), and says
    /// what adding it would do.
    func prepareReading(_ value: Double, of variable: String? = nil, at time: Date, toSlotAt index: Int) -> Result<PreparedReading, OutsideProblem> {
        guard isSlot(index) else { return .failure(OutsideProblem("There's no such slot.")) }
        let slot = slots[index]
        let targets = feedTargets(ofSlotAt: index)
        let name: String
        if let variable {
            guard let target = targets.first(where: { $0.name.lowercased() == variable.lowercased() || $0.label.lowercased() == variable.lowercased() }) else {
                return .failure(OutsideProblem("\(slot.title) has no value called “\(variable)”. Its values: \(targets.map(\.name).joined(separator: ", "))."))
            }
            name = target.name
        } else {
            name = slot.variable
        }
        guard value.isFinite else { return .failure(OutsideProblem("A reading has to be a number.")) }
        let label = targets.first { $0.name == name }?.label ?? name
        let summary = "a reading of \(label.lowercased()), \(style(of: name, inSlotAt: index).full(value)), "
            + "on \(DateText.dayMonthYear(time)) in \(slot.title)"
        return .success(PreparedReading(index: index, variable: name, value: value, time: time, summary: summary))
    }

    /// Adds one reading to a slot, in the readings written in scenario.md. A reading already there
    /// for the same time and value is replaced. One change, which undo takes back.
    @discardableResult
    func addReading(_ value: Double, of variable: String? = nil, at time: Date, toSlotAt index: Int) -> Result<String, OutsideProblem> {
        prepareReading(value, of: variable, at: time, toSlotAt: index).map(add)
    }

    private func add(_ ready: PreparedReading) -> String {
        var config = configs[ready.index]
        var sources = config.readings.sources, parts = config.readings.parts
        let position = sources.firstIndex { if case .inline = $0 { return true } else { return false } }
        var list = position.map { parts[$0].readings } ?? []
        let replaced = list.contains { $0.time == ready.time && $0.variable == ready.variable }
        list.removeAll { $0.time == ready.time && $0.variable == ready.variable }
        list.append(Reading(time: ready.time, variable: ready.variable, value: ready.value))
        let set = ReadingSet(list)
        let csv = Self.inlineCSV(set.readings)
        if let position {
            sources[position] = .inline(csv: csv)
            parts[position] = set
        } else {
            sources.append(.inline(csv: csv))
            parts.append(set)
        }
        config.readings = SlotReadings(sources: sources, parts: parts)
        applySlotChange(configs.replacing(ready.index, with: config), focus: nil)
        let text = (replaced ? "Replaced " : "Added ") + ready.summary
        say(text)
        return text
    }

    // MARK: From outside

    /// The reading a request from the etf tool or Shortcuts asks for, checked as the command bar
    /// checks one: a currency must be the slot's, and a plain number for a percent is in percent.
    func prepare(_ request: ReadingRequest, now: Date) -> Result<PreparedReading, OutsideProblem> {
        guard !slots.isEmpty else { return .failure(OutsideProblem("The scenario has no slots.")) }
        let index: Int
        if let text = request.slot {
            guard let found = slotIndex(named: text) else { return .failure(noSlot(text)) }
            index = found
        } else {
            index = focusedIndex
        }
        let slot = slots[index]
        if let typed = request.currency, !slot.currency.answers(to: typed) {
            return .failure(OutsideProblem("\(slot.title) is in \(slot.currency.plural). Give the reading in \(slot.money.writing.symbol), or without a currency."))
        }
        let name = request.variable.flatMap { wanted in
            feedTargets(ofSlotAt: index).first { $0.name.lowercased() == wanted.lowercased() || $0.label.lowercased() == wanted.lowercased() }?.name
        } ?? (request.variable == nil ? slot.variable : nil)
        let isPercent = name.map { $0 == slot.variable ? slot.format == .percent : quantity(of: $0, inSlotAt: index) == .percent } ?? false
        let value = isPercent && !request.value.isFraction ? request.value.value / 100 : request.value.value
        return prepareReading(value, of: request.variable, at: request.at?.date ?? Self.today(now), toSlotAt: index)
    }

    /// Says what a reading would add, without adding it, or why it can't be added. Shortcuts asks
    /// before it adds anything.
    public func describe(_ request: ReadingRequest, now: Date = Date()) -> Result<String, OutsideProblem> {
        prepare(request, now: now).map { "Add " + $0.summary }
    }

    /// Adds a reading from outside the panel. It can be undone.
    public func addReading(_ request: ReadingRequest, now: Date = Date()) -> Reply {
        switch prepare(request, now: now) {
        case .failure(let problem):
            say(problem.description, isError: true)
            return .failed(problem.description)
        case .success(let ready):
            return .done(add(ready))
        }
    }
}
