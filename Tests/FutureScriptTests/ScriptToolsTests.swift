import Foundation
import Testing
@testable import FutureScript

@Suite("Script editing tools")
struct ScriptToolsTests {
    func kinds(_ source: String, _ language: ScriptLanguage) -> [String: ScriptTokenKind] {
        var result: [String: ScriptTokenKind] = [:]
        for token in ScriptHighlighter.tokens(in: source, language: language) where result[token.text] == nil {
            result[token.text] = token.kind
        }
        return result
    }

    @Test("Lua is coloured by what each word is")
    func luaColours() {
        let source = """
            -- a comment
            every "1 month"
            input("t", "Climate.temp[t-1]")
            --[[ a long
            comment ]]
            local text = [==[ long ]] string ]==]
            function step(s, t) s.x = math.max(1, 2.5e3) end
            """
        let found = kinds(source, .lua)
        #expect(found["-- a comment"] == .comment)
        #expect(found["--[[ a long\ncomment ]]"] == .comment)
        #expect(found["[==[ long ]] string ]==]"] == .string)
        #expect(found["every"] == .api && found["input"] == .api)
        #expect(found["\"1 month\""] == .string)
        #expect(found["Climate.temp[t-1]"] == .reference)
        #expect(found["function"] == .keyword && found["local"] == .keyword && found["end"] == .keyword)
        #expect(found["x"] == .field)
        #expect(found["math"] == .library && found["max"] == .name)
        #expect(found["2.5e3"] == .number)
    }

    @Test("Python is coloured by what each word is")
    func pythonColours() {
        let source = """
            # a comment
            every("1 month")
            note = '''three
            lines'''
            label = f"{1}"
            @on("Sender.Crossed")
            def crossed(s, e, t):
                s.heard += e.by if e.slot is not None else len([1])
            """
        let found = kinds(source, .python)
        #expect(found["# a comment"] == .comment)
        #expect(found["'''three\nlines'''"] == .string)
        #expect(found["f\"{1}\""] == .string)
        #expect(found["Sender.Crossed"] == .reference)
        #expect(found["def"] == .keyword && found["None"] == .keyword && found["is"] == .keyword)
        #expect(found["on"] == .api && found["every"] == .api)
        #expect(found["heard"] == .field && found["by"] == .field && found["slot"] == .field)
        #expect(found["len"] == .library)
    }

    @Test("Completion knows strings, s., t. and e.")
    func completion() {
        let slots = [ScriptSlotSummary(name: "Climate", values: ["temp", "rain"], events: ["Heatwave"])]
        func items(_ source: String) -> [String] {
            ScriptCompleter.complete(source, at: (source as NSString).length, language: .python, slots: slots).items.map(\.text)
        }
        #expect(items("input(\"temp\", \"") == ["Climate."])
        #expect(items("input(\"temp\", \"Cl") == ["Climate."])
        #expect(items("input(\"temp\", \"Climate.") == ["temp", "rain", "Heatwave"])
        #expect(items("input(\"temp\", \"Climate.r") == ["rain"])
        #expect(items("init(\"balance\", 1)\ndef step(s, t):\n    s.b") == ["balance"])
        #expect(items("def step(s, t):\n    t.ye") == ["year"])
        #expect(items("def step(s, t):\n    t.ran") == ["random()"])
        #expect(items("def d(s, e, t):\n    e.") == ["kind", "slot", "date"])
        #expect(items("emi").contains("emit") && items("emi").contains("emits"))
        #expect(items("# Clim") == [] || !items("# Clim").contains("Climate."))
    }

    @Test("References to a slot are found inside strings, without their quotes")
    func references() {
        let source = "input(\"a\", \"Climate.temp\")\ninput(\"b\", \"Climate.rain.mean[t-1]\")\non(\"Other.Kind\", f)"
        let found = ScriptCompleter.references(toSlot: "Climate", in: source, language: .lua)
        #expect(found.map(\.text) == ["Climate.temp", "Climate.rain.mean[t-1]"])
        #expect((source as NSString).substring(with: found[0].range) == "Climate.temp")
        #expect(ScriptCompleter.line(of: found[1].range.location, in: source) == 2)
    }

    @Test("Declared names are found without running the script")
    func declaredNames() {
        let source = "param('rate', 1)\ninit(\"balance\", 2)\noutput(\"interest\")\ninput(\"temp\", \"Climate.temp\")"
        let names = ScriptCompleter.declaredNames(in: source, language: .python)
        #expect(names.parameters == ["rate"] && names.variables == ["balance", "interest"] && names.inputs == ["temp"])
    }
}
