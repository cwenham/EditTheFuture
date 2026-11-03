import Foundation
import Testing
import FutureDocument
import FutureEngine
import FutureSimulation
@testable import FutureUI

/// Simulation modules in slots (docs/DESIGN.md, 6.5): from the picker to scenario.md and back.
@MainActor
@Suite("Module slots")
struct ModuleSlotTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    @Test("The library lists the Epidemic module under Health, as Swift")
    func library() {
        let epidemic = ModelLibrary.epidemic
        #expect(epidemic.kind == .module(ModuleReference(id: "epidemic", version: 1)))
        #expect(epidemic.kind.title == "Swift")
        #expect(epidemic.category == .health)
        #expect(epidemic.variable == "infectious")
        #expect(epidemic.format == .number)
        #expect(ModelLibrary.named("epidemic")?.id == "epidemic")
        #expect(ModelLibrary.search("swift").map(\.id) == ["epidemic", "world-epidemic", "worm"])
        #expect(ModelLibrary.search("infection").map(\.id) == ["epidemic", "world-epidemic"])
    }

    @Test("Adding the module gives a slot that runs, takes its events, and has no formula to edit")
    func adding() async throws {
        let store = try await makeStore()
        #expect(store.addModel(ModelLibrary.epidemic, atPosition: 6))
        let slot = store.focused
        #expect(slot.name == "Outbreak")
        #expect(slot.isModule)
        #expect(slot.summary == "Epidemic · Swift · daily · emits Peak, HerdImmunity")
        #expect(slot.eventKinds == ["imported", "vaccinate"])
        #expect(slot.parameterValues.map(\.name) == ["r0", "incubation", "illness", "population"])
        #expect(slot.startingValues.map(\.name) == ["exposed", "infectious", "recovered", "vaccinated"])
        #expect(slot.outputs.map(\.label).contains("Effective R"))
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.samples.isEmpty)

        // Formula checks leave it alone.
        store.updateFormulaCheck(forSlotAt: store.focusedIndex)
        #expect(store.formulaChecks[slot.id] == nil)
    }

    @Test("A module slot saves as a heading with no block, and reads back the same")
    func saving() async throws {
        let store = try await makeStore()
        store.addModel(ModelLibrary.epidemic, atPosition: 6)
        store.add(Event(time: utc(2026, 3), kind: "vaccinate", values: ["amount": 5000]), toSlotAt: store.focusedIndex)
        let file = store.scenarioFile()
        let saved = try #require(file.slots.first { $0.name == "Outbreak" })
        #expect(saved.module == "epidemic@1")
        #expect(saved.model == "Epidemic")
        #expect(saved.source.isEmpty)

        // It begins at the cursor with its trigger, with nobody incubating before it (5.7).
        let begins = try #require(store.configs[store.focusedIndex].events.first { $0.kind == "imported" }).time
        let text = ScenarioFormat.text(for: file)
        #expect(text.contains("## 7. Outbreak [Epidemic, module: epidemic@1, shows: infectious]\n\n### Values\n- exposed: 0\n\n"
                              + "### Events\n- 2026-03-01 vaccinate [amount: 5000]\n- \(FileDate.text(begins)) imported [amount: 10]"),
                "\(text)")
        let reread = ScenarioDefinition(file: try ScenarioFormat.parse(text).file)
        let spec = try #require(reread.slots.first { $0.name == "Outbreak" })
        #expect(spec.kind == .module(ModuleReference(id: "epidemic", version: 1)))
        #expect(spec.problem == nil)
        #expect(spec.variable == "infectious")
        await store.waitUntilIdle()
    }

    @Test("Without shows, a module slot's graph shows the value the module names, and the file leaves it out")
    func usualVariable() throws {
        let text = "# Test [start: 2026-01-01]\n\n## 1. Outbreak [Epidemic, module: epidemic@1]\n"
        let definition = ScenarioDefinition(file: try ScenarioFormat.parse(text).file)
        #expect(definition.slots[0].variable == "infectious")
        let store = try ScenarioStore(definition: definition, now: now)
        #expect(store.scenarioFile().slots[0].shows == nil)
    }

    @Test("A module the app hasn't got, or too new a version, pauses its slot and says why")
    func missing() async throws {
        let text = """
            # Test [start: 2026-01-01]

            ## 1. Weather [Weather, module: weather@1]

            ## 2. Outbreak [Epidemic, module: epidemic@9]

            ## 3. Typo [Epidemic, module: epi demic]

            """
        let definition = ScenarioDefinition(file: try ScenarioFormat.parse(text).file)
        #expect(definition.slots[2].problem == "“epi demic” isn't a module. Write its name and version, like epidemic@1.")
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        #expect(store.slots[0].pausedReason?.contains("doesn't have") == true)
        #expect(store.slots[1].pausedReason?.contains("Update the app") == true)
        #expect(store.slots[2].isPaused)
    }

    @Test("Changing a formula slot to the module, and undo, swap the model whole")
    func changing() async throws {
        let store = try await makeStore()
        let index = 3  // Climate
        store.changeModel(ofSlotAt: index, to: ModelLibrary.epidemic)
        #expect(store.slots[index].isModule)
        #expect(store.configs[index].formula.isEmpty)
        #expect(store.scenarioFile().slots[index].module == "epidemic@1")
        await store.waitUntilIdle()
        store.undo()
        #expect(store.slots[index].kind == .formula)
        #expect(store.scenarioFile().slots[index].module == nil)
        await store.waitUntilIdle()
    }
}
