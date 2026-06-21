import Foundation

/// UserDefaults-backed translation configuration. Mirrors `CaptureSettings`:
/// explicit write-through setters, `@MainActor @Observable` so SwiftUI settings
/// can bind. Services are stored as JSON-encoded `[TranslationServiceConfig]`,
/// falling back to `seededDefaults()` when the stored value is empty or garbage.
@MainActor
@Observable
final class TranslationSettings {
    static let shared = TranslationSettings()

    static let targetLanguageKey = "translation.targetLanguage"
    static let secondTargetLanguageKey = "translation.secondTargetLanguage"
    static let autoSpeakKey = "translation.autoSpeak"
    static let servicesKey = "translation.services"

    private let defaults: UserDefaults

    private(set) var targetLanguageCode: String
    private(set) var secondTargetLanguageCode: String
    private(set) var autoSpeak: Bool
    private(set) var services: [TranslationServiceConfig]

    private static func readServices(_ defaults: UserDefaults) -> [TranslationServiceConfig] {
        guard let data = defaults.data(forKey: servicesKey),
              let decoded = try? JSONDecoder().decode([TranslationServiceConfig].self, from: data),
              !decoded.isEmpty else {
            return TranslationServiceConfig.seededDefaults()
        }
        return decoded.sorted { $0.order < $1.order }
    }

    private func writeServices(_ value: [TranslationServiceConfig]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.servicesKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targetLanguageCode = defaults.string(forKey: Self.targetLanguageKey)
            ?? TranslationLanguage.systemDefault.code
        self.secondTargetLanguageCode = defaults.string(forKey: Self.secondTargetLanguageKey)
            ?? TranslationLanguage.english.code
        self.autoSpeak = defaults.object(forKey: Self.autoSpeakKey) as? Bool ?? false
        self.services = Self.readServices(defaults)
    }

    func setTargetLanguageCode(_ value: String) {
        targetLanguageCode = value
        defaults.set(value, forKey: Self.targetLanguageKey)
    }

    func setSecondTargetLanguageCode(_ value: String) {
        secondTargetLanguageCode = value
        defaults.set(value, forKey: Self.secondTargetLanguageKey)
    }

    func setAutoSpeak(_ value: Bool) {
        autoSpeak = value
        defaults.set(value, forKey: Self.autoSpeakKey)
    }

    func setServices(_ value: [TranslationServiceConfig]) {
        let sorted = value.sorted { $0.order < $1.order }
        services = sorted
        writeServices(sorted)
    }

    func upsertService(_ config: TranslationServiceConfig) {
        var next = services
        if let index = next.firstIndex(where: { $0.id == config.id }) {
            next[index] = config
        } else {
            next.append(config)
        }
        setServices(next)
    }

    func removeService(id: String) {
        setServices(services.filter { $0.id != id })
    }

    /// Re-read after a config import (parallels `CaptureSettings.reloadFromDefaults`).
    func reloadFromDefaults() {
        targetLanguageCode = defaults.string(forKey: Self.targetLanguageKey)
            ?? TranslationLanguage.systemDefault.code
        secondTargetLanguageCode = defaults.string(forKey: Self.secondTargetLanguageKey)
            ?? TranslationLanguage.english.code
        autoSpeak = defaults.object(forKey: Self.autoSpeakKey) as? Bool ?? false
        services = Self.readServices(defaults)
    }

    var targetLanguage: TranslationLanguage {
        TranslationLanguage.named(targetLanguageCode) ?? TranslationLanguage.systemDefault
    }

    var secondTargetLanguage: TranslationLanguage {
        TranslationLanguage.named(secondTargetLanguageCode) ?? TranslationLanguage.english
    }

    var enabledServicesInOrder: [TranslationServiceConfig] {
        services.filter(\.enabled).sorted { $0.order < $1.order }
    }
}
