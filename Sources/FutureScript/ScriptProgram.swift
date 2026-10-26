import Foundation
import FutureEngine

/// The time as a script sees it for one call: `t.index`, `t.year` and the rest.
struct ScriptTime {
    /// index, year (fractional), month, day, dayOfYear, days, dt: the order both preludes read.
    var numbers: [Double]
    /// "2031-06-01".
    var date: String
    var seed: UInt64
    var index: Int
}

/// An interpreter with one script loaded. Not thread-safe: `ScriptProgram` lets one call in at a time.
protocol ScriptRuntime: AnyObject {
    /// What the script declared, as JSON (`ScriptDescription`).
    var descriptionJSON: String { get }

    /// Lets the script adjust its starting state (its optional `start` function).
    func start(_ state: inout [Double], inputs: [Double], time: ScriptTime) throws

    /// Runs one step: `step`, then the `on` handlers. Returns the events it sent.
    func step(_ state: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> [GeneratedEvent]
}

/// A script loaded into its interpreter, shared by every model built from the same text.
public final class ScriptProgram: @unchecked Sendable {
    public let language: ScriptLanguage
    public let source: String
    let shape: ScriptShape
    private let runtime: any ScriptRuntime
    private let lock = NSLock()

    init(language: ScriptLanguage, source: String, libraries: [URL], limits: ScriptLimits) throws {
        self.language = language
        self.source = source
        let runtime: any ScriptRuntime
        switch language {
        case .lua: runtime = try LuaRuntime(source: source, libraries: libraries, limits: limits)
        case .python: runtime = try PythonRuntime(source: source, libraries: libraries, limits: limits)
        }
        let description: ScriptDescription
        do {
            description = try JSONDecoder().decode(ScriptDescription.self, from: Data(runtime.descriptionJSON.utf8))
        } catch {
            throw ScriptError("The script's declarations couldn't be read (\(error)).")
        }
        shape = try ScriptShape(description, language: language)
        self.runtime = runtime
    }

    func start(_ state: inout [Double], inputs: [Double], time: ScriptTime) throws {
        lock.lock()
        defer { lock.unlock() }
        try runtime.start(&state, inputs: inputs, time: time)
    }

    func step(_ state: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> [GeneratedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try runtime.step(&state, inputs: inputs, time: time, events: events)
    }
}

/// Loads scripts, keeping recent ones so models built from the same text share one interpreter.
public enum ScriptPrograms {
    /// The loaded program for a script, or the mistake that stopped it loading. Both are kept,
    /// so building a slot's model again doesn't load the script again.
    public static func program(_ source: String, language: ScriptLanguage) throws -> ScriptProgram {
        try cache.program(source, language: language)
    }

    /// The folder holding the `lua` and `python` library folders.
    public static var librariesFolder: URL {
        get { cache.settings.librariesFolder }
        set { cache.update { $0.librariesFolder = newValue } }
    }

    public static var limits: ScriptLimits {
        get { cache.settings.limits }
        set { cache.update { $0.limits = newValue } }
    }

    /// Forgets loaded scripts, so they load again with the current library files.
    public static func reloadLibraries() {
        cache.update { _ in }
    }

    /// Increases each time loaded scripts are forgotten, so the app can tell its models are out of date.
    public static var generation: Int { cache.currentGeneration }

    /// The library folder for one language: `Libraries/lua`, `Libraries/python`.
    public static func librariesFolder(for language: ScriptLanguage) -> URL {
        librariesFolder.appendingPathComponent(language.rawValue, isDirectory: true)
    }

    /// Makes the library folders, so people have somewhere to put files.
    public static func createLibrariesFolders() throws {
        for language in ScriptLanguage.allCases {
            try FileManager.default.createDirectory(at: librariesFolder(for: language), withIntermediateDirectories: true)
        }
    }

    /// Application Support on the Mac (inside the app's container when it's sandboxed); Documents on
    /// iOS, where the Files app can reach it.
    static var defaultLibrariesFolder: URL {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Edit The Future", isDirectory: true)
        #endif
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("Libraries", isDirectory: true)
    }

    private static let cache = ProgramCache()

    struct Settings: Sendable {
        var librariesFolder = ScriptPrograms.defaultLibrariesFolder
        var limits = ScriptLimits()
    }

    final class ProgramCache: @unchecked Sendable {
        private struct Key: Hashable {
            let language: ScriptLanguage
            let source: String
        }

        private let lock = NSLock()
        private var entries: [Key: Result<ScriptProgram, ScriptError>] = [:]
        private var order: [Key] = []
        private var current = Settings()
        /// Increases whenever the settings change, so a load that started before doesn't get kept.
        private var generation = 0
        static let capacity = 64

        var settings: Settings {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        var currentGeneration: Int {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        /// Changes the settings and forgets every loaded script.
        func update(_ change: (inout Settings) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            change(&current)
            entries.removeAll()
            order.removeAll()
            generation += 1
        }

        func program(_ source: String, language: ScriptLanguage) throws -> ScriptProgram {
            let key = Key(language: language, source: source)
            lock.lock()
            let found = entries[key]
            let settings = current, started = generation
            lock.unlock()
            if let found { return try found.get() }

            // Loaded outside the lock, so a slow script doesn't hold up others.
            let result: Result<ScriptProgram, ScriptError>
            do {
                let libraries = [settings.librariesFolder.appendingPathComponent(language.rawValue, isDirectory: true)]
                result = .success(try ScriptProgram(language: language, source: source, libraries: libraries, limits: settings.limits))
            } catch let error as ScriptError {
                result = .failure(error)
            } catch {
                result = .failure(ScriptError(String(describing: error)))
            }

            lock.lock()
            if generation == started {
                if let existing = entries[key] {
                    lock.unlock()
                    return try existing.get()
                }
                entries[key] = result
                order.append(key)
                if order.count > Self.capacity { entries[order.removeFirst()] = nil }
            }
            lock.unlock()
            return try result.get()
        }
    }
}
