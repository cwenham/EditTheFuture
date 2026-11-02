import Foundation
#if os(macOS)
import AppKit
#endif

/// What a click on a slot's chip or lane does, from the keys held, as in Finder (docs/UI.md, 5.12).
public enum SlotClick: Sendable, Equatable {
    /// A plain click: focus that slot, alone.
    case only
    /// ⌘: draw the slot over the graph, or take it off.
    case toggle
    /// ⇧: draw every slot from the focused one to this one.
    case range

    /// The click for the keys held, or nil with ⌃, which makes a click a right-click on the Mac.
    public init?(command: Bool, shift: Bool, control: Bool) {
        guard !control else { return nil }
        self = command ? .toggle : shift ? .range : .only
    }

    /// From the keys held now: nil for a ⌃-click, which is a right-click. On a chip that opens
    /// its menu; on a lane it does nothing, as a right-click does there.
    @MainActor public static var current: SlotClick? {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return SlotClick(command: flags.contains(.command), shift: flags.contains(.shift), control: flags.contains(.control))
        #else
        return .only
        #endif
    }
}

extension ScenarioStore {
    /// Whether a slot is drawn over the focused graph.
    public func isOverlaid(_ id: UUID) -> Bool { overlaidIDs.contains(id) }

    /// The slots drawn over the focused graph, by index, in the order they were added.
    var overlaidIndices: [Int] {
        overlaidIDs.compactMap { id in slots.firstIndex { $0.id == id } }.filter { $0 != focusedIndex }
    }

    /// A click on a slot's chip or lane (docs/UI.md, 5.12):
    /// - plain: focus it, and take every other line off the graph;
    /// - toggle: draw it over the graph, or take it off. On the focused slot, the slot added last
    ///   takes the focus, unless it's the only one shown;
    /// - range: draw every slot from the focused one to it, by position, keeping the rest.
    public func select(index: Int, click: SlotClick) {
        guard slots.indices.contains(index) else { return }
        let id = slots[index].id
        switch click {
        case .only:
            setOverlays([])
            focus(index: index)
        case .toggle:
            if index == focusedIndex {
                guard let next = overlaidIDs.last, let nextIndex = slotIndex(id: next) else { return }
                setOverlays(overlaidIDs.dropLast())
                focus(index: nextIndex)
            } else if overlaidIDs.contains(id) {
                setOverlays(overlaidIDs.filter { $0 != id })
            } else {
                setOverlays(overlaidIDs + [id])
            }
        case .range:
            guard slots.indices.contains(focusedIndex) else { return }
            let ends = (focused.key, slots[index].key)
            let keys = min(ends.0, ends.1)...max(ends.0, ends.1)
            let added = slots.filter { keys.contains($0.key) && $0.id != focused.id && !overlaidIDs.contains($0.id) }
                .sorted { $0.key < $1.key }
                .map(\.id)
            setOverlays(overlaidIDs + added)
        }
    }

    /// Takes every other line off the focused graph.
    public func clearOverlays() { setOverlays([]) }

    /// Sets the overlays only when they change, so views that read them don't redraw for nothing.
    func setOverlays<List: Sequence<UUID>>(_ list: List) {
        let new = Array(list)
        if new != overlaidIDs { overlaidIDs = new }
    }

    /// Drops overlays whose slots are gone or now focused, after the slot list changes.
    func pruneOverlays() {
        let focusedID = slots.indices.contains(focusedIndex) ? slots[focusedIndex].id : nil
        setOverlays(overlaidIDs.filter { id in id != focusedID && slots.contains { $0.id == id } })
    }
}

extension ValueStyle {
    /// Whether values in both styles can share an axis: the same kind of value, in the same
    /// currency when they're money.
    func sharesAxis(with other: ValueStyle) -> Bool {
        format == other.format && (format != .currency || currency == other.currency)
    }
}
