import Foundation
import Testing
import AppKit
import SwiftUI
import FutureEngine
import FutureFormula
@testable import FutureUI

/// The formula editor: drafts, checks, fixes, the preview and applying (docs/UI.md, 5.7).
@MainActor
@Suite("Formula editing")
struct FormulaEditingTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    func index(_ store: ScenarioStore, _ name: String) throws -> Int {
        try #require(store.slots.firstIndex { $0.name == name })
    }

    @Test("A draft is kept apart from the slot until it's applied, and undo puts the old formula back")
    func draftAndApply() async throws {
        let store = try await makeStore()
        let original = store.formulaText(forSlotAt: 0)
        store.showFormulaEditor()
        #expect(store.sidePane == .formula)
        let edited = original.replacingOccurrences(of: "* (1 + rate / 12)", with: "* (1 + rate / 12) * 1.01")
        store.editFormula(edited, forSlotAt: 0)
        #expect(store.hasFormulaDraft(forSlotAt: 0))
        #expect(store.configs[0].formula == original)
        store.editFormula(original, forSlotAt: 0)
        #expect(!store.hasFormulaDraft(forSlotAt: 0))  // typing it back drops the draft

        store.editFormula(edited, forSlotAt: 0)
        store.updateFormulaCheck(forSlotAt: 0)
        let check = try #require(store.formulaChecks[store.slots[0].id])
        #expect(check.compiles && check.runs && check.diagnoses.isEmpty)
        #expect(check.text == edited)

        // The dashed preview shows the draft.
        await store.waitUntilIdle()
        #expect(!store.parameterPreview.isEmpty)
        let state = store.timelineState()
        #expect(state.focus.preview == store.parameterPreview)
        #expect(state.focus.preview.last!.value > state.focus.samples.last!.value)

        #expect(store.applyFormula(forSlotAt: 0))
        #expect(store.configs[0].formula == edited)
        #expect(store.slots[0].model == "Savings account (edited)")
        #expect(!store.hasFormulaDraft(forSlotAt: 0))
        #expect(store.parameterPreview.isEmpty)
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.samples.last == state.focus.preview.last)

        store.undo()
        #expect(store.configs[0].formula == original)
        #expect(store.slots[0].model == "Savings account")
    }

    @Test("Mistakes block applying and come with fixes")
    func mistakes() async throws {
        let store = try await makeStore()
        let broken = store.formulaText(forSlotAt: 0).replacingOccurrences(of: "rate / 12", with: "rat / 12")
        store.editFormula(broken, forSlotAt: 0)
        store.updateFormulaCheck(forSlotAt: 0)
        let check = try #require(store.formulaChecks[store.slots[0].id])
        #expect(!check.compiles)
        #expect(check.diagnoses.first?.title == "rat isn't defined")
        #expect(!store.applyFormula(forSlotAt: 0))
        #expect(store.message == "Fix the formula's mistakes first.")

        store.useFormulaFix(try #require(check.diagnoses.first?.fixes.first), forSlotAt: 0)
        #expect(store.formulaChecks[store.slots[0].id]?.compiles == true)
        #expect(!store.hasFormulaDraft(forSlotAt: 0))  // the fix put it back as it was

        store.editFormula("step 1 month\nx[t] = 1 +", forSlotAt: 0)
        store.revertFormula(forSlotAt: 0)
        #expect(!store.hasFormulaDraft(forSlotAt: 0))
        #expect(store.formulaChecks[store.slots[0].id]?.diagnoses.isEmpty == true)
    }

    @Test("Reading other slots is checked too, with fixes")
    func otherSlots() async throws {
        let store = try await makeStore()
        let bill = try index(store, "EnergyBill")
        let text = store.formulaText(forSlotAt: bill)

        store.editFormula(text.replacingOccurrences(of: "15 - Climate.temp", with: "15 - Climate.tmp"), forSlotAt: bill)
        store.updateFormulaCheck(forSlotAt: bill)
        var check = try #require(store.formulaChecks[store.slots[bill].id])
        #expect(check.compiles && !check.runs)
        #expect(check.diagnoses.first?.title == "Climate has no value called tmp")
        #expect(check.diagnoses.first?.fixes.first?.title == "Use Climate.temp")
        store.useFormulaFix(check.diagnoses.first!.fixes.first!, forSlotAt: bill)
        #expect(!store.hasFormulaDraft(forSlotAt: bill))

        store.editFormula(text.replacingOccurrences(of: "Climate.temp", with: "Climat.temp"), forSlotAt: bill)
        store.updateFormulaCheck(forSlotAt: bill)
        check = try #require(store.formulaChecks[store.slots[bill].id])
        #expect(check.diagnoses.first?.title == "There's no slot called Climat")
        #expect(check.diagnoses.first?.fixes.first?.source == text)

        // Reading Energy bill in the same step closes a loop; the fix reads it from the step before.
        let climate = try index(store, "Climate")
        let climateText = store.formulaText(forSlotAt: climate)
        store.editFormula(climateText + "\nload[t] = EnergyBill.bill * 2", forSlotAt: climate)
        store.updateFormulaCheck(forSlotAt: climate)
        check = try #require(store.formulaChecks[store.slots[climate].id])
        #expect(check.diagnoses.first?.title == "Climate and Energy bill depend on each other within the same step")
        let fix = try #require(check.diagnoses.first?.fixes.first)
        #expect(fix.title == "Use EnergyBill.bill[t-1]")
        store.useFormulaFix(fix, forSlotAt: climate)
        #expect(store.formulaChecks[store.slots[climate].id]?.runs == true)

        // Taking away a value another slot reads warns that slot will pause.
        store.editFormula(climateText.replacingOccurrences(of: "temp[t]", with: "temperature[t]")
            .replacingOccurrences(of: "when temp", with: "when temperature"), forSlotAt: climate)
        store.updateFormulaCheck(forSlotAt: climate)
        check = try #require(store.formulaChecks[store.slots[climate].id])
        #expect(check.runs)
        #expect(check.diagnoses.map(\.title) == ["Energy bill would pause"])
        #expect(check.diagnoses.first?.severity == .warning)
    }

    @Test("Applying keeps the graph on a value that still exists")
    func applyChangesDisplayedValue() async throws {
        let store = try await makeStore()
        store.editFormula("step 1 month\ninit pot = 5\npot[t] = pot[t-1] + 1", forSlotAt: 0)
        #expect(store.applyFormula(forSlotAt: 0))
        #expect(store.slots[0].variable == "pot")
        #expect(store.configs[0].values.isEmpty)
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.samples.isEmpty)
    }

    @Test("Checks wait for typing to pause")
    func debounce() async throws {
        let store = try await makeStore()
        store.editFormula("step 1 month\nx[t] = 1 + ", forSlotAt: 0)
        #expect(store.formulaChecks[store.slots[0].id] == nil)
        // It arrives after the pause. Other tests can keep the main thread busy, so wait up to 10 s.
        let started = Date()
        while store.formulaChecks[store.slots[0].id] == nil, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Date().timeIntervalSince(started) >= 0.25)
        #expect(store.formulaChecks[store.slots[0].id]?.compiles == false)
    }

    @Test("Drafts survive switching slots and go with a removed slot")
    func draftsPerSlot() async throws {
        let store = try await makeStore()
        store.editFormula("step 1 year\ninit q = 1\nq[t] = q[t-1]", forSlotAt: 1)
        store.focus(index: 2)
        #expect(store.hasFormulaDraft(forSlotAt: 1))
        #expect(store.formulaText(forSlotAt: 1).hasPrefix("step 1 year"))
        store.removeSlot(at: 1)
        #expect(store.formulaDrafts.isEmpty)
    }

    @Test("A blank formula opens the editor")
    func blankFormula() async throws {
        let store = try await makeStore()
        store.addModel(ModelLibrary.blankFormula, atPosition: 5)
        #expect(store.sidePane == .formula)
        #expect(store.focused.model == "Custom formula")
        #expect(store.focused.name == "Formula")
        let summaries = store.formulaSlotSummaries(excludingSlotAt: store.focusedIndex)
        #expect(!summaries.contains { $0.name == "Formula" })
        #expect(summaries.first { $0.name == "Climate" }?.values.map(\.label).contains("Temperature") == true)
        #expect(summaries.first { $0.name == "Climate" }?.events == ["Heatwave"])
    }

    @Test("The text view completes as you type, and a choice continues completing")
    func textViewCompletion() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = FormulaEditorContainer()
        container.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        window.contentView = container
        let textView = container.textView
        let state = FormulaCompletionState()
        let slots = [FormulaSlotSummary(name: "Climate", values: [("temp", "Temperature")], events: ["Heatwave"])]
        textView.completion = state
        textView.completionSource = { FormulaCompleter.complete($0, at: $1, slots: slots, ownName: "Savings") }
        window.makeFirstResponder(textView)

        textView.insertText("x[t] = Cl", replacementRange: textView.selectedRange())
        #expect(state.items.map(\.text) == ["Climate.", "clamp()"])
        #expect(state.anchor.y > 0)
        state.move(1)
        state.move(-1)
        textView.accept(state.items[0])
        #expect(textView.string == "x[t] = Climate.")
        #expect(state.items.map(\.text) == ["temp"])  // straight on to its values
        textView.accept(state.items[0])
        #expect(textView.string == "x[t] = Climate.temp")
        #expect(!state.isVisible)

        textView.insertText(" + cla", replacementRange: textView.selectedRange())
        textView.accept(try #require(state.items.first { $0.text == "clamp()" }))
        #expect(textView.string == "x[t] = Climate.temp + clamp()")
        #expect(textView.selectedRange().location == ("x[t] = Climate.temp + clamp(" as NSString).length)

        textView.insertText(" ", replacementRange: textView.selectedRange())
        #expect(!state.isVisible)  // a space ends it
        textView.insertText("ye", replacementRange: textView.selectedRange())
        #expect(state.isVisible)
        textView.cancelOperation(nil)
        #expect(!state.isVisible)  // Esc closes the list first

        textView.highlight(diagnoses: [FormulaDiagnosis(severity: .error, title: "x", line: 1,
                                                        range: NSRange(location: 0, length: 1))])
        let underline = textView.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        #expect(underline != nil)
    }
}
