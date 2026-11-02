import Foundation
import FutureEngine

/// A simulation written in Swift and built into the app (docs/DESIGN.md, 6.5).
///
/// A module sees only the engine and this contract: the package won't let it import the UI, read
/// files or reach the network. What it needs from outside, such as a table of countries, it names
/// in `needs`, and the app hands it over when the model is built.
public protocol SimulationModule: Sendable {
    /// Written in scenario.md (`module: epidemic@1`), so it never changes.
    var id: String { get }
    /// Goes up when the model's meaning changes, so a scenario says which one it was made with.
    var version: Int { get }
    var info: ModuleInfo { get }
    /// Data the app has to supply. Empty for a module that needs none.
    var needs: [DataNeed] { get }

    /// The model for a slot called `name`, with the slot's own `values` for parameters and starting
    /// values, and the data asked for in `needs`.
    func makeModel(name: String, values: [String: Double], data: ModuleData) throws -> any AuthoredModel
}

extension SimulationModule {
    public var needs: [DataNeed] { [] }

    public var reference: ModuleReference { ModuleReference(id: id, version: version) }
}

/// How the model picker shows a module.
public struct ModuleInfo: Sendable, Equatable {
    public var name: String
    /// One line for the picker.
    public var summary: String
    /// The picker's category: `money`, `growth`, `climate`, `health` or `physics`.
    public var category: String
    /// The name a slot gets when the module is added, e.g. "Outbreak".
    public var slotName: String
    /// The value the graph shows at first.
    public var shows: String

    public init(name: String, summary: String, category: String, slotName: String, shows: String) {
        self.name = name
        self.summary = summary
        self.category = category
        self.slotName = slotName
        self.shows = shows
    }
}

/// A module and the version a scenario was made with: `epidemic@1`.
public struct ModuleReference: Hashable, Sendable, CustomStringConvertible {
    public var id: String
    public var version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// Reads `epidemic@1`, or `epidemic` for the version the app has.
    public init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty, parts.count <= 2,
              first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        id = first.lowercased()
        if parts.count == 2 {
            guard let version = Int(parts[1]), version >= 1 else { return nil }
            self.version = version
        } else {
            version = 0
        }
    }

    /// `epidemic@1`, or `epidemic` when no version was given.
    public var description: String { version > 0 ? "\(id)@\(version)" : id }
}

/// Why a module's model couldn't be built.
public struct ModuleError: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
