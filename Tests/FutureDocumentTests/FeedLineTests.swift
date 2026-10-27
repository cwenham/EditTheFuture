import Foundation
import Testing
import FutureEngine
@testable import FutureDocument

@Suite("Feeds in scenario.md")
struct FeedLineTests {
    static let text = """
        # Rates [start: 2022-01-01]

        ## 1. Savings [Savings account, shows: balance]

        ```etf
        step 1 month
        param rate = 4.5%
        init balance = 18000
        balance[t] = balance[t-1] * (1 + rate / 12)
        ```

        ### Readings
        - 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent, every: 1 day]
        - Statement balances [feed: csv, url: "https://bank.example/statements.csv?a=1,2", date: Posted, value: Balance]

        A note about where the readings come from.
        """

    @Test("A feed is a line with feed: in its brackets, and its settings keep their order")
    func reads() throws {
        let parsed = try ScenarioFormat.parse(Self.text)
        #expect(parsed.problems.isEmpty)
        let readings = parsed.file.slots[0].readings
        #expect(readings.count == 2)
        let fred = try #require(readings[0].feed)
        #expect(fred.title == "10-year Treasury yield")
        #expect(fred.provider == "fred")
        #expect(fred.settings.map(\.key) == ["series", "into", "convert", "every"])
        #expect(fred["series"] == "DGS10")
        #expect(fred.variable == "rate")
        #expect(fred.conversion == .percent)
        #expect(fred.refresh == .days(1))
        #expect(fred.query == [FeedSetting("series", "DGS10")])
        let csv = try #require(readings[1].feed)
        #expect(csv["url"] == "https://bank.example/statements.csv?a=1,2")
        #expect(csv.variable == nil)
    }

    @Test("An unchanged file is written back as it was, and a new feed gets one line")
    func writesBack() throws {
        let parsed = try ScenarioFormat.parse(Self.text)
        #expect(ScenarioFormat.text(for: parsed.file, over: parsed) == Self.text)

        var file = parsed.file
        file.slots[0].readings.append(.feed(FeedSpec(title: "US national debt", provider: "treasury", settings: [
            FeedSetting("dataset", "v2/accounting/od/debt_to_penny"), FeedSetting("field", "tot_pub_debt_out_amt"),
            FeedSetting("into", "balance"),
        ])))
        let written = ScenarioFormat.text(for: file, over: parsed)
        #expect(written.contains("""
            - 10-year Treasury yield [feed: fred, series: DGS10, into: rate, convert: percent, every: 1 day]
            - Statement balances [feed: csv, url: "https://bank.example/statements.csv?a=1,2", date: Posted, value: Balance]
            - US national debt [feed: treasury, dataset: v2/accounting/od/debt_to_penny, field: tot_pub_debt_out_amt, into: balance]
            """))
        let again = try ScenarioFormat.parse(written)
        #expect(again.file.slots[0].readings == file.slots[0].readings)
    }

    @Test("A feed with a mistake is skipped and reported with its line")
    func mistakes() throws {
        let text = """
            # Rates [start: 2022-01-01]

            ## 1. Savings

            ```etf
            init balance = 1
            balance[t] = balance[t-1]
            ```

            ### Readings
            - Yield [feed: fred, series: DGS10, every: sometimes]
            - Yield [feed: fred, series: DGS10, convert: kelvin]
            - Yield [feed: , series: DGS10]
            - Yield [feed: fred, series]
            - Fine [feed: fred, series: DGS2]
            """
        let parsed = try ScenarioFormat.parse(text)
        #expect(parsed.file.slots[0].readings.compactMap(\.feed).map(\.title) == ["Fine"])
        #expect(parsed.problems.map(\.line) == [11, 12, 13, 14])
        #expect(parsed.problems[0].message.contains("isn't a time step"))
        #expect(parsed.problems[1].message.contains("percent or fahrenheit"))
    }

    @Test("A feed's copy is named for its slot and what it fetches, with a hash when the name lost anything")
    func copyPath() {
        let fred = FeedSpec(title: "Yield", provider: "fred", settings: [FeedSetting("series", "DGS10"), FeedSetting("into", "rate")])
        #expect(fred.copyPath(slot: "Rates") == "readings/Rates-fred-DGS10.csv")
        // How the readings are used doesn't change the copy.
        var other = fred
        other["into"] = "price"
        other["convert"] = "percent"
        #expect(other.copyPath(slot: "Rates") == fred.copyPath(slot: "Rates"))

        let bonds = FeedSpec(title: "Bonds", provider: "treasury", settings: [FeedSetting("filter", "security_desc:eq:Treasury Bonds")])
        let bills = FeedSpec(title: "Bills", provider: "treasury", settings: [FeedSetting("filter", "security_desc:eq:Treasury Bills")])
        let path = bonds.copyPath(slot: "Rates")
        #expect(path.hasPrefix("readings/Rates-treasury-security_desc-eq-Treasury-Bonds-"))
        #expect(path.hasSuffix(".csv"))
        #expect(path != bills.copyPath(slot: "Rates"))
        let debt = FeedSpec(title: "Debt", provider: "treasury", settings: [
            FeedSetting("dataset", "v2/accounting/od/debt_to_penny"), FeedSetting("field", "tot_pub_debt_out_amt"),
        ])
        #expect(!debt.copyPath(slot: "Debt").contains("--"))
        #expect(path == bonds.copyPath(slot: "Rates"))
    }

    @Test("convert and scale turn a source's numbers into the slot's")
    func conversion() {
        var spec = FeedSpec(title: "Yield", provider: "fred", settings: [FeedSetting("convert", "percent")])
        #expect(spec.value(4.5) == 0.045)
        #expect(spec.value(4.98) == 0.0498)
        #expect(spec.value(1e-5) == 1e-7)
        spec["convert"] = "fahrenheit"
        #expect(abs(spec.value(212) - 100) < 1e-12)
        spec["convert"] = nil
        spec["scale"] = "1000"
        #expect(spec.value(2.5) == 2500)
    }

    @Test("A feed's readings come from its copy, as the variable it names")
    func loads() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = FeedSpec(title: "Yield", provider: "fred", settings: [
            FeedSetting("series", "DGS10"), FeedSetting("into", "rate"), FeedSetting("convert", "percent"),
        ])
        // Not fetched yet: no readings and nothing wrong.
        var loaded = ReadingLoader.load([.feed(spec)], slot: "Rates", folder: folder)
        #expect(loaded.set.readings.isEmpty)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.parts.count == 1)

        let copy = folder.appendingPathComponent(spec.copyPath(slot: "Rates"))
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FeedCopy.text([FeedPoint(time: utc(2026, 9), value: 4.79), FeedPoint(time: utc(2026, 10), value: 5)])
            .write(to: copy, atomically: true, encoding: .utf8)
        loaded = ReadingLoader.load([.inline(csv: "date,rate\n2020-01-01,0.01"), .feed(spec)], slot: "Rates", folder: folder)
        #expect(loaded.parts.map(\.readings.count) == [1, 2])
        #expect(loaded.set.readings.map(\.value) == [0.01, 0.0479, 0.05])
        #expect(loaded.set.variables == ["rate"])

        // Without into, the variable the graph shows; without either, it says what's missing.
        var plain = spec
        plain["into"] = nil
        #expect(ReadingLoader.load([.feed(plain)], slot: "Rates", folder: folder, variable: "yield").set.variables == ["yield"])
        #expect(ReadingLoader.load([.feed(plain)], slot: "Rates", folder: folder).problems.first?.contains("into:") == true)
    }

    @Test("New readings replace the old from the first new one; older ones stay")
    func merges() {
        let old = (1...6).map { FeedPoint(time: utc(2026, $0), value: Double($0)) }
        let new = [FeedPoint(time: utc(2026, 5), value: 50), FeedPoint(time: utc(2026, 7), value: 70),
                   FeedPoint(time: utc(2026, 6), value: .nan), FeedPoint(time: utc(2026, 7), value: 71)]
        let merged = FeedCopy.merge(old, with: new)
        #expect(merged.map(\.value) == [1, 2, 3, 4, 50, 71])
        #expect(FeedCopy.merge(old, with: []) == old)
    }

    @Test("A copy is CSV with a date and a value, even with no readings")
    func copyText() throws {
        #expect(FeedCopy.text([]) == "date,value\n")
        #expect(try FeedCopy.parse("date,value\n").isEmpty)
        let points = [FeedPoint(time: utc(1790, 1), value: 71_060_508.5), FeedPoint(time: utc(2026, 10, 23), value: 40_463_151_897_249.19)]
        #expect(try FeedCopy.parse(FeedCopy.text(points)) == points)
    }
}
