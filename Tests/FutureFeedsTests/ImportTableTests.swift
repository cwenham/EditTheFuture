import Foundation
import Testing
import FutureEngine
@testable import FutureFeeds

/// Reading tables of readings to import: CSV, spreadsheet text and European exports (docs/UI.md, 5.10).
@Suite("Importing tables of readings")
struct ImportTableTests {
    @Test("A bank statement: the date column found by its dates, money read with symbols, newest first")
    func statement() throws {
        let table = try ImportTable("""
            Posted,Description,Amount,Balance
            2026-10-03,Coffee,-$4.50,"$1,234.56"
            2026-10-02,Salary,"$2,000.00","$1,239.06"
            2026-10-01,Rent,($900.00),($760.94)
            """)
        #expect(table.hasHeader)
        #expect(table.separator == ",")
        #expect(table.columns == ["Posted", "Description", "Amount", "Balance"])
        #expect(table.dateColumn == 0)
        #expect(table.valueColumns == [2, 3])
        let outcome = table.readings(date: 0, value: 3, variable: "balance")
        #expect(outcome.readings.map(\.value) == [-760.94, 1239.06, 1234.56])
        #expect(outcome.readings.first?.time == utc(2026, 10, 1))
        #expect(outcome.readings.allSatisfy { $0.variable == "balance" })
        #expect(outcome.skipped == 0 && outcome.repeated == 0)
        #expect(table.readings(date: 0, value: 2, variable: "x").readings.map(\.value) == [-900, 2000, -4.5])
    }

    @Test("Text copied from a spreadsheet is split by tabs, and a first line of data isn't taken for names")
    func spreadsheet() throws {
        let table = try ImportTable("2026-01-01\t41200\n2026-02-01\t41850\n2026-03-01\t\n")
        #expect(table.separator == "\t")
        #expect(!table.hasHeader)
        #expect(table.columns == ["Column 1", "Column 2"])
        let outcome = table.readings(date: 0, value: 1, variable: "balance")
        #expect(outcome.readings.map(\.value) == [41200, 41850])
        #expect(outcome.skipped == 1)
    }

    @Test("A European export: semicolons, day-first dates and decimal commas")
    func european() throws {
        let table = try ImportTable("""
            Datum;Kontostand
            05.09.2026;1.234,56 €
            06.09.2026;1.200,00 €
            """)
        #expect(table.separator == ";")
        #expect(table.dateColumn == 0)
        let outcome = table.readings(date: 0, value: 1, variable: "balance")
        #expect(outcome.readings.map(\.value) == [1234.56, 1200])
        #expect(outcome.readings.first?.time == utc(2026, 9, 5))
    }

    @Test("Slashed dates are month first, unless a day above 12 shows they're day first")
    func slashedDates() throws {
        let us = try ImportTable("date,value\n09/05/2026,1\n10/05/2026,2\n")
        #expect(us.readings(date: 0, value: 1, variable: "v").readings.first?.time == utc(2026, 9, 5))
        let uk = try ImportTable("date,value\n05/09/2026,1\n25/09/2026,2\n")
        #expect(uk.readings(date: 0, value: 1, variable: "v").readings.first?.time == utc(2026, 9, 5))
    }

    @Test("Amounts that look like years don't take the place of the dates")
    func yearsAndAmounts() throws {
        let table = try ImportTable("value,when\n1500,2026-01\n2300,2026-02\n")
        #expect(table.dateColumn == 1)
        #expect(table.valueColumns == [0])
        // Bare years are dates when nothing else is.
        let yearly = try ImportTable("Year,Population\n2020,8.0e9\n2021,8.1e9\n")
        #expect(yearly.dateColumn == 0)
        #expect(yearly.readings(date: 0, value: 1, variable: "people").readings.map(\.value) == [8.0e9, 8.1e9])
    }

    @Test("A later row for the same date replaces an earlier one, and is counted")
    func repeatedDates() throws {
        let table = try ImportTable("date,value\n2026-01-01,1\n2026-01-01,2\nnot a date,3\n")
        let outcome = table.readings(date: 0, value: 1, variable: "v")
        #expect(outcome.readings.map(\.value) == [2])
        #expect(outcome.repeated == 1)
        #expect(outcome.skipped == 1)
    }

    @Test("Empty text, a single column and notes are explained")
    func mistakes() {
        #expect(throws: FeedError.self) { try ImportTable("   \n") }
        #expect(throws: FeedError.self) { try ImportTable("just one column\nand another row\n") }
        #expect((try? ImportTable("# a note\ndate,value\n2026-01-01,1\n"))?.rows.count == 1)
    }
}
