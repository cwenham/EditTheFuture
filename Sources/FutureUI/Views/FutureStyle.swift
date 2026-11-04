import SwiftUI
import CoreText

/// How the views look (docs/DESIGN.md, 2.1): their colours, fonts and light or dark appearance. An app
/// that embeds the views sets one with `.futureStyle(_:)` on them or anything around them; without
/// one they look as the panel does (`.standard`).
///
/// ```swift
/// var style = FutureStyle.light
/// style.colors.proposal = .indigo
/// style.fonts.scale = 1.15
/// ScenarioGraph(store: store).futureStyle(style)
/// ```
public struct FutureStyle: Equatable, Sendable {
    public var colors: Colors
    public var fonts: Fonts
    /// Light or dark, for the controls inside the views: buttons, menus, text fields.
    public var colorScheme: ColorScheme
    /// The padding inside the editing panes, and the rounding of their corners.
    public var panePadding: CGFloat = 16
    public var cornerRadius: CGFloat = 12
    /// What the graphs' lines and readings are drawn thicker by: 1 as designed, more for lines
    /// that are easier to see.
    public var lineScale: CGFloat = 1

    /// One of the style's colours as a plain `Color`, for code that needs one: `style[Theme.grid]`.
    public subscript(_ color: ThemeColor) -> Color { color.color(in: self) }

    public init(colors: Colors, fonts: Fonts = Fonts(), colorScheme: ColorScheme) {
        self.colors = colors
        self.fonts = fonts
        self.colorScheme = colorScheme
    }

    /// The colours views draw with. Opacities are applied on top where a view draws something faint,
    /// so `ink` at 6% is a field's background and at 12% a selected tab's.
    public struct Colors: Equatable, Sendable {
        /// Behind everything: the panel, or a pane or graph on its own. `.clear` lets what's behind show.
        public var panel: Color
        public var text: Color
        /// Labels, notes and anything less important than `text`.
        public var secondary: Color
        /// What faint fills, borders and selections are made from: white on dark, black on light.
        public var ink: Color
        /// Text on a filled `proposal`-coloured button.
        public var onAccent: Color
        public var hairline: Color
        public var chipBorder: Color
        /// The faint tint over the future, right of the now line.
        public var futureTint: Color
        /// The shade left of the scenario's start, where there are only readings (docs/UI.md, 2.4).
        public var beforeStart: Color
        /// The dashed line at the scenario's start.
        public var startLine: Color
        public var grid: Color
        public var nowLine: Color
        public var cursorLine: Color
        /// Previews, proposals, targets and the main buttons.
        public var proposal: Color
        public var warning: Color
        /// Behind warnings, such as the drift pill.
        public var warningFill: Color
        public var error: Color
        public var success: Color
        /// Readings on the graph: dots on a thin line.
        public var reading: Color
        /// The formula editor's colours.
        public var code: Code

        public init(panel: Color, text: Color, secondary: Color, ink: Color, onAccent: Color, hairline: Color, chipBorder: Color,
                    futureTint: Color, beforeStart: Color, startLine: Color, grid: Color, nowLine: Color, cursorLine: Color,
                    proposal: Color, warning: Color, warningFill: Color, error: Color, success: Color, reading: Color, code: Code) {
            self.panel = panel
            self.text = text
            self.secondary = secondary
            self.ink = ink
            self.onAccent = onAccent
            self.hairline = hairline
            self.chipBorder = chipBorder
            self.futureTint = futureTint
            self.beforeStart = beforeStart
            self.startLine = startLine
            self.grid = grid
            self.nowLine = nowLine
            self.cursorLine = cursorLine
            self.proposal = proposal
            self.warning = warning
            self.warningFill = warningFill
            self.error = error
            self.success = success
            self.reading = reading
            self.code = code
        }
    }

    /// The formula and script editor's colours (docs/UI.md, 5.7).
    public struct Code: Equatable, Sendable {
        public var background: Color
        /// Behind the completion list.
        public var popup: Color
        public var text: Color
        public var lineNumber: Color
        /// Underlines and markers for mistakes, and line numbers on lines with one.
        public var error: Color
        public var errorLineNumber: Color
        public var warning: Color
        public var keyword: Color
        public var number: Color
        public var string: Color
        public var comment: Color
        /// Built-in functions and the script API.
        public var builtin: Color
        /// Other slots, their values and events.
        public var reference: Color
        /// `[t-1]` and other lags.
        public var lag: Color
        public var symbol: Color
        /// A script language's own library functions.
        public var library: Color

        public init(background: Color, popup: Color, text: Color, lineNumber: Color, error: Color, errorLineNumber: Color,
                    warning: Color, keyword: Color, number: Color, string: Color, comment: Color, builtin: Color,
                    reference: Color, lag: Color, symbol: Color, library: Color) {
            self.background = background
            self.popup = popup
            self.text = text
            self.lineNumber = lineNumber
            self.error = error
            self.errorLineNumber = errorLineNumber
            self.warning = warning
            self.keyword = keyword
            self.number = number
            self.string = string
            self.comment = comment
            self.builtin = builtin
            self.reference = reference
            self.lag = lag
            self.symbol = symbol
            self.library = library
        }
    }

    /// The views' type. Sizes in the views are for the standard style and are multiplied by `scale`.
    /// The views' columns, rows, panes and controls grow and shrink with it too (`layoutScale`).
    public struct Fonts: Equatable, Sendable {
        public var scale: CGFloat
        /// A font family by name, such as "Avenir Next"; nil for the system font.
        public var family: String?
        /// The system font's design, when there's no family. Code stays monospaced.
        public var design: Font.Design

        /// The size of the views' ordinary text at a scale of 1, in points: a slot's name, a field.
        /// Other text is sized against it.
        public static let standardSize: CGFloat = 13
        /// The scales the views are laid out for. Text can go further, but columns and rows stop here.
        public static let layoutScales: ClosedRange<CGFloat> = 0.75...2.5

        public init(scale: CGFloat = 1, family: String? = nil, design: Font.Design = .default) {
            self.scale = scale
            self.family = family
            self.design = design
        }

        /// The scale, or 1 when it's nonsense (zero, negative, infinite or NaN).
        var safeScale: CGFloat { scale.isFinite && scale > 0 ? scale : 1 }

        /// What fixed sizes in the views (columns, row heights, pane widths) are multiplied by.
        public var layoutScale: CGFloat {
            min(max(safeScale, Self.layoutScales.lowerBound), Self.layoutScales.upperBound)
        }

        /// A length the views are written in, at this scale.
        public func scaled(_ length: CGFloat) -> CGFloat { (length * layoutScale).rounded() }

        /// A control size the views are written in, a step or two larger or smaller at this scale,
        /// so buttons, menus and fields keep up with the text around them.
        public func controlSize(_ base: ControlSize = .regular) -> ControlSize {
            let sizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
            let steps = layoutScale < 0.9 ? -1 : layoutScale < 1.15 ? 0 : layoutScale < 1.6 ? 1 : 2
            let index = sizes.firstIndex(of: base) ?? 2
            return sizes[min(max(index + steps, 0), sizes.count - 1)]
        }

        /// A Core Text font for measuring text drawn with `font(size:)`, in its family when it has one.
        public func measuringFont(size: CGFloat, italic: Bool = false) -> CTFont {
            let size = size * safeScale
            var font = family.map { CTFontCreateWithName($0 as CFString, size, nil) }
                ?? CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            if italic, let slanted = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) { font = slanted }
            return font
        }

        /// The font for a size the views are written in.
        public func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
            let size = size * safeScale
            if design == nil, let family { return .custom(family, size: size).weight(weight) }
            // Built as the views wrote them before styles, so the standard style is the same font.
            let design = design ?? self.design
            switch (weight == .regular, design == .default) {
            case (true, true): return .system(size: size)
            case (false, true): return .system(size: size, weight: weight)
            case (true, false): return .system(size: size, design: design)
            case (false, false): return .system(size: size, weight: weight, design: design)
            }
        }
    }

    /// The panel's look: dark, with the colours in docs/UI.md, section 2.
    public static let standard = FutureStyle(
        colors: Colors(
            panel: Color(.sRGB, red: 20 / 255, green: 22 / 255, blue: 27 / 255, opacity: 1),
            text: Color(hex: "#ECEEF1"),
            secondary: Color(hex: "#A3A9B1"),
            ink: .white,
            onAccent: Color(hex: "#14161B"),
            hairline: Color.white.opacity(0.08),
            chipBorder: Color.white.opacity(0.14),
            futureTint: Color.white.opacity(0.03),
            beforeStart: Color.black.opacity(0.18),
            startLine: Color.white.opacity(0.3),
            grid: Color.white.opacity(0.07),
            nowLine: Color.white.opacity(0.45),
            cursorLine: Color.white.opacity(0.85),
            proposal: Color(hex: "#A9D0FF"),
            warning: Color(hex: "#FFC77A"),
            warningFill: Color(.sRGB, red: 1, green: 180 / 255, blue: 84 / 255, opacity: 0.16),
            error: Color(hex: "#FF9C9C"),
            success: Color(hex: "#9FE3C4"),
            reading: Color(hex: "#ECEEF1"),
            code: Code(background: Color(hex: "#111317"), popup: Color(hex: "#1F2228"), text: Color(hex: "#ECEEF1"),
                       lineNumber: Color(hex: "#848B95"), error: Color(hex: "#FF6B6B"), errorLineNumber: Color(hex: "#FF9C9C"),
                       warning: Color(hex: "#FFC77A"), keyword: Color(hex: "#C3A6FF"), number: Color(hex: "#FFC77A"),
                       string: Color(hex: "#9FE3C4"), comment: Color(hex: "#848B95"), builtin: Color(hex: "#46C8E0"),
                       reference: Color(hex: "#8CC4FF"), lag: Color(hex: "#4FD1A5"), symbol: Color(hex: "#A3A9B1"),
                       library: Color(hex: "#E8A0D0"))),
        colorScheme: .dark)

    /// The same style with stronger contrast, as the Mac's Increase Contrast asks for: secondary
    /// text nearer the main text, and hairlines, borders, grid lines and the now line stronger.
    public func increasingContrast() -> FutureStyle {
        var style = self
        let dark = colorScheme == .dark
        let ink: Color = dark ? .white : .black
        style.colors.secondary = dark ? Color(hex: "#D3D7DD") : Color(hex: "#3A3F47")
        style.colors.hairline = ink.opacity(dark ? 0.22 : 0.26)
        style.colors.chipBorder = ink.opacity(dark ? 0.36 : 0.4)
        style.colors.grid = ink.opacity(dark ? 0.18 : 0.2)
        style.colors.nowLine = ink.opacity(0.75)
        style.colors.startLine = ink.opacity(0.6)
        style.colors.cursorLine = ink
        style.colors.code.lineNumber = style.colors.secondary
        style.colors.code.comment = style.colors.secondary
        return style
    }

    /// The same views on a light background.
    public static let light = FutureStyle(
        colors: Colors(
            panel: Color(hex: "#F6F7F9"),
            text: Color(hex: "#1C1E22"),
            secondary: Color(hex: "#5E6570"),
            ink: .black,
            onAccent: .white,
            hairline: Color.black.opacity(0.10),
            chipBorder: Color.black.opacity(0.16),
            futureTint: Color.black.opacity(0.025),
            beforeStart: Color.black.opacity(0.05),
            startLine: Color.black.opacity(0.35),
            grid: Color.black.opacity(0.08),
            nowLine: Color.black.opacity(0.45),
            cursorLine: Color.black.opacity(0.75),
            proposal: Color(hex: "#1F6FD1"),
            warning: Color(hex: "#A65F00"),
            warningFill: Color(.sRGB, red: 1, green: 180 / 255, blue: 84 / 255, opacity: 0.24),
            error: Color(hex: "#C22F2F"),
            success: Color(hex: "#19865A"),
            reading: Color(hex: "#1C1E22"),
            code: Code(background: .white, popup: Color(hex: "#F0F1F3"), text: Color(hex: "#1C1E22"),
                       lineNumber: Color(hex: "#8A9099"), error: Color(hex: "#D93636"), errorLineNumber: Color(hex: "#C22F2F"),
                       warning: Color(hex: "#A65F00"), keyword: Color(hex: "#7B4CC9"), number: Color(hex: "#A65F00"),
                       string: Color(hex: "#19865A"), comment: Color(hex: "#8A9099"), builtin: Color(hex: "#0A7FA3"),
                       reference: Color(hex: "#1F6FD1"), lag: Color(hex: "#0F8F6A"), symbol: Color(hex: "#5E6570"),
                       library: Color(hex: "#B0428A"))),
        colorScheme: .light)
}

extension EnvironmentValues {
    /// How the views look; `FutureStyle.standard` unless a view sets another.
    @Entry public var futureStyle: FutureStyle = .standard
}

extension View {
    /// Sets how the views inside look: their colours, fonts and appearance.
    public func futureStyle(_ style: FutureStyle) -> some View {
        environment(\.futureStyle, style)
    }

    /// A font at a size the views are written in, scaled and set in the style's family.
    func futureFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> some View {
        modifier(FutureFont(size: size, weight: weight, design: design))
    }

    /// The style's light or dark appearance, and its text size, for the controls inside.
    func futureAppearance() -> some View {
        modifier(FutureAppearance())
    }

    /// A control size the views are written in, a step larger or smaller with the style's text.
    func futureControlSize(_ size: ControlSize) -> some View {
        modifier(FutureControlSize(size: size))
    }

    /// A fixed size the views are written in, grown or shrunk with the style's text.
    func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, alignment: alignment))
    }
}

struct FutureControlSize: ViewModifier {
    @Environment(\.futureStyle.fonts) private var fonts
    let size: ControlSize

    func body(content: Content) -> some View {
        content.controlSize(fonts.controlSize(size))
    }
}

struct ScaledFrame: ViewModifier {
    @Environment(\.futureStyle.fonts) private var fonts
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width.map(fonts.scaled), height: height.map(fonts.scaled), alignment: alignment)
    }
}

extension EnvironmentValues {
    /// The graph's columns and rows at the style's text size.
    var timelineLayout: TimelineLayout { TimelineLayout(scale: futureStyle.fonts.layoutScale) }
}

struct FutureFont: ViewModifier {
    @Environment(\.futureStyle.fonts) private var fonts
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(fonts.font(size: size, weight: weight, design: design))
    }
}

/// Light or dark, and text and controls that grow with the style: fields, menus and buttons take
/// the style's ordinary size and family unless a view sets its own.
struct FutureAppearance: ViewModifier {
    @Environment(\.futureStyle.colorScheme) private var scheme
    @Environment(\.futureStyle.fonts) private var fonts

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, scheme)
            .font(fonts.font(size: FutureStyle.Fonts.standardSize))
            .controlSize(fonts.controlSize())
    }
}

/// One of the style's colours, looked up where it's drawn: `Theme.text`, `Theme.proposal.opacity(0.2)`.
/// Draw it as any `ShapeStyle`, or in a `Canvas` with `.style(_:)`.
public struct ThemeColor: ShapeStyle, Sendable {
    public enum Role: Sendable {
        case panel, text, secondary, ink, onAccent, hairline, chipBorder, futureTint, beforeStart, startLine, grid, nowLine,
             cursorLine, proposal, warning, warningFill, error, success, reading, codeBackground, codePopup
    }

    public let role: Role
    public var alpha: Double = 1

    public init(_ role: Role, alpha: Double = 1) {
        self.role = role
        self.alpha = alpha
    }

    /// The same colour, fainter.
    public func opacity(_ opacity: Double) -> ThemeColor {
        ThemeColor(role, alpha: alpha * opacity)
    }

    /// Nothing: the ink at no opacity, for a choice between a fill and none.
    public static var clear: ThemeColor { ThemeColor(.ink, alpha: 0) }

    public func resolve(in environment: EnvironmentValues) -> Color {
        color(in: environment.futureStyle)
    }

    /// The colour in a style.
    public func color(in style: FutureStyle) -> Color {
        let colors = style.colors
        let base: Color
        switch role {
        case .panel: base = colors.panel
        case .text: base = colors.text
        case .secondary: base = colors.secondary
        case .ink: base = colors.ink
        case .onAccent: base = colors.onAccent
        case .hairline: base = colors.hairline
        case .chipBorder: base = colors.chipBorder
        case .futureTint: base = colors.futureTint
        case .beforeStart: base = colors.beforeStart
        case .startLine: base = colors.startLine
        case .grid: base = colors.grid
        case .nowLine: base = colors.nowLine
        case .cursorLine: base = colors.cursorLine
        case .proposal: base = colors.proposal
        case .warning: base = colors.warning
        case .warningFill: base = colors.warningFill
        case .error: base = colors.error
        case .success: base = colors.success
        case .reading: base = colors.reading
        case .codeBackground: base = colors.code.background
        case .codePopup: base = colors.code.popup
        }
        return alpha == 1 ? base : base.opacity(alpha)
    }
}
