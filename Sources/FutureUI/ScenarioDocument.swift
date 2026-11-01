import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds
import FutureScript

/// A scenario saved in its folder (docs/DESIGN.md, 15). It opens the folder, saves changes to
/// `scenario.md` as they're made, notices when another app changes the file, and keeps slow slots'
/// results in `cache/`.
@MainActor
public final class ScenarioDocument {
    /// The scenario's folder. It moves when the scenario is renamed in the app and the folder had
    /// its old name.
    public private(set) var package: ScenarioPackage
    public let store: ScenarioStore
    /// Fetches the scenario's feeds into `readings/` (docs/DESIGN.md, 15.8). A new one takes over
    /// when the folder moves.
    public private(set) var feeds: FeedCenter
    /// Fetches the exchange rates its slots convert money at into `readings/` (docs/DESIGN.md, 5.11).
    public private(set) var rates: RateCenter
    /// Called after the folder moved to follow the scenario's new name.
    public var onMove: ((ScenarioPackage) -> Void)?

    /// Mistakes found the last time `scenario.md` was read, readings' included.
    public private(set) var problems: [String] = []
    /// Set while `scenario.md` has a change from another app that can't be read. The app doesn't
    /// save over it until it can be read again.
    public private(set) var unreadableReason: String?

    /// Slots whose results took at least this long to compute are cached when the document closes.
    public static var cacheThreshold: Double = 1
    /// The most a scenario's cache may hold.
    public static var cacheByteLimit = 256 * 1024 * 1024
    /// How long after a change the file is saved, so a burst of changes is one save.
    public static var saveDelay: Duration = .milliseconds(500)
    /// How often the file is checked for changes from other apps.
    public static var checkInterval: TimeInterval = 1

    /// `scenario.md` as it was last read or written.
    private var parsed: ParsedScenario
    private var saveTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastSeen: (modified: Date?, size: Int?)
    private var isReloading = false
    var isReloadingForTests: Bool { isReloading }
    private var isClosed = false
    private var isWatching = false

    // MARK: Opening

    /// Opens a scenario's folder. Throws when `scenario.md` can't be read or doesn't say enough.
    public static func open(_ package: ScenarioPackage, now: Date = Date(), watch: Bool = true) async throws -> ScenarioDocument {
        let loaded = try await Task.detached(priority: .userInitiated) { try load(package) }.value
        let store = try ScenarioStore(definition: loaded.definition, now: now, savedResults: loaded.results)
        let document = ScenarioDocument(package: package, store: store, parsed: loaded.parsed)
        document.report(loaded.problems)
        if watch {
            document.isWatching = true
            document.startWatching()
            document.feeds.start()
            document.rates.start()
        }
        return document
    }

    /// Writes a new scenario folder for a definition, such as the built-in "Home & money".
    nonisolated public static func create(_ definition: ScenarioDefinition, at package: ScenarioPackage) throws {
        try package.write(text: ScenarioFormat.text(for: ScenarioStore.file(for: definition)))
    }

    private init(package: ScenarioPackage, store: ScenarioStore, parsed: ParsedScenario) {
        self.package = package
        self.store = store
        self.parsed = parsed
        store.scenarioFolder = package.url
        feeds = FeedCenter(store: store, folder: package.url)
        rates = RateCenter(store: store, folder: package.url)
        lastSeen = Self.stamp(package)
        store.onScenarioChange = { [weak self] in
            self?.scheduleSave()
            self?.feeds.sync()
            self?.rates.sync()
        }
        store.onRefreshFeeds = { [weak self] slot in
            self?.feeds.refresh(slot: slot)
            if slot == nil { self?.rates.refresh() }
        }
    }

    struct Loaded: Sendable {
        let parsed: ParsedScenario
        let definition: ScenarioDefinition
        let results: [String: SlotHistory]
        let problems: [String]
    }

    /// Reads everything off the main thread: the file, readings, and cached results that still match.
    nonisolated static func load(_ package: ScenarioPackage, text: String? = nil, cache: Bool = true) throws -> Loaded {
        let parsed = try ScenarioFormat.parse(try text ?? package.readText())
        var readings: [String: LoadedReadings] = [:]
        for slot in parsed.file.slots where !slot.readings.isEmpty {
            readings[slot.name] = ReadingLoader.load(slot.readings, slot: slot.name, folder: package.url, variable: slot.shows)
        }
        try? package.write(copies: readings.values.reduce(into: [:]) { $0.merge($1.copies) { $1 } })
        // The rates kept with the scenario, so slots that convert money run straight away (docs/DESIGN.md, 5.11).
        let rates = parsed.file.rates == ExchangeRateSource.none ? .none : RateCenter.readCopies(in: package.url)
        let definition = ScenarioDefinition(file: parsed.file, loaded: readings, exchangeRates: rates)

        var problems = parsed.problems.map(\.description) + readings.values.flatMap(\.problems)
        let configs = ScenarioStore.configs(from: definition)
        let assembly = ScenarioStore.assemble(configs, money: ScenarioMoney(
            currency: definition.currency ?? .usd, numbers: definition.numbers,
            converts: definition.rates != ExchangeRateSource.none, rates: rates))
        for (index, config) in configs.enumerated() {
            guard let descriptor = assembly.descriptors[index] else { continue }
            let names = Set(descriptor.variables.map(\.name))
            for variable in config.readings.set.variables where !names.contains(variable) {
                problems.append("\(config.name) has readings of \(variable), which its model doesn't have.")
            }
            for name in config.values.keys.sorted() where !names.contains(name) {
                problems.append("\(config.name) has a value for \(name), which its model doesn't have.")
            }
        }

        var results: [String: SlotHistory] = [:]
        let cached = cache ? package.cachedSlots() : [:]
        if !cached.isEmpty {
            let fingerprints = ScenarioStore.fingerprints(configs, descriptors: assembly.descriptors, start: definition.start,
                                                          seed: definition.seed, libraries: ScriptLibraryDigest.compute(),
                                                          conversions: assembly.conversions, rates: rates)
            for (index, config) in configs.enumerated() {
                guard let fingerprint = fingerprints[index], let url = cached[config.name],
                      let history = try? SlotCache.history(at: url, fingerprint: fingerprint) else { continue }
                results[config.name] = history
            }
        }
        return Loaded(parsed: parsed, definition: definition, results: results, problems: problems)
    }

    /// Says what's wrong with the file, if anything.
    private func report(_ problems: [String], loaded: String? = nil) {
        self.problems = problems
        if let first = problems.first {
            let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            store.say("\(ScenarioFormat.fileName): \(first)\(more)", isError: true)
        } else if let loaded {
            store.say(loaded)
        }
    }

    // MARK: Saving

    func scheduleSave() {
        guard !isClosed else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes `scenario.md` now, if the scenario changed. Returns false when it couldn't.
    @discardableResult
    public func save() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard unreadableReason == nil else { return false }
        // Another app changed the file since it was read: its change wins, and undo can take it back.
        if let disk = try? package.readText(), disk != parsed.text {
            checkFile(force: true)
            return false
        }
        let text = ScenarioFormat.text(for: store.scenarioFile(), over: parsed)
        guard text != parsed.text || !FileManager.default.fileExists(atPath: package.scenarioURL.path) else { return true }
        let oldName = parsed.file.name
        do {
            try package.write(text: text)
            parsed = try ScenarioFormat.parse(text)
            lastSeen = Self.stamp(package)
        } catch {
            store.say("Couldn't save \(package.name): \(error.localizedDescription)", isError: true)
            return false
        }
        // Only the app's own changes get here. A change from another app is read into `parsed`
        // first, so its new name never moves the folder under the editor that saved it.
        if parsed.file.name != oldName { followName(from: oldName) }
        return true
    }

    // MARK: Renaming

    /// Moves the folder to follow the scenario's new name, when it had the old one and nothing
    /// is in the way (docs/DESIGN.md, 15.1).
    private func followName(from oldName: String) {
        let manager = FileManager.default
        let target = ScenarioLibrary.package(named: parsed.file.name, in: package.url.deletingLastPathComponent())
        guard package.name == ScenarioLibrary.folderName(for: oldName), target != package else { return }
        // The Mac's disks ignore case, so a change of case alone goes through another name.
        let caseOnly = target.url.path.lowercased() == package.url.path.lowercased()
        guard caseOnly || !manager.fileExists(atPath: target.url.path) else {
            store.say("The scenario's folder keeps its name: there's already a “\(target.url.lastPathComponent)”.")
            return
        }
        do {
            if caseOnly {
                let step = package.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try manager.moveItem(at: package.url, to: step)
                try manager.moveItem(at: step, to: target.url)
            } else {
                try manager.moveItem(at: package.url, to: target.url)
            }
        } catch {
            store.say("Couldn't rename the scenario's folder: \(error.localizedDescription)", isError: true)
            return
        }
        package = target
        store.scenarioFolder = target.url
        lastSeen = Self.stamp(package)
        // A fetch on its way still writes to the old folder, so the old center stops (its fetch
        // finds the folder gone) and a new one reads the copies where they are now.
        let old = feeds
        old.close()
        feeds = FeedCenter(store: store, folder: target.url)
        feeds.now = old.now
        if isWatching { feeds.start() }
        let oldRates = rates
        oldRates.close()
        rates = RateCenter(store: store, folder: target.url)
        rates.now = oldRates.now
        if isWatching { rates.start() }
        onMove?(target)
    }

    // MARK: Changes from other apps

    private func startWatching() {
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFile() }
        }
        timer.tolerance = Self.checkInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func stamp(_ package: ScenarioPackage) -> (modified: Date?, size: Int?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: package.scenarioURL.path)
        return (attributes?[.modificationDate] as? Date, (attributes?[.size] as? NSNumber)?.intValue)
    }

    /// Loads `scenario.md` again if another app changed it. Only the file's date and size are
    /// checked, unless `force` says to read it anyway.
    public func checkFile(force: Bool = false) {
        guard !isClosed, !isReloading else { return }
        let stamp = Self.stamp(package)
        guard force || stamp.modified != lastSeen.modified || stamp.size != lastSeen.size else { return }
        lastSeen = stamp
        guard let text = try? package.readText() else { return }
        guard text != parsed.text else {
            if unreadableReason != nil {
                unreadableReason = nil
                store.say("\(ScenarioFormat.fileName) is back as it was.")
            }
            return
        }
        isReloading = true
        Task { await reload(text) }
    }

    /// Reads the changed file off the main thread, then brings the scenario in line with it.
    func reload(_ text: String) async {
        defer { isReloading = false }
        let package = self.package
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
            Result { try ScenarioDocument.load(package, text: text, cache: false) }
        }.value
        guard !isClosed else { return }
        switch result {
        case .failure(let error):
            unreadableReason = String(describing: error)
            store.say("\(ScenarioFormat.fileName) can't be read: \(error). Changes in the app won't be saved until it can.", isError: true)
        case .success(let loaded):
            unreadableReason = nil
            parsed = loaded.parsed
            saveTask?.cancel()
            let sameStart = loaded.definition.start == store.start && loaded.definition.seed == store.seed
            store.reload(from: loaded.definition)
            report(loaded.problems, loaded: sameStart ? "Loaded the changes to \(ScenarioFormat.fileName). ⌘Z undoes them."
                                                      : "Loaded the changes to \(ScenarioFormat.fileName).")
        }
    }

    // MARK: Closing and the cache

    /// Saves `scenario.md`, stops watching it, and caches slow slots' results.
    public func close() async {
        guard !isClosed else { return }
        save()
        isClosed = true
        timer?.invalidate()
        timer = nil
        feeds.close()
        rates.close()
        store.onScenarioChange = nil
        store.onRefreshFeeds = nil
        await saveResults()
    }

    /// Writes the results worth keeping to `cache/` (docs/DESIGN.md, 15.5), and removes cache
    /// files that no longer match their slot.
    public func saveResults() async {
        let libraries = await Task.detached { ScriptLibraryDigest.compute() }.value
        // Taken together with the engine's answer, which comes after everything queued so far.
        let fingerprints = store.fingerprints(libraries: libraries)
        let names = store.configs.map(\.name)
        let results = await store.resultsToSave(minimumSeconds: Self.cacheThreshold)
        let package = self.package
        let limit = Self.cacheByteLimit
        await Task.detached(priority: .utility) {
            var kept = Set<String>()
            var total = 0
            let costliest = results.sorted {
                $0.value.secondsPerStep * Double($0.value.count) > $1.value.secondsPerStep * Double($1.value.count)
            }
            for (index, history) in costliest {
                guard index < names.count, let fingerprint = fingerprints[index] else { continue }
                let size = (history.values.count + history.checkpointStates.count + history.currentState.count
                            + history.checkpointIndices.count) * 8
                guard total + size <= limit else { continue }
                total += size
                let name = names[index]
                kept.insert(name)
                if let header = try? SlotCache.header(at: package.cacheURL(slot: name)), header.fingerprint == fingerprint,
                   header.engine == Scenario.engineVersion, header.format == SlotCache.formatVersion, header.count >= history.count {
                    continue  // already saved
                }
                if let data = try? SlotCache.data(history, slot: name, fingerprint: fingerprint) {
                    try? package.writeCache(data, slot: name)
                }
            }
            // A file that still matches its slot stays, even if the slot wasn't worth saving this time.
            for (name, url) in package.cachedSlots() where !kept.contains(name) {
                let current = names.firstIndex(of: name).flatMap { fingerprints[$0] }
                if let header = try? SlotCache.header(at: url), header.fingerprint == current,
                   header.engine == Scenario.engineVersion, header.format == SlotCache.formatVersion { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
}

/// Where scenarios are kept (docs/DESIGN.md, 15.1): next to the script Libraries folder.
public enum ScenarioLibrary {
    /// `Application Support/Edit The Future/Scenarios` on the Mac; `Documents/Scenarios` on iOS,
    /// where the Files app can reach it.
    public static var folder: URL {
        ScriptPrograms.librariesFolder.deletingLastPathComponent().appendingPathComponent("Scenarios", isDirectory: true)
    }

    /// The scenarios in a folder, by name.
    public static func scenarios(in folder: URL = folder) -> [ScenarioPackage] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == ScenarioPackage.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(ScenarioPackage.init(url:))
    }

    /// The scenario to open at launch: the one opened last if it's still there, else the first in
    /// the folder, else a new copy of the built-in "Home & money", in `currency`: this Mac's own.
    public static func initial(lastOpened: URL?, in folder: URL = folder, currency: Currency = .local) throws -> ScenarioPackage {
        if let lastOpened, FileManager.default.fileExists(atPath: ScenarioPackage(url: lastOpened).scenarioURL.path) {
            return ScenarioPackage(url: lastOpened)
        }
        if let first = scenarios(in: folder).first(where: { FileManager.default.fileExists(atPath: $0.scenarioURL.path) }) {
            return first
        }
        let package = ScenarioPackage(url: folder.appendingPathComponent(ScenarioDefinition.homeAndMoney.name)
            .appendingPathExtension(ScenarioPackage.fileExtension))
        var definition = ScenarioDefinition.homeAndMoney
        definition.currency = currency
        try ScenarioDocument.create(definition, at: package)
        return package
    }
}
