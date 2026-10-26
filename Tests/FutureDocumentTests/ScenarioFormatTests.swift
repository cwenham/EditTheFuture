import Foundation
import Testing
import FutureEngine
@testable import FutureDocument

func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
    CivilDate.date(year: year, month: month, day: day)
}

/// The example from docs/DESIGN.md, 15.2.
let example = """
    # Home & money [start: 2022-01-01, seed: 0x5EEDF07E]

    Notes can go anywhere, as ordinary text. The rates are the bank's quote from October 2026.

    ## 1. Savings [Savings account, shows: balance]

    ```etf
    step 1 month
    param rate = 4.5% range 0%..15% label "Interest rate"
    param monthly = 400 range 0..5000 by 50 label "Monthly deposit" as currency
    init balance = 18000 label "Balance" as currency
    balance[t] = balance[t-1] * (1 + rate / 12) + monthly
    on deposit: balance += event.amount
    on withdraw: balance -= event.amount
    ```

    ### Values
    - monthly: 650

    ### Events
    - 2028-08-01 withdraw [amount: 6000]
    - 2030-01-01 set [rate: 3.5%]
    - 2027-03-01 deposit [amount: 500, every: 1 month, until: 2035-12-01]

    ## 2. Market [Market with ups and downs, shows: price, color: FF9F43]

    ```python
    every("1 month")
    param("drift", "6%", range=("-10%", "20%"))
    init("price", 100)

    def step(s, t):
        s.price *= 1 + s.drift / 12 + t.normal(0, 0.04)
    ```

    ### Readings
    - [S&P 500 monthly closes](readings/sp500.csv)

    ## 5. Kitchen [Room cooling, shows: temp]

    ```lua
    every "1 hour"
    param("outside", 10, { label = "Outside", as = "temperature" })
    init("temp", 20, { label = "Temperature", as = "temperature" })

    function step(s, t)
      s.temp = s.temp + (s.outside - s.temp) * 0.05
    end
    ```

    ### Readings
    - [Kitchen sensor](~/Data/sensors.sqlite)

    ```sql
    select ts as date, temp_c as temp from readings where sensor = 'kitchen'
    ```

    """

@Suite("scenario.md")
struct ScenarioFormatTests {
    // MARK: Reading

    @Test("The design's example reads as three slots with their models, values, events and readings")
    func readsExample() throws {
        let parsed = try ScenarioFormat.parse(example)
        #expect(parsed.problems.isEmpty)
        let file = parsed.file
        #expect(file.name == "Home & money")
        #expect(file.start == utc(2022, 1))
        #expect(file.seed == 0x5EED_F07E)
        #expect(file.slots.map(\.name) == ["Savings", "Market", "Kitchen"])
        #expect(file.slots.map(\.position) == [0, 1, 4])
        #expect(file.slots.map(\.language) == [.formula, .python, .lua])

        let savings = file.slots[0]
        #expect(savings.model == "Savings account")
        #expect(savings.shows == "balance")
        #expect(savings.source.hasPrefix("step 1 month\nparam rate = 4.5%"))
        #expect(savings.source.hasSuffix("on withdraw: balance -= event.amount"))
        #expect(savings.values == ["monthly": 650])
        #expect(savings.events.count == 2)
        #expect(savings.events[0].time == utc(2028, 8))
        #expect(savings.events[0].kind == "withdraw")
        #expect(savings.events[0].values == ["amount": 6000])
        #expect(savings.events[1].kind == Event.setKind)
        #expect(savings.events[1].values == ["rate": 0.035])
        #expect(savings.percentNames.contains("rate"))
        #expect(savings.rules.count == 1)
        #expect(savings.rules[0].every == .months(1))
        #expect(savings.rules[0].until == utc(2035, 12))

        #expect(file.slots[1].color == "FF9F43")
        #expect(file.slots[1].readings == [.csvFile(title: "S&P 500 monthly closes", path: "readings/sp500.csv")])
        #expect(file.slots[2].readings == [.database(title: "Kitchen sensor", path: "~/Data/sensors.sqlite",
                                                     query: "select ts as date, temp_c as temp from readings where sensor = 'kitchen'")])
    }

    @Test("Writing back what was read gives the same text")
    func roundTrip() throws {
        let parsed = try ScenarioFormat.parse(example)
        #expect(ScenarioFormat.text(for: parsed.file, over: parsed) == example)
    }

    @Test("A file written fresh reads back as the same scenario")
    func freshRoundTrip() throws {
        let parsed = try ScenarioFormat.parse(example)
        let fresh = ScenarioFormat.text(for: parsed.file)
        let again = try ScenarioFormat.parse(fresh)
        #expect(again.problems.isEmpty)
        #expect(again.file == parsed.file)
        // And it's stable: writing it again changes nothing.
        #expect(ScenarioFormat.text(for: again.file) == fresh)
    }

    @Test("The same file always gives the same event ids, and identical lines get different ones")
    func eventIDs() throws {
        let text = """
            # S [start: 2020-01-01]
            ## 1. A
            ```etf
            step 1 month
            init x = 0
            on add: x += event.amount
            ```
            ### Events
            - 2021-01-01 add [amount: 5]
            - 2021-01-01 add [amount: 5]
            - 2022-01-01 add [amount: 6000]
            """
        let a = try ScenarioFormat.parse(text).file.slots[0].events
        let b = try ScenarioFormat.parse(text).file.slots[0].events
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a[0].id != a[1].id)
        // Writing a number another way, or adding notes, doesn't change the event's id.
        let reworded = text.replacingOccurrences(of: "amount: 6000", with: "amount: 6e3")
            .replacingOccurrences(of: "### Events", with: "Some notes.\n\n### Events")
        #expect(try ScenarioFormat.parse(reworded).file.slots[0].events.map(\.id) == a.map(\.id))
    }

    // MARK: Writing back

    @Test("Changing a value rewrites only that line, and keeps notes")
    func changeValue() throws {
        let parsed = try ScenarioFormat.parse(example)
        var file = parsed.file
        file.slots[0].values["monthly"] = 700
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(text == example.replacingOccurrences(of: "- monthly: 650", with: "- monthly: 700"))
    }

    @Test("A new value of a percent is written as a percent")
    func percentValue() throws {
        let parsed = try ScenarioFormat.parse(example)
        var file = parsed.file
        file.slots[0].values["rate"] = 0.042
        file.slots[0].percentNames.insert("rate")
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(text == example.replacingOccurrences(of: "- monthly: 650", with: "- monthly: 650\n- rate: 4.2%"))
    }

    @Test("A new event goes in date order, and the other lines stay as written")
    func addEvent() throws {
        let handwritten = example.replacingOccurrences(of: "[amount: 6000]", with: "[amount: 6e3]")
        let parsed = try ScenarioFormat.parse(handwritten)
        var file = parsed.file
        file.slots[0].events.append(Event(time: utc(2029, 1), kind: "deposit", values: ["amount": 1200.5]))
        let text = ScenarioFormat.text(for: file, over: parsed)
        let expected = handwritten.replacingOccurrences(
            of: "- 2028-08-01 withdraw [amount: 6e3]\n- 2030-01-01 set [rate: 3.5%]\n- 2027-03-01 deposit [amount: 500, every: 1 month, until: 2035-12-01]",
            with: "- 2027-03-01 deposit [amount: 500, every: 1 month, until: 2035-12-01]\n- 2028-08-01 withdraw [amount: 6e3]\n"
                + "- 2029-01-01 deposit [amount: 1200.5]\n- 2030-01-01 set [rate: 3.5%]")
        #expect(text == expected)
        #expect(try ScenarioFormat.parse(text).file.slots[0].events.count == 3)
    }

    @Test("Removing every event removes the Events part")
    func removeEvents() throws {
        let parsed = try ScenarioFormat.parse(example)
        var file = parsed.file
        file.slots[0].events = []
        file.slots[0].rules = []
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(!text.contains("### Events"))
        #expect(text.contains("- monthly: 650\n\n## 2. Market"))
    }

    @Test("Changing a formula rewrites its block only")
    func changeModel() throws {
        let parsed = try ScenarioFormat.parse(example)
        var file = parsed.file
        file.slots[0].source = file.slots[0].source.replacingOccurrences(of: "18000", with: "20000")
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(text == example.replacingOccurrences(of: "init balance = 18000", with: "init balance = 20000"))
    }

    @Test("A removed slot's section goes, and a new slot goes in position order")
    func addAndRemoveSlots() throws {
        let parsed = try ScenarioFormat.parse(example)
        var file = parsed.file
        file.slots.remove(at: 1)
        file.slots.append(SlotFile(position: 2, name: "Loan", model: "Loan", source: "step 1 month\ninit owed = 1000", shows: "owed"))
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(!text.contains("Market"))
        let loan = try #require(text.range(of: "## 3. Loan [Loan, shows: owed]"))
        let kitchen = try #require(text.range(of: "## 5. Kitchen"))
        #expect(loan.lowerBound < kitchen.lowerBound)
        let again = try ScenarioFormat.parse(text)
        #expect(again.problems.isEmpty)
        #expect(again.file.slots.map(\.name) == ["Savings", "Loan", "Kitchen"])
        #expect(again.file.slots[1].source == "step 1 month\ninit owed = 1000")
        #expect(text.contains("Notes can go anywhere"))
    }

    @Test("A renamed or moved slot keeps its place and notes")
    func renameAndMove() throws {
        let withNotes = example.replacingOccurrences(of: "### Values", with: "Saving for the deposit.\n\n### Values")
        let parsed = try ScenarioFormat.parse(withNotes)
        var file = parsed.file
        file.slots[0].name = "Deposit"
        file.slots[2].position = 6
        let text = ScenarioFormat.text(for: file, over: parsed)
        #expect(text.contains("## 1. Deposit [Savings account, shows: balance]\n"))
        #expect(text.contains("## 7. Kitchen [Room cooling, shows: temp]\n"))
        #expect(text.contains("Saving for the deposit."))
    }

    // MARK: Mistakes

    @Test("A file without a start date can't be opened, and says why")
    func noStart() {
        #expect(throws: ScenarioFormat.Unreadable.self) { try ScenarioFormat.parse("# Plans\n\n## 1. A\n") }
        #expect(throws: ScenarioFormat.Unreadable.self) { try ScenarioFormat.parse("Just some text.\n") }
        #expect(throws: ScenarioFormat.Unreadable.self) { try ScenarioFormat.parse("# Plans [start: someday]\n") }
    }

    @Test("Mistakes are reported with their line, and kept as written")
    func mistakes() throws {
        let text = """
            # S [start: 2020-01-01, owner: me]

            ## 1. A [Thing, colour: purple, speed: fast]

            ```etf
            step 1 month
            init x = 0
            ```

            ### Events
            - 2021-13-01 add [amount: 5]
            - 2021-02-01 add [amount: 1,000]
            - 2021-03-01 add [amount: 5]

            ## 2. B

            Nothing here yet.

            ## 9. C

            ```etf
            step 1 year
            ```
            """
        let parsed = try ScenarioFormat.parse(text)
        let lines = parsed.problems.map { $0.line ?? 0 }
        #expect(lines == [1, 3, 3, 11, 12, 15, 19])
        #expect(parsed.problems[3].message.contains("isn't a date"))
        #expect(parsed.problems[4].message.contains("without commas: 6000, not 6,000"))
        #expect(parsed.file.slots.map(\.name) == ["A", "B"])
        #expect(parsed.file.slots[0].events.count == 1)
        #expect(parsed.file.slots[1].problem != nil)
        // Writing back keeps the mistakes, the unknown settings and the unused slot as they were.
        #expect(ScenarioFormat.text(for: parsed.file, over: parsed) == text)
        var file = parsed.file
        file.slots[0].events.append(Event(time: utc(2025, 1), kind: "add", values: ["amount": 1]))
        let changed = ScenarioFormat.text(for: file, over: parsed)
        #expect(changed.contains("- 2021-13-01 add [amount: 5]"))
        #expect(changed.contains("- 2025-01-01 add [amount: 1]"))
        #expect(changed.contains("## 9. C"))
        #expect(changed.contains("[Thing, colour: purple, speed: fast]"))
    }

    @Test("Values above the model's block end where the block starts, and a changed model is written in its place")
    func valuesAboveModel() throws {
        let text = """
            # S [start: 2020-01-01]

            ## 1. A

            ### Values
            - x: 5

            ```etf
            step 1 month
            init x = 0
            ```

            Notes after the model.
            """
        let parsed = try ScenarioFormat.parse(text)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.file.slots[0].values == ["x": 5])
        #expect(parsed.file.slots[0].source == "step 1 month\ninit x = 0")
        var file = parsed.file
        file.slots[0].source = "step 1 year\ninit x = 0"
        file.slots[0].values["x"] = 6
        #expect(ScenarioFormat.text(for: file, over: parsed)
                == text.replacingOccurrences(of: "step 1 month", with: "step 1 year").replacingOccurrences(of: "- x: 5", with: "- x: 6"))
    }

    @Test("Headings inside a model's block aren't read as headings")
    func headingsInBlocks() throws {
        let text = """
            # S [start: 2020-01-01]

            ## 1. A

            ```python
            # A comment, not a heading
            every("1 month")
            ## Still a comment
            init("x", 1)
            ```
            """
        let parsed = try ScenarioFormat.parse(text)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.file.slots[0].source.contains("## Still a comment"))
    }

    // MARK: Numbers and dates

    @Test("Numbers read back exactly, including extreme ones")
    func numbers() {
        let values: [Double] = [0, -0.0, 0.1 + 0.2, 1e300, -1e-300, 5e-324, .greatestFiniteMagnitude, 6000, 1200.5,
                                .infinity, -.infinity, 1.0 / 3, 0.045, 123_456_789_012_345_678]
        for value in values {
            for percent in [false, true] {
                let text = FileNumber.text(value, percent: percent)
                let back = FileNumber.parse(text)
                #expect(back.map { FileNumber.same($0, value) } == true, "\(value) → \(text)")
            }
        }
        #expect(FileNumber.text(.nan) == "nan")
        #expect(FileNumber.parse("nan")?.isNaN == true)
        #expect(FileNumber.text(6000) == "6000")
        #expect(FileNumber.text(0.045, percent: true) == "4.5%")
        #expect(FileNumber.parse("1.5k") == 1500)
        #expect(FileNumber.parse("$1,200") == 1200)
        #expect(FileNumber.parse("1,200", commas: false) == nil)
        #expect(FileNumber.parse("−12") == -12)
        #expect(FileNumber.parse("twelve") == nil)
        #expect(FileNumber.parse("infinity") == .infinity)
    }

    @Test("Dates read and write as ISO 8601, including years past 9999")
    func dates() {
        #expect(FileDate.parse("2028-08-01") == utc(2028, 8))
        #expect(FileDate.parse("2028-08") == utc(2028, 8))
        #expect(FileDate.parse("2028") == utc(2028, 1))
        #expect(FileDate.parse("2028-08-01T09:30") == utc(2028, 8).addingTimeInterval(9.5 * 3600))
        #expect(FileDate.parse("2028-08-01T09:30:15Z") == utc(2028, 8).addingTimeInterval(9.5 * 3600 + 15))
        #expect(FileDate.parse("2028-08-01 09:30:00", spaces: true) == utc(2028, 8).addingTimeInterval(9.5 * 3600))
        #expect(FileDate.parse("+31000-01-01") == CivilDate.date(year: 31_000, month: 1, day: 1))
        #expect(FileDate.parse("-0500-03-01") == CivilDate.date(year: -500, month: 3, day: 1))
        #expect(FileDate.parse("2028-02-30") == nil)
        #expect(FileDate.parse("28-08-01") == nil)
        #expect(FileDate.parse("2028-8-1") == nil)
        for date in [utc(2028, 8), CivilDate.date(year: 31_000, month: 6, day: 15), CivilDate.date(year: -500, month: 3, day: 1),
                     utc(2028, 8).addingTimeInterval(9.5 * 3600 + 15), CivilDate.date(year: 12_345_678, month: 1, day: 1)] {
            #expect(FileDate.parse(FileDate.text(date)) == date, "\(FileDate.text(date))")
        }
        #expect(FileDate.text(CivilDate.date(year: 31_000, month: 1, day: 1)) == "+31000-01-01")
    }

    @Test("Step rates read the formula language's units")
    func stepRates() {
        #expect(StepRate(text: "1 month") == .months(1))
        #expect(StepRate(text: "2 weeks") == .weeks(2))
        #expect(StepRate(text: "monthly") == .months(1))
        #expect(StepRate(text: "quarter") == .quarters(1))
        #expect(StepRate(text: "0 days") == nil)
        #expect(StepRate(text: "fortnight") == nil)
        for rate in [StepRate.seconds(30), .minutes(1), .hours(6), .days(1), .weeks(2), .months(3), .quarters(1), .years(10)] {
            #expect(StepRate(text: rate.text) == rate)
        }
    }

    @Test("Settings in brackets split on commas outside quotes")
    func settings() throws {
        let (label, settings) = try #require(Setting.split("Thing [Model name, shows: x, note: \"a, b\", flag]"))
        #expect(label == "Thing")
        #expect(settings == [Setting(key: "Model name", value: nil), Setting(key: "shows", value: "x"),
                             Setting(key: "note", value: "a, b"), Setting(key: "flag", value: nil)])
        #expect(Setting(key: "note", value: "a, b").text == "note: \"a, b\"")
        #expect(Setting.split("Thing open]") == nil)
        #expect(Setting.split("Thing [open")?.label == "Thing [open")
        #expect(Setting.split("Plain")?.settings == [])
    }
}
