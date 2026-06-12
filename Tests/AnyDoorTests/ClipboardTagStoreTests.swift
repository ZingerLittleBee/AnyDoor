import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardTagStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ClipboardTagStoreTests")!
        defaults.removePersistentDomain(forName: "ClipboardTagStoreTests")
    }

    func testCreateTrimsAndPersistsAcrossReload() {
        let store = ClipboardTagStore(defaults: defaults)
        let tag = store.createTag(name: "  工作  ")
        XCTAssertEqual(tag?.name, "工作")

        let second = ClipboardTagStore(defaults: defaults)
        XCTAssertEqual(second.tags.map(\.name), ["工作"])
        XCTAssertEqual(second.tags.first?.id, tag?.id)
    }

    func testCreateRejectsEmptyAndReturnsExistingOnDuplicate() {
        let store = ClipboardTagStore(defaults: defaults)
        XCTAssertNil(store.createTag(name: "   \n"))
        let first = store.createTag(name: "工作")
        let dup = store.createTag(name: " 工作 ")
        XCTAssertEqual(dup?.id, first?.id)
        XCTAssertEqual(store.tags.count, 1)
    }

    func testRenameKeepsIDAndRejectsEmptyOrDuplicate() {
        let store = ClipboardTagStore(defaults: defaults)
        let work = store.createTag(name: "工作")!
        _ = store.createTag(name: "生活")

        store.renameTag(id: work.id, to: "  常用  ")
        XCTAssertEqual(store.name(for: work.id), "常用")

        store.renameTag(id: work.id, to: "  ")        // empty → no-op
        XCTAssertEqual(store.name(for: work.id), "常用")
        store.renameTag(id: work.id, to: "生活")       // duplicate → no-op
        XCTAssertEqual(store.name(for: work.id), "常用")
    }

    func testDeleteRemovesAndPersists() {
        let store = ClipboardTagStore(defaults: defaults)
        let work = store.createTag(name: "工作")!
        store.deleteTag(id: work.id)
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(ClipboardTagStore(defaults: defaults).tags.isEmpty)
    }

    func testOrderIsCreationOrder() {
        let store = ClipboardTagStore(defaults: defaults)
        _ = store.createTag(name: "b")
        _ = store.createTag(name: "a")
        XCTAssertEqual(store.tags.map(\.name), ["b", "a"])
    }
}
