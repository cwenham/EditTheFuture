import Foundation
import Testing
import FutureEngine
@testable import FutureSimulation

private func utc(_ year: Int, _ month: Int = 1, _ day: Int = 1) -> Date {
    Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))!
}

/// A level that grows by `rate` a month, doubles in `double`, takes "bump" events, and emits Big
/// once it passes 200.
private struct Grower: NumericSimulation {
    enum N: Int { case rate, level, double, big }

    let shape = SimulationShape(
        step: .monthly,
        parameters: [.parameter("rate", 10, range: 0...100, label: "Growth a month")],
        state: [.value("level", 100, label: "Level")],
        outputs: [.value("double", label: "Twice the level")],
        hidden: ["big"], handles: ["bump"], emits: ["Big"],
        fields: [FieldDescriptor(name: "parts", geometry: "groups", keys: ["level", "double"])])

    func field(_ name: String, of s: Numbers) -> [Double]? {
        name == "parts" ? [s[N.level], s[N.double]] : nil
    }

    func start(_ s: inout Numbers, _ t: StepTime) {
        s[N.double] = 2 * s[N.level]
    }

    func step(_ s: inout Numbers, _ t: StepTime, events: [Event]) -> [GeneratedEvent] {
        s[N.level] += s[N.rate]
        for event in events where event.kind == "bump" { s[N.level] += event.values["amount"] ?? 0 }
        s[N.double] = 2 * s[N.level]
        return s.turnedTrue(s[N.level] > 200, flag: N.big) ? [GeneratedEvent(kind: "Big")] : []
    }
}

private struct GrowerModule: SimulationModule {
    let id = "grower"
    let version = 2
    let info = ModuleInfo(name: "Grower", summary: "Grows", category: "growth", slotName: "Grower", shows: "level")
    var needs: [DataNeed] = []

    func makeModel(name: String, values: [String: Double], data: ModuleData) throws -> any AuthoredModel {
        var values = values
        // Uses the table's first number as its starting level, to show the data arrived.
        if let need = needs.first, let first = data[need]?.column("start")?.first { values["level"] = first }
        return NumericModel(Grower(), source: reference.description, name: name, values: values)
    }
}

private struct OneTable: ModuleDataSource {
    let table: DataTable
    func table(for need: DataNeed) -> DataTable? { need.name == "starts" ? table : nil }
}

@Suite("Simulation modules")
struct ModuleContractTests {
    let start = utc(2026)

    @Test("The wrapper describes the module, takes a slot's own values, and runs its steps")
    func runs() throws {
        let model = NumericModel(Grower(), source: "grower@2", name: "Plant", values: ["rate": 20, "level": 50, "nonsense": 1])
        #expect(model.descriptor.name == "Plant")
        #expect(model.descriptor.readable.map(\.name) == ["rate", "level", "double"])
        #expect(model.descriptor.variable(named: "rate")?.causality == .parameter)
        #expect(model.descriptor.variable(named: "big") == nil)
        #expect(model.parameterNames == ["rate"] && model.startingValueNames == ["level"])
        #expect(model.handledEventKinds == ["bump"])
        #expect(model.overrides == ["rate": 20, "level": 50])
        #expect(model.declaredDefaults == ["rate": 10, "level": 100])
        #expect(model.startingValues == ["rate": 20, "level": 50])

        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Plant", model: model)
        #expect(try scenario.value("double", of: slot, at: start) == 100)
        #expect(try scenario.value("level", of: slot, at: utc(2026, 4)) == 110)
    }

    @Test("Set events change parameters, other events reach the step, and emitted events fire once")
    func events() throws {
        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Plant", model: NumericModel(Grower(), source: "grower@2", name: "Plant"))
        scenario.add(Event.set(["rate": 0], at: utc(2026, 3)), to: slot)
        scenario.add(Event(time: utc(2026, 5), kind: "bump", values: ["amount": 150]), to: slot)
        #expect(try scenario.value("level", of: slot, at: utc(2026, 4)) == 110)
        #expect(try scenario.value("level", of: slot, at: utc(2026, 6)) == 260)
        let generated = try scenario.generatedEvents(in: slot, through: utc(2027))
        #expect(generated.map(\.kind) == ["Big"])
        #expect(generated.first?.time == utc(2026, 5))
    }

    @Test("Readings set parameters before a step and replace values after it, saying what the step had")
    func readings() throws {
        let model = NumericModel(Grower(), source: "grower@2", name: "Plant")
        var state = try model.start(StepContext(index: 0, window: StepWindow(lower: start, upper: start, includesLower: true), stepRate: .monthly,
                                                scenarioStart: start, inputs: [:], events: [], readings: [], seed: 1))
        let context = StepContext(index: 1, window: StepWindow(lower: start, upper: utc(2026, 2), includesLower: false), stepRate: .monthly,
                                  scenarioStart: start, inputs: [:], events: [],
                                  readings: [Reading(time: utc(2026, 2), variable: "rate", value: 5),
                                             Reading(time: utc(2026, 2), variable: "level", value: 300)],
                                  seed: 1)
        var replaced: [Prediction] = []
        _ = try model.doStep(&state, context, replaced: &replaced)
        #expect(model.values(of: state)["rate"] == 5)
        #expect(model.values(of: state)["level"] == 300)
        #expect(replaced == [Prediction(variable: "level", value: 105)])

        // Saved numbers include the hidden ones, and load back.
        let saved = try #require(model.savedNumbers(of: state))
        #expect(saved.count == 4)
        #expect(model.restoredState(from: saved).map(model.values(of:)) == model.values(of: state))
        #expect(model.restoredState(from: [1, 2]) == nil)
        #expect(model.readableValues(of: state) == [5, 300, 210])
    }

    @Test("Replacing values keeps the slot's others, for Refit")
    func replacingValues() throws {
        let model = NumericModel(Grower(), source: "grower@2", name: "Plant", values: ["rate": 20])
        let changed = try model.replacingValues(["level": 1])
        #expect(changed.overrides == ["rate": 20, "level": 1])
        #expect(changed.source == "grower@2")
    }

    @Test("Module references read and write as id@version")
    func references() {
        #expect(ModuleReference(text: "epidemic@1") == ModuleReference(id: "epidemic", version: 1))
        #expect(ModuleReference(text: " Epidemic ") == ModuleReference(id: "epidemic", version: 0))
        #expect(ModuleReference(text: "epidemic@1")?.description == "epidemic@1")
        #expect(ModuleReference(text: "epidemic")?.description == "epidemic")
        for bad in ["", "@1", "epidemic@", "epidemic@0", "epidemic@x", "a b", "a@1@2", "../files"] {
            #expect(ModuleReference(text: bad) == nil, "\(bad)")
        }
    }

    @Test("The catalog checks the module, its version and its data before building")
    func catalog() throws {
        let catalog = ModuleCatalog(modules: [GrowerModule()])
        let model = try catalog.makeModel(ModuleReference(id: "grower", version: 1), name: "Plant", values: [:])
        #expect(model.source == "grower@2")
        _ = try catalog.makeModel(ModuleReference(id: "grower", version: 0), name: "Plant", values: [:])

        #expect(throws: ModuleError("This scenario uses the “weather” module, which this version of the app doesn't have.")) {
            try catalog.makeModel(ModuleReference(id: "weather", version: 1), name: "Sky", values: [:])
        }
        #expect(throws: ModuleError("This scenario was made with version 3 of Grower, and this app has version 2. Update the app to run it.")) {
            try catalog.makeModel(ModuleReference(id: "grower", version: 3), name: "Plant", values: [:])
        }

        let needy = GrowerModule(needs: [DataNeed("starts", summary: "Starting levels")])
        #expect(throws: ModuleError("Grower needs data the app hasn't got: starting levels.")) {
            try ModuleCatalog(modules: [needy]).makeModel(ModuleReference(id: "grower", version: 2), name: "Plant", values: [:])
        }
        let supplied = ModuleCatalog(modules: [needy], data: OneTable(table: DataTable(keys: ["a"], columns: ["start": [42]])))
        let fed = try supplied.makeModel(ModuleReference(id: "grower", version: 2), name: "Plant", values: [:])
        #expect(fed.startingValues["level"] == 42)
    }

    @Test("Tables give columns only when they fit the keys")
    func tables() {
        let table = DataTable(keys: ["GB", "FR"], columns: ["people": [67e6, 68e6], "short": [1]])
        #expect(table.count == 2)
        #expect(table.column("people") == [67e6, 68e6])
        #expect(table.column("short") == nil)
        #expect(table.column("missing") == nil)
    }

    @Test("Fields a module declares reach the engine, worked out from its numbers")
    func fields() throws {
        let model = NumericModel(Grower(), source: "grower@2", name: "Plant")
        #expect(model.descriptor.fields.map(\.name) == ["parts"])
        let scenario = Scenario(start: start)
        let slot = try scenario.addSlot("Plant", model: model)
        let field = try #require(try scenario.field("parts", of: slot, at: utc(2028, 7)))
        #expect(field.values == [400, 800])
        #expect(try scenario.field("other", of: slot, at: utc(2028, 7)) == nil)
    }
}
