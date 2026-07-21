import Foundation

/// A typed failure from running a Script Plugin. Every invocation path returns
/// one of these instead of crashing: a throwing fixture, a timed-out loop, or a
/// decode mismatch all surface here so the caller (later, the palette) can show
/// an inline error state or a failure toast.
public enum ScriptPluginError: Error, Equatable {
    /// The manifest's entry-point bundle could not be read (name carried).
    case bundleUnreadable(String)
    /// The bundle threw while evaluating, or never called `anydoor.registerPlugin`.
    case bundleEvaluationFailed(String)
    /// The plugin registered no implementation object.
    case pluginNotRegistered
    /// The plugin implementation has no function for the requested entry point.
    case entryPointMissing(String)
    /// The plugin's code threw during the invocation (message carried).
    case invocationFailed(String)
    /// The invocation exceeded the watchdog deadline and its context was
    /// destroyed. The next invocation runs on a fresh context.
    case timedOut
    /// A capability call failed inside the host (message carried).
    case capabilityFailed(String)
    /// The plugin returned a value that did not match the expected shape.
    case resultDecodingFailed(String)
    /// The runtime does not know this plugin id (never loaded, or unloaded).
    case notLoaded(ScriptPluginID)
    /// A second package tried to load under an already-loaded id.
    case duplicateID(ScriptPluginID)
}
