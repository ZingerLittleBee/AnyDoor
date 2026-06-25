import Foundation

/// UserDefaults-backed translation configuration. Mirrors `CaptureSettings`:
/// explicit write-through setters, `@MainActor @Observable` so SwiftUI settings
/// can bind. Services are stored as a JSON *string* of `[TranslationServiceConfig]`
/// (so they round-trip through `SyncSettingsRegistry`'s `.string` codec during
/// config backup), falling back to `seededDefaults()` when empty or garbage.
@MainActor
@Observable
final class TranslationSettings {
    static let shared = TranslationSettings()

    static let targetLanguageKey = "translation.targetLanguage"
    static let secondTargetLanguageKey = "translation.secondTargetLanguage"
    static let autoSpeakKey = "translation.autoSpeak"
    static let servicesKey = "translation.services"
    static let historyRetentionKey = "translation.historyRetention"

    /// Number of non-favorite history records to keep when none has been chosen.
    static let defaultHistoryRetention = 200

    private let defaults: UserDefaults

    private(set) var targetLanguageCode: String
    private(set) var secondTargetLanguageCode: String
    private(set) var autoSpeak: Bool
    private(set) var historyRetention: Int
    private(set) var services: [TranslationServiceConfig]

    private static func readServices(_ defaults: UserDefaults) -> [TranslationServiceConfig] {
        // Services are stored as a JSON string (not raw Data) so they round-trip
        // through `SyncSettingsRegistry`'s `.string` codec during config backup.
        guard let json = defaults.string(forKey: servicesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TranslationServiceConfig].self, from: data),
              !decoded.isEmpty else {
            return TranslationServiceConfig.seededDefaults()
        }
        return decoded.sorted { $0.order < $1.order }
    }

    private func writeServices(_ value: [TranslationServiceConfig]) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.servicesKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targetLanguageCode = defaults.string(forKey: Self.targetLanguageKey)
            ?? TranslationLanguage.systemDefault.code
        self.secondTargetLanguageCode = defaults.string(forKey: Self.secondTargetLanguageKey)
            ?? TranslationLanguage.english.code
        self.autoSpeak = defaults.object(forKey: Self.autoSpeakKey) as? Bool ?? false
        self.historyRetention = Self.readHistoryRetention(defaults)
        self.services = Self.readServices(defaults)
    }

    private static func readHistoryRetention(_ defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: historyRetentionKey) as? Int else {
            return defaultHistoryRetention
        }
        return stored
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

    func setHistoryRetention(_ value: Int) {
        historyRetention = value
        defaults.set(value, forKey: Self.historyRetentionKey)
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
        historyRetention = Self.readHistoryRetention(defaults)
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
