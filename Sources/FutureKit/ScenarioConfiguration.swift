import Foundation
import FutureFeeds
import FutureSimulation
import FutureVisuals

/// What a scenario is built with besides its definition (docs/DESIGN.md, 2.1): the simulation modules
/// and backdrops its slots may use, the models offered for new slots, and where feed sign-ins are kept
/// and how feeds are fetched. `.standard` is the app's. An app that embeds FutureKit can give its own,
/// to add its own modules or keep sign-ins somewhere other than the Keychain.
public struct ScenarioConfiguration: Sendable {
    /// The Swift simulations slots can run (docs/DESIGN.md, 6.5), with the data they're given.
    public var modules: ModuleCatalog
    /// What can be drawn behind the focused graph (9.6). FutureUI draws the built-in ones;
    /// `BackdropDrawings.catalog` lists what a set of drawings can draw.
    public var backdrops: BackdropCatalog
    /// The models the picker offers and Predict with tries.
    public var templates: [ModelTemplate]
    /// Where feed and exchange-rate sign-ins are kept (15.8).
    public var credentials: any CredentialStore
    /// How feeds and exchange rates are fetched.
    public var feedTransport: any FeedTransport

    /// - Parameter templates: nil for the library's models with one for each of `modules`.
    public init(modules: ModuleCatalog = .app, backdrops: BackdropCatalog = .builtIn, templates: [ModelTemplate]? = nil,
                credentials: any CredentialStore = KeychainCredentialStore(),
                feedTransport: any FeedTransport = URLSessionTransport.shared) {
        self.modules = modules
        self.backdrops = backdrops
        self.templates = templates ?? ModelLibrary.templates(modules: modules)
        self.credentials = credentials
        self.feedTransport = feedTransport
    }

    /// The app's: its modules, backdrops and models, with sign-ins in the Keychain.
    public static let standard = ScenarioConfiguration()
}
