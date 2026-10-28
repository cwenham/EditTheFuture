import Foundation
import Testing
import FutureDocument
import FutureEngine
import FutureFeeds
@testable import FutureUI

/// Converting money between slots, waiting for rates, regional styles, and fetching rates
/// (docs/DESIGN.md, 5.11; docs/UI.md, 3 and 5.7).
@MainActor
@Suite("Exchange rates in the panel", .serialized)
struct ExchangeRatePanelTests {
    let now = utc(2026, 10, 25)
    let pounds = ExchangeRates(perDollar: [.gbp: [(utc(2024, 1), 0.8)], .eur: [(utc(2024, 1), 0.9)]])
    let frankfurter = """
        {"amount":1.0,"base":"USD","start_date":"1999-01-04","end_date":"2026-10-28",
         "rates":{"2024-01-02":{"GBP":0.8},"2026-10-28":{"GBP":0.75}}}
        """

    /// Stocks in US dollars, and a wallet in the scenario's currency that holds what they're worth.
    func definition(currency: Currency? = .gbp, rates: ExchangeRates = .none, source: ExchangeRateSource? = nil,
                    numbers: NumberStyle? = nil) -> ScenarioDefinition {
        let stocks = SlotSpec(name: "Stocks", formula: """
            step 1 month
            init value = 1000 label "Value" as currency
            value[t] = value[t-1]
            """, variable: "value", format: .currency, currency: .usd)
        let wallet = SlotSpec(name: "Wallet", formula: """
            step 1 month
            param fee = 10 label "Fee" as currency
            init held = 0 label "Held" as currency
            held[t] = Stocks.value - fee
            """, variable: "held", format: .currency)
        return ScenarioDefinition(name: "Mixed", start: utc(2024, 1), currency: currency, rates: source, numbers: numbers,
                                  exchangeRates: rates, slots: [stocks, wallet])
    }

    func makeStore(_ definition: ScenarioDefinition) async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: definition, now: now)
        store.credentials = MemoryCredentialStore()
        await store.waitUntilIdle()
        return store
    }

    func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("etf-rates-" + UUID().uuidString, isDirectory: true)
    }

    @Test("Money read from a slot in another currency is converted at the rate, and says so")
    func converts() async throws {
        let store = try await makeStore(definition(rates: pounds))
        let wallet = store.slots[1]
        #expect(wallet.conversions == [SlotConversion(slot: "Stocks", variable: "value", pair: CurrencyPair(from: .usd, to: .gbp))])
        #expect(wallet.reads == "← Stocks.value ($→£)")
        #expect(store.neededCurrencies == [.gbp])
        store.focus(index: 1)
        #expect(store.cursorState().readoutValue == "£790")  // $1,000 at 0.8, less a £10 fee
        #expect(store.cursorState().laneValues[0] == "$1,000")
        #expect(store.conversionNote(forSlotAt: 1) == "Reads Stocks.value in US dollars, converted to British pounds at "
                + "the European Central Bank's daily rates. $1\u{00A0}=\u{00A0}£0.8000 on 1 Jan 2024. "
                + "There are no earlier rates, so this one is used for every date.")
        #expect(store.conversionNote(forSlotAt: 0) == nil)
        #expect(store.slots[0].hasMoney && wallet.hasMoney)

        // New rates compute it again.
        store.receiveExchangeRates(pounds.merged(with: ExchangeRates(perDollar: [.gbp: [(utc(2025, 1), 0.75)]])))
        await store.waitUntilIdle()
        #expect(store.cursorState().readoutValue == "£740")
    }

    @Test("A slot waits for rates it hasn't got, with the slots that read it, and runs once they come")
    func waits() async throws {
        let store = try await makeStore(definition())
        let reason = "Waiting for exchange rates from US dollars to British pounds, to convert Stocks.value."
        #expect(store.slots[1].pausedReason == reason)
        #expect(store.slots[0].pausedReason == nil)
        #expect(store.neededCurrencies == [.gbp])
        #expect(store.conversionNote(forSlotAt: 1)?.hasPrefix("Reads Stocks.value in US dollars") == true)

        store.receiveExchangeRates(ExchangeRates(perDollar: [.eur: [(utc(2024, 1), 0.9)]]))
        #expect(store.slots[1].isPaused)
        store.receiveExchangeRates(pounds)
        await store.waitUntilIdle()
        #expect(store.slots[1].pausedReason == nil)
        store.focus(index: 1)
        #expect(store.cursorState().readoutValue == "£790")
    }

    @Test("Without converting, money passes as it is; slots in one currency never wait")
    func noConversion() async throws {
        let store = try await makeStore(definition(source: ExchangeRateSource.none))
        #expect(store.slots[1].conversions.isEmpty && !store.slots[1].isPaused && store.neededCurrencies.isEmpty)
        store.focus(index: 1)
        #expect(store.cursorState().readoutValue == "£990")

        // Switching conversion on in the settings makes it wait, and undo puts it back.
        store.applySettingsChange(ScenarioSettings(name: store.name, start: store.start, seed: store.seed,
                                                   currency: store.currencySetting, rates: .ecb, numbers: nil))
        #expect(store.slots[1].isPaused)
        #expect(store.scenarioFile().rates == .ecb)
        store.undo()
        #expect(!store.slots[1].isPaused && store.rateSetting == ExchangeRateSource.none)

        let same = try await makeStore(definition(currency: .usd))
        #expect(same.slots.allSatisfy { $0.conversions.isEmpty && !$0.isPaused })
    }

    @Test("Fingerprints of slots that convert count their rates, and only theirs")
    func fingerprints() async throws {
        let store = try await makeStore(definition(rates: pounds))
        let before = store.fingerprints(libraries: [:])
        store.receiveExchangeRates(pounds.merged(with: ExchangeRates(perDollar: [.gbp: [(utc(2025, 1), 0.75)]])))
        let after = store.fingerprints(libraries: [:])
        #expect(before[0] == after[0])
        #expect(before[1] != after[1] && after[1] != nil)
        store.receiveExchangeRates(store.exchangeRates.merged(with: ExchangeRates(perDollar: [.jpy: [(utc(2025, 1), 150)]])))
        #expect(store.fingerprints(libraries: [:]) == after)
    }

    @Test("Each slot is written in its currency's style, or the scenario's choice")
    func styles() async throws {
        let euros = try await makeStore(definition(currency: .eur, rates: pounds))
        euros.focus(index: 1)
        let readout = euros.cursorState().readoutValue
        #expect(readout == "890\u{00A0}€")  // $1,000 at 0.9, less €10
        #expect(euros.cursorState().laneValues[0] == "$1,000")  // dollars in their own style
        let fee = try #require(euros.slots[1].parameterValues.first)
        #expect(fee.text(123.5) == "123,5\u{00A0}€")
        #expect(fee.text(1234.5) == "1.235\u{00A0}€")  // four figures, as the Slot tab always shows
        #expect(fee.parse("1.234,5") == 1234.5)
        #expect(fee.parse("1.234") == 1234)
        #expect(fee.parse("12,5 €") == 12.5)
        #expect(fee.parse("$12") == nil)
        #expect(euros.timelineState().focus.style.axis(250_000) == "250k\u{00A0}€")
        #expect(euros.conversionNote(forSlotAt: 1)?.contains("$1\u{00A0}=\u{00A0}0,9000\u{00A0}€") == true)
        #expect(ValueStyle.money(.eur).amountText(1234567.891, digits: 2) == "1.234.567,89\u{00A0}€")
        #expect(ValueStyle.money(Currency(code: "INR")!).amountText(1234567.5, digits: 1) == "₹12,34,567.5")

        // Typed in the command bar the same way.
        euros.commandText = "+1.234,50 monthly"
        euros.runCommand()
        #expect(euros.message?.hasPrefix("Added +1.235\u{00A0}€ every month") == true)

        // One style for everything.
        let english = try await makeStore(definition(currency: .eur, rates: pounds, numbers: .commaPoint))
        english.focus(index: 1)
        #expect(english.cursorState().readoutValue == "€890")
        #expect(english.slots[1].parameterValues[0].parse("1.234") == 1.234)
        #expect(english.scenarioFile().numbers == .commaPoint)
    }

    @Test("Two currencies that share a symbol are told apart")
    func sharedSymbols() async throws {
        let canadian = try #require(Currency(code: "CAD"))
        let alone = try await makeStore(definition(currency: canadian, rates: ExchangeRates(perDollar: [canadian: [(utc(2024, 1), 1.4)]]),
                                                   source: ExchangeRateSource.none))
        #expect(alone.slots[1].money.full(1000) == "CA$1,000")  // beside US dollars, so not "$"
        var single = definition(currency: canadian)
        single.slots[0].currency = nil
        let only = try await makeStore(single)
        #expect(only.slots[0].money.full(1000) == "$1,000")  // Canadian dollars on their own
        #expect(ScenarioStore.writings(for: [Currency(code: "SEK")!, Currency(code: "NOK")!], numbers: nil)[Currency(code: "SEK")!]?.symbol == "SEK")
    }

    @Test("The Event tab and the command bar read amounts in the slot's style")
    func typedAmounts() async throws {
        let store = try await makeStore(definition(currency: .eur, rates: pounds))
        store.focus(index: 1)
        store.eventDraft.slotIndex = 1
        store.eventDraft.kind = .setParameter
        store.eventDraft.parameter = "fee"
        store.eventDraft.valueText = "1.500,25"
        guard case .success(.event(let event)) = store.buildDraft() else { Issue.record("no event"); return }
        #expect(event.values["fee"] == 1500.25)
        #expect(ScenarioStore.editableText(1500.25, percent: false, numbers: .pointComma) == "1500,25")
        #expect(ScenarioStore.editableText(6000, percent: false, numbers: .pointComma) == "6.000")
        #expect(ScenarioStore.editableText(6000, percent: false, numbers: .spaceComma) == "6\u{202F}000")
        #expect(try CommandBarParser.parse("set fee 4,5", numbers: .pointComma) == .setParameter(name: "fee", value: 4.5, at: nil))
        #expect(try CommandBarParser.parse("goto wallet 1.000 €", numbers: .pointComma)
                == .findValue(slot: "wallet", value: 1000, format: .currency, currency: "€"))
    }

    @Test("Opening a scenario uses the rates kept with it, then fetches what's due and keeps a copy")
    func center() async throws {
        let folder = makeFolder()
        let package = ScenarioLibrary.package(named: "Mixed", in: folder)
        try ScenarioDocument.create(definition(), at: package)
        // No copy yet: the wallet waits until the rates are fetched.
        var document = try await ScenarioDocument.open(package, now: now, watch: false)
        let transport = QueuedTransport([(200, frankfurter)])
        document.store.feedTransport = transport
        document.store.credentials = MemoryCredentialStore()
        #expect(document.store.slots[1].isPaused)
        document.rates.start(watch: false)
        await document.rates.waitUntilIdle()
        await document.store.waitUntilIdle()
        #expect(!document.store.slots[1].isPaused)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.absoluteString == "https://api.frankfurter.dev/v1/1999-01-04..?base=USD&symbols=GBP")
        let copy = try String(contentsOf: package.url.appendingPathComponent(RateCopy.path), encoding: .utf8)
        #expect(copy == "date,GBP\n2024-01-02,0.8\n2026-10-28,0.75\n")
        #expect(document.store.rateStatus.checked != nil && document.store.rateStatus.error == nil)
        await document.close()

        // With the copy, the wallet runs at once, and a fresh copy isn't fetched again.
        document = try await ScenarioDocument.open(package, now: now, watch: false)
        #expect(!document.store.slots[1].isPaused)
        #expect(document.store.exchangeRates.latest(.gbp)?.perDollar == 0.75)
        let quiet = QueuedTransport([(500, "")])
        document.store.feedTransport = quiet
        document.rates.start(watch: false)
        await document.rates.waitUntilIdle()
        #expect(quiet.requests.isEmpty)
        await document.close()
    }

    @Test("Live rates come on top of the daily ones, with the App ID from the Keychain")
    func liveRates() async throws {
        let folder = makeFolder()
        let package = ScenarioLibrary.package(named: "Mixed", in: folder)
        try ScenarioDocument.create(definition(source: .openexchangerates), at: package)
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        let transport = QueuedTransport([(200, frankfurter), (200, """
            {"timestamp": 1793195400, "base": "USD", "rates": {"GBP": 0.7}}
            """)])
        document.store.feedTransport = transport
        document.store.credentials = MemoryCredentialStore([
            "openexchangerates": FeedCredential(kind: .key, secret: "app-123", hosts: ["openexchangerates.org"]),
        ])
        document.rates.start(watch: false)
        await document.rates.waitUntilIdle()
        #expect(transport.requests.map { $0.url?.host } == ["api.frankfurter.dev", "openexchangerates.org"])
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Token app-123")
        #expect(document.store.exchangeRates.latest(.gbp)?.perDollar == 0.7)
        #expect(document.store.exchangeRates.perDollar(.gbp, at: utc(2025, 1)) == 0.8)  // history from the ECB
        let live = try String(contentsOf: package.url.appendingPathComponent(RateCopy.livePath), encoding: .utf8)
        #expect(live.hasPrefix("date,GBP\n") && live.hasSuffix(",0.7\n"))
        #expect(document.store.conversionNote(forSlotAt: 1)?.contains("latest rates from Open Exchange Rates") == true)
        await document.close()
    }

    @Test("A failed fetch says why, and keeps the copy")
    func failure() async throws {
        let folder = makeFolder()
        let package = ScenarioLibrary.package(named: "Mixed", in: folder)
        try ScenarioDocument.create(definition(source: .openexchangerates), at: package)
        let document = try await ScenarioDocument.open(package, now: now, watch: false)
        let transport = QueuedTransport([(200, frankfurter)])
        document.store.feedTransport = transport
        document.store.credentials = MemoryCredentialStore()
        document.rates.start(watch: false)
        await document.rates.waitUntilIdle()
        #expect(document.store.rateStatus.error == "Open Exchange Rates needs an App ID. Add one in the scenario's settings.")
        #expect(document.store.message?.hasPrefix("Couldn't fetch exchange rates from Open Exchange Rates") == true)
        #expect(!document.store.slots[1].isPaused)  // the daily rates came
        // It doesn't ask again until it's due.
        document.rates.sync()
        await document.rates.waitUntilIdle()
        #expect(transport.requests.count == 1)
        await document.close()
    }

    @Test("The form chooses the style and the rates, and saves an App ID only in the Keychain")
    func form() async throws {
        let store = try await makeStore(definition(rates: pounds))
        let credentials = MemoryCredentialStore()
        store.credentials = credentials
        store.openScenarioForm(.edit)
        #expect(store.scenarioForm?.rates == .ecb && store.scenarioForm?.numbers == nil)
        store.scenarioForm?.numbers = .spaceComma
        store.scenarioForm?.rates = .openexchangerates
        store.scenarioForm?.appID = "  app-456 "
        store.feedTransport = QueuedTransport([(200, "{\"timestamp\": 1793195400, \"rates\": {\"GBP\": 0.7531}}")])
        await store.testLiveRates()
        #expect(store.scenarioForm?.rateTest == "Works: $1\u{00A0}=\u{00A0}0,7531\u{00A0}£, as of 28 Oct 2026.")
        #expect(credentials.hasCredential(named: "openexchangerates") == false)  // Test saves nothing
        #expect(await store.submitScenarioForm(nil))
        let saved = try #require(try credentials.credential(named: "openexchangerates"))
        #expect(saved.secret == "app-456" && saved.hosts == ["openexchangerates.org"])
        #expect(store.rateSetting == .openexchangerates && store.numberSetting == .spaceComma)
        let heading = ScenarioFormat.text(for: store.scenarioFile()).split(separator: "\n")[0]
        #expect(heading == "# Mixed [start: 2024-01-01, currency: GBP, rates: openexchangerates, numbers: space-comma]")
        #expect(!heading.contains("app-456"))
        store.focus(index: 1)
        #expect(store.cursorState().readoutValue == "790\u{00A0}£")

        // Choosing the ECB when the file leaves it unsaid keeps it unsaid.
        let plain = try await makeStore(definition(rates: pounds))
        plain.openScenarioForm(.edit)
        #expect(await plain.submitScenarioForm(nil))
        #expect(!plain.canUndo && plain.rateSetting == nil)
    }
}
