import XCTest

@testable import AnyDoor

final class SettingsWindowControllerTests: XCTestCase {
    func testInitialMountClearsFocusButReusedContentPreservesIt() {
        XCTAssertTrue(
            SettingsWindowFocusPolicy.shouldClearInitialFocus(
                didMountContent: true
            )
        )
        XCTAssertFalse(
            SettingsWindowFocusPolicy.shouldClearInitialFocus(
                didMountContent: false
            )
        )
    }
}
