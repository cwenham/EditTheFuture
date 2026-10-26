import Foundation

/// A scenario's folder, such as `Home & money.etf` (docs/DESIGN.md, 15.1): `scenario.md`, the
/// `readings` folder and the `cache` folder.
public struct ScenarioPackage: Sendable, Hashable {
    public static let fileExtension = "etf"

    public let url: URL

    public init(url: URL) {
        // Folder listings give directory URLs a trailing slash; this keeps two URLs for one folder equal.
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    /// The scenario's name from its folder: "Home & money".
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public var scenarioURL: URL { url.appendingPathComponent(ScenarioFormat.fileName) }
    public var cacheFolder: URL { url.appendingPathComponent("cache", isDirectory: true) }

    public func cacheURL(slot: String) -> URL {
        cacheFolder.appendingPathComponent(slot).appendingPathExtension(SlotCache.fileExtension)
    }

    public func readText() throws -> String {
        try String(contentsOf: scenarioURL, encoding: .utf8)
    }

    /// Reads `scenario.md` and every slot's readings. Throws when the scenario can't be opened.
    public func read() throws -> (parsed: ParsedScenario, readings: [String: LoadedReadings]) {
        let parsed = try ScenarioFormat.parse(try readText())
        var readings: [String: LoadedReadings] = [:]
        for slot in parsed.file.slots where !slot.readings.isEmpty {
            readings[slot.name] = ReadingLoader.load(slot.readings, slot: slot.name, folder: url)
        }
        return (parsed, readings)
    }

    /// Writes `scenario.md`, making the folder if it isn't there. The file is replaced in one go,
    /// so an editor watching it never sees half of it.
    public func write(text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: scenarioURL, options: .atomic)
    }

    /// Writes the copies of database readings (15.4), each only when it changed.
    public func write(copies: [String: String]) throws {
        for (path, text) in copies {
            let target = url.appendingPathComponent(path)
            if let existing = try? String(contentsOf: target, encoding: .utf8), existing == text { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target, options: .atomic)
        }
    }

    // MARK: Cache

    /// The cache files there are, by slot name.
    public func cachedSlots() -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for file in files where file.pathExtension == SlotCache.fileExtension {
            found[file.deletingPathExtension().lastPathComponent] = file
        }
        return found
    }

    public func writeCache(_ data: Data, slot: String) throws {
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try data.write(to: cacheURL(slot: slot), options: .atomic)
    }

    public func removeCache(slot: String) {
        try? FileManager.default.removeItem(at: cacheURL(slot: slot))
    }
}
