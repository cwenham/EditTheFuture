import Foundation
import Testing
import FutureCommands
import FutureEngine
@testable import FutureUI

/// What the etf tool and Shortcuts ask of the open scenario (docs/DESIGN.md, 10.2). The engine
/// answers on its own thread, so these wait for it, as the store's tests do.
@MainActor
@Suite("Requests from the etf tool and Shortcuts")
struct OutsideRequestTests {
    let now = utc(2026, 10, 25)

    func makeStore(_ definition: ScenarioDefinition = .homeAndMoney) async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    @Test("Status and slots describe the open scenario")
    func statusAndSlots() async throws {
        let store = try await makeStore()
        let status = try #require(await store.answer(.status, now: now).status)
        #expect(status == ScenarioStatus(name: "Home & money", start: "2022-01-01", now: "2026-10-25", cursor: "2026-10-25",
                                         focused: "Savings", slotCount: 5, currency: "USD"))
        let slots = try #require(await store.answer(.slots, now: now).slots)
        #expect(slots.map(\.title) == ["Savings", "Index fund", "Mortgage", "Climate", "Energy bill"])
        #expect(slots[0].number == 1)
        #expect(slots[0].shows == "balance")
        #expect(slots[0].parameters.contains("rate"))
        #expect(slots[0].events.contains("deposit"))
        #expect(slots[3].name == "Climate")
        #expect(slots.allSatisfy { $0.paused == nil })
    }

    @Test("A value at a date is the panel's value there, written as the panel writes it")
    func valueAtDate() async throws {
        let store = try await makeStore()
        let reply = await store.answer(.value(slot: "savings", variable: nil, at: PartialDate(year: 2030, month: 1)), now: now)
        let value = try #require(reply.value)
        #expect(reply.ok)
        #expect(value.date == "2030-01-01")
        #expect(value.unit == "USD")
        #expect(value.variable == "balance")
        #expect(value.text.hasPrefix("$"))
        #expect(reply.message == "Savings will be \(value.text) in Jan 2030.")

        store.show(utc(2030, 1))
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == value.value)
        // Reading never moves anything: the panel's cursor is where the panel put it.
        #expect(store.cursor == utc(2030, 1))

        // Mid-month, it's the slot's last step before.
        let midMonth = try #require(await store.answer(.value(slot: "1", variable: nil, at: PartialDate("2030-01-20")), now: now).value)
        #expect(midMonth.value == value.value)
        #expect(midMonth.date == "2030-01-01")

        // Another of the slot's values, by name or label, in its own format.
        let rate = try #require(await store.answer(.value(slot: "Savings", variable: "Interest rate", at: nil), now: now).value)
        #expect(rate.variable == "rate")
        #expect(rate.unit == "%")
        #expect(rate.value == 0.045)

        let current = await store.answer(.value(slot: nil, variable: nil, at: nil), now: now)
        #expect(current.message.hasSuffix(" now."))
        #expect(current.message.hasPrefix("Savings is "))
    }

    @Test("Questions that can't be answered say why")
    func mistakes() async throws {
        let store = try await makeStore()
        let noSlot = await store.answer(.value(slot: "piggy bank", variable: nil, at: nil), now: now)
        #expect(!noSlot.ok)
        #expect(noSlot.message == "There's no slot called “piggy bank”. Slots: Savings, Index fund, Mortgage, Climate, Energy bill.")
        let noValue = await store.answer(.value(slot: "savings", variable: "colour", at: nil), now: now)
        #expect(noValue.message.hasPrefix("Savings has no value called “colour”. Its values: "))
        #expect(noValue.message.contains("balance"))
        let early = await store.answer(.value(slot: "savings", variable: nil, at: PartialDate(year: 2020)), now: now)
        #expect(early.message == "Savings: That's before the scenario starts, on 1 Jan 2022.")
        let tooMany = await store.answer(.series(slot: "savings", variable: nil, from: PartialDate(year: 2026),
                                                 through: PartialDate(year: 2500), every: .daily), now: now)
        #expect(!tooMany.ok)
        #expect(tooMany.message.hasPrefix("That's about 173,"))
        #expect(tooMany.message.contains("--every monthly"))
    }

    @Test("A series has a row for each step, or for each repeat asked for")
    func series() async throws {
        let store = try await makeStore()
        let year = try #require(await store.answer(.series(slot: "savings", variable: nil, from: PartialDate("2027-01"),
                                                           through: PartialDate("2027-12"), every: nil), now: now).series)
        #expect(year.rows.count == 12)
        #expect(year.rows.first?.date == "2027-01-01")
        #expect(year.rows.last?.date == "2027-12-01")
        #expect(year.unit == "USD")

        let quarters = try #require(await store.answer(.series(slot: "savings", variable: nil, from: PartialDate("2027-01-15"),
                                                               through: PartialDate("2028-01-15"), every: .quarterly), now: now).series)
        #expect(quarters.rows.map(\.date) == ["2027-01-15", "2027-04-15", "2027-07-15", "2027-10-15", "2028-01-15"])
        // Each holds the slot's value from its last step: the 15th of January has the 1st's.
        #expect(quarters.rows[0].value == year.rows[0].value)
        #expect(quarters.rows[1].value == year.rows[3].value)

        // Without dates: ten years from today.
        let decade = try #require(await store.answer(.series(slot: "climate", variable: nil, from: nil, through: nil, every: nil),
                                                     now: now).series)
        #expect(decade.rows.count == 120)
        #expect(decade.rows.first?.date == "2026-11-01")
        #expect(decade.unit == "°C")
    }

    @Test("Huge, infinite and NaN values travel as they are")
    func extremeValues() async throws {
        let store = try await makeStore(.runaway)
        let rocket = try #require(await store.answer(.value(slot: "rocket", variable: nil, at: PartialDate(year: 2050)), now: now).value)
        #expect(rocket.value == .infinity)
        let furnace = try #require(await store.answer(.value(slot: "furnace", variable: nil, at: PartialDate(year: 2400)), now: now))
        let back = try Wire.decode(Reply.self, from: Wire.encode(furnace))
        #expect(back.value?.value.isNaN == furnace.value?.value.isNaN)
        let rows = try #require(await store.answer(.series(slot: "rocket", variable: nil, from: PartialDate("2045"),
                                                           through: PartialDate("2048"), every: .yearly), now: now).series)
        #expect(rows.rows.last?.value == .infinity)
        #expect(try Wire.decode(Reply.self, from: Wire.encode(Reply(ok: true, message: "", series: rows))).series == rows)

        // The snippet's line leaves out what it can't draw, and never builds a bad range.
        let answer = try #require(try? await store.value(slot: "giant", variable: nil, at: utc(2040, 1), now: now, points: 30).get())
        #expect(answer.line.count == 30)
    }

    @Test("A value for Shortcuts comes with its line, from now to the date")
    func snippetLine() async throws {
        let store = try await makeStore()
        let answer = try #require(try? await store.value(slot: "savings", variable: nil, at: utc(2036, 1), now: now, points: 40).get())
        #expect(answer.line.count == 40)
        #expect(answer.line.first?.time == now)
        #expect(answer.line.last?.time == utc(2036, 1))
        #expect(answer.line.last?.value == answer.reading.value)
        #expect(answer.slotTitle == "Savings")
        #expect(answer.style.format == .currency)
        // Around now when the date is now.
        let around = try #require(try? await store.value(slot: "savings", variable: nil, at: now, now: now, points: 10).get())
        #expect(around.line.first!.time < now)
        #expect(around.line.last!.time > now)
    }

    @Test("Events from outside are checked, added, said, and can be undone")
    func events() async throws {
        let store = try await makeStore()
        let at2030 = PartialDate(year: 2030, month: 1)
        let before = try #require(await store.answer(.value(slot: "savings", variable: nil, at: at2030), now: now).value).value

        let deposit = EventRequest(slot: "savings", kind: "deposit", values: ["amount": Amount(500)], at: PartialDate("2027-01"),
                                   every: .monthly)
        #expect(store.describe(deposit, now: now) == .success("+$500 every month from Jan 2027 to Savings"))
        #expect(!store.canUndo)
        let added = store.addEvent(deposit, now: now)
        #expect(added == .done("Added +$500 every month from Jan 2027 to Savings"))
        #expect(store.message == added.message)
        let after = try #require(await store.answer(.value(slot: "savings", variable: nil, at: at2030), now: now).value).value
        #expect(after > before + 500 * 36)
        store.undo()
        let undone = try #require(await store.answer(.value(slot: "savings", variable: nil, at: at2030), now: now).value).value
        #expect(undone == before)

        // A plain number for a percent is in percent, as in the Slot tab; with % it's a fraction.
        let rate = store.addEvent(EventRequest(slot: "savings", kind: "set", values: ["rate": Amount(5)], at: PartialDate("2027-01")), now: now)
        #expect(rate == .done("Set rate to 5% from Jan 2027 in Savings"))
        #expect(store.configs[0].events.last?.values["rate"] == 0.05)
        _ = store.addEvent(EventRequest(slot: "savings", kind: "SET", values: ["Rate": Amount(0.06, isFraction: true)]), now: now)
        #expect(store.configs[0].events.last?.values["rate"] == 0.06)
        #expect(store.configs[0].events.last?.time == now)

        func refused(_ request: EventRequest) -> String {
            let reply = store.addEvent(request, now: now)
            #expect(!reply.ok)
            #expect(store.messageIsError)
            return reply.message
        }
        #expect(refused(EventRequest(slot: "savings", kind: "deposit", values: ["amount": Amount(500)], currency: "£"))
                == "Savings is in US dollars. Give the amount in $, or without a currency.")
        #expect(refused(EventRequest(slot: "savings", kind: "bonus", values: ["amount": Amount(1)]))
                == "Savings doesn't take “bonus” events. It takes deposit and withdraw.")
        #expect(refused(EventRequest(slot: "climate", kind: "deposit", values: ["amount": Amount(1)]))
                == "Climate doesn't take events. Its parameters can be set, such as mean.")
        #expect(refused(EventRequest(slot: "savings", kind: "withdraw", values: ["amount": Amount(0.5, isFraction: true)]))
                == "A withdraw takes an amount of money above zero.")
        #expect(refused(EventRequest(slot: "savings", kind: "set", values: ["colour": Amount(1)]))
                .hasPrefix("Savings has no parameter called “colour”."))
        #expect(refused(EventRequest(slot: "nowhere", kind: "deposit", values: ["amount": Amount(1)])).hasPrefix("There's no slot called"))

        // Other kinds of event a slot takes, with their values.
        let overpay = store.addEvent(EventRequest(slot: "mortgage", kind: "overpay", values: ["amount": Amount(2000)],
                                                  at: PartialDate("2030-03")), now: now)
        #expect(overpay.ok)
        #expect(overpay.message == "Added an overpay event (amount 2,000) on Mar 2030 to Mortgage")
    }

    @Test("goto from outside answers once the engine has looked")
    func goto() async throws {
        let store = try await makeStore()
        let year = await store.goto("2035")
        #expect(year == .done("Cursor at Jan 2035"))
        #expect(store.cursor == utc(2035, 1))
        let found = await store.goto("savings $100k")
        #expect(found.ok)
        #expect(found.message.hasPrefix("Savings reaches $100,000 in "))
        let nonsense = await store.goto("the moon")
        #expect(!nonsense.ok)
        #expect(nonsense.message.hasPrefix("“the moon” isn't a date"))
    }

    @Test("Slots are added from outside, and removing one asks in the panel")
    func slots() async throws {
        let store = try await makeStore()
        #expect(await store.undoForReply() == .failed("There's nothing to undo."))
        let added = await store.addModel(named: "loan", toSlot: 7)
        #expect(added.ok)
        #expect(store.slots.count == 6)
        #expect(store.slots.last?.key == 7)
        let taken = await store.addModel(named: "loan", toSlot: 7)
        #expect(!taken.ok)
        let missing = await store.addModel(named: "teleporter", toSlot: nil)
        #expect(!missing.ok)

        let removal = await store.removeSlot(named: "climate")
        #expect(removal == .done("Confirm in the Slot tab to remove Climate."))
        #expect(store.pendingRemoval == store.slots[3].id)
        #expect(store.slots.count == 6)

        #expect(await store.undoForReply().ok)
        #expect(store.slots.count == 5)
        #expect(await store.redoForReply().ok)
        #expect(store.slots.count == 6)
    }
}
