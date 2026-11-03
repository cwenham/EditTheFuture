import Foundation
import FutureEngine
import FutureSimulation

/// A computer worm that spreads by scanning random Internet addresses, as Code Red and Slammer did
/// (docs/DESIGN.md, 6.5). It's the two-factor model (Zou, Gong and Towsley, 2002): infected hosts
/// probe random IPv4 addresses; congestion slows their scanning as the network fills; infected
/// hosts are cleaned up; and still-vulnerable hosts are patched faster as more have been hit.
public struct WormModule: SimulationModule {
    public let id = "worm"
    public let version = 1
    public let info = ModuleInfo(name: "Internet worm", summary: "A worm spreading by scanning random Internet addresses",
                                 category: "growth", slotName: "Worm", shows: "infected", backdrop: "parts of groups",
                                 trigger: ModuleTrigger(kind: "infect", values: ["amount": 10], emptied: ["infected": 0]))

    public init() {}

    public func makeModel(name: String, values: [String: Double], data: ModuleData) throws -> any AuthoredModel {
        NumericModel(Worm(), source: reference.description, name: name, values: values)
    }
}

/// The model, a step a minute, worked out in one-second steps inside it. In each second, a
/// vulnerable host is hit by one of the infected hosts' scans with chance 1 − e^(−scans × infected ÷ 2³²),
/// which stays right however fast the worm scans. Each infected host scans at its rate times
/// (1 − infected ÷ vulnerable)^congestion.
struct Worm: NumericSimulation {
    enum N: Int, CaseIterable {
        case vulnerable, scanRate, congestion, cleanup, patching
        case infected, cleaned, patched
        case susceptible, everInfected, scans
        case peaked
    }

    /// Every IPv4 address.
    static let addresses = 4_294_967_296.0
    /// Below this many hosts there are none: the worm has died out, or nobody is left to infect.
    static let nobody = 1e-6

    let shape = SimulationShape(
        step: .minutes(1), timeUnit: .seconds(1),
        parameters: [
            .parameter("vulnerable", 360_000, range: 1...100_000_000, by: 1_000, label: "Vulnerable hosts",
                       about: "How many computers on the Internet run the software the worm attacks. Code Red found about 360,000."),
            .parameter("scanRate", 6, range: 0...100_000, by: 1, label: "Scans a second per infected host",
                       about: "How many random addresses each infected computer tries every second. Code Red tried about 6; Slammer, thousands."),
            .parameter("congestion", 0, range: 0...5, by: 0.1, label: "Slowing as the network fills",
                       about: "How much scanning slows as more hosts are infected and the network clogs. 0 is no slowing; 1 or more slows it sharply near the peak."),
            .parameter("cleanup", 0, range: 0...1, by: 0.01, label: "Infected hosts cleaned an hour", as: .percent,
                       about: "The share of infected computers their owners clean up each hour."),
            .parameter("patching", 0, range: 0...1, by: 0.01, label: "Hosts patched an hour once all were hit", as: .percent,
                       about: "The share of still-vulnerable computers patched each hour, once every one has been hit. Patching starts slowly and speeds up as more are infected and people hear of it."),
        ],
        state: [
            .value("infected", 10, label: "Infected", about: "Computers infected at the start, before any are cleaned up."),
            .value("cleaned", label: "Cleaned up", about: "Computers already cleaned up at the start. They can't be infected again."),
            .value("patched", label: "Patched", about: "Computers already patched at the start, so the worm can't infect them."),
        ],
        outputs: [
            .value("susceptible", label: "Still vulnerable"),
            .value("everInfected", label: "Ever infected"),
            .value("scans", label: "Scans a second, all hosts"),
        ],
        hidden: ["peaked"],
        handles: ["infect", "patch", "clean"],
        emits: ["Peak"],
        fields: [FieldDescriptor(name: "groups", label: "Vulnerable hosts", geometry: "groups",
                                 keys: ["susceptible", "infected", "cleaned", "patched"], quantity: .percent)],
        settles: true)

    func start(_ s: inout Numbers, _ t: StepTime) {
        // The first infected can't be more than there are vulnerable hosts.
        s[N.infected] = min(max(0, s[N.infected]), max(0, s[N.vulnerable]))
        settle(&s)
    }

    func step(_ s: inout Numbers, _ t: StepTime, events: [Event]) -> [GeneratedEvent] {
        let infectedBefore = s[N.infected]
        // Steps of a second, or longer ones for steps of more than an hour, up to 3,600 of them.
        let parts = min(Int(t.dt.rounded()), 3_600)
        if parts > 0 && !isSettled(s) {
            for _ in 0..<parts { second(&s, length: t.dt / Double(parts)) }
        }
        for event in events {
            guard let amount = event.values["amount"], amount.isFinite, amount > 0 else { continue }
            switch event.kind {
            case "infect":
                s[N.infected] += min(amount, s[N.susceptible])
            case "patch":
                s[N.patched] += min(amount, s[N.susceptible])
            case "clean":
                let cleaned = min(amount, s[N.infected])
                s[N.infected] -= cleaned
                s[N.cleaned] += cleaned
            default:
                break
            }
            settle(&s)
        }
        settle(&s)
        return s.turnedTrue(s[N.infected] < infectedBefore, flag: N.peaked) ? [GeneratedEvent(kind: "Peak")] : []
    }

    /// One second, or `length` seconds.
    private func second(_ s: inout Numbers, length: Double) {
        let vulnerable = s[N.vulnerable], infected = s[N.infected], susceptible = s[N.susceptible]
        guard vulnerable > 0 else { return }
        let rate = scanRate(s)
        let hit = susceptible * -expm1(-rate * length * infected / Self.addresses)
        let cleaned = infected * -expm1(-max(0, s[N.cleanup]) / 3_600 * length)
        let awareness = s[N.everInfected] / vulnerable
        let patched = (susceptible - hit) * -expm1(-max(0, s[N.patching]) / 3_600 * awareness * length)
        s[N.infected] = infected + hit - cleaned
        s[N.cleaned] += cleaned
        s[N.patched] += patched
        settle(&s)
    }

    /// Scans a second for each infected host, slowed as the network fills.
    private func scanRate(_ s: Numbers) -> Double {
        let vulnerable = s[N.vulnerable], congestion = max(0, s[N.congestion])
        let base = max(0, s[N.scanRate])
        guard congestion > 0, vulnerable > 0 else { return base }
        return base * pow(max(0, 1 - s[N.infected] / vulnerable), congestion)
    }

    /// Settled once nothing can change: no new infections (nobody infected, or nobody left to
    /// infect), no cleanup (nobody infected, or none happening), and no patching.
    func isSettled(_ s: Numbers) -> Bool {
        let infected = s[N.infected], susceptible = s[N.susceptible]
        let noSpread = infected == 0 || susceptible == 0 || s[N.scanRate] <= 0
        let noCleanup = infected == 0 || s[N.cleanup] <= 0
        let noPatching = susceptible == 0 || s[N.patching] <= 0 || s[N.everInfected] == 0
        return noSpread && noCleanup && noPatching
    }

    func field(_ name: String, of s: Numbers) -> [Double]? {
        guard name == "groups", s[N.vulnerable] > 0 else { return name == "groups" ? [0, 0, 0, 0] : nil }
        let counts: [Double] = [s[N.susceptible], s[N.infected], s[N.cleaned], s[N.patched]]
        return counts.map { $0 / s[N.vulnerable] }
    }

    /// The counts worked out from the groups, with tiny remainders made none so the model settles:
    /// fewer than a millionth of an infected host is none, and so is a millionth of a vulnerable one
    /// (it's counted as patched, so everyone is still counted once).
    private func settle(_ s: inout Numbers) {
        if s[N.infected] < Self.nobody {
            s[N.cleaned] += max(0, s[N.infected])
            s[N.infected] = 0
        }
        var susceptible = s[N.vulnerable] - s[N.infected] - s[N.cleaned] - s[N.patched]
        if susceptible < Self.nobody {
            s[N.patched] += max(0, susceptible)
            susceptible = 0
        }
        s[N.susceptible] = susceptible
        s[N.everInfected] = s[N.infected] + s[N.cleaned]
        s[N.scans] = s[N.infected] * scanRate(s)
    }
}
