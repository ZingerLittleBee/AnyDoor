import Foundation

/// Maps a translation failure into a localized, user-facing message for the
/// result card and the settings Test button. Runs on the MainActor because it
/// resolves strings through `L()`. The backend's own diagnostic text (the
/// `apiError` message and the `network` note) is passed through verbatim — it is
/// produced by the remote service and is the most actionable hint, so it is not
/// re-localized.
@MainActor
func translationErrorMessage(_ error: Error) -> String {
    guard let providerError = error as? TranslationProviderError else {
        return error.localizedDescription
    }
    switch providerError {
    case .emptyInput:
        return L(.translationError)
    case .badResponse(let status):
        return L(.translationErrorHTTP, status)
    case .apiError(let status, let message):
        return L(.translationErrorHTTP, status) + ": " + message
    case .missingAPIKey:
        return L(.translationErrorMissingAPIKey)
    case .missingConfiguration:
        return L(.translationErrorMissingConfig)
    case .decodeFailed:
        return L(.translationErrorDecode)
    case .emptyResponse:
        return L(.translationErrorEmptyResponse)
    case .network(let note):
        return note
    }
}
