import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

/// Fetches the exchange rates a scenario's slots convert money at, and keeps copies of them in
/// `readings/` (docs/DESIGN.md, 5.11), as `FeedCenter` does for feeds.
///
/// It fetches only rates the slots need: the currencies of money one slot reads from a slot in
/// another currency. The daily rates' copy, `readings/exchange-rates.csv`, is fetched again every
/// few hours, from a little before its latest rate; a currency it doesn't have yet is fetched from
/// the start. With live rates, `readings/exchange-rates-live.csv` holds each currency's latest
/// rate, fetched every ten minutes. Fetches run one at a time, off the main thread.
@MainActor
public final class RateCenter {
    public let store: ScenarioStore
    /// The scenario folder, where `readings/` is.
    public let folder: URL

    /// How often to look for rates that are due.
    public static var checkInterval: TimeInterval = 600
    /// After a failure, how long before trying again.
    public static var retryDelay: TimeInterval = 1_800
    /// Daily rates this close to the latest are fetched again, in case a day came late.
    public static let overlap: TimeInterval = 14 * 86_400

    private var daily = ExchangeRates.none
    private var live = ExchangeRates.none
    private var dailyDue = Date.distantFuture
    private var liveDue = Date.distantFuture
    /// The currencies each kind of fetch last asked for. A currency missing after that waits for
    /// the next one that's due, rather than being asked for again straight away.
    private var dailyTried: Set<Currency> = []
    private var liveTried: Set<Currency> = []
    private var isRunning = false
    private var isInspecting = false
    private var timer: Timer?
    private var isActive = false
    private var isClosed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The time, which tests can set.
    var now: () -> Date = Date.init

    public init(store: ScenarioStore, folder: URL) {
        self.store = store
        self.folder = folder
    }

    /// Reads the copies, then fetches what's due. `watch` also checks every few minutes.
    public func start(watch: Bool = true) {
        guard !isActive, !isClosed else { return }
        isActive = true
        if watch {
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
            timer.tolerance = Self.checkInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        inspect()
    }

    public func close() {
        isClosed = true
        timer?.invalidate()
        timer = nil
        finishWaiting()
    }

    public var isIdle: Bool { !isRunning && !isInspecting }

    /// Waits until the copies have been read and every fetch due has finished.
    public func waitUntilIdle() async {
        while !isIdle && !isClosed {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func finishWaiting() {
        guard isIdle || isClosed else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Copies

    /// Both copies' rates together, for opening the scenario: the latest live rates over the daily ones.
    nonisolated public static func readCopies(in folder: URL) -> ExchangeRates {
        let daily = readCopy(folder.appendingPathComponent(RateCopy.path)).rates
        return daily.merged(with: readCopy(folder.appendingPathComponent(RateCopy.livePath)).rates)
    }

    nonisolated static func readCopy(_ url: URL) -> (rates: ExchangeRates, written: Date?) {
        let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let rates = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? RateCopy.parse($0) } ?? .none
        return (rates, written)
    }

    /// Reads both copies off the main thread, and says when each is next due.
    private func inspect() {
        isInspecting = true
        let folder = folder
        Task {
            let (dailyCopy, liveCopy) = await Task.detached(priority: .utility) {
                (Self.readCopy(folder.appendingPathComponent(RateCopy.path)),
                 Self.readCopy(folder.appendingPathComponent(RateCopy.livePath)))
            }.value
            isInspecting = false
            guard !isClosed else { finishWaiting(); return }
            daily = dailyCopy.rates
            live = liveCopy.rates
            dailyDue = dailyCopy.written.map { $0.addingTimeInterval(RateProviders.ecb.refresh) } ?? .distantPast
            liveDue = liveCopy.written.map { $0.addingTimeInterval(RateProviders.openExchangeRates.refresh) } ?? .distantPast
            var status = store.rateStatus
            status.checked = dailyCopy.written
            status.liveChecked = liveCopy.written
            store.setRateStatus(status)
            store.receiveExchangeRates(combined)
            sync()
            finishWaiting()
        }
    }

    private var combined: ExchangeRates { daily.merged(with: live) }

    // MARK: Fetching

    /// Fetches what's due or missing for the rates the slots need now. Called when the scenario
    /// changes, and every few minutes.
    public func sync() {
        guard isActive, !isClosed, !isInspecting, !isRunning else { return }
        let needed = store.neededCurrencies
        let source = store.rateSource
        guard source != .none, !needed.isEmpty else { return }
        let providers = RateProviders.providers(for: source)
        let time = now()
        var status = store.rateStatus

        // Currencies no source here has: say where to find them.
        if let dailyProvider = providers.daily, providers.live == nil,
           let lacking = needed.sorted(by: { $0.code < $1.code }).first(where: { !dailyProvider.has($0) }) {
            status.error = "The European Central Bank has no rates for \(lacking.plural). Open Exchange Rates has them: "
                + "choose it for the scenario's exchange rates."
            store.setRateStatus(status)
        }
        if let dailyProvider = providers.daily {
            let new = needed.filter { dailyProvider.has($0) && !daily.covers($0) && !dailyTried.contains($0) }
            if !new.isEmpty || dailyDue <= time { fetch(dailyProvider, needed: needed); return }
        }
        if let liveProvider = providers.live {
            let new = needed.filter { !live.covers($0) && !liveTried.contains($0) }
            if !new.isEmpty || liveDue <= time { fetch(liveProvider, needed: needed); return }
        }
    }

    /// Fetches everything now, as Refresh Data Feeds asks.
    public func refresh() {
        dailyDue = .distantPast
        liveDue = .distantPast
        sync()
    }

    private func fetch(_ provider: any RateProvider, needed: Set<Currency>) {
        isRunning = true
        if provider.isLive { liveTried = needed } else { dailyTried = needed }
        var status = store.rateStatus
        status.isFetching = true
        store.setRateStatus(status)
        let fetcher = RateFetcher(transport: store.feedTransport, credentials: store.credentials)
        let folder = folder, old = provider.isLive ? live : daily, overlap = Self.overlap
        let wanted = needed.filter { provider.has($0) }.sorted { $0.code < $1.code }
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<ExchangeRates, Error> in
                do {
                    var rates: ExchangeRates
                    if provider.isLive {
                        // Each currency's latest rate replaces the one before.
                        let fresh = try await fetcher.fetch(provider, currencies: wanted)
                        var latest: [Currency: [(time: Date, rate: Double)]] = [:]
                        for currency in old.currencies.union(fresh.currencies) where currency != .usd {
                            if let point = fresh.latest(currency) ?? old.latest(currency) { latest[currency] = [(point.time, point.perDollar)] }
                        }
                        rates = ExchangeRates(perDollar: latest)
                    } else {
                        // Currencies the copy has are fetched from a little before their latest rate;
                        // new ones from the start.
                        let known = wanted.filter { old.covers($0) }, new = wanted.filter { !old.covers($0) }
                        rates = old
                        if !new.isEmpty { rates = rates.merged(with: try await fetcher.fetch(provider, currencies: new)) }
                        if !known.isEmpty {
                            let since = known.compactMap { old.latest($0)?.time }.min()?.addingTimeInterval(-overlap)
                            rates = rates.merged(with: try await fetcher.fetch(provider, currencies: known, since: since))
                        }
                    }
                    // The scenario's folder moved (renamed) while fetching: making it again here
                    // would leave an empty scenario behind.
                    guard FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileNoSuchFile) }
                    let url = folder.appendingPathComponent(provider.isLive ? RateCopy.livePath : RateCopy.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Written even when nothing changed, so its date says when it was checked.
                    try Data(RateCopy.text(rates).utf8).write(to: url, options: .atomic)
                    return .success(rates)
                } catch {
                    return .failure(error)
                }
            }.value
            finish(provider, result)
        }
    }

    private func finish(_ provider: any RateProvider, _ result: Result<ExchangeRates, Error>) {
        isRunning = false
        guard !isClosed else { finishWaiting(); return }
        var status = store.rateStatus
        status.isFetching = false
        let time = now()
        switch result {
        case .success(let rates):
            if provider.isLive {
                live = rates
                liveDue = time.addingTimeInterval(provider.refresh)
                status.liveChecked = time
            } else {
                daily = rates
                dailyDue = time.addingTimeInterval(provider.refresh)
                status.checked = time
            }
            status.error = nil
            store.setRateStatus(status)
            store.receiveExchangeRates(combined)
        case .failure(let error):
            let message = (error as? FeedError)?.message ?? error.localizedDescription
            status.error = message
            let retry = time.addingTimeInterval(max(Self.retryDelay, provider.refresh))
            if provider.isLive { liveDue = retry } else { dailyDue = retry }
            store.setRateStatus(status)
            store.say("Couldn't fetch exchange rates from \(provider.name): \(message)", isError: true)
        }
        sync()
        finishWaiting()
    }
}
