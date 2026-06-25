# Translation History Merge-By-Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show one translation run (one input fanned out to every service) as a single history card listing every service's result, expandable to recall each full translation.

**Architecture:** Stamp every record of a run with a shared `runID` (new scalar field on `TranslationRecord`, threaded from the coordinator). A pure `groupByRun` helper merges flat rows into per-run groups; the history view renders one expandable card per group, with whole-run favorite/delete and per-service copy.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, SwiftData (lightweight migration via inline-defaulted scalar), the in-repo `.xcstrings` string-catalog build-tool plugin.

**Spec:** `docs/superpowers/specs/2026-06-24-translation-history-merge-by-run-design.md`

**Constraint:** Commits are allowed; NEVER push.

---

### Task 1: `runID` through model, store, and coordinator

Stamp every record of a run with a shared id. Backbone change; the view still
shows one card per record until Task 3, which is fine.

**Files:**
- Modify: `Sources/AnyDoor/Models/Translation/TranslationRecord.swift`
- Modify: `Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift`
- Modify: `Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift`
- Test: `Tests/AnyDoorTests/TranslationHistoryStoreTests.swift`

- [ ] **Step 1: Add the `runID` field + init param to `TranslationRecord`**

Replace the whole `TranslationRecord.swift` body of the class with (keeps every
existing field/order, adds `runID`):

```swift
@Model
final class TranslationRecord {
    var id: String = ""
    var createdAt: Date = Date()
    var sourceText: String = ""
    var translatedText: String = ""
    var sourceLangCode: String = ""
    var targetLangCode: String = ""
    var serviceID: String = ""
    var serviceName: String = ""
    var isFavorite: Bool = false
    /// Identifies the translation run this record belongs to: every service result
    /// from one `translate()` shares it, so the history view can merge a run into a
    /// single card. Empty on legacy rows, which each form their own one-record card.
    var runID: String = ""

    init(
        sourceText: String,
        translatedText: String,
        sourceLangCode: String,
        targetLangCode: String,
        serviceID: String,
        serviceName: String,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        runID: String = ""
    ) {
        self.id = UUID().uuidString
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.isFavorite = isFavorite
        self.runID = runID
    }
}
```

(Keep the file's existing `import Foundation` / `import SwiftData` and the leading
doc comment.)

- [ ] **Step 2: Thread `runID` through `TranslationHistoryStore.record`**

In `TranslationHistoryStore.swift`, the `record(...)` method gains a defaulted
`runID` parameter and passes it to the model init. Change the signature and the
`TranslationRecord(...)` construction:

Add `runID: String = "",` to the parameter list immediately before `retention: Int = 0`, and add `runID: runID` to the `TranslationRecord(...)` initializer call. The method becomes:

```swift
    func record(
        sourceText: String,
        translatedText: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        serviceID: String,
        serviceName: String,
        runID: String = "",
        retention: Int = 0
    ) {
        guard let modelContext else { return }
        let record = TranslationRecord(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLangCode: source?.code ?? "",
            targetLangCode: target.code,
            serviceID: serviceID,
            serviceName: serviceName,
            runID: runID
        )
        modelContext.insert(record)
        try? modelContext.save()
        // trim() bumps the revision; when retention is unlimited (<= 0) it
        // returns early without bumping, so bump here to cover that path.
        if retention > 0 {
            trim(retention: retention)
        } else {
            revision &+= 1
        }
    }
```

- [ ] **Step 3: Stamp + pass `currentRunID` in the coordinator**

In `TranslationCoordinator.swift`:

(a) Add the stored property right after the `currentRequest` declaration (around line 21):

```swift
    /// The id stamped onto every record written during the current run, so the
    /// history view can merge a run's per-service records into one card. Set in
    /// `translate()`; reused by `translateOne` (which records through the same
    /// `run()` path).
    private(set) var currentRunID: String = ""
```

(b) In `translate()`, immediately after `currentRequest = request`, add:

```swift
        currentRunID = UUID().uuidString
```

(c) In `recordSuccess(...)`, add `runID: currentRunID,` to the `history.record(...)` call (before `retention:`):

```swift
        history.record(
            sourceText: sourceText,
            translatedText: result.text,
            source: request.source ?? result.detected ?? detectedSource,
            target: request.target,
            serviceID: provider.id,
            serviceName: serviceName,
            runID: currentRunID,
            retention: settings.historyRetention)
```

(d) In `noteAppleSuccess(...)`, add `runID: currentRunID,` to its `history.record(...)` call (before `retention:`):

```swift
        history.record(
            sourceText: sourceText,
            translatedText: translatedText,
            source: source ?? detectedSource,
            target: target,
            serviceID: serviceID,
            serviceName: serviceName,
            runID: currentRunID,
            retention: settings.historyRetention)
```

- [ ] **Step 4: Add a store test that `runID` persists**

In `Tests/AnyDoorTests/TranslationHistoryStoreTests.swift`, add this test (after `testRecordPersists`):

```swift
    func testRecordStoresRunID() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google",
            runID: "run-123"
        )
        let row = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).first)
        XCTAssertEqual(row.runID, "run-123")
    }
```

- [ ] **Step 5: Build and test**

Run: `swift build` → expected `Build complete!`.
Run: `swift test --filter TranslationHistoryStoreTests` → expected all pass including the new `testRecordStoresRunID`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationRecord.swift Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift Tests/AnyDoorTests/TranslationHistoryStoreTests.swift
git commit -m "feat(translation): stamp history records with a per-run id"
```

---

### Task 2: Pure run-grouping helper (TDD)

A pure function that merges flat rows into per-run groups. No SwiftData, no UI —
unit-testable in isolation.

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/TranslationHistoryGrouping.swift`
- Create: `Tests/AnyDoorTests/TranslationHistoryGroupingTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/TranslationHistoryGroupingTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class TranslationHistoryGroupingTests: XCTestCase {
    private func rec(run: String, service: String, text: String, fav: Bool = false, at: TimeInterval) -> TranslationRecord {
        TranslationRecord(
            sourceText: "good",
            translatedText: text,
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: service,
            serviceName: service.capitalized,
            isFavorite: fav,
            createdAt: Date(timeIntervalSinceReferenceDate: at),
            runID: run
        )
    }

    func testSameRunIDMergesIntoOneGroup() {
        let rows = [rec(run: "r1", service: "bing", text: "很好", at: 200),
                    rec(run: "r1", service: "google", text: "好的", at: 201)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "r1")
        XCTAssertEqual(groups[0].records.count, 2)
    }

    func testEmptyRunIDRowsEachStandAlone() {
        let a = rec(run: "", service: "bing", text: "很好", at: 100)
        let b = rec(run: "", service: "google", text: "好的", at: 101)
        let groups = groupByRun([a, b])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, a.id)
        XCTAssertEqual(groups[1].id, b.id)
        XCTAssertEqual(groups[0].records.count, 1)
    }

    func testGroupOrderFollowsInputOrder() {
        // Caller passes newest-first; groups must come out in first-seen order.
        let rows = [rec(run: "rB", service: "bing", text: "b", at: 300),
                    rec(run: "rA", service: "bing", text: "a", at: 200)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups.map(\.id), ["rB", "rA"])
    }

    func testWithinGroupSortedByCreatedAtAscendingAndPrimaryIsEarliest() {
        let rows = [rec(run: "r1", service: "google", text: "late", at: 250),
                    rec(run: "r1", service: "bing", text: "early", at: 200)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups[0].records.map(\.translatedText), ["early", "late"])
        XCTAssertEqual(groups[0].primary.translatedText, "early")
    }

    func testIsFavoriteOnlyWhenAllRecordsFavorited() {
        let mixed = groupByRun([rec(run: "r1", service: "bing", text: "x", fav: true, at: 200),
                                rec(run: "r1", service: "google", text: "y", fav: false, at: 201)])
        XCTAssertFalse(mixed[0].isFavorite)
        let allFav = groupByRun([rec(run: "r2", service: "bing", text: "x", fav: true, at: 200),
                                 rec(run: "r2", service: "google", text: "y", fav: true, at: 201)])
        XCTAssertTrue(allFav[0].isFavorite)
    }

    func testCreatedAtIsGroupMax() {
        let groups = groupByRun([rec(run: "r1", service: "bing", text: "x", at: 200),
                                 rec(run: "r1", service: "google", text: "y", at: 260)])
        XCTAssertEqual(groups[0].createdAt, Date(timeIntervalSinceReferenceDate: 260))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile (no `groupByRun` yet)**

Run: `swift test --filter TranslationHistoryGroupingTests`
Expected: FAIL — `cannot find 'groupByRun' in scope` / `TranslationRunGroup`.

- [ ] **Step 3: Implement the helper**

Create `Sources/AnyDoor/Services/Translation/TranslationHistoryGrouping.swift`:

```swift
import Foundation

/// One translation run surfaced as a single history card: all the per-service
/// `TranslationRecord`s that share a `runID`. Legacy rows (empty `runID`) each form
/// their own one-record group.
struct TranslationRunGroup: Identifiable {
    /// Group key: the shared `runID`, or the lone record's own id when `runID` is empty.
    let id: String
    /// This run's records, sorted oldest-first by `createdAt`.
    let records: [TranslationRecord]

    /// The earliest record — its source text and language codes represent the run
    /// (every record in a real run shares them).
    var primary: TranslationRecord { records[0] }
    /// A run is favorited only when every one of its records is.
    var isFavorite: Bool { records.allSatisfy(\.isFavorite) }
    /// The newest timestamp in the run.
    var createdAt: Date { records.map(\.createdAt).max() ?? .distantPast }
}

/// Merge flat history rows into per-run groups. Groups are emitted in the order
/// their key is first seen, so callers passing newest-first rows get newest-first
/// groups. Within each group, records are sorted oldest-first by `createdAt`.
func groupByRun(_ rows: [TranslationRecord]) -> [TranslationRunGroup] {
    var order: [String] = []
    var buckets: [String: [TranslationRecord]] = [:]
    for row in rows {
        let key = row.runID.isEmpty ? row.id : row.runID
        if buckets[key] == nil {
            buckets[key] = []
            order.append(key)
        }
        buckets[key]?.append(row)
    }
    return order.map { key in
        let sorted = (buckets[key] ?? []).sorted { $0.createdAt < $1.createdAt }
        return TranslationRunGroup(id: key, records: sorted)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TranslationHistoryGroupingTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationHistoryGrouping.swift Tests/AnyDoorTests/TranslationHistoryGroupingTests.swift
git commit -m "feat(translation): add pure run-grouping helper for history cards"
```

---

### Task 3: Merge-by-run card UI + group mutators + drop unused label key

Render one expandable card per run, with whole-run favorite/delete and per-service
copy. Add the store's run-group mutators and remove the now-unused
`translationHistoryTranslatedLabel` key.

**Files:**
- Modify: `Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift` (add group mutators)
- Modify (full rewrite): `Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift`
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` (remove one case)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings` (remove one key)

- [ ] **Step 1: Add run-group mutators to the store**

In `TranslationHistoryStore.swift`, immediately after the existing single-record
`delete(_ record: TranslationRecord)` method, add (the single-record
`toggleFavorite`/`delete` stay — the store's tests use them; these overload on `[TranslationRecord]`):

```swift
    /// Set the favorite state of an entire run together (the history card toggles
    /// all of a run's records as one).
    func setFavorite(_ records: [TranslationRecord], to value: Bool) {
        guard let modelContext, !records.isEmpty else { return }
        for record in records { record.isFavorite = value }
        try? modelContext.save()
        revision &+= 1
    }

    /// Delete every record of a run (the history card's trash removes the whole run).
    func delete(_ records: [TranslationRecord]) {
        guard let modelContext, !records.isEmpty else { return }
        for record in records { modelContext.delete(record) }
        try? modelContext.save()
        revision &+= 1
    }
```

- [ ] **Step 2: Rewrite `TranslationHistoryView.swift`**

Replace the whole file with exactly:

```swift
import AppKit
import SwiftUI

/// In-window History + Favorites viewer presented over the translation panel
/// (a popover anchored to the toolbar's history button). Each translation run
/// (one input fanned out to every service) is shown as a single card listing every
/// service's result, newest-first, with an All / Favorites filter. Tapping a card
/// expands it to recall the full original and each service's full translation (with
/// a per-service copy button); an explicit "Re-translate" button re-runs the whole
/// run and dismisses. The favorite star and delete control act on the whole run.
/// Recall and copy are pure local reads — no network, no tokens.
///
/// Binds to `TranslationHistoryStore.shared`: the view reads the store's `revision`
/// token in `body` so `@Observable` re-renders whenever history mutates, then
/// re-fetches the current filter's rows from SwiftData and groups them by run.
struct TranslationHistoryView: View {
    let store: TranslationHistoryStore
    let coordinator: TranslationCoordinator
    /// Called after a re-translate is requested so the host can dismiss the popover.
    var onSelect: () -> Void

    private enum Filter: Hashable { case all, favorites }
    @State private var filter: Filter = .all
    /// The single currently-expanded card (single-open accordion), keyed by run id.
    @State private var expandedID: String?

    /// Soft cap on the All view so a huge history doesn't build an unbounded list;
    /// favorites are always shown in full.
    private let recentLimit = 200

    var body: some View {
        // Establish an observation dependency so the list refreshes on any store
        // mutation (the fetch methods below are not observable).
        _ = store.revision
        let groups = currentGroups()

        return VStack(spacing: 0) {
            filterPicker
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                list(groups)
            }
        }
        .frame(width: 360, height: 420)
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            LocalizedText(.translationHistoryAll).tag(Filter.all)
            LocalizedText(.translationHistoryFavorites).tag(Filter.favorites)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
        // Collapse any open card when switching filters so an expanded non-favorite
        // card doesn't reappear expanded after toggling back.
        .onChange(of: filter) { _, _ in expandedID = nil }
    }

    private func list(_ groups: [TranslationRunGroup]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(groups) { group in
                    card(group)
                }
            }
            .padding(10)
        }
    }

    private func card(_ group: TranslationRunGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(group.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.primary.sourceText)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        ForEach(group.records, id: \.id) { record in
                            HStack(spacing: 6) {
                                Text(record.translatedText)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                if !record.serviceName.isEmpty {
                                    Text("· \(record.serviceName)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Text(group.primary.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    cardControls(group)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedID == group.id {
                expandedDetail(group)
                    .padding(.top, 8)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func cardControls(_ group: TranslationRunGroup) -> some View {
        VStack(spacing: 8) {
            Button {
                store.setFavorite(group.records, to: !group.isFavorite)
            } label: {
                Image(systemName: group.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(group.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(group.isFavorite ? .translationHistoryUnfavorite : .translationHistoryFavorite))

            Button {
                if expandedID == group.id { expandedID = nil }
                store.delete(group.records)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationHistoryDelete))
        }
    }

    /// Recall detail shown when a card is expanded: full original, then each
    /// service's full translation (selectable) with its own copy button, and an
    /// explicit re-translate button. Pure local read — no network, no tokens.
    @ViewBuilder
    private func expandedDetail(_ group: TranslationRunGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                LocalizedText(.translationHistoryOriginalLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(group.primary.sourceText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(group.records, id: \.id) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(record.serviceName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            copyTranslation(record.translatedText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L(.translationCopy))
                        .help(L(.translationCopy))
                    }
                    Text(record.translatedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                retranslate(group)
            } label: {
                Label(L(.translationHistoryRetranslate), systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .favorites ? "star" : "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            LocalizedText(filter == .favorites ? .translationHistoryEmptyFavorites : .translationHistoryEmpty)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func currentGroups() -> [TranslationRunGroup] {
        switch filter {
        case .all: return groupByRun(store.recent(limit: recentLimit))
        case .favorites: return groupByRun(store.favorites())
        }
    }

    /// Single-open accordion: tapping the open card closes it, another opens it.
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id ? nil : id)
        }
    }

    /// Recall one service's stored translation onto the clipboard. Mirrors
    /// `TranslationView.copy`: notes the self-write so AnyDoor's own clipboard
    /// history ignores it, then shows the success toast.
    private func copyTranslation(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// Explicit re-translate: restore the run's direction and re-run the whole run,
    /// then dismiss. An empty source code means auto-detect.
    private func retranslate(_ group: TranslationRunGroup) {
        let record = group.primary
        coordinator.source = TranslationLanguage.named(record.sourceLangCode)
        if let target = TranslationLanguage.named(record.targetLangCode) {
            coordinator.target = target
        }
        coordinator.prefill(record.sourceText, autoTranslate: true)
        onSelect()
    }
}
```

- [ ] **Step 3: Remove the now-unused `translationHistoryTranslatedLabel` key**

(a) In `Sources/AnyDoor/Utilities/L10n.swift`, delete the line:

```swift
        case translationHistoryTranslatedLabel = "translation.history.translatedLabel"
```

(b) Remove the matching catalog entry. Run from the repo root:

```bash
python3 - <<'PY'
import json
p = "Sources/AnyDoor/Resources/Localizable.xcstrings"
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
d["strings"].pop("translation.history.translatedLabel", None)
open(p, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + ("\n" if raw.endswith("\n") else ""))
PY
```

- [ ] **Step 4: Verify no dangling references and build**

Run: `rg -n "translationHistoryTranslatedLabel|translation.history.translatedLabel" Sources` → expected: NO matches.
Run: `swift build` → expected `Build complete!` with no errors (no missing-key catalog error, no "cannot find 'translationHistoryTranslatedLabel'").
Run: `git diff --stat Sources/AnyDoor/Resources/Localizable.xcstrings` → expected 1 file changed, 0 insertions, ~17 deletions (the removed block), no reformatting.

- [ ] **Step 5: Run the full test suite**

Run: `swift test` → expected: same pass count as baseline plus the Task 1 + Task 2 additions; no regressions.

- [ ] **Step 6: Manual smoke (run the app)**

Do NOT run headless. The implementer should NOT launch `swift run AnyDoor` (interactive GUI). Leave manual verification to the controller / user:
1. A multi-service run shows ONE card listing every service's result (`translation · serviceName` lines).
2. Tapping the card expands it: full original, each service's full translation with its own copy button, a Re-translate button.
3. The star favorites the whole run; trash deletes the whole run.
4. The Favorites filter shows whole favorited cards.
5. Old (pre-`runID`) history rows still each show as one card.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(translation): merge a run into one expandable history card"
```

---

## Final verification (after all tasks)

- [ ] `swift build` clean.
- [ ] `swift test` green (includes `TranslationHistoryGroupingTests` + `testRecordStoresRunID`).
- [ ] `git log --oneline -3` shows the three feature commits, local only — nothing pushed.
- [ ] One history card per run; whole-run favorite/delete; per-service copy; old rows still one card each.

## CHANGELOG

After the feature, fold the merge-by-run behavior into the existing "Translation
history" bullet under `## [Unreleased]` in `CHANGELOG.md` (the whole translation
feature is unreleased, so this is an Added refinement, not a Changed entry). Commit
separately with `docs:`.
