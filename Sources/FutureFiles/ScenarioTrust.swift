import Foundation
import Observation
import FutureDocument

/// Which scenarios from elsewhere may run their scripts and fetch their feeds (docs/UI.md, 7).
///
/// A scenario counts as from elsewhere when the Mac marks its folder or `scenario.md` as
/// downloaded (quarantined): from a browser, Mail, Messages or AirDrop. Scenarios made on this Mac
/// never carry the mark. Until the person allows one, its scripts wait unbuilt and its feeds
/// aren't fetched; once allowed, it's remembered by its folder.
@MainActor
@Observable
public final class ScenarioTrust {
    private var asking: Bool
    private var allowedPaths: [String]
    @ObservationIgnored private let defaults: UserDefaults

    static let askKey = "EditTheFuture.settings.askBeforeOutsideCode"
    static let allowedKey = "EditTheFuture.settings.allowedScenarios"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asking = defaults.object(forKey: Self.askKey) as? Bool ?? true
        allowedPaths = defaults.stringArray(forKey: Self.allowedKey) ?? []
    }

    /// Whether to ask before a scenario from elsewhere runs scripts or fetches feeds. On unless turned off.
    public var asksFirst: Bool {
        get { asking }
        set {
            guard newValue != asking else { return }
            asking = newValue
            defaults.set(newValue, forKey: Self.askKey)
        }
    }

    /// The folders of scenarios from elsewhere that were allowed, in the order they were.
    public var allowed: [String] { allowedPaths }

    /// Whether the scenario may run as it is, without asking.
    public func allows(_ package: ScenarioPackage) -> Bool {
        !asking || allowedPaths.contains(package.url.standardizedFileURL.path) || !Self.cameFromElsewhere(package)
    }

    /// Remembers that the scenario was allowed.
    public func allow(_ package: ScenarioPackage) {
        let path = package.url.standardizedFileURL.path
        guard !allowedPaths.contains(path) else { return }
        allowedPaths.append(path)
        save()
    }

    /// An allowed scenario keeps its place after its folder is renamed.
    public func moved(from old: ScenarioPackage, to new: ScenarioPackage) {
        let oldPath = old.url.standardizedFileURL.path
        guard let index = allowedPaths.firstIndex(of: oldPath) else { return }
        allowedPaths[index] = new.url.standardizedFileURL.path
        save()
    }

    /// Asks again the next time the scenario at `path` opens.
    public func forget(_ path: String) {
        guard allowedPaths.contains(path) else { return }
        allowedPaths.removeAll { $0 == path }
        save()
    }

    private func save() { defaults.set(allowedPaths, forKey: Self.allowedKey) }

    /// Whether the Mac marks the scenario's folder or its `scenario.md` as downloaded.
    nonisolated public static func cameFromElsewhere(_ package: ScenarioPackage) -> Bool {
        #if os(macOS)
        for url in [package.url, package.scenarioURL] {
            if let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]), values.quarantineProperties != nil {
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }
}
