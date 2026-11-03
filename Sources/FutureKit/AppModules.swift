import Foundation
import FutureSimulation
import FutureVisuals
import SimulationCatalog

/// The data the app gives simulation modules (docs/DESIGN.md, 6.5). Modules ask for it by name and
/// never know where it came from: countries come from the world map's table (9.6), which is built into
/// the app, so nothing is read from files or the network.
struct AppModuleData: ModuleDataSource {
    func table(for need: DataNeed) -> DataTable? {
        switch need.name {
        case "countries": return Self.countries
        default: return nil
        }
    }

    /// Every country with people in it: ISO 3166 alpha-3 codes, with Natural Earth's population
    /// estimates and where each one's label goes.
    static let countries: DataTable = {
        let countries = WorldCountries.all.filter { $0.population > 0 }
        return DataTable(keys: countries.map(\.code),
                         columns: ["population": countries.map(\.population),
                                   "latitude": countries.map(\.labelLatitude),
                                   "longitude": countries.map(\.labelLongitude)])
    }()
}

extension ModuleCatalog {
    /// The modules that come with the app, with the app's data.
    public static let app = ModuleCatalog(modules: ModuleCatalog.builtIn.modules, data: AppModuleData())
}
