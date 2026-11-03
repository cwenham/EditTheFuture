import Foundation
import FutureEngine
import FutureSimulation

/// An infection spreading through one population (docs/DESIGN.md, 6.5): an SEIR model. People
/// catch it, incubate, are infectious for a while, then recover. Whoever isn't in one of those
/// groups, or vaccinated, can still catch it.
public struct EpidemicModule: SimulationModule {
    public let id = "epidemic"
    public let version = 1
    public let info = ModuleInfo(name: "Epidemic", summary: "An infection spreading through a population, from R₀ and incubation (SEIR)",
                                 category: "health", slotName: "Outbreak", shows: "infectious",
                                 trigger: ModuleTrigger(kind: "imported", values: ["amount": 10], emptied: ["exposed": 0]))

    public init() {}

    public func makeModel(name: String, values: [String: Double], data: ModuleData) throws -> any AuthoredModel {
        NumericModel(Epidemic(), source: reference.description, name: name, values: values)
    }
}

/// The model, a step a day. Each day 1/days of the incubating and of the infectious move on, so each
/// stays as many days as set, on average. New cases are the people who can still catch it times
/// 1 − e^(−R₀ × infectious ÷ (illness × population)): each case infects R₀ people over its illness,
/// and nobody is counted twice. So an unchecked outbreak reaches the share the final-size equation
/// gives, z = 1 − e^(−R₀ z).
struct Epidemic: NumericSimulation {
    /// The numbers, in the shape's order.
    enum N: Int, CaseIterable {
        case r0, incubation, illness, population
        case exposed, infectious, recovered, vaccinated
        case caught, showing, recovering, susceptible, cases, rt
        case peaked, immune
    }

    let shape = SimulationShape(
        step: .daily,
        parameters: [
            .parameter("r0", 2.5, range: 0.1...20, by: 0.1, label: "R₀: people each case infects",
                       about: "The basic reproduction number: how many people each case infects while nobody is immune. Above 1 it spreads; below 1 it dies out."),
            .parameter("incubation", 5, range: 0.5...60, by: 0.5, label: "Incubation in days",
                       about: "How long, on average, between catching it and being able to pass it on."),
            .parameter("illness", 7, range: 0.5...60, by: 0.5, label: "Days a case is infectious",
                       about: "How long, on average, each case can pass it on before recovering."),
            .parameter("population", 1_000_000, range: 100...10_000_000_000, by: 100, label: "Population",
                       about: "How many people there are, all able to catch it at first."),
        ],
        state: [
            .value("exposed", 10, label: "Incubating", about: "People who have caught it at the start, but can't pass it on yet."),
            .value("infectious", label: "Infectious", about: "People who can pass it on at the start."),
            .value("recovered", label: "Recovered", about: "People already immune from having had it at the start."),
            .value("vaccinated", label: "Vaccinated", about: "People already immune from a vaccine at the start."),
        ],
        outputs: [
            .value("caught", label: "New cases"),
            .value("showing", label: "Becoming infectious"),
            .value("recovering", label: "Recovering"),
            .value("susceptible", label: "Can still catch it"),
            .value("cases", label: "Ever infected"),
            .value("rt", label: "Effective R"),
        ],
        hidden: ["peaked", "immune"],
        handles: ["imported", "vaccinate"],
        emits: ["Peak", "HerdImmunity"],
        fields: [FieldDescriptor(name: "groups", label: "Where everyone is", geometry: "groups", keys: Epidemic.groups,
                                 quantity: .percent)])

    /// The groups everyone is in, in order through the outbreak.
    static let groups = ["susceptible", "exposed", "infectious", "recovered", "vaccinated"]

    func start(_ s: inout Numbers, _ t: StepTime) {
        settle(&s)
    }

    func step(_ s: inout Numbers, _ t: StepTime, events: [Event]) -> [GeneratedEvent] {
        let population = s[N.population], exposed = s[N.exposed], infectious = s[N.infectious]
        let canCatch = max(0, population - exposed - infectious - s[N.recovered] - s[N.vaccinated])
        let leavingIllness = min(1, t.dt / s[N.illness])
        let force = population > 0 ? s[N.r0] * leavingIllness * infectious / population : 0
        s[N.caught] = canCatch * -expm1(-force)
        s[N.showing] = exposed * min(1, t.dt / s[N.incubation])
        s[N.recovering] = infectious * leavingIllness
        s[N.exposed] = exposed + s[N.caught] - s[N.showing]
        s[N.infectious] = infectious + s[N.showing] - s[N.recovering]
        s[N.recovered] += s[N.recovering]
        settle(&s)

        for event in events {
            guard let amount = event.values["amount"], amount.isFinite, amount > 0 else { continue }
            switch event.kind {
            case "imported": s[N.infectious] += amount
            case "vaccinate": s[N.vaccinated] += min(amount, s[N.susceptible])
            default: break
            }
            settle(&s)
        }

        var emitted: [GeneratedEvent] = []
        if s.turnedTrue(s[N.infectious] < infectious, flag: N.peaked) { emitted.append(GeneratedEvent(kind: "Peak")) }
        if s.turnedTrue(s[N.r0] > 1 && s[N.rt] < 1, flag: N.immune) { emitted.append(GeneratedEvent(kind: "HerdImmunity")) }
        return emitted
    }

    /// The share of the population in each group, which adds up to 1.
    func field(_ name: String, of s: Numbers) -> [Double]? {
        guard name == "groups" else { return nil }
        let population = s[N.population]
        let counts = [s[N.susceptible], s[N.exposed], s[N.infectious], s[N.recovered], s[N.vaccinated]]
        return counts.map { population > 0 ? $0 / population : 0 }
    }

    /// The values worked out from the groups: who can still catch it, everyone ever infected, and R now.
    private func settle(_ s: inout Numbers) {
        let population = s[N.population]
        s[N.susceptible] = max(0, population - s[N.exposed] - s[N.infectious] - s[N.recovered] - s[N.vaccinated])
        s[N.cases] = s[N.exposed] + s[N.infectious] + s[N.recovered]
        s[N.rt] = population > 0 ? s[N.r0] * s[N.susceptible] / population : 0
    }
}
