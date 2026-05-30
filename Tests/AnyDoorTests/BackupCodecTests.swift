import XCTest
@testable import AnyDoor

final class BackupCodecTests: XCTestCase {

    func testSettingValueEncodesAndDecodesEachCase() throws {
        let values: [SettingValue] = [.bool(true), .int(42), .string("hi")]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([SettingValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }
}
