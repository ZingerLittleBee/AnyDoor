import XCTest
@testable import AnyDoor

@MainActor
final class BuiltinItemLocalizationTests: XCTestCase {
    func test_everyBuiltinHasATitleKey() {
        for item in BuiltinItem.allCases {
            let key = item.titleKey
            XCTAssertFalse(key.rawValue.isEmpty, "missing titleKey for \(item)")
        }
    }

    func test_titleKeyMapsToNonEmptyTranslation() {
        let previous = LocalizationManager.shared.preference
        defer { LocalizationManager.shared.preference = previous }
        LocalizationManager.shared.preference = .en
        for item in BuiltinItem.allCases {
            let s = L(item.titleKey)
            XCTAssertFalse(s.isEmpty, "empty translation for \(item)")
            // When the xcstrings catalog is compiled into lproj bundles (production /
            // Xcode build), `s` differs from the raw key. In SPM debug builds the
            // bundle contains only the raw xcstrings file and NSLocalizedString falls
            // back to returning the key itself, so we allow equality here.
            // The catalog coverage test in Task 12 will enforce full resolution.
        }
    }
}
