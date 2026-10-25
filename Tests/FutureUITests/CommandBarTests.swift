import Foundation
import Testing
import FutureEngine
@testable import FutureUI

func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Command bar")
struct CommandBarTests {
    @Test("Navigation commands")
    func navigation() throws {
        #expect(try CommandBarParser.parse("now") == .jumpToNow)
        #expect(try CommandBarParser.parse("  Today ") == .jumpToNow)
        #expect(try CommandBarParser.parse("goto 2035") == .moveCursor(utc(2035, 1)))
        #expect(try CommandBarParser.parse("go to Jun 2035") == .moveCursor(utc(2035, 6)))
        #expect(try CommandBarParser.parse("show 2031-03-15") == .moveCursor(utc(2031, 3, 15)))
        #expect(try CommandBarParser.parse("3") == .focus("3"))
        #expect(try CommandBarParser.parse("focus Index fund") == .focus("Index fund"))
    }

    @Test("Adding deposits and withdrawals")
    func events() throws {
        #expect(try CommandBarParser.parse("+500") == .addEvent(kind: "deposit", amount: 500, at: nil, repeats: nil))
        #expect(try CommandBarParser.parse("+500 monthly from 2027-03")
                == .addEvent(kind: "deposit", amount: 500, at: utc(2027, 3), repeats: .monthly))
        #expect(try CommandBarParser.parse("-$6,000 on Aug 2028")
                == .addEvent(kind: "withdraw", amount: 6000, at: utc(2028, 8), repeats: nil))
        #expect(try CommandBarParser.parse("+1.2k every year")
                == .addEvent(kind: "deposit", amount: 1200, at: nil, repeats: .yearly))
        #expect(try CommandBarParser.parse("+ 250 fortnightly")
                == .addEvent(kind: "deposit", amount: 250, at: nil, repeats: .weeks(2)))
    }

    @Test("Setting parameters")
    func parameters() throws {
        #expect(try CommandBarParser.parse("set rate 4% from 2027-06") == .setParameter(name: "rate", value: 0.04, at: utc(2027, 6)))
        #expect(try CommandBarParser.parse("set monthly 650") == .setParameter(name: "monthly", value: 650, at: nil))
    }

    @Test("Clipboard and undo")
    func clipboard() throws {
        #expect(try CommandBarParser.parse("copy") == .copySnapshot)
        #expect(try CommandBarParser.parse("copy data") == .copyData)
        #expect(try CommandBarParser.parse("undo") == .undo)
        #expect(try CommandBarParser.parse("redo") == .redo)
    }

    @Test("Mistakes get helpful errors")
    func errors() {
        #expect(throws: CommandBarError.empty) { try CommandBarParser.parse("   ") }
        #expect(throws: CommandBarError.badDate("next tuesday")) { try CommandBarParser.parse("goto next tuesday") }
        #expect(throws: CommandBarError.badAmount("lots")) { try CommandBarParser.parse("+lots") }
        #expect(throws: CommandBarError.notUnderstood("make it rain")) { try CommandBarParser.parse("make it rain") }
    }
}

@Suite("Peek gesture")
struct PeekGestureTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Holding peeks, releasing hides")
    func hold() {
        var gesture = PeekGesture()
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.release(at: t0.addingTimeInterval(0.8)) == .hide)
    }

    @Test("A quick tap opens the panel, another closes it")
    func tap() {
        var gesture = PeekGesture()
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.release(at: t0.addingTimeInterval(0.1)) == .showFully)
        #expect(gesture.press(at: t0.addingTimeInterval(1), panelVisible: true) == .nothing)
        #expect(gesture.release(at: t0.addingTimeInterval(1.1)) == .hide)
    }

    @Test("Key repeat and stray releases are ignored")
    func repeats() {
        var gesture = PeekGesture()
        #expect(gesture.release(at: t0) == .nothing)
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.press(at: t0.addingTimeInterval(0.05), panelVisible: true) == .nothing)
        #expect(gesture.release(at: t0.addingTimeInterval(0.5)) == .hide)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("Values and axis labels")
    func values() {
        #expect(ValueFormat.currency.full(41223.4) == "$41,223")
        #expect(ValueFormat.currency.full(-6000) == "−$6,000")
        #expect(ValueFormat.currency.axis(250_000) == "$250k")
        #expect(ValueFormat.currency.axis(1_250_000) == "$1.25M")
        #expect(ValueFormat.currency.axis(0) == "$0")
        #expect(ValueFormat.temperature.full(14.25) == "14.2 °C" || ValueFormat.temperature.full(14.25) == "14.3 °C")
        #expect(ValueFormat.temperature.axis(15) == "15°")
    }

    @Test("Nice ticks cover the data with round steps")
    func ticks() {
        let money = niceTicks(low: 18_000, high: 163_000, includeZero: true)
        #expect(money.domain == 0...200_000)
        #expect(money.ticks == [0, 50_000, 100_000, 150_000, 200_000])
        let temperature = niceTicks(low: 2.3, high: 20.4)
        #expect(temperature.ticks.first! <= 2.3 && temperature.ticks.last! >= 20.4)
        let flat = niceTicks(low: 5, high: 5)
        #expect(flat.domain.lowerBound < 5 && flat.domain.upperBound > 5)
    }

    @Test("Slot names read naturally")
    func names() {
        #expect(displayName("IndexFund") == "Index fund")
        #expect(displayName("Savings") == "Savings")
        #expect(displayName("EnergyBill") == "Energy bill")
    }
}

@Suite("Snapshot data")
struct SnapshotDataTests {
    let data = SnapshotData(
        scenario: "Test", createdAt: utc(2026, 10), start: utc(2026, 1), end: utc(2026, 3), cursor: utc(2026, 2), now: utc(2026, 2),
        slots: [
            .init(name: "Savings", variable: "balance", color: "#5AA9FF", format: .currency,
                  points: [.init(t: utc(2026, 1), v: 100), .init(t: utc(2026, 2), v: 110.5), .init(t: utc(2026, 3), v: 121)]),
            .init(name: "Climate", variable: "temp", color: "#FF7A93", format: .temperature,
                  points: [.init(t: utc(2026, 1), v: 2.5), .init(t: utc(2026, 3), v: 8)]),
        ])

    @Test("The table has one row per focused point and holds other slots' values")
    func table() {
        #expect(data.tsv() == """
            Date\tSavings (balance)\tClimate (temp)
            2026-01-01\t100.00\t2.50
            2026-02-01\t110.50\t2.50
            2026-03-01\t121.00\t8.00

            """)
    }

    @Test("JSON round-trips")
    func json() throws {
        #expect(try SnapshotData.decode(data.json()) == data)
    }
}
