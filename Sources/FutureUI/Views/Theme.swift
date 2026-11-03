import SwiftUI

/// The colours views draw with, looked up in the current `FutureStyle` where they're drawn
/// (docs/UI.md, section 2, for the standard ones).
public enum Theme {
    public static let panel = ThemeColor(.panel)
    public static let text = ThemeColor(.text)
    public static let secondary = ThemeColor(.secondary)
    /// White on dark styles, black on light: faint fills, borders and selections are this at a low opacity.
    public static let ink = ThemeColor(.ink)
    /// Text on a filled `proposal` button.
    public static let onAccent = ThemeColor(.onAccent)
    public static let hairline = ThemeColor(.hairline)
    public static let chipBorder = ThemeColor(.chipBorder)
    public static let futureTint = ThemeColor(.futureTint)
    /// Shade left of the scenario's start, where there are only readings (docs/UI.md, 2.4).
    public static let beforeStart = ThemeColor(.beforeStart)
    /// The dashed line at the scenario's start, where the models' lines begin.
    public static let startLine = ThemeColor(.startLine)
    public static let grid = ThemeColor(.grid)
    public static let nowLine = ThemeColor(.nowLine)
    public static let cursorLine = ThemeColor(.cursorLine)
    public static let proposal = ThemeColor(.proposal)
    public static let warning = ThemeColor(.warning)
    /// Behind warnings such as the drift pill (docs/UI.md, 2.1).
    public static let warningFill = ThemeColor(.warningFill)
    public static let error = ThemeColor(.error)
    public static let success = ThemeColor(.success)
    /// Readings: dots on a thin line, drawn at 85% (docs/UI.md, 2.4).
    public static let reading = ThemeColor(.reading)
    /// Behind the formula editor, and its completion list.
    public static let codeBackground = ThemeColor(.codeBackground)
    public static let codePopup = ThemeColor(.codePopup)
}

/// Column layout shared by the focused graph, the axis rows and every lane,
/// so all plots line up on the same time axis.
enum TimelineLayout {
    static let labelWidth: CGFloat = 150
    static let valueWidth: CGFloat = 120
    static let gap: CGFloat = 10
    static let focusHeight: CGFloat = 300
    static let laneHeight: CGFloat = 44
    static let axisHeight: CGFloat = 22
    static let eventsHeight: CGFloat = 34

    static let laneRowHeight: CGFloat = 40
    static let laneSpacing: CGFloat = 4
    static let minimumFocusHeight: CGFloat = 160

    static func plotWidth(forTotal width: CGFloat) -> CGFloat {
        max(120, width - labelWidth - valueWidth - 2 * gap)
    }

    /// Height of everything under the focused graph: axis, events, divider and lanes. A graph
    /// without the events strip or the lanes (`ScenarioGraph.Parts`) leaves them out.
    static func heightBelowFocus(laneCount: Int, events: Bool = true, lanes showsLanes: Bool = true) -> CGFloat {
        let lanes = CGFloat(laneCount) * laneRowHeight + CGFloat(max(laneCount - 1, 0)) * laneSpacing
        return axisHeight + (events ? eventsHeight : 0) + (showsLanes ? 11 + 8 + lanes : 0)
    }

    /// The focused graph takes whatever height the window leaves after the rows under it.
    static func focusHeight(forTotal height: CGFloat, laneCount: Int, events: Bool = true, lanes: Bool = true) -> CGFloat {
        max(minimumFocusHeight, height - heightBelowFocus(laneCount: laneCount, events: events, lanes: lanes))
    }

    static var plotLeading: CGFloat { labelWidth + gap }
}

extension Color {
    /// `Color(hex: "#5AA9FF")`
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}
