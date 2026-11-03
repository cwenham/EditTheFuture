import Foundation
import Testing
import FutureEngine
@testable import FutureUI

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

    @Test("The side pane's width stays between its minimum and what leaves the timeline room")
    func paneWidths() {
        #expect(SidePane.clamped(100, for: .slot, area: 1360) == SidePane.minimumWidth)
        #expect(SidePane.clamped(100, for: .formula, area: 1360) == SidePane.minimumFormulaWidth)
        #expect(SidePane.clamped(5000, for: .slot, area: 1360) == 1360 - PanelView.paneGap - SidePane.timelineRoom)
        #expect(SidePane.clamped(400, for: .slot, area: 1360) == 400)
        // A narrow window still gives the pane its minimum, and an unreadable width falls back to the default.
        #expect(SidePane.clamped(400, for: .slot, area: 500) == SidePane.minimumWidth)
        #expect(SidePane.clamped(.nan, for: .slot, area: 1360) == SidePane.width)
    }
}
