import Foundation
import FutureEngine

/// The modules an app offers, and the data source it gives them (docs/DESIGN.md, 6.5).
public struct ModuleCatalog: Sendable {
    public let modules: [any SimulationModule]
    public let data: any ModuleDataSource

    public init(modules: [any SimulationModule], data: any ModuleDataSource = NoModuleData()) {
        self.modules = modules
        self.data = data
    }

    public func module(id: String) -> (any SimulationModule)? {
        modules.first { $0.id == id }
    }

    /// The model for a slot, after checking the app has the module, a version at least as new as
    /// the scenario's, and the data it needs.
    public func makeModel(_ reference: ModuleReference, name: String, values: [String: Double]) throws -> any AuthoredModel {
        guard let module = module(id: reference.id) else {
            throw ModuleError("This scenario uses the “\(reference.id)” module, which this version of the app doesn't have.")
        }
        guard reference.version <= module.version else {
            throw ModuleError("This scenario was made with version \(reference.version) of \(module.info.name), "
                              + "and this app has version \(module.version). Update the app to run it.")
        }
        var tables: [String: DataTable] = [:]
        for need in module.needs {
            guard let table = data.table(for: need) else {
                throw ModuleError("\(module.info.name) needs data the app hasn't got: \(need.summary.lowercased()).")
            }
            tables[need.name] = table
        }
        return try module.makeModel(name: name, values: values, data: ModuleData(tables: tables))
    }
}
