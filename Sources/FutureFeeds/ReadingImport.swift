import Foundation
import FutureDocument
import FutureEngine

/// A table of readings to import, from a file or the clipboard (docs/UI.md, 5.10; docs/DESIGN.md,
/// 15.3): CSV, text copied from a spreadsheet (tabs), or a European export (semicolons, decimal
/// commas). It guesses which column holds dates and which hold numbers, and turns a date column
/// and a value column into readings.
public struct ImportTable: Sendable {
    /// The columns' names, or "Column 1", "Column 2"… when the first line was already data.
    public let columns: [String]
    public let rows: [[String]]
    /// Whether the first line named the columns.
    public let hasHeader: Bool
    public let separator: Character
    /// The column that looks most like dates, if any does.
    public let dateColumn: Int?
    /// Columns other than the dates that are mostly numbers, in order.
    public let valueColumns: [Int]

    /// The most rows a table may have, so a huge file can't stall the app.
    public static let rowLimit = 1_000_000

    public init(_ text: String) throws(FeedError) {
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard let first = lines.first else { throw FeedError("There's nothing to import: the text is empty.") }
        separator = Self.separator(in: String(first))
        let kept = lines.joined(separator: "\n")
        var all = CSVReadings.table(kept, separator: separator)
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.allSatisfy(\.isEmpty) }
        guard let header = all.first else { throw FeedError("There's nothing to import: the text is empty.") }
        guard all.count <= Self.rowLimit + 1 else {
            throw FeedError("That's more than \(Self.rowLimit.formatted()) rows. Split it, or keep it in a SQLite database.")
        }
        // A first line with a date or a number in it is data, not names.
        hasHeader = !header.contains { Self.date($0, dayFirst: false) != nil || Self.number($0, decimalComma: false) != nil }
        if hasHeader {
            columns = header.enumerated().map { $0.element.isEmpty ? "Column \($0.offset + 1)" : $0.element }
            all.removeFirst()
        } else {
            columns = (1...max(1, all.map(\.count).max() ?? 1)).map { "Column \($0)" }
        }
        rows = all
        guard !rows.isEmpty else { throw FeedError("There are no rows under the column names.") }
        guard columns.count >= 2 else {
            throw FeedError("Readings need two columns, a date and a value. This has one. Is it separated by something other than commas, tabs or semicolons?")
        }

        (dateColumn, valueColumns) = Self.guessColumns(columns, rows)
    }

    /// The date column: the one whose cells are most often dates, at least half of them, with a
    /// name like "date" winning a tie. Then the other columns that are mostly numbers.
    static func guessColumns(_ columns: [String], _ rows: [[String]]) -> (date: Int?, values: [Int]) {
        let sample = Array(rows.prefix(500))
        func share(_ column: Int, _ test: (String) -> Bool) -> Double {
            let cells = sample.compactMap { $0.indices.contains(column) ? $0[column] : nil }.filter { !$0.isEmpty }
            return cells.isEmpty ? 0 : Double(cells.filter(test).count) / Double(cells.count)
        }
        func isDate(_ cell: String) -> Bool { date(cell, dayFirst: true) != nil || date(cell, dayFirst: false) != nil }
        // Dates written with marks or words first: a column of amounts like 1500 also reads as years.
        var dateShares = columns.indices.map { column in share(column) { isDate($0) && $0.contains { !$0.isNumber } } }
        if !dateShares.contains(where: { $0 >= 0.5 }) { dateShares = columns.indices.map { column in share(column, isDate) } }
        let named = Set(columns.indices.filter { index in
            let name = columns[index].lowercased()
            return ["date", "time", "day", "month", "period", "when", "posted"].contains { name.contains($0) }
        })
        let found = columns.indices.filter { dateShares[$0] >= 0.5 }
            .max { (dateShares[$0], named.contains($0) ? 1 : 0, -$0) < (dateShares[$1], named.contains($1) ? 1 : 0, -$1) }
        let values = columns.indices.filter { column in
            column != found && share(column) { number($0, decimalComma: false) != nil || number($0, decimalComma: true) != nil } >= 0.5
        }
        return (found, values)
    }

    /// Commas, unless the first line has tabs (copied from a spreadsheet) or more semicolons than commas.
    static func separator(in line: String) -> Character {
        if line.contains("\t") { return "\t" }
        let semicolons = line.filter { $0 == ";" }.count
        return semicolons > 0 && semicolons >= line.filter({ $0 == "," }).count ? ";" : ","
    }

    /// What became of a table's rows.
    public struct Outcome: Sendable, Equatable {
        /// In time order, one per date: a later row for the same date replaces an earlier one.
        public var readings: [Reading]
        /// Rows without a date or a value that could be read.
        public var skipped: Int
        /// Rows whose date another row already had.
        public var repeated: Int
    }

    /// Readings of `variable` from a date column and a value column.
    public func readings(date: Int, value: Int, variable: String) -> Outcome {
        let dates = rows.compactMap { $0.indices.contains(date) ? $0[date] : nil }
        let dayFirst = Self.isDayFirst(dates)
        let values = rows.compactMap { $0.indices.contains(value) ? $0[value] : nil }
        let decimalComma = Self.hasDecimalComma(values, separator: separator)
        var byTime: [Date: Double] = [:]
        var skipped = 0, repeated = 0
        for row in rows {
            guard row.indices.contains(date), row.indices.contains(value),
                  let time = Self.date(row[date], dayFirst: dayFirst),
                  let number = Self.number(row[value], decimalComma: decimalComma) else {
                skipped += 1
                continue
            }
            if byTime.updateValue(number, forKey: time) != nil { repeated += 1 }
        }
        let readings = byTime.keys.sorted().map { Reading(time: $0, variable: variable, value: byTime[$0]!) }
        return Outcome(readings: readings, skipped: skipped, repeated: repeated)
    }

    // MARK: Cells

    /// A date as sources and spreadsheets write it. With `dayFirst`, `05/09/2026` is 5 September;
    /// `05.09.2026` is always day first, as Europeans write it.
    static func date(_ text: String, dayFirst: Bool) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for mark in [".", "/"] where trimmed.contains(mark) {
            let parts = trimmed.prefix { $0 != " " && $0 != "T" }.split(separator: Character(mark))
            guard parts.count == 3, parts[2].count == 4 || parts[2].count == 2,
                  let first = Int(parts[0]), let second = Int(parts[1]), var year = Int(parts[2]) else { continue }
            if parts[2].count == 2 { year += year < 70 ? 2000 : 1900 }
            let (day, month) = mark == "." || dayFirst ? (first, second) : (second, first)
            guard (1...12).contains(month), (1...CivilDate.daysInMonth(year: year, month: month)).contains(day) else { return nil }
            return CivilDate.date(year: year, month: month, day: day)
        }
        // A plain number of 4 digits is a year; other plain numbers aren't dates here.
        if trimmed.allSatisfy(\.isNumber), trimmed.count != 4, trimmed.count != 6, trimmed.count != 8 { return nil }
        return FeedDate.parse(trimmed)
    }

    /// Whether slashed dates put the day first: some first part is above 12.
    static func isDayFirst(_ cells: [String]) -> Bool {
        cells.contains { cell in
            let parts = cell.split(separator: "/")
            return parts.count == 3 && (Int(parts[0]) ?? 0) > 12
        }
    }

    /// A number as spreadsheets and statements write it: `1,234.56`, `$1,234.56`, `-£12.00`,
    /// `(12.00)` for a negative, `1 234,56 €`, `12%` is 12. With `decimalComma`, `1.234,56`.
    static func number(_ text: String, decimalComma: Bool) -> Double? {
        var cell = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        guard !cell.isEmpty else { return nil }
        var negative = false
        if cell.hasPrefix("("), cell.hasSuffix(")") {
            negative = true
            cell = String(cell.dropFirst().dropLast())
        }
        // Currency symbols, codes and units at either end.
        let numeric = Set("0123456789.,-+")
        while let first = cell.first, !numeric.contains(first) { cell.removeFirst() }
        while let last = cell.last, !last.isNumber, last != "." { cell.removeLast() }
        if cell.hasPrefix("-") {
            negative.toggle()
            cell.removeFirst()
            while let first = cell.first, !numeric.contains(first) { cell.removeFirst() }
        }
        cell = cell.filter { $0 != " " && $0 != "\u{00A0}" && $0 != "\u{202F}" && $0 != "'" && $0 != "’" }
        guard cell.contains(where: \.isNumber), cell.allSatisfy({ numeric.contains($0) || "eE".contains($0) }) else { return nil }
        if decimalComma {
            cell = cell.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            cell = cell.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Double(cell), value.isFinite else { return nil }
        return negative ? -value : value
    }

    /// Whether a column's numbers use a comma for decimals: `12,5` or `1.234,56`, or a table split
    /// by semicolons whose numbers have commas but no points.
    static func hasDecimalComma(_ cells: [String], separator: Character) -> Bool {
        var commaDecimals = 0, pointDecimals = 0
        for cell in cells.prefix(500) {
            let digits = cell.filter { $0.isNumber || $0 == "," || $0 == "." }
            guard let last = digits.lastIndex(where: { $0 == "," || $0 == "." }) else { continue }
            let after = digits[digits.index(after: last)...].count
            let mark = digits[last]
            // Three digits after the only mark could be thousands either way: it doesn't tell.
            let marks = digits.filter { $0 == "," || $0 == "." }
            if after == 3, Set(marks).count == 1 { continue }
            if mark == "," { commaDecimals += 1 } else { pointDecimals += 1 }
        }
        if commaDecimals != pointDecimals { return commaDecimals > pointDecimals }
        return separator == ";" && cells.contains { $0.contains(",") } && !cells.contains { $0.contains(".") }
    }
}
