import Foundation
import Testing
import FutureEngine
@testable import FutureScript

func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))!
}

/// The languages this build can run. Python needs Vendor/Python when it's built.
let languages = ScriptLanguage.allCases.filter(\.isAvailable)

/// The same script in each language.
struct Scripts {
    var lua: String
    var python: String

    func source(_ language: ScriptLanguage) -> String {
        language == .lua ? lua : python
    }
}

let savings = Scripts(lua: """
    every "1 month"
    param("rate", "6%", { range = {"0%", "15%"}, by = "0.1%", label = "Interest rate" })
    param("deposit", 200, { as = "currency" })
    init("balance", 1000, { label = "Balance", as = "currency" })
    output("interest")

    function step(s, t)
      s.interest = s.balance * s.rate / 12
      s.balance = s.balance + s.interest + s.deposit
    end

    on("bonus", function(s, e, t) s.balance = s.balance + e.amount end)
    """, python: """
    every("1 month")
    param("rate", "6%", range=("0%", "15%"), by="0.1%", label="Interest rate")
    param("deposit", 200, as_="currency")
    init("balance", 1000, label="Balance", as_="currency")
    output("interest")

    def step(s, t):
        s.interest = s.balance * s.rate / 12
        s.balance = s.balance + s.interest + s.deposit

    @on("bonus")
    def bonus(s, e, t):
        s.balance += e.amount
    """)

/// Sends Crossed once its value passes 5, and counts down from 10 after that.
let sender = Scripts(lua: """
    every "1 month"
    init("level", 0)
    emits "Crossed"
    function step(s, t)
      local before = s.level
      s.level = s.level + 1
      if before <= 5 and s.level > 5 then emit("Crossed", { by = s.level - 5 }) end
    end
    """, python: """
    every("1 month")
    init("level", 0)
    emits("Crossed")
    def step(s, t):
        before = s.level
        s.level += 1
        if before <= 5 and s.level > 5:
            emit("Crossed", by=s.level - 5)
    """)

/// Copies Sender's level, and counts the Crossed events it hears.
let reader = Scripts(lua: """
    every "1 month"
    input("seen", "Sender.level")
    output("copy")
    init("heard", 0)
    function step(s, t) s.copy = s.seen * 2 end
    on("Sender.Crossed", function(s, e, t) s.heard = s.heard + e.by end)
    """, python: """
    every("1 month")
    input("seen", "Sender.level")
    output("copy")
    init("heard", 0)
    def step(s, t):
        s.copy = s.seen * 2
    @on("Sender.Crossed")
    def crossed(s, e, t):
        s.heard += e.by
    """)

let noisy = Scripts(lua: """
    every "1 day"
    output("x")
    function step(s, t) s.x = t.random() + t.normal(0, 1) + math.random() end
    """, python: """
    import random
    every("1 day")
    output("x")
    def step(s, t):
        s.x = t.random() + t.normal(0, 1) + random.random()
    """)

func series(_ scenario: Scenario, _ slot: SlotID, _ variable: String, through: Date) throws -> [Double] {
    try scenario.series(variable, of: slot, from: scenario.start, through: through).map(\.value)
}

/// A plain call into a script, for tests that don't need a scenario.
func time(_ index: Int) -> ScriptTime {
    ScriptTime(numbers: [Double(index), 2026, 1, 1, 1, 0, 1], date: "2026-01-01", seed: 1, index: index)
}

/// Collects what went wrong on several threads at once.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ failure: String) {
        lock.lock()
        defer { lock.unlock() }
        list.append(failure)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

@Suite("Scripts")
struct ScriptTests {
    let start = utc(2026, 1, 1)

    @Test("A savings script compounds like the arithmetic", arguments: languages)
    func savingsMatchesArithmetic(_ language: ScriptLanguage) throws {
        let model = try ScriptModel(savings.source(language), language: language, name: "Savings")
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot("Savings", model: model)
        scenario.add(Event(time: utc(2026, 3, 15), kind: "bonus", values: ["amount": 500]), to: id)
        scenario.add(Event.set(["rate": 0.03], at: utc(2026, 6, 15)), to: id)
        try scenario.validate()

        var expected = [1000.0]
        var balance = 1000.0, rate = 0.06
        for index in 1...12 {
            if index == 6 { rate = 0.03 }
            balance = balance + balance * rate / 12 + 200
            if index == 3 { balance += 500 }
            expected.append(balance)
        }
        let balances = try series(scenario, id, "balance", through: utc(2027, 1, 1))
        #expect(balances.count == expected.count)
        for (got, want) in zip(balances, expected) { #expect(abs(got - want) < 1e-9) }
        let rates = try series(scenario, id, "rate", through: utc(2027, 1, 1))
        #expect(rates[5] == 0.06 && rates[6] == 0.03)
    }

    @Test("Declarations become the model's descriptor", arguments: languages)
    func declarations(_ language: ScriptLanguage) throws {
        let model = try ScriptModel(savings.source(language), language: language, name: "Savings", values: ["deposit": 300, "nope": 1])
        let descriptor = model.descriptor
        #expect(descriptor.stepRate == .months(1))
        #expect(descriptor.readable.map(\.name) == ["rate", "deposit", "balance", "interest"])
        let rate = try #require(descriptor.variable(named: "rate"))
        #expect(rate.causality == .parameter && rate.quantity == .percent && rate.label == "Interest rate")
        #expect(rate.minimum == 0 && rate.maximum == 0.15 && abs((rate.increment ?? 0) - 0.001) < 1e-12)
        #expect(descriptor.variable(named: "deposit")?.quantity == .currency)
        #expect(descriptor.variable(named: "balance")?.causality == .output)
        #expect(model.parameterNames == ["rate", "deposit"])
        #expect(model.startingValueNames == ["balance"])
        #expect(model.handledEventKinds == ["bonus"])
        #expect(model.overrides == ["deposit": 300])
        #expect(model.declaredDefaults == ["rate": 0.06, "deposit": 200, "balance": 1000])
        #expect(model.startingValues["deposit"] == 300)
    }

    @Test("Slots read each other's values and events", arguments: languages)
    func inputsAndEvents(_ language: ScriptLanguage) throws {
        let scenario = Scenario(start: start)
        let from = try scenario.addSlot("Sender", model: ScriptModel(sender.source(language), language: language, name: "Sender"))
        let to = try scenario.addSlot("Reader", model: ScriptModel(reader.source(language), language: language, name: "Reader"))
        try scenario.validate()
        let end = utc(2026, 12, 1)
        #expect(try series(scenario, from, "level", through: end) == (0...11).map(Double.init))
        #expect(try series(scenario, to, "copy", through: end).dropFirst() == ArraySlice((1...11).map { Double($0) * 2 }))
        let heard = try series(scenario, to, "heard", through: end)
        #expect(heard[5] == 0 && heard[6] == 1 && heard.last == 1)
        let generated = try scenario.generatedEvents(in: from, through: end)
        #expect(generated.map(\.kind) == ["Crossed"] && generated.first?.values == ["by": 1])
    }

    @Test("Randomness is the same every time, and different every step", arguments: languages)
    func determinism(_ language: ScriptLanguage) throws {
        func run() throws -> [Double] {
            let scenario = Scenario(start: start)
            let id = try scenario.addSlot("Noisy", model: ScriptModel(noisy.source(language), language: language, name: "Noisy"))
            return try series(scenario, id, "x", through: utc(2026, 3, 1))
        }
        let first = try run()
        #expect(first == (try run()))
        #expect(Set(first.dropFirst()).count == first.count - 1)

        // Rewinding to a checkpoint and computing again gives the same values.
        let scenario = Scenario(start: start, checkpointInterval: 8)
        let id = try scenario.addSlot("Noisy", model: ScriptModel(noisy.source(language), language: language, name: "Noisy"))
        let before = try series(scenario, id, "x", through: utc(2026, 3, 1))
        scenario.invalidate(id, from: utc(2026, 2, 10))
        #expect(try series(scenario, id, "x", through: utc(2026, 3, 1)) == before)
    }

    // MARK: Mistakes

    @Test("Syntax errors report their line", arguments: languages)
    func syntaxError(_ language: ScriptLanguage) {
        let source = language == .lua ? "every \"1 month\"\ninit(\"x\", 1)\nfunction step(s, t)\n  s.x = = 2\nend"
                                      : "every(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = = 2\n"
        #expect { try ScriptModel(source, language: language) } throws: { ($0 as? ScriptError)?.line == 4 }
    }

    @Test("Errors while running name the slot and the line", arguments: languages)
    func runtimeError(_ language: ScriptLanguage) throws {
        let source = language == .lua ? "every \"1 month\"\ninit(\"x\", 1)\nfunction step(s, t)\n  s.x = s.x + nothing.here\nend"
                                      : "every(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = s.x + nothing.here\n"
        let scenario = Scenario(start: start)
        let id = try scenario.addSlot("Broken", model: ScriptModel(source, language: language, name: "Broken"))
        #expect { try scenario.ensure(id, through: utc(2026, 6, 1)) } throws: { error in
            guard let error = error as? ScriptError else { return false }
            return error.slot == "Broken" && error.line == 4 && error.message.contains("nothing")
        }
        // The start computed before the failing step stays.
        #expect(scenario.computedThrough(id) == start)
    }

    @Test("Undeclared names in s are caught, with a suggestion", arguments: languages)
    func undeclared(_ language: ScriptLanguage) throws {
        let source = language == .lua ? "every \"1 month\"\ninit(\"balance\", 1)\nfunction step(s, t)\n  s.balnce = 2\nend"
                                      : "every(\"1 month\")\ninit(\"balance\", 1)\ndef step(s, t):\n    s.balnce = 2\n"
        let program = try ScriptProgram(language: language, source: source, libraries: [], limits: ScriptLimits())
        var values = [1.0]
        #expect { _ = try program.step(&values, inputs: [], time: time(1), events: []) } throws: { error in
            guard let error = error as? ScriptError else { return false }
            return error.line == 4 && error.message.contains("balnce") && error.message.contains("balance")
        }
    }

    @Test("Inputs can't be changed", arguments: languages)
    func inputsAreReadOnly(_ language: ScriptLanguage) throws {
        let source = language == .lua ? "every \"1 month\"\ninput(\"x\", \"Other.x\")\nfunction step(s, t) s.x = 2 end"
                                      : "every(\"1 month\")\ninput(\"x\", \"Other.x\")\ndef step(s, t):\n    s.x = 2\n"
        let program = try ScriptProgram(language: language, source: source, libraries: [], limits: ScriptLimits())
        var values: [Double] = []
        #expect { _ = try program.step(&values, inputs: [1], time: time(1), events: []) } throws: { error in
            (error as? ScriptError)?.message.contains("input") == true
        }
    }

    @Test("A script must say how often it steps, and have a step", arguments: languages)
    func missingDeclarations(_ language: ScriptLanguage) {
        #expect { try ScriptModel(language == .lua ? "init(\"x\", 1)\nfunction step(s, t) end" : "init(\"x\", 1)\ndef step(s, t):\n    pass", language: language) }
            throws: { ($0 as? ScriptError)?.message.contains("every") == true }
        #expect { try ScriptModel(language == .lua ? "every \"1 month\"\ninit(\"x\", 1)" : "every(\"1 month\")\ninit(\"x\", 1)", language: language) }
            throws: { ($0 as? ScriptError)?.message.contains("step") == true }
        #expect { try ScriptModel(language == .lua ? "every \"fortnightly\"\nfunction step(s, t) end" : "every(\"fortnightly\")\ndef step(s, t):\n    pass", language: language) }
            throws: { ($0 as? ScriptError)?.message.contains("fortnightly") == true }
        #expect { try ScriptModel(language == .lua ? "every \"1 month\"\ninput(\"x\", \"Nope\")\nfunction step(s, t) end" : "every(\"1 month\")\ninput(\"x\", \"Nope\")\ndef step(s, t):\n    pass", language: language) }
            throws: { ($0 as? ScriptError)?.message.contains("Nope") == true }
    }

    @Test("Emitting a kind that isn't declared is an error", arguments: languages)
    func undeclaredEmit(_ language: ScriptLanguage) throws {
        let source = language == .lua ? "every \"1 month\"\nfunction step(s, t) emit(\"Boom\") end"
                                      : "every(\"1 month\")\ndef step(s, t):\n    emit(\"Boom\")\n"
        let program = try ScriptProgram(language: language, source: source, libraries: [], limits: ScriptLimits())
        var values: [Double] = []
        #expect { _ = try program.step(&values, inputs: [], time: time(1), events: []) } throws: { error in
            (error as? ScriptError)?.message.contains("emits") == true
        }
    }

    @Test("Endless loops stop after the time limit", arguments: languages)
    func timeLimit(_ language: ScriptLanguage) throws {
        let source = language == .lua ? "every \"1 month\"\nfunction step(s, t)\n  while true do end\nend"
                                      : "every(\"1 month\")\ndef step(s, t):\n    while True:\n        pass\n"
        let program = try ScriptProgram(language: language, source: source, libraries: [],
                                        limits: ScriptLimits(callSeconds: 0.2))
        var values: [Double] = []
        let clock = ContinuousClock()
        let began = clock.now
        #expect { _ = try program.step(&values, inputs: [], time: time(1), events: []) } throws: { error in
            (error as? ScriptError)?.message.contains("longer than") == true
        }
        #expect(clock.now - began < .seconds(3))
        // The script still works afterwards.
        #expect { _ = try program.step(&values, inputs: [], time: time(2), events: []) } throws: { _ in true }
    }

    @Test("Libraries load from the Libraries folder", arguments: languages)
    func libraries(_ language: ScriptLanguage) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-libraries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("money"), withIntermediateDirectories: true)
        let source: String
        switch language {
        case .lua:
            try "local M = {}\nfunction M.double(x) return x * 2 end\nreturn M".write(to: folder.appendingPathComponent("money/tools.lua"), atomically: true, encoding: .utf8)
            source = "local tools = require \"money.tools\"\nevery \"1 month\"\ninit(\"x\", 1)\nfunction step(s, t) s.x = tools.double(s.x) end"
        case .python:
            try "".write(to: folder.appendingPathComponent("money/__init__.py"), atomically: true, encoding: .utf8)
            try "def double(x):\n    return x * 2\n".write(to: folder.appendingPathComponent("money/tools.py"), atomically: true, encoding: .utf8)
            source = "from money.tools import double\nevery(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = double(s.x)\n"
        }
        let program = try ScriptProgram(language: language, source: source, libraries: [folder], limits: ScriptLimits())
        var values = [3.0]
        _ = try program.step(&values, inputs: [], time: time(1), events: [])
        #expect(values == [6])

        let missing = language == .lua ? "require \"nowhere\"\nevery \"1 month\"\nfunction step(s, t) end"
                                       : "import nowhere_at_all\nevery(\"1 month\")\ndef step(s, t):\n    pass\n"
        #expect { try ScriptProgram(language: language, source: missing, libraries: [folder], limits: ScriptLimits()) }
            throws: { ($0 as? ScriptError)?.message.contains("nowhere") == true }
    }

    @Test("Scripts loading at the same time each find their libraries", arguments: languages)
    func librariesWhileOthersLoad(_ language: ScriptLanguage) throws {
        // Python's sys.path is shared by every script. Scripts loading on other threads, without
        // libraries, mustn't take the folder away while another script imports from it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-libraries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let withLibrary: String, plain: String
        switch language {
        case .lua:
            try "return { double = function(x) return x * 2 end }".write(to: folder.appendingPathComponent("twice.lua"), atomically: true, encoding: .utf8)
            withLibrary = "local twice = require \"twice\"\nevery \"1 month\"\ninit(\"x\", 1)\nfunction step(s, t) s.x = twice.double(s.x) end"
            plain = "every \"1 month\"\ninit(\"x\", 1)\nfunction step(s, t) s.x = s.x + 1 end"
        case .python:
            try "def double(x):\n    return x * 2\n".write(to: folder.appendingPathComponent("twice.py"), atomically: true, encoding: .utf8)
            withLibrary = "from twice import double\nevery(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = double(s.x)\n"
            plain = "every(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = s.x + 1\n"
        }
        // Generous limits: loads wait for each other while the whole suite runs.
        let limits = ScriptLimits(loadSeconds: 60, callSeconds: 60)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                if index.isMultiple(of: 2) {
                    let program = try ScriptProgram(language: language, source: withLibrary, libraries: [folder], limits: limits)
                    var values = [3.0]
                    _ = try program.step(&values, inputs: [], time: time(1), events: [])
                    if values != [6] { failures.add("\(index): \(values)") }
                } else {
                    _ = try ScriptProgram(language: language, source: plain, libraries: [], limits: limits)
                }
            } catch {
                failures.add("\(index): \(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    @Test("Loading the same text again shares the program")
    func programsAreShared() throws {
        let a = try ScriptModel(savings.lua, language: .lua, name: "A")
        let b = try ScriptModel(savings.lua, language: .lua, name: "B", values: ["rate": 0.01])
        #expect(a.program === b.program)
        #expect(a.descriptor.name == "A" && b.descriptor.name == "B")
    }
}

@Suite("Lua scripts")
struct LuaScriptTests {
    func program(_ source: String, limits: ScriptLimits = ScriptLimits()) throws -> ScriptProgram {
        try ScriptProgram(language: .lua, source: source, libraries: [], limits: limits)
    }

    @Test("Only the safe libraries are there")
    func sandbox() throws {
        let source = """
            every "1 month"
            output("missing")
            function step(s, t)
              local count = 0
              for _, name in ipairs({ "io", "os", "debug", "package", "dofile", "loadfile" }) do
                if _G[name] == nil then count = count + 1 end
              end
              s.missing = count
            end
            """
        let loaded = try program(source)
        var values = [0.0]
        _ = try loaded.step(&values, inputs: [], time: time(1), events: [])
        #expect(values == [6])
    }

    @Test("Globals can't change while the script runs")
    func frozenGlobals() throws {
        let loaded = try program("every \"1 month\"\ncounter = 0\nfunction step(s, t)\n  counter = counter + 1\nend")
        var values: [Double] = []
        #expect { _ = try loaded.step(&values, inputs: [], time: time(1), events: []) } throws: { error in
            guard let error = error as? ScriptError else { return false }
            return error.line == 4 && error.message.contains("local counter")
        }
    }

    @Test("Bytecode can't be loaded")
    func noBytecode() throws {
        let source = """
            every "1 month"
            output("ok")
            function step(s, t)
              local f = load(string.dump(function() return 1 end))
              s.ok = f == nil and 1 or 0
            end
            """
        let loaded = try program(source)
        var values = [0.0]
        _ = try loaded.step(&values, inputs: [], time: time(1), events: [])
        #expect(values == [1])
    }

    @Test("Memory is capped")
    func memoryLimit() throws {
        let source = "every \"1 month\"\nfunction step(s, t)\n  local t = {}\n  for i = 1, 1e8 do t[i] = i end\nend"
        let loaded = try program(source, limits: ScriptLimits(memory: 8 << 20))
        var values: [Double] = []
        #expect { _ = try loaded.step(&values, inputs: [], time: time(1), events: []) } throws: { error in
            (error as? ScriptError)?.message.contains("memory") == true
        }
    }

    @Test("Declaration mistakes point at their line")
    func declarationMistakes() {
        #expect { try ScriptModel("every \"1 month\"\nparam(\"rate\", \"lots\")\nfunction step(s, t) end", language: .lua) }
            throws: { ($0 as? ScriptError)?.line == 2 }
        #expect { try ScriptModel("every \"1 month\"\nparam(\"rate\", 1, { colour = \"red\" })\nfunction step(s, t) end", language: .lua) }
            throws: { ($0 as? ScriptError)?.message.contains("colour") == true }
        #expect { try ScriptModel("every \"1 month\"\ninit(\"x\", 1)\ninit(\"x\", 2)\nfunction step(s, t) end", language: .lua) }
            throws: { ($0 as? ScriptError)?.line == 3 }
    }
}

@Suite("Python scripts", .enabled(if: ScriptLanguage.python.isAvailable))
struct PythonScriptTests {
    /// Runs one step of a script whose step does `body`, and returns the error it raised, if any.
    func error(running body: String) throws -> ScriptError? {
        let source = "every(\"1 month\")\noutput(\"x\")\ndef step(s, t):\n" + body.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n"
        // A generous limit: the first import of a module can be slow while the whole suite runs.
        let program = try ScriptProgram(language: .python, source: source, libraries: [], limits: ScriptLimits(loadSeconds: 60, callSeconds: 60))
        var values = [0.0]
        do {
            _ = try program.step(&values, inputs: [], time: time(1), events: [])
            return nil
        } catch let error as ScriptError {
            return error
        }
    }

    @Test("Scripts can't use the network, start programs, use ctypes or write files")
    func auditHooks() throws {
        let attempts = [
            "import socket\nsocket.create_connection((\"example.com\", 80))": "network",
            "import subprocess\nsubprocess.run([\"ls\"])": "programs",
            "import os\nos.system(\"ls\")": "programs",
            "import ctypes": "ctypes",
            "open(\"/tmp/etf-should-not-exist.txt\", \"w\")": "write files",
            "import os\nos.remove(\"/tmp/etf-should-not-exist.txt\")": "change files",
            "import os\nos._exit(1)": "stop the app",
        ]
        for (body, words) in attempts {
            let error = try self.error(running: body)
            #expect(error?.message.contains(words) == true, "\(body): \(String(describing: error))")
            #expect(error?.line != nil, "\(body)")
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/etf-should-not-exist.txt"))
    }

    @Test("Scripts can read files and use the standard library")
    func standardLibrary() throws {
        #expect(try error(running: "import statistics, fractions, decimal, datetime, json\ns.x = statistics.mean([1, 2, 3])") == nil)
        let readable = FileManager.default.temporaryDirectory.appendingPathComponent("etf-read-\(UUID().uuidString).txt")
        try "42".write(to: readable, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: readable) }
        #expect(try error(running: "s.x = float(open(\(String(reflecting: readable.path))).read())") == nil)
    }

    @Test("Scripts loading on other threads don't hide the standard library from imports")
    func importsWhileOthersLoad() throws {
        // Each load changes sys.path. An import on another thread may be looking through it at that
        // moment, and must still find every module. PathFinder looks every time, even for modules
        // that are already imported.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("etf-libraries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let finder = """
            import importlib.machinery
            every("1 month")
            output("missing")
            def step(s, t):
                names = ("json", "statistics", "fractions") * 50
                s.missing = sum(importlib.machinery.PathFinder.find_spec(name) is None for name in names)
            """
        let plain = "every(\"1 month\")\ninit(\"x\", 1)\ndef step(s, t):\n    s.x = s.x + 1\n"
        let limits = ScriptLimits(loadSeconds: 60, callSeconds: 60)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                if index.isMultiple(of: 4) {
                    let program = try ScriptProgram(language: .python, source: finder, libraries: [], limits: limits)
                    var values = [0.0]
                    _ = try program.step(&values, inputs: [], time: time(1), events: [])
                    if values != [0] { failures.add("\(index): \(values[0]) not found") }
                } else {
                    _ = try ScriptProgram(language: .python, source: plain, libraries: index.isMultiple(of: 2) ? [folder] : [], limits: limits)
                }
            } catch {
                failures.add("\(index): \(error)")
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all)")
    }

    @Test("pip isn't there")
    func noPip() throws {
        for module in ["pip", "ensurepip", "venv"] {
            let error = try self.error(running: "import \(module)")
            #expect(error?.message.contains("no Python module called '\(module)'") == true, "\(module): \(String(describing: error))")
        }
    }

    @Test("Printing doesn't go to the app's output, and emit takes a dictionary too")
    func printAndEmit() throws {
        let source = "every(\"1 month\")\nemits(\"Paid\")\ndef step(s, t):\n    print(\"hello\")\n    emit(\"Paid\", {\"amount\": 5})\n    t.emit(\"Paid\", amount=6)\n"
        let program = try ScriptProgram(language: .python, source: source, libraries: [], limits: ScriptLimits())
        var values: [Double] = []
        let sent = try program.step(&values, inputs: [], time: time(1), events: [])
        #expect(sent == [GeneratedEvent(kind: "Paid", values: ["amount": 5]), GeneratedEvent(kind: "Paid", values: ["amount": 6])])
    }

    @Test("Events reach handlers with their fields")
    func eventFields() throws {
        let source = "every(\"1 month\")\ninit(\"total\", 0)\n@on(\"deposit\")\ndef deposit(s, e, t):\n    s.total += e.amount + e.get(\"extra\", 0)\n    s.total += 100 if e.date == \"2026-03-15\" else 0\n"
        let program = try ScriptProgram(language: .python, source: source, libraries: [], limits: ScriptLimits())
        var values = [0.0]
        let event = Event(time: utc(2026, 3, 15), kind: "deposit", values: ["amount": 5])
        _ = try program.step(&values, inputs: [], time: time(1), events: [event])
        #expect(values == [105])
    }
}
