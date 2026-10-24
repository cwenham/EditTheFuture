import Foundation
import Testing
@testable import FutureEngine

@Suite("Scenario evaluation")
struct ScenarioTests {
    let start = utc(2026, 1, 1)

    @Test("Slots are only computed as far as a query needs")
    func lazyEvaluation() throws {
        let scenario = Scenario(start: start)
        let counter = try scenario.addSlot("Counter", model: CounterModel())
        #expect(scenario.computedThrough(counter) == nil)
        #expect(try scenario.value("count", of: counter, at: utc(2026, 6, 15)) == 5)
        #expect(scenario.computedThrough(counter) == utc(2026, 6, 1))
    }

    @Test("Slot names must be valid and unique")
    func slotNames() throws {
        let scenario = Scenario(start: start)
        try scenario.addSlot("Savings", model: CounterModel())
        #expect(throws: EngineError.duplicateSlotName("Savings")) { try scenario.addSlot("Savings", model: CounterModel()) }
        #expect(throws: EngineError.invalidSlotName("2fast")) { try scenario.addSlot("2fast", model: CounterModel()) }
        #expect(throws: EngineError.invalidSlotName("has space")) { try scenario.addSlot("has space", model: CounterModel()) }
    }

    @Test("Inserting an event recomputes only what comes after it")
    func invalidationKeepsThePast() throws {
        let scenario = Scenario(start: start, checkpointInterval: 5)
        let walk = try scenario.addSlot("Walk", model: RandomWalk())
        let original = try scenario.series("x", of: walk, from: start, through: utc(2040, 1, 1))

        let shock = Event(time: utc(2030, 1, 15), kind: "shock", values: ["amount": 100])
        scenario.add(shock, to: walk)
        let shocked = try scenario.series("x", of: walk, from: start, through: utc(2040, 1, 1))

        #expect(shocked.count == original.count)
        for (before, after) in zip(original, shocked) {
            if after.time < utc(2030, 2, 1) {
                #expect(after.value == before.value)
            } else {
                #expect(abs(after.value - (before.value + 100)) < 1e-9)
            }
        }

        scenario.removeEvent(id: shock.id, from: walk)
        #expect(try scenario.series("x", of: walk, from: start, through: utc(2040, 1, 1)) == original)
    }

    @Test("A consumer can read the mean of a faster producer over its own step")
    func resampledMean() throws {
        let scenario = Scenario(start: start)
        let weather = try scenario.addSlot("Weather", model: DailyTemperature())
        let monthly = try scenario.addSlot("Monthly", model: Observer(source: Reference(slot: "Weather", variable: "temp", resampling: .mean)))

        let seen = try scenario.value("seen", of: monthly, at: utc(2026, 8, 1))
        let julyDays = try scenario.series("temp", of: weather, from: utc(2026, 7, 2), through: utc(2026, 8, 1))
        #expect(julyDays.count == 31)
        let expected = julyDays.map(\.value).reduce(0, +) / 31
        #expect(abs(seen - expected) < 1e-12)
    }

    @Test("Previous-step connections read the value from one step earlier")
    func laggedConnection() throws {
        let scenario = Scenario(start: start)
        try scenario.addSlot("Counter", model: CounterModel(rate: .monthly))
        let observer = try scenario.addSlot("Observer", model: Observer(source: Reference(slot: "Counter", variable: "count", timing: .previousStep)))
        #expect(try scenario.value("seen", of: observer, at: utc(2026, 1, 1)) == 0)
        #expect(try scenario.value("seen", of: observer, at: utc(2026, 2, 1)) == 0)
        #expect(try scenario.value("seen", of: observer, at: utc(2026, 7, 1)) == 5)
    }

    @Test("Same-step loops are rejected, and a previous-step link breaks them")
    func sameStepLoops() throws {
        let looped = Scenario(start: start)
        try looped.addSlot("A", model: Observer(source: Reference(slot: "B", variable: "seen")))
        try looped.addSlot("B", model: Observer(source: Reference(slot: "A", variable: "seen")))
        #expect(throws: EngineError.sameStepLoop(["A", "B", "A"])) { try looped.validate() }

        let lagged = Scenario(start: start)
        let a = try lagged.addSlot("A", model: Observer(source: Reference(slot: "B", variable: "seen", timing: .previousStep)))
        try lagged.addSlot("B", model: Observer(source: Reference(slot: "A", variable: "seen")))
        try lagged.validate()
        _ = try lagged.value("seen", of: a, at: utc(2027, 1, 1))
    }

    @Test("Generated events reach subscribers in the same step or the next")
    func eventRoutes() throws {
        let scenario = Scenario(start: start)
        let weather = try scenario.addSlot("Weather", model: DailyTemperature(threshold: 20))
        let reference = Reference(slot: "Weather", variable: "temp")
        let now = try scenario.addSlot("Now", model: Observer(source: reference, subscription: EventSubscription(slot: "Weather", kind: "Hot")))
        let later = try scenario.addSlot("Later", model: Observer(source: reference, subscription: EventSubscription(slot: "Weather", kind: "Hot", timing: .previousStep)))

        let hot = try scenario.generatedEvents(in: weather, through: utc(2026, 12, 31))
        #expect(hot.count == 1)
        let hotDay = hot[0].time
        #expect(hot[0].originSlot == "Weather")

        let grid = TimeGrid(start: start, rate: .monthly)
        let stepWithEvent = grid.firstIndex(atOrAfter: hotDay)
        let pointWithEvent = grid.point(stepWithEvent)
        let pointBefore = grid.point(stepWithEvent - 1)
        #expect(try scenario.value("hotEvents", of: now, at: pointBefore) == 0)
        #expect(try scenario.value("hotEvents", of: now, at: pointWithEvent) == 1)
        #expect(try scenario.value("hotEvents", of: later, at: pointWithEvent) == 0)
        #expect(try scenario.value("hotEvents", of: later, at: grid.point(stepWithEvent + 1)) == 1)
    }

    @Test("Wiring mistakes are reported clearly")
    func wiringErrors() throws {
        let missingSlot = Scenario(start: start)
        try missingSlot.addSlot("Observer", model: Observer(source: Reference(slot: "Nowhere", variable: "x")))
        #expect(throws: EngineError.unknownSlot("Nowhere", referencedBy: "Observer")) { try missingSlot.validate() }

        let missingVariable = Scenario(start: start)
        try missingVariable.addSlot("Counter", model: CounterModel())
        try missingVariable.addSlot("Observer", model: Observer(source: Reference(slot: "Counter", variable: "nope")))
        #expect(throws: EngineError.unknownVariable(slot: "Counter", variable: "nope")) { try missingVariable.validate() }

        let missingEvent = Scenario(start: start)
        try missingEvent.addSlot("Counter", model: CounterModel())
        try missingEvent.addSlot("Observer", model: Observer(source: Reference(slot: "Counter", variable: "count"),
                                                             subscription: EventSubscription(slot: "Counter", kind: "Boom")))
        #expect(throws: EngineError.unknownEventKind(slot: "Counter", kind: "Boom")) { try missingEvent.validate() }
    }

    @Test("Explicit connections work for models that don't name their sources")
    func explicitConnection() throws {
        let scenario = Scenario(start: start)
        let counter = try scenario.addSlot("Counter", model: CounterModel())
        let observer = try scenario.addSlot("Observer", model: Observer(source: Reference(slot: "Counter", variable: "count")))
        let other = try scenario.addSlot("Other", model: CounterModel(rate: .weekly))
        scenario.connect(Connection(from: other, variable: "count", to: observer, input: "input"))
        #expect(try scenario.value("seen", of: observer, at: utc(2026, 2, 1)) == 4)
        _ = counter
    }

    @Test("Goal seek solves for an event and leaves the scenario as it was")
    func goalSeek() throws {
        let scenario = Scenario(start: start)
        let walk = try scenario.addSlot("Walk", model: RandomWalk())
        let target = 1_000.0
        let date = utc(2030, 1, 1)
        let before = try scenario.value("x", of: walk, at: date)

        let result = try scenario.goalSeek("x", of: walk, at: date, target: target, within: -10_000...10_000) { amount in
            Event(time: utc(2027, 6, 15), kind: "shock", values: ["amount": amount])
        }
        #expect(abs(result.achieved - target) < 1e-6)
        #expect(abs(result.input - (target - before)) < 1e-6)
        #expect(scenario.events(in: walk).isEmpty)
        #expect(try scenario.value("x", of: walk, at: date) == before)
    }
}
