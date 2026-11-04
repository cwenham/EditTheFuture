import Foundation

/// What a scenario from someone else holds back until the person allows it (docs/UI.md, 7): its
/// scripts, which run code, and its feeds, which tell their sources it was opened.
public struct TrustRequest: Equatable, Sendable {
    public let scripts: Int
    public let feeds: Int

    /// Why a held script slot is paused.
    public static let heldReason = "This scenario came from elsewhere, so its scripts wait until you allow them."

    /// "2 scripts and 1 data feed".
    public var waiting: String {
        func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(scripts, "script"), count(feeds, "data feed")].compactMap { $0 }.joined(separator: " and ")
    }

    public var text: String {
        "This scenario was downloaded or sent from elsewhere. Its \(waiting) wait until you allow them: "
            + (scripts > 0 ? "scripts run code on this Mac" : "")
            + (scripts > 0 && feeds > 0 ? ", and " : "")
            + (feeds > 0 ? "feeds tell the sites they fetch from that it was opened" : "") + "."
    }
}

extension ScenarioStore {
    /// How many script slots and feeds the scenario has.
    package var heldCounts: (scripts: Int, feeds: Int) {
        let scripts = configs.filter { if case .script = $0.kind { true } else { false } }.count
        let feeds = configs.flatMap(\.readings.sources).filter { if case .feed = $0 { true } else { false } }.count
        return (scripts, feeds)
    }

    /// Asks the person, in the panel, to allow the scenario's scripts and feeds. With none to
    /// hold, it lets the scenario run as it is and returns false.
    @discardableResult
    package func requestTrust() -> Bool {
        let counts = heldCounts
        guard counts.scripts + counts.feeds > 0 else {
            if holdsScripts { holdsScripts = false }
            return false
        }
        let request = TrustRequest(scripts: counts.scripts, feeds: counts.feeds)
        if trustRequest != request { trustRequest = request }
        return true
    }

    /// Lets the held scripts run and the feeds fetch, and tells the app so it remembers.
    public func allowHeldScenario() {
        if trustRequest != nil { trustRequest = nil }
        if holdsScripts {
            holdsScripts = false
            rebuildSlots()
        }
        onAllowHeld?()
    }

    /// Puts the question away; the scripts and feeds keep waiting, and the scenario menu can allow them later.
    public func dismissTrustRequest() {
        if trustRequest != nil { trustRequest = nil }
    }

    /// Whether the scenario's scripts or feeds are still held, for the scenario menu.
    public var isHeld: Bool { holdsScripts || trustRequest != nil }
}
