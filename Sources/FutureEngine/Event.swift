import Foundation

/// Something that happens at a moment in time and changes a model: a deposit, a rate change,
/// a market shock, or an event another model generated.
public struct Event: Hashable, Sendable, Codable, Identifiable {
    public enum Source: Hashable, Sendable, Codable {
        /// Added by a person.
        case authored
        /// Produced by a recurring rule.
        case recurring(rule: UUID)
        /// Emitted by the model in the named slot.
        case generated(slot: String)
    }

    /// Kind used for parameter changes. Values map parameter names to their new values.
    public static let setKind = "set"

    public var id: UUID
    public var time: Date
    public var kind: String
    public var values: [String: Double]
    public var source: Source

    public init(id: UUID = UUID(), time: Date, kind: String, values: [String: Double] = [:], source: Source = .authored) {
        self.id = id
        self.time = time
        self.kind = kind
        self.values = values
        self.source = source
    }

    /// A parameter change, e.g. `Event.set(["rate": 0.04], at: june)`.
    public static func set(_ parameters: [String: Double], at time: Date, id: UUID = UUID()) -> Event {
        Event(id: id, time: time, kind: setKind, values: parameters)
    }

    /// Name of the slot that generated this event, if any.
    public var originSlot: String? {
        if case .generated(let slot) = source { return slot }
        return nil
    }

    /// Deterministic order for events inside one step: time, then kind, then id.
    static func stepOrder(_ a: Event, _ b: Event) -> Bool {
        if a.time != b.time { return a.time < b.time }
        if a.kind != b.kind { return a.kind < b.kind }
        return a.id.uuidString < b.id.uuidString
    }
}

/// A rule that produces events on a schedule, e.g. a deposit on the 1st of every month.
public struct RecurringEvent: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: String
    public var values: [String: Double]
    public var first: Date
    public var every: StepRate
    /// Last allowed time, inclusive.
    public var until: Date?
    /// Maximum number of occurrences.
    public var count: Int?

    public init(id: UUID = UUID(), kind: String, values: [String: Double] = [:], first: Date,
                every: StepRate, until: Date? = nil, count: Int? = nil) {
        self.id = id
        self.kind = kind
        self.values = values
        self.first = first
        self.every = every
        self.until = until
        self.count = count
    }

    /// The occurrences that fall inside `window`.
    public func occurrences(in window: StepWindow, calendar: Calendar = .utcGregorian) -> [Event] {
        guard every.isValid, window.upper >= first else { return [] }
        let grid = TimeGrid(start: first, rate: every, calendar: calendar)
        var index = grid.lastIndex(atOrBefore: window.lower) ?? 0
        var result: [Event] = []
        while true {
            if let count, index >= count { break }
            let time = grid.point(index)
            if time > window.upper { break }
            if let until, time > until { break }
            if window.contains(time) {
                result.append(Event(id: UUID.derived(from: id, index: UInt64(index)), time: time,
                                    kind: kind, values: values, source: .recurring(rule: id)))
            }
            index += 1
        }
        return result
    }
}

/// A real-world observation of one variable, used to correct a model's state.
public struct Reading: Hashable, Sendable, Codable {
    public var time: Date
    public var variable: String
    public var value: Double

    public init(time: Date, variable: String, value: Double) {
        self.time = time
        self.variable = variable
        self.value = value
    }
}

extension UUID {
    /// A stable UUID derived from another UUID and an index, so recomputed events keep their IDs.
    static func derived(from base: UUID, index: UInt64) -> UUID {
        var bytes = base.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            var mixed = splitMix(index &+ 0x9E37_79B9_7F4A_7C15)
            for i in 8..<16 {
                raw[i] ^= UInt8(truncatingIfNeeded: mixed)
                mixed >>= 8
            }
        }
        return UUID(uuid: bytes)
    }

    /// A stable UUID built from two numbers.
    static func deterministic(_ a: UInt64, _ b: UInt64) -> UUID {
        let hi = splitMix(a), lo = splitMix(b ^ hi)
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<8 { raw[i] = UInt8(truncatingIfNeeded: hi >> (8 * UInt64(i))) }
            for i in 0..<8 { raw[8 + i] = UInt8(truncatingIfNeeded: lo >> (8 * UInt64(i))) }
        }
        return UUID(uuid: bytes)
    }
}

func splitMix(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}
