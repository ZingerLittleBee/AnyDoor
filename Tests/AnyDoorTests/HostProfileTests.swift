import XCTest
import SwiftData
@testable import AnyDoor

final class HostProfileTests: XCTestCase {
    func test_init_setsDefaultsAndTimestamps() throws {
        let p = HostProfile(name: "Dev", content: "1.2.3.4 dev")
        XCTAssertEqual(p.name, "Dev")
        XCTAssertEqual(p.content, "1.2.3.4 dev")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.displayOrder, 0)
        XCTAssertEqual(p.createdAt.timeIntervalSince1970,
                       p.updatedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    @MainActor
    func test_persistsInInMemoryContainer() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        let container = try ModelContainer(for: HostProfile.self, configurations: config)
        let ctx = container.mainContext
        ctx.insert(HostProfile(name: "A", content: "x", isActive: true, displayOrder: 100))
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<HostProfile>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isActive)
    }
}
