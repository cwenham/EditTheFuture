import SwiftUI

/// The keys the panel's tooltips and badges name, so they say what Settings has chosen
/// (docs/UI.md, 4.1). Nil means the shortcut is turned off.
public struct ShortcutLabels: Equatable, Sendable {
    public var commandBar: String? = "⌘K"
    public var slotTab: String? = "⌘I"
    public var formulaTab: String? = "⌥⌘I"
    public var addEvent: String? = "E"
    public var jumpToNow: String? = "T"

    public init() {}

    /// "Jump to now  T", or just the text when there's no shortcut.
    func help(_ text: String, _ key: String?) -> String { key.map { text + "  " + $0 } ?? text }
}

extension EnvironmentValues {
    /// The panel's shortcuts, as its tooltips name them.
    @Entry public var shortcutLabels = ShortcutLabels()
}

#if os(macOS)
import AppKit

/// A key with modifiers, such as ⌃⌥Space or ⌘K (docs/UI.md, 4.1 and 4.2).
public struct KeyShortcut: Codable, Hashable, Sendable {
    /// The key's virtual key code, as `NSEvent.keyCode` gives it.
    public var keyCode: UInt16
    /// ⌃, ⌥, ⇧ and ⌘, as `NSEvent.ModifierFlags`' raw value.
    public var modifiers: UInt
    /// What the key is called: "Space", "C", "F5", "+".
    public var key: String

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowed).rawValue
        self.key = key
    }

    /// The shortcut a key press makes for an action in `scope`, or nil when it can't have it.
    /// One that works from any app needs ⌃, ⌥ or ⌘: a plain key, or one with only ⇧, would take
    /// that key from every app. In the panel any key will do.
    public init?(event: NSEvent, for scope: ShortcutSettings.Scope = .anywhere) {
        var flags = event.modifierFlags.intersection(Self.allowed)
        if scope == .anywhere {
            guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        }
        let key = Self.keyName(code: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard !key.isEmpty else { return nil }
        // In the panel keys are matched by what they type, so ⇧ is already in a symbol: ⇧= types
        // "+", and ⌘+ should work on any keyboard. Registering from any app goes by the key itself.
        if scope != .anywhere, Self.typesSymbol(key) { flags.remove(.shift) }
        self.init(keyCode: event.keyCode, modifiers: flags, key: key)
    }

    static let allowed: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    public var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥Space", with the modifiers in the Mac's order.
    public var text: String {
        let flags = flags
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    /// The same key and modifiers, whatever key code recorded it.
    func sameKeys(as other: KeyShortcut) -> Bool { key == other.key && modifiers == other.modifiers }

    /// Whether the key holds ⌘ or ⌃, so it can be a shortcut while text is being typed.
    var commandsText: Bool { !flags.intersection([.command, .control]).isEmpty }

    /// Keys that type nothing, or something unreadable, by name; others as they're typed.
    static func keyName(code: UInt16, characters: String?) -> String {
        if let name = named[code] { return name }
        return (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static let named: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    /// A key that types one character that isn't a letter, such as "+", "1" or ",".
    static func typesSymbol(_ key: String) -> Bool {
        key.count == 1 && !named.values.contains(key) && !key.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }

    static let arrows: Set<String> = ["←", "→", "↑", "↓"]

    /// What the key does everywhere on the Mac, such as Copy for ⌘C, if it's one Settings
    /// can't give to anything else.
    public var macAction: String? {
        switch (flags, key) {
        case (.command, "C"): "Copy"
        case (.command, "V"): "Paste"
        case (.command, "X"): "Cut"
        case (.command, "A"): "Select All"
        case (.command, "Z"): "Undo"
        case ([.shift, .command], "Z"): "Redo"
        case (.command, ","): "Settings"
        case (.command, "Q"): "Quit"
        default: nil
        }
    }

    /// Escape, which cancels a recording.
    static let escape: UInt16 = 53
}

/// Kept for apps that embed the package and used the earlier name.
public typealias GlobalShortcut = KeyShortcut

/// The app's keyboard shortcuts, chosen in Settings and remembered between launches: those that
/// work from any app, which the app registers (saying which the Mac wouldn't let it have, in
/// `unavailable`), and those the panel and its graph answer to.
@MainActor
@Observable
public final class ShortcutSettings {
    /// Where a shortcut works.
    public enum Scope: Sendable, CaseIterable {
        /// From any app, while the app runs.
        case anywhere
        /// In the panel, even while typing, if it holds ⌘ or ⌃.
        case panel
        /// Over the graph, when no text field is being typed in.
        case graph
    }

    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case showPanel, copySnapshot, addEvent
        case commandBar = "panel.commandBar", slotTab = "panel.slotTab", formulaTab = "panel.formulaTab"
        case copyData = "panel.copyData"
        case largerText = "panel.largerText", smallerText = "panel.smallerText", standardText = "panel.standardText"
        case cursorBack = "graph.cursorBack", cursorForward = "graph.cursorForward"
        case yearBack = "graph.yearBack", yearForward = "graph.yearForward"
        case jumpToNow = "graph.jumpToNow", addEventAtCursor = "graph.addEvent"
        case zoomIn = "graph.zoomIn", zoomOut = "graph.zoomOut"

        public var id: String { rawValue }

        public var scope: Scope {
            switch self {
            case .showPanel, .copySnapshot, .addEvent: .anywhere
            case .commandBar, .slotTab, .formulaTab, .copyData, .largerText, .smallerText, .standardText: .panel
            case .cursorBack, .cursorForward, .yearBack, .yearForward, .jumpToNow, .addEventAtCursor, .zoomIn, .zoomOut: .graph
            }
        }

        public static func all(in scope: Scope) -> [Action] { allCases.filter { $0.scope == scope } }

        public var title: String {
            switch self {
            case .showPanel: "Show or hide the panel"
            case .copySnapshot: "Copy a snapshot"
            case .addEvent: "Add an event at now"
            case .commandBar: "Type a command"
            case .slotTab: "Show the Slot tab"
            case .formulaTab: "Show the Formula tab"
            case .copyData: "Copy the data"
            case .largerText: "Make the text larger"
            case .smallerText: "Make the text smaller"
            case .standardText: "Put the text back to its standard size"
            case .cursorBack: "Move the cursor back"
            case .cursorForward: "Move the cursor forward"
            case .yearBack: "Move the cursor back a year"
            case .yearForward: "Move the cursor forward a year"
            case .jumpToNow: "Jump to now"
            case .addEventAtCursor: "Add an event at the cursor"
            case .zoomIn: "Zoom in"
            case .zoomOut: "Zoom out"
            }
        }

        public var detail: String? {
            switch self {
            case .showPanel: "Tap to show or hide it; hold to peek while you keep working in another app."
            case .slotTab: "Pressed again, it goes back to the Event tab."
            case .cursorBack, .cursorForward: "By a step at the graph’s scale."
            default: nil
            }
        }

        /// The standard shortcut, then any others that also work while it's in use: ⌘= as well
        /// as ⌘+, since + takes ⇧ on many keyboards.
        public var standards: [KeyShortcut] {
            func key(_ code: UInt16, _ name: String, _ flags: NSEvent.ModifierFlags = []) -> KeyShortcut {
                KeyShortcut(keyCode: code, modifiers: flags, key: name)
            }
            return switch self {
            case .showPanel: [key(49, "Space", [.control, .option])]
            case .copySnapshot: [key(8, "C", [.control, .option])]
            case .addEvent: [key(14, "E", [.control, .option])]
            case .commandBar: [key(40, "K", .command)]
            case .slotTab: [key(34, "I", .command)]
            case .formulaTab: [key(34, "I", [.option, .command])]
            case .copyData: [key(8, "C", [.shift, .command])]
            case .largerText: [key(24, "+", .command), key(24, "=", .command)]
            case .smallerText: [key(27, "-", .command)]
            case .standardText: [key(29, "0", .command)]
            case .cursorBack: [key(123, "←")]
            case .cursorForward: [key(124, "→")]
            case .yearBack: [key(123, "←", .shift)]
            case .yearForward: [key(124, "→", .shift)]
            case .jumpToNow: [key(17, "T")]
            case .addEventAtCursor: [key(14, "E")]
            case .zoomIn: [key(24, "+"), key(24, "=")]
            case .zoomOut: [key(27, "-")]
            }
        }

        public var standard: KeyShortcut { standards[0] }

        /// Taken from a text field only if it can't do the same itself.
        var yieldsToText: Bool { self == .copyData }
    }

    /// Each action's shortcut, where it isn't the standard one; nil inside means turned off.
    private var chosen: [Action: KeyShortcut?]
    private var refused: Set<Action> = []
    private var recording = false
    @ObservationIgnored private let defaults: UserDefaults

    static let key = "EditTheFuture.settings.shortcuts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: KeyShortcut?].self, from: $0) } ?? [:]
        chosen = Dictionary(uniqueKeysWithValues: stored.compactMap { name, shortcut in Action(rawValue: name).map { ($0, shortcut) } })
    }

    /// The action's shortcut, or nil when it's turned off.
    public func shortcut(for action: Action) -> KeyShortcut? {
        if let own = chosen[action] { return own }
        return action.standard
    }

    /// Gives an action a shortcut, or turns it off with nil. Another action with the same keys
    /// loses them, so a key press never means two things.
    public func setShortcut(_ shortcut: KeyShortcut?, for action: Action) {
        guard self.shortcut(for: action) != shortcut else { return }
        var new = chosen
        if let shortcut {
            for other in Action.allCases where other != action && self.shortcut(for: other)?.sameKeys(as: shortcut) == true {
                new[other] = .some(nil)
            }
        }
        new[action] = shortcut == action.standard ? nil : .some(shortcut)
        chosen = new
        save()
    }

    public var isStandard: Bool { chosen.isEmpty }

    /// Whether every action in `scope` has its standard shortcut.
    public func isStandard(in scope: Scope) -> Bool { !chosen.keys.contains { $0.scope == scope } }

    /// Every action back to its standard shortcut.
    public func reset() {
        guard !chosen.isEmpty else { return }
        chosen = [:]
        save()
    }

    /// The actions in `scope` back to their standard shortcuts.
    public func reset(_ scope: Scope) {
        guard !isStandard(in: scope) else { return }
        chosen = chosen.filter { $0.key.scope != scope }
        save()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    /// The action in `scope` that a key press asks for, if any.
    public func action(for event: NSEvent, in scope: Scope) -> Action? {
        Self.action(for: event, in: scope, shortcut: shortcut(for:))
    }

    /// The action in `scope` that a key press asks for with the standard shortcuts.
    public static func standardAction(for event: NSEvent, in scope: Scope) -> Action? {
        action(for: event, in: scope, shortcut: { $0.standard })
    }

    private static func action(for event: NSEvent, in scope: Scope, shortcut: (Action) -> KeyShortcut?) -> Action? {
        guard event.type == .keyDown, let pressed = KeyShortcut(event: event, for: scope) else { return nil }
        let actions = Action.all(in: scope)
        if let action = actions.first(where: { shortcut($0)?.sameKeys(as: pressed) == true }) { return action }
        // The other standard keys work while the action keeps its standard shortcut, unless
        // another action has been given them.
        return actions.first { action in
            shortcut(action) == action.standard && action.standards.dropFirst().contains { $0.sameKeys(as: pressed) }
        }
    }

    /// Whether a panel action can take a key press while text is being typed: only with ⌘ or ⌃,
    /// and never the keys a text field uses itself.
    public static func takesWhileTyping(_ action: Action, _ event: NSEvent) -> Bool {
        guard !action.yieldsToText, let pressed = KeyShortcut(event: event, for: .panel), pressed.commandsText else { return false }
        if KeyShortcut.arrows.contains(pressed.key) { return false }
        let editing: Set<String> = ["A", "C", "V", "X", "Z"]
        return !(pressed.flags.subtracting(.shift) == .command && editing.contains(pressed.key))
    }

    /// What the panel's tooltips name.
    public var labels: ShortcutLabels {
        var labels = ShortcutLabels()
        labels.commandBar = shortcut(for: .commandBar)?.text
        labels.slotTab = shortcut(for: .slotTab)?.text
        labels.formulaTab = shortcut(for: .formulaTab)?.text
        labels.addEvent = shortcut(for: .addEventAtCursor)?.text
        labels.jumpToNow = shortcut(for: .jumpToNow)?.text
        return labels
    }

    /// The actions whose shortcuts the Mac refused, usually because another app has them.
    public var unavailable: Set<Action> {
        get { refused }
        set { if newValue != refused { refused = newValue } }
    }

    /// While a new shortcut is being typed in Settings, the app lets its shortcuts go, so
    /// typing one of them records it rather than doing it.
    public var isRecording: Bool {
        get { recording }
        set { if newValue != recording { recording = newValue } }
    }
}

/// A button that shows a shortcut and records a new one when clicked: the next key press becomes
/// the shortcut (with ⌃, ⌥ or ⌘ for one that works from any app), and Esc leaves it as it was.
struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    let scope: ShortcutSettings.Scope
    @Binding var isRecording: Bool
    let onChange: (KeyShortcut?) -> Void
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { isRecording ? stop() : start() } label: {
                    Text(isRecording ? "Type a shortcut…" : shortcut?.text ?? "Off")
                        .monospacedDigit()
                        .frame(minWidth: 130)
                }
                .accessibilityLabel(isRecording ? "Recording a shortcut" : "Shortcut: " + (shortcut?.text ?? "off"))
                .accessibilityHint("Click, then type the new shortcut")
                if shortcut != nil && !isRecording {
                    Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Turn this shortcut off")
                        .accessibilityLabel("Turn off")
                }
            }
            if isRecording, let hint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isRecording) { if !isRecording { removeMonitor() } }
        .onDisappear { stop() }
    }

    private func start() {
        hint = switch scope {
        case .anywhere: "Hold ⌃, ⌥ or ⌘ and press a key. Esc cancels."
        case .panel: "Press a key, usually with ⌘. Esc cancels."
        case .graph: "Press a key, with or without modifiers. Esc cancels."
        }
        isRecording = true
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyShortcut.escape && event.modifierFlags.intersection(KeyShortcut.allowed).isEmpty {
                stop()
            } else if let recorded = KeyShortcut(event: event, for: scope) {
                if let mac = recorded.macAction {
                    hint = "\(recorded.text) is always \(mac), so choose another."
                } else {
                    onChange(recorded)
                    stop()
                }
            } else {
                hint = "A shortcut that works from any app needs ⌃, ⌥ or ⌘, so it doesn't take a key from other apps."
            }
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if isRecording { isRecording = false }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutSettingsPane: View {
    @Bindable var shortcuts: ShortcutSettings
    @State private var recordingAction: ShortcutSettings.Action?

    var body: some View {
        section(.anywhere, title: "From any app")
            .onChange(of: recordingAction) { shortcuts.isRecording = recordingAction != nil }
            .onDisappear { shortcuts.isRecording = false }
        section(.panel, title: "In the panel", note: "While you’re typing, only those with ⌘ or ⌃ work, and copying the data waits until you aren’t.")
        section(.graph, title: "Over the graph", note: "These work when you aren’t typing in a text field.")

        SettingsSection(title: "Always the same") {
            Text("⌘C copies a snapshot, ⌘Z and ⇧⌘Z undo and redo (in a text field, they’re its own), and ⌘, opens Settings. Esc leaves the text field, then drops a Drag the future target, then hides the panel. ⌘↩ adds the chosen fix or applies a sheet. While Drag the future shows its fixes, ↑ and ↓ choose among them. Over the graph, 1–8 focus a slot.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
            Button("Use Standard Shortcuts") { shortcuts.reset() }
                .disabled(shortcuts.isStandard)
                .padding(.top, 6)
        }
    }

    private func section(_ scope: ShortcutSettings.Scope, title: String, note: String? = nil) -> some View {
        SettingsSection(title: title) {
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            ForEach(ShortcutSettings.Action.all(in: scope)) { action in
                row(action)
            }
        }
    }

    private func row(_ action: ShortcutSettings.Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let detail = action.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if shortcuts.unavailable.contains(action) {
                    Text("Another app is using this shortcut, so it does nothing here. Choose another.")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 250, alignment: .leading)
            ShortcutRecorder(shortcut: shortcuts.shortcut(for: action), scope: action.scope,
                             isRecording: Binding(get: { recordingAction == action },
                                                  set: { recordingAction = $0 ? action : (recordingAction == action ? nil : recordingAction) }),
                             onChange: { shortcuts.setShortcut($0, for: action) })
        }
        .padding(.bottom, 4)
    }
}
#endif
