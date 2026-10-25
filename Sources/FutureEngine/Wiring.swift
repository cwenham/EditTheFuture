import Foundation

/// Why a slot can't run. Found before the scenario is built, so the slots that can run still do,
/// and the app can say what's wrong (docs/UI.md, 5.7).
public enum SlotProblem: Hashable, Sendable, CustomStringConvertible {
    /// It reads `Climate.temp`, but there's no slot called Climate.
    case missingSlot(String, reading: String)
    /// It reads `Climate.temp`, but Climate has no readable value called temp.
    case missingValue(slot: String, variable: String)
    /// It listens for `Climate.Heatwave`, but Climate never emits it.
    case missingEvents(slot: String, kind: String)
    /// It reads itself by its own slot name.
    case readsItself(String)
    /// It's in a loop of slots that read each other within the same step.
    case loop([String])
    /// It reads from a slot that can't run.
    case waitsFor(String)
    /// Its model couldn't be built, for example a formula with a mistake in it.
    case model(String)

    public var description: String {
        switch self {
        case .missingSlot(let slot, let reading):
            return "Reads \(reading), but there's no slot called \(slot)."
        case .missingValue(let slot, let variable):
            return "Reads \(slot).\(variable), but \(slot) has no value called \(variable)."
        case .missingEvents(let slot, let kind):
            return "Listens for \(slot).\(kind), but \(slot) never sends it."
        case .readsItself(let reading):
            return "Reads its own value as \(reading). Use the variable's name instead, with [t-1] for the previous step."
        case .loop(let names):
            return "In a loop of slots that read each other in the same step: \(names.joined(separator: " → ")). "
                + "Read one of them from the previous step, with [t-1]."
        case .waitsFor(let slot):
            return "Reads from \(slot), which is paused."
        case .model(let message):
            return message
        }
    }
}

/// Checks how slots read each other before a scenario is built.
public enum Wiring {
    public struct Report: Sendable, Equatable {
        /// Slots that can't run, by position in the list that was checked.
        public let problems: [Int: SlotProblem]
        /// Connections and event routes between the slots that can run.
        public let linkCount: Int
    }

    /// - Parameter slots: each slot's name and model descriptor. A nil descriptor is a slot whose
    ///   model couldn't be built; it can't run, and neither can anything that reads it.
    public static func check(_ slots: [(name: String, descriptor: ModelDescriptor?)]) -> Report {
        var index: [String: Int] = [:]
        for (position, slot) in slots.enumerated() where index[slot.name] == nil { index[slot.name] = position }
        var problems: [Int: SlotProblem] = [:]
        var broken = Set(slots.indices.filter { slots[$0].descriptor == nil })

        // What each slot reads: (producer, same step?).
        var reads = [[(from: Int, sameStep: Bool)]](repeating: [], count: slots.count)
        for (position, slot) in slots.enumerated() {
            guard let descriptor = slot.descriptor else { continue }
            func problem(_ found: SlotProblem) {
                if problems[position] == nil { problems[position] = found }
            }
            for input in descriptor.inputs {
                guard let source = input.source else { continue }
                let reading = "\(source.slot).\(source.variable)"
                guard let from = index[source.slot] else { problem(.missingSlot(source.slot, reading: reading)); continue }
                guard from != position else { problem(.readsItself(reading)); continue }
                if let producer = slots[from].descriptor, !producer.readable.contains(where: { $0.name == source.variable }) {
                    problem(.missingValue(slot: source.slot, variable: source.variable))
                    continue
                }
                reads[position].append((from, source.timing == .sameStep))
            }
            for subscription in descriptor.subscriptions {
                let reading = "\(subscription.slot).\(subscription.kind)"
                guard let from = index[subscription.slot] else { problem(.missingSlot(subscription.slot, reading: reading)); continue }
                guard from != position else { problem(.readsItself(reading)); continue }
                if let producer = slots[from].descriptor, !producer.emits.contains(subscription.kind) {
                    problem(.missingEvents(slot: subscription.slot, kind: subscription.kind))
                    continue
                }
                reads[position].append((from, subscription.timing == .sameStep))
            }
        }
        broken.formUnion(problems.keys)

        /// Pauses every slot that reads (at any distance) from one that can't run.
        func spread() {
            var changed = true
            while changed {
                changed = false
                for position in slots.indices where !broken.contains(position) {
                    if let from = reads[position].first(where: { broken.contains($0.from) })?.from {
                        problems[position] = .waitsFor(slots[from].name)
                        broken.insert(position)
                        changed = true
                    }
                }
            }
        }
        spread()

        // Loops of same-step reads among the rest.
        for cycle in sameStepCycles(reads: reads, excluding: broken) {
            let names = cycle.map { slots[$0].name } + [slots[cycle[0]].name]
            for position in cycle where !broken.contains(position) {
                problems[position] = .loop(names)
            }
            broken.formUnion(cycle)
        }
        spread()

        let linkCount = slots.indices.filter { !broken.contains($0) }.reduce(0) { $0 + reads[$1].count }
        return Report(problems: problems, linkCount: linkCount)
    }

    /// One cycle through each group of slots that read each other within the same step.
    private static func sameStepCycles(reads: [[(from: Int, sameStep: Bool)]], excluding broken: Set<Int>) -> [[Int]] {
        // Downstream edges: producer → consumer.
        var downstream = [[Int]](repeating: [], count: reads.count)
        for (consumer, list) in reads.enumerated() where !broken.contains(consumer) {
            for read in list where read.sameStep && !broken.contains(read.from) {
                downstream[read.from].append(consumer)
            }
        }
        var cycles: [[Int]] = []
        var inCycle = Set<Int>()
        // 0 = not visited, 1 = on the current path, 2 = finished.
        var marks = [UInt8](repeating: 0, count: reads.count)
        var path: [Int] = []
        func visit(_ node: Int) {
            marks[node] = 1
            path.append(node)
            for next in downstream[node] {
                if marks[next] == 1 {
                    let cycle = Array(path[path.lastIndex(of: next)!...])
                    if inCycle.isDisjoint(with: cycle) { cycles.append(cycle) }
                    inCycle.formUnion(cycle)
                } else if marks[next] == 0 {
                    visit(next)
                }
            }
            path.removeLast()
            marks[node] = 2
        }
        for node in reads.indices where marks[node] == 0 && !broken.contains(node) { visit(node) }
        return cycles
    }
}
