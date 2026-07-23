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
