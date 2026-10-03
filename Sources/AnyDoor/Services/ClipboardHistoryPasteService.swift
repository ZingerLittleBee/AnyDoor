import AppKit
import ApplicationServices
import ClipboardHistory

enum ClipboardHistoryPasteServiceError: Error {
    case emptyMaterialization
    case invalidTypeIdentifier
    case writeFailed
}

/// How `ClipboardHistoryPasteService.copyEntry` ended. The caller decides what
/// a failure shows and what follows a copy.
enum ClipboardHistoryCopyOutcome: Equatable {
    case copied
    /// Carries the presentation's `actionFailure` right after the attempt. A
    /// reload that overtook the attempt drops its failure, so this can be
    /// `nil`.
    case materializationFailed(ClipboardHistoryActionFailure?)
    /// A plain-text paste of an entry that lacks exact text on some item.
    /// Nothing was written.
    case plainTextUnavailable
    case pasteboardWriteFailed
    /// The caller stopped wanting the copy while the entry materialized: a
    /// newer commit superseded it, or its surface closed and the pasteboard
    /// changed meanwhile. Nothing was written, and nothing is shown.
    case discarded
}

/// One choice of a history entry, from the wall or a menu-bar popover. The
/// newest commit wins: a slow copy never blocks the next choice, and an older
/// result never lands after a newer one.
struct ClipboardHistoryCommit: Equatable, Sendable {
    fileprivate let number: Int
    /// The pasteboard's change count when the commit started. Once its
    /// surface has closed, the commit writes only while this still matches,
    /// so it never overwrites what the user copied in the meantime.
    let changeCount: Int
}

/// What a commit needs from the surface it came from.
struct ClipboardHistoryCommitSurface {
    /// Whether the surface is still open for this commit. Esc, a click
    /// elsewhere, or a newer showing of the surface closes it.
    let isOpen: @MainActor () -> Bool
    /// Closes the surface and calls `then` once it is off screen, so ⌘V
    /// reaches the app below it. A surface that is already gone drops `then`.
    let close: @MainActor (_ then: @escaping @MainActor @Sendable () -> Void) -> Void
    /// Whether the surface has stayed closed since `close` called `then`. The
    /// paste asks again after its delay, so ⌘V never reaches a surface that
    /// was reopened meanwhile.
    var isStillClosed: @MainActor () -> Bool = { true }
}

@MainActor
enum ClipboardHistoryPasteService {
    /// How long a paste waits after its surface has closed, so keyboard focus
    /// is back in the app that receives ⌘V.
    static let pasteDelay: Duration = .milliseconds(50)

    private static var latestCommitNumber = 0

    /// Starts a commit, superseding every earlier one.
    static func beginCommit(
        on pasteboard: NSPasteboard = .general
    ) -> ClipboardHistoryCommit {
        latestCommitNumber += 1
        return ClipboardHistoryCommit(
            number: latestCommitNumber,
            changeCount: pasteboard.changeCount
        )
    }

    static func isLatest(_ commit: ClipboardHistoryCommit) -> Bool {
        commit.number == latestCommitNumber
    }

    /// Whether `commit` may still write: it is the newest commit, and its
    /// surface is open or the pasteboard is unchanged since it started.
    static func mayWrite(
        _ commit: ClipboardHistoryCommit,
        surfaceIsOpen: Bool,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        isLatest(commit)
            && (surfaceIsOpen || pasteboard.changeCount == commit.changeCount)
    }

    /// The one path from a history entry to the pasteboard, shared by the
    /// menu-bar popover and the wall. The entry is materialized afresh, never
    /// from the presentation's cache, and written through the self-write
    /// funnel so history does not capture AnyDoor's own write. Nothing is
    /// presented, closed or pasted here.
    ///
    /// `isWanted` runs once the entry has materialized, before anything is
    /// written or reported; false ends the copy as `.discarded`.
    static func copyEntry(
        _ entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose = .normalPaste,
        from presentation: ClipboardHistoryPresentationModel,
        to pasteboard: NSPasteboard = .general,
        isWanted: @MainActor () -> Bool = { true }
    ) async -> ClipboardHistoryCopyOutcome {
        let materialization = await presentation.materialization(
            for: entryID,
            purpose: purpose,
            usesCache: false
        )
        guard isWanted() else { return .discarded }
        guard let materialization else {
            // For a plain-text paste, the module reports exactly this when
            // some item has no exact text.
            if purpose == .plainTextPaste,
                presentation.actionFailure == .operationUnavailable
            {
                return .plainTextUnavailable
            }
            return .materializationFailed(presentation.actionFailure)
        }
        do {
            try ClipboardSelfWrites.perform(to: pasteboard) { pasteboard in
                try write(materialization, to: pasteboard)
            }
        } catch {
            return .pasteboardWriteFailed
        }
        return .copied
    }

    static func write(
        _ materialization: ClipboardHistoryMaterialization,
        to pasteboard: NSPasteboard
    ) throws {
        guard !materialization.items.isEmpty else {
            throw ClipboardHistoryPasteServiceError.emptyMaterialization
        }

        let pasteboardItems = try materialization.items.map { item in
            guard !item.representations.isEmpty else {
                throw ClipboardHistoryPasteServiceError.emptyMaterialization
            }
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                switch representation {
                case .text(let typeIdentifier, let value):
                    guard !typeIdentifier.isEmpty else {
                        throw ClipboardHistoryPasteServiceError
                            .invalidTypeIdentifier
                    }
                    guard pasteboardItem.setString(
                        value,
                        forType: NSPasteboard.PasteboardType(typeIdentifier)
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                case .data(let typeIdentifier, let data):
                    guard !typeIdentifier.isEmpty else {
                        throw ClipboardHistoryPasteServiceError
                            .invalidTypeIdentifier
                    }
                    guard pasteboardItem.setData(
                        data,
                        forType: NSPasteboard.PasteboardType(typeIdentifier)
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                case .file(let file):
                    guard pasteboardItem.setString(
                        file.currentURL.absoluteString,
                        forType: .fileURL
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                }
            }
            return pasteboardItem
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            throw ClipboardHistoryPasteServiceError.writeFailed
        }
    }

    /// Copies an entry chosen on `surface`, then closes the surface and
    /// pastes into the app below it, unless Copy only is on.
    ///
    /// - A newer commit supersedes this one: once it starts, this one writes
    ///   nothing and shows nothing.
    /// - A failure goes to `presentFailure`, and the surface stays open.
    /// - When the surface closed while the entry was copying, the entry is
    ///   written only if the pasteboard is unchanged since the commit
    ///   started, and a "Copied" toast follows. It is never pasted then,
    ///   because ⌘V would land in an app the user did not choose.
    ///
    /// The Accessibility check runs detached, beside the copy. The remaining
    /// parameters let tests run without posting a key event or a toast.
    static func commit(
        _ entryID: ClipboardHistoryEntryID,
        plain: Bool,
        from presentation: ClipboardHistoryPresentationModel,
        surface: ClipboardHistoryCommitSurface,
        presentFailure: @MainActor (ClipboardHistoryCopyOutcome) -> Void,
        copyOnly: Bool = ClipboardPreferences.copyOnly,
        pasteboard: NSPasteboard = .general,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        paste: @escaping @MainActor @Sendable () -> Void = {
            ClipboardHistoryPasteService.synthesizePaste()
        },
        notify: @escaping @MainActor @Sendable (ToastStyle) -> Void = {
            ToastPresenter.shared.show($0)
        },
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let commit = beginCommit(on: pasteboard)
        // AXIsProcessTrusted can block, so it stays off the main actor. It
        // only checks: HotkeyService owns the Accessibility prompt.
        let trust = copyOnly ? nil : Task.detached { isTrusted() }
        var surfaceWasOpen = false
        let outcome = await copyEntry(
            entryID,
            purpose: plain ? .plainTextPaste : .normalPaste,
            from: presentation,
            to: pasteboard
        ) {
            surfaceWasOpen = surface.isOpen()
            return mayWrite(
                commit,
                surfaceIsOpen: surfaceWasOpen,
                pasteboard: pasteboard
            )
        }
        switch outcome {
        case .copied:
            break
        case .discarded:
            return
        case .materializationFailed, .plainTextUnavailable,
            .pasteboardWriteFailed:
            presentFailure(outcome)
            return
        }
        guard surfaceWasOpen else {
            notify(.success(L(.toastCopiedToClipboard)))
            return
        }
        let isStillClosed = surface.isStillClosed
        surface.close {
            Task { @MainActor in
                await pasteAfterClosing(
                    copyOnly: copyOnly,
                    trust: trust,
                    isCurrent: { isLatest(commit) && isStillClosed() },
                    paste: paste,
                    notify: notify,
                    clock: clock
                )
            }
        }
    }

    /// Copies an entry without closing its surface or pasting: a context-menu
    /// or preview Copy, confirmed by a "Copied" toast. It takes a commit like
    /// `commit` does and follows the same rules for writing.
    static func copyWithoutPasting(
        _ entryID: ClipboardHistoryEntryID,
        from presentation: ClipboardHistoryPresentationModel,
        surfaceIsOpen: @MainActor () -> Bool,
        presentFailure: @MainActor (ClipboardHistoryCopyOutcome) -> Void,
        pasteboard: NSPasteboard = .general,
        notify: @MainActor (ToastStyle) -> Void = {
            ToastPresenter.shared.show($0)
        }
    ) async {
        let commit = beginCommit(on: pasteboard)
        let outcome = await copyEntry(
            entryID,
            from: presentation,
            to: pasteboard
        ) {
            mayWrite(
                commit,
                surfaceIsOpen: surfaceIsOpen(),
                pasteboard: pasteboard
            )
        }
        switch outcome {
        case .copied:
            notify(.success(L(.toastCopiedToClipboard)))
        case .discarded:
            break
        case .materializationFailed, .plainTextUnavailable,
            .pasteboardWriteFailed:
            presentFailure(outcome)
        }
    }

    /// Runs once a surface has closed after a copy: ⌘V after `pasteDelay`, or
    /// a toast when Accessibility is missing, since macOS then drops the
    /// synthesized event silently. Copy only does neither, and neither does
    /// a commit that is no longer current.
    static func pasteAfterClosing(
        copyOnly: Bool,
        trust: Task<Bool, Never>?,
        isCurrent: @MainActor () -> Bool = { true },
        paste: @MainActor () -> Void = { synthesizePaste() },
        notify: @MainActor (ToastStyle) -> Void = {
            ToastPresenter.shared.show($0)
        },
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        guard !copyOnly else { return }
        let isTrusted = await trust?.value ?? false
        guard isCurrent() else { return }
        guard isTrusted else {
            notify(.failure(L(.clipboardToastPasteNeedsAccessibility)))
            return
        }
        do {
            try await clock.sleep(for: pasteDelay)
        } catch {
            return
        }
        guard isCurrent() else { return }
        paste()
    }

    static func synthesizePaste() {
        SyntheticKeyChord.postCommandShortcut(key: SyntheticKeyChord.vKeyCode)
    }
}
