#if os(macOS)
import AppKit
import FutureCommands
import FutureUI

/// Runs commands from any source (URL scheme now; hardware and the CLI later) against the panel,
/// asking first when the source isn't trusted for that kind of command (DESIGN.md, section 13).
@MainActor
final class CommandRouter {
    let panel: PanelController

    init(panel: PanelController) {
        self.panel = panel
    }

    var store: ScenarioStore { panel.store }

    func perform(_ command: Command, from source: CommandSource) {
        if command.requiresConfirmation(from: source), !confirm(command, source: source) { return }
        switch command {
        case .toggleWindow: panel.toggle()
        case .peek(.begin): panel.summonPressed()
        case .peek(.end): panel.summonReleased()
        case .selectSlot(let number): store.focus(index: number - 1)
        case .toggleSlotVisible, .soloSlot, .nextBank, .previousBank: break  // single bank for now
        case .scroll(let ticks): store.pan(by: Double(ticks) / 24)
        case .zoom(let ticks): store.zoom(by: pow(0.9, Double(ticks)))
        case .jumpToNow: store.jumpToNow()
        case .show(let timeline, let at):
            if let timeline, !store.focus(named: timeline) {
                store.say("There's no slot called \(timeline).", isError: true)
            }
            if let at { store.show(at.date) }
            panel.showFully()
        case .setWheelMode, .cycleWheelMode, .adjustParameter: break  // hardware arrives in M2
        case .insertEventAtCursor:
            panel.addEvent()
        case .undo: store.undo()
        case .redo: store.redo()
        case .copySnapshot: panel.copy(.everything)
        case .copyData: panel.copy(.dataOnly)
        }
    }

    private func confirm(_ command: Command, source: CommandSource) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow this link to change Edit The Future?"
        alert.informativeText = "A link asked to \(describe(command)). Only allow it if you opened the link yourself."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func describe(_ command: Command) -> String {
        switch command.category {
        case .clipboard: return "copy a snapshot to your clipboard"
        case .editing: return "edit your scenario"
        case .navigation: return "move the timeline"
        }
    }
}
#endif
