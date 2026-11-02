import SwiftUI

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
                Text(state.scenarioName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                RoundedRectangle(cornerRadius: 3).fill(state.focus.color).frame(width: 10, height: 10)
                Text(state.focus.name).font(.system(size: 18, weight: .semibold))
                OverlayLegend(overlays: state.timeline.overlays)
                Spacer()
                Text("\(DateText.monthYear(state.frame.start)) – \(DateText.monthYear(state.frame.end))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            TimelineRows(timeline: state.timeline, cursor: .fixed(state.cursor), plotWidth: plotWidth)
            Text("Edit The Future · \(state.nowText)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 6)
        }
        .padding(20)
        .frame(width: Self.width, alignment: .topLeading)
        .foregroundStyle(Theme.text)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }
}
