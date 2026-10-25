import Foundation
import Testing
import FutureEngine
@testable import FutureUI

/// Adding, changing, moving and removing slots, and setting their values (docs/UI.md, 5.7).
@MainActor
@Suite("Slot editing")
struct SlotEditingTests {
    let now = utc(2026, 10, 25)

    func makeStore() async throws -> ScenarioStore {
        let store = try ScenarioStore(definition: .homeAndMoney, now: now)
        await store.waitUntilIdle()
        return store
    }

    func index(_ store: ScenarioStore, _ name: String) throws -> Int {
        try #require(store.slots.firstIndex { $0.name == name })
    }

    @Test("Slots describe their model, parameters and starting values")
    func slotInfo() async throws {
        let store = try await makeStore()
        let savings = store.slots[0]
        #expect(savings.model == "Savings account")
        #expect(savings.summary == "Savings account · Formula · monthly")
        #expect(store.slots[3].summary == "Seasonal temperature · Formula · monthly · emits Heatwave")
        let rate = try #require(savings.parameterValues.first)
        #expect(rate.label == "Interest rate")
        #expect(rate.quantity == .percent)
        #expect(rate.value == 0.045)
        #expect(rate.sliderRange == 0...0.15)
        #expect(rate.text(0.045) == "4.5%")
        #expect(rate.parse("6") == 0.06)
        #expect(rate.parse("6%") == 0.06)
        #expect(savings.startingValues.map(\.label) == ["Balance"])
        #expect(savings.startingValues[0].text(18000) == "$18,000")
        #expect(savings.outputs.map(\.name) == ["balance"])
        #expect(store.freePositions == [5, 6, 7])
    }

    @Test("Adding a model fills a free slot, focuses it and computes it")
    func adding() async throws {
        let store = try await makeStore()
        #expect(store.addModel(ModelLibrary.bodyWeight, atPosition: 6))
        #expect(store.slots.map(\.key) == [1, 2, 3, 4, 5, 7])
        #expect(store.focused.title == "Weight")
        #expect(store.focused.colorHex == SlotPalette.color(forSlotAt: 6))
        #expect(store.sidePane == .slot)
        #expect(store.statusText().contains("6 of 8 slots"))
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.samples.isEmpty)
        #expect(store.cursorState().readoutValue != "…")

        // The same model again gets a numbered name; a full bank says so.
        store.addModel(ModelLibrary.bodyWeight)
        #expect(store.focused.name == "Weight2")
        #expect(store.focused.title == "Weight 2")
        #expect(store.focused.key == 6)
        store.addModel(ModelLibrary.prices)
        #expect(!store.addModel(ModelLibrary.prices))
        #expect(store.message == "All 8 slots are full. Remove one first.")

        store.focus(key: 6)
        #expect(store.focused.name == "Weight2")
    }

    @Test("Removing a slot pauses the slots that read it, and undo brings it all back")
    func removing() async throws {
        let store = try await makeStore()
        let climate = try index(store, "Climate")
        #expect(store.removalQuestion(forSlotAt: climate)
                == "Remove Climate? Energy bill reads Climate.temp, so it will pause. You can undo this.")
        #expect(store.removalQuestion(forSlotAt: 0) == "Remove Savings and its event? You can undo this.")

        store.requestRemoval(ofSlotAt: climate)
        #expect(store.pendingRemoval == store.slots[climate].id)
        #expect(store.sidePane == .slot)
        store.removeSlot(at: climate)
        #expect(store.pendingRemoval == nil)
        #expect(store.slots.map(\.key) == [1, 2, 3, 5])
        let bill = try index(store, "EnergyBill")
        #expect(store.slots[bill].pausedReason == "Reads Climate.temp, but there's no slot called Climate.")
        #expect(store.linkCount == 0)
        #expect(store.statusText().hasSuffix("1 paused"))
        await store.waitUntilIdle()
        store.focus(index: bill)
        #expect(store.timelineState().focus.samples.isEmpty)
        #expect(store.timelineState().focus.pausedReason != nil)
        #expect(store.cursorState().readoutNote == "Paused")
        store.focus(index: 0)
        #expect(store.cursorState().laneValues[bill] == "Paused")

        store.undo()
        #expect(store.slots.count == 5)
        #expect(store.slots.allSatisfy { !$0.isPaused })
        #expect(store.focused.name == "Climate")  // the slot that came back
        await store.waitUntilIdle()
        store.focus(named: "energybill")
        #expect(!store.timelineState().focus.samples.isEmpty)
        #expect(store.focused.reads == "← Climate.temp")
        store.redo()
        #expect(store.slots.count == 4)
    }

    @Test("Lines stay on screen while the engine catches up with a change")
    func resultsFollowSlots() async throws {
        let store = try await makeStore()
        let mortgageLine = store.timelineState().lanes.first { $0.name == "Mortgage" }?.samples
        store.removeSlot(at: 0)
        // Before the engine has answered, the slots that moved up still draw.
        #expect(store.timelineState().focus.name == "Index fund")
        #expect(!store.timelineState().focus.samples.isEmpty)
        #expect(store.timelineState().lanes.first { $0.name == "Mortgage" }?.samples == mortgageLine)
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.samples.isEmpty)
    }

    @Test("A position from before a slot was removed is ignored, not a crash")
    func staleIndexes() async throws {
        let store = try await makeStore()
        let last = store.slots.count - 1
        store.removeSlot(at: last)
        store.removeSlot(at: last)
        store.setColor("#46C8E0", inSlotAt: last)
        store.setStartingValue("rate", to: 0.1, inSlotAt: -1)
        store.previewStartingValue("rate", 0.1, inSlotAt: last)
        store.add(Event(time: utc(2030, 1), kind: "deposit", values: ["amount": 1]), toSlotAt: last)
        #expect(store.scheduledChanges(of: store.slots[0].parameterValues[0], inSlotAt: last).isEmpty)
        #expect(store.removalQuestion(forSlotAt: last) == "")
        #expect(store.slots.count == 4)
        #expect(store.slotIndex(id: store.slots[2].id) == 2)
    }

    @Test("The last slot can't be removed")
    func lastSlot() async throws {
        let store = try await makeStore()
        for _ in 0..<4 { store.removeSlot(at: 0) }
        #expect(store.slots.count == 1)
        #expect(!store.canRemoveSlot)
        store.removeSlot(at: 0)
        #expect(store.slots.count == 1)
        #expect(store.message == "A scenario needs at least one slot. Change its model instead.")
    }

    @Test("Renaming a slot updates the formulas that read it")
    func renaming() async throws {
        let store = try await makeStore()
        let climate = try index(store, "Climate")
        #expect(store.renameSlot(at: climate, to: "Local weather") == nil)
        #expect(store.slots[climate].name == "LocalWeather")
        #expect(store.slots[climate].title == "Local weather")
        let bill = try index(store, "EnergyBill")
        #expect(store.slots[bill].reads == "← LocalWeather.temp")
        #expect(!store.slots[bill].isPaused)
        #expect(store.message == "Renamed Climate to Local weather, and updated 1 formula that read it")

        #expect(store.renameSlot(at: climate, to: "savings") == "There's already a slot called Savings.")
        #expect(store.renameSlot(at: climate, to: "2050 plan") == "Names start with a letter, e.g. Rainy day fund.")
        store.undo()
        #expect(store.slots[climate].name == "Climate")
        #expect(store.slots[bill].reads == "← Climate.temp")
    }

    @Test("Renaming changes references to the slot, and nothing else")
    func renamingReferences() {
        let formula = """
            x[t] = Climate.temp + MyClimate.temp + Climate . rain
            on Climate.Heatwave: x = event.Climate
            # Climate is great
            """
        let (renamed, count) = ScenarioStore.renameReferences(in: formula, from: "Climate", to: "Weather")
        #expect(count == 3)
        #expect(renamed == """
            x[t] = Weather.temp + MyClimate.temp + Weather . rain
            on Weather.Heatwave: x = event.Climate
            # Climate is great
            """)
    }

    @Test("Names people type become formula names and back")
    func names() {
        #expect(formulaName(fromTitle: "Rainy day fund") == "RainyDayFund")
        #expect(formulaName(fromTitle: "  ISA ") == "ISA")
        #expect(formulaName(fromTitle: "401k") == nil)
        #expect(displayName("RainyDayFund") == "Rainy day fund")
        #expect(displayName("ISA") == "ISA")
        #expect(displayName("USStocks") == "US stocks")
        #expect(displayName("Savings2") == "Savings 2")
        #expect(displayName("EnergyBill") == "Energy bill")
    }

    @Test("Changing a model keeps the slot's name, events and matching values")
    func changingModel() async throws {
        let store = try await makeStore()
        store.setStartingValue("rate", to: 0.05, inSlotAt: 0)
        store.setStartingValue("monthly", to: 900, inSlotAt: 0)
        #expect(store.eventsThatWontApply(inSlotAt: 0, with: ModelLibrary.loan)
                == "1 withdraw event won't apply to this model. It's kept, but ignored.")
        #expect(store.eventsThatWontApply(inSlotAt: 0, with: ModelLibrary.indexFund) == nil)

        store.changeModel(ofSlotAt: 0, to: ModelLibrary.loan)
        let slot = store.slots[0]
        #expect(slot.name == "Savings")
        #expect(slot.model == "Loan or mortgage")
        #expect(slot.variable == "owed")
        #expect(slot.parameterValues.first { $0.name == "rate" }?.value == 0.05)  // carried over
        #expect(slot.parameterValues.first { $0.name == "rate" }?.isChanged == true)
        #expect(store.configs[0].values["monthly"] == nil)  // the loan has no such parameter
        #expect(store.configs[0].events.count == 1)
        await store.waitUntilIdle()
        #expect(!store.timelineState().focus.samples.isEmpty)
        store.undo()
        #expect(store.slots[0].model == "Savings account")
    }

    @Test("Starting values change the line from the start, can be reset and undone")
    func startingValues() async throws {
        let store = try await makeStore()
        store.show(utc(2040, 1, 1))
        await store.waitUntilIdle()
        let before = try #require(store.cursorState().focusValue)

        store.setStartingValue("rate", to: 0.08, inSlotAt: 0)
        #expect(store.slots[0].parameterValues[0].isChanged)
        #expect(store.slots[0].parameterValues[0].value == 0.08)
        await store.waitUntilIdle()
        let higher = try #require(store.cursorState().focusValue)
        #expect(higher > before + 10_000)

        store.setStartingValue("balance", to: 0, inSlotAt: 0)
        await store.waitUntilIdle()
        #expect(try #require(store.cursorState().focusValue) < higher - 18_000)

        store.setStartingValue("rate", to: nil, inSlotAt: 0)
        store.setStartingValue("balance", to: nil, inSlotAt: 0)
        #expect(!store.slots[0].parameterValues[0].isChanged)
        await store.waitUntilIdle()
        #expect(store.cursorState().focusValue == before)

        store.undo()
        store.undo()
        await store.waitUntilIdle()
        #expect(store.slots[0].startingValues[0].value == 0)

        // Other slots keep their results when one slot's values change.
        store.setStartingValue("warming", to: 0.1, inSlotAt: 3)
        await store.waitUntilIdle()
        #expect(store.slots[3].parameterValues.first { $0.name == "warming" }?.value == 0.1)
    }

    @Test("Dragging a slider previews the line; letting go applies it")
    func sliderPreview() async throws {
        let store = try await makeStore()
        store.previewStartingValue("rate", 0.12, inSlotAt: 0)
        await store.waitUntilIdle()
        #expect(!store.parameterPreview.isEmpty)
        let state = store.timelineState()
        #expect(state.focus.preview == store.parameterPreview)
        #expect(state.focus.preview.last!.value > state.focus.samples.last!.value)
        #expect(!store.slots[0].parameterValues[0].isChanged)  // nothing changes until it's let go

        store.endStartingValuePreview(commit: false)
        #expect(store.parameterPreview.isEmpty)
        #expect(!store.canUndo)

        store.previewStartingValue("rate", 0.07, inSlotAt: 0)
        store.previewStartingValue("rate", 0.09, inSlotAt: 0)
        store.endStartingValuePreview(commit: true)
        #expect(store.slots[0].parameterValues[0].value == 0.09)
        await store.waitUntilIdle()
        #expect(store.parameterPreview.isEmpty)  // a late preview doesn't come back
    }

    @Test("Slots move to another position, swapping with what's there")
    func moving() async throws {
        let store = try await makeStore()
        store.moveSlot(at: 0, toPosition: 6)
        #expect(store.slots.map(\.name) == ["IndexFund", "Mortgage", "Climate", "EnergyBill", "Savings"])
        #expect(store.slots.last?.key == 7)
        #expect(store.slots.last?.colorHex == SlotPalette.color(forSlotAt: 6))
        #expect(store.focused.name == "Savings")

        store.moveSlot(at: 4, toPosition: 1)  // onto Index fund, which goes to 7
        #expect(store.slots.map(\.key) == [2, 3, 4, 5, 7])
        #expect(store.slots[0].name == "Savings")
        #expect(store.slots.last?.name == "IndexFund")
        #expect(store.dropSlot(store.slots[0].id.uuidString, atPosition: 0))
        #expect(store.slots[0].key == 1)

        store.setColor("#46C8E0", inSlotAt: 0)
        store.moveSlot(at: 0, toPosition: 5)
        #expect(store.slots.first { $0.name == "Savings" }?.colorHex == "#46C8E0")  // its own color moves with it
    }

    @Test("Duplicating copies a slot and its events to the next free position")
    func duplicating() async throws {
        let store = try await makeStore()
        store.duplicateSlot(at: 0)
        #expect(store.focused.name == "Savings2")
        #expect(store.focused.key == 6)
        #expect(store.configs[5].events.count == 1)
        #expect(store.configs[5].events[0].id != store.configs[0].events[0].id)
        await store.waitUntilIdle()
        #expect(store.timelineState().focus.samples == store.timelineState().lanes[0].samples)
    }

    @Test("The command bar adds and removes models")
    func commandBar() async throws {
        let store = try await makeStore()
        store.commandText = "add loan to 7"
        store.runCommand()
        #expect(store.focused.model == "Loan or mortgage")
        #expect(store.focused.key == 7)

        store.commandText = "add savings account"
        store.runCommand()
        #expect(store.focused.key == 6)
        #expect(store.focused.name == "Savings2")

        store.commandText = "add loan to 3"
        store.runCommand()
        #expect(store.message == "Slot 3 has Mortgage in it. Remove it first, or add to another slot.")

        store.commandText = "add teleporter"
        store.runCommand()
        #expect(store.messageIsError)

        store.commandText = "remove climate"
        store.runCommand()
        #expect(store.pendingRemoval == store.slots[try index(store, "Climate")].id)
        #expect(store.focused.name == "Climate")
    }

    @Test("Number keys focus by position, and say when a position is empty")
    func numberKeys() async throws {
        let store = try await makeStore()
        store.moveSlot(at: 0, toPosition: 7)
        store.focus(key: 8)
        #expect(store.focused.name == "Savings")
        store.focus(key: 1)
        #expect(store.focused.name == "Savings")
        #expect(store.message == "Slot 1 is empty. Click its chip to add a model.")
        #expect(store.focus(named: "8"))
    }

    @Test("Change from a date opens the Event tab ready to set that parameter")
    func changeFromDate() async throws {
        let store = try await makeStore()
        store.showSlotSettings()
        store.beginParameterChange("monthly")
        #expect(store.sidePane == .event)
        #expect(store.eventDraft.kind == .setParameter)
        #expect(store.eventDraft.parameter == "monthly")
        store.add(Event.set(["rate": 0.04], at: utc(2027, 6, 1)), toSlotAt: 0)
        #expect(store.scheduledChanges(of: store.slots[0].parameterValues[0], inSlotAt: 0) == ["Changes to 4% from Jun 2027"])
        store.toggleSlotSettings()
        #expect(store.sidePane == .slot)
    }
}
