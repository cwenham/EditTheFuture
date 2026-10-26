import Foundation
import Testing
import FutureEngine
import FutureFormula
import FutureScript
@testable import FutureUI

/// Scripts in slots: adding them, editing them in the Formula tab, and errors while they run
/// (docs/DESIGN.md, 6.4).
@MainActor
@Suite("Script slots")
struct ScriptSlotTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    nonisolated static let templates = [ModelLibrary.predatorPrey, ModelLibrary.blankLua]
        + (ScriptLanguage.python.isAvailable ? [ModelLibrary.marketSwings, ModelLibrary.blankPython] : [])

    @Test("Script models from the library run in slots", arguments: templates)
    func addScript(_ template: ModelTemplate) async throws {
        let store = try await makeStore()
        #expect(store.addModel(template))
        await store.waitUntilIdle()
        let slot = store.focused
        #expect(slot.kind == template.kind && slot.isScript && slot.noun == "script")
        #expect(slot.pausedReason == nil)
        #expect(slot.summary.contains(template.kind.title))
        #expect(!slot.parameterValues.isEmpty)
        let samples = store.timelineState().focus.samples
        #expect(samples.count > 100 && samples.allSatisfy { $0.value.isFinite })
        #expect(store.slotFailures.isEmpty)
    }

    @Test("The picker can add every library model, scripts included, and previews the ones that stand alone")
    func pickerFacts() async throws {
        for template in ModelLibrary.all {
            let facts = TemplateFacts.of(template)
            #expect(facts.error == nil, "\(template.name): \(facts.error ?? "")")
            #expect(!facts.parameters.isEmpty, "\(template.name) shows no parameters")
            #expect(facts.line.hasPrefix(template.kind.title), "\(template.name): \(facts.line)")
            if facts.reads == nil {
                let preview = await TemplatePreview.samples(for: template, start: utc(2026, 1, 1))
                #expect(preview.count > 20, "\(template.name) has no preview")
            }
        }
    }

    @Test("Script slots read formula slots, and formulas read scripts")
    func mixedWiring() async throws {
        let store = try await makeStore()
        let reader = """
            every "1 month"
            input("temp", "Climate.temp")
            output("doubled")
            function step(s, t) s.doubled = s.temp * 2 end
            """
        let template = ModelTemplate(id: "test-reader", name: "Reader", category: .blank, kind: .script(.lua), summary: "",
                                     slotName: "Reader", formula: reader, variable: "doubled", format: .number)
        #expect(store.addModel(template))
        await store.waitUntilIdle()
        let climate = try #require(store.slots.firstIndex { $0.name == "Climate" })
        let readerIndex = try #require(store.slots.firstIndex { $0.name == "Reader" })
        #expect(store.slots[readerIndex].reads == "← Climate.temp")
        store.focus(index: readerIndex)
        let doubled = store.timelineState().focus.samples
        store.focus(index: climate)
        let temps = store.timelineState().focus.samples
        let pairs = Dictionary(temps.map { ($0.time, $0.value) }, uniquingKeysWith: { a, _ in a })
        let matched = doubled.dropFirst().compactMap { sample in pairs[sample.time].map { (sample.value, $0) } }
        #expect(matched.count > 100)
        #expect(matched.allSatisfy { abs($0.0 - 2 * $0.1) < 1e-9 })
    }

    @Test("Script mistakes show in the Formula tab with their line, and block applying")
    func scriptMistakes() async throws {
        let store = try await makeStore()
        #expect(store.addModel(ModelLibrary.blankLua))
        let index = store.focusedIndex
        let original = store.formulaText(forSlotAt: index)
        let broken = original.replacingOccurrences(of: "s.value = s.value * (1 + s.growth / 12)", with: "s.value = = 2")
        store.editFormula(broken, forSlotAt: index)
        store.updateFormulaCheck(forSlotAt: index)
        let check = try #require(store.formulaChecks[store.focused.id])
        #expect(!check.compiles)
        let diagnosis = try #require(check.diagnoses.first)
        #expect(diagnosis.line == 7 && diagnosis.range != nil)
        #expect(!store.applyFormula(forSlotAt: index))
        #expect(store.message == "Fix the script's mistakes first.")

        let changed = original.replacingOccurrences(of: "s.growth / 12", with: "s.growth / 6")
        store.editFormula(changed, forSlotAt: index)
        store.updateFormulaCheck(forSlotAt: index)
        #expect(store.formulaChecks[store.focused.id]?.compiles == true)
        await store.waitUntilIdle()
        #expect(!store.parameterPreview.isEmpty)
        #expect(store.applyFormula(forSlotAt: index))
        #expect(store.configs[index].formula == changed)
        #expect(store.slots[index].model == "Custom Lua script")
        #expect(store.message == "Applied the new script to \(store.slots[index].title)")
    }

    @Test("Wiring problems point inside the script's strings, with fixes")
    func wiringFixes() async throws {
        let store = try await makeStore()
        let source = """
            every "1 month"
            input("temp", "Climat.temp")
            output("x")
            function step(s, t) s.x = s.temp end
            """
        let template = ModelTemplate(id: "test-typo", name: "Typo", category: .blank, kind: .script(.lua), summary: "",
                                     slotName: "Typo", formula: source, variable: "x", format: .number)
        #expect(store.addModel(template))
        let index = store.focusedIndex
        #expect(store.focused.pausedReason != nil)
        store.updateFormulaCheck(forSlotAt: index)
        let check = try #require(store.formulaChecks[store.focused.id])
        let diagnosis = try #require(check.diagnoses.first)
        #expect(diagnosis.title == "There's no slot called Climat")
        let range = try #require(diagnosis.range)
        #expect((source as NSString).substring(with: range) == "Climat.temp")
        let fix = try #require(diagnosis.fixes.first)
        #expect(fix.title == "Use Climate")
        #expect(fix.source.contains("input(\"temp\", \"Climate.temp\")"))
    }

    @Test("An error while running stops the line, and says where")
    func runtimeFailure() async throws {
        let store = try await makeStore()
        let source = """
            every "1 month"
            init("x", 1)
            function step(s, t)
              if t.year > 2030 then error("too far") end
              s.x = s.x + 1
            end
            """
        let template = ModelTemplate(id: "test-fails", name: "Fails", category: .blank, kind: .script(.lua), summary: "",
                                     slotName: "Fails", formula: source, variable: "x", format: .number)
        #expect(store.addModel(template))
        await store.waitUntilIdle()
        let slot = store.focused
        let failure = try #require(store.slotFailures[slot.id])
        #expect(failure.line == 4 && failure.message.contains("too far"))
        // t.year is the end of the step, so the step to February 2030 is the first past 2030.
        #expect(failure.date == utc(2030, 1, 1))
        let state = store.timelineState()
        #expect(state.focus.stoppedReason?.contains("too far") == true)
        #expect(state.focus.samples.last.map { $0.time <= failure.date } == true)
        #expect(store.message?.contains("stopped") == true)

        store.updateFormulaCheck(forSlotAt: store.focusedIndex)
        let check = try #require(store.formulaChecks[slot.id])
        #expect(check.compiles)
        #expect(check.diagnoses.contains { $0.line == 4 && $0.title.contains("Too far") })

        // Fixing the script clears it.
        store.editFormula(source.replacingOccurrences(of: "2030", with: "3000"), forSlotAt: store.focusedIndex)
        #expect(store.applyFormula(forSlotAt: store.focusedIndex))
        await store.waitUntilIdle()
        #expect(store.slotFailures[slot.id] == nil)
        #expect(store.timelineState().focus.stoppedReason == nil)
    }

    @Test("Errors a draft raises while running show in its check")
    func draftRuntimeError() async throws {
        let store = try await makeStore()
        #expect(store.addModel(ModelLibrary.blankLua))
        let index = store.focusedIndex
        await store.waitUntilIdle()
        let draft = store.formulaText(forSlotAt: index).replacingOccurrences(of: "s.value = s.value", with: "s.valeu = s.value")
        store.editFormula(draft, forSlotAt: index)
        store.updateFormulaCheck(forSlotAt: index)
        await store.waitUntilIdle()
        let check = try #require(store.formulaChecks[store.focused.id])
        #expect(check.compiles)
        let diagnosis = try #require(check.diagnoses.first)
        #expect(diagnosis.line == 7 && diagnosis.title.contains("valeu") && diagnosis.title.contains("Did you mean s.value?"))
    }

    @Test("Completion offers the script's own names after s.")
    func completion() {
        let source = "every \"1 month\"\nparam(\"rate\", 1)\ninit(\"balance\", 2)\nfunction step(s, t)\n  s.\nend"
        let cursor = (source as NSString).range(of: "s.\n").location + 2
        let (_, items) = FormulaPane.complete(source, at: cursor, kind: .script(.lua), slots: [], ownName: "Me")
        #expect(items.map(\.text) == ["rate", "balance"])
        #expect(items.map(\.kind) == [.parameter, .variable])
    }
}
