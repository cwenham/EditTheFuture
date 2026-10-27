import SwiftUI
import FutureDocument
import FutureEngine
import FutureFeeds

/// The feed setup screen (docs/UI.md, 5.10): pick a ready-made feed or a source, fill in its
/// settings and sign-in, test it, and add it to a slot or give it a slot of its own.
struct FeedSetup: View {
    let store: ScenarioStore
    let request: FeedSetupRequest

    @State private var query = ""
    @State private var category = FeedPreset.Category.markets
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    static let size = CGSize(width: 880, height: 560)

    private var presets: [FeedPreset] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? FeedCatalog.presets(in: category) : FeedCatalog.search(query)
    }

    private var selected: FeedPreset? {
        let list = presets
        return list.first { $0.id == selection } ?? list.first
    }

    /// The feed being changed, when editing.
    private var editing: (slot: Int, source: Int, spec: FeedSpec)? {
        guard case .edit(let id, let source) = request, let index = store.slotIndex(id: id),
              let spec = store.readingSources(ofSlotAt: index).indices.contains(source)
                ? store.readingSources(ofSlotAt: index)[source].feed : nil else { return nil }
        return (index, source, spec)
    }

    private var title: String {
        switch request {
        case .add(let id): return "Add a feed to \(store.slotIndex(id: id).map { store.slots[$0].title } ?? "the slot")"
        case .edit: return "Change the feed"
        case .newSlot(let position): return "Add a data feed to slot \(position + 1)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search feeds: debt, CPI, rain, flu…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            HStack(spacing: 0) {
                categories.frame(width: 150)
                Divider()
                list.frame(width: 240)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .presentationBackground(Theme.panel)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
        .onAppear {
            // Editing starts on the feed's own preset, or the source's "any" one.
            if let spec = editing?.spec, let preset = Self.preset(for: spec) {
                category = preset.category
                selection = preset.id
            } else {
                searchFocused = true
            }
        }
    }

    /// The ready-made feed a feed was made from: the same source and settings, or the source's "any" one.
    static func preset(for spec: FeedSpec) -> FeedPreset? {
        FeedCatalog.all.first { $0.spec.provider == spec.provider && $0.spec.query == spec.query }
            ?? FeedCatalog.all.first { $0.category == .custom && $0.spec.provider == spec.provider }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FeedPreset.Category.allCases) { item in
                let active = query.isEmpty && item == category
                Button {
                    category = item
                    query = ""
                    selection = nil
                } label: {
                    Text(item.title)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(active ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer()
            Text("Most sources are free and need no key.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if presets.isEmpty {
                    Text("No feeds match “\(query)”. Any source has FRED, the World Bank, open data portals, and CSV or JSON at any web address.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(10)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(presets) { preset in
                    let active = preset.id == selected?.id
                    Button {
                        selection = preset.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(preset.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                if preset.provider?.signIn.need == .required {
                                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                                        .help("Needs a key")
                                }
                            }
                            Text(preset.provider?.name ?? preset.spec.provider)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(active ? Theme.proposal.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Theme.proposal.opacity(0.5) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let preset = selected {
            // Editing shows the feed as it is while its own preset is selected.
            let existing = editing.flatMap { Self.preset(for: $0.spec)?.id == preset.id ? $0.spec : nil }
            FeedForm(store: store, request: request, preset: preset, existing: existing)
                .id(preset.id + (existing?.identity ?? ""))
        } else {
            Color.clear
        }
    }
}

/// The settings of one feed: what it fetches, what it's readings of, how often, and the sign-in.
private struct FeedForm: View {
    let store: ScenarioStore
    let request: FeedSetupRequest
    let preset: FeedPreset
    /// The feed being changed, when editing.
    let existing: FeedSpec?

    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var into = ""
    @State private var convert = ""
    @State private var every = ""
    @State private var from = ""
    @State private var signIn = SignInDraft()
    @State private var savedSignIn = false
    @State private var test: TestState = .idle
    @State private var error: String?

    enum TestState: Equatable {
        case idle, running
        case done([Sample])
        case failed(String)
    }

    private var provider: (any FeedProvider)? { preset.provider }

    /// The slot it's for, when it's for one.
    private var slotIndex: Int? {
        switch request {
        case .add(let id), .edit(let id, _): return store.slotIndex(id: id)
        case .newSlot: return nil
        }
    }

    private var refreshChoices: [(String, String)] {
        [("", "As the source updates (\(provider.map { StepRate.text(adverbOf: $0.refresh) } ?? "daily"))"),
         ("1 hour", "Every hour"), ("1 day", "Every day"), ("1 week", "Every week"), ("1 month", "Every month")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let provider { settings(provider) }
                    usage
                    if let provider, provider.signIn.need != .none { SignInSection(provider: provider, spec: spec, draft: $signIn,
                                                                                 saved: $savedSignIn, store: store) }
                    testResult
                }
                .padding(14)
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel("Feed name")
            Text(preset.summary).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let provider {
                HStack(spacing: 6) {
                    Text("From \(provider.name)").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Link("Website", destination: provider.website).font(.system(size: 11)).foregroundStyle(Theme.proposal)
                    Spacer(minLength: 8)
                    Text("Values: \(preset.units)").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
    }

    private func settings(_ provider: any FeedProvider) -> some View {
        section("What to fetch") {
            ForEach(provider.fields) { field in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(field.label + (field.required ? "" : " (optional)"))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .frame(width: 128, alignment: .leading)
                        TextField(field.placeholder, text: binding(field.key))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: field.key == "url" || field.key == "where" ? .monospaced : .default))
                            .accessibilityLabel(field.label)
                        if !field.choices.isEmpty {
                            Menu {
                                ForEach(field.choices) { choice in
                                    Button(choice.label) { values[field.key] = choice.value }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Choose a common \(field.label.lowercased())")
                        }
                    }
                    if let help = field.help {
                        Text(help).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            .padding(.leading, 134)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var usage: some View {
        section("How to use the readings") {
            if let index = slotIndex {
                row("Readings of") {
                    Picker("Readings of", selection: $into) {
                        ForEach(store.feedTargets(ofSlotAt: index)) { Text($0.label).tag($0.name) }
                    }
                    .labelsHidden()
                    .onChange(of: into) { suggestConversion() }
                }
                Text("Readings replace this value on their dates. Between and after them, the model carries on.")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.leading, 134)
            }
            row("Convert") {
                Picker("Convert", selection: $convert) {
                    Text("As the source gives them").tag("")
                    ForEach(FeedConversion.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
            }
            row("Check for new") {
                Picker("Check for new", selection: $every) {
                    ForEach(refreshChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
            }
            row("Earliest reading") {
                TextField("All of them", text: $from)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 120)
                    .accessibilityLabel("Earliest reading")
                Text("like 1990-01-01").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching the last year of readings…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        case .done(let samples):
            VStack(alignment: .leading, spacing: 6) {
                if let first = samples.first, let last = samples.last {
                    Label("\(samples.count) readings from \(DateText.monthYear(first.time)) to \(DateText.monthYear(last.time)). "
                          + "Latest: \(SlotValue.number(last.value)) on \(DateText.iso(last.time)).", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                    FeedSparkline(samples: samples).frame(height: 56)
                } else {
                    Label("The source answered, but had no readings for the last year.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.system(size: 12)).foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Test") { runTest() }
                .disabled(test == .running || missingField != nil)
                .help("Fetch the last year of readings, without adding anything")
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.error).lineLimit(2)
            } else if let missing = missingField {
                Text("Fill in \(missing).").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Cancel") { store.closeFeedSetup() }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(missingField != nil || (provider?.signIn.need == .required && !signIn.isFilled && !savedSignIn))
        }
    }

    private var actionTitle: String {
        switch request {
        case .add(let id): return "Add to \(store.slotIndex(id: id).map { store.slots[$0].title } ?? "the slot")"
        case .edit: return "Save"
        case .newSlot(let position): return "Add to slot \(position + 1)"
        }
    }

    // MARK: The feed

    private var missingField: String? {
        guard let provider else { return "a source" }
        return provider.fields.first { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "“\($0.label)”" }
    }

    /// The feed as the form says it.
    private var spec: FeedSpec {
        var settings: [FeedSetting] = []
        let known = Set((provider?.fields ?? []).map(\.key))
        for field in provider?.fields ?? [] {
            let value = (values[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { settings.append(FeedSetting(field.key, value)) }
        }
        // Settings the form doesn't show, such as a preset's `from`, stay.
        for (key, value) in values.sorted(by: { $0.key < $1.key })
        where !known.contains(key) && !FeedSpec.usageKeys.contains(key) && key != "from" && !value.isEmpty {
            settings.append(FeedSetting(key, value))
        }
        var spec = FeedSpec(title: name.trimmingCharacters(in: .whitespaces).isEmpty ? preset.title : name,
                            provider: preset.spec.provider, settings: settings)
        let trimmedFrom = from.trimmingCharacters(in: .whitespaces)
        if !trimmedFrom.isEmpty { spec["from"] = trimmedFrom }
        if slotIndex != nil, !into.isEmpty { spec["into"] = into }
        if !convert.isEmpty { spec["convert"] = convert }
        if !every.isEmpty { spec["every"] = every }
        if let credential = existing?.credentialName { spec["credential"] = credential }
        return spec
    }

    private func load() {
        let source = existing ?? preset.spec
        name = existing?.title ?? preset.title
        var values: [String: String] = [:]
        for setting in source.settings where !FeedSpec.usageKeys.contains(setting.key) { values[setting.key] = setting.value }
        from = values.removeValue(forKey: "from") ?? ""
        self.values = values
        every = existing?["every"] ?? ""
        if let existing {
            into = existing.variable ?? slotIndex.map { store.slots[$0].variable } ?? ""
            convert = existing["convert"] ?? ""
        } else {
            into = slotIndex.map { store.slots[$0].variable } ?? ""
            suggestConversion()
            if case .newSlot = request { convert = preset.conversion(forFormat: preset.format)?.rawValue ?? "" }
        }
        signIn = SignInDraft(kind: provider?.signIn.kinds.first ?? .key)
        if let provider, provider.signIn.need != .none {
            let name = provider.credentialName(for: spec)
            savedSignIn = store.credentials.hasCredential(named: name)
        }
    }

    /// Percent points into a percent, or °F into a temperature, converts.
    private func suggestConversion() {
        guard existing == nil, let index = slotIndex else { return }
        let quantity = store.quantity(of: into, inSlotAt: index)
        let format: String
        switch quantity {
        case .percent: format = "percent"
        case .temperature: format = "temperature"
        default: format = "number"
        }
        convert = preset.conversion(forFormat: format)?.rawValue ?? ""
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    /// The sign-in typed in, ready to save, for this feed's hosts.
    private var typedCredential: FeedCredential? {
        guard let provider, signIn.isFilled else { return nil }
        return signIn.credential(hosts: provider.hosts(for: spec))
    }

    private func runTest() {
        let spec = self.spec
        error = nil
        test = .running
        let credentials: any CredentialStore
        if let provider, let typed = typedCredential {
            credentials = MemoryCredentialStore([provider.credentialName(for: spec): typed])
        } else {
            credentials = store.credentials
        }
        let fetcher = FeedFetcher(transport: store.feedTransport, credentials: credentials)
        Task {
            do {
                let points = try await fetcher.fetch(spec, since: Date().addingTimeInterval(-366 * 86_400))
                test = .done(points.map { Sample(time: $0.time, value: spec.value($0.value)) })
            } catch {
                test = .failed((error as? FeedError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func commit() {
        let spec = self.spec
        if let from = spec["from"], FileDate.parse(from) == nil {
            error = "“\(from)” isn't a date. Write it like 1990-01-01."
            return
        }
        if let provider, let typed = typedCredential {
            guard typed.hosts.allSatisfy({ !$0.isEmpty }), !typed.hosts.isEmpty else {
                error = "Fill in the web address first, so the sign-in knows where it may be sent."
                return
            }
            do {
                try store.credentials.save(typed, named: provider.credentialName(for: spec))
            } catch {
                self.error = "Couldn't save the sign-in: \(error)"
                return
            }
        }
        switch request {
        case .add:
            if let index = slotIndex { store.addFeed(spec, toSlotAt: index) }
        case .edit(_, let source):
            if let index = slotIndex { store.replaceFeed(at: source, inSlotAt: index, with: spec) }
        case .newSlot(let position):
            let format = ValueFormat(rawValue: preset.format) ?? .number
            let slotName = name == preset.title ? preset.slotName : name
            store.addFeedSlot(spec, name: slotName, format: format, step: preset.step, atPosition: position)
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 128, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// A sign-in as it's being typed.
struct SignInDraft: Equatable {
    var kind: FeedCredential.Kind = .key
    var secret = ""
    var username = ""
    /// The parameter's or header's name.
    var name = ""
    var reveal = false

    var isFilled: Bool {
        switch kind {
        case .basic: return !username.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty
        case .header: return !secret.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !secret.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func credential(hosts: [String]) -> FeedCredential {
        FeedCredential(kind: kind, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                       username: username.trimmingCharacters(in: .whitespaces),
                       name: name.trimmingCharacters(in: .whitespaces), hosts: hosts)
    }
}

/// The sign-in part of the form: a box to paste a key, a token, or a username and password, and
/// where it's kept and sent.
private struct SignInSection: View {
    let provider: any FeedProvider
    let spec: FeedSpec
    @Binding var draft: SignInDraft
    @Binding var saved: Bool
    let store: ScenarioStore

    private var credentialName: String { provider.credentialName(for: spec) }
    private var hosts: [String] { provider.hosts(for: spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Sign-in").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Text(needText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(provider.signIn.need == .required ? Theme.warning : Theme.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.chipBorder))
                Spacer()
                if let signUp = provider.signIn.signUp {
                    Link(provider.signIn.need == .required ? "Get a key" : "Get a free key", destination: signUp)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.proposal)
                }
            }
            if let note = provider.signIn.note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if provider.signIn.kinds.count > 1 {
                labelled("Kind") {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(provider.signIn.kinds) { kind in Text(kindTitle(kind)).tag(kind) }
                    }
                    .labelsHidden()
                }
            }
            fields
            if saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").foregroundStyle(Theme.success)
                    Text("A sign-in for \(credentialName) is saved. Paste a new one to replace it.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Forget") { forget() }.controlSize(.small)
                }
            }
            Text("Kept in your Keychain, never in the scenario file. Sent only to \(hosts.isEmpty ? "the source's address" : hosts.joined(separator: ", ")), over HTTPS.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var needText: String {
        switch provider.signIn.need {
        case .none: return "Not needed"
        case .optional: return "Optional"
        case .required: return "Needed"
        }
    }

    private func kindTitle(_ kind: FeedCredential.Kind) -> String {
        kind == .key && provider.signsInByHost ? "Key in the address" : kind.title
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .key:
            if provider.signsInByHost {
                labelled("Parameter") {
                    TextField("api_key", text: $draft.name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
            }
            labelled("API key") { secretField("Paste your API key") }
        case .header:
            labelled("Header") {
                TextField(provider.id == "socrata" ? "X-App-Token" : "X-API-Key", text: $draft.name)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            }
            labelled("Value") { secretField(provider.id == "socrata" ? "Paste your app token" : "Paste the key") }
        case .bearer:
            labelled("Token") { secretField("Paste your token") }
        case .basic:
            labelled("Username") {
                TextField("Username", text: $draft.username).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            labelled("Password") { secretField("Password") }
        }
    }

    @ViewBuilder
    private func secretField(_ prompt: String) -> some View {
        HStack(spacing: 4) {
            Group {
                if draft.reveal {
                    TextField(prompt, text: $draft.secret)
                } else {
                    SecureField(prompt, text: $draft.secret)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .accessibilityLabel(prompt)
            Button {
                draft.reveal.toggle()
            } label: {
                Image(systemName: draft.reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help(draft.reveal ? "Hide it" : "Show it")
            .accessibilityLabel(draft.reveal ? "Hide" : "Show")
        }
        .onAppear {
            if draft.name.isEmpty, draft.kind == .header, provider.id == "socrata" { draft.name = "X-App-Token" }
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 72, alignment: .leading)
            content()
        }
    }

    private func forget() {
        do {
            try store.credentials.remove(named: credentialName)
            saved = false
        } catch {
            store.say("Couldn't forget the sign-in: \(error)", isError: true)
        }
    }
}

/// A small line chart of a test fetch.
struct FeedSparkline: View {
    let samples: [Sample]

    var body: some View {
        Canvas { context, size in
            let finite = samples.filter { $0.value.isFinite }
            guard let first = finite.first, let last = finite.last, last.time > first.time else { return }
            var low = finite.map(\.value).min()!, high = finite.map(\.value).max()!
            if !(high > low) { low -= 1; high += 1 }
            let span = last.time.timeIntervalSince(first.time)
            var path = Path()
            for (offset, sample) in finite.enumerated() {
                let x = CGFloat(sample.time.timeIntervalSince(first.time) / span) * size.width
                let y = (1 - CGFloat((sample.value - low) / (high - low))) * (size.height - 6) + 3
                if offset == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(Theme.reading.opacity(0.85)), lineWidth: 1.5)
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.hairline))
        }
        .accessibilityLabel("The last year of readings")
    }
}

extension StepRate {
    /// "daily", "weekly": for saying how often a source updates.
    static func text(adverbOf rate: StepRate) -> String { rate.adverb }
}
