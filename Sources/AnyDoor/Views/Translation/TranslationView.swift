import AppKit
import SwiftUI

/// Root translation panel UI: toolbar, input editor, language bar, and the
/// stacked result cards (one generic card per stream service in configured
/// order, plus the dedicated Apple card on macOS 15+). Enter in the input
/// triggers a fan-out translation; auto-speak narrates the first success.
struct TranslationView: View {
    let controller: TranslationWindowController

    @State private var coordinator = TranslationCoordinator.shared
    @State private var settings = TranslationSettings.shared
    @State private var isPinned: Bool
    /// serviceIDs already auto-spoken for the current translation run, so the
    /// "first success" narration fires exactly once per run.
    @State private var autoSpokenRun = false
    /// Whether the in-window History + Favorites popover is showing.
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    init(controller: TranslationWindowController) {
        self.controller = controller
        _isPinned = State(initialValue: controller.isPinned)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    inputCard
                    LanguageBar(coordinator: coordinator) { runTranslation() }
                    resultCards
                }
                .padding(14)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // Reset the auto-speak guard at the start of every run, including the
        // screenshot/selection prefill path that calls coordinator.translate()
        // directly (not via runTranslation()).
        .onChange(of: coordinator.runToken) { _, _ in autoSpokenRun = false }
        .onChange(of: coordinator.results.map(\.status)) { _, _ in autoSpeakIfNeeded() }
        .onChange(of: appleAutoSpeakKey) { _, _ in autoSpeakIfNeeded() }
        .onAppear { inputFocused = true }
        .focusEffectDisabled()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Spacer()
            toolbarButton(systemImage: isPinned ? "pin.fill" : "pin", help: L(.translationPin)) {
                isPinned.toggle()
                controller.setPinned(isPinned)
            }
            toolbarButton(systemImage: "clock.arrow.circlepath", help: L(.translationHistory)) {
                showingHistory.toggle()
            }
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                TranslationHistoryView(
                    store: TranslationHistoryStore.shared,
                    coordinator: coordinator
                ) {
                    showingHistory = false
                }
            }
            toolbarButton(systemImage: "camera.viewfinder", help: L(.translationScreenshot)) {
                controller.close()
                Task { await PanelStore.shared.run(.screenshotTranslate) }
            }
            toolbarButton(systemImage: "gearshape", help: L(.translationSettings)) {
                SettingsOpener.shared.tryOpen(tab: .translation)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func toolbarButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                EnterToTranslateEditor(text: $coordinator.inputText) { runTranslation() }
                    .frame(minHeight: 70, maxHeight: 140)
                    .focused($inputFocused)
                if coordinator.inputText.isEmpty {
                    LocalizedText(.translationInputPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if let detected = coordinator.detectedSource, coordinator.source == nil {
                    Text(L(.translationRecognizedAs, detected.displayName()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !coordinator.inputText.isEmpty {
                    Button {
                        SpeechService.shared.speak(coordinator.inputText, language: coordinator.source ?? coordinator.detectedSource)
                    } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L(.translationSpeak))
                    Button {
                        copy(coordinator.inputText)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L(.translationCopy))
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: coordinator.inputText) { _, _ in coordinator.updateDetection() }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultCards: some View {
        let target = coordinator.effectiveTarget()
        ForEach(settings.enabledServicesInOrder) { config in
            if config.kind == .apple {
                AppleTranslationCard(config: config, coordinator: coordinator)
            } else if let result = coordinator.results.first(where: { $0.serviceID == config.id }) {
                TranslationServiceCard(
                    config: config,
                    result: result,
                    target: target
                )
            }
        }
    }

    // MARK: - Actions

    private func runTranslation() {
        // The auto-speak guard is reset by the coordinator.runToken onChange,
        // which fires for both this path and the direct prefill translate().
        coordinator.translate()
    }

    /// A value that changes when the Apple card publishes a fresh success for the
    /// current run, so onChange can re-evaluate auto-speak (the Apple card lives
    /// outside `coordinator.results`).
    private var appleAutoSpeakKey: String {
        guard let apple = coordinator.appleResult, apple.runToken == coordinator.runToken else { return "" }
        return apple.text
    }

    /// On the first enabled service that produces a success after a run, speak it
    /// once when the user enabled auto-speak. The Apple card is included even
    /// though it lives outside `coordinator.results`.
    private func autoSpeakIfNeeded() {
        guard settings.autoSpeak, !autoSpokenRun else { return }
        guard let text = firstSuccessText() else { return }
        autoSpokenRun = true
        SpeechService.shared.speak(text, language: coordinator.effectiveTarget())
    }

    /// The translated text of the first enabled service (in configured order)
    /// that has a non-empty success, considering both the stream results and the
    /// Apple card's published success for the current run.
    private func firstSuccessText() -> String? {
        let appleText: String? = {
            guard let apple = coordinator.appleResult,
                  apple.runToken == coordinator.runToken,
                  !apple.text.isEmpty else { return nil }
            return apple.text
        }()
        for config in settings.enabledServicesInOrder {
            if config.kind == .apple {
                if let appleText { return appleText }
            } else if let result = coordinator.results.first(where: { $0.serviceID == config.id }),
                      result.status == .success, !result.text.isEmpty {
                return result.text
            }
        }
        return nil
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}

/// An NSTextView-backed multiline editor where a bare Return triggers
/// translation (Shift+Return inserts a newline). SwiftUI's TextEditor can't
/// intercept Return cleanly, so this thin AppKit bridge does.
private struct EnterToTranslateEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.focusRingType = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        // While the user is typing (text view is first responder), an external
        // write would collapse the caret/selection and race streaming re-renders;
        // the binding already mirrors the user's edits via textDidChange. When we
        // must write (e.g. prefill), preserve the selection where possible.
        let isEditing = textView.window?.firstResponder === textView
        guard !isEditing else { return }
        let previousSelection = textView.selectedRange()
        textView.string = text
        let clamped = NSRange(
            location: min(previousSelection.location, (text as NSString).length),
            length: 0
        )
        textView.setSelectedRange(clamped)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: EnterToTranslateEditor
        init(_ parent: EnterToTranslateEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// Bare Return submits; Shift+Return falls through to insert a newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if !shift {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}
