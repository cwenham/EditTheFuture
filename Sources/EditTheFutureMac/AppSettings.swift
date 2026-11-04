#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import FutureEngine
import FutureFiles
import FutureKit
import FutureUI

/// The app's own settings, beside the views' (docs/UI.md, 7): how dates are written, what new
/// scenarios start with, drift notifications and how often live rates are checked. Each is
/// remembered in the app's defaults.
@MainActor
@Observable
final class AppSettings {
    private var monthFirstDates: Bool
    private var newScenarios: NewScenarioDefaults
    private var notifiesDrift: Bool
    private var liveRates: TimeInterval
    @ObservationIgnored private let defaults: UserDefaults

    static let monthFirstKey = "EditTheFuture.settings.monthFirstDates"
    static let newScenarioKey = "EditTheFuture.settings.newScenario"
    static let driftKey = "EditTheFuture.settings.driftNotifications"
    static let liveRatesKey = "EditTheFuture.settings.liveRateInterval"

    /// How often live rates can be checked, with what each costs on Open Exchange Rates' plans.
    static let liveRateChoices: [(interval: TimeInterval, title: String)] = [
        (600, "Every 10 minutes"), (1_800, "Every 30 minutes"), (3_600, "Every hour"),
        (6 * 3_600, "Every 6 hours"), (86_400, "Once a day"),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        monthFirstDates = defaults.bool(forKey: Self.monthFirstKey)
        newScenarios = NewScenarioDefaults(stored: defaults.dictionary(forKey: Self.newScenarioKey) as? [String: String] ?? [:])
        notifiesDrift = defaults.object(forKey: Self.driftKey) as? Bool ?? true
        let interval = defaults.double(forKey: Self.liveRatesKey)
        liveRates = Self.liveRateChoices.contains { $0.interval == interval } ? interval : 600
        DateText.monthFirst = monthFirstDates
        RateCenter.liveRefresh = liveRates
    }

    /// "Mar 15, 2031" rather than "15 Mar 2031".
    var monthFirst: Bool {
        get { monthFirstDates }
        set {
            guard newValue != monthFirstDates else { return }
            monthFirstDates = newValue
            DateText.monthFirst = newValue
            defaults.set(newValue, forKey: Self.monthFirstKey)
        }
    }

    var newScenario: NewScenarioDefaults {
        get { newScenarios }
        set {
            guard newValue != newScenarios else { return }
            newScenarios = newValue
            defaults.set(newValue.stored, forKey: Self.newScenarioKey)
        }
    }

    /// Notify when a slot's readings start drifting while the panel is hidden (docs/UI.md, 5.6).
    var driftNotifications: Bool {
        get { notifiesDrift }
        set {
            guard newValue != notifiesDrift else { return }
            notifiesDrift = newValue
            defaults.set(newValue, forKey: Self.driftKey)
        }
    }

    /// How often live exchange rates are fetched.
    var liveRateInterval: TimeInterval {
        get { liveRates }
        set {
            guard newValue != liveRates else { return }
            liveRates = newValue
            RateCenter.liveRefresh = newValue
            defaults.set(newValue, forKey: Self.liveRatesKey)
        }
    }
}

/// Starting the app when you log in, through the Mac's Login Items.
@MainActor
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var problem: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if problem != nil { problem = nil }
        } catch {
            problem = "The Mac wouldn’t change it: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        let now = SMAppService.mainApp.status
        if now != status { status = now }
    }
}

// MARK: Pages

struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    let login: LoginItem
    /// Asks the open scenario to draw its dates again.
    let redrawDates: () -> Void

    var body: some View {
        SettingsSection(title: "Starting") {
            SettingRow(label: "") {
                Toggle("Open Edit The Future when you log in", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                if login.status == .requiresApproval {
                    HStack {
                        Text("Waiting for you to allow it in Login Items.").font(.callout).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let problem = login.problem {
                    Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("It starts in the menu bar, with the panel hidden until you summon it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { login.refresh() }

        SettingsSection(title: "Dates") {
            SettingRow(label: "Write dates:") {
                Picker("Write dates", selection: $settings.monthFirst) {
                    Text("15 Mar 2031").tag(false)
                    Text("Mar 15, 2031").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: settings.monthFirst) { redrawDates() }
                Text("On the graph, in the readouts and in the panel’s messages. Date fields follow the Mac’s region settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }

        SettingsSection(title: "New scenarios") {
            SettingRow(label: "Currency:") {
                Picker("Currency", selection: Binding(get: { settings.newScenario.currency?.code ?? "" },
                                                      set: { settings.newScenario.currency = $0.isEmpty ? nil : Currency(code: $0) })) {
                    Text("The open scenario’s").tag("")
                    Divider()
                    ForEach(ScenarioStore.currencyChoices(including: settings.newScenario.currency.map { [$0] } ?? []), id: \.code) {
                        Text($0.menuTitle).tag($0.code)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            SettingRow(label: "Numbers:") {
                Picker("Numbers", selection: Binding(get: { Self.numbersTag(settings.newScenario.numbers) },
                                                     set: { settings.newScenario.numbers = Self.numbers(fromTag: $0) })) {
                    Text("The open scenario’s").tag("")
                    Divider()
                    Text("Each currency’s own").tag("own")
                    ForEach(NumberStyle.allCases, id: \.self) { Text($0.example).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            SettingRow(label: "Exchange rates:") {
                Picker("Exchange rates", selection: Binding(get: { settings.newScenario.rates?.rawValue ?? "" },
                                                            set: { settings.newScenario.rates = ExchangeRateSource(rawValue: $0) })) {
                    Text("The open scenario’s").tag("")
                    Divider()
                    Text("European Central Bank, daily (free)").tag(ExchangeRateSource.ecb.rawValue)
                    Text("Live, from Open Exchange Rates").tag(ExchangeRateSource.openexchangerates.rawValue)
                    Text("Don’t convert").tag(ExchangeRateSource.none.rawValue)
                }
                .labelsHidden()
                .frame(width: 280)
                Text("What New Scenario… in the panel’s scenario menu starts with. You can still change them in the form.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    static func numbersTag(_ numbers: NewScenarioDefaults.Numbers?) -> String {
        switch numbers {
        case nil: ""
        case .currencysOwn?: "own"
        case .style(let style)?: style.rawValue
        }
    }

    static func numbers(fromTag tag: String) -> NewScenarioDefaults.Numbers? {
        if tag == "own" { return .currencysOwn }
        return NumberStyle(rawValue: tag).map { .style($0) }
    }
}

struct NotificationSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var allowed: UNAuthorizationStatus?

    var body: some View {
        SettingsSection(title: "Drifting readings") {
            SettingRow(label: "") {
                Toggle("Notify me when readings drift away from a model while the panel is hidden", isOn: $settings.driftNotifications)
                Text("The panel always marks a drift beside the now line, whether or not you’re notified.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.driftNotifications, allowed == .denied {
                    HStack {
                        Text("Notifications for Edit The Future are off in the Mac’s settings.")
                            .font(.callout).foregroundStyle(.orange)
                        Button("Open Notifications") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard Bundle.main.bundleIdentifier != nil else { return }
            allowed = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }
}

struct FeedSettingsPane: View {
    @Bindable var settings: AppSettings
    /// Fetches live rates on the new schedule.
    let rescheduleRates: () -> Void

    var body: some View {
        SettingsSection(title: "Live exchange rates") {
            SettingRow(label: "Check:") {
                Picker("Check live rates", selection: $settings.liveRateInterval) {
                    ForEach(AppSettings.liveRateChoices, id: \.interval) { Text($0.title).tag($0.interval) }
                }
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: settings.liveRateInterval) { rescheduleRates() }
                Text("For scenarios that use live rates from Open Exchange Rates. Its free plan allows 1,000 requests a month, which checking every hour stays within; every 10 minutes needs a paid plan.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        SettingsSection(title: "Data feeds") {
            Text("Each feed has its own Check for new setting, in the Slot tab’s Readings section. Refresh Data Feeds in the menu bar item fetches them all now.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

struct PrivacySettingsPane: View {
    @Bindable var trust: ScenarioTrust

    var body: some View {
        SettingsSection(title: "Scenarios from elsewhere") {
            SettingRow(label: "") {
                Toggle("Ask before running their scripts and fetching their data feeds", isOn: $trust.asksFirst)
                Text("A scenario downloaded, or sent by Mail, Messages or AirDrop, opens with its scripts and feeds waiting until you allow them. Scripts run code on this Mac, and a feed tells the site it fetches from that the scenario was opened.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)
            }
        }
        SettingsSection(title: "Allowed") {
            if trust.allowed.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(trust.allowed, id: \.self) { path in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(width: 360, alignment: .leading)
                            .help(path)
                            Button("Forget") { trust.forget(path) }
                                .help("Ask again the next time it opens")
                        }
                    }
                }
            }
        }
    }
}
#endif
