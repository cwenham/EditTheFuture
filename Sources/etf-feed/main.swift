import Foundation
import FutureDocument
import FutureEngine
import FutureFeeds

// Fetches a feed without the app and prints its readings as CSV (docs/DESIGN.md, 15.8).
//
//   swift run etf-feed "[feed: fred, series: DGS10]" --since 2026-01-01
//   swift run etf-feed treasury10 --since 2026-09-01       a ready-made feed, by its id
//   swift run etf-feed --list                               the ready-made feeds
//   swift run etf-feed --check                              fetches the last 120 days of each one that needs no key
//   swift run etf-feed --rates GBP,EUR --since 2026-10-01   exchange rates, units per US dollar (docs/DESIGN.md, 5.11)
//   swift run etf-feed --rates GBP,EUR --live               the latest from Open Exchange Rates (needs its App ID)
//
// Sign-ins come from the Keychain, as the app saves them. --key KEY uses a key just this once.

let usage = """
    Usage: etf-feed <feed line or ready-made feed> [--since YYYY-MM-DD] [--key KEY]
           etf-feed --list
           etf-feed --check
           etf-feed --rates GBP,EUR [--since YYYY-MM-DD] [--live] [--key KEY]
    """

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var since: Date?
if let text = option("--since") {
    guard let date = FeedDate.parse(text) else { fail("“\(text)” isn't a date.") }
    since = date
}
let key = option("--key")

if let codes = option("--rates") {
    var currencies: [Currency] = []
    for code in codes.split(separator: ",") {
        guard let currency = Currency(code: String(code)) else { fail("“\(code)” isn't a currency code.") }
        currencies.append(currency)
    }
    let live = arguments.contains("--live")
    let provider: any RateProvider = live ? RateProviders.openExchangeRates : RateProviders.ecb
    let store: any CredentialStore = key.map {
        MemoryCredentialStore([provider.credentialName: FeedCredential(kind: .key, secret: $0, hosts: provider.hosts)])
    } ?? KeychainCredentialStore()
    do {
        let rates = try await RateFetcher(credentials: store).fetch(provider, currencies: currencies, since: since)
        for currency in currencies where !rates.covers(currency) {
            FileHandle.standardError.write(Data("\(provider.name) has no rates for \(currency.code).\n".utf8))
        }
        print(RateCopy.text(rates), terminator: "")
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if arguments == ["--list"] {
    for category in FeedPreset.Category.allCases {
        print("\n\(category.title)")
        for preset in FeedCatalog.presets(in: category) {
            let needsKey = preset.provider?.signIn.need == .required ? "  (needs a key)" : ""
            print("  \(preset.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(preset.title)\(needsKey)")
        }
    }
    exit(0)
}

/// Feeds with a key given on the command line use it, for that source's hosts only.
@MainActor
func fetcher(for spec: FeedSpec) -> FeedFetcher {
    guard let key, let provider = FeedProviders.named(spec.provider) else { return FeedFetcher() }
    let kind = provider.signIn.kinds.first ?? .key
    let store = MemoryCredentialStore([
        provider.credentialName(for: spec): FeedCredential(kind: kind, secret: key, hosts: provider.hosts(for: spec)),
    ])
    return FeedFetcher(credentials: store)
}

if arguments == ["--check"] {
    let start = Date().addingTimeInterval(-120 * 86_400)
    var failures = 0
    for preset in FeedCatalog.all where preset.provider?.signIn.need != .required
        && preset.spec.query.allSatisfy({ !$0.value.isEmpty }) {
        let began = Date()
        do {
            let points = try await FeedFetcher().fetch(preset.spec, since: start)
            let last = points.last.map { "\(FeedDate.day($0.time)) \(FileNumber.text($0.value))" } ?? "none"
            print("ok    \(preset.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(points.count) readings, last \(last)"
                  + String(format: "  (%.1fs)", Date().timeIntervalSince(began)))
        } catch {
            failures += 1
            print("FAIL  \(preset.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(error)")
        }
    }
    exit(failures == 0 ? 0 : 1)
}

guard arguments.count == 1 else { fail(usage) }
let text = arguments[0]
let spec: FeedSpec
if let preset = FeedCatalog.preset(id: text) {
    spec = preset.spec
} else {
    do {
        guard let parsed = try FeedSpec.parse(line: text.hasPrefix("[") ? "Feed " + text : text) else {
            fail("That isn't a feed. " + usage)
        }
        spec = parsed
    } catch {
        fail("\(error)")
    }
}

do {
    let points = try await fetcher(for: spec).fetch(spec, since: since)
    print(FeedCopy.text(points), terminator: "")
} catch {
    fail("\(error)")
}
