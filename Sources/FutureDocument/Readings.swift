import Foundation
import CryptoKit
import SQLite3
import FutureEngine

/// A slot's readings, loaded once and shared, so long lists aren't copied or compared
/// (docs/DESIGN.md, 15.3 and 15.4).
public final class ReadingSet: Sendable, Equatable {
    /// In time order.
    public let readings: [Reading]
    /// The variables they're readings of, in the order they first appear.
    public let variables: [String]
    /// A SHA-256 hash of the readings, for fingerprints and for telling sets apart.
    public let digest: String

    public init(_ readings: [Reading]) {
        let sorted = readings.sorted { $0.time < $1.time }
        self.readings = sorted
        var variables: [String] = []
        var seen = Set<String>()
        var hash = Fingerprint()
        for reading in sorted {
            if seen.insert(reading.variable).inserted { variables.append(reading.variable) }
            hash.add(reading.time.timeIntervalSince1970)
            hash.add(reading.variable)
            hash.add(reading.value)
        }
        self.variables = variables
        digest = hash.finish()
    }

    public static let empty = ReadingSet([])

    public static func == (a: ReadingSet, b: ReadingSet) -> Bool { a === b || a.digest == b.digest }
}

/// What reading a slot's readings found: the readings, mistakes, and copies of database readings to
/// keep in the scenario folder.
public struct LoadedReadings: Sendable {
    public var set: ReadingSet
    /// What each source gave, in the order of the sources.
    public var parts: [ReadingSet]
    public var problems: [String]
    /// CSV copies of what was read from databases, by their path in the scenario folder.
    public var copies: [String: String]
}

public enum ReadingLoader {
    /// How long a database query may run.
    public static let queryTimeLimit: TimeInterval = 10

    /// Reads every source of a slot's readings. `folder` is the scenario folder; links are relative to it.
    /// `variable` is the one the slot's graph shows, which feeds without `into` are readings of.
    public static func load(_ sources: [ReadingSource], slot: String, folder: URL?, variable: String? = nil) -> LoadedReadings {
        var parts: [ReadingSet] = []
        var problems: [String] = []
        var copies: [String: String] = [:]
        for source in sources {
            var readings: [Reading] = []
            defer { parts.append(ReadingSet(readings)) }
            switch source {
            case .inline(let csv):
                do {
                    readings += try CSVReadings.parse(csv)
                } catch {
                    problems.append("\(slot)'s readings: \(error)")
                }
            case .csvFile(_, let path):
                guard let url = resolve(path, in: folder) else {
                    problems.append("\(slot)'s readings: \(path) can't be found until the scenario is saved.")
                    continue
                }
                do {
                    readings += try CSVReadings.parse(try String(contentsOf: url, encoding: .utf8))
                } catch let error as CSVReadings.Mistake {
                    problems.append("\(path): \(error)")
                } catch {
                    problems.append("\(slot)'s readings: couldn't read \(path): \(error.localizedDescription)")
                }
            case .database(_, let path, let query):
                let copyPath = copyPath(slot: slot, database: path)
                do {
                    guard let url = resolve(path, in: folder) else { throw DatabaseReadings.Mistake("can't find it") }
                    let found = try DatabaseReadings.read(url, query: query, timeLimit: queryTimeLimit)
                    readings += found
                    copies[copyPath] = CSVReadings.text(found)
                } catch {
                    // Use the copy kept from the last time, if there is one.
                    let reason = (error as? DatabaseReadings.Mistake)?.message ?? error.localizedDescription
                    if let folder, let copy = try? String(contentsOf: folder.appendingPathComponent(copyPath), encoding: .utf8),
                       let found = try? CSVReadings.parse(copy) {
                        readings += found
                        problems.append("\(slot)'s readings: \(path): \(reason). Using the copy in \(copyPath).")
                    } else {
                        problems.append("\(slot)'s readings: \(path): \(reason).")
                    }
                }
            case .feed(let spec):
                do {
                    readings = try feedReadings(spec, slot: slot, folder: folder, variable: variable) ?? []
                } catch {
                    problems.append("\(slot)'s readings: \(spec.title): \(error)")
                }
            }
        }
        return LoadedReadings(set: ReadingSet(parts.flatMap(\.readings)), parts: parts, problems: problems, copies: copies)
    }

    /// A feed's readings from its copy in `readings/`, or nil when it hasn't been fetched yet.
    public static func feedReadings(_ spec: FeedSpec, slot: String, folder: URL?, variable: String?) throws -> [Reading]? {
        guard let into = spec.variable ?? variable, !into.isEmpty else {
            throw DatabaseReadings.Mistake("say which variable the readings are of, with into: (into: price)")
        }
        guard let folder,
              let text = try? String(contentsOf: folder.appendingPathComponent(spec.copyPath(slot: slot)), encoding: .utf8)
        else { return nil }
        return try readings(FeedCopy.parse(text), spec: spec, variable: into)
    }

    /// Points from a feed as readings of a variable, with the feed's `convert` and `scale`.
    public static func readings(_ points: [FeedPoint], spec: FeedSpec, variable: String) -> [Reading] {
        points.compactMap { point in
            let value = spec.value(point.value)
            return value.isNaN ? nil : Reading(time: point.time, variable: variable, value: value)
        }
    }

    /// Where the copy of a database's readings is kept: `readings/Kitchen-sensors.csv`.
    public static func copyPath(slot: String, database path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "readings/\(slot)-\(base).csv"
    }

    /// A link's file: relative to the scenario folder, or from the home folder with `~`.
    static func resolve(_ path: String, in folder: URL?) -> URL? {
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return folder?.appendingPathComponent(path)
    }
}

// MARK: CSV

/// Readings as CSV: the date first, then a column for each variable (docs/DESIGN.md, 15.3).
public enum CSVReadings {
    public struct Mistake: Error, CustomStringConvertible {
        public let line: Int?
        public let message: String
        public var description: String { (line.map { "line \($0): " } ?? "") + message }
    }

    public static func parse(_ text: String) throws -> [Reading] {
        let rows = records(text)
        guard let header = rows.first(where: { !$0.fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }) else {
            return []
        }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count >= 2 else {
            throw Mistake(line: header.line, message: "The first line names the columns: date, then a variable for each column.")
        }
        for name in names.dropFirst() where !isIdentifier(name) {
            throw Mistake(line: header.line, message: "“\(name)” isn't a variable's name.")
        }
        var readings: [Reading] = []
        for row in rows where row.line > header.line {
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            let dateText = row.fields[0].trimmingCharacters(in: .whitespaces)
            guard let time = FileDate.parse(dateText, spaces: true) else {
                throw Mistake(line: row.line, message: "“\(dateText)” isn't a date. Write dates like 2028-08-01.")
            }
            for (column, field) in row.fields.enumerated().dropFirst() where column < names.count {
                let text = field.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                guard let value = FileNumber.parse(text), !value.isNaN else {
                    throw Mistake(line: row.line, message: "“\(text)” isn't a number.")
                }
                readings.append(Reading(time: time, variable: names[column], value: value))
            }
        }
        return readings
    }

    /// The readings as CSV, one row per time.
    public static func text(_ readings: [Reading]) -> String {
        var variables: [String] = []
        var rows: [Date: [String: Double]] = [:]
        for reading in readings {
            if !variables.contains(reading.variable) { variables.append(reading.variable) }
            rows[reading.time, default: [:]][reading.variable] = reading.value
        }
        var lines = [(["date"] + variables).joined(separator: ",")]
        for time in rows.keys.sorted() {
            let values = rows[time]!
            lines.append(([FileDate.text(time)] + variables.map { values[$0].map { FileNumber.text($0) } ?? "" }).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV text as rows of fields, for sources that aren't readings yet (docs/DESIGN.md, 15.8).
    /// `separator` splits fields: a comma, a tab (text copied from a spreadsheet) or a semicolon.
    public static func table(_ text: String, separator: Character = ",") -> [[String]] {
        records(text, separator: separator).map(\.fields)
    }

    struct Record {
        let line: Int
        let fields: [String]
    }

    /// Splits CSV text into records, with quoted fields that may hold commas, quotes and line breaks.
    static func records(_ text: String, separator: Character = ",") -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var recordLine = 1
        var characters = text.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? characters.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character == "\n" || character == "\r\n" { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"": inQuotes = true
            case separator: fields.append(field); field = ""
            case "\n", "\r\n", "\r":
                fields.append(field)
                records.append(Record(line: recordLine, fields: fields))
                fields = []
                field = ""
                line += 1
                recordLine = line
            default: field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            records.append(Record(line: recordLine, fields: fields))
        }
        return records
    }
}

// MARK: SQLite

/// Readings read from a SQLite database through a query (docs/DESIGN.md, 15.4). The database is
/// opened read-only, `ATTACH` is refused, and a query has a time limit, so a query can only read
/// that one database.
public enum DatabaseReadings {
    public struct Mistake: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public static func read(_ url: URL, query: String, timeLimit: TimeInterval) throws -> [Reading] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Mistake("can't find it") }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open it"
            sqlite3_close(handle)
            throw Mistake(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
            switch action {
            case SQLITE_ATTACH, SQLITE_DETACH, SQLITE_PRAGMA: return SQLITE_DENY
            default: return SQLITE_OK
            }
        }, nil)
        let deadline = Deadline(DispatchTime.now().uptimeNanoseconds + UInt64(timeLimit * 1e9))
        let context = Unmanaged.passRetained(deadline)
        defer { context.release() }
        sqlite3_progress_handler(db, 10_000, { pointer in
            guard let pointer else { return 0 }
            let deadline = Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue()
            return DispatchTime.now().uptimeNanoseconds > deadline.nanoseconds ? 1 : 0
        }, context.toOpaque())

        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepared = query.withCString { sqlite3_prepare_v2(db, $0, -1, &statement, &tail) }
        guard prepared == SQLITE_OK, let statement else {
            throw Mistake("the query has a mistake: " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty {
            throw Mistake("the sql block can hold only one query")
        }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw Mistake("the query can only read") }
        let columns = Int(sqlite3_column_count(statement))
        let names = (0..<columns).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        guard columns >= 2, names[0].lowercased() == "date" else {
            throw Mistake("the query's first column must be the date (… as date), then a column for each variable")
        }
        for name in names.dropFirst() where !isIdentifier(name) {
            throw Mistake("“\(name)” isn't a variable's name; rename the column with as")
        }

        var readings: [Reading] = []
        var row = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                if step == SQLITE_INTERRUPT { throw Mistake("the query took longer than \(Int(timeLimit)) seconds") }
                throw Mistake(String(cString: sqlite3_errmsg(db)))
            }
            row += 1
            let time: Date
            switch sqlite3_column_type(statement, 0) {
            case SQLITE_INTEGER, SQLITE_FLOAT:
                time = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            case SQLITE_TEXT:
                let text = String(cString: sqlite3_column_text(statement, 0))
                guard let date = FileDate.parse(text, spaces: true) else {
                    throw Mistake("row \(row): “\(text)” isn't a date; write ISO text or seconds since 1970")
                }
                time = date
            default:
                continue  // no date, no reading
            }
            for column in 1..<columns {
                let index = Int32(column)
                let value: Double
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER, SQLITE_FLOAT:
                    value = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    let text = String(cString: sqlite3_column_text(statement, index))
                    guard let number = FileNumber.parse(text) else { throw Mistake("row \(row): “\(text)” isn't a number") }
                    value = number
                default:
                    continue  // null: no reading
                }
                guard !value.isNaN else { continue }
                readings.append(Reading(time: time, variable: names[column], value: value))
            }
        }
        return readings
    }

    private final class Deadline {
        let nanoseconds: UInt64
        init(_ nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    }
}

// MARK: Fingerprints

/// A SHA-256 hash built from parts, each marked with its length so parts can't run together.
public struct Fingerprint: Sendable {
    private var hasher = SHA256()

    public init() {}

    public mutating func add(_ text: String) {
        let data = Data(text.utf8)
        add(UInt64(data.count))
        hasher.update(data: data)
    }

    public mutating func add(_ number: Double) { add(number.bitPattern) }

    public mutating func add(_ number: Int) { add(UInt64(bitPattern: Int64(number))) }

    public mutating func add(_ number: UInt64) {
        withUnsafeBytes(of: number.littleEndian) { hasher.update(bufferPointer: $0) }
    }

    public func finish() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
