import Foundation
import Testing
import SQLite3
import FutureEngine
import FutureFormula
@testable import FutureDocument

/// A fresh folder for one test.
func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("etf-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Makes a SQLite database with the given statements.
func makeDatabase(at url: URL, _ statements: [String]) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else { throw DatabaseReadings.Mistake("can't make it") }
    defer { sqlite3_close(db) }
    for statement in statements {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseReadings.Mistake(String(cString: sqlite3_errmsg(db)))
        }
    }
}

@Suite("Readings")
struct ReadingsTests {
    @Test("CSV readings: a date column, then a column per variable; empty cells are no reading")
    func csv() throws {
        let text = "date,price,volume\n2025-01-01,5881.63,12\n2025-02-01,,\"1,300\"\n\n2025-03-01T12:00,5954.5,\n"
        let readings = try CSVReadings.parse(text)
        #expect(readings == [
            Reading(time: utc(2025, 1), variable: "price", value: 5881.63),
            Reading(time: utc(2025, 1), variable: "volume", value: 12),
            Reading(time: utc(2025, 2), variable: "volume", value: 1300),
            Reading(time: utc(2025, 3).addingTimeInterval(12 * 3600), variable: "price", value: 5954.5),
        ])
        #expect(try CSVReadings.parse(CSVReadings.text(readings)) == readings)
        #expect(throws: CSVReadings.Mistake.self) { try CSVReadings.parse("date,price\nlast week,3\n") }
        #expect(throws: CSVReadings.Mistake.self) { try CSVReadings.parse("date,price\n2025-01-01,lots\n") }
    }

    @Test("A query reads readings from SQLite; nulls are no reading, and times can be text or seconds")
    func sqlite() throws {
        let folder = try temporaryFolder()
        let db = folder.appendingPathComponent("sensors.sqlite")
        try makeDatabase(at: db, [
            "create table readings (ts, sensor text, temp_c real)",
            "insert into readings values (1735689600, 'kitchen', 19.5)",          // 2025-01-01, as seconds
            "insert into readings values ('2025-01-02 06:00:00', 'kitchen', 18.25)",
            "insert into readings values ('2025-01-03', 'kitchen', null)",
            "insert into readings values (1735689600, 'hall', 15)",
        ])
        let readings = try DatabaseReadings.read(db, query: "select ts as date, temp_c as temp from readings where sensor = 'kitchen'",
                                                 timeLimit: 5)
        #expect(readings == [
            Reading(time: utc(2025, 1), variable: "temp", value: 19.5),
            Reading(time: utc(2025, 1, 2).addingTimeInterval(6 * 3600), variable: "temp", value: 18.25),
        ])
    }

    @Test("A query can only read that one database")
    func sqliteGuards() throws {
        let folder = try temporaryFolder()
        let db = folder.appendingPathComponent("a.sqlite")
        try makeDatabase(at: db, ["create table t (d, v)", "insert into t values ('2025-01-01', 1)"])
        let other = folder.appendingPathComponent("b.sqlite").path
        let refused = [
            "attach database '\(other)' as b",
            "insert into t values ('2025-01-02', 2)",
            "select d as date, v from t; drop table t",
            "pragma table_info(t)",
            "select v, d as date from t",
        ]
        for query in refused {
            #expect(throws: DatabaseReadings.Mistake.self, "\(query)") { try DatabaseReadings.read(db, query: query, timeLimit: 5) }
        }
        #expect(try DatabaseReadings.read(db, query: "select d as date, v from t", timeLimit: 5).count == 1)
    }

    @Test("A query that runs too long is stopped")
    func sqliteTimeLimit() throws {
        let folder = try temporaryFolder()
        let db = folder.appendingPathComponent("a.sqlite")
        try makeDatabase(at: db, ["create table t (d, v)"])
        let endless = "with recursive n(i) as (select 1 union all select i + 1 from n) select i as date, i as v from n where i < 0"
        let began = Date()
        #expect(throws: DatabaseReadings.Mistake.self) { try DatabaseReadings.read(db, query: endless, timeLimit: 0.2) }
        #expect(Date().timeIntervalSince(began) < 5)
    }

    @Test("Database readings keep a CSV copy, which is used when the database is missing")
    func databaseCopy() throws {
        let folder = try temporaryFolder()
        let db = folder.appendingPathComponent("sensors.sqlite")
        try makeDatabase(at: db, ["create table r (d, t)", "insert into r values ('2025-01-01', 21)"])
        let sources = [ReadingSource.database(title: "Sensor", path: "sensors.sqlite", query: "select d as date, t as temp from r")]
        let loaded = ReadingLoader.load(sources, slot: "Kitchen", folder: folder)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.set.readings == [Reading(time: utc(2025, 1), variable: "temp", value: 21)])
        #expect(loaded.copies.keys.sorted() == ["readings/Kitchen-sensors.csv"])

        try ScenarioPackage(url: folder).write(copies: loaded.copies)
        try FileManager.default.removeItem(at: db)
        let fallback = ReadingLoader.load(sources, slot: "Kitchen", folder: folder)
        #expect(fallback.set == loaded.set)
        #expect(fallback.problems.count == 1)
        #expect(fallback.problems[0].contains("Using the copy in readings/Kitchen-sensors.csv"))
    }
}

@Suite("Saved results")
struct SavedResultsTests {
    let source = """
        step 1 month
        param rate = 5%
        init balance = 1000
        balance[t] = balance[t-1] * (1 + rate / 12) + 100 + normal(0, 10)
        when balance > 5000 emit Rich
        on bonus: balance += event.amount
        """

    func scenario(_ events: [Event] = []) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: utc(2020, 1))
        let id = try scenario.addSlot("Savings", model: try FormulaModel(source, name: "Savings"))
        for event in events { scenario.add(event, to: id) }
        try scenario.validate()
        return (scenario, id)
    }

    @Test("A restored slot has the same values and events, and carries on as if it had computed them")
    func restore() throws {
        let (original, id) = try scenario()
        try original.ensure(id, through: utc(2040, 1))
        let history = try #require(original.history(of: id))
        #expect(history.count == 241)
        #expect(!history.generated.isEmpty)

        let (restored, restoredID) = try scenario()
        #expect(restored.restore(history, to: restoredID))
        #expect(restored.computedThrough(restoredID) == utc(2040, 1))
        #expect(try restored.series("balance", of: restoredID, from: utc(2020, 1), through: utc(2040, 1))
                == original.series("balance", of: id, from: utc(2020, 1), through: utc(2040, 1)))
        // Carrying on gives the same as computing from the start.
        #expect(try restored.series("balance", of: restoredID, from: utc(2040, 1), through: utc(2060, 1))
                == original.series("balance", of: id, from: utc(2040, 1), through: utc(2060, 1)))
        #expect(try restored.generatedEvents(in: restoredID, through: utc(2060, 1))
                == original.generatedEvents(in: id, through: utc(2060, 1)))
    }

    @Test("An event added in the middle rewinds a restored slot to a checkpoint, as usual")
    func editAfterRestore() throws {
        let (original, id) = try scenario()
        try original.ensure(id, through: utc(2040, 1))
        let history = try #require(original.history(of: id))
        let bonus = Event(time: utc(2030, 6), kind: "bonus", values: ["amount": 1000])

        let (restored, restoredID) = try scenario()
        #expect(restored.restore(history, to: restoredID))
        restored.add(bonus, to: restoredID)
        let (fresh, freshID) = try scenario([bonus])
        #expect(try restored.series("balance", of: restoredID, from: utc(2020, 1), through: utc(2045, 1))
                == fresh.series("balance", of: freshID, from: utc(2020, 1), through: utc(2045, 1)))
    }

    @Test("Results that don't fit the slot's model are refused")
    func mismatch() throws {
        let (original, id) = try scenario()
        try original.ensure(id, through: utc(2030, 1))
        var history = try #require(original.history(of: id))
        history.columns = ["rate", "other"]
        let (restored, restoredID) = try scenario()
        #expect(!restored.restore(history, to: restoredID))
        #expect(restored.computedThrough(restoredID) == nil)
    }

    @Test("A cache file reads back exactly what was written, including infinity and NaN")
    func cacheFile() throws {
        let (original, id) = try scenario()
        try original.ensure(id, through: utc(2030, 1))
        var history = try #require(original.history(of: id))
        history.values[3] = .infinity
        history.values[5] = .nan
        history.generated.append(Event(time: utc(2029, 1), kind: "Odd", values: ["x": -.infinity, "y": 0.1 + 0.2],
                                       source: .generated(slot: "Savings")))
        let folder = try temporaryFolder()
        let package = ScenarioPackage(url: folder.appendingPathComponent("Test.etf"))
        try package.writeCache(try SlotCache.data(history, slot: "Savings", fingerprint: "abc"), slot: "Savings")

        let url = try #require(package.cachedSlots()["Savings"])
        let header = try SlotCache.header(at: url)
        #expect(header.fingerprint == "abc")
        #expect(header.numbersOffset % 8 == 0)
        #expect(try SlotCache.history(at: url, fingerprint: "other") == nil)
        let back = try #require(try SlotCache.history(at: url, fingerprint: "abc"))
        #expect(back.values.count == history.values.count)
        #expect(zip(back.values, history.values).allSatisfy { FileNumber.same($0, $1) })
        #expect(back.checkpointIndices == history.checkpointIndices)
        #expect(back.checkpointStates == history.checkpointStates)
        #expect(back.currentState == history.currentState)
        #expect(back.generated.count == history.generated.count)
        let odd = try #require(back.generated.last)
        #expect(odd.values["x"] == -.infinity && odd.values["y"] == 0.1 + 0.2 && odd.originSlot == "Savings")
        #expect(back.generated.dropLast() == history.generated.dropLast())
    }
}
