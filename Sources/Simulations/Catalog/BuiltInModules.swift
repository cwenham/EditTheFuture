import FutureSimulation
import EpidemicSimulation
import WorldEpidemicSimulation

extension ModuleCatalog {
    /// The simulation modules that come with the app (docs/DESIGN.md, 6.5), with no data: the app
    /// gives them its own data source. A new module gets its own folder under Sources/Simulations
    /// and a line here.
    public static let builtIn = ModuleCatalog(modules: [EpidemicModule(), WorldEpidemicModule()])
}
