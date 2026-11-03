import SwiftUI
import FutureVisuals

/// Draws a backdrop faintly behind the focused graph, showing the slot's state at the cursor, such as a
/// world map shaded by each country's share infected (docs/DESIGN.md, 9.6). Backdrops only draw: the
/// scenario works out what they show and hands it over in a `BackdropInput`.
public protocol Backdrop: Sendable {
    /// What it is: its id, name and the fields it draws.
    var kind: BackdropKind { get }

    /// Draws what follows the cursor into a context the size of the focused graph. The layer is
    /// drawn under the graph's lines and grid, so it should be faint.
    func draw(_ input: BackdropInput, in context: inout GraphicsContext, size: CGSize)

    /// Draws what doesn't follow the cursor, such as a map's outlines, underneath. It's a layer of its
    /// own, drawn again only when the size, colour or backdrop changes, so moving the cursor doesn't
    /// pay for it. The default draws nothing.
    func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize)
}

extension Backdrop {
    public var id: String { kind.id }

    public func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize) {}
}

/// The backdrops the views can draw, found by the id a slot's `BackdropKind` has.
public struct BackdropDrawings: Sendable {
    public let backdrops: [any Backdrop]

    public init(_ backdrops: [any Backdrop]) {
        self.backdrops = backdrops
    }

    public static let builtIn = BackdropDrawings([WorldMapBackdrop(), SkyMapBackdrop(), PartsBackdrop()])

    public func backdrop(id: String) -> (any Backdrop)? {
        backdrops.first { $0.id == id }
    }

    /// What they are, for the scenario (`ScenarioStore.Configuration.backdrops`).
    public var catalog: BackdropCatalog { BackdropCatalog(backdrops.map(\.kind)) }
}

extension Color {
    /// A colour the scenario carries, as SwiftUI draws it.
    public init(_ color: RGBA) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.opacity)
    }
}
