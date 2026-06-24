import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Apple's on-device Translation rendered by a dedicated SwiftUI card via the
/// `.translationTask` modifier (macOS 15+). Unlike the network/LLM services this
/// is not a TranslationProvider — Apple's API binds directly to the view. On
/// macOS 14 the card is empty (the host also filters the apple config out).
struct AppleTranslationCard: View {
    let config: TranslationServiceConfig
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        if #available(macOS 15, *) {
            AppleTranslationCardBody(config: config, coordinator: coordinator)
        } else {
            EmptyView()
        }
    }
}

#if canImport(Translation)
/// Holds the card's mutable render state in a MainActor reference type so the
/// `nonisolated` `.translationTask` closure can publish results via `await`
/// without forcing `session` (Apple's main actor-isolated handle) to be "sent"
/// into a nonisolated method — which Swift 6 strict concurrency rejects.
@available(macOS 15, *)
@MainActor
@Observable
private final class AppleCardState {
    var output: String = ""
    var status: TranslationResult.Status = .idle
    var errorMessage: String?

    func beginLoading() {
        status = .loading
        output = ""
        errorMessage = nil
    }

    func reset() {
        status = .idle
        output = ""
        errorMessage = nil
    }

    func succeed(_ text: String) {
        output = text
        status = .success
    }

    func fail(_ message: String) {
        errorMessage = message
        status = .failure
    }
}

@available(macOS 15, *)
private struct AppleTranslationCardBody: View {
    let config: TranslationServiceConfig
    @Bindable var coordinator: TranslationCoordinator

    @State private var configuration: TranslationSession.Configuration?
    @State private var state = AppleCardState()
    @State private var collapsed = false

    var body: some View {
        // While idle (no run yet) render nothing so the card matches the stream
        // service cards, which only appear once a translation runs — otherwise the
        // resting `.idle` state would surface as a perpetual "translating" spinner.
        // The driving modifiers stay attached to the always-present Group so a
        // later runToken change still arms the session.
        Group {
            if state.status != .idle {
                card
            }
        }
        // Rebuild the session only on an explicit translate run (Enter), matching
        // the stream providers — not on every keystroke. `translate()` bumps
        // `runToken`, which is the same signal the coordinator fans out on.
        .onChange(of: coordinator.runToken) { _, _ in refreshConfiguration() }
        .translationTask(configuration) { @Sendable [state, coordinator, config] session in
            // @Sendable makes this closure nonisolated, so `session` lives outside
            // the MainActor and can be passed straight to Apple's nonisolated
            // translate(_:). State writes hop back via `await`.
            await run(session, state: state, coordinator: coordinator, config: config)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The icon + name + status region (including the flexible gap) toggles
            // collapse on tap; the trailing action buttons keep their own hit
            // targets so a tap on them isn't swallowed by this gesture.
            HStack(spacing: 8) {
                Image(systemName: config.iconName)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(config.displayName)
                    .font(.subheadline.weight(.semibold))
                if state.status == .loading || state.status == .streaming {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleCollapsed() }

            if !state.output.isEmpty {
                Button {
                    SpeechService.shared.speak(state.output, language: coordinator.effectiveTarget())
                } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(.translationSpeak))
                .hoverTooltip(L(.translationSpeak))

                Button {
                    copy(state.output)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(.translationCopy))
                .hoverTooltip(L(.translationCopy))
            }
            Button {
                toggleCollapsed()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(collapsed ? .translationExpand : .translationCollapse))
            .hoverTooltip(L(collapsed ? .translationExpand : .translationCollapse))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Toggle the body's visibility with a short ease so the disclosure (and the
    /// chevron's rotation) animate together.
    private func toggleCollapsed() {
        withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        switch state.status {
        case .idle, .deferred:
            // Not reachable: the Apple card never defers (manual mode is
            // openAICompatible-only). Kept to satisfy the shared enum switch.
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.translationTranslating).foregroundStyle(.secondary).font(.callout)
            }
        case .streaming, .success:
            Text(state.output.isEmpty ? " " : state.output)
                .font(.body)
                .textSelection(.enabled)
        case .failure:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(state.errorMessage ?? L(.translationError)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Rebuild the configuration only when there is text to translate. Passing a
    /// fresh Configuration value re-runs `.translationTask`. A nil source lets
    /// Apple auto-detect.
    private func refreshConfiguration() {
        let text = coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.reset()
            configuration = nil
            return
        }
        let sourceLocale = (coordinator.source ?? coordinator.detectedSource)
            .flatMap { Locale.Language(identifier: $0.code) }
        let targetLocale = Locale.Language(identifier: coordinator.effectiveTarget().code)
        state.beginLoading()
        configuration = TranslationSession.Configuration(source: sourceLocale, target: targetLocale)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}

/// Drive one on-device translation from a `nonisolated` context. `session` stays
/// in this nonisolated region so it can be passed to Apple's `nonisolated`
/// `translate(_:)`; the MainActor-isolated `coordinator` and `state` are touched
/// only via `await`, so nothing crosses isolation unsafely.
@available(macOS 15, *)
private nonisolated func run(_ session: TranslationSession,
                             state: AppleCardState,
                             coordinator: TranslationCoordinator,
                             config: TranslationServiceConfig) async {
    let text = await coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    // Freeze the run id at dispatch so a superseding run can't restamp this result.
    let runID = await coordinator.currentRunID

    // A missing on-device language pack makes session.translate present a system
    // download sheet (from another process) that steals key focus and would
    // dismiss the floating panel. Guard auto-dismiss ONLY for that case, so an
    // installed (fast) translation doesn't hold focus for its whole duration.
    let guarded = await mayDownloadLanguagePack(coordinator: coordinator)
    if guarded { await coordinator.beginSystemSheet() }
    let result: Result<String, Error>
    do {
        result = .success(try await session.translate(text).targetText)
    } catch {
        result = .failure(error)
    }
    if guarded { await coordinator.endSystemSheet() }

    switch result {
    case .success(let translated):
        await state.succeed(translated)
        // Record to history through the same store the coordinator uses, so an
        // Apple-only success is not dropped (the coordinator's run() never sees it).
        await coordinator.noteAppleSuccess(
            serviceID: config.id,
            serviceName: config.displayName,
            sourceText: text,
            translatedText: translated,
            target: coordinator.effectiveTarget(),
            runID: runID)
    case .failure(let error):
        if error is CancellationError {
            // Superseded by a newer request; leave state for the new run.
        } else if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            // The person declined or dismissed the language-pack download sheet —
            // a choice, not a failure, so fall back to idle (the card hides)
            // instead of flashing a red error.
            await state.reset()
        } else {
            await state.fail(error.localizedDescription)
        }
    }
}

/// Whether the current source→target pair still needs an on-device language
/// pack — i.e. `session.translate` will present the system download sheet. Used
/// to scope the panel's auto-dismiss guard to just the sheet-presenting case.
@available(macOS 15, *)
private nonisolated func mayDownloadLanguagePack(coordinator: TranslationCoordinator) async -> Bool {
    let (sourceCode, targetCode) = await MainActor.run {
        ((coordinator.source ?? coordinator.detectedSource)?.code, coordinator.effectiveTarget().code)
    }
    // Without a concrete source (auto-detect, nothing detected yet) we can't
    // check, so assume a sheet may appear and protect the panel.
    guard let sourceCode else { return true }
    let status = await LanguageAvailability().status(
        from: Locale.Language(identifier: sourceCode),
        to: Locale.Language(identifier: targetCode)
    )
    return status == .supported
}
#endif
