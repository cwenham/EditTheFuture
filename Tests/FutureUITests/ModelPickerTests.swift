import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Model picker and script completion")
struct ModelPickerTests {
    @Test("Completion offers the script's own names after s.")
    func completion() {
        let source = "every \"1 month\"\nparam(\"rate\", 1)\ninit(\"balance\", 2)\nfunction step(s, t)\n  s.\nend"
        let cursor = (source as NSString).range(of: "s.\n").location + 2
        let (_, items) = FormulaPane.complete(source, at: cursor, kind: .script(.lua), slots: [], ownName: "Me")
        #expect(items.map(\.text) == ["rate", "balance"])
        #expect(items.map(\.kind) == [.parameter, .variable])
    }

    @Test("The picker can add every library model, scripts included, and previews the ones that stand alone")
    func pickerFacts() async throws {
        for template in ModelLibrary.all {
            let facts = TemplateFacts.of(template, modules: .app)
            #expect(facts.error == nil, "\(template.name): \(facts.error ?? "")")
            // Hold the latest has nothing to set: its readings make its line.
            if template.id != "forecast-holdTheLatest" {
                #expect(!facts.parameters.isEmpty, "\(template.name) shows no parameters")
            }
            #expect(facts.line.hasPrefix(template.kind.title), "\(template.name): \(facts.line)")
            if facts.reads == nil {
                let preview = await TemplatePreview.samples(for: template, start: utc(2026, 1, 1), modules: .app)
                #expect(preview.count > 20, "\(template.name) has no preview")
            }
        }
    }
}
