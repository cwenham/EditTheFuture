import SwiftUI

/// Colors and sizes from docs/UI.md, section 2.
public enum Theme {
    public static let panel = Color(.sRGB, red: 20 / 255, green: 22 / 255, blue: 27 / 255, opacity: 1)
    public static let text = Color(hex: "#ECEEF1")
    public static let secondary = Color(hex: "#A3A9B1")
    public static let hairline = Color.white.opacity(0.08)
    public static let chipBorder = Color.white.opacity(0.14)
    public static let futureTint = Color.white.opacity(0.03)
    /// Shade left of the scenario's start, where there are only readings (docs/UI.md, 2.4).
    public static let beforeStart = Color.black.opacity(0.18)
    /// The dashed line at the scenario's start, where the models' lines begin.
    public static let startLine = Color.white.opacity(0.3)
    public static let grid = Color.white.opacity(0.07)
    public static let nowLine = Color.white.opacity(0.45)
    public static let cursorLine = Color.white.opacity(0.85)
    public static let proposal = Color(hex: "#A9D0FF")
    public static let warning = Color(hex: "#FFC77A")
    public static let error = Color(hex: "#FF9C9C")
    public static let success = Color(hex: "#9FE3C4")
    /// Readings: dots on a thin line, drawn at 85% (docs/UI.md, 2.4).
    public static let reading = Color(hex: "#ECEEF1")
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

    /// Height of everything under the focused graph: axis, events, divider and lanes.
    static func heightBelowFocus(laneCount: Int) -> CGFloat {
        let lanes = CGFloat(laneCount) * laneRowHeight + CGFloat(max(laneCount - 1, 0)) * laneSpacing
        return axisHeight + eventsHeight + 11 + 8 + lanes
    }

    /// The focused graph takes whatever height the window leaves after the rows under it.
    static func focusHeight(forTotal height: CGFloat, laneCount: Int) -> CGFloat {
        max(minimumFocusHeight, height - heightBelowFocus(laneCount: laneCount))
    }

    static var plotLeading: CGFloat { labelWidth + gap }
}
