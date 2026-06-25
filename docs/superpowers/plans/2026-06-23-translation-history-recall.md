# Translation History Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tapping a translation history/favorites row recall the stored result inline (no re-translate), with copy and an explicit "Re-translate" button.

**Architecture:** A single SwiftUI view (`TranslationHistoryView`) gains a single-open accordion: the row's primary tap toggles an `expandedID` instead of re-translating. The expanded detail reads the record's already-stored `sourceText` / `translatedText` (no network, no tokens), offers a local copy, and moves the old re-translate logic behind an explicit button. No model/store/coordinator changes.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSPasteboard`), the in-repo `.xcstrings` string-catalog build-tool plugin (missing keys fail `swift build`).

**Spec:** `docs/superpowers/specs/2026-06-23-translation-history-recall-design.md`

**Constraint:** Local commits only — never push.

---

### Task 1: Localization keys

Add three new keys used by the recall UI. They must exist in BOTH the `L10n.Key`
enum AND the `.xcstrings` catalog, or the string-catalog build-tool plugin fails
`swift build`.

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` (after line 546, the `translationHistory*` group)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the three `L10n.Key` cases**

Use Edit on `Sources/AnyDoor/Utilities/L10n.swift`. Find this exact line:

```swift
        case translationHistoryUnfavorite = "translation.history.unfavorite"
```

Replace it with:

```swift
        case translationHistoryUnfavorite = "translation.history.unfavorite"
        case translationHistoryRetranslate = "translation.history.retranslate"
        case translationHistoryOriginalLabel = "translation.history.originalLabel"
        case translationHistoryTranslatedLabel = "translation.history.translatedLabel"
```

- [ ] **Step 2: Add the three `.xcstrings` entries**

Run this script (verified to round-trip the catalog byte-identically, so the diff
is only the three appended entries). From the repo root:

```bash
python3 - <<'PY'
import json
p = "Sources/AnyDoor/Resources/Localizable.xcstrings"
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
def add(key, en, zh):
    d["strings"][key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        },
    }
add("translation.history.retranslate", "Re-translate", "重新翻译")
add("translation.history.originalLabel", "Original", "原文")
add("translation.history.translatedLabel", "Translation", "译文")
out = json.dumps(d, ensure_ascii=False, indent=2)
open(p, "w", encoding="utf-8").write(out + ("\n" if raw.endswith("\n") else ""))
PY
```

- [ ] **Step 3: Verify only the intended entries changed**

Run: `git diff --stat Sources/AnyDoor/Resources/Localizable.xcstrings`
Expected: a single file changed with ~30 lines added, 0 removed (three 10-line
JSON blocks). If lines are removed or the count is far larger, the catalog was
reformatted — `git checkout` the file and re-run Step 2.

- [ ] **Step 4: Build to verify the catalog compiles**

Run: `swift build`
Expected: `Build complete!` with no string-catalog errors. (A missing/mismatched
key would fail here with an `xcstringstool` error.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(translation): add localization keys for history recall UI"
```

---

### Task 2: Recall UI in `TranslationHistoryView`

Replace tap-to-re-translate with a single-open accordion that recalls the stored
result inline, plus a copy button and an explicit re-translate button. This is one
cohesive edit to one file; the full new file content is given below to remove all
ambiguity.

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift` (full rewrite)

**Context the engineer needs (already true in the codebase — do not re-implement):**
- `coordinator.prefill(_ text: String, autoTranslate: Bool)` exists on
  `TranslationCoordinator` and is what re-translate uses.
- `coordinator.source` / `coordinator.target` are settable; `TranslationLanguage.named(_:)`
  maps a stored code (empty ⇒ `nil` ⇒ auto-detect) to a `TranslationLanguage?`.
- `ClipboardWatcher.shared?.noteSelfWrite(changeCount:)`, `ToastPresenter.shared.show(.success(_:))`,
  `L(_:)`, `LocalizedText(_:)`, `store.toggleFavorite(_:)`, `store.delete(_:)`,
  `store.recent(limit:)`, `store.favorites()` all exist and are used as-is
  (the copy + toast pattern is copied verbatim from `TranslationView.copy`).

- [ ] **Step 1: Replace the whole file**

Write `Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift` with exactly:

```swift
import AppKit
import SwiftUI

/// In-window History + Favorites viewer presented over the translation panel
/// (a popover anchored to the toolbar's history button). Lists persisted
/// `TranslationRecord` rows newest-first with an All / Favorites filter, a
/// per-row favorite-star toggle, and a delete control. Tapping a row expands it
/// inline to recall the stored result (full original + translation, with a copy
/// button); an explicit "Re-translate" button in the expanded detail refills the
/// input and re-runs the translation, then dismisses. Recall and copy are pure
/// local reads — no network, no tokens.
///
/// Binds to `TranslationHistoryStore.shared`: the view reads the store's
/// `revision` token in `body` so `@Observable` re-renders the list whenever
/// history mutates (record / favorite / delete / clear), then re-fetches the
/// current filter's rows from SwiftData.
struct TranslationHistoryView: View {
    let store: TranslationHistoryStore
    let coordinator: TranslationCoordinator
    /// Called after a re-translate is requested so the host can dismiss the popover.
    var onSelect: () -> Void

    private enum Filter: Hashable { case all, favorites }
    @State private var filter: Filter = .all
    /// The single currently-expanded row (single-open accordion), or nil.
    @State private var expandedID: String?

    /// Soft cap on the All view so a huge history doesn't build an unbounded
    /// list; favorites are always shown in full.
    private let recentLimit = 200

    var body: some View {
        // Establish an observation dependency so the list refreshes on any
        // store mutation (the fetch methods below are not observable).
        _ = store.revision
        let rows = currentRows()

        return VStack(spacing: 0) {
            filterPicker
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                list(rows)
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
    }

    private func list(_ rows: [TranslationRecord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows, id: \.id) { record in
                    row(record)
                }
            }
            .padding(10)
        }
    }

    private func row(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(record.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.sourceText)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        Text(record.translatedText)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if !record.serviceName.isEmpty {
                                Text(record.serviceName)
                            }
                            Text(record.createdAt, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    rowControls(record)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedID == record.id {
                expandedDetail(record)
                    .padding(.top, 8)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func rowControls(_ record: TranslationRecord) -> some View {
        VStack(spacing: 8) {
            Button {
                store.toggleFavorite(record)
            } label: {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(record.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(record.isFavorite ? .translationHistoryUnfavorite : .translationHistoryFavorite))

            Button {
                store.delete(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationHistoryDelete))
        }
    }

    /// Recall detail shown when a row is expanded: full original + translation
    /// (both selectable), a copy-translation button, and an explicit re-translate
    /// button. Pure local read — no network, no tokens.
    @ViewBuilder
    private func expandedDetail(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                LocalizedText(.translationHistoryOriginalLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(record.sourceText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    LocalizedText(.translationHistoryTranslatedLabel)
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

            Button {
                retranslate(record)
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

    private func currentRows() -> [TranslationRecord] {
        switch filter {
        case .all: return store.recent(limit: recentLimit)
        case .favorites: return store.favorites()
        }
    }

    /// Single-open accordion: tapping the open row closes it, another opens it.
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id ? nil : id)
        }
    }

    /// Recall the stored translation onto the clipboard. Mirrors
    /// `TranslationView.copy`: notes the self-write so AnyDoor's own clipboard
    /// history ignores it, then shows the success toast.
    private func copyTranslation(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// Explicit re-translate: restore the record's direction and re-run the
    /// translation, then dismiss. An empty source code means auto-detect.
    private func retranslate(_ record: TranslationRecord) {
        coordinator.source = TranslationLanguage.named(record.sourceLangCode)
        if let target = TranslationLanguage.named(record.targetLangCode) {
            coordinator.target = target
        }
        coordinator.prefill(record.sourceText, autoTranslate: true)
        onSelect()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings about the new file
(in particular, no "result of call to 'select' is unused" — the old `select(_:)`
is gone).

- [ ] **Step 3: Confirm the existing test suite is unaffected**

Run: `swift test`
Expected: same pass count as the pre-change baseline (no test references
`TranslationHistoryView`; this is a view-only change, so nothing should regress).

- [ ] **Step 4: Manual smoke test (run the app)**

Run: `swift run AnyDoor`, open the translation panel, click the history (clock)
toolbar button, and verify:
1. Tapping a row **expands it in place** showing the full original + translation;
   no service-card spinner appears in the main panel and no network call happens.
2. Tapping the same row again collapses it; tapping a different row moves the
   expansion (single-open).
3. The copy button puts the stored translation on the clipboard and shows the
   "已复制" success toast.
4. The **重新翻译** button refills the input, restores the language direction,
   runs a fresh translation, and dismisses the popover.
5. Switching to the **收藏 (Favorites)** filter shows the same behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift
git commit -m "feat(translation): recall stored result on history tap instead of re-translating"
```

---

## Final verification (after all tasks)

- [ ] `swift build` is clean.
- [ ] `git log --oneline -3` shows the two feature commits (Task 1, Task 2), local only — nothing pushed.
- [ ] The history popover tap recalls instead of re-translating; re-translate is reachable only via the explicit button.
