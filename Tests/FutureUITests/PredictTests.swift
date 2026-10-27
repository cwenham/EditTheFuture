import Foundation
import Observation
import Testing
import FutureDocument
import FutureEngine
@testable import FutureUI

/// Predict with in the panel (docs/UI.md, 5.11): the menu of models, their scores on readings they
/// didn't see, the previews, and choosing one.
@MainActor
@Suite("Predict with in the panel")
struct PredictTests {
    let now = utc(2026, 10, 25)
    let start = utc(2020, 1, 1)

    static let refittable = """
        step 1 month
        param growth = 3% range -50%..100% label "Growth per month" fit
        init value = 0
        value[t] = value[t-1] * (1 + growth)
        """

    /// Swings of up to 1 around a line rising 0.3 a year, monthly from 1995 to 2015: they cross zero.
    static func noisyLine(count: Int = 240) -> [Reading] {
        ForecastModelTests.monthly(from: utc(1995, 1, 1), count: count) { index, year in
            0.3 * (year - 2000) + ForecastModelTests.noise(index)
        }
    }

    func makeStore(_ readings: [Reading], formula: String? = nil, model: String = "Hold the latest") async throws -> ScenarioStore {
        let set = SlotReadings(sources: [.inline(csv: "")], parts: [ReadingSet(readings)])
        let definition = ScenarioDefinition(name: "Predict", start: start, slots: [
            SlotSpec(name: "Data", model: model,
                     formula: formula ?? ScenarioStore.dataSeriesFormula(label: "Value", format: .number, step: .months(1)),
                     variable: "value", format: .number, readings: set),
            SlotSpec(name: "Plain", formula: Self.refittable, variable: "value", format: .number),
        ])
        let store = try ScenarioStore(definition: definition, now: now)
        await store.waitUntilIdle()
        return store
    }

    func settle(_ store: ScenarioStore) async {
        await store.waitForPredict()
        await store.waitUntilIdle()
    }

    @Test("The menu lists the Forecast models that suit the readings, with the slot's own ticked")
    func rows() async throws {
        let store = try await makeStore(Self.noisyLine())
        store.openPredict(slotAt: 0)
        let state = try #require(store.predict)
        #expect(store.sidePane == .slot)
        #expect(state.variable == "value")
        // The readings cross zero, so the models that work in ratios aren't offered.
        #expect(state.rows.map(\.name) == ["Hold the latest", "Steady change", "Recent change", "Trend line", "Seasonal"])
        #expect(state.rows.map(\.isCurrent) == [true, false, false, false, false])
        #expect(state.rows.allSatisfy { $0.group == "Forecast" })
        #expect(state.rows.map(\.fittedCount) == [0, 1, 1, 2, 4])
        #expect(state.selection == state.rows[0].id)
        #expect(state.isComparing)
        #expect(state.status == "Comparing 5 models…")
        #expect(state.best == nil)

        // A slot without readings has nothing to predict from, and the menu stays as it was.
        store.openPredict(slotAt: 1)
        #expect(store.messageIsError)
        #expect(store.predict?.slot == store.slots[0].id)
    }

    @Test("Scores fill in, and a noisy line's best is a line through its readings")
    func scores() async throws {
        let store = try await makeStore(Self.noisyLine())
        store.openPredict(slotAt: 0)
        await settle(store)
        let state = try #require(store.predict)
        #expect(!state.isComparing)
        #expect(state.status == nil)
        for row in state.rows {
            let score = try #require(row.score, "\(row.name)")
            #expect(score.text.hasPrefix("off by "))
            #expect(score.compared > 100)
        }
        let trend = try #require(state.rows.first { $0.name == "Trend line" })
        #expect(state.best == trend.id)
        let fitted = try #require(trend.score?.fitted)
        #expect(fitted.map(\.label) == ["Value in 2000", "Change per year"])
        #expect(abs(trend.score!.values["perYear"]! - 0.3) < 0.03)
    }

    @Test("Selecting a model previews its fitted line dashed and its held-back test dotted")
    func preview() async throws {
        let store = try await makeStore(Self.noisyLine())
        store.openPredict(slotAt: 0)
        await settle(store)
        let trend = try #require(store.predict?.rows.first { $0.name == "Trend line" })
        store.selectPredict(trend.id)
        await store.waitUntilIdle()
        let focus = store.timelineState().focus
        #expect(!focus.preview.isEmpty)
        #expect(!focus.heldBack.isEmpty)
        #expect(focus.cutoff == trend.score?.cutoff)

        // Moving down the list selects the next model; past the end it stays on the last.
        store.movePredictSelection(by: 1)
        #expect(store.predict?.selection == store.predict?.rows[4].id)
        store.movePredictSelection(by: 5)
        #expect(store.predict?.selection == store.predict?.rows[4].id)

        store.closePredict()
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.preview.isEmpty)
        #expect(store.timelineState().focus.heldBack.isEmpty)
        #expect(store.heldBack == nil)
    }

    @Test("Choosing a model gives the slot it with its fitted values, and undo takes it back")
    func choose() async throws {
        let store = try await makeStore(Self.noisyLine())
        let before = store.configs[0]
        store.openPredict(slotAt: 0)
        await settle(store)
        store.usePredictBest()
        #expect(store.predict == nil)
        let config = store.configs[0]
        #expect(config.model == "Trend line")
        #expect(config.formula.contains("perYear * (year - 2000)"))
        #expect(abs(config.values["perYear"]! - 0.3) < 0.03)
        #expect(store.message?.hasPrefix("Data now predicts with Trend line: Value in 2000 ") == true)
        await store.waitUntilIdle()
        #expect(store.slots[0].model == "Trend line")

        store.undo()
        #expect(store.configs[0].formula == before.formula)
        #expect(store.configs[0].model == "Hold the latest")
    }

    @Test("A slot's own model that isn't a Forecast model comes first, and choosing it refits it")
    func ownModel() async throws {
        let readings = ForecastModelTests.monthly(from: utc(2000, 1, 1), count: 120) { index, _ in 1000 * pow(1.01, Double(index)) }
        let store = try await makeStore(readings, formula: Self.refittable, model: "Growth")
        store.openPredict(slotAt: 0)
        let state = try #require(store.predict)
        #expect(state.rows.first?.name == "Growth")
        #expect(state.rows.first?.group == "This slot")
        #expect(state.rows.first?.isCurrent == true)
        // All above zero, so every Forecast model is offered.
        #expect(state.rows.count == 1 + ForecastModels.Kind.allCases.count)
        await settle(store)
        store.openRefit(slotAt: 0)
        #expect(store.predict == nil)
        store.openPredict(slotAt: 0)
        #expect(store.refit == nil)
        // The scores were kept, so choosing doesn't wait.
        #expect(store.predict?.isComparing == false)
        store.choosePredict("current")
        #expect(abs(store.configs[0].values["growth"]! - 0.01) < 1e-4)
        #expect(store.configs[0].formula == Self.refittable)
        #expect(store.message?.hasPrefix("Refitted Data: Growth per month ") == true)
    }

    @Test("Too few readings says why, and nothing is scored")
    func tooFew() async throws {
        let store = try await makeStore(Self.noisyLine(count: 15))
        store.openPredict(slotAt: 0)
        await settle(store)
        let state = try #require(store.predict)
        #expect(state.problem?.hasPrefix("Comparing models needs more readings") == true)
        #expect(!state.isComparing)
        #expect(state.best == nil)
        #expect(state.rows.allSatisfy { $0.phase == .waiting })
    }

    @Test("Choosing the readings scores again, and scores are kept for when the menu opens again")
    func windowAndKeeping() async throws {
        let store = try await makeStore(Self.noisyLine())
        store.openPredict(slotAt: 0)
        await settle(store)
        let all = try #require(store.predict?.rows.first { $0.name == "Trend line" }?.score)

        store.setPredictWindow(.tenYears)
        #expect(store.predict?.isComparing == true)
        await settle(store)
        let recent = try #require(store.predict?.rows.first { $0.name == "Trend line" }?.score)
        #expect(recent.cutoff > all.cutoff)
        #expect(recent.compared < all.compared)

        store.closePredict()
        store.openPredict(slotAt: 0)
        #expect(store.predict?.isComparing == false)
        #expect(store.predict?.rows.first { $0.name == "Trend line" }?.score == all)
    }

    @Test("Leaving the Slot tab, focusing another slot, opening Refit or cancelling closes the menu")
    func closing() async throws {
        let store = try await makeStore(Self.noisyLine())
        for leave in [{ store.focus(index: 1) }, { store.showFormulaEditor() }, { store.toggleSlotSettings() },
                      { store.beginEvent(at: store.now) }, { store.closePredict() }] as [() -> Void] {
            store.closeRefit()
            store.focus(index: 0)
            store.openPredict(slotAt: 0)
            #expect(store.predict != nil)
            leave()
            #expect(store.predict == nil)
            await store.waitForPredict()
        }
    }

    @Test("predict in the command bar opens the menu with a model selected, or the best once it's known")
    func command() async throws {
        #expect(try CommandBarParser.parse("predict") == .predict(slot: nil, with: nil))
        #expect(try CommandBarParser.parse("predict data") == .predict(slot: "data", with: nil))
        #expect(try CommandBarParser.parse("predict data with trend line") == .predict(slot: "data", with: "trend line"))
        #expect(try CommandBarParser.parse("predict with best") == .predict(slot: nil, with: "best"))

        let store = try await makeStore(Self.noisyLine())
        store.commandText = "predict data with trend"
        _ = store.runCommand()
        #expect(store.predict?.selectedRow?.name == "Trend line")
        store.closePredict()

        store.commandText = "predict data with best"
        _ = store.runCommand()
        #expect(store.predict?.wantsBest == true)
        await settle(store)
        #expect(store.predict?.selectedRow?.name == "Trend line")
        #expect(store.predict?.wantsBest == false)
        #expect(!store.timelineState().focus.heldBack.isEmpty)

        store.commandText = "predict data with crystal ball"
        _ = store.runCommand()
        #expect(store.messageIsError)
    }

    @Test("The best is the lowest score, but within a tenth of it the model fitting fewer values wins")
    func ranking() {
        func row(_ id: String, _ fitted: Int, _ typical: Double?) -> PredictState.Row {
            PredictState.Row(id: id, name: id, summary: "", group: "", isCurrent: false, fittedCount: fitted,
                             phase: typical.map { .scored(PredictState.Score(typical: $0, text: "", values: [:], fitted: [],
                                                                            cutoff: .distantPast, line: [], compared: 1)) }
                                ?? .failed("no"))
        }
        #expect(PredictState.best(of: [row("a", 4, 1.0), row("b", 2, 1.05), row("c", 0, 1.2)]) == "b")
        #expect(PredictState.best(of: [row("a", 4, 1.0), row("b", 2, 1.15)]) == "a")
        #expect(PredictState.best(of: [row("a", 1, 0.5), row("b", 1, 0.52), row("c", 1, nil)]) == "a")
        #expect(PredictState.best(of: [row("c", 1, nil)]) == nil)
    }
}
