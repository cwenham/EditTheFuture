#if os(macOS)
import AppKit
import SwiftUI

/// A key with modifiers that works from any app, such as ⌃⌥Space (docs/UI.md, 4.2).
public struct GlobalShortcut: Codable, Hashable, Sendable {
    /// The key's virtual key code, as `NSEvent.keyCode` gives it.
    public var keyCode: UInt16
    /// ⌃, ⌥, ⇧ and ⌘, as `NSEvent.ModifierFlags`' raw value.
    public var modifiers: UInt
    /// What the key is called: "Space", "C", "F5".
    public var key: String

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowed).rawValue
        self.key = key
    }

    /// The shortcut a key press makes, or nil without ⌃, ⌥ or ⌘: a shortcut of a plain key, or
    /// only ⇧, would take that key from every app.
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.allowed)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let key = Self.keyName(code: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard !key.isEmpty else { return nil }
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

    /// Keys that type nothing, or something unreadable, by name; others as they're typed.
    static func keyName(code: UInt16, characters: String?) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        if let name = named[code] { return name }
        return (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Escape (53, for cancelling a recording) and the keys that edit it (Delete, 51).
    static let escape: UInt16 = 53
}

/// The app's global shortcuts, chosen in Settings and remembered between launches. The app
/// registers them, and says which the Mac wouldn't let it have (`unavailable`).
@MainActor
@Observable
public final class ShortcutSettings {
    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case showPanel, copySnapshot, addEvent

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .showPanel: "Show or hide the panel"
            case .copySnapshot: "Copy a snapshot"
            case .addEvent: "Add an event at now"
            }
        }

        public var detail: String? {
            switch self {
            case .showPanel: "Tap to show or hide it; hold to peek while you keep working in another app."
            case .copySnapshot: nil
            case .addEvent: nil
            }
        }

        /// ⌃⌥Space, ⌃⌥C and ⌃⌥E.
        public var standard: GlobalShortcut {
            switch self {
            case .showPanel: GlobalShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space")
            case .copySnapshot: GlobalShortcut(keyCode: 8, modifiers: [.control, .option], key: "C")
            case .addEvent: GlobalShortcut(keyCode: 14, modifiers: [.control, .option], key: "E")
            }
        }
    }

    /// Each action's shortcut, where it isn't the standard one; nil inside means turned off.
    private var chosen: [Action: GlobalShortcut?]
    private var refused: Set<Action> = []
    private var recording = false
    @ObservationIgnored private let defaults: UserDefaults

    static let key = "EditTheFuture.settings.shortcuts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: GlobalShortcut?].self, from: $0) } ?? [:]
        chosen = Dictionary(uniqueKeysWithValues: stored.compactMap { name, shortcut in Action(rawValue: name).map { ($0, shortcut) } })
    }

    /// The action's shortcut, or nil when it's turned off.
    public func shortcut(for action: Action) -> GlobalShortcut? {
        if let own = chosen[action] { return own }
        return action.standard
    }

    /// Gives an action a shortcut, or turns it off with nil. Another action with the same
    /// shortcut loses it, so a key press never means two things.
    public func setShortcut(_ shortcut: GlobalShortcut?, for action: Action) {
        guard self.shortcut(for: action) != shortcut else { return }
        var new = chosen
        if let shortcut {
            for other in Action.allCases where other != action && self.shortcut(for: other) == shortcut { new[other] = .some(nil) }
        }
        new[action] = shortcut == action.standard ? nil : .some(shortcut)
        chosen = new
        save()
    }

    public var isStandard: Bool { chosen.isEmpty }

    /// Every action back to its standard shortcut.
    public func reset() {
        guard !chosen.isEmpty else { return }
        chosen = [:]
        save()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
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

/// A button that shows a shortcut and records a new one when clicked: the next key press with
/// ⌃, ⌥ or ⌘ becomes the shortcut, and Esc leaves it as it was.
struct ShortcutRecorder: View {
    let shortcut: GlobalShortcut?
    @Binding var isRecording: Bool
    let onChange: (GlobalShortcut?) -> Void
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
            }
        }
        .onChange(of: isRecording) { if !isRecording { removeMonitor() } }
        .onDisappear { stop() }
    }

    private func start() {
        hint = "Hold ⌃, ⌥ or ⌘ and press a key. Esc cancels."
        isRecording = true
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == GlobalShortcut.escape && event.modifierFlags.intersection(GlobalShortcut.allowed).isEmpty {
                stop()
            } else if let recorded = GlobalShortcut(event: event) {
                onChange(recorded)
                stop()
            } else {
                hint = "A shortcut needs ⌃, ⌥ or ⌘, so it doesn't take a key from other apps."
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
        SettingsSection(title: "Shortcuts that work from any app") {
            ForEach(ShortcutSettings.Action.allCases) { action in
                SettingRow(label: "", labelWidth: 0) {
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
                        ShortcutRecorder(shortcut: shortcuts.shortcut(for: action),
                                         isRecording: Binding(get: { recordingAction == action },
                                                              set: { recordingAction = $0 ? action : (recordingAction == action ? nil : recordingAction) }),
                                         onChange: { shortcuts.setShortcut($0, for: action) })
                    }
                }
                .padding(.bottom, 6)
            }
            Button("Use Standard Shortcuts") { shortcuts.reset() }
                .disabled(shortcuts.isStandard)
        }
        .onChange(of: recordingAction) { shortcuts.isRecording = recordingAction != nil }
        .onDisappear { shortcuts.isRecording = false }

        SettingsSection(title: "In the panel") {
            Text("⌘K command bar · ⌘I Slot tab · ⌥⌘I Formula tab · ⌘C copy a snapshot · ⇧⌘C copy data · ⌘Z undo · ⌘+ ⌘− ⌘0 text size · ⌘, Settings · Esc hide. Over the graph: ← → move the cursor (⇧ a year), T now, E add an event, + − zoom, 1–8 focus a slot.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
