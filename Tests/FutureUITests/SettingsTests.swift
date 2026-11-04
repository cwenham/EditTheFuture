import Foundation
import Testing
import FutureTestSupport
import AppKit
import SwiftUI
import FutureEngine
@testable import FutureKit
@testable import FutureUI

/// The Settings window's font and text size, and how the panel grows with them (docs/UI.md, 7).
@MainActor
@Suite("Settings")
struct SettingsTests {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EditTheFutureTests.settings.\(UUID().uuidString)")!
    }

    @Test("The font and text size are remembered, and sizes outside the range are kept inside it")
    func remembered() {
        let defaults = freshDefaults()
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.font == .standard)
        #expect(settings.textSize == 13)
        #expect(settings.scale == 1)

        settings.font = .family("Avenir Next")
        settings.textSize = 19.5
        let again = AppearanceSettings(defaults: defaults)
        #expect(again.font == .family("Avenir Next"))
        #expect(again.textSize == 19.5)

        settings.textSize = 400
        #expect(settings.textSize == AppearanceSettings.textSizes.upperBound)
        settings.textSize = .nan
        #expect(settings.textSize == AppearanceSettings.textSizes.upperBound)
        settings.textSize = 2
        #expect(settings.textSize == AppearanceSettings.textSizes.lowerBound)
        defaults.set(-5.0, forKey: AppearanceSettings.textSizeKey)
        #expect(AppearanceSettings(defaults: defaults).textSize == AppearanceSettings.textSizes.lowerBound)

        settings.font = .system(.serif)
        #expect(AppearanceSettings(defaults: defaults).font == .system(.serif))
        settings.reset()
        #expect(settings.font == .standard && settings.textSize == 13)
        #expect(AppearanceSettings.FontChoice(stored: "nonsense") == nil)
    }

    @Test("The style they make keeps the colours and sets the scale, design and family")
    func style() {
        let settings = AppearanceSettings(defaults: freshDefaults())
        #expect(settings.style() == .standard)
        settings.textSize = 26
        settings.font = .system(.rounded)
        var style = settings.style(from: .light)
        #expect(style.colors == FutureStyle.light.colors)
        #expect(style.fonts.scale == 2)
        #expect(style.fonts.design == .rounded)
        #expect(style.fonts.family == nil)

        settings.font = .family("Helvetica")
        style = settings.style()
        #expect(style.fonts.family == "Helvetica")
        // A family that isn't installed is drawn in the system font.
        settings.font = .family("No Such Font 3fa1")
        #expect(!settings.fontIsInstalled)
        #expect(settings.style().fonts.family == nil)
    }

    @Test("Columns, rows and controls grow with the text, within limits")
    func layoutScale() {
        #expect(FutureStyle.Fonts().layoutScale == 1)
        #expect(FutureStyle.Fonts(scale: 2).scaled(30) == 60)
        #expect(FutureStyle.Fonts(scale: 10).layoutScale == FutureStyle.Fonts.layoutScales.upperBound)
        #expect(FutureStyle.Fonts(scale: .nan).layoutScale == 1)
        #expect(FutureStyle.Fonts().controlSize() == .regular)
        #expect(FutureStyle.Fonts().controlSize(.small) == .small)
        #expect(FutureStyle.Fonts(scale: 1.4).controlSize(.small) == .regular)
        #expect(FutureStyle.Fonts(scale: 2).controlSize() == .extraLarge)
        #expect(FutureStyle.Fonts(scale: 0.8).controlSize(.mini) == .mini)
        #expect(FutureStyle.Fonts().usesSystemControls)
        #expect(!FutureStyle.Fonts(scale: 1.5).usesSystemControls)

        let standard = TimelineLayout.standard, large = TimelineLayout(scale: 2)
        #expect(large.labelWidth == 2 * standard.labelWidth)
        #expect(large.laneRowHeight == 2 * standard.laneRowHeight)
        #expect(large.plotWidth(forTotal: 1400) < standard.plotWidth(forTotal: 1400))
        #expect(large.plotWidth(forTotal: 100) == 120)

        // The side pane's minimum and the room it leaves the timeline grow too.
        #expect(SidePane.clamped(100, for: .slot, area: 2000, scale: 1.5) == 390)
        #expect(SidePane.clamped(5000, for: .slot, area: 2000, scale: 1.5) == 2000 - PanelView.paneGap - 630)
    }

    @Test("The events strip lays out and hit-tests at the scale it's drawn at")
    func eventsStripScale() {
        let frame = TimeFrame(start: utc(2026, 1), end: utc(2036, 1))
        let width: CGFloat = 1000
        let oneOff = EventMarker(id: UUID(), date: utc(2028, 1), endDate: nil, label: "Bonus", kind: .oneOff)
        let rule = EventMarker(id: UUID(), date: utc(2030, 1), endDate: utc(2033, 1), label: "", kind: .recurring)
        let scale: CGFloat = 2
        let items = EventsStrip.layout(markers: [oneOff, rule], frame: frame, width: width, scale: scale) { _, _ in 40 }
        let label = try? #require(items.first { $0.id == oneOff.id }?.labelRect)
        #expect(label?.midY == EventsStrip.labelY * scale)
        #expect(label?.height == EventsStrip.labelHeight * scale)
        let x = frame.x(utc(2028, 1), width: width)
        // Below the label, a diamond's reach grows with it.
        #expect(EventsStrip.editableEvent(at: CGPoint(x: x + 14, y: EventsStrip.markerY * scale), in: items, scale: scale) == oneOff.id)
        #expect(EventsStrip.editableEvent(at: CGPoint(x: x + 14, y: EventsStrip.markerY * scale), in: items) == nil)
        let barX = frame.x(utc(2031, 6), width: width)
        #expect(EventsStrip.editableEvent(at: CGPoint(x: barX, y: EventsStrip.barY(row: 0, scale: scale)), in: items, scale: scale) == rule.id)

        // Measured in the style's font, a label is wider at a larger size.
        let measure = EventsStrip.measure(in: FutureStyle.Fonts(scale: 2))
        #expect(measure("Bonus", false) > EventsStrip.labelWidth("Bonus", italic: false) * 1.8)
        #expect(EventsStrip.measure(in: FutureStyle.Fonts())("Bonus", false) == EventsStrip.labelWidth("Bonus", italic: false))
    }

    @Test("The panel draws every tab at large and small sizes without crashing")
    func panelAtSizes() async throws {
        for scale in [0.77, 2.0, 2.46] {
            let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
            var style = FutureStyle.standard
            style.fonts.scale = scale
            style.fonts.family = "Helvetica"
            let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})).futureStyle(style))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = view
            await store.waitUntilIdle()
            settle(view)
            store.beginEvent(at: utc(2030, 1))
            store.eventDraft.amountText = "500"
            store.eventDraft.repeats = .monthly
            settle(view)
            #expect(store.commitEvent())
            store.sidePane = .slot
            settle(view)
            store.showFormulaEditor()
            settle(view)
            store.sidePane = .event
            store.eventDraft.kind = .setParameter
            settle(view)
        }
    }

    @Test("The Settings window shows each of its pages")
    func settingsWindow() {
        let defaults = freshDefaults()
        let wheel = TimelineWheel(rememberingUnder: "wheel", in: defaults)
        let pages: [SettingsPage] = [.appearance(AppearanceSettings(defaults: defaults)), .mouse(wheel)]
        for page in pages {
            UserDefaults.standard.set(page.id, forKey: SettingsView.groupKey)
            let view = NSHostingView(rootView: SettingsView(pages: pages))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            settle(view)
            window.close()
        }
        UserDefaults.standard.removeObject(forKey: SettingsView.groupKey)
    }

    func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

/// The rest of Settings: theme, contrast, lines, wheel feel, shortcuts and the panel's look.
@MainActor
@Suite("More settings")
struct MoreSettingsTests {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "EditTheFutureTests.more.\(UUID().uuidString)")!
    }

    @Test("Theme, contrast and thicker lines are remembered and make the style")
    func look() {
        let defaults = freshDefaults()
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.theme == .dark && settings.isStandard)
        #expect(settings.style(colorScheme: .light) == .standard)

        settings.theme = .system
        #expect(settings.style(colorScheme: .light).colors == FutureStyle.light.colors)
        #expect(settings.style(colorScheme: .dark).colors == FutureStyle.standard.colors)
        settings.theme = .light
        #expect(settings.style(colorScheme: .dark).colorScheme == .light)

        settings.increasesContrast = true
        settings.thickerLines = true
        let again = AppearanceSettings(defaults: defaults)
        #expect(again.theme == .light && again.increasesContrast && again.thickerLines)
        let style = again.style()
        #expect(style.colors == FutureStyle.light.increasingContrast().colors)
        #expect(style.lineScale == AppearanceSettings.thickLineScale)
        #expect(!again.isStandard)
        again.reset()
        #expect(again.isStandard && again.style() == .standard)

        // The Mac's Increase Contrast turns it on without the setting.
        #expect(again.style(increasedContrast: true).colors == FutureStyle.standard.increasingContrast().colors)
        #expect(FutureStyle.standard.increasingContrast().colors.secondary != FutureStyle.standard.colors.secondary)
    }

    @Test("⌘+ and ⌘− step the text size, within its range, and ⌘0 puts it back")
    func stepping() {
        let settings = AppearanceSettings(defaults: freshDefaults())
        #expect(settings.stepTextSize(1) == 14)
        #expect(settings.stepTextSize(-3) == 11)
        #expect(settings.stepTextSize(0) == 13)
        settings.textSize = 32
        #expect(settings.stepTextSize(1) == 32)
    }

    @Test("Wheel speeds and reversing are remembered and change what the wheel does")
    func wheelFeel() {
        let defaults = freshDefaults()
        let wheel = TimelineWheel(rememberingUnder: "wheel", in: defaults)
        #expect(wheel.panSpeed == 1 && wheel.zoomSpeed == 1 && !wheel.reversesHorizontalWheel)
        wheel.panSpeed = 2
        wheel.zoomSpeed = 0.5
        wheel.reversesHorizontalWheel = true
        #expect(wheel.mapper.map(.init(dx: 0, dy: -1, precise: false)).action == .pan(0.08))
        wheel.mode = .twoWheels
        #expect(wheel.mapper.map(.init(dx: -1, dy: 0, precise: false)).action == .pan(-0.08))
        #expect(wheel.mapper.map(.init(dx: 0, dy: 2, precise: false)).action == .zoom(0.88))
        // Trackpads aren't reversed.
        #expect(wheel.mapper.map(.init(dx: -20, dy: 0, precise: true)).action == .pan(0.06))

        let again = TimelineWheel(rememberingUnder: "wheel", in: defaults)
        #expect(again.panSpeed == 2 && again.zoomSpeed == 0.5 && again.reversesHorizontalWheel)
        again.resetFeel()
        #expect(again.panSpeed == 1 && !again.reversesHorizontalWheel)
        defaults.set(99.0, forKey: "wheel.panSpeed")
        #expect(TimelineWheel(rememberingUnder: "wheel", in: defaults).panSpeed == 1)
    }

    @Test("Shortcuts start standard, can be changed or turned off, never clash, and are remembered")
    func shortcuts() throws {
        let defaults = freshDefaults()
        let shortcuts = ShortcutSettings(defaults: defaults)
        #expect(shortcuts.shortcut(for: .showPanel)?.text == "⌃⌥Space")
        #expect(shortcuts.shortcut(for: .copySnapshot)?.text == "⌃⌥C")
        #expect(shortcuts.isStandard)

        let f5 = GlobalShortcut(keyCode: 96, modifiers: [.command, .shift], key: "F5")
        #expect(f5.text == "⇧⌘F5")
        shortcuts.setShortcut(f5, for: .showPanel)
        shortcuts.setShortcut(nil, for: .addEvent)
        // Taking another action's shortcut takes it off that action.
        shortcuts.setShortcut(ShortcutSettings.Action.copySnapshot.standard, for: .showPanel)
        #expect(shortcuts.shortcut(for: .showPanel)?.text == "⌃⌥C")
        #expect(shortcuts.shortcut(for: .copySnapshot) == nil)

        let again = ShortcutSettings(defaults: defaults)
        #expect(again.shortcut(for: .showPanel)?.text == "⌃⌥C")
        #expect(again.shortcut(for: .addEvent) == nil)
        #expect(again.shortcut(for: .copySnapshot) == nil)
        again.reset()
        #expect(again.isStandard && again.shortcut(for: .addEvent)?.text == "⌃⌥E")

        func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> GlobalShortcut? {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            return GlobalShortcut(event: event)
        }
        #expect(try press("k", code: 40, [.control, .option])?.text == "⌃⌥K")
        #expect(try press(" ", code: 49, [.command])?.text == "⌘Space")
        // A plain key, or one with only Shift, would take it from every app.
        #expect(try press("k", code: 40, []) == nil)
        #expect(try press("K", code: 40, [.shift]) == nil)
    }

    @Test("The panel puts back the opacity and blur it had, kept within the slider's range")
    func panelLook() throws {
        let defaults = freshDefaults()
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        PanelView.restoreLook(of: store, from: defaults)
        #expect(store.opacity == 0.86 && store.blursBehind)
        defaults.set(0.7, forKey: PanelView.opacityKey)
        defaults.set(false, forKey: PanelView.blurKey)
        PanelView.restoreLook(of: store, from: defaults)
        #expect(store.opacity == 0.7 && !store.blursBehind)
        defaults.set(0.1, forKey: PanelView.opacityKey)
        PanelView.restoreLook(of: store, from: defaults)
        #expect(store.opacity == 0.6)
    }

    @Test("Every page of the Settings window, and the panel in light and high contrast, draw without crashing")
    func pages() async throws {
        let defaults = freshDefaults()
        let appearance = AppearanceSettings(defaults: defaults)
        let pages: [SettingsPage] = [.appearance(appearance), .mouse(TimelineWheel(rememberingUnder: "w", in: defaults)),
                                     .shortcuts(ShortcutSettings(defaults: defaults))]
        for page in pages {
            UserDefaults.standard.set(page.id, forKey: SettingsView.groupKey)
            let view = NSHostingView(rootView: SettingsView(pages: pages))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            settle(view)
            window.close()
        }
        UserDefaults.standard.removeObject(forKey: SettingsView.groupKey)

        appearance.theme = .light
        appearance.increasesContrast = true
        appearance.thickerLines = true
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        store.trustRequest = TrustRequest(scripts: 1, feeds: 2)
        let view = NSHostingView(rootView: PanelView(store: store, actions: PanelActions(hide: {}, copySnapshot: {})).futureStyle(appearance.style()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        await store.waitUntilIdle()
        settle(view)
        // The banner's wrapping text once made the panel's least height thousands of points.
        #expect(view.fittingSize.height < 400)
        #expect(view.bounds.height == 820)
        store.dismissTrustRequest()
        settle(view)
    }

    func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
