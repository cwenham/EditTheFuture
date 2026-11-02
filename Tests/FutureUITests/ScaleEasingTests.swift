import Foundation
import Testing
@testable import FutureUI

/// Graphs' value ranges easing to new ones over a second (docs/UI.md, 2.4).
@MainActor
@Suite("Scale easing")
struct ScaleEasingTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let money = ScaleKey(role: .focus, style: .money(.usd))

    @Test("A new range eases from the old one over a second, fast at first")
    func easing() {
        let easing = ScaleEasing()
        easing.retarget([money: 0...100], at: t0)
        #expect(easing.range(money, target: 0...100, at: t0) == 0...100)
        #expect(!easing.isMoving(at: t0))

        easing.retarget([money: 0...200], at: t0)
        #expect(easing.range(money, target: 0...200, at: t0) == 0...100)
        #expect(easing.isMoving(at: t0))
        #expect(easing.end(after: t0) == t0.addingTimeInterval(1))

        let half = easing.range(money, target: 0...200, at: t0.addingTimeInterval(0.5)).upperBound
        #expect(half > 150 && half < 200)  // ease-out: past halfway by half time
        #expect(easing.range(money, target: 0...200, at: t0.addingTimeInterval(1)) == 0...200)
        #expect(!easing.isMoving(at: t0.addingTimeInterval(1)))
        #expect(easing.end(after: t0.addingTimeInterval(1)) == nil)
    }

    @Test("A new target part-way starts from the last frame drawn, and the same target changes nothing")
    func retargeting() {
        let easing = ScaleEasing()
        easing.retarget([money: 0...100], at: t0)
        easing.retarget([money: 0...200], at: t0)
        let mid = t0.addingTimeInterval(0.3)
        let drawn = easing.range(money, target: 0...200, at: mid)
        easing.retarget([money: 0...200], at: mid)  // the same target: keeps going
        #expect(easing.range(money, target: 0...200, at: mid) == drawn)
        #expect(easing.end(after: mid) == t0.addingTimeInterval(1))

        easing.advance(to: mid)  // the frame drawn
        easing.retarget([money: 0...50], at: mid)
        #expect(easing.range(money, target: 0...50, at: mid) == drawn)
        #expect(easing.range(money, target: 0...50) == drawn)
        #expect(easing.end(after: mid) == mid.addingTimeInterval(1))
    }

    @Test("Another kind of value changes the scale at once, and gone graphs are forgotten")
    func otherKinds() {
        let easing = ScaleEasing()
        let degrees = ScaleKey(role: .focus, style: .temperature)
        easing.retarget([money: 0...400_000], at: t0)
        easing.retarget([degrees: 0...3], at: t0)
        #expect(easing.range(degrees, target: 0...3, at: t0) == 0...3)
        #expect(easing.motions.keys.map { $0 } == [degrees])
    }

    @Test("Huge ranges stay finite while easing")
    func hugeRanges() {
        let easing = ScaleEasing()
        easing.retarget([money: 0...1e5], at: t0)
        easing.retarget([money: -1e300...1e300], at: t0)
        for step in 0...10 {
            let range = easing.range(money, target: -1e300...1e300, at: t0.addingTimeInterval(Double(step) / 10))
            #expect(range.lowerBound.isFinite && range.upperBound.isFinite)
        }
    }

    @Test("The eased timeline moves the graph, its shared overlays and the lanes together")
    func easedTimeline() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        await store.waitUntilIdle()
        let easing = ScaleEasing()
        let before = store.timelineState()
        easing.retarget(before.scaleTargets, at: t0)

        store.select(index: try #require(store.slots.firstIndex { $0.name == "Mortgage" }), click: .toggle)
        store.select(index: try #require(store.slots.firstIndex { $0.name == "Climate" }), click: .toggle)
        await store.waitUntilIdle()
        let after = store.timelineState()
        #expect(after.focus.yDomain != before.focus.yDomain)
        easing.retarget(after.scaleTargets, at: t0)

        let start = after.eased(by: easing, at: t0)
        #expect(start.focus.yDomain == before.focus.yDomain)
        let mortgage = try #require(start.overlays.first { !$0.ownScale })
        #expect(mortgage.yDomain == before.focus.yDomain)
        // Climate's own scale is new, so it starts where it's going.
        let climate = try #require(start.overlays.first { $0.ownScale })
        #expect(climate.yDomain == after.overlays.first { $0.ownScale }?.yDomain)

        let done = after.eased(by: easing, at: t0.addingTimeInterval(1))
        #expect(done.focus.yDomain == after.focus.yDomain)
        #expect(done.lanes.map(\.yDomain) == after.lanes.map(\.yDomain))
    }
}
