import XCTest
@testable import AnyDoor

final class ImageConversionFormatTests: XCTestCase {
    func testAvailableTargetsKeepWhitelistOrderAndFilterUnsupportedEncoders() {
        let available = ImageConversionFormat.availableTargets(
            encoderTypeIdentifiers: ["public.jpeg", "com.adobe.pdf", "public.png"]
        )

        XCTAssertEqual(available, [.png, .jpeg, .pdf])
    }

    func testWebPIsNeverOfferedAsATargetEvenIfSystemReportsIt() {
        let available = ImageConversionFormat.availableTargets(
            encoderTypeIdentifiers: ["public.webp", "public.png"]
        )

        XCTAssertEqual(available, [.png])
    }
}
