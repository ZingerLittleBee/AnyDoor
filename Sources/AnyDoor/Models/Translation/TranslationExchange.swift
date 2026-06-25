import Foundation

/// A single translation request fanned out to every enabled provider.
struct TranslationRequest: Sendable, Equatable {
    var text: String
    /// `nil` means auto-detect the source language.
    var source: TranslationLanguage?
    var target: TranslationLanguage
}

/// One emission from a provider's stream. Non-LLM providers yield a single
/// `.final` (optionally preceded by `.detected`); LLM providers yield many
/// `.delta` chunks then `.final`.
enum TranslationChunk: Sendable, Equatable {
    case detected(TranslationLanguage)
    case delta(String)
    case final(String)
}

/// The rendered state of one service's translation, suitable as a SwiftUI card
/// model. Keyed by `serviceID` for diffable lists.
struct TranslationResult: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case idle
        /// Manual (collapsed-by-default) service: shown but not yet translated.
        case deferred
        case loading
        case streaming
        case success
        case failure
    }

    let serviceID: String
    var status: Status
    var text: String
    var detected: TranslationLanguage?
    var errorMessage: String?

    var id: String { serviceID }

    /// An empty, idle result for the given service.
    static func idle(_ serviceID: String) -> TranslationResult {
        TranslationResult(
            serviceID: serviceID,
            status: .idle,
            text: "",
            detected: nil,
            errorMessage: nil
        )
    }

    /// A deferred (manual, not-yet-translated) result for the given service.
    static func deferred(_ serviceID: String) -> TranslationResult {
        TranslationResult(
            serviceID: serviceID,
            status: .deferred,
            text: "",
            detected: nil,
            errorMessage: nil
        )
    }
}
