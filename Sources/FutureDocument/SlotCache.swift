import Foundation
import FutureEngine

/// A slot's computed results in `cache/` (docs/DESIGN.md, 15.5).
///
/// The first line is a JSON header. The numbers follow as little-endian doubles, starting on an
/// 8-byte boundary: the values (a row per point), the checkpoints' indices, their states, and the
/// state at the last point. The generated events come last, as JSON.
public enum SlotCache {
    /// The file format's version. Raise it when the layout changes.
    public static let formatVersion = 1
    public static let fileExtension = "etfcache"

    public struct Header: Codable, Sendable, Equatable {
        public var format: Int
        public var engine: Int
        public var fingerprint: String
        public var slot: String
        public var columns: [String]
        public var count: Int
        public var stateWidth: Int
        public var checkpoints: Int
        public var secondsPerStep: Double
        /// Where the numbers start, in bytes from the start of the file.
        public var numbersOffset: Int
        public var eventsLength: Int
        /// When it was written, for people looking at the file.
        public var written: String
    }

    public struct Mistake: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func data(_ history: SlotHistory, slot: String, fingerprint: String, written: Date = Date()) throws -> Data {
        guard history.isWellFormed else { throw Mistake(message: "The results don't fit together.") }
        let events = try encoder.encode(history.generated.map(SavedEvent.init))
        var header = Header(format: formatVersion, engine: Scenario.engineVersion, fingerprint: fingerprint, slot: slot,
                            columns: history.columns, count: history.count, stateWidth: history.stateWidth,
                            checkpoints: history.checkpointIndices.count, secondsPerStep: history.secondsPerStep,
                            numbersOffset: 0, eventsLength: events.count, written: FileDate.text(written))
        // The header's length decides where the numbers start, and says so itself: settle it in two passes.
        var headerData = Data()
        for _ in 0..<3 {
            headerData = try encoder.encode(header)
            let length = headerData.count + 1
            let padded = (length + 7) / 8 * 8
            if header.numbersOffset == padded { break }
            header.numbersOffset = padded
        }
        headerData = try encoder.encode(header)
        var data = headerData
        data.append(contentsOf: Array(repeating: UInt8(ascii: " "), count: header.numbersOffset - headerData.count - 1))
        data.append(UInt8(ascii: "\n"))
        precondition(data.count == header.numbersOffset)
        append(history.values, to: &data)
        append(history.checkpointIndices.map(Double.init), to: &data)
        append(history.checkpointStates, to: &data)
        append(history.currentState, to: &data)
        data.append(events)
        return data
    }

    /// Reads just the header, without the rest of the file.
    public static func header(at url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = try handle.read(upToCount: 64 * 1024) ?? Data()
        guard let newline = start.firstIndex(of: UInt8(ascii: "\n")) else { throw Mistake(message: "No header.") }
        return try decoder.decode(Header.self, from: start[..<newline])
    }

    /// The results in a cache file, when it was written for this fingerprint by this engine.
    public static func history(at url: URL, fingerprint: String) throws -> SlotHistory? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { throw Mistake(message: "No header.") }
        let header = try decoder.decode(Header.self, from: data[..<newline])
        guard header.format == formatVersion, header.engine == Scenario.engineVersion, header.fingerprint == fingerprint else {
            return nil
        }
        let width = header.columns.count
        let counts = [header.count * width, header.checkpoints, header.checkpoints * header.stateWidth, header.stateWidth]
        let numbersLength = counts.reduce(0, +) * 8
        guard header.numbersOffset + numbersLength + header.eventsLength == data.count else {
            throw Mistake(message: "The file is the wrong length.")
        }
        var offset = header.numbersOffset
        func doubles(_ count: Int) -> [Double] {
            defer { offset += count * 8 }
            return read(data, at: offset, count: count)
        }
        let values = doubles(counts[0])
        let indices = doubles(counts[1])
        let states = doubles(counts[2])
        let current = doubles(counts[3])
        let events = try decoder.decode([SavedEvent].self, from: data[offset..<(offset + header.eventsLength)])
        guard indices.allSatisfy({ $0 >= 0 && $0 < Double(header.count) && $0 == $0.rounded() }) else {
            throw Mistake(message: "The checkpoints are out of range.")
        }
        let history = SlotHistory(columns: header.columns, count: header.count, values: values, stateWidth: header.stateWidth,
                                  checkpointIndices: indices.map { Int($0) }, checkpointStates: states, currentState: current,
                                  generated: events.map(\.event), secondsPerStep: header.secondsPerStep)
        guard history.isWellFormed else { throw Mistake(message: "The results don't fit together.") }
        return history
    }

    // MARK: Numbers and events

    private static func append(_ numbers: [Double], to data: inout Data) {
        #if _endian(little)
        numbers.withUnsafeBytes { data.append(contentsOf: $0) }
        #else
        for number in numbers { withUnsafeBytes(of: number.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        #endif
    }

    private static func read(_ data: Data, at offset: Int, count: Int) -> [Double] {
        var numbers = [Double](repeating: 0, count: count)
        numbers.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                target.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + count * 8)]))
            }
        }
        #if !_endian(little)
        numbers = numbers.map { Double(bitPattern: UInt64(littleEndian: $0.bitPattern)) }
        #endif
        return numbers
    }

    /// Generated events as JSON. Numbers are written as exact text (`FileNumber`), since JSON
    /// writers don't all keep every digit. The time is in seconds since 2001, as `Date` keeps it.
    struct SavedEvent: Codable {
        var id: UUID
        var t: String
        var k: String
        var v: [String: String]
        var s: String?

        init(_ event: Event) {
            id = event.id
            t = FileNumber.text(event.time.timeIntervalSinceReferenceDate)
            k = event.kind
            v = event.values.mapValues { FileNumber.text($0) }
            s = event.originSlot
        }

        var event: Event {
            Event(id: id, time: Date(timeIntervalSinceReferenceDate: FileNumber.parse(t) ?? 0), kind: k,
                  values: v.compactMapValues { FileNumber.parse($0) }, source: s.map { .generated(slot: $0) } ?? .authored)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}
