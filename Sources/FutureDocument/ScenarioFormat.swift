import Foundation
import FutureEngine

/// `scenario.md` as it was read: what it says, its mistakes, and where each part is, so writing it
/// back can keep everything that didn't change (docs/DESIGN.md, 15.2).
public struct ParsedScenario: Sendable {
    public let file: ScenarioFile
    public let problems: [FileProblem]
    /// The text as it was read.
    public let text: String
    let lines: [String]
    let lineEnding: String
    let endsWithNewline: Bool
    let layout: Layout
}

/// Reads and writes `scenario.md` (docs/DESIGN.md, 15.2).
public enum ScenarioFormat {
    public static let fileName = "scenario.md"

    /// Why a scenario can't be opened at all.
    public struct Unreadable: Error, CustomStringConvertible {
        public let line: Int?
        public let message: String
        public var description: String { (line.map { "Line \($0): " } ?? "") + message }
    }

    // MARK: Reading

    public static func parse(_ text: String) throws -> ParsedScenario {
        var reader = Reader(text: text)
        return try reader.read()
    }

    // MARK: Writing

    /// The text for `file`. With `original`, the text it was read from is kept wherever it still
    /// says the same thing: notes, other headings, and each part of a slot that didn't change.
    public static func text(for file: ScenarioFile, over original: ParsedScenario? = nil) -> String {
        guard let original else { return fresh(file) }
        var writer = Writer(file: file, original: original)
        return writer.write()
    }

    /// A whole file in one consistent form.
    static func fresh(_ file: ScenarioFile) -> String {
        var out = [heading(file, extras: [])]
        for slot in file.slots.sorted(by: { $0.position < $1.position }) {
            out.append("")
            out += slotLines(slot)
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func slotLines(_ slot: SlotFile) -> [String] {
        var out = [slotHeading(slot, extras: [])]
        if !slot.source.isEmpty || slot.problem == nil {
            out.append("")
            out += modelLines(slot)
        }
        for kind in PartKind.allCases {
            let items = partItems(kind, slot)
            guard !items.isEmpty else { continue }
            out.append("")
            out.append("### " + kind.title)
            out += items
        }
        return out
    }

    // MARK: Canonical lines

    static func heading(_ file: ScenarioFile, extras: [Setting]) -> String {
        var settings = [Setting(key: "start", value: FileDate.text(file.start))]
        if let seed = file.seed { settings.append(Setting(key: "seed", value: "0x" + String(seed, radix: 16, uppercase: true))) }
        if let currency = file.currency { settings.append(Setting(key: "currency", value: currency.code)) }
        if let rates = file.rates { settings.append(Setting(key: "rates", value: rates.rawValue)) }
        if let numbers = file.numbers { settings.append(Setting(key: "numbers", value: numbers.rawValue)) }
        settings += extras
        return "# " + file.name + " [" + settings.map(\.text).joined(separator: ", ") + "]"
    }

    static func slotHeading(_ slot: SlotFile, extras: [Setting]) -> String {
        var settings: [Setting] = []
        if !slot.model.isEmpty { settings.append(Setting(key: slot.model, value: nil)) }
        if let shows = slot.shows { settings.append(Setting(key: "shows", value: shows)) }
        if let format = slot.format { settings.append(Setting(key: "as", value: format)) }
        if let currency = slot.currency { settings.append(Setting(key: "currency", value: currency.code)) }
        if let color = slot.color { settings.append(Setting(key: "color", value: color)) }
        settings += extras
        let base = "## \(slot.position + 1). \(slot.name)"
        return settings.isEmpty ? base : base + " [" + settings.map(\.text).joined(separator: ", ") + "]"
    }

    /// The model's fenced block. The fence is longer than any run of backticks in the text.
    static func modelLines(_ slot: SlotFile) -> [String] {
        var longest = 2
        for line in slot.source.split(separator: "\n", omittingEmptySubsequences: false) {
            let run = line.drop(while: { $0 == " " }).prefix(while: { $0 == "`" }).count
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        return [fence + slot.language.rawValue] + slot.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            + [fence]
    }

    static func partItems(_ kind: PartKind, _ slot: SlotFile) -> [String] {
        switch kind {
        case .values:
            return slot.values.keys.sorted().map { valueLine($0, slot) }
        case .events:
            return eventEntries(slot).map { "- " + $0.text }
        case .readings:
            return readingLines(slot.readings)
        }
    }

    static func valueLine(_ name: String, _ slot: SlotFile) -> String {
        "- \(name): " + FileNumber.text(slot.values[name] ?? .nan, percent: slot.percentNames.contains(name))
    }

    struct EventEntry {
        let time: Date
        /// The line as the app writes it.
        let text: String
        /// The same with plain numbers, which identifies the event whatever its formatting.
        let identity: String
    }

    /// Events and rules in date order.
    static func eventEntries(_ slot: SlotFile) -> [EventEntry] {
        let events = slot.events.map {
            EventEntry(time: $0.time, text: EventLine.text($0, percent: slot.percentNames), identity: EventLine.text($0, percent: []))
        }
        let rules = slot.rules.map {
            EventEntry(time: $0.first, text: EventLine.text($0, percent: slot.percentNames), identity: EventLine.text($0, percent: []))
        }
        return (events + rules).sorted { $0.time != $1.time ? $0.time < $1.time : $0.identity < $1.identity }
    }

    static func readingLines(_ sources: [ReadingSource]) -> [String] {
        var out: [String] = []
        for source in sources {
            if !out.isEmpty { out.append("") }
            switch source {
            case .inline(let csv):
                out += ["```csv"] + csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) + ["```"]
            case .csvFile(let title, let path):
                out.append("- [\(title)](\(path))")
            case .database(let title, let path, let query):
                out.append("- [\(title)](\(path))")
                out.append("")
                out += ["```sql"] + query.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) + ["```"]
            case .feed(let spec):
                // Feeds sit together, one line each.
                if out.count >= 2, out[out.count - 2].hasPrefix("- "), (try? FeedSpec.parse(line: String(out[out.count - 2].dropFirst(2)))) != nil {
                    out.removeLast()
                }
                out.append("- " + spec.line)
            }
        }
        return out
    }
}

// MARK: Layout

enum PartKind: CaseIterable, Sendable {
    case values, events, readings

    var title: String {
        switch self {
        case .values: return "Values"
        case .events: return "Events"
        case .readings: return "Readings"
        }
    }

    init?(heading: String) {
        switch heading.trimmingCharacters(in: .whitespaces).lowercased() {
        case "values", "value": self = .values
        case "events", "event": self = .events
        case "readings", "reading": self = .readings
        default: return nil
        }
    }
}

struct Layout: Sendable {
    var headingLine: Int
    /// Settings in the scenario's heading that the app doesn't know, kept as written.
    var headingExtras: [Setting]
    var sections: [Section]
}

enum Section: Sendable {
    /// Notes, other headings and slots that couldn't be read: kept as written.
    case text(Range<Int>)
    case slot(SlotLayout)
}

struct SlotLayout: Sendable {
    /// The slot's index in the file's list.
    var slot: Int
    /// The whole section, from its heading.
    var lines: Range<Int>
    /// Settings in the heading the app doesn't know, kept as written.
    var extras: [Setting]
    /// The model's block, both fences included.
    var model: Range<Int>?
    var parts: [PartKind: Part]
}

struct Part: Sendable {
    /// From its heading to the next.
    var lines: Range<Int>
    /// The lines that are items the app understands. Anything else in the part is kept.
    var items: [Int]
    /// For values, each item's name; for events, each item's identity.
    var keys: [Int: String]
}

// MARK: Reader

private struct Reader {
    let lines: [String]
    let lineEnding: String
    let endsWithNewline: Bool
    let text: String
    var problems: [FileProblem] = []

    enum Kind {
        case text
        case heading(level: Int, text: String)
        case fenceOpen(language: String, end: Int)
        case fenced
        case fenceClose
    }

    var kinds: [Kind] = []

    init(text: String) {
        self.text = text
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        self.lines = lines
    }

    mutating func read() throws -> ParsedScenario {
        classify()
        guard let headingLine = kinds.indices.first(where: {
            if case .heading(1, _) = kinds[$0] { return true }
            return false
        }), case .heading(_, let headingText) = kinds[headingLine] else {
            throw ScenarioFormat.Unreadable(line: nil, message: "The file needs a first heading with the scenario's name and start: # Home & money [start: 2022-01-01].")
        }
        let heading = try scenarioHeading(headingText, line: headingLine)
        var file = ScenarioFile(name: heading.name, start: heading.start, seed: heading.seed, currency: heading.currency,
                                rates: heading.rates, numbers: heading.numbers)
        let extras = heading.extras

        // Sections start at each level 1 or 2 heading.
        var sections: [Section] = []
        var boundaries: [Int] = []
        for index in (headingLine + 1)..<lines.count {
            if case .heading(let level, _) = kinds[index], level <= 2 { boundaries.append(index) }
        }
        let firstBoundary = boundaries.first ?? lines.count
        if firstBoundary > headingLine + 1 { sections.append(.text((headingLine + 1)..<firstBoundary)) }
        for (offset, begin) in boundaries.enumerated() {
            let end = offset + 1 < boundaries.count ? boundaries[offset + 1] : lines.count
            guard case .heading(let level, let title) = kinds[begin], level == 2,
                  let slot = slotSection(title, lines: begin..<end, file: &file) else {
                sections.append(.text(begin..<end))
                continue
            }
            sections.append(.slot(slot))
        }
        let layout = Layout(headingLine: headingLine, headingExtras: extras, sections: sections)
        return ParsedScenario(file: file, problems: problems, text: text, lines: lines, lineEnding: lineEnding,
                              endsWithNewline: endsWithNewline, layout: layout)
    }

    /// Marks headings and fenced blocks, so nothing inside a block is read as a heading.
    mutating func classify() {
        kinds = Array(repeating: .text, count: lines.count)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = Self.fence(line) {
                var end = index + 1
                while end < lines.count && !Self.closes(lines[end], fence: fence) { end += 1 }
                if end >= lines.count {
                    problems.append(FileProblem(line: index + 1, message: "This block's fence (\(fence.marker)) never closes, so the rest of the file is inside it."))
                }
                kinds[index] = .fenceOpen(language: fence.language, end: min(end, lines.count - 1))
                if index + 1 < min(end, lines.count) {
                    for inner in (index + 1)..<min(end, lines.count) { kinds[inner] = .fenced }
                }
                if end < lines.count { kinds[end] = .fenceClose }
                index = end + 1
                continue
            }
            if let heading = Self.heading(line) { kinds[index] = .heading(level: heading.level, text: heading.text) }
            index += 1
        }
    }

    struct Fence {
        let marker: String
        let language: String
    }

    static func fence(_ line: String) -> Fence? {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3, let first = body.first, first == "`" || first == "~" else { return nil }
        let marker = body.prefix(while: { $0 == first })
        guard marker.count >= 3 else { return nil }
        let info = body.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return Fence(marker: String(marker), language: language)
    }

    static func closes(_ line: String, fence: Fence) -> Bool {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3, let first = fence.marker.first else { return false }
        let run = body.prefix(while: { $0 == first })
        return run.count >= fence.marker.count && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3 else { return nil }
        let hashes = body.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of hashes isn't part of the text.
        if text.hasSuffix("#") {
            let trimmed = text.reversed().drop(while: { $0 == "#" })
            if trimmed.first == " " || trimmed.isEmpty { text = String(trimmed.reversed()).trimmingCharacters(in: .whitespaces) }
        }
        return (hashes.count, text)
    }

    struct Heading {
        var name: String
        var start: Date
        var seed: UInt64?
        var currency: Currency?
        var rates: ExchangeRateSource?
        var numbers: NumberStyle?
        var extras: [Setting]
    }

    mutating func scenarioHeading(_ text: String, line: Int) throws -> Heading {
        guard let (name, settings) = Setting.split(text) else {
            throw ScenarioFormat.Unreadable(line: line + 1, message: "The brackets in the scenario's heading don't close.")
        }
        guard !name.isEmpty else { throw ScenarioFormat.Unreadable(line: line + 1, message: "The scenario's heading needs a name.") }
        var start: Date?
        var seed: UInt64?
        var currency: Currency?
        var rates: ExchangeRateSource?
        var numbers: NumberStyle?
        var extras: [Setting] = []
        for setting in settings {
            switch (setting.key.lowercased(), setting.value) {
            case ("start", let value?):
                guard let date = FileDate.parse(value) else {
                    throw ScenarioFormat.Unreadable(line: line + 1, message: "“\(value)” isn't a start date. Write it like 2022-01-01.")
                }
                start = date
            case ("seed", let value?):
                let parsed = value.lowercased().hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
                if let parsed { seed = parsed } else {
                    problems.append(FileProblem(line: line + 1, message: "“\(value)” isn't a seed: use a whole number, like 0x5EEDF07E. The engine's own is used."))
                }
            case ("currency", let value?):
                if let found = Currency.named(value) { currency = found } else {
                    extras.append(setting)
                    problems.append(FileProblem(line: line + 1, message: "“\(value)” isn't a currency: use its code, like GBP or EUR. US dollars are used."))
                }
            case ("rates", let value?):
                if let found = ExchangeRateSource(rawValue: value.lowercased()) { rates = found } else {
                    extras.append(setting)
                    let names = ExchangeRateSource.allCases.map(\.rawValue).joined(separator: ", ")
                    problems.append(FileProblem(line: line + 1, message: "“\(value)” isn't a source of exchange rates: use \(names). The ECB's are used."))
                }
            case ("numbers", let value?):
                if value.lowercased() == "regional" { numbers = nil } else if let found = NumberStyle(rawValue: value.lowercased()) {
                    numbers = found
                } else {
                    extras.append(setting)
                    let names = (["regional"] + NumberStyle.allCases.map(\.rawValue)).joined(separator: ", ")
                    problems.append(FileProblem(line: line + 1, message: "“\(value)” isn't a way to write numbers: use \(names). Each currency's own is used."))
                }
            default:
                extras.append(setting)
                problems.append(FileProblem(line: line + 1, message: "The scenario has no setting called “\(setting.key)”. It's kept as written."))
            }
        }
        guard let start else {
            throw ScenarioFormat.Unreadable(line: line + 1, message: "The scenario's heading needs a start date: # \(name) [start: 2022-01-01].")
        }
        return Heading(name: name, start: start, seed: seed, currency: currency, rates: rates, numbers: numbers, extras: extras)
    }

    /// Reads a slot's section, or returns nil when its heading isn't a slot's (it's then kept as
    /// written, with a problem when it looked like one).
    mutating func slotSection(_ title: String, lines range: Range<Int>, file: inout ScenarioFile) -> SlotLayout? {
        let line = range.lowerBound + 1
        let digits = title.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, title.dropFirst(digits.count).first == "." else { return nil }
        let rest = title.dropFirst(digits.count + 1)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        func skip(_ message: String) -> SlotLayout? {
            problems.append(FileProblem(line: line, message: message + " The section is kept as written, but not used."))
            return nil
        }
        guard let (name, settings) = Setting.split(String(rest)) else { return skip("The brackets in this slot's heading don't close.") }
        guard let number = Int(digits), (1...Scenario.bankSize).contains(number) else {
            return skip("Slots are numbered 1 to \(Scenario.bankSize).")
        }
        guard isIdentifier(name) else {
            return skip("“\(name)” can't be a slot's name. Use one word of letters and digits, like IndexFund.")
        }
        if file.slots.contains(where: { $0.position == number - 1 }) { return skip("There's already a slot \(number).") }
        if file.slots.contains(where: { $0.name == name }) { return skip("There's already a slot called \(name).") }

        var slot = SlotFile(position: number - 1, name: name)
        var extras: [Setting] = []
        for (index, setting) in settings.enumerated() {
            switch (setting.key.lowercased(), setting.value) {
            case (_, nil) where index == 0:
                slot.model = setting.key
            case ("shows", let value?):
                slot.shows = value
            case ("as", let value?):
                if ["number", "percent", "currency", "temperature"].contains(value.lowercased()) {
                    slot.format = value.lowercased()
                } else {
                    extras.append(setting)
                    problems.append(FileProblem(line: line, message: "“\(value)” isn't a format. Use number, percent, currency or temperature.", slot: name))
                }
            case ("currency", let value?):
                if let found = Currency.named(value) { slot.currency = found } else {
                    extras.append(setting)
                    problems.append(FileProblem(line: line, message: "“\(value)” isn't a currency: use its code, like GBP or EUR. The scenario's is used.", slot: name))
                }
            case ("color", let value?), ("colour", let value?):
                let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
                if hex.count == 6, UInt32(hex, radix: 16) != nil {
                    slot.color = hex.uppercased()
                } else {
                    extras.append(setting)
                    problems.append(FileProblem(line: line, message: "“\(value)” isn't a color. Write six hex digits, like 5AA9FF.", slot: name))
                }
            default:
                extras.append(setting)
                problems.append(FileProblem(line: line, message: "A slot has no setting called “\(setting.key)”. It's kept as written.", slot: name))
            }
        }

        var layout = SlotLayout(slot: file.slots.count, lines: range, extras: extras, model: nil, parts: [:])
        // The body: parts start at level 3 headings.
        var partStarts: [(Int, PartKind?)] = []
        for index in (range.lowerBound + 1)..<range.upperBound {
            if case .heading(3, let text) = kinds[index] { partStarts.append((index, PartKind(heading: text))) }
        }
        func headingEnd(_ offset: Int) -> Int { offset + 1 < partStarts.count ? partStarts[offset + 1].0 : range.upperBound }

        // The model is the first block in a model's language, anywhere but under Readings.
        let readingsParts = partStarts.enumerated().filter { $0.element.1 == .readings }.map { $0.element.0..<headingEnd($0.offset) }
        var otherBlock = false
        for index in (range.lowerBound + 1)..<range.upperBound where !readingsParts.contains(where: { $0.contains(index) }) {
            guard case .fenceOpen(let language, let end) = kinds[index] else { continue }
            guard let modelLanguage = ModelLanguage(fence: language) else { otherBlock = true; continue }
            slot.language = modelLanguage
            slot.source = end > index + 1 ? lines[(index + 1)..<end].joined(separator: "\n") : ""
            layout.model = index..<(end + 1)
            break
        }
        // A part ends at the next heading, or at the model's block.
        func partEnd(_ offset: Int) -> Int {
            let end = headingEnd(offset)
            if let model = layout.model, model.lowerBound > partStarts[offset].0, model.lowerBound < end { return model.lowerBound }
            return end
        }
        if layout.model == nil {
            let message = otherBlock
                ? "The model's block needs a language: ```etf for a formula, ```lua or ```python for a script."
                : "This slot has no model. Add a ```etf, ```lua or ```python block under its heading."
            slot.problem = message
            problems.append(FileProblem(line: line, message: message, slot: name))
        }

        for (offset, (start, kind)) in partStarts.enumerated() {
            guard let kind else { continue }
            let partRange = start..<partEnd(offset)
            if layout.parts[kind] != nil {
                problems.append(FileProblem(line: start + 1, message: "A second ### \(kind.title) in a slot is ignored. Put them all under the first.", slot: name))
                continue
            }
            layout.parts[kind] = readPart(kind, lines: partRange, slot: &slot)
        }
        file.slots.append(slot)
        return layout
    }

    static func listItem(_ line: String) -> String? {
        let body = line.drop(while: { $0 == " " })
        guard line.count - body.count <= 3, let marker = body.first, "-*+".contains(marker),
              body.dropFirst().first == " " || body.dropFirst().first == "\t" else { return nil }
        return body.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    mutating func readPart(_ kind: PartKind, lines range: Range<Int>, slot: inout SlotFile) -> Part {
        var part = Part(lines: range, items: [], keys: [:])
        let body = (range.lowerBound + 1)..<range.upperBound
        switch kind {
        case .values:
            for index in body {
                guard case .text = kinds[index], let item = Self.listItem(lines[index]) else { continue }
                guard let colon = item.firstIndex(of: ":"),
                      case let name = item[..<colon].trimmingCharacters(in: .whitespaces), isIdentifier(name) else {
                    problems.append(FileProblem(line: index + 1, message: "A value is written - name: value, like - rate: 4.5%.", slot: slot.name))
                    continue
                }
                let valueText = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let value = FileNumber.parse(valueText) else {
                    problems.append(FileProblem(line: index + 1, message: "“\(valueText)” isn't a number.", slot: slot.name))
                    continue
                }
                if slot.values[name] != nil {
                    problems.append(FileProblem(line: index + 1, message: "\(name) has a value already; this one is used.", slot: slot.name))
                }
                slot.values[name] = value
                if valueText.hasSuffix("%") { slot.percentNames.insert(name) } else { slot.percentNames.remove(name) }
                part.items.append(index)
                part.keys[index] = name
            }
        case .events:
            var seen: [String: Int] = [:]
            for index in body {
                guard case .text = kinds[index], let item = Self.listItem(lines[index]) else { continue }
                do {
                    switch try EventLine.parse(item) {
                    case .event(let time, let kind, let values):
                        let identity = EventLine.text(Event(time: time, kind: kind, values: values), percent: [])
                        let occurrence = seen[identity, default: 0]
                        seen[identity] = occurrence + 1
                        slot.events.append(Event(id: EventLine.id(slot: slot.name, line: identity, occurrence: occurrence),
                                                 time: time, kind: kind, values: values))
                        if kind == Event.setKind { notePercents(item, values: values, slot: &slot) }
                        part.keys[index] = identity
                    case .rule(let first, let kind, let values, let every, let until, let count):
                        let rule = RecurringEvent(kind: kind, values: values, first: first, every: every, until: until, count: count)
                        let identity = EventLine.text(rule, percent: [])
                        let occurrence = seen[identity, default: 0]
                        seen[identity] = occurrence + 1
                        slot.rules.append(RecurringEvent(id: EventLine.id(slot: slot.name, line: identity, occurrence: occurrence),
                                                         kind: kind, values: values, first: first, every: every,
                                                         until: until, count: count))
                        if kind == Event.setKind { notePercents(item, values: values, slot: &slot) }
                        part.keys[index] = identity
                    }
                    part.items.append(index)
                } catch let error as LineError {
                    problems.append(FileProblem(line: index + 1, message: error.message + " The line is skipped.", slot: slot.name))
                } catch {
                    problems.append(FileProblem(line: index + 1, message: String(describing: error), slot: slot.name))
                }
            }
        case .readings:
            var index = body.lowerBound
            while index < body.upperBound {
                switch kinds[index] {
                case .fenceOpen(let language, let end):
                    let content = end > index + 1 ? lines[(index + 1)..<end].joined(separator: "\n") : ""
                    switch language.lowercased() {
                    case "csv":
                        slot.readings.append(.inline(csv: content))
                    case "sql":
                        if case .database(let title, let path, let query)? = slot.readings.last, query.isEmpty {
                            slot.readings[slot.readings.count - 1] = .database(title: title, path: path, query: content)
                        } else {
                            problems.append(FileProblem(line: index + 1, message: "A sql block belongs under a link to a database.", slot: slot.name))
                        }
                    default:
                        break
                    }
                    index = end + 1
                    continue
                case .text:
                    if let item = Self.listItem(lines[index]), !item.hasPrefix("[") || Self.link(item) == nil {
                        do {
                            if let spec = try FeedSpec.parse(line: item) { slot.readings.append(.feed(spec)) }
                        } catch let error as FeedLineError {
                            problems.append(FileProblem(line: index + 1, message: error.message + " The feed is skipped.", slot: slot.name))
                        } catch {
                            problems.append(FileProblem(line: index + 1, message: String(describing: error), slot: slot.name))
                        }
                    } else if let item = Self.listItem(lines[index]), let (title, path) = Self.link(item) {
                        let ext = (path as NSString).pathExtension.lowercased()
                        if ["sqlite", "sqlite3", "db", "db3"].contains(ext) {
                            slot.readings.append(.database(title: title, path: path, query: ""))
                        } else if ext == "csv" {
                            slot.readings.append(.csvFile(title: title, path: path))
                        } else {
                            problems.append(FileProblem(line: index + 1, message: "Readings come from .csv files or SQLite databases (.sqlite or .db).", slot: slot.name))
                        }
                    }
                default:
                    break
                }
                index += 1
            }
            for (offset, source) in slot.readings.enumerated() {
                if case .database(_, let path, let query) = source, query.isEmpty {
                    problems.append(FileProblem(line: range.lowerBound + 1, message: "\(path) needs a sql block after it, saying what to read.", slot: slot.name))
                    _ = offset
                }
            }
            part.items = Array(body)
        }
        return part
    }

    /// `set` fields written as percents are written back that way.
    func notePercents(_ item: String, values: [String: Double], slot: inout SlotFile) {
        guard let (_, settings) = Setting.split(item) else { return }
        for setting in settings where values[setting.key] != nil {
            if setting.value?.hasSuffix("%") == true { slot.percentNames.insert(setting.key) }
        }
    }

    /// `[title](path)`.
    static func link(_ text: String) -> (String, String)? {
        guard text.hasPrefix("["), let close = text.range(of: "]("), text.hasSuffix(")") else { return nil }
        let title = String(text[text.index(after: text.startIndex)..<close.lowerBound])
        let path = String(text[close.upperBound..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return (title, path.removingPercentEncoding ?? path)
    }
}

// MARK: Writer

private struct Writer {
    let file: ScenarioFile
    let original: ParsedScenario
    var lines: [String] { original.lines }

    init(file: ScenarioFile, original: ParsedScenario) {
        self.file = file
        self.original = original
    }

    mutating func write() -> String {
        let layout = original.layout
        var out = Array(lines[..<layout.headingLine])
        // A part is written again only when what it says changed, not how it's written.
        let headingSame = file.name == original.file.name && file.start == original.file.start && file.seed == original.file.seed
            && file.currency == original.file.currency && file.rates == original.file.rates && file.numbers == original.file.numbers
        out.append(headingSame ? lines[layout.headingLine] : ScenarioFormat.heading(file, extras: layout.headingExtras))

        // Match each slot in the file to a slot now: by name, then by position.
        var match: [Int: Int] = [:]  // original slot index → new slot index
        var used = Set<Int>()
        for (index, slot) in original.file.slots.enumerated() {
            if let found = file.slots.indices.first(where: { !used.contains($0) && file.slots[$0].name == slot.name }) {
                match[index] = found
                used.insert(found)
            }
        }
        for (index, slot) in original.file.slots.enumerated() where match[index] == nil {
            if let found = file.slots.indices.first(where: { !used.contains($0) && file.slots[$0].position == slot.position }) {
                match[index] = found
                used.insert(found)
            }
        }
        // New slots go before the first slot (in the file) with a later position, else after the last slot.
        var pending = file.slots.indices.filter { !used.contains($0) }.sorted { file.slots[$0].position < file.slots[$1].position }
        let lastSlotSection = layout.sections.lastIndex { if case .slot(let s) = $0 { return match[s.slot] != nil } else { return false } }

        for (sectionIndex, section) in layout.sections.enumerated() {
            switch section {
            case .text(let range):
                out += lines[range]
            case .slot(let slotLayout):
                guard let newIndex = match[slotLayout.slot] else { continue }  // removed
                let position = file.slots[newIndex].position
                while let next = pending.first, file.slots[next].position < position {
                    insert(ScenarioFormat.slotLines(file.slots[next]), into: &out, before: true)
                    pending.removeFirst()
                }
                out += slot(file.slots[newIndex], over: slotLayout, was: original.file.slots[slotLayout.slot])
                if sectionIndex == lastSlotSection {
                    for next in pending { insert(ScenarioFormat.slotLines(file.slots[next]), into: &out, before: false) }
                    pending.removeAll()
                }
            }
        }
        for next in pending { insert(ScenarioFormat.slotLines(file.slots[next]), into: &out, before: false) }

        var text = out.joined(separator: original.lineEnding)
        if original.endsWithNewline || out.isEmpty { text += original.lineEnding }
        return text
    }

    /// Adds a block, with a blank line between it and what's around it.
    func insert(_ block: [String], into out: inout [String], before: Bool) {
        if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
        out += block
        if before { out.append("") }
    }

    /// One slot's section, keeping each part that still says the same thing.
    func slot(_ new: SlotFile, over layout: SlotLayout, was old: SlotFile) -> [String] {
        var out: [String] = []
        let headingSame = new.position == old.position && new.name == old.name && new.model == old.model
            && new.shows == old.shows && new.format == old.format && new.currency == old.currency && new.color == old.color
        out.append(headingSame ? lines[layout.lines.lowerBound] : ScenarioFormat.slotHeading(new, extras: layout.extras))
        let modelSame = new.language == old.language && new.source == old.source
        let partStarts = Dictionary(uniqueKeysWithValues: layout.parts.map { ($0.value.lines.lowerBound, $0.key) })

        var index = layout.lines.lowerBound + 1
        if layout.model == nil && !new.source.isEmpty {
            out.append("")
            out += ScenarioFormat.modelLines(new)
            if index < layout.lines.upperBound, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
        }
        while index < layout.lines.upperBound {
            if let model = layout.model, index == model.lowerBound {
                out += modelSame ? Array(lines[model]) : ScenarioFormat.modelLines(new)
                index = model.upperBound
                continue
            }
            if let kind = partStarts[index], let part = layout.parts[kind] {
                out += self.part(kind, new: new, old: old, layout: part)
                index = part.lines.upperBound
                continue
            }
            out.append(lines[index])
            index += 1
        }

        // Parts the file didn't have go at the end of the section, before its blank lines.
        var trailing = 0
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty, out.count > 1 {
            out.removeLast()
            trailing += 1
        }
        for kind in PartKind.allCases where layout.parts[kind] == nil {
            let items = ScenarioFormat.partItems(kind, new)
            guard !items.isEmpty else { continue }
            out.append("")
            out.append("### " + kind.title)
            out += items
        }
        out += Array(repeating: "", count: trailing)
        return out
    }

    /// A part as it was when it says the same thing; otherwise its items written again, with the
    /// lines around them kept.
    func part(_ kind: PartKind, new: SlotFile, old: SlotFile, layout: Part) -> [String] {
        let range = layout.lines
        let unchanged: Bool
        switch kind {
        case .values:
            unchanged = new.values.count == old.values.count && new.values.allSatisfy { name, value in
                old.values[name].map { FileNumber.same($0, value) } == true
            }
        case .events:
            unchanged = ScenarioFormat.eventEntries(new).map(\.identity).sorted() == ScenarioFormat.eventEntries(old).map(\.identity).sorted()
        case .readings:
            unchanged = new.readings == old.readings
        }
        if unchanged { return Array(lines[range]) }

        let heading = lines[range.lowerBound]
        if kind == .readings {
            let items = ScenarioFormat.readingLines(new.readings)
            guard !items.isEmpty else { return [] }
            return [heading] + items + trailingBlanks(range)
        }

        let itemSet = Set(layout.items)
        let body = Array((range.lowerBound + 1)..<range.upperBound)
        let firstItem = body.first(where: { itemSet.contains($0) }) ?? body.first(where: {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? range.upperBound
        let before = body.filter { $0 < firstItem && !itemSet.contains($0) }.map { lines[$0] }
        var after = body.filter { $0 >= firstItem && !itemSet.contains($0) }.map { lines[$0] }

        var items: [String] = []
        switch kind {
        case .values:
            let kept = layout.items.compactMap { layout.keys[$0] }.filter { new.values[$0] != nil }
            let added = new.values.keys.filter { !kept.contains($0) }.sorted()
            for name in kept + added {
                if let line = layout.items.first(where: { layout.keys[$0] == name }),
                   let was = old.values[name], let now = new.values[name], FileNumber.same(was, now) {
                    items.append(lines[line])
                } else {
                    items.append(ScenarioFormat.valueLine(name, new))
                }
            }
        case .events:
            var unused = layout.items
            for entry in ScenarioFormat.eventEntries(new) {
                if let found = unused.firstIndex(where: { layout.keys[$0] == entry.identity }) {
                    items.append(lines[unused[found]])
                    unused.remove(at: found)
                } else {
                    items.append("- " + entry.text)
                }
            }
        case .readings:
            break
        }
        let meaningful = (before + after).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if items.isEmpty && !meaningful { return [] }
        // Blank lines after the items stay after them.
        var trailing: [String] = []
        while let last = after.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trailing.insert(after.removeLast(), at: 0)
        }
        return [heading] + before + items + after + trailing
    }

    func trailingBlanks(_ range: Range<Int>) -> [String] {
        var count = 0
        var index = range.upperBound - 1
        while index > range.lowerBound, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            count += 1
            index -= 1
        }
        return Array(repeating: "", count: count)
    }
}
