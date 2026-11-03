import Foundation
import Testing
@testable import FutureEngine

/// Halves every minute, so a minute after a kick it's half, and after about half an hour it's
/// nothing and settled. `kick` events add their amount, readings of x replace it, and `parts` is a
/// field of x and 2x.
private struct Decay: TimelineModel {
    var withInput = false

    var descriptor: ModelDescriptor {
        var variables = [Variable(name: "x", causality: .output)]
        if withInput { variables.append(Variable(name: "push", causality: .input)) }
        return ModelDescriptor(name: "Decay", stepRate: .minutes(1), variables: variables, emits: ["Kicked"], capabilities: [.settles],
                               fields: [FieldDescriptor(name: "parts", geometry: "groups", keys: ["x", "twice"])])
    }

    func start(_ context: StepContext) throws -> Double { 1 }

    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] {
        state *= 0.5
        var emitted: [GeneratedEvent] = []
        for event in context.events where event.kind == "kick" {
            state += event.values["amount"] ?? 0
            emitted.append(GeneratedEvent(kind: "Kicked"))
        }
        state += context.inputs["push"] ?? 0
        for reading in context.readings where reading.variable == "x" { state = reading.value }
        if state < 1e-9 { state = 0 }
        return emitted
    }

    func values(of state: Double) -> [String: Double] { ["x": state] }
    func field(_ name: String, of state: Double) -> [Double]? { name == "parts" ? [state, 2 * state] : nil }
    func isSettled(_ state: Double) -> Bool { state == 0 }
    func savedNumbers(of state: Double) -> [Double]? { [state] }
    func restoredState(from numbers: [Double]) -> Double? { numbers.first }
}

/// Counts minutes; it never settles.
private struct Minutes: TimelineModel {
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Minutes", stepRate: .minutes(1), variables: [Variable(name: "n", causality: .output)])
    }
    func start(_ context: StepContext) throws -> Double { 0 }
    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] { state += 1; return [] }
    func values(of state: Double) -> [String: Double] { ["n": state] }
}

@Suite("Settled models")
struct SettlingTests {
    let start = utc(2026, 1, 1)

    func at(_ date: Date, minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }

    fileprivate func decay(_ model: Decay = Decay()) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: start)
        return (scenario, try scenario.addSlot("Decay", model: model))
    }

    @Test("A settled model holds for ever: a century of minutes takes a few dozen steps")
    func holdsForever() throws {
        let (scenario, slot) = try decay()
        let far = utc(2126, 1, 1)
        let began = Date()
        #expect(try scenario.value("x", of: slot, at: far) == 0)
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(scenario.storedCount(of: slot) < 50)
        #expect(scenario.computedThrough(slot) == .distantFuture)
        #expect(try scenario.value("x", of: slot, at: at(start, minutes: 1)) == 0.5)
        #expect(try scenario.value("x", of: slot, at: at(start, minutes: 3)) == 0.125)
        #expect(try scenario.point("x", of: slot, atOrBefore: at(far, minutes: 0.5)).time == far)
        #expect(try scenario.generatedEvents(in: slot, through: far).isEmpty)
    }

    @Test("Held stretches come as their first and last points, so the line is drawn the same")
    func series() throws {
        let (scenario, slot) = try decay()
        let samples = try scenario.series("x", of: slot, from: start, through: utc(2026, 1, 2))
        #expect(samples.count < 50)
        #expect(samples.first == Sample(time: start, value: 1))
        #expect(samples.last == Sample(time: utc(2026, 1, 2), value: 0))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.time < $1.time })
        // Starting inside a held stretch.
        let later = try scenario.series("x", of: slot, from: utc(2026, 6, 1), through: utc(2026, 6, 2))
        #expect(later == [Sample(time: utc(2026, 6, 1), value: 0), Sample(time: utc(2026, 6, 2), value: 0)])
    }

    @Test("An event far ahead wakes it at its own step; it settles again after")
    func eventAhead() throws {
        let (scenario, slot) = try decay()
        let kick = at(utc(2030, 6, 1), minutes: 720)
        scenario.add(Event(time: kick, kind: "kick", values: ["amount": 8]), to: slot)
        #expect(try scenario.value("x", of: slot, at: at(kick, minutes: -1)) == 0)
        #expect(try scenario.value("x", of: slot, at: kick) == 8)
        #expect(try scenario.value("x", of: slot, at: at(kick, minutes: 2)) == 2)
        #expect(try scenario.value("x", of: slot, at: utc(2100, 1, 1)) == 0)
        #expect(scenario.storedCount(of: slot) < 120)
        #expect(try scenario.generatedEvents(in: slot, through: utc(2100, 1, 1)).map(\.time) == [kick])
    }

    @Test("An event added after it settled, inside the held stretch, is computed from where it settled")
    func eventAddedLater() throws {
        let (scenario, slot) = try decay()
        _ = try scenario.value("x", of: slot, at: utc(2100, 1, 1))
        let kick = utc(2050, 3, 1)
        scenario.add(Event(time: kick, kind: "kick", values: ["amount": 4]), to: slot)
        #expect(try scenario.value("x", of: slot, at: at(kick, minutes: -1)) == 0)
        #expect(try scenario.value("x", of: slot, at: at(kick, minutes: 1)) == 2)
        #expect(scenario.storedCount(of: slot) < 120)
        // And taken away again.
        scenario.removeEvent(id: scenario.events(in: slot)[0].id, from: slot)
        #expect(try scenario.value("x", of: slot, at: at(kick, minutes: 1)) == 0)
    }

    @Test("Repeating events and readings wake it too")
    func repeatingAndReadings() throws {
        let (scenario, slot) = try decay()
        scenario.add(RecurringEvent(kind: "kick", values: ["amount": 16], first: utc(2027, 1, 1), every: .daily), to: slot)
        scenario.setReadings([Reading(time: utc(2028, 1, 1), variable: "x", value: 3)], for: slot)
        // Each day's kick is a few dozen minutes of work, not 1,440.
        _ = try scenario.value("x", of: slot, at: utc(2027, 2, 1))
        #expect(scenario.storedCount(of: slot) < 32 * 60)
        #expect(try scenario.value("x", of: slot, at: utc(2027, 1, 5)) == 16)
        #expect(try scenario.value("x", of: slot, at: at(utc(2027, 1, 5), minutes: 1)) == 8)
        #expect(try scenario.value("x", of: slot, at: at(utc(2027, 1, 5), minutes: 600)) == 0)
        #expect(try scenario.value("x", of: slot, at: utc(2028, 1, 1)) == 3)
        #expect(try scenario.value("x", of: slot, at: at(utc(2028, 1, 1), minutes: 1)) == 1.5)
    }

    @Test("Fields inside a held stretch, and after one, match the run")
    func fields() throws {
        let (scenario, slot) = try decay()
        let kick = utc(2040, 1, 1)
        scenario.add(Event(time: kick, kind: "kick", values: ["amount": 8]), to: slot)
        _ = try scenario.value("x", of: slot, at: utc(2045, 1, 1))
        #expect(try scenario.field("parts", of: slot, at: utc(2035, 1, 1))?.values == [0, 0])
        for minutes in [0.0, 1, 2, 5] {
            let date = at(kick, minutes: minutes)
            let x = try scenario.value("x", of: slot, at: date)
            #expect(try scenario.field("parts", of: slot, at: date)?.values == [x, 2 * x], "\(minutes)")
        }
    }

    @Test("Slots that read another slot never skip, and read a held slot's values")
    func readers() throws {
        let scenario = Scenario(start: start)
        let source = try scenario.addSlot("Source", model: Minutes())
        let pushed = try scenario.addSlot("Pushed", model: Decay(withInput: true))
        scenario.connect(Connection(from: source, variable: "n", to: pushed, input: "push"))
        _ = try scenario.value("x", of: pushed, at: at(start, minutes: 600))
        #expect(scenario.storedCount(of: pushed) == 601)

        // An hourly reader of a held slot sees its held value. The first hour includes the start, when it's 1.
        let reader = Scenario(start: start)
        let decaying = try reader.addSlot("Decay", model: Decay())
        let hourly = try reader.addSlot("Hourly", model: HourlyReader())
        reader.connect(Connection(from: decaying, variable: "x", to: hourly, input: "x", resampling: .max))
        #expect(try reader.value("seen", of: hourly, at: utc(2026, 1, 1).addingTimeInterval(3600)) == 1)
        #expect(try reader.value("seen", of: hourly, at: utc(2026, 1, 1).addingTimeInterval(7200)) == 0)
        #expect(try reader.value("seen", of: hourly, at: utc(2026, 3, 1)) == 0)
    }

    @Test("Held results aren't cached; results without held points still are")
    func cache() throws {
        let (scenario, slot) = try decay()
        _ = try scenario.value("x", of: slot, at: at(start, minutes: 10))
        #expect(scenario.history(of: slot) != nil)
        _ = try scenario.value("x", of: slot, at: utc(2030, 1, 1))
        #expect(scenario.history(of: slot) == nil)
    }

    @Test("Only models that say they can settle are asked")
    func onlyWhenDeclared() throws {
        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Undeclared", model: Undeclared())
        _ = try scenario.value("x", of: slot, at: at(start, minutes: 300))
        #expect(scenario.storedCount(of: slot) == 301)
    }
}

/// Takes the largest of an input each hour.
private struct HourlyReader: TimelineModel {
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Hourly", stepRate: .hours(1),
                        variables: [Variable(name: "x", causality: .input), Variable(name: "seen", causality: .output)])
    }
    func start(_ context: StepContext) throws -> Double { 0 }
    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] {
        state = context.inputs["x"] ?? -1
        return []
    }
    func values(of state: Double) -> [String: Double] { ["seen": state] }
}

/// Says it's settled, but its descriptor doesn't say it can settle, so it's never asked.
private struct Undeclared: TimelineModel {
    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Undeclared", stepRate: .minutes(1), variables: [Variable(name: "x", causality: .output)])
    }
    func start(_ context: StepContext) throws -> Double { 0 }
    func doStep(_ state: inout Double, _ context: StepContext) throws -> [GeneratedEvent] { [] }
    func values(of state: Double) -> [String: Double] { ["x": state] }
    func isSettled(_ state: Double) -> Bool { true }
}
