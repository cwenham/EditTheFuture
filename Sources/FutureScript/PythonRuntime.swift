import Foundation
import FutureEngine

#if canImport(CPythonBridge)
import CPythonBridge

/// A Python script loaded into the bundled CPython (docs/DESIGN.md, 6.4).
///
/// There's one interpreter for the process, started the first time a Python script loads (or
/// sooner, with `prepare()`). Each script runs in a namespace of its own. Audit hooks keep scripts
/// off the network and from writing files, and a watchdog stops calls that run too long.
final class PythonRuntime: ScriptRuntime {
    static var isBundled: Bool { true }

    private let program: UnsafeMutableRawPointer
    private let limits: ScriptLimits
    let descriptionJSON: String

    init(source: String, libraries: [URL], limits: ScriptLimits) throws {
        try Self.start()
        self.limits = limits
        var description: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let paths = libraries.map(\.path).joined(separator: "\n")
        guard let program = etf_py_load(source, paths, limits.loadSeconds, &description, &error) else {
            throw Self.scriptError(take(error))
        }
        self.program = program
        descriptionJSON = take(description) ?? "{}"
    }

    deinit {
        etf_py_release(program)
    }

    func start(_ state: inout [Double], inputs: [Double], time: ScriptTime) throws {
        _ = try call(isStep: false, &state, inputs: inputs, time: time, events: [])
    }

    func step(_ state: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> [GeneratedEvent] {
        guard let sent = try call(isStep: true, &state, inputs: inputs, time: time, events: events) else { return [] }
        return try ScriptEvents.decode(sent)
    }

    private func call(isStep: Bool, _ state: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> String? {
        var emitted: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let eventsJSON = events.isEmpty ? nil : Self.json(events)
        let status = state.withUnsafeMutableBufferPointer { values in
            inputs.withUnsafeBufferPointer { inputs in
                time.numbers.withUnsafeBufferPointer { numbers in
                    etf_py_call(program, isStep ? 1 : 0, values.baseAddress, Int32(values.count),
                                inputs.baseAddress, Int32(inputs.count), numbers.baseAddress, Int32(numbers.count),
                                time.date, time.seed, Int64(time.index), eventsJSON, limits.callSeconds, &emitted, &error)
                }
            }
        }
        guard status == 0 else { throw Self.scriptError(take(error)) }
        return take(emitted)
    }

    // MARK: Starting CPython

    /// Starts the interpreter now, rather than when the first Python script loads. The Mac app
    /// calls this on a background thread at launch, since it takes a moment.
    static func prepare() {
        try? start()
    }

    static func start() throws {
        guard etf_py_is_started() == 0 else { return }
        guard let environment else {
            throw ScriptError("Python's standard library isn't in the app.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard etf_py_start(environment.home, environment.paths.joined(separator: "\n"), pythonPrelude, &error) == 0 else {
            throw ScriptError("Python couldn't start: \(take(error) ?? "no reason given").")
        }
    }

    /// Where the standard library is: inside Python.framework on the Mac, and in the app's `python`
    /// folder on iOS. `ETF_PYTHON_HOME`, a folder holding lib/python3.x, overrides both, for tests.
    static let environment: (home: String, paths: [String])? = {
        let fileManager = FileManager.default
        var homes: [String] = []
        if let home = ProcessInfo.processInfo.environment["ETF_PYTHON_HOME"] { homes.append(home) }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("python").path { homes.append(resources) }
        if let prefix = etf_py_framework_prefix() {
            homes.append(String(cString: prefix))
            etf_py_free(prefix)
        }
        for home in homes {
            let lib = (home as NSString).appendingPathComponent("lib")
            guard let version = (try? fileManager.contentsOfDirectory(atPath: lib))?
                .filter({ $0.hasPrefix("python3.") }).sorted().last else { continue }
            let stdlib = (lib as NSString).appendingPathComponent(version)
            guard fileManager.fileExists(atPath: (stdlib as NSString).appendingPathComponent("os.py")) else { continue }
            var paths = [stdlib]
            let dynload = (stdlib as NSString).appendingPathComponent("lib-dynload")
            if fileManager.fileExists(atPath: dynload) { paths.append(dynload) }
            if let extra = ProcessInfo.processInfo.environment["ETF_PYTHON_PATHS"] {
                paths += extra.split(separator: ":").map(String.init)
            }
            return (home, paths)
        }
        return nil
    }()

    // MARK: Helpers

    private struct ErrorReport: Decodable {
        var message: String
        var line: Int?
    }

    private static func scriptError(_ json: String?) -> ScriptError {
        guard let json, let report = try? JSONDecoder().decode(ErrorReport.self, from: Data(json.utf8)) else {
            return ScriptError(json ?? "Python failed without saying why.")
        }
        return ScriptError(report.message, line: report.line)
    }

    private struct SentEvent: Encodable {
        var kind: String
        var slot: String?
        var date: String
        var values: [String: Double]
    }

    /// Events for the prelude. Non-finite values go as "NaN" and "Infinity", which Python's float() reads.
    private static func json(_ events: [Event]) -> String {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let sent = events.map { SentEvent(kind: $0.kind, slot: $0.originSlot, date: ScriptEvents.dateText($0.time), values: $0.values) }
        return (try? encoder.encode(sent)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// Takes a string the bridge returned, and frees it.
private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { etf_py_free(pointer) }
    return String(cString: pointer)
}

#else

/// Python isn't linked into this build: scripts/fetch-python.sh hasn't been run.
final class PythonRuntime: ScriptRuntime {
    static var isBundled: Bool { false }

    let descriptionJSON = "{}"

    init(source: String, libraries: [URL], limits: ScriptLimits) throws {
        throw ScriptError("Python isn't included in this build. Run scripts/fetch-python.sh (again, if Vendor/Python is already there), then build again.")
    }

    static func prepare() {}

    func start(_ state: inout [Double], inputs: [Double], time: ScriptTime) throws {}

    func step(_ state: inout [Double], inputs: [Double], time: ScriptTime, events: [Event]) throws -> [GeneratedEvent] { [] }
}

#endif

extension ScriptPrograms {
    /// Starts a language's interpreter ahead of time, off the main thread. Only Python needs it.
    public static func prepare(_ language: ScriptLanguage) {
        if language == .python { PythonRuntime.prepare() }
    }
}
