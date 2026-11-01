import SwiftUI
import FutureEngine

/// Where values go on the focused graph, for views placed over it.
private struct GraphMapping {
    let frame: TimeFrame
    let domain: ClosedRange<Double>
    let size: CGSize

    func x(_ date: Date) -> CGFloat { frame.x(date, width: size.width) }

    /// Kept within the graph, so a target dragged past its edge stays in sight.
    func y(_ value: Double) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        let y = size.height * (1 - CGFloat((value - domain.lowerBound) / (span == 0 ? 1 : span)))
        return min(max(y.isFinite ? y : 0, 0), size.height)
    }

    /// The value that a vertical move of `points` adds (down is less).
    func value(movedBy points: CGFloat) -> Double {
        -Double(points / size.height) * (domain.upperBound - domain.lowerBound)
    }
}

/// Drag the future on the graph (docs/UI.md, 5.2): the line's value at the target's date as it is,
/// the gap to the target with its amount, and the target with its label. The dashed path and the
/// guide line are drawn by the graph itself.
struct GoalOverlay: View {
    let goal: GoalMark
    let frame: TimeFrame
    let domain: ClosedRange<Double>
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let map = GraphMapping(frame: frame, domain: domain, size: geometry.size)
            let x = map.x(goal.date), targetY = map.y(goal.target)
            ZStack(alignment: .topLeading) {
                if let current = goal.current {
                    let currentY = map.y(current)
                    // The gap: a bracket from the line to the target, with its amount beside it.
                    Path { path in
                        path.move(to: CGPoint(x: x - 14, y: currentY))
                        path.addLine(to: CGPoint(x: x - 14, y: targetY))
                        path.move(to: CGPoint(x: x - 18, y: currentY))
                        path.addLine(to: CGPoint(x: x - 10, y: currentY))
                        path.move(to: CGPoint(x: x - 18, y: targetY))
                        path.addLine(to: CGPoint(x: x - 10, y: targetY))
                    }
                    .stroke(Theme.proposal, lineWidth: 1.4)
                    if let gap = goal.gap, abs(currentY - targetY) > 14 {
                        Text(gap)
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.proposal)
                            .padding(.horizontal, 4)
                            .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .position(x: x - 22, y: (currentY + targetY) / 2)
                            .offset(x: -labelHalfWidth(gap))
                    }
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .background(Circle().fill(Theme.panel))
                        .frame(width: 9, height: 9)
                        .position(x: x, y: currentY)
                }
                Circle()
                    .fill(Theme.proposal)
                    .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.proposal.opacity(0.22)).frame(width: 30, height: 30))
                    .position(x: x, y: targetY)
                Text(goal.label)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Color(hex: "#14161B"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: 8))
                    .fixedSize()
                    .position(x: min(max(x, 90), geometry.size.width - 90), y: targetY < 44 ? targetY + 34 : targetY - 30)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target \(goal.label)" + (goal.gap.map { ", \($0) from the projection" } ?? ""))
    }

    /// About half a label's width, so it ends just left of the bracket.
    private func labelHalfWidth(_ text: String) -> CGFloat { CGFloat(text.count) * 3.6 + 4 }
}

/// The grab handle (docs/UI.md, 5.2): on the focused line at the cursor, after now, it shows
/// when the pointer is over it, and dragging it up or down sets a target at that date. Once a
/// target is set, it sits on the target, so the target can be dragged again. It reads the cursor,
/// so it redraws as the pointer moves; the graph under it doesn't.
struct GoalHandle: View {
    let cursor: CursorSource
    let timeline: TimelineState
    let interactions: TimelineInteractions
    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let map = GraphMapping(frame: timeline.frame, domain: timeline.focus.yDomain, size: geometry.size)
            if let place = place() {
                Circle()
                    .strokeBorder(Theme.proposal, lineWidth: 2)
                    .background(Circle().fill(Theme.proposal.opacity(0.18)))
                    .frame(width: 16, height: 16)
                    .opacity(timeline.focus.goal == nil && (hovering || dragStart != nil) ? 1 : 0)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .onHover { hovering = $0 }
                    .grabPointer(active: dragStart != nil)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(PanelView.panelSpace))
                            .onChanged { value in
                                if dragStart == nil {
                                    dragStart = place.value
                                    interactions.beginGoal(place.date, place.value)
                                }
                                interactions.dragGoal(dragStart! + map.value(movedBy: value.translation.height))
                            }
                            .onEnded { _ in
                                dragStart = nil
                                interactions.endGoal()
                            })
                    .position(x: map.x(place.date), y: map.y(place.value))
                    .help(timeline.focus.goal == nil ? "Drag up or down to set a target here" : "Drag to move the target")
                    .accessibilityLabel("Set a target")
            }
        }
    }

    /// The target, or the line at the cursor when it's after now and a target can be set there.
    private func place() -> (date: Date, value: Double)? {
        if let goal = timeline.focus.goal { return (goal.date, goal.target) }
        let state = cursor.state
        guard timeline.focus.pausedReason == nil, state.date > timeline.now, let value = state.focusValue, value.isFinite,
              interactions.canSetGoal(state.date) else { return nil }
        return (state.date, value)
    }
}

extension View {
    /// The open hand over the grab handle, and the closed hand while dragging.
    @ViewBuilder func grabPointer(active: Bool) -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            pointerStyle(active ? .grabActive : .grabIdle)
        } else {
            onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
        }
        #else
        self
        #endif
    }
}

/// "Ways to get there", in the side pane while a target is set (docs/UI.md, 5.2): what may change
/// and from when, the fixes found, smallest change first, and Add event.
struct GoalCard: View {
    @Bindable var store: ScenarioStore
    let state: GoalState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ways to get there").font(.system(size: 15, weight: .semibold))
                if let summary = store.goalSummary() {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                menu("Change") {
                    Picker("Change", selection: Binding(get: { state.change }, set: { store.setGoalChange($0) })) {
                        ForEach(state.changeOptions) { Text($0.label).tag($0.id) }
                    }
                }
                menu("Starting") {
                    Picker("Starting", selection: Binding(get: { state.start }, set: { store.setGoalStart($0) })) {
                        ForEach(state.startOptions, id: \.self) { Text(DateText.monthYear($0)).tag($0) }
                    }
                }
            }
            fixes
            Spacer(minLength: 0)
            Text("Drag the target to move it · ↑↓ choose · ⌘↩ add · Esc cancel")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { store.cancelGoal() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add event") { store.applyGoalFix() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.selectedFix == nil)
                    .help(state.selectedFix.map { "Add “\($0.title)”  ⌘↩" } ?? "Nothing to add")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var fixes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.fixes.isEmpty {
                if state.phase == .solving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working out ways…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("No change of that kind reaches the target within its range. Try Anything, or start sooner.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(state.fixes.enumerated()), id: \.element.id) { index, fix in
                let selected = index == state.selected
                Button { store.selectGoalFix(index) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(fix.title).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if index == 0 {
                                Text("Smallest change")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color(hex: "#14161B"))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Theme.proposal, in: RoundedRectangle(cornerRadius: 4))
                                    .fixedSize()
                            }
                        }
                        Text(fix.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Theme.proposal.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Theme.proposal : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(fix.detail)
            }
            if state.phase == .solving, !state.fixes.isEmpty {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func menu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
