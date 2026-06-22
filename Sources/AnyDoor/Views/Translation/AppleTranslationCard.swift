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
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: config.iconName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(config.displayName)
                .font(.subheadline.weight(.semibold))
            if state.status == .loading || state.status == .streaming {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if !state.output.isEmpty {
                Button {
                    SpeechService.shared.speak(state.output, language: coordinator.effectiveTarget())
                } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.translationSpeak))

                Button {
                    copy(state.output)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.translationCopy))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch state.status {
        case .idle:
            // Not reachable while the card is hidden in `.idle`; kept as an empty
            // resting state for safety.
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
    do {
        let translated = try await session.translate(text).targetText
        await state.succeed(translated)
        // Record to history through the same store the coordinator uses, so an
        // Apple-only success is not dropped (the coordinator's run() never sees it).
        await coordinator.noteAppleSuccess(
            serviceID: config.id,
            serviceName: config.displayName,
            sourceText: text,
            translatedText: translated,
            target: coordinator.effectiveTarget())
    } catch is CancellationError {
        // Superseded by a newer request; leave state for the new run.
    } catch {
        await state.fail(error.localizedDescription)
    }
}
#endif
