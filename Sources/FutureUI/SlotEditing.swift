import Foundation
import FutureEngine
import FutureFormula

/// Adding, changing, moving and removing slots, and setting their values (docs/UI.md, 5.7).
/// Every change here can be undone.
extension ScenarioStore {
    // MARK: Positions

    /// 0-based positions with no slot, in order.
    public var freePositions: [Int] {
        let taken = Set(configs.map(\.position))
        return (0..<Self.bankSize).filter { !taken.contains($0) }
    }

    /// Where a slot is in `slots` now. Views keep a slot's id, not its index: removing a slot
    /// moves the ones after it, and a view drawn before the header catches up would read past
    /// the end of the list.
    public func slotIndex(id: UUID) -> Int? {
        slots.firstIndex { $0.id == id }
    }

    /// Whether an index still points at a slot.
    func isSlot(_ index: Int) -> Bool {
        configs.indices.contains(index) && slots.indices.contains(index)
    }

    /// The slot at a 0-based position, if there is one.
    public func slotIndex(atPosition position: Int) -> Int? {
        slots.firstIndex { $0.key == position + 1 }
    }

    /// `base`, or `base` with the first number that makes it unique: "Savings", "Savings2".
    func uniqueName(_ base: String, ignoring id: UUID? = nil) -> String {
        let taken = Set(configs.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base)\(number)".lowercased()) { number += 1 }
        return "\(base)\(number)"
    }

    // MARK: The side pane and picker

    /// Shows the Slot tab for a slot (the focused one by default).
    public func showSlotSettings(forSlotAt index: Int? = nil) {
        if let index { focus(index: index) }
        if sidePane != .slot { sidePane = .slot }
    }

    /// ⌘I: the Slot tab, or back to the Event tab when it's showing.
    public func toggleSlotSettings() {
        sidePane = sidePane == .slot ? .event : .slot
    }

    public func openPicker(_ request: PickerRequest) {
        if case .change(let id) = request, let index = slots.firstIndex(where: { $0.id == id }) {
            showSlotSettings(forSlotAt: index)
        }
        if picker != request { picker = request }
    }

    public func closePicker() {
        if picker != nil { picker = nil }
    }

    // MARK: Adding and changing models

    /// Adds a library model with its defaults at a 0-based position (the first free one by
    /// default), focuses it and shows the Slot tab.
    @discardableResult
    public func addModel(_ template: ModelTemplate, atPosition position: Int? = nil) -> Bool {
        guard let position = position ?? freePositions.first, freePositions.contains(position) else {
            say("All \(Self.bankSize) slots are full. Remove one first.", isError: true)
            return false
        }
        let config = SlotConfig(position: position, name: uniqueName(template.slotName), model: template.name,
                                kind: template.kind, formula: template.formula, variable: template.variable,
                                format: template.format)
        closePicker()
        applySlotChange(configs + [config], focus: config.id)
        showSlotSettings()
        say("Added \(template.name) to slot \(position + 1) as \(displayName(config.name))")
        return true
    }

    /// Gives a slot a different library model. Its name, color, events and readings stay, and so
    /// do its own values wherever the new model has a value of the same name.
    public func changeModel(ofSlotAt index: Int, to template: ModelTemplate) {
        guard isSlot(index) else { return }
        var config = configs[index]
        let declared = (try? FormulaModel(template.formula)).map { Set($0.parameterNames + $0.startingValueNames) } ?? []
        config.model = template.name
        config.kind = template.kind
        config.formula = template.formula
        config.variable = template.variable
        config.format = template.format
        config.values = config.values.filter { declared.contains($0.key) }
        closePicker()
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
        say("\(slots[focusedIndex].title) now uses \(template.name)")
    }

    /// Says how many of a slot's events a different model wouldn't handle, or nil when they all apply.
    public func eventsThatWontApply(inSlotAt index: Int, with template: ModelTemplate) -> String? {
        guard isSlot(index) else { return nil }
        guard let model = try? FormulaModel(template.formula) else { return nil }
        let kinds = Set(model.handledEventKinds), parameters = Set(model.parameterNames)
        func applies(_ kind: String, _ values: [String: Double]) -> Bool {
            kind == Event.setKind ? values.keys.allSatisfy(parameters.contains) : kinds.contains(kind)
        }
        let config = configs[index]
        var skipped: [String] = []
        for event in config.events where !applies(event.kind, event.values) { skipped.append(event.kind) }
        for rule in config.rules where !applies(rule.kind, rule.values) { skipped.append(rule.kind) }
        guard !skipped.isEmpty else { return nil }
        let names = Set(skipped).sorted().map { $0 == Event.setKind ? "parameter" : $0 }
        let what = names.count == 1 ? "\(names[0]) event" : "event"
        return "\(skipped.count) \(what)\(skipped.count == 1 ? "" : "s") won't apply to this model. "
            + "\(skipped.count == 1 ? "It's" : "They're") kept, but ignored."
    }

    // MARK: Removing

    /// A scenario keeps at least one slot.
    public var canRemoveSlot: Bool { slots.count > 1 }

    /// Shows the removal question for a slot in the Slot tab.
    public func requestRemoval(ofSlotAt index: Int) {
        guard isSlot(index) else { return }
        guard canRemoveSlot else {
            say("A scenario needs at least one slot. Change its model instead.", isError: true)
            return
        }
        showSlotSettings(forSlotAt: index)
        if pendingRemoval != slots[index].id { pendingRemoval = slots[index].id }
    }

    public func cancelRemoval() {
        if pendingRemoval != nil { pendingRemoval = nil }
    }

    /// "Remove Climate and its 2 events? Energy bill reads Climate.temp, so it will pause."
    public func removalQuestion(forSlotAt index: Int) -> String {
        guard isSlot(index) else { return "" }
        let slot = slots[index], config = configs[index]
        let count = config.events.count + config.rules.count
        var text = "Remove \(slot.title)" + (count == 0 ? "?" : " and its \(count == 1 ? "event" : "\(count) events")?")
        let readers = readersOf(slotAt: index)
        if !readers.isEmpty {
            let names = readers.map { slots[$0.index].title }
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
            if readers.count == 1 {
                text += " \(list) reads \(readers[0].what), so it will pause."
            } else {
                text += " \(list) read from \(slot.name), so they will pause."
            }
        }
        return text + " You can undo this."
    }

    /// Slots that read a slot's values or events, with the first thing each reads ("Climate.temp").
    func readersOf(slotAt index: Int) -> [(index: Int, what: String)] {
        guard isSlot(index) else { return [] }
        let name = configs[index].name
        var readers: [(index: Int, what: String)] = []
        for (other, config) in configs.enumerated() where other != index {
            guard let descriptor = (try? config.makeModel())?.descriptor else { continue }
            if let input = descriptor.inputs.compactMap(\.source).first(where: { $0.slot == name }) {
                readers.append((other, "\(input.slot).\(input.variable)"))
            } else if let subscription = descriptor.subscriptions.first(where: { $0.slot == name }) {
                readers.append((other, "\(subscription.slot).\(subscription.kind)"))
            }
        }
        return readers
    }

    /// Removes a slot and its events. Its position becomes free; the other slots keep theirs.
    public func removeSlot(at index: Int) {
        guard isSlot(index) else { return }
        guard canRemoveSlot else {
            say("A scenario needs at least one slot. Change its model instead.", isError: true)
            return
        }
        let removed = configs[index]
        let title = slots[index].title
        let neighbour = configs.indices.filter { $0 != index }.min { abs($0 - index) < abs($1 - index) }.map { configs[$0].id }
        cancelRemoval()
        applySlotChange(configs.filter { $0.id != removed.id }, focus: neighbour)
        say("Removed \(title). Undo brings it back.")
    }

    // MARK: Names and positions

    /// Renames a slot from what people typed ("Rainy day fund" becomes `RainyDayFund`), updating
    /// the formulas that refer to it. Returns why it can't, or nil when it's done.
    @discardableResult
    public func renameSlot(at index: Int, to title: String) -> String? {
        guard isSlot(index) else { return nil }
        guard let name = formulaName(fromTitle: title) else { return "Names start with a letter, e.g. Rainy day fund." }
        let old = configs[index]
        guard name != old.name else { return nil }
        if configs.contains(where: { $0.id != old.id && $0.name.lowercased() == name.lowercased() }) {
            return "There's already a slot called \(displayName(name))."
        }
        var updated = configs
        updated[index].name = name
        var rewritten = 0
        for other in updated.indices where other != index {
            let (formula, count) = Self.renameReferences(in: updated[other].formula, from: old.name, to: name)
            if count > 0 {
                updated[other].formula = formula
                rewritten += 1
            }
        }
        applySlotChange(updated, focus: old.id)
        say("Renamed \(displayName(old.name)) to \(displayName(name))"
            + (rewritten == 0 ? "" : ", and updated \(rewritten) formula\(rewritten == 1 ? "" : "s") that read it"))
        return nil
    }

    /// Rewrites `Old.value` and `on Old.Kind:` references to another slot name. Returns the new
    /// formula and how many references changed.
    nonisolated static func renameReferences(in formula: String, from old: String, to new: String) -> (String, Int) {
        // A slot name starts a dotted reference: it isn't the second part of one (`event.amount`)
        // or the end of a longer name.
        let pattern = "(?<![A-Za-z0-9_.])" + NSRegularExpression.escapedPattern(for: old) + "(?=\\s*\\.)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (formula, 0) }
        let range = NSRange(formula.startIndex..., in: formula)
        let count = regex.numberOfMatches(in: formula, range: range)
        guard count > 0 else { return (formula, 0) }
        let replaced = regex.stringByReplacingMatches(in: formula, range: range,
                                                      withTemplate: NSRegularExpression.escapedTemplate(for: new))
        return (replaced, count)
    }

    /// Copies a slot, with its events, to the first free position.
    public func duplicateSlot(at index: Int) {
        guard isSlot(index) else { return }
        guard let position = freePositions.first else {
            say("All \(Self.bankSize) slots are full. Remove one first.", isError: true)
            return
        }
        var copy = configs[index]
        copy.id = UUID()
        copy.position = position
        copy.name = uniqueName(copy.name)
        copy.color = nil  // the new position's color, so the two are easy to tell apart
        copy.events = copy.events.map { var event = $0; event.id = UUID(); return event }
        copy.rules = copy.rules.map { var rule = $0; rule.id = UUID(); return rule }
        applySlotChange(configs + [copy], focus: copy.id)
        say("Copied \(slots[index].title) to slot \(position + 1)")
    }

    /// Moves a slot to a 0-based position, swapping with any slot already there.
    public func moveSlot(at index: Int, toPosition position: Int) {
        guard isSlot(index) else { return }
        guard (0..<Self.bankSize).contains(position), configs[index].position != position else { return }
        var updated = configs
        let from = updated[index].position
        if let other = updated.firstIndex(where: { $0.position == position }) { updated[other].position = from }
        updated[index].position = position
        let moved = configs[index]
        applySlotChange(updated, focus: moved.id)
        say("Moved \(displayName(moved.name)) to slot \(position + 1)")
    }

    /// A chip dropped on a position: moves the dragged slot there. Returns whether it moved.
    @discardableResult
    public func dropSlot(_ text: String?, atPosition position: Int) -> Bool {
        guard let text, let id = UUID(uuidString: text), let index = slots.firstIndex(where: { $0.id == id }),
              slots[index].key != position + 1 else { return false }
        moveSlot(at: index, toPosition: position)
        return true
    }

    // MARK: Values and display

    /// Sets the value a slot starts with for a parameter or starting value. nil puts back the
    /// formula's default.
    public func setStartingValue(_ name: String, to value: Double?, inSlotAt index: Int) {
        guard isSlot(index) else { return }
        if let value, !value.isFinite {
            say("That value is too big to use.", isError: true)
            return
        }
        var config = configs[index]
        config.values[name] = value
        guard config != configs[index] else { return }
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }

    /// Which of the model's values the graph shows.
    public func setDisplayedVariable(_ variable: String, inSlotAt index: Int) {
        guard isSlot(index) else { return }
        var config = configs[index]
        config.variable = variable
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }

    public func setFormat(_ format: ValueFormat, inSlotAt index: Int) {
        guard isSlot(index) else { return }
        var config = configs[index]
        config.format = format
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }

    /// A color of the slot's own, or nil for its position's palette color.
    public func setColor(_ hex: String?, inSlotAt index: Int) {
        guard isSlot(index) else { return }
        var config = configs[index]
        config.color = hex
        applySlotChange(configs.replacing(index, with: config), focus: config.id)
    }

    /// The parameter changes from a date in a slot's events: "Changes to 4.0% from Jun 2027".
    public func scheduledChanges(of value: SlotValue, inSlotAt index: Int) -> [String] {
        guard isSlot(index) else { return [] }
        return configs[index].events
            .filter { $0.kind == Event.setKind && $0.values[value.name] != nil }
            .sorted { $0.time < $1.time }
            .map { "Changes to \(value.text($0.values[value.name]!)) from \(DateText.monthYear($0.time))" }
    }

    /// Opens the Event tab ready to change a parameter from a date.
    public func beginParameterChange(_ name: String) {
        var draft = eventDraft
        draft.kind = .setParameter
        draft.parameter = name
        if draft != eventDraft { eventDraft = draft }
        requestEventFieldFocus()
    }

    // MARK: Slider previews

    /// While a slider is dragged: the focused graph shows the slot's line with this value, dashed.
    public func previewStartingValue(_ name: String, _ value: Double, inSlotAt index: Int) {
        guard isSlot(index) else { return }
        let config = configs[index]
        parameterDrag = ParameterDrag(slot: config.id, name: name, value: value)
        guard value.isFinite, !slots[index].isPaused else { return }
        var values = config.values
        values[name] = value
        guard let model = try? config.makeModel(values: values) else { return }
        parameterPreviewSequence += 1
        let margin: TimeInterval = 62 * 86_400
        let setup = ScenarioEngine.SlotSetup(name: config.name, variable: config.variable, model: model, key: "preview")
        requestPreview(ScenarioEngine.PreviewRequest(
            version: revision, sequence: parameterPreviewSequence, slot: index, change: .model(setup),
            from: max(start, frame.start.addingTimeInterval(-margin)), through: frame.end.addingTimeInterval(margin)))
    }

    /// When the slider is let go: applies the dragged value, or drops it.
    public func endStartingValuePreview(commit: Bool) {
        let drag = parameterDrag
        parameterDrag = nil
        parameterPreviewSequence += 1
        if !parameterPreview.isEmpty { parameterPreview = [] }
        guard commit, let drag, let index = configs.firstIndex(where: { $0.id == drag.slot }) else { return }
        setStartingValue(drag.name, to: drag.value, inSlotAt: index)
    }
}

extension Array {
    /// A copy with one element replaced.
    func replacing(_ index: Int, with element: Element) -> [Element] {
        var copy = self
        copy[index] = element
        return copy
    }
}
