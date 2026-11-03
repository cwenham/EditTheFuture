import Foundation

/// The visible data, in a form that can be pasted as a table or into another Edit The Future window.
public struct SnapshotData: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var t: Date
        public var v: Double
    }

    public struct Slot: Codable, Equatable, Sendable {
        public var name: String
        public var variable: String
        public var color: String
        public var format: ValueFormat
        /// The currency's code, for money: "GBP". The table's numbers are plain, so its heading says it.
        public var currency: String?
        public var points: [Point]

        public init(name: String, variable: String, color: String, format: ValueFormat, currency: String? = nil,
                    points: [Point]) {
            self.name = name
            self.variable = variable
            self.color = color
            self.format = format
            self.currency = currency
            self.points = points
        }
    }

    /// Uniform type identifier for the app's own pasteboard format.
    public static let typeIdentifier = "com.editthefuture.snapshot"

    public var version = 1
    public var scenario: String
    public var createdAt: Date
    public var start: Date
    public var end: Date
    public var cursor: Date
    public var now: Date
    /// The focused slot first.
    public var slots: [Slot]

    public init(scenario: String, createdAt: Date, start: Date, end: Date, cursor: Date, now: Date, slots: [Slot]) {
        self.scenario = scenario
        self.createdAt = createdAt
        self.start = start
        self.end = end
        self.cursor = cursor
        self.now = now
        self.slots = slots
    }

    /// Tab-separated table: one row per point of the focused slot, one column per slot.
    /// Other slots show their value at or before each row's date. Numbers are plain so
    /// spreadsheets treat them as numbers.
    public func tsv() -> String {
        guard let first = slots.first else { return "" }
        // "Savings (balance, GBP)": the numbers are plain, so the heading says what money is in.
        let headings = slots.map { slot in
            let about = slot.currency.map { slot.variable + ", " + $0 } ?? slot.variable
            return "\(slot.name) (\(about))"
        }
        var lines = [(["Date"] + headings).joined(separator: "\t")]
        for point in first.points {
            var row = [DateText.iso(point.t)]
            for slot in slots {
                row.append(Self.held(slot.points, at: point.t).map(Self.plain) ?? "")
            }
            lines.append(row.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // JSON has no infinity or NaN, which values that overflowed become.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SnapshotData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(SnapshotData.self, from: data)
    }

    static func held(_ points: [Point], at date: Date) -> Double? {
        var low = 0, high = points.count - 1, found: Double?
        while low <= high {
            let mid = (low + high) / 2
            if points[mid].t <= date {
                found = points[mid].v
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    static func plain(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
