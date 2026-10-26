import Foundation

/// A model people write in the app, as a formula or a script. On top of running, it tells the app
/// what to show in the Slot tab and the add-event pane.
public protocol AuthoredModel: TimelineModel {
    /// The text it was built from.
    var source: String { get }

    /// Parameter names in declaration order.
    var parameterNames: [String] { get }

    /// The state variables a slot can give its own starting values, in declaration order.
    var startingValueNames: [String] { get }

    /// Kinds of this slot's own events the model handles, in order. `set` events are always
    /// handled (they change parameters) and aren't listed.
    var handledEventKinds: [String] { get }

    /// The slot's own values for parameters and starting values, in place of the model's defaults.
    var overrides: [String: Double] { get }

    /// Each parameter's and starting value's default as the model writes it, when it's known
    /// without running the model.
    var declaredDefaults: [String: Double] { get }

    /// The same with `overrides` applied: what the slot starts with.
    var startingValues: [String: Double] { get }
}

/// An error a model raises that already names its slot and where it went wrong, such as a script's
/// error with its line. The engine passes these on as they are, rather than wrapping them in
/// `EngineError.modelFailed`.
public protocol ModelFailure: Error, CustomStringConvertible {}
