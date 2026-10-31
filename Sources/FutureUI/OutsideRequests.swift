import Foundation
import FutureCommands
import FutureEngine

/// Requests from outside the panel: the `etf` command-line tool and Shortcuts (docs/DESIGN.md, 10.2).
///
/// Questions are worked out by the engine after anything already queued, so the main thread still
/// never computes. Changes go the same way as the panel's, so they show in the panel, save, and can
/// be undone. Dates arrive in UTC, as the engine counts them; "now" is the clock's, not the
/// moment the scenario opened.
extension ScenarioStore {
    /// Why an outside request can't be done, in the panel's words.
    public struct OutsideProblem: Error, Equatable, CustomStringConvertible {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// The most rows a series answer has.
    nonisolated static let maxRows = 100_000

    // MARK: Questions

    public func answer(_ query: Query, now: Date = Date()) async -> Reply {
        switch query {
        case .status:
            let status = status(now: now)
            return Reply(ok: true, message: "\(name): \(slots.count) slot\(slots.count == 1 ? "" : "s")", status: status)
        case .slots:
            return Reply(ok: true, message: slots.map(\.title).joined(separator: ", "), slots: slotSummaries())
        case .value(let slot, let variable, let at):
            switch await value(slot: slot, variable: variable, at: at?.date ?? now, now: now) {
            case .success(let answer): return Reply(ok: true, message: answer.sentence, value: answer.reading)
            case .failure(let problem): return .failed(problem.description)
            }
        case .series(let slot, let variable, let from, let through, let every):
            switch await series(slot: slot, variable: variable, from: from?.date, through: through?.date, every: every, now: now) {
            case .success(let series):
                return Reply(ok: true, message: "\(series.rows.count) row\(series.rows.count == 1 ? "" : "s") of \(series.slot)", series: series)
            case .failure(let problem): return .failed(problem.description)
            }
        }
    }

    public func status(now: Date = Date()) -> ScenarioStatus {
        ScenarioStatus(name: name, start: DateText.iso(start), now: DateText.iso(now), cursor: DateText.iso(cursor),
                       focused: slots.indices.contains(focusedIndex) ? focused.title : "", slotCount: slots.count,
                       currency: currency.code)
    }

    public func slotSummaries() -> [SlotSummary] {
        slots.map { slot in
            SlotSummary(number: slot.key, name: slot.name, title: slot.title, model: slot.model, shows: slot.variable,
                        outputs: slot.outputs.map(\.name), parameters: slot.parameters, events: slot.eventKinds,
                        currency: slot.currency.code, paused: slot.pausedReason)
        }
    }

    /// A value, what to say about it, and a line around it for Siri's and Shortcuts' snippet.
    public struct OutsideValue: Sendable {
        public let reading: ValueReading
        /// "Savings will be £96,420 in Jan 2030."
        public let sentence: String
        public let slotTitle: String
        public let colorHex: String
        public let style: ValueStyle
        /// The value's line from now to the date asked about, or around now. Empty without `points`.
        public let line: [Sample]
        /// Where the value is on `line`.
        public let date: Date
    }

    /// A slot's value at a date: the slot's last point at or before it. With `points`, also its
    /// line, evenly spaced, from now to the date (or five years either side of now).
    public func value(slot: String?, variable: String?, at date: Date, now: Date = Date(),
                      points: Int = 0) async -> Result<OutsideValue, OutsideProblem> {
        let target: (index: Int, variable: String, style: ValueStyle)
        switch resolve(slot: slot, variable: variable) {
        case .success(let found): target = found
        case .failure(let problem): return .failure(problem)
        }
        let info = slots[target.index]
        var dates = [date]
        var span = (from: date, through: date)
        if points > 1 {
            let fiveYears = 5 * 365.2425 * 86_400
            span = abs(date.timeIntervalSince(now)) < 31 * 86_400
                ? (now.addingTimeInterval(-fiveYears), now.addingTimeInterval(fiveYears))
                : (min(now, date), max(now, date))
            span.from = max(span.from, start)
            span.through = max(span.through, span.from)
            let step = span.through.timeIntervalSince(span.from) / Double(points - 1)
            dates += (0..<points).map { span.from.addingTimeInterval(step * Double($0)) }
        }
        let request = ScenarioEngine.ReadRequest(slot: target.index, variable: target.variable, points: .at(dates))
        switch await read(request) {
        case .failed(let text):
            return .failure(OutsideProblem("\(info.title): \(text)"))
        case .samples(let samples):
            guard let point = samples.first else { return .failure(OutsideProblem("\(info.title) has no value then.")) }
            let text = target.style.full(point.value)
            let reading = ValueReading(slot: info.title, variable: target.variable, date: Self.wireDate(point.time),
                                       value: point.value, text: text, unit: Self.unit(target.style))
            let label = target.variable == info.variable ? info.title : "\(info.title)’s \(target.variable)"
            // The line's points take the dates asked for, so a monthly slot draws as steps.
            let line = zip(dates.dropFirst(), samples.dropFirst()).map { Sample(time: $0, value: $1.value) }
            return .success(OutsideValue(reading: reading, sentence: Self.sentence(label, text, at: date, now: now),
                                         slotTitle: info.title, colorHex: info.colorHex, style: target.style, line: line,
                                         date: date))
        }
    }

    /// A slot's values from `from` (now, at the start of its day) through `through` (ten years
    /// later): every point it computes, or its value at each `every` from `from`.
    public func series(slot: String?, variable: String?, from: Date?, through: Date?, every: Repetition?,
                       now: Date = Date()) async -> Result<SeriesReading, OutsideProblem> {
        let target: (index: Int, variable: String, style: ValueStyle)
        switch resolve(slot: slot, variable: variable) {
        case .success(let found): target = found
        case .failure(let problem): return .failure(problem)
        }
        let info = slots[target.index]
        let calendar = Calendar.utcGregorian
        let first = max(from ?? calendar.startOfDay(for: now), start)
        let last = through ?? calendar.date(byAdding: .year, value: 10, to: from ?? now) ?? first
        guard last >= first else {
            return .failure(OutsideProblem("\(info.title) starts on \(DateText.dayMonthYear(start)), after the end of that range."))
        }
        let points: ScenarioEngine.ReadRequest.Points
        if let every {
            let rate = Self.stepRate(every)
            let grid = TimeGrid(start: first, rate: rate, calendar: calendar)
            let count = (grid.lastIndex(atOrBefore: last) ?? 0) + 1
            guard count <= Self.maxRows else { return .failure(Self.tooMany(count)) }
            points = .at((0..<count).map { grid.point($0) })
        } else {
            if let rate = descriptors.indices.contains(target.index) ? descriptors[target.index]?.stepRate : nil {
                let estimate = last.timeIntervalSince(first) / rate.approximateSeconds
                guard estimate <= Double(Self.maxRows) else { return .failure(Self.tooMany(estimate)) }
            }
            points = .all(from: first, through: last)
        }
        switch await read(ScenarioEngine.ReadRequest(slot: target.index, variable: target.variable, points: points)) {
        case .failed(let text):
            return .failure(OutsideProblem("\(info.title): \(text)"))
        case .samples(let samples):
            // With `every`, each row is the date asked for, holding the slot's value then.
            let rows: [SeriesReading.Row]
            if case .at(let dates) = points {
                rows = zip(dates, samples).map { SeriesReading.Row(date: Self.wireDate($0), value: $1.value) }
            } else {
                rows = samples.map { SeriesReading.Row(date: Self.wireDate($0.time), value: $0.value) }
            }
            return .success(SeriesReading(slot: info.title, variable: target.variable, unit: Self.unit(target.style), rows: rows))
        }
    }

    /// The slot named (or the focused one), one of its values (or the one its graph shows), and how
    /// to write it.
    func resolve(slot text: String?, variable name: String?) -> Result<(index: Int, variable: String, style: ValueStyle), OutsideProblem> {
        guard !slots.isEmpty else { return .failure(OutsideProblem("The scenario has no slots.")) }
        let index: Int
        if let text {
            guard let found = slotIndex(named: text) else { return .failure(noSlot(text)) }
            index = found
        } else {
            index = focusedIndex
        }
        let info = slots[index]
        if let reason = info.pausedReason { return .failure(OutsideProblem("\(info.title) is paused: \(reason)")) }
        let descriptor = descriptors.indices.contains(index) ? descriptors[index] : nil
        let readable = descriptor?.readable.map(\.name) ?? [info.variable]
        let variable: String
        if let name {
            let wanted = name.lowercased()
            guard let found = readable.first(where: { $0.lowercased() == wanted })
                    ?? descriptor?.readable.first(where: { $0.label?.lowercased() == wanted })?.name else {
                return .failure(OutsideProblem("\(info.title) has no value called “\(name)”. Its values: \(readable.joined(separator: ", "))."))
            }
            variable = found
        } else {
            variable = info.variable
        }
        let style = variable == info.variable
            ? info.style
            : ValueStyle(ValueFormat(descriptor?.variable(named: variable)?.quantity), currency: info.currency, writing: info.writing)
        return .success((index, variable, style))
    }

    func noSlot(_ text: String) -> OutsideProblem {
        OutsideProblem("There's no slot called “\(text)”. Slots: \(slots.map(\.title).joined(separator: ", ")).")
    }

    nonisolated static func tooMany(_ count: some BinaryInteger) -> OutsideProblem { tooMany(Double(count)) }

    nonisolated static func tooMany(_ count: Double) -> OutsideProblem {
        let rows = count >= 1e6 ? ValueStyle.number.axis(count) : ValueFormat.grouped(count.rounded())
        return OutsideProblem("That's about \(rows) rows, more than \(ValueFormat.grouped(Double(maxRows))). Ask for a shorter range, or fewer rows with --every monthly or yearly.")
    }

    /// "Jan 2030", as the panel writes months.
    public nonisolated static func monthYearText(_ date: Date) -> String { DateText.monthYear(date) }

    /// "Savings will be £96,420 in Jan 2030.", "Savings is £41,223 now."
    nonisolated static func sentence(_ label: String, _ text: String, at date: Date, now: Date) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "\(label) is \(text) now." }
        let civil = CivilDate(date)
        let when = civil.day == 1 && civil.secondsIntoDay == 0
            ? "in " + DateText.monthYear(date)
            : "on " + DateText.dayMonthYear(date)
        return date > now ? "\(label) will be \(text) \(when)." : "\(label) was \(text) \(when)."
    }

    /// `2030-01-01`, or `2030-01-01T06:00:00Z` for a point during the day.
    nonisolated static func wireDate(_ date: Date) -> String {
        let civil = CivilDate(date)
        let day = DateText.iso(date)
        guard civil.secondsIntoDay != 0 else { return day }
        let seconds = Int(civil.secondsIntoDay.rounded(.down))
        return day + String(format: "T%02d:%02d:%02dZ", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// "GBP", "°C", "%" or "".
    nonisolated static func unit(_ style: ValueStyle) -> String {
        switch style.format {
        case .currency: return style.currency.code
        case .temperature: return "°C"
        case .percent: return "%"
        case .number: return ""
        }
    }

    nonisolated static func stepRate(_ repetition: Repetition) -> StepRate {
        switch repetition {
        case .daily: return .daily
        case .weekly: return .weekly
        case .fortnightly: return .weeks(2)
        case .monthly: return .monthly
        case .quarterly: return .quarters(1)
        case .yearly: return .yearly
        }
    }

    // MARK: Changes

    /// An event checked and ready to add, with what to say about it.
    struct OutsideEvent {
        let index: Int
        let event: Event?
        let rule: RecurringEvent?
        /// "+£500 monthly from Jan 2027 to Savings".
        let summary: String
    }

    /// Says what an event would add, without adding it, or why it can't be added. Shortcuts asks
    /// before it adds anything.
    public func describe(_ request: EventRequest, now: Date = Date()) -> Result<String, OutsideProblem> {
        prepare(request, now: now).map(\.summary)
    }

    /// Adds an event from outside the panel, checked the way the panel checks it. It can be undone.
    public func addEvent(_ request: EventRequest, now: Date = Date()) -> Reply {
        switch prepare(request, now: now) {
        case .failure(let problem):
            say(problem.description, isError: true)
            return .failed(problem.description)
        case .success(let ready):
            if let event = ready.event { add(event, toSlotAt: ready.index) }
            if let rule = ready.rule { add(rule, toSlotAt: ready.index) }
            let message = (request.kind.lowercased() == "set" ? "" : "Added ") + ready.summary
            say(message)
            return .done(message)
        }
    }

    func prepare(_ request: EventRequest, now: Date) -> Result<OutsideEvent, OutsideProblem> {
        guard !slots.isEmpty else { return .failure(OutsideProblem("The scenario has no slots.")) }
        let index: Int
        if let text = request.slot {
            guard let found = slotIndex(named: text) else { return .failure(noSlot(text)) }
            index = found
        } else {
            index = focusedIndex
        }
        let slot = slots[index]
        let when = request.at?.date ?? now
        let repeats = request.every.map(Self.stepRate)
        let month = DateText.monthYear(when)
        /// "on Jan 2027" for once, "every month from Jan 2027" for a repeat.
        let whenText = repeats.map { Self.describe($0) + " from " + month } ?? "on " + month
        let fromText = repeats.map { Self.describe($0) + " from " + month } ?? "from " + month
        if let typed = request.currency, !slot.currency.answers(to: typed) {
            return .failure(OutsideProblem("\(slot.title) is in \(slot.currency.plural). Give the amount in \(slot.money.writing.symbol), or without a currency."))
        }
        let kind = request.kind.lowercased()

        if kind == "set" {
            var values: [String: Double] = [:]
            var parts: [String] = []
            for (name, amount) in request.values.sorted(by: { $0.key < $1.key }) {
                guard let parameter = slot.parameterValues.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                    return .failure(OutsideProblem("\(slot.title) has no parameter called “\(name)”. Its parameters: \(slot.parameters.joined(separator: ", "))."))
                }
                // As in the Slot tab, a plain number for a percent is in percent: 4.5 is 4.5%.
                let value = parameter.quantity == .percent && !amount.isFraction ? amount.value / 100 : amount.value
                values[parameter.name] = value
                parts.append("\(parameter.name) to \(parameter.text(value))")
            }
            let summary = "Set \(parts.joined(separator: " and ")) \(fromText) in \(slot.title)"
            if let repeats {
                return .success(OutsideEvent(index: index, event: nil,
                                             rule: RecurringEvent(kind: "set", values: values, first: when, every: repeats), summary: summary))
            }
            return .success(OutsideEvent(index: index, event: Event.set(values, at: when), rule: nil, summary: summary))
        }

        guard slot.eventKinds.contains(where: { $0.lowercased() == kind }) else {
            if slot.eventKinds.isEmpty {
                let hint = slot.parameters.first.map { " Its parameters can be set, such as \($0)." } ?? ""
                return .failure(OutsideProblem("\(slot.title) doesn't take events.\(hint)"))
            }
            return .failure(OutsideProblem("\(slot.title) doesn't take “\(request.kind)” events. It takes \(Self.list(slot.eventKinds))."))
        }
        let canonical = slot.eventKinds.first { $0.lowercased() == kind } ?? kind
        let values = request.values.mapValues(\.value)
        let summary: String
        if canonical == "deposit" || canonical == "withdraw" {
            guard let amount = values["amount"] else {
                return .failure(OutsideProblem("A \(canonical) needs an amount."))
            }
            guard amount > 0, request.values["amount"]?.isFraction == false else {
                return .failure(OutsideProblem("A \(canonical) takes an amount of money above zero."))
            }
            let sign = canonical == "deposit" ? "+" : "−"
            summary = "\(sign)\(slot.money.full(amount).replacingOccurrences(of: "−", with: "")) \(whenText) to \(slot.title)"
        } else {
            let list = values.sorted { $0.key < $1.key }.map { "\($0.key) \(ValueStyle.number.full($0.value))" }
            let article = canonical.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
            summary = "\(article) \(canonical) event (\(list.joined(separator: ", "))) \(whenText) to \(slot.title)"
        }
        if let repeats {
            return .success(OutsideEvent(index: index, event: nil,
                                         rule: RecurringEvent(kind: canonical, values: values, first: when, every: repeats), summary: summary))
        }
        return .success(OutsideEvent(index: index, event: Event(time: when, kind: canonical, values: values), rule: nil, summary: summary))
    }

    /// "deposit and withdraw", "a, b and c".
    nonisolated static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Moves the cursor as the command bar's `goto` does, and says where it went once the engine
    /// has looked.
    public func goto(_ text: String) async -> Reply {
        let numbers = slots.indices.contains(focusedIndex) ? focused.writing.numbers : .commaPoint
        let action: CommandBarAction
        do {
            action = try CommandBarParser.parse("goto " + text, numbers: numbers)
        } catch let error as CommandBarError {
            if case .badGoto = error { return .failed(error.description) }
            return .failed(CommandBarError.badGoto(text).description)
        } catch {
            return .failed(String(describing: error))
        }
        return await replying(fallback: "Cursor at " + DateText.monthYear(cursor)) { _ = try perform(action) }
    }

    /// Adds a library model, as the command bar's `add` does.
    public func addModel(named name: String, toSlot key: Int?) async -> Reply {
        await replying(fallback: "Added \(name)") { _ = try perform(.addModel(name, slot: key)) }
    }

    /// Asks to remove a slot in the Slot tab, as the command bar's `remove` does. The panel asks first.
    public func removeSlot(named text: String) async -> Reply {
        await replying(fallback: "Confirm in the Slot tab to remove \(text).") { _ = try perform(.removeSlot(text)) }
    }

    public func undoForReply() async -> Reply {
        guard canUndo else { return .failed("There's nothing to undo.") }
        return await replying(fallback: "Undone.") { undo() }
    }

    public func redoForReply() async -> Reply {
        guard canRedo else { return .failed("There's nothing to redo.") }
        return await replying(fallback: "Redone.") { redo() }
    }

    /// Runs something the panel does and answers with what it said, once the engine has caught up.
    func replying(fallback: String, _ action: () throws -> Void) async -> Reply {
        let before = messageCount
        do {
            try action()
        } catch let error as CommandBarError {
            return .failed(error.description)
        } catch {
            return .failed(String(describing: error))
        }
        await waitUntilIdle()
        guard messageCount != before, let message else { return .done(fallback) }
        return Reply(ok: !messageIsError, message: message)
    }
}
