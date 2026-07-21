import Foundation
import ScriptPluginRuntime

/// Chooses how a Script Plugin failure is worded, by audience (ticket 023).
///
/// A normal user sees the plain inline error states from ticket 022 — a single
/// generic localized string, because the internals of a plugin they merely
/// installed are noise to them. A plugin *author*, working behind the
/// developer-mode switch on a Dev Plugin, sees the error's own detail (the JS
/// message and, for a thrown `Error`, its stack) so a failure is diagnosable
/// without reaching for the log file.
///
/// A pure policy — no I/O, no singletons — so the dev-vs-installed choice is a
/// unit-testable seam independent of the palette and the runtime.
enum ScriptPluginErrorPresentation {
    /// The message to show for a failed row build, Detail build, or row action.
    ///
    /// - Parameters:
    ///   - error: the runtime failure.
    ///   - surfacesDetail: `true` for a Dev Plugin (show the detail), `false` for
    ///     a normally installed plugin (show `generic`).
    ///   - generic: the plain localized string a normal user sees.
    static func message(for error: any Error, surfacesDetail: Bool, generic: String) -> String {
        surfacesDetail ? detail(of: error) : generic
    }

    /// The author-facing detail of a runtime error (English developer
    /// diagnostics, not localized user copy). For a JS throw this already
    /// carries the message and stack the runtime captured.
    static func detail(of error: any Error) -> String {
        guard let scriptError = error as? ScriptPluginError else {
            return error.localizedDescription
        }
        switch scriptError {
        case .bundleUnreadable(let name): return "Bundle unreadable: \(name)"
        case .bundleEvaluationFailed(let message): return message
        case .pluginNotRegistered: return "Plugin never called anydoor.registerPlugin."
        case .entryPointMissing(let entry): return "Missing entry point: \(entry)"
        case .invocationFailed(let message): return message
        case .timedOut: return "Invocation timed out (watchdog killed the context)."
        case .capabilityFailed(let message): return message
        case .resultDecodingFailed(let message): return message
        case .notLoaded(let id): return "Plugin is not loaded: \(id.rawValue)."
        case .duplicateID(let id): return "Duplicate plugin id: \(id.rawValue)."
        }
    }
}
