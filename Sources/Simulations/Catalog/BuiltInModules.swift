import FutureSimulation
import EpidemicSimulation

extension ModuleCatalog {
    /// The simulation modules that come with the app (docs/DESIGN.md, 6.5). A new module gets its own
    /// folder under Sources/Simulations and a line here.
    public static let builtIn = ModuleCatalog(modules: [EpidemicModule()])
}
