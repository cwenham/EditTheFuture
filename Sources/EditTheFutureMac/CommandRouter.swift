#if os(macOS)
import AppKit
import FutureCommands
import FutureUI

/// Runs commands from any source (links, the etf tool, Shortcuts; hardware later) against the
/// panel, asking first when the source isn't trusted for that kind of command (DESIGN.md, section 13).
/// Each command answers with what happened, for the etf tool to print and Siri to say.
@MainActor
final class CommandRouter {
    let panel: PanelController

    init(panel: PanelController) {
        self.panel = panel
    }

    var store: ScenarioStore { panel.store }

    /// Runs a command. `confirmed` is for a command its source has already asked about: Shortcuts
    /// asks in its own way before it edits.
    @discardableResult
    func perform(_ command: Command, from source: CommandSource, confirmed: Bool = false) async -> Reply {
        if command.requiresConfirmation(from: source), !confirmed, !confirm(command, source: source) {
            return .failed("Not allowed.")
        }
        switch command {
        case .toggleWindow:
            panel.toggle()
            return .done(panel.isVisible ? "Showed the panel." : "Hid the panel.")
        case .peek(.begin):
            panel.summonPressed()
            return .done("")
        case .peek(.end):
            panel.summonReleased()
            return .done("")
        case .selectSlot(let number):
            guard store.slots.contains(where: { $0.key == number }) else {
                store.focus(key: number)
                return .failed("Slot \(number) is empty.")
            }
            store.focus(key: number)
            return .done("Focused \(store.focused.title).")
        case .toggleSlotVisible, .soloSlot, .nextBank, .previousBank:
            return .failed("Mute, solo and banks aren't built yet.")
        case .scroll(let ticks):
            store.pan(by: Double(ticks) / 24)
            return .done("Scrolled.")
        case .zoom(let ticks):
            store.zoom(by: pow(0.9, Double(ticks)))
            return .done("Zoomed.")
        case .jumpToNow:
            store.jumpToNow()
            return .done("Cursor at now, \(ScenarioStore.monthYearText(store.cursor)).")
        case .show(let timeline, let at):
            if let timeline, !store.focus(named: timeline) {
                let message = "There's no slot called \(timeline). Slots: \(store.slots.map(\.title).joined(separator: ", "))."
                store.say(message, isError: true)
                panel.showFully()
                return .failed(message)
            }
            if let at { store.show(at.date) }
            panel.showFully()
            return .done("Showing \(store.focused.title) at \(ScenarioStore.monthYearText(store.cursor)).")
        case .goto(let text):
            let reply = await store.goto(text)
            panel.showFully()
            return reply
        case .setWheelMode, .cycleWheelMode, .adjustParameter:
            return .failed("That's for hardware controllers, which come later.")
        case .insertEventAtCursor:
            panel.addEvent()
            return .done("Opened the Event tab at the cursor.")
        case .addEvent(let request):
            return store.addEvent(request)
        case .addReading(let request):
            return store.addReading(request)
        case .addModel(let name, let slot):
            return await store.addModel(named: name, toSlot: slot)
        case .removeSlot(let text):
            let reply = await store.removeSlot(named: text)
            // Removing always asks in the panel (DESIGN.md, 13), so the panel shows the question.
            if reply.ok { panel.showFully() }
            return reply
        case .undo:
            return await store.undoForReply()
        case .redo:
            return await store.redoForReply()
        case .copySnapshot:
            panel.copy(.everything)
            return Reply(ok: !store.messageIsError, message: store.message ?? "Copied.")
        case .copyData:
            panel.copy(.dataOnly)
            return Reply(ok: !store.messageIsError, message: store.message ?? "Copied.")
        }
    }

    private func confirm(_ command: Command, source: CommandSource) -> Bool {
        let who: String
        switch source {
        case .urlScheme: who = "a link"
        case .appIntent: who = "Shortcuts"
        case .pairedDevice: who = "a paired device"
        default: who = "another app"
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(who) to change Edit The Future?"
        alert.informativeText = "\(who.prefix(1).uppercased() + who.dropFirst()) asked to \(describe(command)). Only allow it if you started it yourself."
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

/// Requests from outside the panel, from the etf tool and Shortcuts, wait here until a scenario is
/// open, then go to the one that's open (DESIGN.md, 10.2).
@MainActor
final class Outside {
    static let shared = Outside()

    private var router: CommandRouter?
    private var waiters: [CheckedContinuation<CommandRouter, Never>] = []
    /// The slots Shortcuts and Spotlight were last told about.
    private var announced: [String] = []

    /// The scenario's router, once one is open; nil while another opens in its place.
    func connect(_ router: CommandRouter?) {
        self.router = router
        guard let router else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: router) }
        slotsMayHaveChanged()
    }

    func currentRouter() async -> CommandRouter {
        if let router { return router }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func store() async -> ScenarioStore {
        await currentRouter().store
    }

    func handle(_ request: Request, from source: CommandSource, confirmed: Bool = false) async -> Reply {
        guard request.isWellFormed else { return .failed("That request has a value out of range.") }
        let router = await currentRouter()
        switch request {
        case .command(let command): return await router.perform(command, from: source, confirmed: confirmed)
        case .query(let query): return await router.store.answer(query)
        }
    }

    /// Tells Siri and Spotlight about the slots when their names change (Intents.swift).
    func slotsMayHaveChanged() {
        guard let store = router?.store else { return }
        let names = store.slots.map { $0.name + "\u{1F}" + $0.title } + [store.name]
        guard names != announced else { return }
        announced = names
        SlotIntents.slotsChanged(in: store)
    }
}
#endif
