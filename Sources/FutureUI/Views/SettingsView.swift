import SwiftUI

/// A group of settings: its name and symbol in the list on the left, and its settings.
public struct SettingsPage: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    let content: () -> AnyView

    public init<Content: View>(id: String, title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = { AnyView(content()) }
    }

    /// The panel's theme, contrast, lines, font and text size.
    @MainActor public static func appearance(_ settings: AppearanceSettings) -> SettingsPage {
        SettingsPage(id: "appearance", title: "Appearance", symbol: "textformat.size") { AppearanceSettingsPane(settings: settings) }
    }

    /// Which wheels the mouse has, and how fast they move and zoom.
    @MainActor public static func mouse(_ wheel: TimelineWheel) -> SettingsPage {
        SettingsPage(id: "mouse", title: "Mouse and Trackpad", symbol: "computermouse") { MouseSettingsPane(wheel: wheel) }
    }

    #if os(macOS)
    /// The shortcuts that work from any app.
    @MainActor public static func shortcuts(_ shortcuts: ShortcutSettings) -> SettingsPage {
        SettingsPage(id: "shortcuts", title: "Shortcuts", symbol: "keyboard") { ShortcutSettingsPane(shortcuts: shortcuts) }
    }
    #endif
}

/// The app's Settings window (docs/UI.md, 7): groups of settings in a list on the left, and the
/// chosen group's settings on the right. It's ordinary Mac window chrome, so it's drawn in the Mac's
/// own look rather than the panel's style, and stays the same size whatever text size is chosen;
/// the preview shows the panel's text at that size.
public struct SettingsView: View {
    let pages: [SettingsPage]
    @AppStorage(SettingsView.groupKey) private var pageID = ""

    /// Where the group last shown is remembered, in `UserDefaults.standard`.
    public static let groupKey = "EditTheFuture.settings.group"

    /// The groups, in the order they're listed. The first shows until another is chosen.
    public init(pages: [SettingsPage]) {
        self.pages = pages
    }

    private var selection: Binding<String?> {
        Binding(get: { pages.contains { $0.id == pageID } ? pageID : pages.first?.id },
                set: { if let new = $0, new != pageID { pageID = new } })
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(pages, selection: selection) { page in
                Label(page.title, systemImage: page.symbol).tag(page.id)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let page = pages.first(where: { $0.id == selection.wrappedValue }) {
                        page.content()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// A heading and the settings under it, as Mac settings panes lay them out.
public struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(.bottom, 22)
    }
}

/// A setting's name on the left, in a column, and its control on the right.
public struct SettingRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 110
    let content: Content

    public init(label: String, labelWidth: CGFloat = 110, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: labelWidth > 0 ? 12 : 0) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

struct AppearanceSettingsPane: View {
    @Bindable var settings: AppearanceSettings
    @State private var families: [String] = []
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        SettingsSection(title: "Panel") {
            SettingRow(label: "Theme:") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppearanceSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            SettingRow(label: "") {
                Toggle("Increase contrast", isOn: $settings.increasesContrast)
                Text(contrast == .increased
                     ? "On, because Increase Contrast is on in the Mac’s Accessibility settings."
                     : "Text, borders and grid lines stand out more. The Mac’s own Increase Contrast turns it on too.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Thicker lines on the graphs", isOn: $settings.thickerLines)
            }
        }

        SettingsSection(title: "Text") {
            SettingRow(label: "Font:") {
                Picker("Font", selection: $settings.font) {
                    ForEach(AppearanceSettings.FontChoice.SystemDesign.allCases, id: \.self) { design in
                        Text(design.title).tag(AppearanceSettings.FontChoice.system(design))
                    }
                    Divider()
                    if case .family(let name) = settings.font, !families.contains(name) {
                        Text("\(name) (not installed)").tag(settings.font)
                    }
                    ForEach(families, id: \.self) { Text($0).tag(AppearanceSettings.FontChoice.family($0)) }
                }
                .labelsHidden()
                .frame(width: 260)
                if !settings.fontIsInstalled {
                    Text("This font isn't installed, so the panel uses the system font.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Formulas and scripts stay in a monospaced font.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            SettingRow(label: "Text size:") {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $settings.textSize, in: AppearanceSettings.textSizes, step: 1)
                        .frame(width: 220)
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(Int(settings.textSize)) points")
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(sizeText).monospacedDigit().frame(minWidth: 110, alignment: .leading)
                }
                Text("Everything in the panel is sized against this: names, values, buttons, menus, the graph’s columns and the side pane. In the panel, ⌘+ and ⌘− change it a point at a time, and ⌘0 puts it back.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            SettingRow(label: "") {
                Button("Use the Standard Look") { settings.reset() }
                    .disabled(settings.isStandard)
            }
        }

        SettingsSection(title: "Preview") {
            TextPreview(style: settings.style(colorScheme: systemScheme, increasedContrast: contrast == .increased))
        }
        .onAppear { if families.isEmpty { families = AppearanceSettings.installedFamilies() } }
    }

    private var sizeText: String {
        let points = "\(Int(settings.textSize)) pt"
        return settings.textSize == AppearanceSettings.standardTextSize ? points + " (standard)" : points
    }
}

/// A few lines of the panel, drawn in its style at the chosen font and size.
struct TextPreview: View {
    let style: FutureStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("1").futureFont(11).monospacedDigit().foregroundStyle(Theme.secondary)
                    .padding(.trailing, 2)
                Circle().fill(Color(hex: "#5AA9FF")).frame(width: 8, height: 8)
                Text("Savings").futureFont(13, weight: .medium)
            }
            Text("Jan 2030").futureFont(12).foregroundStyle(Theme.secondary)
            Text("$96,420").futureFont(22, weight: .semibold).monospacedDigit()
            Text("Deposit 500 monthly, starting next spring").futureFont(11).foregroundStyle(Theme.secondary)
            PreviewLine()
                .frame(height: 36)
                .padding(.top, 4)
        }
        .foregroundStyle(Theme.text)
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .futureStyle(style)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the panel's text")
    }
}

/// A short rising line with grid lines, as the graph draws them.
private struct PreviewLine: View {
    var body: some View {
        Canvas { context, size in
            let style = context.environment.futureStyle
            var grid = Path()
            for y in [size.height * 0.2, size.height * 0.8] {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .style(Theme.grid), lineWidth: 1)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height * 0.85))
            line.addCurve(to: CGPoint(x: size.width, y: size.height * 0.1),
                          control1: CGPoint(x: size.width * 0.5, y: size.height * 0.8),
                          control2: CGPoint(x: size.width * 0.7, y: size.height * 0.4))
            context.stroke(line, with: .color(Color(hex: "#5AA9FF")),
                           style: StrokeStyle(lineWidth: 1.8 * style.lineScale, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

struct MouseSettingsPane: View {
    @Bindable var wheel: TimelineWheel

    var body: some View {
        SettingsSection(title: "Mouse wheels over the graph") {
            Picker("Mouse wheels", selection: $wheel.mode) {
                ForEach(TimelineWheel.Mode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(mode))
                        Text(Self.detail(mode)).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if wheel.mode == .automatic {
                HStack(spacing: 10) {
                    Text(wheel.foundHorizontalWheel ? "A horizontal wheel has been found, so the vertical wheel zooms."
                         : "No horizontal wheel has turned yet, so the wheel moves through time.")
                        .font(.callout).foregroundStyle(.secondary)
                    if wheel.foundHorizontalWheel {
                        Button("Forget It") { wheel.noteHorizontalWheel(false) }
                            .help("Go back to one wheel until a horizontal wheel turns again")
                    }
                }
            }
        }

        SettingsSection(title: "Speed") {
            SettingRow(label: "Moving in time:") { speedSlider("Moving through time", value: $wheel.panSpeed) }
            SettingRow(label: "Zooming:") { speedSlider("Zooming", value: $wheel.zoomSpeed) }
            SettingRow(label: "") {
                Toggle("Reverse the horizontal wheel", isOn: $wheel.reversesHorizontalWheel)
                    .disabled(wheel.mode == .oneWheel)
                Text("Speeds are for mouse wheels and trackpad swipes alike; pinching always follows your fingers. Reversing changes only a mouse’s horizontal wheel.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                Button("Use Standard Speeds") { wheel.resetFeel() }
                    .disabled(wheel.panSpeed == 1 && wheel.zoomSpeed == 1 && !wheel.reversesHorizontalWheel)
            }
        }

        SettingsSection(title: "Trackpad and Magic Mouse") {
            Text("Swipe to move through time. Pinch, or hold Shift or ⌘ while you swipe, to zoom.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A slider from a quarter of the designed speed to four times it, even steps each way.
    private func speedSlider(_ title: String, value: Binding<Double>) -> some View {
        let exponent = Binding(get: { log2(min(max(value.wrappedValue, 0.25), 4)) },
                               set: { new in
                                   let speed = pow(2, (new * 4).rounded() / 4)
                                   if speed != value.wrappedValue { value.wrappedValue = speed }
                               })
        return HStack(spacing: 8) {
            Text("Slower").font(.callout).foregroundStyle(.secondary)
            Slider(value: exponent, in: -2...2)
                .frame(width: 200)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.2g times", value.wrappedValue))
            Text("Faster").font(.callout).foregroundStyle(.secondary)
        }
    }

    static func title(_ mode: TimelineWheel.Mode) -> String {
        switch mode {
        case .automatic: "Find out automatically"
        case .twoWheels: "Vertical and horizontal wheels"
        case .oneWheel: "One wheel"
        }
    }

    static func detail(_ mode: TimelineWheel.Mode) -> String {
        switch mode {
        case .automatic: "The first time a horizontal wheel turns, it moves through time and the vertical wheel zooms."
        case .twoWheels: "The horizontal wheel moves through time; the vertical wheel zooms."
        case .oneWheel: "The wheel moves through time; hold Shift while you turn it to zoom."
        }
    }
}
