import Foundation

/// The category of a translation service. Drives provider construction and the
/// per-kind code remapping in `TranslationLanguage.serviceCode(for:)`.
enum TranslationServiceKind: String, Codable, Sendable, CaseIterable {
    case apple
    case googleFree
    case bingFree
    case openAICompatible
    case deepl
}
