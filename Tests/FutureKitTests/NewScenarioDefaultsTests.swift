import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit

/// What new scenarios start with, and how dates are written, as chosen in Settings (docs/UI.md, 7).
@MainActor
@Suite("New scenario defaults")
struct NewScenarioDefaultsTests {
    @Test("A new scenario's form starts from Settings' choices, or else the open scenario's")
    func form() throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        store.openScenarioForm(.new)
        #expect(store.scenarioForm?.currency == store.currency)
        #expect(store.scenarioForm?.rates == store.rateSource)

        store.newScenarioDefaults = NewScenarioDefaults(currency: Currency(code: "GBP"), numbers: .style(.pointComma), rates: ExchangeRateSource.none)
        store.openScenarioForm(.new)
        #expect(store.scenarioForm?.currency.code == "GBP")
        #expect(store.scenarioForm?.numbers == .pointComma)
        #expect(store.scenarioForm?.rates == ExchangeRateSource.none)

        store.newScenarioDefaults.numbers = .currencysOwn
        store.openScenarioForm(.new)
        #expect(store.scenarioForm?.numbers == nil)

        // A copy is still the open scenario's.
        store.openScenarioForm(.duplicate)
        #expect(store.scenarioForm?.currency == store.currency)
    }

    @Test("The choices are kept as plain names, and come back the same")
    func stored() {
        let defaults = NewScenarioDefaults(currency: Currency(code: "EUR"), numbers: .style(.spaceComma), rates: .openexchangerates)
        #expect(NewScenarioDefaults(stored: defaults.stored) == defaults)
        #expect(NewScenarioDefaults(stored: [:]) == NewScenarioDefaults())
        #expect(NewScenarioDefaults(stored: ["numbers": "own"]).numbers == .currencysOwn)
        #expect(NewScenarioDefaults(stored: ["numbers": "nonsense", "rates": "nope"]) == NewScenarioDefaults())
    }

    @Test("Dates can be written month first")
    func monthFirst() {
        let date = utc(2031, 3, 15)
        #expect(DateText.dayMonthYear(date, monthFirst: false) == "15 Mar 2031")
        #expect(DateText.dayMonthYear(date, monthFirst: true) == "Mar 15, 2031")
        #expect(DateText.dayMonth(date, monthFirst: true) == "Mar 15")
        #expect(DateText.monthYear(date) == "Mar 2031")
    }

    @Test("A scenario with nothing to hold isn't held")
    func nothingToHold() throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25), holdsScripts: true)
        #expect(!store.requestTrust())
        #expect(!store.isHeld && store.trustRequest == nil)
        #expect(TrustRequest(scripts: 2, feeds: 1).waiting == "2 scripts and 1 data feed")
        #expect(TrustRequest(scripts: 0, feeds: 3).text.contains("feeds tell the sites"))
        #expect(!TrustRequest(scripts: 0, feeds: 3).text.contains("scripts run"))
    }
}
