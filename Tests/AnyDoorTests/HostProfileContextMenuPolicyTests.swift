import XCTest

@testable import HostsPlugin

final class HostProfileContextMenuPolicyTests: XCTestCase {
    func testInactiveProfileOffersEnableBeforeEditingActions() {
        XCTAssertEqual(
            HostProfileContextMenuPolicy.actions(isActive: false),
            [.enable, .rename, .duplicate, .delete]
        )
    }

    func testActiveProfileOffersDestructiveDisableBeforeEditingActions() {
        let actions = HostProfileContextMenuPolicy.actions(isActive: true)

        XCTAssertEqual(actions, [.disable, .rename, .duplicate, .delete])
        XCTAssertTrue(actions[0].isDestructive)
        XCTAssertTrue(actions[3].isDestructive)
        XCTAssertFalse(actions[1].isDestructive)
        XCTAssertFalse(actions[2].isDestructive)
    }
}
