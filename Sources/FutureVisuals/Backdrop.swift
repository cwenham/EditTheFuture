import Foundation
import FutureEngine

/// What a backdrop is, without how it draws (docs/DESIGN.md, 9.6): enough for the scenario to offer it
/// and work out what it shows. FutureUI's `Backdrop` draws one.
public struct BackdropKind: Sendable {
    /// Written in scenario.md (`backdrop: world-map`), so it never changes.
    public let id: String
    /// As the Slot tab's Backdrop menu says it: "World map".
    public let name: String
    /// The geometries of fields it draws (FieldDescriptor.geometry): `world/countries`, `groups`.
    public let geometries: Set<String>
    /// Whether it can place a point from two values, such as a ship's latitude and longitude.
    public let drawsPoints: Bool
    /// The names of the two values it places a point from, as a slot might call them: latitude and
    /// longitude on Earth, declination and right ascension on the sky (both in degrees).
    public let pointNames: [(String, String)]

    public init(id: String, name: String, geometries: Set<String>, drawsPoints: Bool = false,
                pointNames: [(String, String)]? = nil) {
        self.id = id
        self.name = name
        self.geometries = geometries
        self.drawsPoints = drawsPoints
        self.pointNames = pointNames ?? (drawsPoints ? [("latitude", "longitude"), ("lat", "lon")] : [])
    }

    public func draws(geometry: String) -> Bool { geometries.contains(geometry) }

    public static let worldMap = BackdropKind(id: "world-map", name: "World map", geometries: ["world/countries"],
                                              drawsPoints: true)
    public static let skyMap = BackdropKind(id: "sky-map", name: "Sky map", geometries: ["sky/stars"], drawsPoints: true,
                                            pointNames: [("declination", "rightAscension"), ("dec", "ra")])
    public static let parts = BackdropKind(id: "parts", name: "Parts of a whole", geometries: ["groups"])
}

/// What a backdrop shows: the slot's field at the cursor, or a point, in the slot's colour.
public struct BackdropInput: Sendable, Equatable {
    public var field: FieldSample?
    /// The field's label, such as "Where everyone is".
    public var label: String?
    public var quantity: Quantity?
    /// How the field says to shade it; see `intensities()`.
    public var scale: FieldScale?
    /// How to write each key, such as "Can still catch it" for `susceptible`. Keys without one are
    /// written as they are.
    public var keyLabels: [String: String]
    public var point: GeoPoint?
    public var color: RGBA

    public init(field: FieldSample? = nil, label: String? = nil, quantity: Quantity? = nil, scale: FieldScale? = nil,
                keyLabels: [String: String] = [:], point: GeoPoint? = nil, color: RGBA) {
        self.field = field
        self.label = label
        self.quantity = quantity
        self.scale = scale
        self.keyLabels = keyLabels
        self.point = point
        self.color = color
    }

    /// The field's values as 0...1 for shading, by its scale: shares as they are, values against the
    /// largest, or a logarithmic range. Without a scale, percents are shares and anything else is
    /// against the largest. Values that aren't finite are left out.
    public func intensities() -> [String: Double] {
        guard let field else { return [:] }
        let scale = self.scale ?? (quantity == .percent ? .share : .relative)
        var largest = 0.0
        if case .relative = scale { largest = field.values.filter(\.isFinite).map(abs).max() ?? 0 }
        var result: [String: Double] = [:]
        for (key, value) in zip(field.keys, field.values) where value.isFinite {
            let intensity: Double
            switch scale {
            case .share:
                intensity = value
            case .relative:
                intensity = largest > 0 ? abs(value) / largest : 0
            case .logarithmic(let faintest, let full):
                intensity = value > faintest && full > faintest && faintest > 0 ? log(value / faintest) / log(full / faintest) : 0
            }
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

/// The backdrops an app offers (docs/DESIGN.md, 9.6). A new one is a kind here and a type in FutureUI
/// that draws it.
public struct BackdropCatalog: Sendable {
    public let backdrops: [BackdropKind]

    public init(_ backdrops: [BackdropKind]) {
        self.backdrops = backdrops
    }

    public static let builtIn = BackdropCatalog([.worldMap, .skyMap, .parts])

    public func backdrop(id: String) -> BackdropKind? {
        backdrops.first { $0.id == id }
    }

    /// The backdrops that draw fields of this geometry.
    public func drawing(geometry: String) -> [BackdropKind] {
        backdrops.filter { $0.draws(geometry: geometry) }
    }
}
