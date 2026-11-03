import Foundation
import Testing
import AppKit
import FutureEngine
import FutureFormula
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Formula text view")
struct FormulaTextViewTests {
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
