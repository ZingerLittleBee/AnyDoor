import XCTest
@testable import AnyDoor

final class LocalizationCoverageTests: XCTestCase {
    func test_everyL10nKeyHasZhHansAndEnTranslations() throws {
        let catalog = try loadCatalog()
        let strings = catalog["strings"] as? [String: Any] ?? [:]

        var missing: [String] = []
        for key in L10n.Key.allCases {
            guard let entry = strings[key.rawValue] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                missing.append("\(key.rawValue) (no entry)")
                continue
            }
            for lang in ["en", "zh-Hans"] {
                let value = (((localizations[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                if value.isEmpty {
                    missing.append("\(key.rawValue) (\(lang) missing)")
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
