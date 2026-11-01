import Foundation
import FutureEngine

/// Drag the future (docs/UI.md, 5.2): a target set by dragging the focused slot's line after now,
/// and the ranked ways to reach it.
public struct GoalState: Equatable, Sendable {
    /// A choice in one of the card's menus.
    public struct Option: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
    }

    /// One way to reach the target.
    public struct Fix: Identifiable, Equatable, Sendable {
        public let id: String
        /// "Monthly deposit $1,050 from Jan 2027".
        public let title: String
        /// "+$650 from $400".
        public let detail: String
        /// How big a change it is, for ranking: a share of the value's range, or of the line's size.
        public let size: Double
        /// What the line reaches at the target's date with it, as written: "$250,000".
        public let reaches: String
        public let line: [Sample]
        public let event: Event
    }

    public enum Phase: Equatable, Sendable {
        case solving
        case solved
    }

    public let slot: UUID
    /// Where the target is.
    public let date: Date
    public var target: Double
    /// The line's value at the target's date as it is, once the engine says.
    public var current: Double?
    /// What may change: "anything", a parameter ("p:monthly") or a kind of one-off event ("e:deposit").
    public var change: String
    public let changeOptions: [Option]
    /// When the change starts.
    public var start: Date
    public let startOptions: [Date]
    /// The fixes found, smallest change first.
    public var fixes: [Fix]
    public var selected: Int
    public var phase: Phase
    /// Whether the target is being dragged now.
    public var isDragging: Bool

    public var selectedFix: Fix? { fixes.indices.contains(selected) ? fixes[selected] : nil }
}

/// What the focused graph draws for Drag the future: the target, the line as it is there, and the gap.
public struct GoalMark: Sendable {
    public let date: Date
    public let target: Double
    public let current: Double?
    /// "$250,000 by Jan 2040".
    public let label: String
    /// "+$86,860", or nil until the line's value there is known.
    public let gap: String?
    public let isDragging: Bool
}

extension ScenarioStore {
    /// How many fixes the card lists.
    static let goalFixLimit = 5

    // MARK: Starting and dragging

    /// Whether a target can be set on the focused slot at `date`: it runs, and `date` is after now.
    public func canSetGoal(at date: Date) -> Bool {
        isSlot(focusedIndex) && !focused.isPaused && date > now && !startOptions(before: date).isEmpty
    }

    /// Starts a target on the focused slot's line at `date`, at `value`: the line's value there
    /// when a drag starts on it (docs/UI.md, 5.2).
    public func beginGoal(at date: Date, value: Double) {
        // Dragging the target again picks it up where it is.
        if var state = goal, state.slot == focused.id, state.date == date {
            goalDomain = timelineState().focus.yDomain
            state.isDragging = true
            goal = state
            return
        }
        guard canSetGoal(at: date), value.isFinite else { return }
        let index = focusedIndex, slot = slots[index]
        closeRefit()
        closePredict()
        cancelReadingImport()
        if editingEvent != nil { stopEditingEvent() }
        let starts = startOptions(before: date)
        goalDomain = timelineState().focus.yDomain
        goal = GoalState(slot: slot.id, date: date, target: value, current: nil, change: "anything",
                         changeOptions: changeOptions(slotAt: index), start: starts[0], startOptions: starts,
                         fixes: [], selected: 0, phase: .solving, isDragging: true)
        requestGoalSolve()
    }

    /// Moves the target while it's dragged. The solver runs again for each new target; one still
    /// waiting is replaced, so it keeps up at its own pace.
    public func dragGoal(to value: Double) {
        guard var state = goal, value.isFinite else { return }
        // Round to a step of the graph's range, so the target reads $250,000 rather than $249,873.
        var value = value
        if let domain = goalDomain {
            let span = domain.upperBound - domain.lowerBound
            if span.isFinite, span > 0 {
                let unit = pow(10, (log10(span / 200)).rounded(.down))
                if unit.isFinite, unit > 0 { value = (value / unit).rounded() * unit }
            }
        }
        guard state.target != value else { return }
        state.target = value
        goal = state
        requestGoalSolve()
    }

    /// The drag let go: the graph's range takes in the target and the fix again.
    public func endGoalDrag() {
        guard var state = goal, state.isDragging else { return }
        state.isDragging = false
        goal = state
        goalDomain = nil
    }

    // MARK: The card

    public func setGoalChange(_ id: String) {
        guard var state = goal, state.change != id, state.changeOptions.contains(where: { $0.id == id }) else { return }
        state.change = id
        goal = state
        requestGoalSolve()
    }

    public func setGoalStart(_ date: Date) {
        guard var state = goal, state.start != date, state.startOptions.contains(date) else { return }
        state.start = date
        goal = state
        requestGoalSolve()
    }

    public func selectGoalFix(_ index: Int) {
        guard var state = goal, state.fixes.indices.contains(index), state.selected != index else { return }
        state.selected = index
        goal = state
    }

    /// ↑ and ↓ in the card.
    public func moveGoalSelection(by offset: Int) {
        guard let state = goal, !state.fixes.isEmpty else { return }
        selectGoalFix(min(max(state.selected + offset, 0), state.fixes.count - 1))
    }

    /// Adds the selected fix as an event, which undo takes back, and closes the card.
    public func applyGoalFix() {
        guard let state = goal, let fix = state.selectedFix, let index = slotIndex(id: state.slot) else { return }
        let title = slots[index].title
        cancelGoal()
        add(fix.event, toSlotAt: index)
        say("Added: \(fix.title). \(title) reaches \(fix.reaches) in \(DateText.monthYear(state.date)).")
    }

    /// Closes the card and drops the target, changing nothing.
    public func cancelGoal() {
        goalSequence += 1
        goalDomain = nil
        if goal != nil { goal = nil }
    }

    /// After slots change: closes the card if its slot is gone, paused or no longer focused, or
    /// solves again for the slot as it is now.
    func goalSlotsChanged() {
        guard let state = goal else { return }
        guard let index = slotIndex(id: state.slot), index == focusedIndex, !slots[index].isPaused else {
            cancelGoal()
            return
        }
        requestGoalSolve()
    }

    // MARK: Choices

    /// When a change can start: the slot's next point after now, the next January, and three
    /// years on, while they're before the target.
    func startOptions(before date: Date) -> [Date] {
        guard descriptors.indices.contains(focusedIndex), let rate = descriptors[focusedIndex]?.stepRate else { return [] }
        let grid = TimeGrid(start: start, rate: rate)
        let next = grid.point((grid.lastIndex(atOrBefore: max(now, start)) ?? -1) + 1)
        let year = CivilDate(next).year
        let january = CivilDate.date(year: CivilDate(next).month == 1 && CivilDate(next).day == 1 ? year : year + 1, month: 1, day: 1)
        var options = [next]
        for candidate in [january, CivilDate.date(year: CivilDate(january).year + 3, month: 1, day: 1)]
        where candidate > options.last! { options.append(candidate) }
        return options.filter { $0 < date }
    }

    /// Anything, each parameter, and each kind of one-off event the slot takes.
    private func changeOptions(slotAt index: Int) -> [GoalState.Option] {
        let slot = slots[index]
        var options = [GoalState.Option(id: "anything", label: "Anything")]
        options += slot.parameterValues.map { GoalState.Option(id: "p:" + $0.name, label: $0.label) }
        options += slot.eventKinds.map { GoalState.Option(id: "e:" + $0, label: "One-off " + $0) }
        return options
    }

    // MARK: Solving

    /// Asks the engine to solve the changes the card allows, for the target as it is now.
    func requestGoalSolve() {
        guard var state = goal, let index = slotIndex(id: state.slot), isSlot(index) else { return }
        let slot = slots[index]
        var levers: [ScenarioEngine.GoalRequest.Lever] = []
        func parameter(_ value: SlotValue, from date: Date, later: Bool) {
            // Not rounded to the slider's step: $50 steps in a monthly deposit miss a target by
            // thousands after a few years.
            levers.append(.init(id: "p:\(value.name)@\(later ? "later" : "start")", lever: .parameter(value.name, from: date),
                                bounds: value.sliderRange, step: nil))
        }
        let later = state.startOptions.last.flatMap { $0 > state.start ? $0 : nil }
        for value in slot.parameterValues where state.change == "anything" || state.change == "p:" + value.name {
            parameter(value, from: state.start, later: false)
            if let later { parameter(value, from: later, later: true) }
        }
        for kind in slot.eventKinds where state.change == "anything" || state.change == "e:" + kind {
            levers.append(.init(id: "e:\(kind)@start", lever: .amount(kind: kind, at: state.start), bounds: nil, step: nil))
        }
        goalSequence += 1
        if state.phase != .solving {
            state.phase = .solving
            goal = state
        }
        let through = max(frame.end.addingTimeInterval(frame.span), state.date.addingTimeInterval(frame.span * 0.25))
        goalThrough = through
        requestGoal(ScenarioEngine.GoalRequest(version: revision, sequence: goalSequence, slot: index, variable: slot.variable,
                                               date: state.date, target: state.target, levers: levers, start: state.start,
                                               through: through))
    }

    /// After the view moves: asks again once the fixes' lines no longer reach past it.
    func extendGoalIfNeeded() {
        guard let state = goal, !state.isDragging, let through = goalThrough else { return }
        if frame.end.addingTimeInterval(frame.span * 0.25) > through { requestGoalSolve() }
    }

    func receiveGoal(_ result: ScenarioEngine.GoalResult) {
        guard result.sequence == goalSequence, result.version == revision, var state = goal,
              let index = slotIndex(id: state.slot) else { return }
        let slot = slots[index]
        let selectedID = state.selectedFix?.id
        state.current = result.current
        let scale = max(abs(result.atStart ?? 0), abs(state.target), abs(result.current ?? 0), 1e-12)
        var fixes: [GoalState.Fix] = []
        for found in result.fixes {
            let solution = found.solution
            let month = DateText.monthYear(solution.lever.date)
            let reaches = slot.style.full(solution.achieved)
            switch solution.lever {
            case .parameter(let name, _):
                guard let value = slot.parameterValues.first(where: { $0.name == name }), solution.input != solution.before else { continue }
                let change = solution.input - solution.before
                let width = value.sliderRange.map { $0.upperBound - $0.lowerBound } ?? max(abs(solution.before), 1e-12)
                let difference = value.quantity == .percent
                    ? ValueStyle.number.full(abs(change) * 100) + " points"
                    : value.text(abs(change))
                var detail = (change > 0 ? "+" : "−") + difference + " from " + value.text(solution.before)
                if found.id.hasSuffix("@later") { detail += ". Starts later, so it changes more." }
                fixes.append(GoalState.Fix(id: found.id, title: "\(value.label) \(value.text(solution.input)) from \(month)",
                                           detail: detail, size: abs(change) / width, reaches: reaches,
                                           line: found.line, event: solution.event))
            case .amount(let kind, _):
                guard solution.input > 0 else { continue }
                fixes.append(GoalState.Fix(id: found.id, title: "One \(kind) of \(slot.money.full(solution.input)) in \(month)",
                                           detail: "Once, then everything as before", size: solution.input / scale,
                                           reaches: reaches, line: found.line, event: solution.event))
            }
        }
        fixes.sort { $0.size < $1.size }
        state.fixes = Array(fixes.prefix(Self.goalFixLimit))
        state.selected = state.fixes.firstIndex { $0.id == selectedID } ?? 0
        state.phase = .solved
        if goal != state { goal = state }
    }

    // MARK: Drawing

    /// The target, the line's value there and the gap, for the focused graph.
    func goalMark(forSlotAt index: Int) -> GoalMark? {
        guard let state = goal, slots.indices.contains(index), state.slot == slots[index].id else { return nil }
        let style = slots[index].style
        let gap = state.current.map { current -> String in
            let difference = state.target - current
            return (difference >= 0 ? "+" : "−") + style.full(abs(difference)).replacingOccurrences(of: "−", with: "")
        }
        return GoalMark(date: state.date, target: state.target, current: state.current,
                        label: "\(style.full(state.target)) by \(DateText.monthYear(state.date))", gap: gap,
                        isDragging: state.isDragging)
    }

    /// "Reaching $250,000 by Jan 2040 needs +$86,860 more than the current projection of $163,140."
    public func goalSummary() -> String? {
        guard let state = goal, let index = slotIndex(id: state.slot), let mark = goalMark(forSlotAt: index) else { return nil }
        guard let current = state.current, let gap = mark.gap else { return "Reaching \(mark.label)…" }
        let style = slots[index].style
        if abs(state.target - current) <= 1e-9 * max(abs(current), 1) {
            return "\(slots[index].title) is already at \(mark.label)."
        }
        let more = state.target > current ? "more" : "less"
        return "Reaching \(mark.label) needs \(gap.dropFirst()) \(more) than the current projection of \(style.full(current))."
    }
}
