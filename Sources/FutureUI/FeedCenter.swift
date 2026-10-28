import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

/// Fetches a scenario's feeds and keeps their copies in `readings/` (docs/DESIGN.md, 15.8).
///
/// When the scenario opens, and whenever its slots change, it looks for feeds it hasn't seen.
/// Each one's copy is read off the main thread; a feed with no copy, or whose copy is older than
/// its refresh interval, is fetched. Fetches run one at a time. Each asks for the readings since
/// a little before the latest one, since sources revise recent readings, and merges them into
/// the copy. New readings go to the store, which recomputes from the first one that changed.
@MainActor
public final class FeedCenter {
    public let store: ScenarioStore
    /// The scenario folder, where `readings/` is.
    public let folder: URL

    /// How often to look for feeds that are due.
    public static var checkInterval: TimeInterval = 600
    /// Readings this close to the latest are fetched again each time.
    public static let overlap: TimeInterval = 400 * 86_400
    /// After a failure, how long before trying again.
    public static var retryDelay: TimeInterval = 3_600
    /// The shortest refresh interval a feed can ask for.
    public static let shortestRefresh: TimeInterval = 3_600

    private struct Tracked {
        var slotName: String
        var spec: FeedSpec
        var copyPath: String
        /// When it's next due; distant future while its copy is being read.
        var due: Date
    }

    private var tracked: [FeedKey: Tracked] = [:]
    private var queue: [FeedKey] = []
    private var running: FeedKey?
    private var pending = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?
    private var isActive = false
    private var isClosed = false
    /// The time, which tests can set.
    var now: () -> Date = Date.init

    public init(store: ScenarioStore, folder: URL) {
        self.store = store
        self.folder = folder
    }

    /// Starts watching the scenario's feeds. `watch` also checks every few minutes for feeds that
    /// are due.
    public func start(watch: Bool = true) {
        guard !isActive, !isClosed else { return }
        isActive = true
        if watch {
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkDue() }
            }
            timer.tolerance = Self.checkInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        sync()
    }

    public func close() {
        isClosed = true
        timer?.invalidate()
        timer = nil
        queue.removeAll()
        finishWaiting()
    }

    /// Whether nothing is being read or fetched, or waiting to be.
    public var isIdle: Bool { queue.isEmpty && running == nil && pending == 0 }

    /// Waits until every copy has been read and every fetch due has finished.
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

    // MARK: Which feeds there are

    /// Brings the list of feeds in line with the scenario's slots.
    public func sync() {
        guard isActive, !isClosed else { return }
        var wanted: [FeedKey: (name: String, spec: FeedSpec)] = [:]
        for config in store.configs {
            for source in config.readings.sources {
                guard case .feed(let spec) = source else { continue }
                wanted[FeedKey(slot: config.id, identity: spec.identity)] = (config.name, spec)
            }
        }
        for key in tracked.keys where wanted[key] == nil {
            tracked[key] = nil
            queue.removeAll { $0 == key }
            store.setFeedStatus(nil, for: key)
        }
        for (key, feed) in wanted {
            let path = feed.spec.copyPath(slot: feed.name)
            if var known = tracked[key] {
                // A renamed slot takes its copy along.
                if known.copyPath != path { moveCopy(from: known.copyPath, to: path) }
                known.slotName = feed.name
                known.spec = feed.spec
                known.copyPath = path
                tracked[key] = known
                continue
            }
            tracked[key] = Tracked(slotName: feed.name, spec: feed.spec, copyPath: path, due: .distantFuture)
            inspect(key)
        }
        finishWaiting()
    }

    /// Fetches now: one slot's feeds, or all of them.
    public func refresh(slot: UUID? = nil) {
        guard isActive, !isClosed else { return }
        for key in tracked.keys.sorted(by: { $0.identity < $1.identity }) where slot == nil || key.slot == slot {
            enqueue(key, first: true)
        }
        pump()
    }

    /// Queues the feeds that are due.
    func checkDue() {
        let time = now()
        for (key, feed) in tracked where feed.due <= time { enqueue(key) }
        pump()
    }

    private func enqueue(_ key: FeedKey, first: Bool = false) {
        guard running != key, !queue.contains(key) else { return }
        if first { queue.insert(key, at: 0) } else { queue.append(key) }
        var status = store.feedStatuses[key] ?? FeedStatus()
        status.isFetching = true
        store.setFeedStatus(status, for: key)
    }

    private func moveCopy(from old: String, to new: String) {
        let manager = FileManager.default
        let source = folder.appendingPathComponent(old), target = folder.appendingPathComponent(new)
        guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) else { return }
        try? manager.moveItem(at: source, to: target)
    }

    // MARK: Reading copies

    private struct Inspected: Sendable {
        let points: [FeedPoint]
        let written: Date?
        let sets: [FeedSpec: ReadingSet]
    }

    /// Reads a feed's copy off the main thread, then says when it's next due.
    private func inspect(_ key: FeedKey) {
        guard let feed = tracked[key] else { return }
        pending += 1
        let url = folder.appendingPathComponent(feed.copyPath)
        let specs = specs(for: key)
        Task {
            let inspected = await Task.detached(priority: .utility) { () -> Inspected in
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                let points = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? FeedCopy.parse($0) } ?? []
                return Inspected(points: points, written: written, sets: Self.sets(points, specs: specs))
            }.value
            pending -= 1
            guard !isClosed, let feed = tracked[key] else { finishWaiting(); return }
            store.receiveFeedReadings(inspected.sets, forSlot: key.slot)
            var status = store.feedStatuses[key] ?? FeedStatus()
            status.describe(inspected.points)
            status.checked = inspected.written
            store.setFeedStatus(status, for: key)
            let due = inspected.written.map { $0.addingTimeInterval(refreshInterval(feed.spec)) } ?? .distantPast
            tracked[key]?.due = due
            if due <= now() { enqueue(key) }
            pump()
            finishWaiting()
        }
    }

    /// Each of the slot's feeds with this key, and the variable it brings readings of.
    private func specs(for key: FeedKey) -> [FeedSpec: String] {
        guard let config = store.configs.first(where: { $0.id == key.slot }) else { return [:] }
        var specs: [FeedSpec: String] = [:]
        for source in config.readings.sources {
            guard case .feed(let spec) = source, spec.identity == key.identity else { continue }
            specs[spec] = spec.variable ?? config.variable
        }
        return specs
    }

    /// Each feed's readings, with its own `into`, `convert` and `scale`.
    nonisolated private static func sets(_ points: [FeedPoint], specs: [FeedSpec: String]) -> [FeedSpec: ReadingSet] {
        var sets: [FeedSpec: ReadingSet] = [:]
        for (spec, variable) in specs {
            sets[spec] = ReadingSet(ReadingLoader.readings(points, spec: spec, variable: variable))
        }
        return sets
    }

    private func refreshInterval(_ spec: FeedSpec) -> TimeInterval {
        let rate = spec.refresh ?? FeedProviders.named(spec.provider)?.refresh ?? .days(1)
        return max(Self.shortestRefresh, rate.approximateSeconds)
    }

    // MARK: Fetching

    private struct Fetched: Sendable {
        let points: [FeedPoint]
        let sets: [FeedSpec: ReadingSet]
    }

    /// Starts the next fetch, if none is running.
    private func pump() {
        guard running == nil, !isClosed else { return }
        while let key = queue.first {
            queue.removeFirst()
            guard let feed = tracked[key] else { continue }
            running = key
            let url = folder.appendingPathComponent(feed.copyPath)
            let fetcher = FeedFetcher(transport: store.feedTransport, credentials: store.credentials)
            let spec = feed.spec, specs = specs(for: key), time = now(), overlap = Self.overlap, folder = folder
            Task {
                let result = await Task.detached(priority: .utility) { () -> Result<Fetched, Error> in
                    do {
                        let text = try? String(contentsOf: url, encoding: .utf8)
                        let old = text.flatMap { try? FeedCopy.parse($0) } ?? []
                        let since = old.last.map { $0.time.addingTimeInterval(-overlap) }
                        let fresh = try await fetcher.fetch(spec, since: since, now: time)
                        let merged = FeedCopy.merge(old, with: fresh)
                        // The scenario's folder moved (renamed) while fetching: making it again
                        // here would leave an empty scenario behind.
                        guard FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileNoSuchFile) }
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Written even when nothing changed, so its date says when it was checked.
                        try Data(FeedCopy.text(merged).utf8).write(to: url, options: .atomic)
                        return .success(Fetched(points: merged, sets: Self.sets(merged, specs: specs)))
                    } catch {
                        return .failure(error)
                    }
                }.value
                finish(key, spec: spec, result)
            }
            return
        }
        finishWaiting()
    }

    private func finish(_ key: FeedKey, spec: FeedSpec, _ result: Result<Fetched, Error>) {
        running = nil
        guard !isClosed else { finishWaiting(); return }
        if tracked[key] != nil {
            var status = store.feedStatuses[key] ?? FeedStatus()
            status.isFetching = queue.contains(key)
            switch result {
            case .success(let fetched):
                store.receiveFeedReadings(fetched.sets, forSlot: key.slot)
                status.describe(fetched.points)
                status.checked = now()
                status.error = nil
                tracked[key]?.due = now().addingTimeInterval(refreshInterval(spec))
            case .failure(let error):
                status.error = (error as? FeedError)?.message ?? error.localizedDescription
                tracked[key]?.due = now().addingTimeInterval(min(Self.retryDelay, refreshInterval(spec)))
                if let title = tracked[key].map({ $0.spec.title }) {
                    store.say("Couldn't fetch “\(title)”: \(status.error ?? "")", isError: true)
                }
            }
            store.setFeedStatus(status, for: key)
        }
        pump()
    }
}

extension FeedStatus {
    /// Takes the count, the span and the latest value from a feed's readings.
    mutating func describe(_ points: [FeedPoint]) {
        count = points.count
        first = points.first?.time
        last = points.last?.time
        lastValue = points.last?.value
    }
}
