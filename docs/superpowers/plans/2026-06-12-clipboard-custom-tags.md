# Clipboard Custom Categories (Manual Tags) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-defined clipboard categories: manual multi-tag assignment via the card context menu, tag tabs in the wall, tagged items exempt from pruning, all management inside the wall window.

**Architecture:** Tag *definitions* (id + name) live in a UserDefaults-backed `ClipboardTagStore` (JSON string under one key, whitelisted for backup sync). Tag *membership* is a `tagIDs: [String]` array on the SwiftData `ClipboardHistoryItem` (inline default → lightweight migration; the four-model schema is unchanged). `ClipboardWallCategory` gains a `.tag(id)` case; the wall's tab order becomes a function of the registry. Create/rename/delete-confirm use an in-wall SwiftUI overlay (never `NSAlert`, which would steal key status and trigger the wall's resign-key dismissal).

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI + AppKit (NSMenu submenus), SwiftData, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-12-clipboard-custom-tags-design.md`

**Conventions reminder:** code comments / commit messages in English; UI strings via `L10n` (zh-Hans + en in `Localizable.xcstrings`). Run tests with `swift test`. Commit after every task; do NOT push.

---

### Task 1: `ClipboardTag` + `ClipboardTagStore`

**Files:**
- Create: `Sources/AnyDoor/Services/ClipboardTagStore.swift`
- Test: `Tests/AnyDoorTests/ClipboardTagStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/ClipboardTagStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClipboardTagStoreTests 2>&1 | tail -5`
Expected: compile error — `ClipboardTagStore` not found.

- [ ] **Step 3: Implement**

Create `Sources/AnyDoor/Services/ClipboardTagStore.swift`:

```swift
import Foundation
import Observation

/// A user-defined clipboard category. The id is a UUID string and stays
/// stable across renames; items reference tags by id (`ClipboardHistoryItem
/// .tagIDs`), so renaming touches only this registry.
struct ClipboardTag: Codable, Equatable, Identifiable {
    let id: String
    var name: String
}

/// Registry of user-defined clipboard categories. Definitions are a small
/// JSON array persisted as a string under one UserDefaults key so they ride
/// the existing settings backup (`SyncSettingsRegistry`); membership lives on
/// the items themselves and stays machine-local, like clipboard history.
@MainActor
@Observable
final class ClipboardTagStore {
    static let shared = ClipboardTagStore()
    static let defaultsKey = "clipboard.customTags"

    @ObservationIgnored private let defaults: UserDefaults
    /// Array order is display order (creation order; no manual reordering).
    private(set) var tags: [ClipboardTag] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Re-read from UserDefaults (used after a settings backup import).
    func reload() {
        guard let json = defaults.string(forKey: Self.defaultsKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ClipboardTag].self, from: data)
        else {
            tags = []
            return
        }
        tags = decoded
    }

    func name(for id: String) -> String? {
        tags.first { $0.id == id }?.name
    }

    /// Creates a tag with the trimmed name. Returns nil for an empty name;
    /// returns the existing tag instead of creating a duplicate name.
    @discardableResult
    func createTag(name: String) -> ClipboardTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name == trimmed }) { return existing }
        let tag = ClipboardTag(id: UUID().uuidString, name: trimmed)
        tags.append(tag)
        persist()
        return tag
    }

    /// Renames in place. Empty names and names already used by another tag
    /// are rejected (no-op) so the registry never holds ambiguous entries.
    func renameTag(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !tags.contains(where: { $0.id != id && $0.name == trimmed }),
              let index = tags.firstIndex(where: { $0.id == id })
        else { return }
        tags[index].name = trimmed
        persist()
    }

    /// Removes the definition only. The caller is responsible for sweeping the
    /// id off items (`ClipboardHistoryStore.removeTagFromAllItems`) so they
    /// regain prunability; a launch-time sweep covers crash gaps.
    func deleteTag(id: String) {
        tags.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tags),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ClipboardTagStoreTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardTagStore.swift Tests/AnyDoorTests/ClipboardTagStoreTests.swift
git commit -m "feat(clipboard): add user-defined tag registry store"
```

---

### Task 2: `tagIDs` on the model + `ClipboardSearch` tag narrowing

**Files:**
- Modify: `Sources/AnyDoor/Models/ClipboardHistoryItem.swift` (field + init param)
- Modify: `Sources/AnyDoor/Services/ClipboardSearch.swift` (`filter` signature)
- Test: `Tests/AnyDoorTests/ClipboardSearchTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/AnyDoorTests/ClipboardSearchTests.swift`, after the `// MARK: - Favorites narrowing` test block, add:

```swift
    // MARK: - Tag narrowing

    func testTagIDKeepsOnlyItemsCarryingThatTag() {
        let tagged = text("tagged")
        tagged.tagIDs = ["t1", "t2"]
        let other = text("other")
        other.tagIDs = ["t9"]
        let plain = text("plain")
        let out = ClipboardSearch.filter([tagged, other, plain], category: nil,
                                         tagID: "t1", query: "")
        XCTAssertEqual(titles(out), ["tagged"])
    }

    func testTagIDComposesWithQuery() {
        let match = text("codex tagged")
        match.tagIDs = ["t1"]
        let wrongTag = text("codex other")
        let out = ClipboardSearch.filter([match, wrongTag], category: nil,
                                         tagID: "t1", query: "codex")
        XCTAssertEqual(titles(out), ["codex tagged"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClipboardSearchTests 2>&1 | tail -5`
Expected: compile error — `tagIDs` / `tagID:` not found.

- [ ] **Step 3: Implement the model field**

In `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`:

After the line `var isReferenceOnly: Bool = false` add:

```swift
    /// IDs of user-defined categories (`ClipboardTag.id`) this item belongs
    /// to. Inline default so SwiftData lightweight migration backfills
    /// existing rows. Non-empty exempts the item from pruning, like
    /// `isFavorite`.
    var tagIDs: [String] = []
```

In the `init`, after the parameter `isReferenceOnly: Bool = false` add `tagIDs: [String] = []` (comma-separated), and after `self.isReferenceOnly = isReferenceOnly` add:

```swift
        self.tagIDs = tagIDs
```

- [ ] **Step 4: Implement the filter parameter**

In `Sources/AnyDoor/Services/ClipboardSearch.swift`, replace the `filter` signature and the favorites block with:

```swift
    /// Narrow `items` to the given category, favorite flag, tag, and query.
    static func filter(_ items: [ClipboardHistoryItem],
                       category: ClipboardHistoryKind?,
                       favoritesOnly: Bool = false,
                       tagID: String? = nil,
                       query: String) -> [ClipboardHistoryItem] {
        var rows = items
        if favoritesOnly {
            rows = rows.filter(\.isFavorite)
        }
        if let tagID {
            rows = rows.filter { $0.tagIDs.contains(tagID) }
        }
        if let category {
            let raw = category.rawValue
            rows = rows.filter { $0.kind == raw }
        }
```

(The rest of the function body is unchanged.)

- [ ] **Step 5: Run to verify pass, then run the full suite**

Run: `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: 0 failures (the new field must not break existing store tests — the in-memory container migrates trivially).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Models/ClipboardHistoryItem.swift Sources/AnyDoor/Services/ClipboardSearch.swift Tests/AnyDoorTests/ClipboardSearchTests.swift
git commit -m "feat(clipboard): store tag membership on items and filter by tag"
```

---

### Task 3: `ClipboardHistoryStore` tag methods + pruning/timeline exemption

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift` (launch-time sweep)
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift` (inside the class; it already has `makeContainer()` and `@MainActor`):

```swift
    func testToggleTagAddsAndRemoves() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let item = ClipboardHistoryItem(kind: .text, text: "a", previewTitle: "a")
        container.mainContext.insert(item)
        try container.mainContext.save()

        await store.toggleTag(item, tagID: "t1")
        XCTAssertEqual(item.tagIDs, ["t1"])
        await store.toggleTag(item, tagID: "t1")
        XCTAssertEqual(item.tagIDs, [])
    }

    func testPruneExemptsTaggedItems() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 2)
        store.bootstrap(modelContainer: container)
        let context = container.mainContext

        let oldTagged = ClipboardHistoryItem(kind: .ocr, text: "oldTagged", previewTitle: "oldTagged",
                                             createdAt: now.addingTimeInterval(-8 * 86_400))
        oldTagged.tagIDs = ["t1"]
        context.insert(oldTagged)
        // Overflow pressure: 4 fresh rows with a 2-per-kind cap.
        for index in 0..<4 {
            let row = ClipboardHistoryItem(kind: .ocr, text: "\(index)", previewTitle: "\(index)",
                                           createdAt: now.addingTimeInterval(TimeInterval(index)))
            if index == 0 { row.tagIDs = ["t1"] }   // oldest fresh row, tagged
            context.insert(row)
        }
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)

        let survivors = try context.fetch(FetchDescriptor<ClipboardHistoryItem>()).map(\.text)
        XCTAssertTrue(survivors.contains("oldTagged"))   // age-exempt
        XCTAssertTrue(survivors.contains("0"))           // overflow-exempt
        XCTAssertFalse(survivors.contains("1"))          // untagged overflow goes
    }

    func testRemoveTagFromAllItemsRestoresPrunability() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let expired = ClipboardHistoryItem(kind: .text, text: "expired", previewTitle: "expired",
                                           createdAt: now.addingTimeInterval(-8 * 86_400))
        expired.tagIDs = ["t1"]
        context.insert(expired)
        try context.save()

        await store.removeTagFromAllItems("t1")
        XCTAssertEqual(expired.tagIDs, [])
        await store.pruneExpiredAndOverflow(force: true)
        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertTrue(rows.isEmpty)
    }

    func testCleanUpUnknownTagsDropsStaleIDsOnly() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let item = ClipboardHistoryItem(kind: .text, text: "a", previewTitle: "a")
        item.tagIDs = ["alive", "ghost"]
        context.insert(item)
        try context.save()

        await store.cleanUpUnknownTags(validIDs: ["alive"])
        XCTAssertEqual(item.tagIDs, ["alive"])
    }

    func testTimelineKeepsOldTaggedItems() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)
        let context = container.mainContext
        let oldTagged = ClipboardHistoryItem(kind: .text, text: "oldTagged", previewTitle: "oldTagged",
                                             createdAt: now.addingTimeInterval(-8 * 86_400))
        oldTagged.tagIDs = ["t1"]
        context.insert(oldTagged)
        let oldPlain = ClipboardHistoryItem(kind: .text, text: "oldPlain", previewTitle: "oldPlain",
                                            createdAt: now.addingTimeInterval(-8 * 86_400))
        context.insert(oldPlain)
        try context.save()

        let titles = store.timeline(category: nil, query: "").map(\.previewTitle)
        XCTAssertTrue(titles.contains("oldTagged"))
        XCTAssertFalse(titles.contains("oldPlain"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClipboardHistoryStoreTests 2>&1 | tail -5`
Expected: compile error — `toggleTag` not found.

- [ ] **Step 3: Implement the store methods**

In `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`, after `toggleFavorite` add:

```swift
    /// Toggle a custom-category tag on one item. Tagged items are exempt from
    /// pruning, like favorites.
    func toggleTag(_ item: ClipboardHistoryItem, tagID: String) async {
        guard let container = modelContainer else { return }
        if let index = item.tagIDs.firstIndex(of: tagID) {
            item.tagIDs.remove(at: index)
        } else {
            item.tagIDs.append(tagID)
        }
        try? container.mainContext.save()
        if let kind = item.historyKind { await reload(kind: kind) }
    }

    /// Strip a deleted tag's id from every item so the tag stops blocking
    /// pruning. Called when the user deletes a tag definition.
    func removeTagFromAllItems(_ tagID: String) async {
        guard let container = modelContainer else { return }
        let all = (try? container.mainContext.fetch(FetchDescriptor<ClipboardHistoryItem>())) ?? []
        var changed = false
        for item in all where item.tagIDs.contains(tagID) {
            item.tagIDs.removeAll { $0 == tagID }
            changed = true
        }
        if changed { try? container.mainContext.save() }
    }

    /// Launch-time hygiene: drop tag ids that no longer exist in the registry
    /// (covers a crash between a registry delete and the item sweep), so a
    /// stale id cannot exempt items from pruning forever.
    func cleanUpUnknownTags(validIDs: Set<String>) async {
        guard let container = modelContainer else { return }
        let all = (try? container.mainContext.fetch(FetchDescriptor<ClipboardHistoryItem>())) ?? []
        var changed = false
        for item in all where item.tagIDs.contains(where: { !validIDs.contains($0) }) {
            item.tagIDs.removeAll { !validIDs.contains($0) }
            changed = true
        }
        if changed { try? container.mainContext.save() }
    }
```

- [ ] **Step 4: Extend the pruning exemption**

In `pruneExpiredAndOverflow`, replace:

```swift
            // Favorites are exempt from both the age sweep and the overflow trim.
            for item in all where !item.isFavorite && item.createdAt < cutoff {
                idsToDelete.insert(item.id)
            }

            for kind in ClipboardHistoryKind.allCases {
                let rows = all
                    .filter { $0.kind == kind.rawValue && !$0.isFavorite && !idsToDelete.contains($0.id) }
```

with:

```swift
            // Favorites and tagged items are exempt from both the age sweep
            // and the overflow trim.
            for item in all where !item.isFavorite && item.tagIDs.isEmpty && item.createdAt < cutoff {
                idsToDelete.insert(item.id)
            }

            for kind in ClipboardHistoryKind.allCases {
                let rows = all
                    .filter { $0.kind == kind.rawValue && !$0.isFavorite && $0.tagIDs.isEmpty && !idsToDelete.contains($0.id) }
```

- [ ] **Step 5: Switch `timeline` to in-memory exemption filtering**

Replace the body section of `timeline(category:query:)`:

```swift
    func timeline(category: ClipboardHistoryKind?, query: String) -> [ClipboardHistoryItem] {
        guard let container = modelContainer else { return [] }
        let cutoff = now().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<ClipboardHistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? container.mainContext.fetch(descriptor)) ?? []
        // Favorites and tagged items are exempt from pruning, so keep them
        // visible past the retention cutoff too. Array emptiness is not
        // reliably expressible in #Predicate, so filter in memory — row
        // counts are capped per kind, this is cheap.
        let visible = rows.filter { $0.createdAt >= cutoff || $0.isFavorite || !$0.tagIDs.isEmpty }
        return ClipboardSearch.filter(visible, category: category, query: query)
    }
```

(Note: `descriptor` becomes `let`; the old `descriptor.predicate = ...` line is removed.)

- [ ] **Step 6: Launch-time sweep in AppDelegate**

In `Sources/AnyDoor/AppDelegate.swift`, directly after the line
`ClipboardHistoryStore.shared.bootstrap(modelContainer: modelContainer)` add:

```swift
        // Drop tag ids whose definition no longer exists (crash between a
        // registry delete and the item sweep) so they can't block pruning.
        Task {
            await ClipboardHistoryStore.shared.cleanUpUnknownTags(
                validIDs: Set(ClipboardTagStore.shared.tags.map(\.id))
            )
        }
```

- [ ] **Step 7: Run the full suite**

Run: `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Sources/AnyDoor/AppDelegate.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): exempt tagged items from pruning and add tag mutations"
```

---

### Task 4: `.tag` category case, dynamic tab order, dialog state, L10n keys

**Files:**
- Modify: `Sources/AnyDoor/Views/ClipboardWallState.swift`
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`
- Test: `Tests/AnyDoorTests/ClipboardWallStateTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/AnyDoorTests/ClipboardWallStateTests.swift`:

Replace `testCategoryCyclingWrapsBothWays` (it references the now-changing static) with:

```swift
    func testCategoryCyclingWrapsBothWays() {
        let state = ClipboardWallState()
        XCTAssertEqual(state.category, .all)
        state.selectNextCategory()
        XCTAssertEqual(state.category, .favorites)
        state.selectPreviousCategory()
        XCTAssertEqual(state.category, .all)
        // Wrap backwards from the first tab to the last, and forward again.
        state.selectPreviousCategory()
        XCTAssertEqual(state.category, state.categories.last)
        state.selectNextCategory()
        XCTAssertEqual(state.category, .all)
    }

    func testCyclingIncludesCustomTags() {
        let state = ClipboardWallState()
        let tags = [ClipboardTag(id: "t1", name: "工作")]
        state.setCategories(ClipboardWallState.order(tags: tags))
        state.selectNextCategory()   // .all → .favorites
        state.selectNextCategory()   // .favorites → .tag("t1")
        XCTAssertEqual(state.category, .tag("t1"))
    }

    func testSetCategoriesFallsBackToAllWhenActiveTagRemoved() {
        let state = ClipboardWallState()
        state.setCategories(ClipboardWallState.order(tags: [ClipboardTag(id: "t1", name: "工作")]))
        state.category = .tag("t1")
        state.setCategories(ClipboardWallState.order(tags: []))
        XCTAssertEqual(state.category, .all)
    }

    func testTagFilterAccessors() {
        XCTAssertEqual(ClipboardWallCategory.tag("t1").tagFilter, "t1")
        XCTAssertNil(ClipboardWallCategory.tag("t1").kindFilter)
        XCTAssertNil(ClipboardWallCategory.all.tagFilter)
        XCTAssertNil(ClipboardWallCategory.tag("t1").titleKey)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClipboardWallStateTests 2>&1 | tail -5`
Expected: compile error — `.tag` / `order(tags:)` / `setCategories` not found.

- [ ] **Step 3: Implement the category model + state**

In `Sources/AnyDoor/Views/ClipboardWallState.swift`:

Replace the whole `ClipboardWallCategory` enum with:

```swift
/// A clipboard-wall filter tab. `favorites` and `tag` cut across kinds, so
/// they are their own cases rather than a `ClipboardHistoryKind`.
enum ClipboardWallCategory: Equatable {
    case all
    case favorites
    case kind(ClipboardHistoryKind)
    /// A user-defined category; the payload is the `ClipboardTag.id`.
    case tag(String)

    /// L10n key for builtin tabs; nil for custom tags, whose free-form names
    /// come from `ClipboardTagStore` instead.
    var titleKey: L10n.Key? {
        switch self {
        case .all: return .clipboardCategoryAll
        case .favorites: return .clipboardCategoryFavorites
        case .kind(let kind): return kind.titleKey
        case .tag: return nil
        }
    }

    /// The kind to narrow by; nil for the cross-kind tabs.
    var kindFilter: ClipboardHistoryKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }

    /// The tag id to narrow by; nil for builtin tabs.
    var tagFilter: String? {
        if case .tag(let id) = self { return id }
        return nil
    }
}
```

Replace the `static let categoryOrder` block with:

```swift
    /// Tab display order: All and Favorites, then the user's custom tags in
    /// registry order, then the kind tabs.
    static func order(tags: [ClipboardTag]) -> [ClipboardWallCategory] {
        [.all, .favorites]
            + tags.map { .tag($0.id) }
            + [.kind(.text), .kind(.image), .kind(.file),
               .kind(.screenshot), .kind(.color), .kind(.ocr), .kind(.qrcode)]
    }

    /// The current tab order; the view pushes a fresh order in whenever the
    /// tag registry changes. Kept on the state so Tab-cycling is testable.
    private(set) var categories: [ClipboardWallCategory] = ClipboardWallState.order(tags: [])

    func setCategories(_ order: [ClipboardWallCategory]) {
        categories = order
        // The active tag may have just been deleted; never strand the wall on
        // a tab that no longer exists.
        if !order.contains(category) { category = .all }
    }
```

Update `stepCategory` to use the instance order:

```swift
    private func stepCategory(by delta: Int) {
        let order = categories
        let current = order.firstIndex(of: category) ?? 0
        category = order[(current + delta + order.count) % order.count]
    }
```

Then add the dialog state inside `ClipboardWallState` (after `selectedIndex`):

```swift
    /// The in-wall tag dialog (create / rename / delete-confirm). Rendered as
    /// an overlay by `ClipboardWallView`; the window controller routes Return
    /// and Esc to commit/cancel while this is non-nil.
    enum TagDialog {
        case create(item: ClipboardHistoryItem)
        case rename(tagID: String)
        case confirmDelete(tagID: String)
    }
    var tagDialog: TagDialog?
    /// Backing text for the dialog's name field.
    var tagDialogText: String = ""
```

- [ ] **Step 4: Add the L10n keys**

In `Sources/AnyDoor/Utilities/L10n.swift`, after `case clipboardActionRevealInFinder ...` add (keeping the list alphabetically grouped with the other clipboard keys):

```swift
        case clipboardActionAddToTag = "clipboard.action.addToTag"
```

and after `case clipboardKindText ...`-style clipboard keys (next to the other `clipboardTag*`-free area, e.g. right after `clipboardHintSelect`), add:

```swift
        case clipboardTagConfirm = "clipboard.tag.confirm"
        case clipboardTagCreateTitle = "clipboard.tag.createTitle"
        case clipboardTagDelete = "clipboard.tag.delete"
        case clipboardTagDeletePrompt = "clipboard.tag.deletePrompt"
        case clipboardTagNamePlaceholder = "clipboard.tag.namePlaceholder"
        case clipboardTagNew = "clipboard.tag.new"
        case clipboardTagRename = "clipboard.tag.rename"
        case clipboardTagRenameTitle = "clipboard.tag.renameTitle"
```

In `Sources/AnyDoor/Resources/Localizable.xcstrings`, add these entries (alphabetical position; the file is a flat JSON dictionary under `"strings"` — follow the exact shape of `"clipboard.category.favorites"`):

| key | en | zh-Hans |
|---|---|---|
| `clipboard.action.addToTag` | `Add to Category` | `添加到分类` |
| `clipboard.tag.confirm` | `OK` | `确定` |
| `clipboard.tag.createTitle` | `New Category` | `新建分类` |
| `clipboard.tag.delete` | `Delete…` | `删除…` |
| `clipboard.tag.deletePrompt` | `Delete category "%@"? Items are kept; they just become prunable again.` | `删除分类「%@」？条目不会被删除，仅恢复自动清理。` |
| `clipboard.tag.namePlaceholder` | `Category name` | `分类名称` |
| `clipboard.tag.new` | `New Category…` | `新建分类…` |
| `clipboard.tag.rename` | `Rename…` | `重命名…` |
| `clipboard.tag.renameTitle` | `Rename Category` | `重命名分类` |

Each entry looks like:

```json
    "clipboard.tag.confirm": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "OK" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "确定" } }
      }
    },
```

- [ ] **Step 5: Fix the two compile sites that used the old API**

`Sources/AnyDoor/Views/ClipboardWallView.swift` references `ClipboardWallState.categoryOrder` and non-optional `titleKey`; patch minimally so the target compiles (full UI work is Task 5):

- `ForEach(Array(ClipboardWallState.categoryOrder.enumerated()), ...)` → `ForEach(Array(state.categories.enumerated()), ...)`
- `LocalizedText(cat.titleKey)` → temporarily `LocalizedText(cat.titleKey ?? .clipboardCategoryAll)` (Task 5 replaces this with proper tag-name rendering).

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallState.swift Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings Tests/AnyDoorTests/ClipboardWallStateTests.swift
git commit -m "feat(clipboard): add tag category case, dynamic tab order, dialog state"
```

---

### Task 5: Tab row UI (scroll, tag tabs, tab context menu) + card submenu

**Files:**
- Modify: `Sources/AnyDoor/Views/ClipboardWallView.swift`
- Modify: `Sources/AnyDoor/Views/ClipboardCardView.swift`
- Modify: `Sources/AnyDoor/Views/RightClickMenu.swift` (optional icon)
- Modify: `Sources/AnyDoor/Views/ClipboardWallWindowController.swift` (closure wiring + tab-row scroll exemption)

- [ ] **Step 1: Make `ClosureMenuItem`'s icon optional**

In `Sources/AnyDoor/Views/RightClickMenu.swift`, change the init:

```swift
    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }
```

(Tag entries in the submenu carry a checkmark via `state`, not an icon.)

- [ ] **Step 2: Card context menu — "Add to Category" submenu**

In `Sources/AnyDoor/Views/ClipboardCardView.swift`:

Add the two new callbacks after `var onRevealInFinder`:

```swift
    var onToggleTag: ((String) -> Void)? = nil
    var onNewTag: (() -> Void)? = nil
```

In `makeContextMenu()`, after the favorite `ClosureMenuItem` block and before the `if let onDelete` block, insert:

```swift
        if let submenu = makeTagSubmenu() { menu.addItem(submenu) }
```

and add the builder below `makeContextMenu()`:

```swift
    /// "Add to Category ▸": checkable entries for every user-defined tag plus
    /// "New Category…". Built at click time so registry order, names, and the
    /// item's membership are current.
    private func makeTagSubmenu() -> NSMenuItem? {
        guard let onToggleTag, let onNewTag else { return nil }
        let parent = NSMenuItem(title: L(.clipboardActionAddToTag), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tag in ClipboardTagStore.shared.tags {
            let entry = ClosureMenuItem(title: tag.name) { onToggleTag(tag.id) }
            entry.state = item.tagIDs.contains(tag.id) ? .on : .off
            submenu.addItem(entry)
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem(title: L(.clipboardTagNew), systemImage: "plus", handler: onNewTag))
        parent.submenu = submenu
        return parent
    }
```

- [ ] **Step 3: Tab row — registry-driven tabs, tag titles, tab context menu, horizontal scroll**

In `Sources/AnyDoor/Views/ClipboardWallView.swift`:

Add the new injected closures after `let onDelete`:

```swift
    let onToggleTag: (ClipboardHistoryItem, String) -> Void
    let onNewTag: (ClipboardHistoryItem) -> Void
```

Update `filtered` to pass the tag filter:

```swift
    private var filtered: [ClipboardHistoryItem] {
        ClipboardSearch.filter(allItems,
                               category: state.category.kindFilter,
                               favoritesOnly: state.category == .favorites,
                               tagID: state.category.tagFilter,
                               query: state.query)
    }
```

Keep the tab order in sync with the registry — on the outer `VStack` (next to the existing `.onAppear` / `.onChange(of: items.map(\.id))`) add:

```swift
        .onAppear { state.setCategories(ClipboardWallState.order(tags: ClipboardTagStore.shared.tags)) }
        .onChange(of: ClipboardTagStore.shared.tags) { _, newTags in
            state.setCategories(ClipboardWallState.order(tags: newTags))
        }
```

Replace the whole `tabs` property with:

```swift
    private var tabs: some View {
        HStack(spacing: 8) {
            // Horizontal scroll so many custom tags can't push the search
            // field out of the window.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(state.categories.enumerated()), id: \.offset) { _, cat in
                        tabCapsule(cat)
                    }
                }
            }
            Spacer()
            // A real, focusable field so an IME can compose CJK search text. The
            // controller toggles focus between this field (input mode) and card
            // navigation; see ClipboardWallWindowController.handle(_:).
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                WallSearchField(state: state, registerField: registerSearchField)
                    .frame(height: 18)
            }
            .frame(width: 160)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func tabCapsule(_ cat: ClipboardWallCategory) -> some View {
        let active = state.category == cat
        Button {
            state.category = cat
        } label: {
            HStack(spacing: 3) {
                if cat == .favorites {
                    Image(systemName: "star.fill").font(.system(size: 8))
                }
                if let key = cat.titleKey {
                    LocalizedText(key)
                } else if let id = cat.tagFilter {
                    Text(ClipboardTagStore.shared.name(for: id) ?? "")
                }
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        // The active capsule is the selection indicator; a keyboard
        // focus ring on top of it (Tab is claimed for tab cycling
        // anyway) just adds noise.
        .focusEffectDisabled()
        .overlay {
            // Custom tags are managed from their own tab; builtins have no menu.
            if let id = cat.tagFilter {
                RightClickMenu(makeMenu: { tagTabMenu(tagID: id) })
            }
        }
    }

    /// Rename / delete for a custom tag tab. Both open the in-wall dialog
    /// overlay; deletion asks for confirmation because items lose their
    /// retention exemption.
    private func tagTabMenu(tagID: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L(.clipboardTagRename), systemImage: "pencil") {
            state.tagDialogText = ClipboardTagStore.shared.name(for: tagID) ?? ""
            state.isSearchFocused = false
            state.tagDialog = .rename(tagID: tagID)
        })
        menu.addItem(ClosureMenuItem(title: L(.clipboardTagDelete), systemImage: "trash") {
            state.tagDialog = .confirmDelete(tagID: tagID)
        })
        return menu
    }
```

Wire the card closures inside `cards(_:)` — after `onRevealInFinder: ...` add:

```swift
                            onToggleTag: { state.select(index); onToggleTag(item, $0) },
                            onNewTag: { state.select(index); onNewTag(item) },
```

- [ ] **Step 4: Controller wiring + tab-row scroll exemption**

In `Sources/AnyDoor/Views/ClipboardWallWindowController.swift`:

In `makeWallView()`, after the `onRevealInFinder:` line add:

```swift
            onToggleTag: { item, tagID in
                Task { await ClipboardHistoryStore.shared.toggleTag(item, tagID: tagID) }
            },
            onNewTag: { [weak self] item in
                self?.state.tagDialogText = ""
                self?.state.isSearchFocused = false
                self?.state.tagDialog = .create(item: item)
            },
```

In `handleScroll(_:)`, right after the existing `if ClipboardTextWindow.shared.owns(event.window) { return false }` line, add:

```swift
        // The tab row hosts its own horizontal ScrollView; let scrolls over
        // that strip reach it instead of becoming card navigation.
        if let window, event.window === window,
           event.locationInWindow.y > window.contentLayoutRect.maxY - 48 {
            return false
        }
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error|Build"` then `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: build complete, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/Views/ClipboardCardView.swift Sources/AnyDoor/Views/RightClickMenu.swift Sources/AnyDoor/Views/ClipboardWallWindowController.swift
git commit -m "feat(clipboard): tag tabs, card add-to-category submenu, tab menus"
```

---

### Task 6: In-wall dialog overlay + key routing + commit logic

**Files:**
- Modify: `Sources/AnyDoor/Views/ClipboardWallView.swift` (overlay)
- Modify: `Sources/AnyDoor/Views/ClipboardWallWindowController.swift` (key gate + commit/cancel)

- [ ] **Step 1: Controller commit/cancel + key gate**

In `Sources/AnyDoor/Views/ClipboardWallWindowController.swift`:

Add the two methods near `beginEdit` / `copyWithoutPasting`:

```swift
    /// Commit the in-wall tag dialog. Create assigns the new (or existing
    /// same-named) tag to the right-clicked item in one step; rename and
    /// delete go through the registry, and delete additionally sweeps the id
    /// off all items so they regain prunability.
    private func commitTagDialog() {
        guard let dialog = state.tagDialog else { return }
        switch dialog {
        case .create(let item):
            // Empty name → keep the dialog open instead of silently closing.
            guard let tag = ClipboardTagStore.shared.createTag(name: state.tagDialogText) else { return }
            if !item.tagIDs.contains(tag.id) {
                Task { await ClipboardHistoryStore.shared.toggleTag(item, tagID: tag.id) }
            }
        case .rename(let tagID):
            let trimmed = state.tagDialogText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            ClipboardTagStore.shared.renameTag(id: tagID, to: trimmed)
        case .confirmDelete(let tagID):
            ClipboardTagStore.shared.deleteTag(id: tagID)
            Task { await ClipboardHistoryStore.shared.removeTagFromAllItems(tagID) }
        }
        cancelTagDialog()
    }

    private func cancelTagDialog() {
        state.tagDialog = nil
        state.tagDialogText = ""
    }
```

In `handle(_:)`, directly after `if let consumed = routeToTextWindow(event) { return consumed }`, add:

```swift
        // While the tag dialog overlay is up it owns the keyboard: Return
        // commits, Esc cancels, everything else flows to its text field.
        if state.tagDialog != nil {
            switch event.keyCode {
            case 53: cancelTagDialog(); return true
            case 36, 76: commitTagDialog(); return true
            default: return false
            }
        }
```

- [ ] **Step 2: Overlay view**

In `Sources/AnyDoor/Views/ClipboardWallView.swift`:

Add the injected commit/cancel closures after `let onNewTag`:

```swift
    let onTagDialogCommit: () -> Void
    let onTagDialogCancel: () -> Void
```

(and wire them in the controller's `makeWallView()` after `onNewTag:`:)

```swift
            onTagDialogCommit: { [weak self] in self?.commitTagDialog() },
            onTagDialogCancel: { [weak self] in self?.cancelTagDialog() },
```

This requires `commitTagDialog`/`cancelTagDialog` to be callable — they are `private` methods on the controller, referenced from inside the controller, which is fine.

Add a focus state property to `ClipboardWallView`:

```swift
    @FocusState private var tagFieldFocused: Bool
```

On the outer `VStack` (after the `.onChange(of: ClipboardTagStore.shared.tags)` modifier) add:

```swift
        .overlay { if state.tagDialog != nil { tagDialogOverlay } }
```

And add the overlay views at the bottom of the struct:

```swift
    /// Create / rename / delete-confirm card. Lives inside the wall window —
    /// an app-modal NSAlert would steal key status and trip the wall's
    /// resign-key dismissal.
    private var tagDialogOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { onTagDialogCancel() }
            VStack(spacing: 12) {
                switch state.tagDialog {
                case .create:
                    LocalizedText(.clipboardTagCreateTitle).font(.headline)
                    tagNameField
                case .rename:
                    LocalizedText(.clipboardTagRenameTitle).font(.headline)
                    tagNameField
                case .confirmDelete(let tagID):
                    Text(L(.clipboardTagDeletePrompt, ClipboardTagStore.shared.name(for: tagID) ?? ""))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
                HStack(spacing: 8) {
                    Button(action: onTagDialogCancel) { LocalizedText(.clipboardEditCancel) }
                    Button(action: onTagDialogCommit) {
                        LocalizedText(isDeleteDialog ? .clipboardActionDelete : .clipboardTagConfirm)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var isDeleteDialog: Bool {
        if case .confirmDelete = state.tagDialog { return true }
        return false
    }

    private var tagNameField: some View {
        TextField(L(.clipboardTagNamePlaceholder), text: Bindable(state).tagDialogText)
            .textFieldStyle(.roundedBorder)
            .focused($tagFieldFocused)
            .onAppear { tagFieldFocused = true }
    }
```

Note: `state` is already `@Bindable var state` on the view, so `$state.tagDialogText` also works; use whichever compiles (`$state.tagDialogText` preferred).

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error|Build"` then `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: build complete, 0 failures.

- [ ] **Step 4: Manual smoke test**

Run: `swift run AnyDoor` (needs Accessibility) and verify:
1. Card right-click → 添加到分类 ▸ 新建分类… → overlay opens, typing works (CJK too), Return creates the tag, the tab appears after 收藏, the card is in it.
2. Submenu shows the tag with a checkmark; clicking it removes membership.
3. Tag tab right-click → 重命名…: prefilled name, Return applies. 删除…: confirm card, Return deletes; the wall falls back to 全部 if that tab was active.
4. Esc in a dialog cancels and does NOT close the wall; Esc again closes the wall.
5. Tab key cycles through the custom tab too.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/Views/ClipboardWallWindowController.swift
git commit -m "feat(clipboard): in-wall tag dialogs for create, rename, delete"
```

---

### Task 7: Backup sync + CHANGELOG

**Files:**
- Modify: `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`
- Modify: `Sources/AnyDoor/Services/BackupService.swift`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Whitelist the registry key**

In `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`, add to `entries`:

```swift
        Entry(key: "clipboard.customTags", type: .string),
```

- [ ] **Step 2: Reload the tag store after import**

In `Sources/AnyDoor/Services/BackupService.swift`, inside `reconcileAfterImport()`, add alongside the other `reloadFromDefaults()` calls:

```swift
        ClipboardTagStore.shared.reload()
```

- [ ] **Step 3: CHANGELOG entry**

In `CHANGELOG.md` under `## [Unreleased]` → `### Added` (create the subsection if absent), add:

```markdown
- Clipboard wall: user-defined categories. Right-click a card → "Add to Category" to tag it (multi-tag, checkable submenu, "New Category…" inline); custom tabs appear after Favorites and are renamed/deleted from their own right-click menu. Tagged items are exempt from automatic cleanup, like favorites; deleting a category keeps its items and only restores normal retention. Category definitions are included in settings backup.
```

- [ ] **Step 4: Full suite + commit**

Run: `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -2`
Expected: 0 failures.

```bash
git add Sources/AnyDoor/Services/SyncSettingsRegistry.swift Sources/AnyDoor/Services/BackupService.swift CHANGELOG.md
git commit -m "feat(clipboard): sync custom tag definitions via settings backup"
```

---

## Self-review notes

- Spec coverage: data model (T1/T2), retention + hygiene (T3), category model + fallback (T4), tab UI + menus (T5), overlay dialogs + key routing (T6), sync + docs (T7). The spec's "no tag badge on cards" and "no reordering" are deliberate omissions, not gaps.
- Type consistency: `ClipboardTag(id:name:)`, `createTag(name:) -> ClipboardTag?`, `toggleTag(_:tagID:)`, `tagFilter: String?`, `TagDialog` cases — names match across tasks.
- The Task 4 temporary `?? .clipboardCategoryAll` in the view is replaced in Task 5; both tasks compile and pass tests independently.
