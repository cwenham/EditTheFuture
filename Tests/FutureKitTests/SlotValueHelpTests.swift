import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit

/// Labels in the Slot tab can be cut short, so hovering shows the whole of it and what it means.
@MainActor
@Suite("Parameter hover text")
struct SlotValueHelpTests {
    @Test("Hovering shows the name, the whole label and what it means")
    func helpText() async throws {
        let worm = try #require(ModelLibrary.template(id: "worm")).slot(position: 0)
        let store = try ScenarioStore(definition: ScenarioDefinition(name: "W", start: utc(2026, 1, 1), slots: [worm]),
                                      now: utc(2026, 11, 3))
        await store.waitUntilIdle()
        let scan = try #require(store.focused.parameterValues.first { $0.name == "scanRate" })
        #expect(scan.help.hasPrefix("scanRate: Scans a second per infected host\nHow many random addresses"))
    }

    @Test("Every built-in simulation says what its parameters and starting values mean")
    func modulesExplainThemselves() async throws {
        for id in ["worm", "world-epidemic", "epidemic"] {
            let slot = try #require(ModelLibrary.template(id: id)).slot(position: 0)
            let store = try ScenarioStore(definition: ScenarioDefinition(name: "M", start: utc(2026, 1, 1), slots: [slot]),
                                          now: utc(2026, 11, 3))
            await store.waitUntilIdle()
            let values = store.focused.parameterValues + store.focused.startingValues
            #expect(!values.isEmpty)
            for value in values { #expect(value.about?.isEmpty == false, "\(id).\(value.name) has no description") }
        }
    }

    @Test("Without a description, it's the name and the label, or just the name")
    func plainHelp() {
        func value(_ name: String, _ label: String) -> SlotValue {
            SlotValue(name: name, label: label, quantity: .number, money: .money(.usd), minimum: nil, maximum: nil,
                      increment: nil, value: 1, defaultValue: 1, isChanged: false)
        }
        #expect(value("rate", "Interest rate").help == "rate: Interest rate")
        #expect(value("rate", "rate").help == "rate")
    }
}
