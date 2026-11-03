import Foundation
import Testing
@testable import FutureEngine

/// Three regions, each a random walk with its own drift, pushed by `push` events and by an input.
/// The field `regions` is the three levels; the outputs record them too, so a field worked out
/// from a checkpoint can be checked against what the straight run recorded at every point.
private struct Regions: TimelineModel {
    static let keys = ["north", "middle", "south"]

    var descriptor: ModelDescriptor {
        ModelDescriptor(name: "Regions", stepRate: .monthly,
                        variables: [Variable(name: "push", causality: .input),
                                    Variable(name: "north", causality: .output), Variable(name: "middle", causality: .output),
                                    Variable(name: "south", causality: .output), Variable(name: "total", causality: .output)],
                        capabilities: [.stochastic],
                        fields: [FieldDescriptor(name: "regions", label: "Levels", geometry: "groups", keys: Self.keys),
                                 FieldDescriptor(name: "broken", geometry: "groups", keys: Self.keys)])
    }

    func start(_ context: StepContext) throws -> [Double] { [100, 200, 300] }

    func doStep(_ state: inout [Double], _ context: StepContext) throws -> [GeneratedEvent] {
        var random = context.makeRandom()
        let push = context.inputs["push"] ?? 0
        for index in state.indices {
            state[index] += Double(index + 1) + random.normal(mean: 0, sd: 3) + push
        }
        for event in context.events where event.kind == "push" { state[0] += event.values["amount"] ?? 0 }
        return []
    }

    func values(of state: [Double]) -> [String: Double] {
        ["north": state[0], "middle": state[1], "south": state[2], "total": state.reduce(0, +)]
    }

    func field(_ name: String, of state: [Double]) -> [Double]? {
        switch name {
        case "regions": return state
        case "broken": return [1]
        default: return nil
        }
    }
}

@Suite("Fields")
struct FieldTests {
    let start = utc(2026, 1, 1)

    func scenario() throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: start)
        let counter = try scenario.addSlot("Counter", model: CounterModel())
        let regions = try scenario.addSlot("Regions", model: Regions())
        scenario.connect(Connection(from: counter, variable: "count", to: regions, input: "push"))
        scenario.add(Event(time: utc(2027, 5, 1), kind: "push", values: ["amount": 50]), to: regions)
        return (scenario, regions)
    }

    @Test("A field at any point matches the state the straight run had there, from checkpoints")
    func matchesStraightRun() throws {
        let (scenario, slot) = try scenario()
        try scenario.ensure(slot, through: utc(2036, 1, 1))
        var month = start
        // Every month for ten years: 120 points across four checkpoints, and the last point.
        while month <= utc(2036, 1, 1) {
            let field = try #require(try scenario.field("regions", of: slot, at: month))
            #expect(field.time == month)
            #expect(field.keys == Regions.keys)
            for key in Regions.keys {
                #expect(field[key] == (try scenario.value(key, of: slot, at: month)), "\(key) at \(month)")
            }
            month = Calendar.utcGregorian.date(byAdding: .month, value: 1, to: month)!
        }
    }

    @Test("A date between points gives the last point before it, and computes as far as needed")
    func betweenPoints() throws {
        let (scenario, slot) = try scenario()
        let field = try #require(try scenario.field("regions", of: slot, at: utc(2030, 6, 17)))
        #expect(field.time == utc(2030, 6, 1))
        #expect(field["middle"] == (try scenario.value("middle", of: slot, at: utc(2030, 6, 1))))
        #expect(field["west"] == nil)
        #expect(scenario.computedThrough(slot).map { $0 >= utc(2030, 6, 1) } == true)
    }

    @Test("After an edit, the field follows the recomputed results")
    func afterEdit() throws {
        let (scenario, slot) = try scenario()
        try scenario.ensure(slot, through: utc(2030, 1, 1))
        let before = try #require(try scenario.field("regions", of: slot, at: utc(2028, 3, 1)))
        scenario.add(Event(time: utc(2027, 1, 1), kind: "push", values: ["amount": 1000]), to: slot)
        let after = try #require(try scenario.field("regions", of: slot, at: utc(2028, 3, 1)))
        #expect(abs(after["north"]! - before["north"]! - 1000) < 1e-9)
        #expect(after["north"] == (try scenario.value("north", of: slot, at: utc(2028, 3, 1))))
    }

    @Test("Fields the model hasn't got are nil, a wrong count is an error, and before the start is refused")
    func mistakes() throws {
        let (scenario, slot) = try scenario()
        #expect(try scenario.field("nothing", of: slot, at: utc(2027, 1, 1)) == nil)
        #expect(throws: EngineError.self) { try scenario.field("broken", of: slot, at: utc(2027, 1, 1)) }
        #expect(throws: EngineError.dateBeforeStart) { try scenario.field("regions", of: slot, at: utc(2020, 1, 1)) }
        // Models without fields have none.
        let counter = SlotID(rawValue: 0)
        #expect(scenario.descriptor(of: counter).fields.isEmpty)
        #expect(try scenario.field("regions", of: counter, at: utc(2027, 1, 1)) == nil)
    }

    @Test("Descriptors written before fields existed still read")
    func oldDescriptors() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CounterModel().descriptor)) as! [String: Any]
        json.removeValue(forKey: "fields")
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == CounterModel().descriptor)
    }
}
