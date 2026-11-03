import SwiftUI
import FutureKit

/// What the clipboard image shows: the timeline without any controls.
public struct SnapshotView: View {
    let state: PanelState
    public static let width: CGFloat = 1120

    public init(state: PanelState) {
        self.state = state
    }

    public var body: some View {
        let plotWidth = TimelineLayout.plotWidth(forTotal: Self.width - 40)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(state.scenarioName).futureFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
                RoundedRectangle(cornerRadius: 3).fill(Color(state.focus.color)).frame(width: 10, height: 10)
                Text(state.focus.name).futureFont(18, weight: .semibold)
                OverlayLegend(overlays: state.timeline.overlays)
                Spacer()
                Text("\(DateText.monthYear(state.frame.start)) – \(DateText.monthYear(state.frame.end))")
                    .futureFont(12)
                    .foregroundStyle(Theme.secondary)
            }
            TimelineRows(timeline: state.timeline, cursor: .fixed(state.cursor), backdrop: .fixed(state.backdrop), plotWidth: plotWidth)
            Text("Edit The Future · \(state.nowText)")
                .futureFont(11)
                .foregroundStyle(Theme.secondary)
                .padding(.top, 6)
        }
        .padding(20)
        .frame(width: Self.width, alignment: .topLeading)
        .foregroundStyle(Theme.text)
        .background(Theme.panel)
        .futureAppearance()
    }
}
