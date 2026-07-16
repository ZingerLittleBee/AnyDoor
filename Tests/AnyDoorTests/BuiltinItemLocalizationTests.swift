import XCTest
import PluginInterface
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
            XCTAssertNotEqual(s, item.titleKey.rawValue, "unresolved key for \(item)")
        }
    }
}
