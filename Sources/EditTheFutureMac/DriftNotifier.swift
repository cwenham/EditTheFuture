#if os(macOS)
import AppKit
import UserNotifications
import FutureUI

/// Sends a notification when a slot's readings start drifting while the panel isn't showing, and
/// opens Refit when it's clicked (docs/UI.md, 5.6).
@MainActor
final class DriftNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the scenario's folder and the slot's name when a notification is clicked.
    var onOpen: ((_ scenario: String, _ slot: String) -> Void)?
    private var center: UNUserNotificationCenter? {
        // The notification center needs an app bundle; `swift run` has none.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Drifts already notified, kept across launches so reopening a scenario doesn't repeat them.
    static let notifiedKey = "drift.notified"
    static let rememberedLimit = 200

    override init() {
        super.init()
        center?.delegate = self
    }

    /// Notifies of a drift once, asking for permission the first time.
    func notify(_ alert: DriftAlert, scenario: String, folder: String) {
        guard let center else { return }
        let key = [folder, alert.title, alert.outcome.lastReading.description].joined(separator: "|")
        var notified = UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? []
        guard !notified.contains(key) else { return }
        notified.append(key)
        UserDefaults.standard.set(Array(notified.suffix(Self.rememberedLimit)), forKey: Self.notifiedKey)

        let content = UNMutableNotificationContent()
        content.title = "\(alert.title) is drifting"
        content.subtitle = scenario
        content.body = alert.detail + " Click to refit it to the last year of readings."
        content.threadIdentifier = folder
        content.userInfo = ["scenario": folder, "slot": alert.title]
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let scenario = info["scenario"] as? String, let slot = info["slot"] as? String else { return }
        await MainActor.run { onOpen?(scenario, slot) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
#endif
