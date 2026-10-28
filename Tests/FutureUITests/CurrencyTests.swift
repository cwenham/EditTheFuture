import Foundation
import Testing
import FutureDocument
import FutureEngine
import FutureFeeds
@testable import FutureUI

@Suite("Writing money")
struct MoneyFormattingTests {
    @Test("Amounts in other currencies, full and on axes")
    func styles() throws {
        let pounds = ValueStyle.money(.gbp), euros = ValueStyle.money(.eur)
        let francs = ValueStyle.money(try #require(Currency(code: "CHF")))
        #expect(pounds.full(41223.4) == "£41,223")
        #expect(pounds.full(-6000) == "−£6,000")
        // Each in its own style: euros after the number, francs with apostrophes.
        #expect(euros.axis(250_000) == "250k\u{00A0}€")
        #expect(euros.axis(0) == "0\u{00A0}€")
        #expect(euros.full(-1_234_567) == "−1.234.567\u{00A0}€")
        #expect(francs.full(1200) == "CHF\u{00A0}1’200")
        #expect(francs.axis(-1_250_000) == "−CHF\u{00A0}1.25M")
        #expect(ValueStyle(.currency, currency: .eur, writing: MoneyWriting.plain(.eur)).axis(250_000) == "€250k")
        #expect(pounds.axis(2.5e25) == "£2.5e25")
        #expect(pounds.full(-.infinity) == "−£∞")
        #expect(pounds.full(.nan) == "—")
        #expect(ValueStyle(.percent, currency: .gbp).full(0.045) == "4.5%")
    }

    @Test("Typed values keep the currency typed with them")
    func typed() throws {
        func goto(_ text: String) throws -> CommandBarAction { try CommandBarParser.parse("goto " + text) }
        #expect(try goto("£1M") == .findValue(slot: nil, value: 1_000_000, format: .currency, currency: "£"))
        #expect(try goto("500 euros") == .findValue(slot: nil, value: 500, format: .currency, currency: "euros"))
        #expect(try goto("2k EUR") == .findValue(slot: nil, value: 2000, format: .currency, currency: "eur"))
        #expect(try goto("500 chf") == .findValue(slot: nil, value: 500, format: .currency, currency: "chf"))
        #expect(try goto("savings £5k") == .findValue(slot: "savings", value: 5000, format: .currency, currency: "£"))
        #expect(try goto("savings 50000") == .findValue(slot: "savings", value: 50_000, format: nil))
        #expect(try CommandBarParser.parse("+500 euros monthly")
                == .addEvent(kind: "deposit", amount: 500, at: nil, repeats: .monthly, currency: "euros"))
        #expect(try CommandBarParser.parse("-£1,200 on Aug 2028")
                == .addEvent(kind: "withdraw", amount: 1200, at: utc(2028, 8), repeats: nil, currency: "£"))
        #expect(try CommandBarParser.parse("+500 from 2027-03")
                == .addEvent(kind: "deposit", amount: 500, at: utc(2027, 3), repeats: nil))
        for text in ["£", "€°C"] {
            #expect(throws: CommandBarError.badGoto(text)) { try goto(text) }
        }
    }

    @Test("The table's headings say what money is in")
    func table() {
        let data = SnapshotData(scenario: "Budget", createdAt: utc(2026, 1), start: utc(2026, 1), end: utc(2026, 3),
                                cursor: utc(2026, 2), now: utc(2026, 2), slots: [
            .init(name: "Savings", variable: "balance", color: "#5AA9FF", format: .currency, currency: "GBP",
                  points: [.init(t: utc(2026, 1), v: 100)]),
            .init(name: "Climate", variable: "temp", color: "#FF7A93", format: .temperature,
                  points: [.init(t: utc(2026, 1), v: 2.5)]),
        ])
        #expect(data.tsv().hasPrefix("Date\tSavings (balance, GBP)\tClimate (temp)\n"))
    }
}

/// A scenario's currency and a slot's own, in the panel (docs/UI.md, 3 and 5.7).
@MainActor
@Suite("Currencies in the panel", .serialized)
struct CurrencyPanelTests {
    let now = utc(2026, 10, 25)

    func makeStore(currency: Currency? = .gbp) async throws -> ScenarioStore {
        var definition = ScenarioDefinition.homeAndMoney
        definition.currency = currency
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("etf-money-" + UUID().uuidString, isDirectory: true)
    }

    @Test("Without a currency a scenario is in US dollars, as before")
    func dollarsByDefault() async throws {
        let store = try await makeStore(currency: nil)
        #expect(store.currency == .usd && store.currencySetting == nil)
        #expect(store.cursorState().readoutValue.hasPrefix("$"))
        #expect(store.scenarioFile().currency == nil)
    }

    @Test("Readouts, lanes, axes, values and events are written in the scenario's currency")
    func scenarioCurrency() async throws {
        let store = try await makeStore()
        #expect(store.slots.map(\.currency) == Array(repeating: .gbp, count: 5))
        let cursor = store.cursorState()
        #expect(cursor.readoutValue.hasPrefix("£"))
        #expect(cursor.laneValues[1]?.hasPrefix("£") == true)  // Index fund
        #expect(cursor.laneValues[3]?.hasSuffix("°C") == true)  // Climate isn't money
        let timeline = store.timelineState()
        #expect(timeline.focus.style == .money(.gbp))
        #expect(timeline.focus.events.contains { $0.label == "−£6,000" })
        let savings = store.slots[0]
        #expect(savings.startingValues[0].text(18000) == "£18,000")
        #expect(savings.startingValues[0].parse("£20,000") == 20_000)
        #expect(savings.startingValues[0].parse("20k") == 20_000)
        #expect(savings.startingValues[0].parse("$20,000") == nil)  // nothing converts it
        #expect(savings.parameterValues.first { $0.name == "rate" }?.text(0.045) == "4.5%")
        #expect(store.scenarioFile().currency == .gbp)
    }

    @Test("Changing the scenario's currency relabels its money, and undo puts it back")
    func changeScenarioCurrency() async throws {
        let store = try await makeStore(currency: nil)
        let before = store.cursorState().readoutValue
        store.openScenarioForm(.edit)
        #expect(store.scenarioForm?.currency == .usd)
        store.scenarioForm?.currency = .eur
        #expect(await store.submitScenarioForm(nil))
        await store.waitUntilIdle()
        #expect(store.currencySetting == .eur)
        #expect(store.message?.contains("now in euros") == true)
        // The same amount, written as euros usually are.
        #expect(store.cursorState().readoutValue.filter(\.isNumber) == before.filter(\.isNumber))
        #expect(store.cursorState().readoutValue.hasSuffix("\u{00A0}€"))
        #expect(store.slots[0].startingValues[0].text(18000) == "18.000\u{00A0}€")

        store.undo()
        #expect(store.currencySetting == nil)
        #expect(store.cursorState().readoutValue == before)
        store.redo()
        #expect(store.currencySetting == .eur)

        // Choosing US dollars when the file left them unsaid changes nothing.
        let plain = try await makeStore(currency: nil)
        plain.openScenarioForm(.edit)
        #expect(await plain.submitScenarioForm(nil))
        #expect(!plain.canUndo && plain.currencySetting == nil)
    }

    @Test("A slot can have a currency of its own, written in its heading, and undo takes it back")
    func slotCurrency() async throws {
        let store = try await makeStore()
        #expect(store.slots[0].hasMoney && !store.slots[3].hasMoney)  // Savings, Climate
        store.setCurrency(.usd, inSlotAt: 1)
        await store.waitUntilIdle()
        #expect(store.slots[1].currency == .usd && store.slots[1].ownCurrency == .usd)
        #expect(store.slots[0].currency == .gbp)
        #expect(store.focused.title == "Index fund")  // a slot change focuses the slot
        #expect(store.cursorState().readoutValue.hasPrefix("$"))
        #expect(store.cursorState().laneValues[0]?.hasPrefix("£") == true)
        #expect(store.scenarioFile().slots[1].currency == .usd)
        #expect(ScenarioFormat.text(for: store.scenarioFile()).contains("## 2. IndexFund [Index fund, shows: value, currency: USD]"))

        // A new scenario currency leaves the slot's own alone.
        store.applySettingsChange(ScenarioSettings(name: store.name, start: store.start, seed: store.seed, currency: .jpy))
        #expect(store.slots[0].currency == .jpy && store.slots[1].currency == .usd)

        store.undo()
        store.undo()
        #expect(store.slots[1].ownCurrency == nil && store.slots[1].currency == .gbp)
        #expect(ScenarioStore.currencyChoices(including: [Currency(code: "HNL")!]).contains { $0.code == "HNL" })
        #expect(ScenarioStore.currencyChoices().first?.name == "Argentine peso")  // by name
    }

    @Test("goto and the command bar take only the slot's currency")
    func commandBar() async throws {
        let store = try await makeStore()
        store.setCurrency(.usd, inSlotAt: 2)  // Mortgage
        await store.waitUntilIdle()

        store.commandText = "goto savings $5"
        store.runCommand()
        #expect(store.message == "Savings is in British pounds, not US dollars.")

        store.focus(named: "climate")
        store.commandText = "goto $100k"
        store.runCommand()
        #expect(store.message?.hasPrefix("Looking for $100,000 in Mortgage") == true)  // the only slot in dollars

        store.commandText = "goto £1M"
        store.runCommand()
        #expect(store.message?.hasPrefix("Which slot? Savings, Index fund and Energy bill are in British pounds.") == true)

        store.commandText = "goto 5 yen"
        store.runCommand()
        #expect(store.message == "No slot is in Japanese yen.")

        store.focus(named: "savings")
        let events = store.timelineState().focus.events.count
        store.commandText = "+€500"
        store.runCommand()
        #expect(store.messageIsError)
        #expect(store.message == "Savings is in British pounds. Type the amount in £, or without a currency.")
        store.commandText = "+500 pounds monthly"
        store.runCommand()
        #expect(store.message?.hasPrefix("Added +£500 every month") == true)
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.events.count == events + 1)
    }

    @Test("The Event tab refuses an amount in another currency, and previews in the slot's")
    func eventTab() async throws {
        let store = try await makeStore()
        store.eventDraft.amountText = "€500"
        #expect(!store.draftIsComplete)
        #expect(!store.commitEvent())
        #expect(store.draftError == "This slot is in British pounds. Type the amount in £, or without a currency.")
        store.eventDraft.amountText = "£500"
        #expect(store.draftIsComplete)
        #expect(store.commitEvent())
        #expect(store.message?.contains("+£500") == true)
    }

    @Test("A ready-made feed in US dollars keeps its slot in dollars")
    func dollarFeed() async throws {
        let store = try await makeStore()
        let oil = try #require(FeedCatalog.preset(id: "oil"))
        #expect(oil.currency == .usd)
        #expect(store.addFeedSlot(oil.spec, name: oil.slotName, format: .currency, currency: oil.currency, step: oil.step, atPosition: 5))
        await store.waitUntilIdle()
        let slot = try #require(store.slots.first { $0.title == "Oil" })
        #expect(slot.currency == .usd && slot.ownCurrency == .usd)
        #expect(FeedCatalog.all.filter { $0.format == "currency" }.allSatisfy { $0.currency == .usd })
    }

    @Test("New scenarios and copies take the open scenario's currency, or the one chosen")
    func newScenarios() async throws {
        let folder = makeFolder()
        var definition = ScenarioDefinition.homeAndMoney
        definition.currency = .gbp
        let package = ScenarioLibrary.package(named: definition.name, in: folder)
        try ScenarioDocument.create(definition, at: package)
        #expect(try package.readText().hasPrefix("# Home & money [start: 2022-01-01, currency: GBP]\n"))
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        await document.store.waitUntilIdle()
        let store = document.store
        var opened: [ScenarioPackage] = []
        let menu = ScenarioMenuActions(folder: folder, current: { document.package }, save: { _ = document.save() },
                                       open: { opened.append($0) }, showInFinder: {}, openOther: {})

        store.openScenarioForm(.new, actions: menu)
        #expect(store.scenarioForm?.currency == .gbp)
        store.scenarioForm?.name = "Garden"
        #expect(await store.submitScenarioForm(menu))
        #expect(try opened[0].readText().hasPrefix("# Garden [start: 2026-01-01, currency: GBP]\n"))

        store.openScenarioForm(.duplicate, actions: menu)
        store.scenarioForm?.currency = .eur
        #expect(await store.submitScenarioForm(menu))
        #expect(try opened[1].readText().hasPrefix("# Home & money copy [start: 2022-01-01, currency: EUR]\n"))
        await document.close()

        // The built-in scenario starts in the Mac's currency.
        let first = try ScenarioLibrary.initial(lastOpened: nil, in: makeFolder(), currency: .jpy)
        #expect(try first.readText().hasPrefix("# Home & money [start: 2022-01-01, currency: JPY]\n"))
    }

    @Test("A currency changed in another editor is picked up")
    func reload() async throws {
        let store = try await makeStore(currency: nil)
        var file = store.scenarioFile()
        file.currency = .eur
        file.slots[2].currency = .usd
        store.reload(from: ScenarioDefinition(file: file))
        await store.waitUntilIdle()
        #expect(store.currency == .eur)
        #expect(store.slots.map(\.currency.code) == ["EUR", "EUR", "USD", "EUR", "EUR"])
        #expect(store.cursorState().readoutValue.hasSuffix("€"))
    }
}
