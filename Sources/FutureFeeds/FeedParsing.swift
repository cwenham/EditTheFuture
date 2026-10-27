import Foundation
import FutureDocument
import FutureEngine

/// Dates as sources write them.
public enum FeedDate {
    /// Reads `2026`, `2026-09`, `2026-09-05`, `2026-09-05T00:00:00.000Z`, `2026-09-05 11:03`,
    /// `202609` (year and month), `20260905`, `2026M09`, `2026Q3`, `09/05/2026` (US order), and
    /// seconds or milliseconds since 1970.
    public static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // An offset of zero, as some sources write UTC.
        for suffix in ["+00:00", "+0000"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        // All digits first: the general reader would take 202609 for the year 202,609.
        let digits = text.allSatisfy { $0.isASCII && $0.isNumber }
        if digits {
            switch text.count {
            case 4:
                return Int(text).map { CivilDate.date(year: $0, month: 1, day: 1) }
            case 6:
                guard let year = Int(text.prefix(4)), let month = Int(text.suffix(2)), (1...12).contains(month) else { return nil }
                return CivilDate.date(year: year, month: month, day: 1)
            case 8:
                guard let year = Int(text.prefix(4)), let month = Int(text.dropFirst(4).prefix(2)),
                      let day = Int(text.suffix(2)), (1...12).contains(month),
                      (1...CivilDate.daysInMonth(year: year, month: month)).contains(day) else { return nil }
                return CivilDate.date(year: year, month: month, day: day)
            case 10...13:
                guard let number = Double(text) else { return nil }
                return Date(timeIntervalSince1970: text.count >= 12 ? number / 1000 : number)
            default:
                return nil
            }
        }
        if let date = FileDate.parse(text, spaces: true) { return date }
        // 2026M09 and 2026Q3, as statistics offices write months and quarters.
        if text.count >= 6, let year = Int(text.prefix(4)) {
            let rest = text.dropFirst(4)
            if let marker = rest.first, let number = Int(rest.dropFirst()) {
                switch marker {
                case "M", "m": if (1...12).contains(number) { return CivilDate.date(year: year, month: number, day: 1) }
                case "Q", "q": if (1...4).contains(number) { return CivilDate.date(year: year, month: (number - 1) * 3 + 1, day: 1) }
                default: break
                }
            }
        }
        // 09/05/2026: month first, as US sources write it.
        let parts = text.split(separator: "/")
        if parts.count == 3, let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2].prefix(4)),
           parts[2].count >= 4, (1...12).contains(month), (1...CivilDate.daysInMonth(year: year, month: month)).contains(day) {
            return CivilDate.date(year: year, month: month, day: day)
        }
        return nil
    }

    /// `2026-09-05`, as most sources take dates.
    public static func day(_ date: Date) -> String {
        let civil = CivilDate(date)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    public static func year(_ date: Date) -> Int { CivilDate(date).year }
}

/// Numbers as sources write them: JSON numbers, or text such as `"4.79"`, `"40463151897249.19"`
/// and `"1,234.5"`. Markers of a missing value, such as `.`, `-`, `NA` and `null`, are nil.
public enum FeedNumber {
    public static func parse(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSON's true and false aren't readings.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        case let text as String:
            return parse(text)
        default:
            return nil
        }
    }

    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !missing.contains(trimmed.lowercased()) else { return nil }
        if let value = Double(trimmed) { return value.isNaN ? nil : value }
        // Thousands separators.
        let plain = trimmed.replacingOccurrences(of: ",", with: "")
        if let value = Double(plain), plain.contains(where: \.isNumber) { return value.isNaN ? nil : value }
        return nil
    }

    static let missing: Set<String> = [".", "-", "--", "na", "n/a", "nan", "null", "none", "(na)", "nd"]
}

/// Finds values in decoded JSON by a path such as `data`, `Results.series.0.data` or
/// `daily.temperature_2m_mean`.
public enum JSONPath {
    public static func value(_ path: String, in root: Any) -> Any? {
        var current: Any? = root
        for key in path.split(separator: ".") where !key.isEmpty {
            switch current {
            case let object as [String: Any]:
                current = object[String(key)]
            case let array as [Any]:
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    public static func decode(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw FeedError("The source didn't send JSON" + snippet(data))
        }
    }

    /// The start of a response, to say what came instead of what was expected.
    static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(160), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "." }
        if text.lowercased().hasPrefix("<!doctype") || text.lowercased().hasPrefix("<html") { return ": it sent a web page." }
        return ": “\(text)”."
    }
}

/// A CSV table from a source: a header row naming the columns, then rows. Lines starting with `#`
/// are notes, as NOAA writes them.
public struct FeedTable {
    public let columns: [String]
    public let rows: [[String]]

    public init(_ text: String) throws {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        let all = CSVReadings.table(kept).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = all.first else { throw FeedError("The source sent no rows.") }
        if header.first?.lowercased().hasPrefix("<") == true || header.first?.lowercased().hasPrefix("{") == true {
            throw FeedError("The source didn't send CSV" + JSONPath.snippet(Data(text.utf8)))
        }
        columns = header.map { $0.trimmingCharacters(in: .whitespaces) }
        rows = Array(all.dropFirst())
    }

    /// A column's position, by name (ignoring case and spaces at the ends), or by number from 1.
    public func column(_ name: String) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let index = columns.firstIndex(where: { $0.lowercased() == wanted }) { return index }
        if let number = Int(wanted), number >= 1, number <= columns.count { return number - 1 }
        return nil
    }

    public func field(_ row: [String], _ column: Int) -> String? {
        row.indices.contains(column) ? row[column].trimmingCharacters(in: .whitespaces) : nil
    }
}

/// Why a feed couldn't be fetched, in words for the Slot tab.
public struct FeedError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
