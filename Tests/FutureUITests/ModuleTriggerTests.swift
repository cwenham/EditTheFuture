import Foundation
import Testing
import FutureEngine
import FutureSimulation
@testable import FutureUI

/// A module with a trigger begins where the person is looking: a new slot gets the event at the
/// cursor, and the view eases to where its line does its changing (docs/UI.md, 5.7; DESIGN.md, 6.5).
@MainActor
@Suite("Module triggers")
struct ModuleTriggerTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        store.glideDuration = 0
        await store.waitUntilIdle()
        return store
    }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc(year, month, day).addingTimeInterval(Double(hour * 3_600 + minute * 60))
    }

    var worm: ModelTemplate { ModelLibrary.template(id: "worm")! }

    @Test("Each built-in module's trigger is an event it handles, and with its values emptied nothing happens before it")
    func everyTrigger() throws {
        for module in ModuleCatalog.app.modules {
            let trigger = try #require(module.info.trigger, "\(module.id) has no trigger")
            let model = try ModuleCatalog.app.makeModel(module.reference, name: "Slot", values: trigger.emptied)
            #expect(model.handledEventKinds.contains(trigger.kind), "\(module.id)")
            #expect(Set(trigger.emptied.keys).isSubset(of: Set(model.parameterNames + model.startingValueNames)), "\(module.id)")
            let release = utc(2026, 6, 1)
            let scenario = Scenario(start: utc(2026, 1, 1))
            let slot = try scenario.addSlot("Slot", model: model)
            scenario.add(Event(time: release, kind: trigger.kind, values: trigger.values), to: slot)
            let before = try scenario.value(module.info.shows, of: slot, at: release.addingTimeInterval(-86_400))
            let after = try scenario.value(module.info.shows, of: slot, at: release.addingTimeInterval(30 * 86_400))
            #expect(before == 0, "\(module.id)")
            #expect(after > 0, "\(module.id)")
        }
    }

    @Test("Adding the worm begins it on the cursor's day, with nobody infected before, and zooms in to the hours it spreads in")
    func addingTheWorm() async throws {
        let store = try await makeStore()
        store.show(at(2030, 3, 10, 13))
        #expect(store.frame.span > 4 * 86_400)
        let begins = Calendar.current.startOfDay(for: store.cursor)
        #expect(store.addModel(worm, atPosition: 6))
        let config = store.configs[store.focusedIndex]
        #expect(config.values == ["infected": 0])
        #expect(config.events.map(\.time) == [begins])
        #expect(config.events.map(\.kind) == ["infect"])
        #expect(config.events.map(\.values) == [["amount": 10]])
        #expect(store.message?.contains("starting with its infect event on") == true)

        await store.waitUntilIdle()
        // Code Red's numbers take about eight hours to reach everyone.
        #expect(store.frame.span > 6 * 3_600 && store.frame.span < 16 * 3_600)
        #expect(store.frame.contains(begins))
        #expect(store.cursor == begins)
        let index = store.focusedIndex
        let early = try #require(store.outputValue("infected", ofSlotAt: index, at: begins.addingTimeInterval(-60)))
        #expect(early == 0)
        await store.waitUntilIdle()
        let samples = store.timelineState().focus.samples.filter { store.frame.contains($0.time) }
        let last = try #require(samples.last)
        #expect(last.value > 0.99 * 360_000)
    }

    @Test("Zoomed in to hours, the trigger goes at the cursor's minute; an epidemic then zooms out to its months")
    func zoomedIn() async throws {
        let store = try await makeStore()
        store.show(at(2030, 3, 10, 13, 42).addingTimeInterval(17))
        store.zoom(by: 1e-12)
        #expect(store.frame.span == ScenarioStore.minimumSpan)
        #expect(store.addModel(ModelLibrary.epidemic, atPosition: 6))
        let config = store.configs[store.focusedIndex]
        #expect(config.values == ["exposed": 0])
        #expect(config.events.map(\.time) == [at(2030, 3, 10, 13, 42)])
        #expect(config.events.map(\.kind) == ["imported"])

        await store.waitUntilIdle()
        #expect(store.frame.span > 30 * 86_400 && store.frame.span < 3 * 365 * 86_400)
        await store.waitUntilIdle()
        let samples = store.timelineState().focus.samples.filter { store.frame.contains($0.time) }
        let peak = try #require(samples.max { $0.value < $1.value })
        let last = try #require(samples.last)
        // The whole outbreak is in view: it rises to its peak and has died away by the right edge.
        #expect(peak.time > store.frame.start && peak.time < store.frame.end)
        #expect(last.value < 0.05 * peak.value)
    }

    @Test("Giving a slot the worm begins it at the cursor, unless the slot already has an infect event")
    func changing() async throws {
        let store = try await makeStore()
        store.show(at(2030, 3, 10, 13))
        let begins = Calendar.current.startOfDay(for: store.cursor)
        let before = store.configs[0].events.count
        store.changeModel(ofSlotAt: 0, to: worm)
        #expect(store.configs[0].values["infected"] == 0)
        #expect(store.configs[0].events.filter { $0.kind == "infect" }.map(\.time) == [begins])
        #expect(store.configs[0].events.count == before + 1)
        await store.waitUntilIdle()
        #expect(store.frame.span < 16 * 3_600)

        store.show(utc(2040, 1, 1))
        store.changeModel(ofSlotAt: 0, to: worm)
        #expect(store.configs[0].events.filter { $0.kind == "infect" }.map(\.time) == [begins])
        await store.waitUntilIdle()
    }

    @Test("Undo takes the slot and its trigger away together")
    func undo() async throws {
        let store = try await makeStore()
        let count = store.configs.count
        store.addModel(worm, atPosition: 6)
        await store.waitUntilIdle()
        store.undo()
        #expect(store.configs.count == count)
        #expect(!store.configs.contains { $0.events.contains { $0.kind == "infect" } })
        await store.waitUntilIdle()
    }

    @Test("Moving the view before the answer comes keeps it where it was put")
    func movedFirst() async throws {
        let store = try await makeStore()
        store.addModel(worm, atPosition: 6)
        store.zoom(by: 2)
        let moved = store.frame
        await store.waitUntilIdle()
        #expect(store.frame == moved)
    }

    @Test("Easing between views zooms around the moment in the same place in both, by the same factor each moment")
    func easing() {
        let earliest = utc(2000, 1, 1)
        let a = TimeFrame(start: utc(2000, 1, 1), end: utc(2040, 1, 1))
        let b = TimeFrame(start: at(2026, 11, 3, 14), end: at(2026, 11, 3, 15))
        #expect(ScenarioStore.frame(between: a, and: b, at: 0, earliest: earliest) == a)
        let end = ScenarioStore.frame(between: a, and: b, at: 1, earliest: earliest)
        #expect(abs(end.start.timeIntervalSince(b.start)) < 1e-3)
        #expect(abs(end.span - b.span) < 1e-3)

        let half = ScenarioStore.frame(between: a, and: b, at: 0.5, earliest: earliest)
        #expect(abs(half.span - (a.span * b.span).squareRoot()) / half.span < 1e-9)
        // The moment that's the same share of the way across a and b is there halfway too.
        let share = b.start.timeIntervalSince(a.start) / (a.span - b.span)
        let fixed = a.start.addingTimeInterval(share * a.span)
        #expect(abs(fixed.timeIntervalSince(half.start) / half.span - share) < 1e-9)

        // The same span slides.
        let later = TimeFrame(start: utc(2001, 1, 1), end: utc(2001, 1, 1).addingTimeInterval(a.span))
        let sliding = ScenarioStore.frame(between: a, and: later, at: 0.5, earliest: earliest)
        #expect(abs(sliding.start.timeIntervalSince(a.start) - later.start.timeIntervalSince(a.start) / 2) < 1e-3)
        #expect(sliding.span == a.span)
        // Never before the earliest moment.
        #expect(ScenarioStore.frame(between: b, and: a, at: 0.5, earliest: at(2026, 11, 3)).start >= at(2026, 11, 3))
    }

    @Test("Clicking the graph zoomed in to hours picks the minute, not midnight")
    func pickingAMinute() async throws {
        let store = try await makeStore()
        store.show(at(2030, 3, 10, 13, 42))
        store.zoom(by: 1e-12)
        store.pickEventDate(at(2030, 3, 10, 13, 15).addingTimeInterval(31))
        #expect(store.eventDraft.date == at(2030, 3, 10, 13, 15))
        store.zoom(by: 1e6)
        store.pickEventDate(at(2030, 3, 10, 13, 15))
        #expect(store.eventDraft.date == Calendar.current.startOfDay(for: at(2030, 3, 10, 13, 15)))
    }

    @Test("A line's moves add up its changes, leaving out values that aren't finite")
    func moves() {
        func line(_ values: [Double]) -> [Sample] {
            values.enumerated().map { Sample(time: utc(2026, 1, 1).addingTimeInterval(Double($0.offset) * 60), value: $0.element) }
        }
        let rising = line([0, 10, 10, 5])
        #expect(ScenarioEngine.moves(rising) == 15)
        #expect(ScenarioEngine.end(ofMoves: rising, share: 0.5) == rising[1].time)
        #expect(ScenarioEngine.end(ofMoves: rising, share: 0.99) == rising[3].time)
        #expect(ScenarioEngine.end(ofMoves: line([3, 3, 3]), share: 0.99) == nil)
        #expect(ScenarioEngine.end(ofMoves: line([0, .infinity, .nan, 1]), share: 0.99) == nil)
        #expect(ScenarioEngine.end(ofMoves: line([.greatestFiniteMagnitude, -.greatestFiniteMagnitude]), share: 0.99) == nil)
    }
}

extension ModelTemplate {
    /// The module with no trigger, so a new slot starts at the scenario's start: for tests about
    /// other things, such as fields and backdrops, that read the outbreak from its first day.
    var startingAtStart: ModelTemplate {
        var copy = self
        copy.trigger = nil
        return copy
    }
}
