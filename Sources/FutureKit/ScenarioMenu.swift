import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

// The scenario menu in the panel's header, and its form (docs/UI.md, 3): switching scenarios,
// making new ones, and changing a scenario's name, start date, seed and currency.

/// A scenario's name, start date, seed and currency: what the heading of its `scenario.md` holds
/// (docs/DESIGN.md, 15.2).
public struct ScenarioSettings: Equatable, Sendable {
    public var name: String
    public var start: Date
    /// nil for the engine's own (docs/DESIGN.md, 4.4).
    public var seed: UInt64?
    /// nil when the file doesn't name one, which means US dollars.
    public var currency: Currency?
    /// Where exchange rates come from: nil for the ECB's.
    public var rates: ExchangeRateSource?
    /// How numbers are written: nil for each currency in its own style.
    public var numbers: NumberStyle?

    public init(name: String, start: Date, seed: UInt64?, currency: Currency? = nil, rates: ExchangeRateSource? = nil,
                numbers: NumberStyle? = nil) {
        self.name = name
        self.start = start
        self.seed = seed
        self.currency = currency
        self.rates = rates
        self.numbers = numbers
    }
}

/// A scenario to make from the scenario menu's form: new, or a copy of the open one.
public struct NewScenario: Sendable {
    public var name: String
    public var start: Date
    /// nil leaves it unsaid in the file: US dollars.
    public var currency: Currency?
    /// nil leaves it unsaid: the ECB's rates.
    public var rates: ExchangeRateSource?
    /// nil writes each currency in its own style.
    public var numbers: NumberStyle?

    public init(name: String, start: Date, currency: Currency?, rates: ExchangeRateSource?, numbers: NumberStyle?) {
        self.name = name
        self.start = start
        self.currency = currency
        self.rates = rates
        self.numbers = numbers
    }
}

/// What the scenario menu needs from the app: the scenarios and opening them. FutureFiles makes
/// these for a folder of `.etf` scenarios (`ScenarioMenuActions(folder:…)`); an app that keeps its
/// scenarios elsewhere gives its own.
public struct ScenarioMenuActions {
    /// The scenarios the menu lists, in the order it lists them, with the open one among them.
    public var scenarios: () -> [ScenarioPackage]
    /// The names a scenario made in this mode can't have: folder names (`ScenarioPackage.folderName`),
    /// lowercased, since the Mac's disks ignore case.
    public var takenNames: (ScenarioForm.Mode) -> Set<String>
    /// The scenario that's open.
    public var current: () -> ScenarioPackage?
    /// Saves the open scenario now, so a copy of it is up to date.
    public var save: () -> Void
    /// Opens a scenario in the panel, in place of the one open now.
    public var open: (ScenarioPackage) -> Void
    public var showInFinder: () -> Void
    /// Picks a scenario from anywhere to open, as Open Scenario… in the menu bar item does.
    public var openOther: () -> Void
    /// Makes a scenario with one blank formula, or a copy of the one given, and says where it is.
    /// It's called off the main thread.
    public var make: @Sendable (NewScenario, _ copying: ScenarioPackage?) throws -> ScenarioPackage
    /// The folder new scenarios go in, if they go in one. The menu says where scenarios outside it are.
    public var folder: URL?

    public init(scenarios: @escaping () -> [ScenarioPackage], takenNames: @escaping (ScenarioForm.Mode) -> Set<String>,
                current: @escaping () -> ScenarioPackage?, save: @escaping () -> Void, open: @escaping (ScenarioPackage) -> Void,
                showInFinder: @escaping () -> Void, openOther: @escaping () -> Void,
                make: @escaping @Sendable (NewScenario, _ copying: ScenarioPackage?) throws -> ScenarioPackage, folder: URL? = nil) {
        self.scenarios = scenarios
        self.takenNames = takenNames
        self.current = current
        self.save = save
        self.open = open
        self.showInFinder = showInFinder
        self.openOther = openOther
        self.make = make
        self.folder = folder
    }
}

/// The scenario menu's form: the open scenario's settings, or a new scenario's.
/// What a new scenario starts with, chosen in Settings (docs/UI.md, 7). Each nil means the open
/// scenario's, as a copy has.
public struct NewScenarioDefaults: Equatable, Sendable {
    public enum Numbers: Equatable, Sendable {
        /// Each currency written its own way.
        case currencysOwn
        case style(NumberStyle)
    }

    public var currency: Currency?
    public var numbers: Numbers?
    public var rates: ExchangeRateSource?

    public init(currency: Currency? = nil, numbers: Numbers? = nil, rates: ExchangeRateSource? = nil) {
        self.currency = currency
        self.numbers = numbers
        self.rates = rates
    }

    /// As it's kept in the app's settings: codes and names, with nothing for the open scenario's.
    public var stored: [String: String] {
        var stored: [String: String] = [:]
        stored["currency"] = currency?.code
        switch numbers {
        case nil: break
        case .currencysOwn?: stored["numbers"] = "own"
        case .style(let style)?: stored["numbers"] = style.rawValue
        }
        stored["rates"] = rates?.rawValue
        return stored
    }

    public init(stored: [String: String]) {
        currency = stored["currency"].flatMap { $0.isEmpty ? nil : Currency(code: $0) }
        numbers = stored["numbers"].flatMap { $0 == "own" ? .currencysOwn : NumberStyle(rawValue: $0).map(Numbers.style) }
        rates = stored["rates"].flatMap(ExchangeRateSource.init(rawValue:))
    }
}

public struct ScenarioForm: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The open scenario's name, start and seed.
        case edit
        /// A new scenario, with one blank formula.
        case new
        /// A copy of the open scenario, readings included.
        case duplicate
    }

    public var mode: Mode
    public var name: String
    public var start: Date
    /// What the scenario's money is in. Changing it changes the symbol, not the amounts.
    public var currency: Currency
    /// How numbers are written: nil for each currency in its own style.
    public var numbers: NumberStyle?
    /// Where exchange rates come from (docs/DESIGN.md, 5.11).
    public var rates: ExchangeRateSource
    /// An App ID for live rates, as typed. Saved in the Keychain, never in the scenario; empty
    /// keeps the one saved.
    public var appID = ""
    /// Whether the Keychain has an App ID for live rates.
    public var hasAppID = false
    /// What Test found: the latest rate, or what went wrong.
    public var rateTest: String?
    public var isTestingRates = false
    /// The seed as typed: `0x5EEDF07E` or a whole number. Empty for the engine's own.
    public var seedText: String
    /// Folder names other scenarios use there, lowercased, since the Mac's disks ignore case.
    var taken: Set<String>
    /// Why the last try to make the scenario failed.
    public var failure: String?

    /// The name without spaces around it.
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What stops the form from being saved, if anything.
    public var problem: String? {
        let name = trimmedName
        if name.isEmpty { return "Give the scenario a name." }
        if name.contains("[") || name.contains("]") { return "A name can't have square brackets in it." }
        if taken.contains(ScenarioPackage.folderName(for: name).lowercased()) {
            return "There's already a scenario called “\(name)”."
        }
        if mode == .edit, Self.seed(from: seedText) == nil { return "A seed is a whole number, like 0x5EEDF07E." }
        return nil
    }

    /// A seed as the file writes it: `0x5EEDF07E`, or empty for the engine's own.
    public static func text(seed: UInt64?) -> String {
        seed.map { "0x" + String($0, radix: 16, uppercase: true) } ?? ""
    }

    /// The seed typed, read as the file reads it. `.some(nil)` is the engine's own; nil means it
    /// can't be read.
    public static func seed(from text: String) -> UInt64?? {
        let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        if text.isEmpty { return .some(nil) }
        let parsed = text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
        return parsed.map { .some($0) }
    }

    /// A seed picked at random, for "New seed".
    public static func randomSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64(UInt32.max))
    }
}

extension ScenarioStore {
    /// Opens the form for editing the scenario's settings, or for a new one or a copy. `taken`
    /// holds the folder names other scenarios use there.
    public func openScenarioForm(_ mode: ScenarioForm.Mode, taken: Set<String> = []) {
        let name: String
        switch mode {
        case .edit: name = self.name
        case .new: name = ScenarioPackage.uniqueName("New scenario", taken: taken)
        case .duplicate: name = ScenarioPackage.uniqueName(self.name + " copy", taken: taken)
        }
        let start = mode == .new ? DateText.startOfYear(DateText.year(now)) : self.start
        // A new scenario is in this one's currency and style, as a copy is: the ones being worked in,
        // unless Settings chose others for new scenarios.
        let defaults = mode == .new ? newScenarioDefaults : NewScenarioDefaults()
        let numbers: NumberStyle? = switch defaults.numbers {
        case nil: numberSetting
        case .currencysOwn?: nil
        case .style(let style)?: style
        }
        let form = ScenarioForm(mode: mode, name: name, start: start, currency: defaults.currency ?? currency, numbers: numbers,
                                rates: defaults.rates ?? rateSource, seedText: mode == .edit ? ScenarioForm.text(seed: seed) : "",
                                taken: taken)
        scenarioForm = form
        if form.rates.isLive { checkForAppID() }
    }

    /// Looks in the Keychain for an App ID for live rates, once live rates are chosen in the form.
    public func checkForAppID() {
        let found = credentials.hasCredential(named: RateProviders.openExchangeRates.credentialName)
        if scenarioForm?.hasAppID != found { scenarioForm?.hasAppID = found }
    }

    /// The source of rates a form's choice means for the file: none when it's the ECB's and the
    /// file leaves it unsaid.
    func rateSetting(for choice: ExchangeRateSource) -> ExchangeRateSource? {
        choice == rateSource ? rateSetting : choice
    }

    /// Saves the App ID typed in the form in the Keychain, for Open Exchange Rates' hosts only.
    /// Returns why it couldn't be saved.
    func saveAppID(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let provider = RateProviders.openExchangeRates
        do {
            try credentials.save(FeedCredential(kind: .key, secret: key, hosts: provider.hosts), named: provider.credentialName)
            return nil
        } catch {
            return "Couldn't save the App ID: \(error)"
        }
    }

    /// Fetches the latest rate for the form's currency with the App ID typed, or the one saved,
    /// without saving anything, and says what came back.
    public func testLiveRates() async {
        guard var form = scenarioForm else { return }
        form.isTestingRates = true
        form.rateTest = nil
        scenarioForm = form
        let provider = RateProviders.openExchangeRates
        let key = form.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let store: any CredentialStore = key.isEmpty ? credentials
            : MemoryCredentialStore([provider.credentialName: FeedCredential(kind: .key, secret: key, hosts: provider.hosts)])
        let fetcher = RateFetcher(transport: feedTransport, credentials: store)
        let target = form.currency == .usd ? Currency.eur : form.currency
        let result: String
        do {
            let rates = try await fetcher.fetch(provider, currencies: [target])
            if let latest = rates.latest(target) {
                let one = ValueStyle.money(.usd).amountText(1)
                let rate = ValueStyle(.currency, currency: target, writing: target.writing(form.numbers)).amountText(latest.perDollar, digits: 4)
                result = "Works: \(one)\u{00A0}=\u{00A0}\(rate), as of \(DateText.dayMonthYear(latest.time))."
            } else {
                result = "Open Exchange Rates has no rate for \(target.plural)."
            }
        } catch {
            result = (error as? FeedError)?.message ?? error.localizedDescription
        }
        guard scenarioForm != nil else { return }
        scenarioForm?.isTestingRates = false
        scenarioForm?.rateTest = result
    }

    /// The currency a form's choice means for the file: none when it's what the file leaves
    /// unsaid, so a heading without one keeps its meaning and its text.
    func currencySetting(for choice: Currency) -> Currency? {
        choice == currency ? currencySetting : choice
    }

    /// Opens the form for the menu, with the names the app's folders already use.
    public func openScenarioForm(_ mode: ScenarioForm.Mode, actions: ScenarioMenuActions) {
        openScenarioForm(mode, taken: actions.takenNames(mode))
    }

    public func closeScenarioForm() {
        if scenarioForm != nil { scenarioForm = nil }
    }

    /// Saves the form. Editing changes the open scenario, as one change undo takes back. A new
    /// scenario or a copy is written to the Scenarios folder and opened in the panel. Returns
    /// false when the form can't be saved, or making the scenario failed.
    @discardableResult
    public func submitScenarioForm(_ actions: ScenarioMenuActions?) async -> Bool {
        guard let form = scenarioForm, form.problem == nil else { return false }
        let name = form.trimmedName, start = form.start, currency = currencySetting(for: form.currency)
        let rates = rateSetting(for: form.rates), numbers = form.numbers
        if form.rates.isLive, let problem = saveAppID(form.appID) {
            scenarioForm?.failure = problem
            return false
        }
        switch form.mode {
        case .edit:
            guard let seed = ScenarioForm.seed(from: form.seedText) else { return false }
            let old = settings
            closeScenarioForm()
            applySettingsChange(ScenarioSettings(name: name, start: start, seed: seed, currency: currency, rates: rates,
                                                 numbers: numbers))
            if old.start != start {
                say("\(name) now starts \(DateText.dayMonthYear(start)). ⌘Z undoes it.")
            } else if old.currency != currency {
                say("\(name) is now in \(form.currency.plural). The amounts are the same; ⌘Z undoes it.")
            }
            return true
        case .new, .duplicate:
            guard let actions else { return false }
            var request = NewScenario(name: name, start: start, currency: currency, rates: rates, numbers: numbers)
            var copying: ScenarioPackage?
            if form.mode == .duplicate {
                guard let current = actions.current() else { return false }
                actions.save()
                copying = current
                // A copy's file says its currency when the original did, or it's another one.
                request.currency = form.currency
            }
            let make = actions.make, scenario = request, source = copying
            let made: Result<ScenarioPackage, Error> = await Task.detached(priority: .userInitiated) {
                Result { try make(scenario, source) }
            }.value
            switch made {
            case .success(let package):
                closeScenarioForm()
                actions.open(package)
                return true
            case .failure(let error):
                scenarioForm?.failure = "Couldn't make “\(name)”: \(error.localizedDescription)"
                return false
            }
        }
    }
}
