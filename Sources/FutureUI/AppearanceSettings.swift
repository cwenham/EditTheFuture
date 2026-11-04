import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The panel's font and text size, chosen in Settings (docs/UI.md, 7) and remembered between
/// launches. `style(from:)` turns them into the `FutureStyle` the views are drawn with.
///
/// Every size in the views is written against one standard size (`FutureStyle.Fonts.standardSize`),
/// so one setting makes all of it larger or smaller: labels, values, buttons, menus, the graph's
/// columns and the side pane.
@MainActor
@Observable
public final class AppearanceSettings {
    /// A font for the panel's text. Formulas and scripts stay monospaced whatever is chosen.
    public enum FontChoice: Hashable, Sendable {
        /// The Mac's own font, in one of its designs.
        case system(SystemDesign)
        /// An installed font family, by name.
        case family(String)

        public enum SystemDesign: String, CaseIterable, Sendable {
            case standard, rounded, serif

            var design: Font.Design {
                switch self {
                case .standard: .default
                case .rounded: .rounded
                case .serif: .serif
                }
            }

            public var title: String {
                switch self {
                case .standard: "System"
                case .rounded: "System Rounded"
                case .serif: "System Serif"
                }
            }
        }

        public static let standard = FontChoice.system(.standard)

        public var title: String {
            switch self {
            case .system(let design): design.title
            case .family(let name): name
            }
        }

        /// How it's kept in the settings: "system", "system:rounded", "family:Avenir Next".
        var stored: String {
            switch self {
            case .system(.standard): "system"
            case .system(let design): "system:" + design.rawValue
            case .family(let name): "family:" + name
            }
        }

        init?(stored: String) {
            if stored == "system" {
                self = .standard
            } else if stored.hasPrefix("system:"), let design = SystemDesign(rawValue: String(stored.dropFirst(7))) {
                self = .system(design)
            } else if stored.hasPrefix("family:"), stored.count > 7 {
                self = .family(String(stored.dropFirst(7)))
            } else {
                return nil
            }
        }
    }

    /// Dark, light, or whichever the Mac is set to.
    public enum Theme: String, CaseIterable, Identifiable, Sendable {
        case dark, light, system

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .dark: "Dark"
            case .light: "Light"
            case .system: "Match the Mac"
            }
        }
    }

    /// The text sizes offered, in points, for the panel's ordinary text.
    public static let textSizes: ClosedRange<Double> = 10...32
    public static let standardTextSize = Double(FutureStyle.Fonts.standardSize)

    private var chosenFont: FontChoice
    private var chosenSize: Double
    private var chosenTheme: Theme
    private var chosenContrast: Bool
    private var chosenThickLines: Bool

    /// The panel is dark unless another theme is chosen.
    public var theme: Theme {
        get { chosenTheme }
        set {
            guard newValue != chosenTheme else { return }
            chosenTheme = newValue
            defaults.set(newValue.rawValue, forKey: Self.themeKey)
        }
    }

    /// Stronger contrast for text, borders and grid lines. The Mac's own Increase Contrast turns it on too.
    public var increasesContrast: Bool {
        get { chosenContrast }
        set {
            guard newValue != chosenContrast else { return }
            chosenContrast = newValue
            defaults.set(newValue, forKey: Self.contrastKey)
        }
    }

    /// The graphs' lines and readings drawn thicker (`lineScale`).
    public var thickerLines: Bool {
        get { chosenThickLines }
        set {
            guard newValue != chosenThickLines else { return }
            chosenThickLines = newValue
            defaults.set(newValue, forKey: Self.thickLinesKey)
        }
    }

    /// How much thicker lines are drawn with `thickerLines` on.
    public static let thickLineScale: CGFloat = 1.75

    public var font: FontChoice {
        get { chosenFont }
        set {
            guard newValue != chosenFont else { return }
            chosenFont = newValue
            defaults.set(newValue.stored, forKey: Self.fontKey)
        }
    }

    /// The size of the panel's ordinary text, in points, within `textSizes`; everything else is
    /// sized against it.
    public var textSize: Double {
        get { chosenSize }
        set {
            let size = Self.clamp(newValue)
            guard newValue.isFinite, size != chosenSize else { return }
            chosenSize = size
            defaults.set(size, forKey: Self.textSizeKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    static let fontKey = "EditTheFuture.settings.font"
    static let textSizeKey = "EditTheFuture.settings.textSize"
    static let themeKey = "EditTheFuture.settings.theme"
    static let contrastKey = "EditTheFuture.settings.increaseContrast"
    static let thickLinesKey = "EditTheFuture.settings.thickerLines"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosenFont = defaults.string(forKey: Self.fontKey).flatMap(FontChoice.init(stored:)) ?? .standard
        chosenSize = Self.clamp(defaults.object(forKey: Self.textSizeKey) == nil
                              ? Self.standardTextSize : defaults.double(forKey: Self.textSizeKey))
        chosenTheme = defaults.string(forKey: Self.themeKey).flatMap(Theme.init(rawValue:)) ?? .dark
        chosenContrast = defaults.bool(forKey: Self.contrastKey)
        chosenThickLines = defaults.bool(forKey: Self.thickLinesKey)
    }

    private static func clamp(_ size: Double) -> Double {
        guard size.isFinite else { return standardTextSize }
        return min(max(size, textSizes.lowerBound), textSizes.upperBound)
    }

    /// How much larger or smaller than standard the text is.
    public var scale: CGFloat { CGFloat(textSize / Self.standardTextSize) }

    /// Whether the chosen family is installed. One that isn't is drawn in the system font.
    public var fontIsInstalled: Bool {
        guard case .family(let name) = font else { return true }
        return Self.isInstalled(name)
    }

    /// The style to draw with. `colorScheme` is the Mac's, for `.system`; `increasedContrast` says
    /// whether the Mac's Increase Contrast is on.
    public func style(colorScheme: ColorScheme = .dark, increasedContrast: Bool = false) -> FutureStyle {
        let light = theme == .light || (theme == .system && colorScheme == .light)
        var style = self.style(from: light ? .light : .standard)
        if increasedContrast && !increasesContrast { style = style.increasingContrast() }
        return style
    }

    /// `base` with this font, size, contrast and line thickness; its colours are otherwise left as they are.
    public func style(from base: FutureStyle) -> FutureStyle {
        var style = increasesContrast ? base.increasingContrast() : base
        style.lineScale = thickerLines ? Self.thickLineScale : 1
        style.fonts.scale = scale
        switch font {
        case .system(let design):
            style.fonts.family = nil
            style.fonts.design = design.design
        case .family(let name):
            style.fonts.family = fontIsInstalled ? name : nil
            style.fonts.design = .default
        }
        return style
    }

    /// Back to the system font at the standard size, and the panel's own look.
    public func reset() {
        font = .standard
        textSize = Self.standardTextSize
        theme = .dark
        increasesContrast = false
        thickerLines = false
    }

    /// Whether everything is as it was designed.
    public var isStandard: Bool {
        font == .standard && textSize == Self.standardTextSize && theme == .dark && !increasesContrast && !thickerLines
    }

    /// One step larger or smaller (⌘+ and ⌘− in the panel), or back to standard (⌘0). Returns
    /// what the size is now, for saying so.
    @discardableResult
    public func stepTextSize(_ steps: Int) -> Double {
        textSize = steps == 0 ? Self.standardTextSize : (textSize + Double(steps)).rounded()
        return textSize
    }

    /// The font families installed on this Mac, by name.
    public static func installedFamilies() -> [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        #else
        UIFont.familyNames.sorted()
        #endif
    }

    static func isInstalled(_ family: String) -> Bool {
        #if os(macOS)
        NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
        #else
        !UIFont.fontNames(forFamilyName: family).isEmpty
        #endif
    }
}
