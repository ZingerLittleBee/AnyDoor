import XCTest
@testable import AnyDoor
@testable import HostsPlugin
@testable import ImageConversionPlugin

final class LocalizationCoverageTests: XCTestCase {
    func test_everyL10nKeyHasZhHansAndEnTranslations() throws {
        // Both the Core's keys and the plugin modules' keys resolve against
        // the single shared catalog (plugin UI localizes through the existing
        // string catalog), so all three enums are covered here.
        let allKeys = AnyDoor.L10n.Key.allCases.map(\.rawValue)
            + ImageConversionPlugin.L10n.Key.allCases.map(\.rawValue)
            + HostsPlugin.L10n.Key.allCases.map(\.rawValue)
        let catalog = try loadCatalog()
        let strings = catalog["strings"] as? [String: Any] ?? [:]

        var missing: [String] = []
        for key in allKeys {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                missing.append("\(key) (no entry)")
                continue
            }
            for lang in ["en", "zh-Hans"] {
                let value = (((localizations[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                if value.isEmpty {
                    missing.append("\(key) (\(lang) missing)")
                }
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            "Missing translations:\n" + missing.joined(separator: "\n")
        )
    }

    /// A zh-Hans value identical to English is usually a forgotten
    /// translation (Keep Awake shipped that way). Names, formats, and
    /// technical terms that stay English on purpose are listed here.
    private static let intentionallyEnglishInChinese: Set<String> = [
        "colorFormat.hsl",
        "colorFormat.rgb",
        "colorFormat.swiftUI",
        "commandPalette.brightness.level",
        "commandPalette.section.hosts",
        "devTool.hash.md5",
        "devTool.hash.sha1",
        "devTool.hash.sha256",
        "devTool.timestamp.iso",
        "devTool.timestamp.utc",
        "onboarding.demo.currencyResult",
        "onboarding.demo.portResult",
        "onboarding.sidebar.hyperKey",
        "quicklink.template.chatgpt",
        "settings.configSync.transportWebDAV",
        "settings.general.languageOption.en",
        "settings.general.languageOption.zh",
        "settings.translation.serviceAPIKey",
        "settings.translation.serviceBaseURL",
        "settingsGeneral.hyperKey.label",
        "settingsGeneral.hyperKey.quickPress.escape",
        "settingsGeneral.hyperKey.section",
    ]

    func test_zhHansValuesAreTranslatedUnlessIntentionallyEnglish() throws {
        let strings = try loadCatalog()["strings"] as? [String: Any] ?? [:]
        var untranslated: [String] = []
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
            func value(_ lang: String) -> String? {
                ((localizations?[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            guard let en = value("en"), en == value("zh-Hans"),
                  !Self.intentionallyEnglishInChinese.contains(key) else { continue }
            untranslated.append("\(key): \(en)")
        }
        XCTAssertTrue(
            untranslated.isEmpty,
            "zh-Hans equals English; translate it or allowlist an intentional term:\n"
                + untranslated.sorted().joined(separator: "\n")
        )
    }

    private func loadCatalog() throws -> [String: Any] {
        // #filePath resolves to .../Tests/AnyDoorTests/LocalizationCoverageTests.swift.
        // Walk up to the package root, then into Sources/AnyDoor/Resources.
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent() // AnyDoorTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <repo root>
        let catalogURL = packageRoot
            .appendingPathComponent("Sources/AnyDoor/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "LocalizationCoverageTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "xcstrings did not deserialize to a dictionary"]
            )
        }
        return json
    }
}
