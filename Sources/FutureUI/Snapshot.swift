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
        public var points: [Point]
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
        var lines = [(["Date"] + slots.map { "\($0.name) (\($0.variable))" }).joined(separator: "\t")]
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
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SnapshotData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
