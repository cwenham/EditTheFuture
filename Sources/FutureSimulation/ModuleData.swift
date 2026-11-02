import Foundation

/// Data a module asks the app for, by name: "countries", "air-routes" (docs/DESIGN.md, 6.5).
/// The app decides where it comes from (bundled with the app, a feed, a cache), so the module
/// never touches files or the network, and tests can hand it a small table instead.
public struct DataNeed: Hashable, Sendable {
    public var name: String
    /// What it's for, said when it's missing: "Populations and positions of countries".
    public var summary: String

    public init(_ name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// Rows with a key each, such as an ISO country code, and columns of numbers.
public struct DataTable: Sendable, Equatable {
    public var keys: [String]
    public var columns: [String: [Double]]

    public init(keys: [String], columns: [String: [Double]]) {
        self.keys = keys
        self.columns = columns
    }

    public var count: Int { keys.count }

    /// A column, or nil when the table hasn't got it or it's the wrong length.
    public func column(_ name: String) -> [Double]? {
        guard let values = columns[name], values.count == keys.count else { return nil }
        return values
    }
}

/// The data the app hands a module when its model is built, by need name.
public struct ModuleData: Sendable, Equatable {
    public var tables: [String: DataTable]

    public init(tables: [String: DataTable] = [:]) {
        self.tables = tables
    }

    public static let none = ModuleData()

    public subscript(_ need: DataNeed) -> DataTable? { tables[need.name] }
}

/// Where the app gets modules' data from. The app supplies one; tests supply their own.
public protocol ModuleDataSource: Sendable {
    func table(for need: DataNeed) -> DataTable?
}

/// No data at all, for modules that need none.
public struct NoModuleData: ModuleDataSource {
    public init() {}
    public func table(for need: DataNeed) -> DataTable? { nil }
}
