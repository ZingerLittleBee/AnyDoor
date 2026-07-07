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

/// Invisible, always-mounted driver for Apple's on-device language pack. Mount it
/// as a `.background` of an always-visible panel element: SwiftUI fires no
/// appearance lifecycle on a view that renders nothing, and the Apple result card
/// renders nothing while its pack status is unknown or while installed+idle — so
/// the availability check and the download must be driven from a view that is
/// always on screen, not from the (often hidden) card.
struct AppleLanguagePackDriver: View {
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        if #available(macOS 15, *) {
            AppleLanguagePackDriverBody(coordinator: coordinator)
        } else {
            Color.clear.frame(width: 0, height: 0)
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
private struct AppleLanguagePackDriverBody: View {
    @Bindable var coordinator: TranslationCoordinator
    @State private var pack = AppleLanguagePackModel()

    /// The on-device pair whose assets gate Apple translation. Uses the actual
    /// source→target when a source is known (selected or detected), otherwise the
    /// configured `secondTarget → target` direction (assets are per-language, so
    /// one direction is enough) — matching the settings download button.
    private var relevantPair: AppleLanguagePackModel.LanguagePair? {
        let target = coordinator.effectiveTarget().code
        let source = (coordinator.source ?? coordinator.detectedSource)?.code
            ?? TranslationSettings.shared.secondTargetLanguage.code
        guard source != target else { return nil }
        return .init(source: source, target: target)
    }

    private var pairKey: String {
        relevantPair.map { "\($0.source)|\($0.target)" } ?? "none"
    }

    var body: some View {
        Color.clear
            // Re-read real availability on first appearance and on every pair
            // change. `.onChange(initial:)` on this always-visible background fires
            // reliably (unlike lifecycle on the hidden card). Result is mirrored to
            // the coordinator so the card can render its gate.
            .onChange(of: pairKey, initial: true) {
                Task { await pack.evaluate(pair: relevantPair) }
            }
            .onChange(of: pack.phase, initial: true) { _, phase in
                coordinator.applePackPhase = Self.mapped(phase)
            }
            // The card bumps this token to request a download.
            .onChange(of: coordinator.appleDownloadRequestToken) { _, _ in
                guard pack.phase != .downloading else { return }
                pack.startDownload()
            }
            // Drive the on-device language download; guard the floating panel's
            // auto-dismiss while the system sheet (from another process) holds key
            // focus.
            .translationTask(pack.configuration) { @Sendable [pack, coordinator] session in
                await coordinator.beginSystemSheet()
                await runApplePrepare(session, model: pack)
                await coordinator.endSystemSheet()
            }
    }

    private static func mapped(_ phase: AppleLanguagePackModel.Phase) -> TranslationCoordinator.ApplePackPhase {
        switch phase {
        case .checking: return .checking
        case .needsDownload: return .needsDownload
        case .downloading: return .downloading
        case .installed: return .installed
        case .unsupported: return .unsupported
        case .failed: return .failed
        }
    }
}

@available(macOS 15, *)
private struct AppleTranslationCardBody: View {
    let config: TranslationServiceConfig
    @Bindable var coordinator: TranslationCoordinator

    @State private var configuration: TranslationSession.Configuration?
    @State private var state = AppleCardState()
    @State private var collapsed = false
    @State private var hovered = false
    /// Set when a translate run is requested (Enter) while the language pack isn't
    /// installed yet, so the translation fires automatically once the pack becomes
    /// available — after the user downloads it, or once the async check resolves.
    @State private var wantsTranslateWhenReady = false

    /// Apple pack availability, owned by the always-present driver and mirrored on
    /// the coordinator. The card only reads it.
    private var phase: TranslationCoordinator.ApplePackPhase { coordinator.applePackPhase }

    var body: some View {
        Group {
            rootContent
        }
        // Rebuild the translate session only on an explicit run (Enter), and only
        // when the pack is installed — see refreshConfiguration(). Change-driven
        // `.onChange` fires even while the card renders nothing, so this still
        // arms a translation from the hidden idle state.
        .onChange(of: coordinator.runToken) { _, _ in refreshConfiguration() }
        // Once the pack becomes installed, fire any pending translate request
        // (covers both the post-download re-run and the run-while-checking race).
        .onChange(of: phase) { _, newValue in packPhaseChanged(newValue) }
        .translationTask(configuration) { @Sendable [state, coordinator, config] session in
            // @Sendable makes this closure nonisolated, so `session` lives outside
            // the MainActor and can be passed straight to Apple's nonisolated
            // translate(_:). State writes hop back via `await`.
            await run(session, state: state, coordinator: coordinator, config: config)
        }
    }

    // MARK: - Availability-driven rendering

    /// What to render given the pack availability and the run status. When the
    /// pack isn't installed the download card is shown unconditionally (even with
    /// empty input); when installed the card behaves like the stream cards and
    /// only appears once a translation runs.
    @ViewBuilder
    private var rootContent: some View {
        switch phase {
        case .unknown, .checking, .installed:
            // While idle (no run yet) render nothing so the card matches the
            // stream service cards; the resting `.idle` state would otherwise
            // surface as a perpetual "translating" spinner.
            if state.status != .idle {
                card
            }
        case .needsDownload, .downloading, .failed:
            downloadCard
        case .unsupported:
            EmptyView()
        }
    }

    // MARK: - Download card (pack not installed)

    /// Collapsed, non-expandable card shown while the language pack is missing.
    /// Tapping anywhere on the header — or the download control — presents the
    /// system download sheet; there is no body to disclose.
    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            downloadHeader
        }
        .translationTile(isHovered: hovered, isExpanded: false)
        .onHover { hovered = $0 }
    }

    private var downloadHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: config.iconName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(config.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            downloadControl
        }
        .padding(.horizontal, TranslationTheme.tileInsetH)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { startDownload() }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch phase {
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.settingsTranslationDownloadLanguagesDownloading)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        case .failed:
            Button { startDownload() } label: {
                Label {
                    LocalizedText(.settingsTranslationDownloadLanguagesFailed)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .font(.callout)
        default:
            Button { startDownload() } label: {
                Label {
                    LocalizedText(.settingsTranslationDownloadLanguages)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    /// Ask the always-present driver to present the system download sheet (no-op
    /// while a download is already in flight).
    private func startDownload() {
        guard phase != .downloading else { return }
        coordinator.appleDownloadRequestToken &+= 1
    }

    /// React to the pack becoming installed: fire a pending translate request so
    /// a just-downloaded pack immediately produces a result, and the run requested
    /// while the check was still resolving isn't dropped.
    private func packPhaseChanged(_ phase: TranslationCoordinator.ApplePackPhase) {
        guard phase == .installed, wantsTranslateWhenReady else { return }
        let text = coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        wantsTranslateWhenReady = false
        guard !text.isEmpty else { return }
        startTranslate()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TranslationTheme.tileInsetH)
                        .padding(.vertical, TranslationTheme.tileInsetV)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .translationTile(isHovered: hovered, isExpanded: !collapsed)
        .onHover { hovered = $0 }
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
        .padding(.horizontal, TranslationTheme.tileInsetH)
        .padding(.vertical, 8)
    }

    /// Toggle the body's visibility with a short ease so the disclosure (and the
    /// chevron's rotation) animate together.
    private func toggleCollapsed() {
        withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
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

    /// On an explicit run (Enter), translate only when the language pack is
    /// installed. When it isn't, skip translating — the download card is shown
    /// instead — and record the intent so the run fires once the pack lands
    /// (after the user downloads it). This replaces the old behavior of letting
    /// `session.translate` auto-present the system download sheet.
    private func refreshConfiguration() {
        let text = coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.reset()
            configuration = nil
            wantsTranslateWhenReady = false
            return
        }
        guard phase == .installed else {
            state.reset()
            configuration = nil
            wantsTranslateWhenReady = true
            return
        }
        wantsTranslateWhenReady = false
        startTranslate()
    }

    /// Build a fresh translate configuration so `.translationTask` re-runs. A nil
    /// source lets Apple auto-detect.
    private func startTranslate() {
        let sourceLocale = (coordinator.source ?? coordinator.detectedSource)
            .flatMap { Locale.Language(identifier: $0.code) }
        let targetLocale = Locale.Language(identifier: coordinator.effectiveTarget().code)
        state.beginLoading()
        configuration = TranslationSession.Configuration(source: sourceLocale, target: targetLocale)
    }

    private func copy(_ text: String) {
        ClipboardWatcher.selfWrite(string: text)
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
    let (text, runID, runToken, source, target) = await MainActor.run {
        (
            coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            coordinator.currentRunID,
            coordinator.runToken,
            coordinator.source ?? coordinator.detectedSource,
            coordinator.effectiveTarget()
        )
    }
    guard !text.isEmpty else { return }

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
    guard await coordinator.runToken == runToken else { return }

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
            source: source,
            target: target,
            runID: runID,
            runToken: runToken)
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
