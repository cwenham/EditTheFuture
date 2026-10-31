import Foundation

/// What a run of the `etf` tool asks for, and how to print the answer (docs/DESIGN.md, 10.2).
public struct Invocation: Equatable, Sendable {
    public enum Output: Equatable, Sendable {
        /// The message, or the value as the panel writes it.
        case text
        /// The app's whole reply, as JSON.
        case json
        /// A value as a bare number, every digit kept.
        case number
        /// A series as CSV.
        case csv
    }

    /// nil when only the help is wanted.
    public var request: Request?
    public var output: Output
    /// Whether to start the app when it isn't running.
    public var launchesApp: Bool
    /// How long to wait for an answer, in seconds. Reading far into the future can take a while.
    public var timeout: TimeInterval

    public init(request: Request?, output: Output = .text, launchesApp: Bool = true, timeout: TimeInterval = 120) {
        self.request = request
        self.output = output
        self.launchesApp = launchesApp
        self.timeout = timeout
    }
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Reads the `etf` tool's arguments and prints the app's replies. The tool itself only connects.
public enum CommandLineTool {
    public static let usage = """
    Usage: etf COMMAND [ARGUMENTS] [OPTIONS]

    Reading (nothing changes):
      etf status                              The open scenario, its slots and the cursor
      etf slots                               Every slot, its model and what it shows
      etf value [SLOT] [VALUE] [--at DATE]    A slot's value, now or at a date
      etf data [SLOT] [VALUE] [--from DATE] [--through DATE] [--every monthly]
                                              Values as CSV, ten years from now unless asked

    Moving the panel:
      etf show [SLOT] [--at DATE]             Shows the panel, at a slot and a date
      etf goto 2035 | savings 1m | 25°C       Moves the cursor to a date, or to where a line reaches a value
      etf focus SLOT    etf now    etf toggle    etf scroll TICKS    etf zoom TICKS

    Changing the scenario:
      etf deposit SLOT AMOUNT [--at DATE] [--every monthly]
      etf withdraw SLOT AMOUNT [--at DATE] [--every monthly]
      etf set SLOT PARAMETER VALUE [--at DATE]
      etf event add SLOT KIND [NAME=VALUE ...] [--at DATE] [--every monthly]
      etf add MODEL [--slot N]                Adds a model from the library
      etf remove SLOT                         Asks in the panel before removing a slot
      etf undo    etf redo

    Copying:
      etf copy [--format all|png|pdf|tsv|data]

    Options:
      --json          Print the app's whole answer as JSON
      --number        For value: the bare number, every digit kept
      --no-launch     Don't start Edit The Future if it isn't running
      --timeout SECS  How long to wait for an answer (120)

    SLOT is a slot's name or number; quote names with spaces: "Index fund". VALUE is one of the
    slot's values, such as balance; without it, the one its graph shows. Dates are 2030, 2030-06
    or 2030-06-15, in UTC like the panel. Numbers use a point for decimals: 1200, 1,200.50, 1.5k,
    2m, 4.5%, £500, 500eur. For a percent, 4.5 means 4.5%. Repeats: daily, weekly, fortnightly,
    monthly, quarterly, yearly.
    """

    /// Options that take a value.
    static let valueOptions: Set<String> = ["at", "from", "through", "every", "format", "slot", "timeout"]
    /// Options that are just there or not.
    static let flags: Set<String> = ["json", "number", "no-launch", "help"]

    /// Reads the arguments that follow the tool's name.
    public static func parse(_ arguments: [String]) throws(UsageError) -> Invocation {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var present: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-h" { present.insert("help"); continue }
            // "-500" and "-12" are numbers, not options.
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                continue
            }
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if flags.contains(name) {
                guard value == nil else { throw UsageError("--\(name) doesn't take a value.") }
                present.insert(name)
            } else if valueOptions.contains(name) {
                if value == nil {
                    guard index < arguments.count else { throw UsageError("--\(name) needs a value.") }
                    value = arguments[index]
                    index += 1
                }
                options[name] = value
            } else {
                throw UsageError("There's no --\(name) option. Try etf help.")
            }
        }

        var timeout: TimeInterval = 120
        if let text = options["timeout"] {
            guard let seconds = Double(text), seconds > 0, seconds <= 3600 else { throw UsageError("--timeout takes seconds, up to 3600.") }
            timeout = seconds
        }
        var output: Invocation.Output = present.contains("json") ? .json : .text
        func done(_ request: Request?) -> Invocation {
            Invocation(request: request, output: output, launchesApp: !present.contains("no-launch"), timeout: timeout)
        }
        guard !present.contains("help"), let name = positionals.first?.lowercased(), name != "help" else { return done(nil) }
        var rest = Array(positionals.dropFirst())

        /// Options a command doesn't use are mistakes, not something to ignore.
        func allow(_ names: Set<String>) throws(UsageError) {
            if let extra = options.keys.filter({ !names.contains($0) && $0 != "timeout" }).sorted().first {
                throw UsageError("etf \(name) doesn't take --\(extra).")
            }
            if present.contains("number"), !names.contains("number") { throw UsageError("--number is only for etf value.") }
        }
        func most(_ count: Int, _ what: String) throws(UsageError) {
            if rest.count > count { throw UsageError("Too many arguments for etf \(name). It takes \(what).") }
        }
        func slotName(_ text: String) throws(UsageError) -> String {
            guard URLScheme.isValidTimelineName(text) else { throw UsageError("“\(text)” isn't a slot's name or number.") }
            return text
        }
        func date(_ option: String) throws(UsageError) -> PartialDate? {
            guard let text = options[option], text.lowercased() != "now" else { return nil }
            guard let date = PartialDate(text) else { throw UsageError("“\(text)” isn't a date. Use 2030, 2030-06 or 2030-06-15.") }
            return date
        }
        func every() throws(UsageError) -> Repetition? {
            guard let text = options["every"] else { return nil }
            guard let repetition = Repetition(word: text) else {
                throw UsageError("“\(text)” isn't a repeat. Use daily, weekly, fortnightly, monthly, quarterly or yearly.")
            }
            return repetition
        }
        func ticks() throws(UsageError) -> Int {
            try most(1, "a number of ticks")
            guard let text = rest.first, let value = Int(text.replacingOccurrences(of: "−", with: "-")),
                  abs(value) <= URLScheme.maxTicks else {
                throw UsageError("etf \(name) takes a number of ticks, up to \(URLScheme.maxTicks).")
            }
            return value
        }
        func amount(_ text: String) throws(UsageError) -> (Amount, String?) {
            guard let parsed = parseAmount(text) else {
                throw UsageError("“\(text)” isn't an amount. Use 500, 1,200.50, 1.5k, 4.5% or £500, with a point for decimals.")
            }
            return parsed
        }

        switch name {
        case "status":
            try allow([]); try most(0, "no arguments")
            return done(.query(.status))
        case "slots":
            try allow([]); try most(0, "no arguments")
            return done(.query(.slots))
        case "value":
            try allow(["at", "number"]); try most(2, "a slot and a value's name")
            if present.contains("number"), output != .json { output = .number }
            return done(.query(.value(slot: try rest.first.map(slotName), variable: rest.dropFirst().first, at: try date("at"))))
        case "data":
            try allow(["from", "through", "every"]); try most(2, "a slot and a value's name")
            if output != .json { output = .csv }
            let from = try date("from"), through = try date("through")
            if let from, let through, through.date < from.date { throw UsageError("--through comes before --from.") }
            return done(.query(.series(slot: try rest.first.map(slotName), variable: rest.dropFirst().first, from: from,
                                       through: through, every: try every())))
        case "show":
            try allow(["at"]); try most(1, "a slot")
            return done(.command(.show(timeline: try rest.first.map(slotName), at: try date("at"))))
        case "goto", "go":
            try allow([])
            if name == "go", rest.first?.lowercased() == "to" { rest.removeFirst() }
            guard !rest.isEmpty else { throw UsageError("etf goto needs a date or a value: etf goto 2035, etf goto savings 1m.") }
            return done(.command(.goto(rest.joined(separator: " "))))
        case "focus":
            try allow([]); try most(1, "a slot")
            guard let slot = rest.first else { throw UsageError("etf focus needs a slot's name or number.") }
            if let number = Int(slot) {
                guard (1...8).contains(number) else { throw UsageError("Slots go from 1 to 8.") }
                return done(.command(.selectSlot(number)))
            }
            return done(.command(.show(timeline: try slotName(slot), at: nil)))
        case "now":
            try allow([]); try most(0, "no arguments")
            return done(.command(.jumpToNow))
        case "toggle":
            try allow([]); try most(0, "no arguments")
            return done(.command(.toggleWindow))
        case "scroll":
            try allow([])
            return done(.command(.scroll(ticks: try ticks())))
        case "zoom":
            try allow([])
            return done(.command(.zoom(ticks: try ticks())))
        case "deposit", "withdraw":
            try allow(["at", "every"]); try most(2, "a slot and an amount")
            guard rest.count == 2 else { throw UsageError("etf \(name) needs a slot and an amount: etf \(name) savings 500.") }
            let (value, currency) = try amount(rest[1])
            guard value.value > 0, !value.isFraction else { throw UsageError("etf \(name) takes an amount of money above zero.") }
            return done(.command(.addEvent(EventRequest(slot: try slotName(rest[0]), kind: name, values: ["amount": value],
                                                        currency: currency, at: try date("at"), every: try every()))))
        case "set":
            try allow(["at", "every"]); try most(3, "a slot, a parameter and a value")
            guard rest.count == 3 else { throw UsageError("etf set needs a slot, a parameter and a value: etf set savings rate 4.5%.") }
            let (value, currency) = try amount(rest[2])
            return done(.command(.addEvent(EventRequest(slot: try slotName(rest[0]), kind: "set", values: [rest[1]: value],
                                                        currency: currency, at: try date("at"), every: try every()))))
        case "event":
            try allow(["at", "every"])
            guard rest.first?.lowercased() == "add" else { throw UsageError("Try etf event add SLOT KIND NAME=VALUE.") }
            rest.removeFirst()
            guard rest.count >= 2 else { throw UsageError("etf event add needs a slot and a kind of event: etf event add savings deposit amount=500.") }
            let slot = try slotName(rest[0])
            let kind = rest[1].lowercased()
            var values: [String: Amount] = [:]
            var currency: String?
            for item in rest.dropFirst(2) {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                // A bare amount is the event's amount: etf event add savings deposit 500.
                let (key, text) = parts.count == 2 ? (parts[0], parts[1]) : ("amount", item)
                guard !key.isEmpty, values[key] == nil else { throw UsageError("Give each value once, as NAME=VALUE.") }
                let (value, typed) = try amount(text)
                if let typed {
                    if let currency, currency.lowercased() != typed.lowercased() { throw UsageError("Give the amounts in one currency.") }
                    currency = typed
                }
                values[key] = value
            }
            guard !values.isEmpty else { throw UsageError("etf event add needs a value, such as amount=500.") }
            return done(.command(.addEvent(EventRequest(slot: slot, kind: kind, values: values, currency: currency,
                                                        at: try date("at"), every: try every()))))
        case "add":
            try allow(["slot"])
            guard !rest.isEmpty else { throw UsageError("etf add needs a model's name: etf add savings account.") }
            var slot: Int?
            if let text = options["slot"] {
                guard let number = Int(text), (1...8).contains(number) else { throw UsageError("--slot takes a number from 1 to 8.") }
                slot = number
            }
            return done(.command(.addModel(name: rest.joined(separator: " "), slot: slot)))
        case "remove":
            try allow([]); try most(1, "a slot")
            guard let slot = rest.first else { throw UsageError("etf remove needs a slot's name or number.") }
            return done(.command(.removeSlot(try slotName(slot))))
        case "undo":
            try allow([]); try most(0, "no arguments")
            return done(.command(.undo))
        case "redo":
            try allow([]); try most(0, "no arguments")
            return done(.command(.redo))
        case "copy":
            try allow(["format"]); try most(0, "no arguments")
            let format = options["format"]?.lowercased() ?? "all"
            if format == "data" { return done(.command(.copyData)) }
            guard let snapshot = SnapshotFormat(rawValue: format) else { throw UsageError("--format is all, png, pdf, tsv or data.") }
            return done(.command(.copySnapshot(snapshot)))
        default:
            throw UsageError("“\(positionals[0])” isn't a command. Try etf help.")
        }
    }

    /// `500`, `-500`, `1,200.50`, `1.5k`, `2m`, `1bn`, `4.5%` (→ 0.045), `£500`, `CA$12`, `500eur`,
    /// `500 EUR`. A point is the decimal mark; commas only group thousands, so `1,5` is refused
    /// rather than read as 15. Returns the currency as given.
    public static func parseAmount(_ text: String) -> (Amount, currency: String?)? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-"))
        var negative = false
        if rest.first == "-" || rest.first == "+" {
            negative = rest.first == "-"
            rest = rest.dropFirst()
        }
        let prefix = rest.prefix { !$0.isNumber && $0 != "." }
        rest = rest.dropFirst(prefix.count)
        if prefix.trimmingCharacters(in: .whitespaces) == "-" { return nil }
        let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "," }
        rest = rest.dropFirst(digits.count)
        let groups = digits.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1 {
            // Every group after a comma has three digits, and only the last may have a point.
            for (index, group) in groups.enumerated() where index > 0 {
                let whole = group.prefix { $0 != "." }
                guard whole.count == 3, index == groups.count - 1 || !group.contains(".") else { return nil }
            }
        }
        let plain = digits.replacingOccurrences(of: ",", with: "")
        guard plain.contains(where: \.isNumber), plain.allSatisfy({ $0.isASCII }), var value = Double(plain) else { return nil }

        var words = rest.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        var isFraction = false
        let multipliers: [String: Double] = ["k": 1e3, "m": 1e6, "b": 1e9, "bn": 1e9, "t": 1e12, "tn": 1e12]
        if let first = words.first {
            if first == "%" {
                value /= 100
                isFraction = true
                words.removeFirst()
            } else if let factor = multipliers[first] {
                value *= factor
                words.removeFirst()
            }
        }
        let typedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        let typedSuffix = words.joined(separator: " ")
        guard typedPrefix.isEmpty || typedSuffix.isEmpty else { return nil }
        let currency = typedPrefix.isEmpty ? typedSuffix : typedPrefix
        if !currency.isEmpty && (isFraction || currency.contains(where: { $0.isNumber || $0 == "%" })) { return nil }
        if negative { value = -value }
        guard value.isFinite else { return nil }
        return (Amount(value, isFraction: isFraction), currency.isEmpty ? nil : currency)
    }

    /// What to print for a reply: text for standard output, and text for standard error.
    public static func render(_ reply: Reply, as output: Invocation.Output) -> (out: String, error: String) {
        if output == .json { return (Wire.pretty(reply) + "\n", "") }
        guard reply.ok else { return ("", reply.message + "\n") }
        if let value = reply.value {
            return ((output == .number ? number(value.value) : value.text) + "\n", "")
        }
        if let series = reply.series {
            var lines = ["date," + csvField(series.variable)]
            lines.reserveCapacity(series.rows.count + 1)
            for row in series.rows { lines.append(row.date + "," + number(row.value)) }
            return (lines.joined(separator: "\n") + "\n", "")
        }
        if let slots = reply.slots {
            return (table(slots), "")
        }
        if let status = reply.status {
            let lines = [
                "\(status.name): \(status.slotCount) slot\(status.slotCount == 1 ? "" : "s"), in \(status.currency), from \(status.start)",
                "Now: \(status.now)",
                "Cursor: \(status.cursor)",
                "Focused: \(status.focused)",
            ]
            return (lines.joined(separator: "\n") + "\n", "")
        }
        return (reply.message.isEmpty ? "" : reply.message + "\n", "")
    }

    /// Every digit kept, so a script reads back the same number: "96420.12345", "1e+28", "inf", "nan".
    public static func number(_ value: Double) -> String {
        "\(value)"
    }

    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func table(_ slots: [SlotSummary]) -> String {
        let rows = slots.map { slot in
            [String(slot.number), slot.title, slot.model, slot.shows, slot.currency, slot.paused.map { "paused: " + $0 } ?? ""]
        }
        let header = ["#", "Slot", "Model", "Shows", "Currency", ""]
        let all = [header] + rows
        let widths = (0..<header.count).map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, text in
                column == row.count - 1 ? text : text.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n") + "\n"
    }
}
