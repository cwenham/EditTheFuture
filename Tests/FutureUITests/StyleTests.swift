import Foundation
import Testing
import FutureTestSupport
import AppKit
import SwiftUI
@testable import FutureKit
@testable import FutureUI

/// How the views look, set by an app that embeds them (docs/DESIGN.md, 2.1).
@MainActor
@Suite("Styles")
struct StyleTests {
    @Test("Theme colours are looked up in the style they're drawn in, with their opacity")
    func colors() {
        #expect(Theme.text.color(in: .standard) == FutureStyle.standard.colors.text)
        #expect(Theme.text.color(in: .light) == FutureStyle.light.colors.text)
        #expect(FutureStyle.light[Theme.proposal] == FutureStyle.light.colors.proposal)
        #expect(Theme.ink.opacity(0.5).opacity(0.5).alpha == 0.25)
        #expect(ThemeColor.clear.alpha == 0)
        var style = FutureStyle.standard
        style.colors.proposal = .purple
        #expect(style[Theme.proposal] == .purple)
        #expect(style != .standard)
    }

    @Test("Fonts scale, take a family, and keep code monospaced; nonsense scales are ignored")
    func fonts() {
        #expect(FutureStyle.Fonts().font(size: 12) == .system(size: 12))
        #expect(FutureStyle.Fonts(scale: 1.5).font(size: 12, weight: .medium) == .system(size: 18, weight: .medium))
        #expect(FutureStyle.Fonts(family: "Avenir Next").font(size: 10) == .custom("Avenir Next", size: 10).weight(.regular))
        #expect(FutureStyle.Fonts(family: "Avenir Next").font(size: 10, design: .monospaced) == .system(size: 10, design: .monospaced))
        #expect(FutureStyle.Fonts(scale: .nan).font(size: 12) == .system(size: 12))
        #expect(FutureStyle.Fonts(scale: -2).font(size: 12) == .system(size: 12))
    }

    @Test("The formula editor takes its colours and size from the style")
    func formulaColors() {
        var style = FutureStyle.light
        style.fonts.scale = 2
        let colors = FormulaColors(style)
        #expect(colors != .standard)
        #expect(colors.scale == 2)
        #expect(colors.font.pointSize == 25)
        #expect(FormulaColors(.standard) == .standard)
    }

    /// The brightness, 0...1, at a point in a view drawn into a bitmap (top-left coordinates).
    func brightness<V: View>(of content: V, at point: CGPoint, size: CGSize = CGSize(width: 900, height: 560)) throws -> Double {
        let color = try pixel(of: content, at: point, size: size)
        return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    /// The colour at a point in a view drawn into a bitmap, in sRGB.
    func pixel<V: View>(of content: V, at point: CGPoint, size: CGSize = CGSize(width: 900, height: 560)) throws -> NSColor {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    @Test("A graph and an editor draw on the style's background: dark as standard, light when set")
    func background() async throws {
        let store = try ScenarioStore(definition: .homeAndMoney, now: utc(2026, 10, 25))
        await store.waitUntilIdle()
        let corner = CGPoint(x: 3, y: 3)
        #expect(try brightness(of: ScenarioGraph(store: store), at: corner) < 0.2)
        #expect(try brightness(of: ScenarioGraph(store: store).futureStyle(.light), at: corner) > 0.9)
        #expect(try brightness(of: EventEditor(store: store), at: corner, size: CGSize(width: 320, height: 500)) < 0.2)
        #expect(try brightness(of: EventEditor(store: store).futureStyle(.light), at: corner, size: CGSize(width: 320, height: 500)) > 0.9)
        var clear = FutureStyle.light
        clear.colors.panel = .clear
        let red = Color(.sRGB, red: 1, green: 0, blue: 0)
        let onRed = ZStack { red; ScenarioGraph(store: store).futureStyle(clear) }
        let shown = try pixel(of: onRed, at: corner)
        #expect(shown.redComponent > 0.8 && shown.greenComponent < 0.4 && shown.blueComponent < 0.4)  // red shows through
    }

    @Test("The panel looks as it did: the standard style is the default")
    func standardIsDefault() throws {
        #expect(EnvironmentValues().futureStyle == .standard)
        #expect(FutureStyle.standard.colors.panel == Color(.sRGB, red: 20 / 255, green: 22 / 255, blue: 27 / 255, opacity: 1))
        #expect(FutureStyle.standard.colorScheme == .dark && FutureStyle.light.colorScheme == .light)
    }
}
