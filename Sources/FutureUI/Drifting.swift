import Foundation
import FutureEngine

/// A slot whose latest readings left the range its model projected for them (docs/UI.md, 5.6).
public struct DriftAlert: Equatable, Sendable {
    public let slot: UUID
    /// The slot's name, as people see it.
    public let title: String
    /// For the pill: "12% above the projection".
    public let text: String
    /// "Readings since Dec 2025 are running 12% above what the model projected for them."
    public let detail: String
    public let outcome: DriftOutcome

    /// Identifies this drift for notifications, so one is sent once, until newer readings come.
    var notificationKey: String { slot.uuidString + "|" + outcome.lastReading.description }
}

/// Drift alerts in the panel (docs/UI.md, 5.6; docs/DESIGN.md, 8.2): each slot with readings of
/// the value its graph shows is checked after its readings, model or values change, off the main
/// thread and off the engine's, one slot at a time. Nothing is saved: the check runs again on opening.
extension ScenarioStore {
    /// Checks slots for drift shortly after something they depend on changes. A newer request
    /// replaces one that hasn't finished.
    func scheduleDriftCheck() {
        driftFlag?.cancel()
        driftTask?.cancel()
        let flag = CancelFlag()
        driftFlag = flag
        driftSequence += 1
        let sequence = driftSequence
        let delay = driftDelay
        driftTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            await self.checkDrift(flag: flag, sequence: sequence)
        }
    }

    /// Waits for the drift check that's waiting or running, if there is one.
    public func waitForDriftCheck() async {
        while let task = driftTask {
            await task.value
            if driftTask == task { break }
        }
    }

    /// What a slot's check depends on: its model and values, its readings, its events, and, for a
    /// slot that reads others or converts money, everything else too.
    private func driftKey(slotAt index: Int) -> String {
        let config = configs[index]
        var hasher = Hasher()
        hasher.combine(config.events)
        hasher.combine(config.rules)
        var parts = [config.id.uuidString, config.modelKey, config.variable, config.readings.set.digest,
                     start.description, String(hasher.finalize())]
        if slots[index].reads != nil || !slots[index].conversions.isEmpty { parts.append(String(revision)) }
        return parts.joined(separator: "|")
    }

    private func checkDrift(flag: CancelFlag, sequence: Int) async {
        var wanted: [(id: UUID, key: String, variable: String)] = []
        for (index, config) in configs.enumerated() where isSlot(index) && !slots[index].isPaused {
            guard config.readings.set.readings.contains(where: { $0.variable == config.variable }) else { continue }
            wanted.append((config.id, driftKey(slotAt: index), config.variable))
        }
        let ids = Set(wanted.map(\.id))
        if driftChecked.keys.contains(where: { !ids.contains($0) }) {
            driftChecked = driftChecked.filter { ids.contains($0.key) }
            publishDrifts()
        }
        for item in wanted where driftChecked[item.id]?.key != item.key {
            guard let index = slotIndex(id: item.id) else { continue }
            let copy = await copyForFitting(slotAt: index)
            guard !flag.isCancelled, sequence == driftSequence else { return }
            var outcome: DriftOutcome?
            if case .copy(let copy) = copy {
                let variable = item.variable
                outcome = await Task.detached(priority: .utility) {
                    try? copy.drift(variable, isCancelled: { flag.isCancelled })
                }.value ?? nil
            }
            guard !flag.isCancelled, sequence == driftSequence else { return }
            driftChecked[item.id] = (item.key, outcome)
            publishDrifts()
        }
        if sequence == driftSequence { driftTask = nil }
    }

    /// Turns the checks into alerts, and passes on each new one, once, for a notification.
    private func publishDrifts() {
        var alerts: [UUID: DriftAlert] = [:]
        for (id, entry) in driftChecked {
            guard let outcome = entry.outcome, outcome.isDrifting, let index = slotIndex(id: id) else { continue }
            alerts[id] = alert(outcome, slotAt: index)
        }
        guard alerts != drifts else { return }
        drifts = alerts
        for alert in alerts.values.sorted(by: { $0.title < $1.title }) where driftNotified.insert(alert.notificationKey).inserted {
            onDrift?(alert)
        }
    }

    private func alert(_ outcome: DriftOutcome, slotAt index: Int) -> DriftAlert {
        let slot = slots[index]
        let size = abs(outcome.offset)
        let amount = outcome.isRatio ? slot.style.with(.percent).full(size) : slot.style.full(size)
        let side = outcome.offset >= 0 ? "above" : "below"
        let since = DateText.monthYear(outcome.cutoff)
        return DriftAlert(slot: slot.id, title: slot.title, text: "\(amount) \(side) the projection",
                          detail: "\(slot.title)'s readings since \(since) are running \(amount) \(side) what its model "
                            + "projected for them.",
                          outcome: outcome)
    }

    /// The drift alert for a slot, if its readings are drifting.
    public func drift(forSlot id: UUID) -> DriftAlert? {
        drifts[id]
    }

    /// Opens Refit for a drifting slot, on the last year of its readings (docs/UI.md, 5.6). The
    /// pill and the notification come here.
    public func openDriftRefit(slot id: UUID) {
        guard let index = slotIndex(id: id) else { return }
        focus(index: index)
        openRefit(slotAt: index, window: .year)
    }
}
