import SwiftUI
import FutureEngine

/// A visual drawn faintly behind the focused graph, showing the slot's state at the cursor, such as
/// a world map shaded by each country's share infected (docs/DESIGN.md, 9.6). Backdrops only draw:
/// the app works out what they show and hands it over in a `BackdropInput`.
public protocol Backdrop: Sendable {
    /// Written in scenario.md (`backdrop: world-map`), so it never changes.
    var id: String { get }
    /// As the Slot tab's Backdrop menu says it: "World map".
    var name: String { get }
    /// The geometries of fields it draws (FieldDescriptor.geometry): `world/countries`, `groups`.
    var geometries: Set<String> { get }
    /// Whether it can place a point from a latitude and a longitude, such as a ship's position.
    var drawsPoints: Bool { get }

    /// Draws what follows the cursor into a context the size of the focused graph. The layer is
    /// drawn under the graph's lines and grid, so it should be faint.
    func draw(_ input: BackdropInput, in context: inout GraphicsContext, size: CGSize)

    /// Draws what doesn't follow the cursor, such as a map's outlines, underneath. It's a layer of its
    /// own, drawn again only when the size, colour or backdrop changes, so moving the cursor doesn't
    /// pay for it. The default draws nothing.
    func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize)
}

extension Backdrop {
    public var drawsPoints: Bool { false }

    public func drawBase(color: Color, in context: inout GraphicsContext, size: CGSize) {}

    public func draws(geometry: String) -> Bool { geometries.contains(geometry) }
}

/// What a backdrop shows: the slot's field at the cursor, or a point, in the slot's colour.
public struct BackdropInput: Sendable, Equatable {
    public var field: FieldSample?
    /// The field's label, such as "Where everyone is".
    public var label: String?
    public var quantity: Quantity?
    /// How to write each key, such as "Can still catch it" for `susceptible`. Keys without one are
    /// written as they are.
    public var keyLabels: [String: String]
    public var point: GeoPoint?
    public var color: Color

    public init(field: FieldSample? = nil, label: String? = nil, quantity: Quantity? = nil, keyLabels: [String: String] = [:],
                point: GeoPoint? = nil, color: Color) {
        self.field = field
        self.label = label
        self.quantity = quantity
        self.keyLabels = keyLabels
        self.point = point
        self.color = color
    }

    /// The field's values as 0...1 for shading: as they are when they're shares (a percent field,
    /// or all between 0 and 1), else each over the largest. Values that aren't finite are left out.
    public func intensities() -> [String: Double] {
        guard let field else { return [:] }
        let finite = field.values.filter(\.isFinite)
        let largest = finite.map(abs).max() ?? 0
        let shares = quantity == .percent || finite.allSatisfy { $0 >= 0 && $0 <= 1 }
        var result: [String: Double] = [:]
        for (key, value) in zip(field.keys, field.values) where value.isFinite {
            let intensity = shares ? value : (largest > 0 ? abs(value) / largest : 0)
            result[key] = min(1, max(0, intensity))
        }
        return result
    }
}

/// A place on Earth, in degrees.
public struct GeoPoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Nil unless both are finite and on the globe.
    public static func valid(latitude: Double?, longitude: Double?) -> GeoPoint? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 360 else {
            return nil
        }
        // Longitudes past 180 wrap round.
        var wrapped = longitude.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 } else if wrapped < -180 { wrapped += 360 }
        return GeoPoint(latitude: latitude, longitude: wrapped)
    }
}

/// The backdrops an app offers (docs/DESIGN.md, 9.6). A new one is a type that draws, and a line here.
public struct BackdropCatalog: Sendable {
    public let backdrops: [any Backdrop]

    public init(_ backdrops: [any Backdrop]) {
        self.backdrops = backdrops
    }

    public static let builtIn = BackdropCatalog([WorldMapBackdrop(), PartsBackdrop()])

    public func backdrop(id: String) -> (any Backdrop)? {
        backdrops.first { $0.id == id }
    }

    /// The backdrops that draw fields of this geometry.
    public func drawing(geometry: String) -> [any Backdrop] {
        backdrops.filter { $0.draws(geometry: geometry) }
    }
}
