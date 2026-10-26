import Foundation
import FutureEngine

/// A language scripts can be written in (docs/DESIGN.md, 6.4).
public enum ScriptLanguage: String, CaseIterable, Hashable, Sendable, Codable {
    case lua
    case python

    /// "Lua", "Python".
    public var title: String {
        switch self {
        case .lua: return "Lua"
        case .python: return "Python"
        }
    }

    public var fileExtension: String {
        switch self {
        case .lua: return "lua"
        case .python: return "py"
        }
    }

    /// Whether this build can run it. Python needs CPython in Vendor/Python when it's built.
    public var isAvailable: Bool {
        switch self {
        case .lua: return true
        case .python: return PythonRuntime.isBundled
        }
    }

    /// A declaration written the way this language calls functions: `every "1 month"` in Lua,
    /// `every("1 month")` in Python.
    func call(_ function: String, _ argument: String) -> String {
        switch self {
        case .lua: return "\(function) \"\(argument)\""
        case .python: return "\(function)(\"\(argument)\")"
        }
    }

    /// How a step function starts.
    var stepFunctionExample: String {
        switch self {
        case .lua: return "function step(s, t)"
        case .python: return "def step(s, t):"
        }
    }

    /// The language's word for "no value".
    var nothing: String {
        switch self {
        case .lua: return "nil"
        case .python: return "None"
        }
    }
}

/// A mistake in a script, or an error it raised while running.
public struct ScriptError: ModelFailure, Sendable, Equatable {
    public var message: String
    /// The line in the script, counting from 1, when it's known.
    public var line: Int?
    /// The slot whose script failed, once it's known.
    public var slot: String?

    public init(_ message: String, line: Int? = nil, slot: String? = nil) {
        self.message = message
        self.line = line
        self.slot = slot
    }

    public var description: String {
        var text = ""
        if let slot { text += "\(slot): " }
        if let line { text += "line \(line): " }
        return text + message
    }
}

/// How much a script may use.
public struct ScriptLimits: Sendable, Equatable {
    /// Bytes a Lua script may allocate.
    public var memory: Int
    /// Seconds loading a script may take.
    public var loadSeconds: Double
    /// Seconds each call into a script (a step, or the start) may take.
    public var callSeconds: Double

    public init(memory: Int = 64 << 20, loadSeconds: Double = 5, callSeconds: Double = 2) {
        self.memory = memory
        self.loadSeconds = loadSeconds
        self.callSeconds = callSeconds
    }
}
