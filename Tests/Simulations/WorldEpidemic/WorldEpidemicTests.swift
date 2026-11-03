import Foundation
import Testing
import FutureEngine
import FutureSimulation
@testable import WorldEpidemicSimulation

/// The World epidemic module, on small made-up worlds, with nothing but the engine.
@Suite("World epidemic module")
struct WorldEpidemicTests {
    static let start = date(2026, 1, 1)

    static func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar.utcGregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A big country at (0, 0), a middling one about 1,100 km east, and a small one across the world.
    static let three = DataTable(keys: ["AAA", "BBB", "CCC"],
                                 columns: ["population": [10_000_000, 5_000_000, 1_000_000],
                                           "latitude": [0, 0, 0], "longitude": [0, 10, 120]])

    func world(_ table: DataTable = Self.three, _ values: [String: Double] = [:]) throws -> (Scenario, SlotID) {
        let scenario = Scenario(start: Self.start)
        let model = try WorldEpidemicModule().makeModel(name: "Pandemic", values: ["originLatitude": 0, "originLongitude": 0]
                                                            .merging(values) { $1 },
                                                        data: ModuleData(tables: ["countries": table]))
        return (scenario, try scenario.addSlot("Pandemic", model: model))
    }

    func cases(_ scenario: Scenario, _ slot: SlotID, at date: Date) throws -> [String: Double] {
        let field = try #require(try scenario.field("infected", of: slot, at: date))
        let people = Self.three.column("population")!
        return Dictionary(uniqueKeysWithValues: field.keys.enumerated().map { ($0.element, field.values[$0.offset] * people[$0.offset]) })
    }

    /// The share an unchecked outbreak reaches: z = 1 − e^(−R₀ z).
    static func finalShare(r0: Double) -> Double {
        var z = 0.5
        for _ in 0..<200 { z = 1 - exp(-r0 * z) }
        return z
    }

    @Test("One country on its own is the single-population model, step for step")
    func oneCountry() throws {
        let alone = DataTable(keys: ["AAA"], columns: ["population": [1_000_000], "latitude": [0], "longitude": [0]])
        let (scenario, slot) = try world(alone)
        // The same daily equations, written out.
        var e = 10.0, i = 0.0, r = 0.0
        var day = Self.start
        for _ in 0..<400 {
            day = day.addingTimeInterval(86_400)
            let caught = (1_000_000 - e - i - r) * -expm1(-2.5 / 7 * i / 1_000_000)
            let showing = e / 5, recovering = i / 7
            (e, i, r) = (e + caught - showing, i + showing - recovering, r + recovering)
            if Int(day.timeIntervalSince(Self.start) / 86_400) % 37 == 0 {
                #expect(abs(try scenario.value("infectious", of: slot, at: day) - i) < 1e-6 * max(1, i))
            }
        }
        let reached = try scenario.value("cases", of: slot, at: Self.date(2029, 1)) / 1_000_000
        #expect(abs(reached - Self.finalShare(r0: 2.5)) < 0.005)
    }

    @Test("Travel carries it abroad: nearer and bigger countries first, and every country reaches the final size")
    func spreads() throws {
        let (scenario, slot) = try world()
        func arrival(_ code: String) throws -> Date? {
            var day = Self.start
            while day < Self.date(2030, 1) {
                if try cases(scenario, slot, at: day)[code]! >= 1 { return day }
                day = day.addingTimeInterval(7 * 86_400)
            }
            return nil
        }
        let b = try #require(try arrival("BBB")), c = try #require(try arrival("CCC"))
        #expect(b < c)
        #expect(try scenario.value("reached", of: slot, at: Self.date(2030, 1)) == 3)
        let end = try cases(scenario, slot, at: Self.date(2032, 1))
        for (code, people) in zip(["AAA", "BBB", "CCC"], [10e6, 5e6, 1e6]) {
            #expect(abs(end[code]! / people - Self.finalShare(r0: 2.5)) < 0.01, "\(code)")
        }
    }

    @Test("With no travel, or a ban from the start, it stays where it began; a trace abroad never grows")
    func noTravel() throws {
        let (scenario, slot) = try world(Self.three, ["travel": 0])
        let end = try cases(scenario, slot, at: Self.date(2030, 1))
        #expect(end["AAA"]! > 8_000_000)
        #expect(end["BBB"] == 0 && end["CCC"] == 0)
        #expect(try scenario.value("reached", of: slot, at: Self.date(2030, 1)) == 1)

        // Banned on day two: the little that crossed on day one never makes a whole case.
        let (banned, bannedSlot) = try world()
        banned.add(Event.set(["travel": 0], at: Self.start.addingTimeInterval(2 * 86_400)), to: bannedSlot)
        let after = try cases(banned, bannedSlot, at: Self.date(2030, 1))
        #expect(after["BBB"]! < 1 && after["CCC"]! < 1)
    }

    @Test("Imported cases go to the country nearest the place given, or where it started")
    func imported() throws {
        let (scenario, slot) = try world(Self.three, ["travel": 0])
        scenario.add(Event(time: Self.date(2026, 3), kind: "imported", values: ["amount": 20, "latitude": 1, "longitude": 118]), to: slot)
        let end = try cases(scenario, slot, at: Self.date(2030, 1))
        #expect(end["CCC"]! > 800_000)
        #expect(end["BBB"] == 0)
    }

    @Test("Vaccines are shared by how many can still catch it, never more than there are")
    func vaccinate() throws {
        let (scenario, slot) = try world(Self.three, ["travel": 0, "firstCases": 1])
        scenario.add(Event(time: Self.date(2026, 1, 2), kind: "vaccinate", values: ["amount": 1_600_000]), to: slot)
        let date = Self.date(2026, 1, 3)
        #expect(abs(try scenario.value("vaccinated", of: slot, at: date) - 1_600_000) < 1e-6)
        let groups = try #require(try scenario.field("groups", of: slot, at: date))
        #expect(abs(groups["vaccinated"]! - 0.1) < 1e-9)
        #expect(abs(groups.values.reduce(0, +) - 1) < 1e-9)

        let (over, overSlot) = try world(Self.three, ["travel": 0])
        over.add(Event(time: Self.date(2026, 1, 2), kind: "vaccinate", values: ["amount": 1e12]), to: overSlot)
        #expect(try over.value("vaccinated", of: overSlot, at: date) <= 16_000_000)
        #expect(try over.value("susceptible", of: overSlot, at: date) >= 0)
    }

    @Test("Everyone is counted once in every country, and the totals are the countries' sums")
    func conserved() throws {
        let (scenario, slot) = try world()
        for month in [2, 5, 9, 12] {
            let date = Self.date(2026, month)
            let groups = try #require(try scenario.field("groups", of: slot, at: date))
            #expect(abs(groups.values.reduce(0, +) - 1) < 1e-9)
            let infected = try #require(try scenario.field("infected", of: slot, at: date))
            #expect(infected.values.allSatisfy { $0 >= 0 && $0 <= 1 })
            let total = try cases(scenario, slot, at: date).values.reduce(0, +)
            #expect(abs(total - (try scenario.value("cases", of: slot, at: date))) < 1e-6 * max(1, total))
        }
    }

    @Test("The world: links share each country's travel, rows that can't be used are left out, and distances are right")
    func links() throws {
        let messy = DataTable(keys: ["AAA", "BBB", "NUL", "BAD", "CCC"],
                              columns: ["population": [10, 5, 0, .nan, 1], "latitude": [0, 0, 0, 0, 0], "longitude": [0, 10, 5, 5, 120]])
        let world = try World(messy, links: 1)
        #expect(world.codes == ["AAA", "BBB", "CCC"])
        for i in 0..<world.count {
            let range = world.linkStart[i]..<world.linkStart[i + 1]
            #expect(range.count == 1)
            #expect(abs(range.map { world.linkWeight[$0] }.reduce(0, +) - 1) < 1e-12)
        }
        // The far one's people meet the bigger of the other two most.
        #expect(world.linkTarget[world.linkStart[2]] == 0)
        #expect(world.nearest(latitude: 1, longitude: 119) == 2)
        // London to Paris.
        #expect(abs(World.kilometres(51.507, -0.128, 48.857, 2.352) - 344) < 3)

        #expect(throws: ModuleError.self) { try World(DataTable(keys: ["A"], columns: ["population": [1]])) }
        #expect(throws: ModuleError.self) {
            try World(DataTable(keys: ["A"], columns: ["population": [0], "latitude": [0], "longitude": [0]]))
        }
        #expect(throws: ModuleError.self) { try WorldEpidemicModule().makeModel(name: "P", values: [:], data: .none) }
    }

    @Test("The numbers' names follow the shape, so the enum and the bases read the right ones")
    func layout() throws {
        let model = WorldEpidemic(world: try World(Self.three))
        let names = model.shape.names
        #expect(Array(names.prefix(WorldEpidemic.N.allCases.count)) == WorldEpidemic.N.allCases.map { String(describing: $0) })
        #expect(names[model.exposedBase] == "E.AAA")
        #expect(names[model.infectiousBase + 2] == "I.CCC")
        #expect(names[model.vaccinatedBase + 1] == "V.BBB")
        #expect(names.count == model.vaccinatedBase + 3)
    }
}
