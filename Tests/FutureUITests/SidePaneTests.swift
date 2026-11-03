import Foundation
import Testing
@testable import FutureKit
@testable import FutureUI

@MainActor
@Suite("Side pane")
struct SidePaneTests {
    @Test("The side pane's width stays between its minimum and what leaves the timeline room")
    func paneWidths() {
        #expect(SidePane.clamped(100, for: .slot, area: 1360) == SidePane.minimumWidth)
        #expect(SidePane.clamped(100, for: .formula, area: 1360) == SidePane.minimumFormulaWidth)
        #expect(SidePane.clamped(5000, for: .slot, area: 1360) == 1360 - PanelView.paneGap - SidePane.timelineRoom)
        #expect(SidePane.clamped(400, for: .slot, area: 1360) == 400)
        // A narrow window still gives the pane its minimum, and an unreadable width falls back to the default.
        #expect(SidePane.clamped(400, for: .slot, area: 500) == SidePane.minimumWidth)
        #expect(SidePane.clamped(.nan, for: .slot, area: 1360) == SidePane.width)
    }
}
