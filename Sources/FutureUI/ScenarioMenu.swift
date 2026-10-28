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

/// What the scenario menu needs from the app: the scenarios and opening them.
public struct ScenarioMenuActions {
    /// The Scenarios folder. The menu lists it, and new scenarios go there.
    public var folder: URL
    /// The scenario that's open.
    public var current: () -> ScenarioPackage?
    /// Saves the open scenario now, so a copy of it is up to date.
    public var save: () -> Void
    /// Opens a scenario in the panel, in place of the one open now.
    public var open: (ScenarioPackage) -> Void
    public var showInFinder: () -> Void
    /// Picks a scenario from anywhere to open, as Open Scenario… in the menu bar item does.
    public var openOther: () -> Void

    public init(folder: URL, current: @escaping () -> ScenarioPackage?, save: @escaping () -> Void,
                open: @escaping (ScenarioPackage) -> Void, showInFinder: @escaping () -> Void,
                openOther: @escaping () -> Void) {
        self.folder = folder
        self.current = current
        self.save = save
        self.open = open
        self.showInFinder = showInFinder
        self.openOther = openOther
    }

    /// The scenarios the menu lists, in Finder's order, with the open one among them.
    public func scenarios() -> [ScenarioPackage] {
        ScenarioLibrary.menuEntries(current: current(), in: folder)
    }

    /// The folder a scenario made in `mode` goes in, and the names already used there.
    func taken(for mode: ScenarioForm.Mode) -> Set<String> {
        guard mode == .edit, let current = current() else { return ScenarioLibrary.takenNames(in: folder) }
        // A renamed scenario's folder follows its name, so the names beside it are taken.
        return ScenarioLibrary.takenNames(in: current.url.deletingLastPathComponent(), except: current)
    }
}

/// The scenario menu's form: the open scenario's settings, or a new scenario's.
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
        if taken.contains(ScenarioLibrary.folderName(for: name).lowercased()) {
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
        case .new: name = ScenarioLibrary.uniqueName("New scenario", taken: taken)
        case .duplicate: name = ScenarioLibrary.uniqueName(self.name + " copy", taken: taken)
        }
        let start = mode == .new ? DateText.startOfYear(DateText.year(now)) : self.start
        // A new scenario is in this one's currency and style, as a copy is: the ones being worked in.
        var form = ScenarioForm(mode: mode, name: name, start: start, currency: currency, numbers: numberSetting,
                                rates: rateSource, seedText: mode == .edit ? ScenarioForm.text(seed: seed) : "", taken: taken)
        scenarioForm = form
        if rateSource.isLive { checkForAppID() }
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
        openScenarioForm(mode, taken: actions.taken(for: mode))
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
            let folder = actions.folder
            let made: Result<ScenarioPackage, Error>
            if form.mode == .new {
                made = await Task.detached(priority: .userInitiated) {
                    Result {
                        try ScenarioLibrary.createBlank(name: name, start: start, currency: currency, rates: rates, numbers: numbers,
                                                        in: folder)
                    }
                }.value
            } else {
                guard let source = actions.current() else { return false }
                actions.save()
                let copyCurrency = form.currency
                made = await Task.detached(priority: .userInitiated) {
                    Result {
                        try ScenarioLibrary.duplicate(source, name: name, start: start, currency: copyCurrency, rates: rates,
                                                      numbers: numbers, in: folder)
                    }
                }.value
            }
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

extension ScenarioLibrary {
    /// The folder name for a scenario called `name`: slashes and colons become dashes, and leading
    /// dots go, so the folder isn't hidden.
    public static func folderName(for name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while text.hasPrefix(".") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        // Room for ".etf" within the 255 bytes a file name can have.
        while text.utf8.count > 200 { text.removeLast() }
        return text.isEmpty ? "Untitled" : text
    }

    /// Where a scenario called `name` goes in a folder.
    public static func package(named name: String, in folder: URL) -> ScenarioPackage {
        ScenarioPackage(url: folder.appendingPathComponent(folderName(for: name), isDirectory: true)
            .appendingPathExtension(ScenarioPackage.fileExtension))
    }

    /// The names of the scenario folders in a folder, lowercased.
    public static func takenNames(in folder: URL, except: ScenarioPackage? = nil) -> Set<String> {
        Set(scenarios(in: folder).filter { $0 != except }.map { $0.name.lowercased() })
    }

    /// `base`, else `base 2`, `base 3`… whichever no scenario there uses.
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var name = base, number = 2
        while taken.contains(folderName(for: name).lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// What the scenario menu lists: the scenarios in the folder, and the open one wherever it
    /// is, in Finder's order.
    public static func menuEntries(current: ScenarioPackage?, in folder: URL) -> [ScenarioPackage] {
        var list = scenarios(in: folder)
        if let current, !list.contains(current) { list.append(current) }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new scenario: one blank formula, to start from. `currency` nil leaves it unsaid: US dollars.
    public static func blank(name: String, start: Date, currency: Currency? = nil, rates: ExchangeRateSource? = nil,
                             numbers: NumberStyle? = nil) -> ScenarioDefinition {
        let template = ModelLibrary.blankFormula
        var slot = SlotSpec(name: template.slotName, model: template.slotModelName, kind: template.kind,
                            formula: template.formula, variable: template.variable, format: template.format, position: 0)
        slot.showsInFile = false  // the model's own choice, so the heading stays plain
        return ScenarioDefinition(name: name, start: start, currency: currency, rates: rates, numbers: numbers, slots: [slot])
    }

    /// Writes a new scenario with one blank formula, and returns its folder.
    public static func createBlank(name: String, start: Date, currency: Currency? = nil, rates: ExchangeRateSource? = nil,
                                   numbers: NumberStyle? = nil, in folder: URL) throws -> ScenarioPackage {
        let package = package(named: name, in: folder)
        guard !FileManager.default.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        try ScenarioDocument.create(blank(name: name, start: start, currency: currency, rates: rates, numbers: numbers), at: package)
        return package
    }

    /// Copies a scenario's folder under a new name, start and currency, with its readings but not
    /// its cache, and returns the copy.
    public static func duplicate(_ source: ScenarioPackage, name: String, start: Date, currency: Currency? = nil,
                                 rates: ExchangeRateSource? = nil, numbers: NumberStyle? = nil,
                                 in folder: URL) throws -> ScenarioPackage {
        let manager = FileManager.default
        let package = package(named: name, in: folder)
        guard !manager.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        let parsed = try ScenarioFormat.parse(try source.readText())
        var file = parsed.file
        file.name = name
        file.start = start
        // The copy's file says its currency only when the original did, or it's another one.
        if let currency, currency != (file.currency ?? .usd) || file.currency != nil { file.currency = currency }
        file.rates = rates
        file.numbers = numbers
        do {
            try manager.createDirectory(at: package.url, withIntermediateDirectories: true)
            for item in try manager.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil)
            where item.lastPathComponent != source.cacheFolder.lastPathComponent {
                try manager.copyItem(at: item, to: package.url.appendingPathComponent(item.lastPathComponent))
            }
            try package.write(text: ScenarioFormat.text(for: file, over: parsed))
        } catch {
            try? manager.removeItem(at: package.url)
            throw error
        }
        return package
    }
}
