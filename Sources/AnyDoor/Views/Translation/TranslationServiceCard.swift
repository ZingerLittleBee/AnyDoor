import AppKit
import SwiftUI

/// A single translation result rendered as a stacked card. Header shows the
/// service icon, name, and a collapse chevron; the body shows the translated
/// text or a loading/error state; the footer offers TTS and copy. Apple's
/// on-device translation is NOT rendered here — it has its own card.
struct TranslationServiceCard: View {
    let config: TranslationServiceConfig
    let result: TranslationResult
    /// Resolved target language used to pick the TTS voice (the translated text
    /// is in the target language).
    let target: TranslationLanguage

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    body(for: result)
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
                statusBadge
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleCollapsed() }

            footerButtons
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
    private var statusBadge: some View {
        switch result.status {
        case .loading:
            ProgressView().controlSize(.small)
        case .streaming:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    /// Speaker + copy, shown only once there is text to act on.
    @ViewBuilder
    private var footerButtons: some View {
        if !result.text.isEmpty {
            Button {
                SpeechService.shared.speak(result.text, language: voiceLanguage)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.translationSpeak))
            .hoverTooltip(L(.translationSpeak))

            Button {
                copyToPasteboard(result.text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.translationCopy))
            .hoverTooltip(L(.translationCopy))
        }
    }

    @ViewBuilder
    private func body(for result: TranslationResult) -> some View {
        switch result.status {
        case .idle, .loading, .deferred:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.translationTranslating).foregroundStyle(.secondary).font(.callout)
            }
        case .streaming, .success:
            Text(result.text.isEmpty ? " " : result.text)
                .font(.body)
                .textSelection(.enabled)
        case .failure:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(result.errorMessage ?? L(.translationError))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The translated text is in the target language, so the target drives the
    /// spoken voice (not `result.detected`, which is the source language).
    private var voiceLanguage: TranslationLanguage? {
        target
    }

    /// Copy and suppress clipboard-history capture, matching every other
    /// internal copy path (Calc / PickColor / OCR / QRCode / Screenshot).
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}
