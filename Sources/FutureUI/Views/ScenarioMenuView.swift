import SwiftUI
import FutureEngine
import FutureFeeds
#if os(macOS)
import AppKit
#endif

/// The scenario's name at the top left of the header. Clicking it opens the scenario menu
/// (docs/UI.md, 3); its form hangs from it in a popover.
struct ScenarioTitle: View {
    let store: ScenarioStore
    let actions: ScenarioMenuActions?
    @State private var hovering = false
    #if os(macOS)
    @State private var anchor = MenuAnchor()
    #endif

    /// Long names are cut short, so the slot chips keep their room.
    static let maximumWidth: CGFloat = 260

    var body: some View {
        if let actions {
            Button { showMenu(actions) } label: { label(menu: true) }
                .buttonStyle(.plain)
                .background(Color.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                #if os(macOS)
                .background(MenuAnchorView(anchor: anchor))
                #endif
                .help("Switch scenarios, make a new one, or change this one's name, start date, currency and seed")
                .accessibilityLabel("Scenario: \(store.name)")
                .accessibilityHint("Opens the scenario menu")
                .popover(isPresented: Binding(get: { store.scenarioForm != nil }, set: { if !$0 { store.closeScenarioForm() } }),
                         arrowEdge: .bottom) {
                    ScenarioFormView(store: store, actions: actions)
                }
        } else {
            label(menu: false).allowsHitTesting(false)
        }
    }

    private func label(menu: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .semibold))
            Text(store.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if menu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .frame(height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func showMenu(_ actions: ScenarioMenuActions) {
        #if os(macOS)
        guard let view = anchor.view else { return }
        let menu = ScenarioMenu.make(store: store, actions: actions)
        // Just under the title, lined up with its left edge.
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
        #endif
    }
}

#if os(macOS)
/// The scenario menu (docs/UI.md, 3): every scenario, ticked where it's the one open, then new,
/// duplicate and edit, then Show in Finder and Open Other…. Built afresh each time it opens, so
/// folders added in Finder show up.
@MainActor
enum ScenarioMenu {
    static func make(store: ScenarioStore, actions: ScenarioMenuActions) -> NSMenu {
        let menu = NSMenu(title: "Scenarios")
        menu.autoenablesItems = false
        let current = actions.current()
        let scenarios = actions.scenarios()
        for package in scenarios {
            let item = ActionMenuItem(package.name) { actions.open(package) }
            item.state = package == current ? .on : .off
            if package.url.deletingLastPathComponent().standardizedFileURL.path != actions.folder.standardizedFileURL.path {
                item.toolTip = package.url.deletingLastPathComponent().path
            }
            menu.addItem(item)
        }
        if !scenarios.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem("New Scenario…") { store.openScenarioForm(.new, actions: actions) })
        let duplicate = ActionMenuItem("Duplicate “\(store.name)”…") { store.openScenarioForm(.duplicate, actions: actions) }
        duplicate.isEnabled = current != nil
        menu.addItem(duplicate)
        menu.addItem(ActionMenuItem("Edit “\(store.name)”…") { store.openScenarioForm(.edit, actions: actions) })
        menu.addItem(.separator())
        let finder = ActionMenuItem("Show in Finder", handler: actions.showInFinder)
        finder.isEnabled = current != nil
        menu.addItem(finder)
        menu.addItem(ActionMenuItem("Open Other…", handler: actions.openOther))
        return menu
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) isn't used") }

    @objc private func fire() { handler() }
}

/// Holds the view a menu hangs from.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// A plain view behind a button, for placing a menu under it.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
#endif

/// The form for a scenario's name, start date, currency and seed, or for a new scenario or a copy.
struct ScenarioFormView: View {
    @Bindable var store: ScenarioStore
    let actions: ScenarioMenuActions?
    @FocusState private var nameFocused: Bool
    @State private var isSaving = false

    static let width: CGFloat = 340

    var body: some View {
        if let form = store.scenarioForm {
            VStack(alignment: .leading, spacing: 14) {
                Text(title(form)).font(.system(size: 15, weight: .semibold))

                field("Name") {
                    TextField("Name", text: binding(form, \.name))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(save)
                        .accessibilityLabel("Scenario name")
                }

                field("Starts") {
                    DatePicker("Starts", selection: binding(form, \.start), displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .environment(\.timeZone, DateText.calendar.timeZone)
                        .environment(\.calendar, DateText.calendar)
                        .accessibilityLabel("Start date")
                    hint(startHint(form))
                }

                field("Currency") {
                    Picker("Currency", selection: binding(form, \.currency)) {
                        ForEach(ScenarioStore.currencyChoices(including: [form.currency, store.currency]), id: \.code) {
                            Text($0.menuTitle).tag($0)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Currency")
                    hint(currencyHint(form))
                }

                field("Numbers") {
                    Picker("Numbers", selection: binding(form, \.numbers)) {
                        Text("Each currency's own: \(example(form.currency, nil))").tag(NumberStyle?.none)
                        Divider()
                        ForEach(NumberStyle.allCases, id: \.self) { style in
                            Text(example(form.currency, style)).tag(NumberStyle?.some(style))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("How numbers are written")
                    hint(form.numbers == nil ? "Each slot is written the way its currency usually is, such as 1.234,56 € or ¥1,235."
                         : "Every slot is written this way, whatever its currency.")
                }

                field("Exchange rates") {
                    Picker("Exchange rates", selection: binding(form, \.rates)) {
                        Text("European Central Bank, daily (free)").tag(ExchangeRateSource.ecb)
                        Text("Live, from Open Exchange Rates").tag(ExchangeRateSource.openexchangerates)
                        Text("Don't convert").tag(ExchangeRateSource.none)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Exchange rates")
                    .onChange(of: form.rates) { if form.rates.isLive { store.checkForAppID() } }
                    if form.rates.isLive {
                        HStack(spacing: 8) {
                            SecureField(form.hasAppID ? "Saved in your Keychain" : "App ID", text: binding(form, \.appID))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                                .accessibilityLabel("Open Exchange Rates App ID")
                            Button(form.isTestingRates ? "Testing…" : "Test") { Task { await store.testLiveRates() } }
                                .disabled(form.isTestingRates || (form.appID.isEmpty && !form.hasAppID))
                                .help("Fetch the latest rate with this App ID, without saving anything")
                        }
                        if let test = form.rateTest { hint(test) }
                        HStack(spacing: 4) {
                            hint(RateProviders.openExchangeRates.signIn.note ?? "")
                        }
                        if let signUp = RateProviders.openExchangeRates.signIn.signUp {
                            Link("Get an App ID", destination: signUp)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.proposal)
                        }
                    }
                    hint(ratesHint(form))
                }

                if form.mode == .edit {
                    field("Seed") {
                        HStack(spacing: 8) {
                            TextField("The engine's own", text: binding(form, \.seedText))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13).monospacedDigit())
                                .onSubmit(save)
                                .accessibilityLabel("Seed")
                            Button("New Seed") { store.scenarioForm?.seedText = ScenarioForm.text(seed: ScenarioForm.randomSeed()) }
                                .help("Pick a seed at random")
                        }
                        hint("Models with chance in them, like Market with ups and downs, draw from the seed. The same seed gives the same results.")
                    }
                }

                if let message = form.problem ?? form.failure {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { store.closeScenarioForm() }
                        .keyboardShortcut(.cancelAction)
                        .help("Leave everything as it was  Esc")
                    Button(saveTitle(form), action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(form.problem != nil || isSaving)
                }
            }
            .padding(18)
            .frame(width: Self.width, alignment: .leading)
            .presentationBackground(Theme.panel)
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, .dark)
            .onAppear { nameFocused = true }
        }
    }

    private func title(_ form: ScenarioForm) -> String {
        switch form.mode {
        case .edit: return "Edit “\(store.name)”"
        case .new: return "New Scenario"
        case .duplicate: return "Duplicate “\(store.name)”"
        }
    }

    private func saveTitle(_ form: ScenarioForm) -> String {
        switch form.mode {
        case .edit: return "Save"
        case .new: return "Create"
        case .duplicate: return "Duplicate"
        }
    }

    private func startHint(_ form: ScenarioForm) -> String {
        switch form.mode {
        case .edit:
            return form.start == store.start
                ? "Every slot is worked out from this date. Readings from before it still count when fitting."
                : "Everything will be worked out again from \(DateText.dayMonthYear(form.start)). ⌘Z undoes it."
        case .new: return "The new scenario is worked out from this date. It starts with one blank formula."
        case .duplicate: return "The copy is worked out from this date. It keeps the slots, events and readings."
        }
    }

    private func currencyHint(_ form: ScenarioForm) -> String {
        guard form.mode == .edit, form.currency != store.currency else {
            return "Money is written in this, unless a slot has a currency of its own."
        }
        let example = store.money(inSlotAt: -1).full(18_000)
        let changed = ValueStyle(.currency, currency: form.currency, writing: form.currency.writing(form.numbers)).full(18_000)
        return "Slots' own amounts keep their numbers: \(example) becomes \(changed). Money read from slots in other currencies is converted."
    }

    /// "1.234,56 €": an amount in the currency, written the way a choice of style would.
    private func example(_ currency: Currency, _ style: NumberStyle?) -> String {
        ValueStyle(.currency, currency: currency, writing: currency.writing(style)).amountText(1234.56, digits: 2)
    }

    private func ratesHint(_ form: ScenarioForm) -> String {
        switch form.rates {
        case .ecb:
            return "Money a slot reads from a slot in another currency is converted at each day's rate, back to 1999. The latest rate is used for the future."
        case .openexchangerates:
            return "The ECB's daily rates for the past, with the latest from Open Exchange Rates every 10 minutes. The App ID is kept in your Keychain, never in the scenario."
        case .none:
            return "Money passes between slots as it is, whatever their currencies."
        }
    }

    private func save() {
        guard store.scenarioForm?.problem == nil, !isSaving else { return }
        isSaving = true
        Task {
            await store.submitScenarioForm(actions)
            isSaving = false
        }
    }

    /// A binding to one of the form's fields, while the form is open. Setting a field to what it
    /// is already changes nothing, so nothing redraws for it.
    private func binding<Value: Equatable>(_ form: ScenarioForm, _ path: WritableKeyPath<ScenarioForm, Value>) -> Binding<Value> {
        let fallback = form[keyPath: path]
        return Binding(
            get: { store.scenarioForm?[keyPath: path] ?? fallback },
            set: { value in
                guard var form = store.scenarioForm, form[keyPath: path] != value else { return }
                form[keyPath: path] = value
                form.failure = nil
                store.scenarioForm = form
            })
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
