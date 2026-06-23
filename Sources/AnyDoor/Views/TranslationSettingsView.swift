import SwiftUI
import AppKit

/// Settings pane for the translation feature. Binds to the shared
/// `TranslationSettings` (UserDefaults-backed `@Observable`) through its
/// explicit setters so the live coordinator sees changes immediately, mirroring
/// `CaptureSettingsView`.
@MainActor
struct TranslationSettingsView: View {
    @State private var settings = TranslationSettings.shared
    @State private var history = TranslationHistoryStore.shared
    private let keychain = TranslationKeychainStore()

    var body: some View {
        Form {
            languageSection
            servicesSection
            historySection
        }
        .formStyle(.grouped)
    }

    /// Present the editor as a modal dialog centered over — and dimming — the
    /// entire Settings window. It is hosted in a window-level scrim because the
    /// tab bar lives in the window's toolbar, which a SwiftUI overlay inside a tab
    /// cannot cover.
    private func presentEditor(_ config: TranslationServiceConfig, isNew: Bool) {
        TranslationServiceEditorOverlay.shared.present(
            config: config,
            isNew: isNew,
            keychain: keychain,
            onSave: applySave
        )
    }

    /// Persist the editor result: store or clear the API key (a nil/empty key
    /// clears it so the factory stops treating the service as configured), then
    /// upsert the config.
    private func applySave(_ saved: TranslationServiceConfig, _ apiKey: String?) {
        if let apiKey, !apiKey.isEmpty {
            keychain.setAPIKey(apiKey, for: saved.id)
        } else {
            keychain.deleteAPIKey(for: saved.id)
        }
        settings.upsertService(saved)
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker(selection: targetLanguage) {
                ForEach(TranslationLanguage.catalog) { lang in
                    Text(lang.displayName()).tag(lang.code)
                }
            } label: {
                LocalizedText(.settingsTranslationTargetLanguage)
            }

            Picker(selection: secondTargetLanguage) {
                ForEach(TranslationLanguage.catalog) { lang in
                    Text(lang.displayName()).tag(lang.code)
                }
            } label: {
                LocalizedText(.settingsTranslationSecondTarget)
            }

            Toggle(isOn: autoSpeak) { LocalizedText(.settingsTranslationAutoSpeak) }
        } header: {
            LocalizedText(.settingsTranslationLanguageSection)
        } footer: {
            LocalizedText(.settingsTranslationSecondTargetFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Services

    /// Services shown in settings. The Apple service produces no card on macOS 14
    /// (its `.translationTask` requires macOS 15+), so hide its row there to mirror
    /// the `if #available(macOS 15, *)` gate AppleTranslationCard uses.
    private var visibleServices: [TranslationServiceConfig] {
        if #available(macOS 15, *) {
            return settings.services
        }
        return settings.services.filter { $0.kind != .apple }
    }

    private var servicesSection: some View {
        Section {
            ForEach(visibleServices) { config in
                serviceRow(config)
            }
            .onMove { indices, newOffset in
                var reordered = visibleServices
                reordered.move(fromOffsets: indices, toOffset: newOffset)
                // Hidden services (e.g. Apple on macOS 14) aren't shown, but must
                // survive the reorder; keep them ahead of the reordered visible set.
                let hidden = settings.services.filter { config in
                    !reordered.contains { $0.id == config.id }
                }
                var merged = hidden + reordered
                for (index, var config) in merged.enumerated() {
                    config.order = index
                    merged[index] = config
                }
                settings.setServices(merged)
            }

            Button {
                let new = TranslationServiceConfig(
                    id: UUID().uuidString,
                    kind: .openAICompatible,
                    displayName: "OpenAI",
                    iconName: "brain",
                    enabled: true,
                    order: settings.services.count,
                    baseURL: "https://api.openai.com/v1",
                    model: "gpt-4o-mini",
                    promptTemplate: TranslationServiceConfig.defaultPromptTemplate
                )
                presentEditor(new, isNew: true)
            } label: {
                Label { LocalizedText(.settingsTranslationAddService) } icon: { Image(systemName: "plus") }
            }
        } header: {
            LocalizedText(.settingsTranslationServicesSection)
        }
    }

    @ViewBuilder
    private func serviceRow(_ config: TranslationServiceConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: config.iconName)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(config.displayName)
            Spacer()

            if config.kind == .apple {
                AppleLanguageDownloadButton(
                    target: settings.targetLanguage,
                    secondTarget: settings.secondTargetLanguage
                )
            }

            if config.kind == .openAICompatible {
                Button { presentEditor(config, isNew: false) } label: {
                    LocalizedText(.settingsTranslationEdit)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    keychain.deleteAPIKey(for: config.id)
                    settings.removeService(id: config.id)
                } label: {
                    LocalizedText(.settingsTranslationRemove)
                }
                .buttonStyle(.borderless)
            }

            // Keep the enable switch trailing, matching the macOS settings-row
            // convention of placing the control at the row's far edge.
            Toggle(isOn: enabledBinding(config)) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Stepper(value: historyRetention, in: 20...2000, step: 20) {
                Text(L(.settingsTranslationHistoryRetention) + ": \(settings.historyRetention)")
            }

            Button(role: .destructive) {
                history.clear()
            } label: {
                LocalizedText(.settingsTranslationHistoryClear)
            }
        } header: {
            LocalizedText(.settingsTranslationHistorySection)
        }
    }

    // MARK: - Bindings into TranslationSettings setters

    private var targetLanguage: Binding<String> {
        Binding(get: { settings.targetLanguageCode }, set: { settings.setTargetLanguageCode($0) })
    }
    private var secondTargetLanguage: Binding<String> {
        Binding(get: { settings.secondTargetLanguageCode }, set: { settings.setSecondTargetLanguageCode($0) })
    }
    private var autoSpeak: Binding<Bool> {
        Binding(get: { settings.autoSpeak }, set: { settings.setAutoSpeak($0) })
    }
    private var historyRetention: Binding<Int> {
        Binding(
            get: { settings.historyRetention },
            set: { newValue in
                settings.setHistoryRetention(newValue)
                // Apply the new cap immediately so lowering it prunes existing rows.
                history.trim(retention: newValue)
            }
        )
    }
    private func enabledBinding(_ config: TranslationServiceConfig) -> Binding<Bool> {
        Binding(
            get: { settings.services.first(where: { $0.id == config.id })?.enabled ?? config.enabled },
            set: { newValue in
                var updated = config
                updated.enabled = newValue
                settings.upsertService(updated)
            }
        )
    }
}

/// Sheet for creating/editing an OpenAI-compatible LLM instance. The API key is
/// stored in (and pre-loaded from) the Keychain via `TranslationKeychainStore`;
/// it is never persisted into `TranslationServiceConfig`.
@MainActor
struct TranslationServiceConfigSheet: View {
    @State private var draft: TranslationServiceConfig
    @State private var apiKey: String
    @State private var testState: TestState = .idle
    @FocusState private var focusedField: Field?
    private let isNew: Bool
    private let keychain: TranslationKeychainStore
    private let onSave: (TranslationServiceConfig, String?) -> Void
    private let onCancel: () -> Void

    private enum TestState: Equatable { case idle, testing, success, failure(String) }
    /// Drives the initial keyboard focus so the cursor lands in a field as soon as
    /// the editor appears (the scrim is a borderless panel; without an explicit
    /// focus the caret would only land after a manual click).
    private enum Field: Hashable { case name }

    init(
        config: TranslationServiceConfig,
        isNew: Bool,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        _apiKey = State(initialValue: keychain.apiKey(for: config.id) ?? "")
        self.isNew = isNew
        self.keychain = keychain
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                        .focused($focusedField, equals: .name)
                    TextField(text: baseURL) { LocalizedText(.settingsTranslationServiceBaseURL) }
                    TextField(text: model) { LocalizedText(.settingsTranslationServiceModel) }
                    SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
                } footer: {
                    if !TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "") {
                        LocalizedText(.settingsTranslationServiceBaseURLInvalid)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextEditor(text: promptTemplate)
                        .font(.body.monospaced())
                        // Fixed height (not just minHeight): a min-only TextEditor
                        // greedily fills the form's slack and jumps taller when the
                        // layout re-runs on a state change (e.g. after a test).
                        .frame(height: 120)
                } header: {
                    LocalizedText(.settingsTranslationServicePrompt)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        LocalizedText(.settingsTranslationServicePromptHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !TranslationServiceConfig.promptContainsText(promptTemplate.wrappedValue) {
                            LocalizedText(.settingsTranslationServicePromptMissingText)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Toggle(isOn: manualMode) {
                        LocalizedText(.settingsTranslationServiceManualMode)
                    }
                } footer: {
                    LocalizedText(.settingsTranslationServiceManualModeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button { runTest() } label: { LocalizedText(.settingsTranslationServiceTest) }
                    .disabled(testState == .testing)
                testStatusLabel
                    .font(.callout)
                Spacer()
                Button(role: .cancel) { onCancel() } label: { LocalizedText(.settingsTranslationServiceCancel) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft, trimmedKey.isEmpty ? nil : trimmedKey)
                } label: { LocalizedText(.settingsTranslationServiceSave) }
                .keyboardShortcut(.defaultAction)
                .disabled(!isSaveable)
            }
            // Pin the bar height so the status label appearing/changing after a
            // test never resizes the bar and reflows the fixed-height card above.
            .frame(height: 28)
            .padding(12)
        }
        .onAppear {
            // Defer one runloop hop so NSHostingView finishes building its
            // responder chain before we claim focus; otherwise the assignment can
            // land before the field exists and silently no-op.
            DispatchQueue.main.async { focusedField = .name }
        }
    }

    /// The connection-test outcome shown next to the Test button. Idle renders
    /// nothing; a failure is truncated to one line so it never pushes the bottom
    /// bar's buttons off the edge.
    @ViewBuilder
    private var testStatusLabel: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            LocalizedText(.settingsTranslationServiceTesting)
                .foregroundStyle(.secondary)
        case .success:
            Label { LocalizedText(.settingsTranslationServiceTestOK) } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .failure(let message):
            Label { Text(message) } icon: { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var baseURL: Binding<String> {
        Binding(get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 })
    }
    private var model: Binding<String> {
        Binding(get: { draft.model ?? "" }, set: { draft.model = $0 })
    }
    private var promptTemplate: Binding<String> {
        Binding(
            get: { draft.promptTemplate ?? TranslationServiceConfig.defaultPromptTemplate },
            set: { draft.promptTemplate = $0 }
        )
    }
    private var manualMode: Binding<Bool> {
        Binding(get: { draft.manualMode ?? false }, set: { draft.manualMode = $0 })
    }

    /// Save is allowed only once the service is actually runnable: a name, a
    /// valid http(s) base URL, a model, and an API key. Without all four the
    /// factory silently skips the service and it vanishes from the panel, which
    /// reads as the feature being broken.
    private var isSaveable: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "")
            && !(draft.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            testState = .failure(L(.settingsTranslationServiceTestFailed))
            return
        }
        let config = draft
        testState = .testing
        Task {
            let provider = OpenAICompatibleProvider(config: config, apiKey: trimmedKey)
            let request = TranslationRequest(
                text: "Hello",
                source: TranslationLanguage.english,
                target: TranslationLanguage.simplifiedChinese
            )
            do {
                var received = false
                for try await chunk in provider.translate(request) {
                    switch chunk {
                    case .delta(let s) where !s.isEmpty: received = true
                    case .final(let s) where !s.isEmpty: received = true
                    default: break
                    }
                }
                testState = received ? .success : .failure(L(.settingsTranslationServiceTestFailed))
            } catch {
                testState = .failure(translationErrorMessage(error))
            }
        }
    }
}
