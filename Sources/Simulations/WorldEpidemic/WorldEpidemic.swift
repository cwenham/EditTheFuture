import Foundation
import FutureEngine
import FutureSimulation

/// An infection spreading between the world's countries by travel (docs/DESIGN.md, 6.5): an SEIR
/// model in each country, as Epidemic's, joined by the share of people's contacts that are with
/// people from other countries. Which countries meet most comes from a gravity model: a country's
/// people meet another's in proportion to its population over the distance between them to the 1.5.
public struct WorldEpidemicModule: SimulationModule {
    public let id = "world-epidemic"
    public let version = 1
    public let info = ModuleInfo(name: "World epidemic", summary: "An infection spreading between countries by travel (SEIR)",
                                 category: "health", slotName: "Pandemic", shows: "infectious", backdrop: "world-map of infectious",
                                 trigger: ModuleTrigger(kind: "imported", values: ["amount": 10], emptied: ["firstCases": 0]))

    /// Each country's ISO 3166 alpha-3 code as its key, with columns `population`, `latitude` and
    /// `longitude` (degrees, where its label goes).
    public static let countries = DataNeed("countries", summary: "Countries' codes, populations and positions")

    public var needs: [DataNeed] { [Self.countries] }

    public init() {}

    public func makeModel(name: String, values: [String: Double], data: ModuleData) throws -> any AuthoredModel {
        guard let table = data[Self.countries] else { throw ModuleError("World epidemic needs the countries' data.") }
        return NumericModel(WorldEpidemic(world: try World(table)), source: reference.description, name: name, values: values)
    }
}

/// The countries and who meets whom.
struct World: Sendable {
    let codes: [String]
    let population: [Double]
    let latitude: [Double]
    let longitude: [Double]
    /// For country i, the countries its people meet most are `linkTarget[linkStart[i]..<linkStart[i + 1]]`,
    /// with shares of their contacts abroad in `linkWeight`, adding up to 1.
    let linkStart: [Int]
    let linkTarget: [Int]
    let linkWeight: [Double]

    var count: Int { codes.count }

    /// - Parameters:
    ///   - links: how many countries each one's travel goes to.
    ///   - decay: how fast travel falls with distance.
    init(_ table: DataTable, links: Int = 20, decay: Double = 1.5) throws {
        guard let people = table.column("population"), let lat = table.column("latitude"), let lon = table.column("longitude") else {
            throw ModuleError("The countries' data needs population, latitude and longitude.")
        }
        // Countries with nobody in them, or numbers that can't be used, are left out.
        let kept = table.keys.indices.filter {
            people[$0].isFinite && people[$0] > 0 && lat[$0].isFinite && lon[$0].isFinite && abs(lat[$0]) <= 90
        }
        guard !kept.isEmpty else { throw ModuleError("The countries' data has no countries with people in them.") }
        codes = kept.map { table.keys[$0] }
        population = kept.map { people[$0] }
        latitude = kept.map { lat[$0] }
        longitude = kept.map { lon[$0] }

        let n = kept.count
        var start = [0], target: [Int] = [], weight: [Double] = []
        for i in 0..<n {
            var candidates: [(index: Int, weight: Double)] = []
            for j in 0..<n where j != i {
                // Nearer than 500 km counts as 500 km, so tiny neighbours don't take all the travel.
                let distance = max(500, Self.kilometres(latitude[i], longitude[i], latitude[j], longitude[j]))
                candidates.append((j, population[j] / pow(distance, decay)))
            }
            let strongest = candidates.sorted { $0.weight > $1.weight }.prefix(links)
            let total = strongest.reduce(0) { $0 + $1.weight }
            for link in strongest where total > 0 {
                target.append(link.index)
                weight.append(link.weight / total)
            }
            start.append(target.count)
        }
        linkStart = start
        linkTarget = target
        linkWeight = weight
    }

    /// The great-circle distance between two places, in kilometres.
    static func kilometres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// The country whose label point is nearest a place.
    func nearest(latitude lat: Double, longitude lon: Double) -> Int {
        guard lat.isFinite, lon.isFinite else { return 0 }
        var best = 0, bestDistance = Double.infinity
        for i in 0..<count {
            let distance = Self.kilometres(lat, lon, latitude[i], longitude[i])
            if distance < bestDistance { (best, bestDistance) = (i, distance) }
        }
        return best
    }
}

/// The model, a step a day. In each country, as in Epidemic, 1/days of the incubating and infectious
/// move on each day, and new cases are the people who can still catch it times 1 − e^(−force). The
/// force is R₀ × (1/illness) × the infectious share among the people they meet: (1 − travel) of their
/// contacts at home, and travel shared among the countries they meet most. A country spreads it at
/// home only once a whole person there has caught it.
struct WorldEpidemic: NumericSimulation {
    /// The numbers before the countries', in the shape's order.
    enum N: Int, CaseIterable {
        case r0, incubation, illness, travel, originLatitude, originLongitude, firstCases
        case infectious, exposed, caught, cases, susceptible, recovered, vaccinated, reached
        case peaked
    }

    let world: World
    let shape: SimulationShape
    /// Where each country's incubating, infectious, recovered and vaccinated are.
    let exposedBase: Int, infectiousBase: Int, recoveredBase: Int, vaccinatedBase: Int

    init(world: World) {
        self.world = world
        let n = world.count
        exposedBase = N.allCases.count
        infectiousBase = exposedBase + n
        recoveredBase = infectiousBase + n
        vaccinatedBase = recoveredBase + n
        let hidden = ["peaked"] + ["E", "I", "R", "V"].flatMap { group in world.codes.map { "\(group).\($0)" } }
        shape = SimulationShape(
            step: .daily,
            parameters: [
                .parameter("r0", 2.5, range: 0.1...20, by: 0.1, label: "R₀: people each case infects"),
                .parameter("incubation", 5, range: 0.5...60, by: 0.5, label: "Incubation in days"),
                .parameter("illness", 7, range: 0.5...60, by: 0.5, label: "Days a case is infectious"),
                .parameter("travel", 0.001, range: 0...0.05, by: 0.0001, label: "Contacts abroad", as: .percent),
                .parameter("originLatitude", 51.5, range: -90...90, by: 0.1, label: "Where it starts: latitude"),
                .parameter("originLongitude", -0.1, range: -180...180, by: 0.1, label: "Where it starts: longitude"),
                .parameter("firstCases", 10, range: 0...1_000_000, by: 1, label: "First cases"),
            ],
            state: [],
            outputs: [
                .value("infectious", label: "Infectious"),
                .value("exposed", label: "Incubating"),
                .value("caught", label: "New cases"),
                .value("cases", label: "Ever infected"),
                .value("susceptible", label: "Can still catch it"),
                .value("recovered", label: "Recovered"),
                .value("vaccinated", label: "Vaccinated"),
                .value("reached", label: "Countries reached"),
            ],
            hidden: hidden,
            handles: ["imported", "vaccinate"],
            emits: ["Peak"],
            fields: [
                // Shaded from one in a million to a tenth, so the first cases show and the tail doesn't glare.
                FieldDescriptor(name: "infectious", label: "Infectious now", geometry: "world/countries", keys: world.codes,
                                quantity: .percent, scale: .logarithmic(faintest: 1e-6, full: 0.1)),
                FieldDescriptor(name: "infected", label: "Ever infected", geometry: "world/countries", keys: world.codes,
                                quantity: .percent),
                FieldDescriptor(name: "groups", label: "Where everyone is", geometry: "groups",
                                keys: ["susceptible", "exposed", "infectious", "recovered", "vaccinated"], quantity: .percent),
            ])
    }

    func start(_ s: inout Numbers, _ t: StepTime) {
        let origin = world.nearest(latitude: s[N.originLatitude], longitude: s[N.originLongitude])
        let first = s[N.firstCases].isFinite ? max(0, s[N.firstCases]) : 0
        s[exposedBase + origin] = min(first, world.population[origin])
        settle(&s)
    }

    /// Below this many people, incubating or infectious counts are none. Numbers that small (they reach
    /// 10⁻³⁰⁸ as an outbreak dies away) are very slow to work with, and mean nothing.
    static let nobody = 1e-12

    func step(_ s: inout Numbers, _ t: StepTime, events: [Event]) -> [GeneratedEvent] {
        let n = world.count
        let leavingIllness = min(1, t.dt / s[N.illness]), leavingIncubation = min(1, t.dt / s[N.incubation])
        let travel = min(1, max(0, s[N.travel].isFinite ? s[N.travel] : 0))
        let r0 = s[N.r0]
        let infectiousBefore = s[N.infectious]

        // Once nobody anywhere is incubating or infectious, nothing changes until an event.
        if s[N.exposed] + infectiousBefore == 0 && events.isEmpty {
            s[N.caught] = 0
            _ = s.turnedTrue(false, flag: N.peaked)
            return []
        }

        // The infectious share in each country, before anyone moves on today.
        var share = [Double](repeating: 0, count: n)
        for i in 0..<n { share[i] = s[infectiousBase + i] / world.population[i] }

        var caught = 0.0
        for i in 0..<n {
            let links = world.linkStart[i]..<world.linkStart[i + 1]
            var abroad = 0.0
            for link in links { abroad += world.linkWeight[link] * share[world.linkTarget[link]] }
            let exposed = s[exposedBase + i], infectious = s[infectiousBase + i]
            // Until a whole person has caught it, it hasn't arrived: only cases from abroad count, not
            // a fraction of one spreading at home. Otherwise every country would grow its own outbreak
            // from a trace on the first day, and no travel ban could keep it out.
            let arrived = exposed + infectious + s[recoveredBase + i] >= 1
            let home = arrived ? share[i] : 0
            // With nowhere to go, contacts abroad are at home.
            let met = links.isEmpty ? home : (1 - travel) * home + travel * abroad
            let canCatch = max(0, world.population[i] - exposed - infectious - s[recoveredBase + i] - s[vaccinatedBase + i])
            let newCases = canCatch * -expm1(-r0 * leavingIllness * met)
            let showing = exposed * leavingIncubation
            let recovering = infectious * leavingIllness
            let stillExposed = exposed + newCases - showing, stillInfectious = infectious + showing - recovering
            s[exposedBase + i] = stillExposed < Self.nobody ? 0 : stillExposed
            s[infectiousBase + i] = stillInfectious < Self.nobody ? 0 : stillInfectious
            s[recoveredBase + i] += recovering
            caught += newCases
        }

        for event in events {
            guard let amount = event.values["amount"], amount.isFinite, amount > 0 else { continue }
            switch event.kind {
            case "imported":
                // Into the country nearest the event's place, or where it started.
                let country = world.nearest(latitude: event.values["latitude"] ?? s[N.originLatitude],
                                            longitude: event.values["longitude"] ?? s[N.originLongitude])
                s[infectiousBase + country] += min(amount, world.population[country])
            case "vaccinate":
                // Shared among countries by how many can still catch it.
                var canCatch = [Double](repeating: 0, count: n)
                for i in 0..<n { canCatch[i] = susceptible(s, i) }
                let total = canCatch.reduce(0, +)
                guard total > 0 else { continue }
                let given = min(amount, total)
                for i in 0..<n { s[vaccinatedBase + i] += given * canCatch[i] / total }
            default:
                break
            }
        }
        settle(&s)
        s[N.caught] = caught

        return s.turnedTrue(s[N.infectious] < infectiousBefore, flag: N.peaked) ? [GeneratedEvent(kind: "Peak")] : []
    }

    func field(_ name: String, of s: Numbers) -> [Double]? {
        let n = world.count
        switch name {
        case "infectious":
            return (0..<n).map { (i: Int) -> Double in s[infectiousBase + i] / world.population[i] }
        case "infected":
            return (0..<n).map { (i: Int) -> Double in
                let caught: Double = s[exposedBase + i] + s[infectiousBase + i] + s[recoveredBase + i]
                return caught / world.population[i]
            }
        case "groups":
            let total = world.population.reduce(0, +)
            let counts: [Double] = [s[N.susceptible], s[N.exposed], s[N.infectious], s[N.recovered], s[N.vaccinated]]
            return counts.map { $0 / total }
        default:
            return nil
        }
    }

    private func susceptible(_ s: Numbers, _ i: Int) -> Double {
        max(0, world.population[i] - s[exposedBase + i] - s[infectiousBase + i] - s[recoveredBase + i] - s[vaccinatedBase + i])
    }

    /// The world's totals, from the countries'.
    private func settle(_ s: inout Numbers) {
        var exposed = 0.0, infectious = 0.0, recovered = 0.0, vaccinated = 0.0, susceptible = 0.0, reached = 0.0
        for i in 0..<world.count {
            let e = s[exposedBase + i], ill = s[infectiousBase + i], r = s[recoveredBase + i]
            exposed += e
            infectious += ill
            recovered += r
            vaccinated += s[vaccinatedBase + i]
            susceptible += self.susceptible(s, i)
            if e + ill + r >= 1 { reached += 1 }
        }
        s[N.exposed] = exposed
        s[N.infectious] = infectious
        s[N.recovered] = recovered
        s[N.vaccinated] = vaccinated
        s[N.susceptible] = susceptible
        s[N.cases] = exposed + infectious + recovered
        s[N.reached] = reached
    }
}
