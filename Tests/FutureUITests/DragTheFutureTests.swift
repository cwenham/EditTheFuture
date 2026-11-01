import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// Drag the future in the panel (docs/UI.md, 5.2): a target dragged on the focused line, the fixes
/// ranked in the card, the path and the target on the graph, and adding a fix.
@MainActor
@Suite("Drag the future")
struct DragTheFutureTests {
    let now = utc(2026, 10, 25)
    let date = utc(2040, 1, 1)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    /// Savings' value at `date`, read from the engine.
    func value(_ store: ScenarioStore, at date: Date) async -> Double {
        guard case .samples(let samples) = await store.read(.init(slot: 0, variable: "balance", points: .at([date]))) else { return .nan }
        return samples[0].value
    }

    @Test("A target can be set only after now, on a slot that runs")
    func whereTargetsGo() async throws {
        let store = try await makeStore()
        #expect(!store.canSetGoal(at: utc(2025, 1, 1)))
        #expect(store.canSetGoal(at: date))
        store.beginGoal(at: utc(2025, 1, 1), value: 1)
        #expect(store.goal == nil)
    }

    @Test("Dragging sets a target, and the card ranks the fixes, smallest change first")
    func fixes() async throws {
        let store = try await makeStore()
        let current = await value(store, at: date)
        store.beginGoal(at: date, value: current)
        store.dragGoal(to: current + 50_000)
        await store.waitUntilIdle()
        let goal = try #require(store.goal)
        #expect(goal.isDragging)
        #expect(goal.startOptions == [utc(2026, 11, 1), utc(2027, 1, 1), utc(2030, 1, 1)])
        #expect(goal.start == utc(2026, 11, 1))
        #expect(goal.changeOptions.map(\.id) == ["anything", "p:rate", "p:monthly", "e:deposit", "e:withdraw"])
        #expect(goal.phase == .solved)
        #expect(abs((goal.current ?? 0) - current) < 0.01)
        #expect(goal.fixes.count >= 3)
        #expect(goal.fixes.map(\.size) == goal.fixes.map(\.size).sorted())
        let titles = goal.fixes.map(\.title)
        #expect(titles.contains { $0.hasPrefix("Monthly deposit $") && $0.hasSuffix(" from Nov 2026") })
        #expect(titles.contains { $0.hasPrefix("Interest rate ") && $0.hasSuffix(" from Nov 2026") })
        #expect(titles.contains { $0.hasPrefix("One deposit of $") && $0.hasSuffix(" in Nov 2026") })
        // A withdrawal can't take the line up.
        #expect(!titles.contains { $0.contains("withdraw") })
        // The target snaps to a round step of the graph's range while dragged.
        #expect(goal.target.truncatingRemainder(dividingBy: 1_000) == 0)
        #expect(abs(goal.target - current - 50_000) <= 500)
        #expect(store.goalSummary()?.hasPrefix("Reaching $213,000 by Jan 2040 needs $4") == true)
        #expect(store.goalSummary()?.contains(" more than the current projection of $") == true)

        // The graph shows the target, the gap and the selected fix's path, dashed.
        let focus = store.timelineState().focus
        let mark = try #require(focus.goal)
        #expect(mark.target == goal.target)
        #expect(mark.gap?.hasPrefix("+$4") == true)
        #expect(focus.preview == goal.fixes[0].line)
        #expect(focus.draftDate == goal.fixes[0].event.time)
    }

    @Test("While dragging, the graph's range holds still; letting go takes in the target")
    func range() async throws {
        let store = try await makeStore()
        let before = store.timelineState().focus.yDomain
        let current = await value(store, at: date)
        store.beginGoal(at: date, value: current)
        store.dragGoal(to: before.upperBound * 3)
        #expect(store.timelineState().focus.yDomain == before)
        store.endGoalDrag()
        #expect(store.timelineState().focus.yDomain.contains(before.upperBound * 3))
        #expect(store.goal?.isDragging == false)
    }

    @Test("Choosing what may change and when it starts solves again")
    func choices() async throws {
        let store = try await makeStore()
        let current = await value(store, at: date)
        store.beginGoal(at: date, value: current + 50_000)
        store.endGoalDrag()
        store.setGoalChange("e:deposit")
        await store.waitUntilIdle()
        #expect(store.goal?.fixes.map(\.title).allSatisfy { $0.hasPrefix("One deposit of") } == true)
        store.setGoalStart(utc(2030, 1, 1))
        await store.waitUntilIdle()
        let later = try #require(store.goal?.fixes.first)
        #expect(later.title.hasSuffix(" in Jan 2030"))

        store.setGoalChange("p:rate")
        store.setGoalStart(utc(2026, 11, 1))
        await store.waitUntilIdle()
        // The rate from now, and the same from three years on, which changes more.
        let fixes = try #require(store.goal?.fixes)
        #expect(fixes.count == 2)
        #expect(fixes[1].detail.hasSuffix("Starts later, so it changes more."))
        #expect(fixes[0].detail.contains(" points from "))
    }

    @Test("Adding a fix brings the line to the target, and undo takes it back")
    func applying() async throws {
        let store = try await makeStore()
        let current = await value(store, at: date)
        let target = current + 50_000
        store.beginGoal(at: date, value: current)
        store.dragGoal(to: target)
        store.endGoalDrag()
        await store.waitUntilIdle()
        store.moveGoalSelection(by: 1)
        #expect(store.goal?.selected == 1)
        store.moveGoalSelection(by: -5)
        let fix = try #require(store.goal?.selectedFix)
        let events = store.configs[0].events.count
        store.applyGoalFix()
        #expect(store.goal == nil)
        #expect(store.configs[0].events.count == events + 1)
        #expect(store.message?.hasPrefix("Added: \(fix.title).") == true)
        await store.waitUntilIdle()
        // Within the rounding of the value it changed.
        let reached = await value(store, at: date)
        #expect(abs(reached - target) / target < 0.01)

        store.undo()
        await store.waitUntilIdle()
        #expect(abs(await value(store, at: date) - current) < 0.01)
    }

    @Test("Cancelling, or focusing another slot, drops the target and changes nothing")
    func cancelling() async throws {
        let store = try await makeStore()
        let current = await value(store, at: date)
        store.beginGoal(at: date, value: current + 10_000)
        await store.waitUntilIdle()
        store.cancelGoal()
        #expect(store.goal == nil)
        #expect(store.timelineState().focus.goal == nil)
        #expect(store.timelineState().focus.preview.isEmpty)

        store.beginGoal(at: date, value: current + 10_000)
        store.focus(index: 1)
        #expect(store.goal == nil)
        #expect(abs(await value(store, at: date) - current) < 0.01)
    }

    @Test("Dragging the target again picks it up where it is")
    func dragAgain() async throws {
        let store = try await makeStore()
        let current = await value(store, at: date)
        store.beginGoal(at: date, value: current + 10_000)
        store.endGoalDrag()
        store.beginGoal(at: date, value: current + 10_000)
        #expect(store.goal?.isDragging == true)
        #expect(store.goal?.target == current + 10_000)
    }
}
