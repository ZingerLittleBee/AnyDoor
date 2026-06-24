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
    private func presentEditor(_ config: TranslationServiceConfig, isNew: Bool, initialKey: String? = nil) {
        TranslationServiceEditorOverlay.shared.present(
            config: config,
            isNew: isNew,
            initialKey: initialKey,
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
                // Attach the explanation to this specific field (an inline caption
                // under its label) rather than as a section footer, so it sits
                // directly beneath "备用目标语言".
                VStack(alignment: .leading, spacing: 2) {
                    LocalizedText(.settingsTranslationSecondTarget)
                    LocalizedText(.settingsTranslationSecondTargetFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: autoSpeak) { LocalizedText(.settingsTranslationAutoSpeak) }
        } header: {
            LocalizedText(.settingsTranslationLanguageSection)
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

            if config.kind == .openAICompatible || config.kind == .deepl {
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
    /// Keeps the DeepLX endpoint/token fields collapsed by default so official
    /// DeepL users (the common case) aren't presented with self-hosted options.
    @State private var showDeepLXAdvanced = false
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
        initialKey: String? = nil,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        // A new-from-preset draft seeds its key from the preset (e.g. Ollama);
        // otherwise load any stored key for an existing service.
        _apiKey = State(initialValue: initialKey ?? keychain.apiKey(for: config.id) ?? "")
        self.isNew = isNew
        self.keychain = keychain
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if draft.kind == .deepl {
                    deepLSection
                } else {
                    llmConnectionSection
                    llmPromptSection
                    llmExtraBodySection
                    llmManualModeSection
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

    // MARK: - Kind-aware form sections

    @ViewBuilder private var llmConnectionSection: some View {
        Section {
            TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                .focused($focusedField, equals: .name)
            TextField(text: baseURL) { LocalizedText(.settingsTranslationServiceBaseURL) }
            TextField(text: model) { LocalizedText(.settingsTranslationServiceModel) }
            SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
        } footer: {
            if !TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "") {
                LocalizedText(.settingsTranslationServiceBaseURLInvalid)
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var llmPromptSection: some View {
        Section {
            TextEditor(text: promptTemplate)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                // Fixed height (not just minHeight): a min-only TextEditor
                // greedily fills the form's slack and jumps taller when the
                // layout re-runs on a state change (e.g. after a test).
                .frame(height: 120)
        } header: {
            LocalizedText(.settingsTranslationServicePrompt)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.settingsTranslationServicePromptHint)
                    .font(.caption).foregroundStyle(.secondary)
                if !TranslationServiceConfig.promptContainsText(promptTemplate.wrappedValue) {
                    LocalizedText(.settingsTranslationServicePromptMissingText)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var llmExtraBodySection: some View {
        Section {
            TextField(text: extraBodyJSON, axis: .vertical) {
                LocalizedText(.settingsTranslationServiceExtraBody)
            }
            .lineLimit(2...4)
            .font(.body.monospaced())
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.settingsTranslationServiceExtraBodyHint)
                    .font(.caption).foregroundStyle(.secondary)
                if !TranslationServiceConfig.isValidExtraBody(draft.extraBodyJSON) {
                    LocalizedText(.settingsTranslationServiceExtraBodyInvalid)
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var llmManualModeSection: some View {
        Section {
            Toggle(isOn: manualMode) { LocalizedText(.settingsTranslationServiceManualMode) }
        } footer: {
            LocalizedText(.settingsTranslationServiceManualModeHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var deepLSection: some View {
        Section {
            TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                .focused($focusedField, equals: .name)
            SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
        }
        Section {
            DisclosureGroup(isExpanded: $showDeepLXAdvanced) {
                TextField(text: baseURL) { LocalizedText(.settingsTranslationDeepLEndpoint) }
                SecureField(text: deeplxToken) { LocalizedText(.settingsTranslationDeepLToken) }
            } label: {
                LocalizedText(.settingsTranslationDeepLAdvanced)
            }
        } footer: {
            LocalizedText(.settingsTranslationDeepLHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

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
    private var extraBodyJSON: Binding<String> {
        Binding(get: { draft.extraBodyJSON ?? "" },
                set: { draft.extraBodyJSON = $0.isEmpty ? nil : $0 })
    }
    /// DeepLX token mirrors the same Keychain slot as the official DeepL key.
    private var deeplxToken: Binding<String> {
        Binding(get: { apiKey }, set: { apiKey = $0 })
    }

    /// Save is allowed only once the service is actually runnable. Rules vary by kind:
    /// DeepL needs a name + (official key OR valid DeepLX endpoint); LLM services need
    /// name + valid base URL + model + key + valid extraBody JSON.
    private var isSaveable: Bool {
        let named = !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        let keyPresent = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch draft.kind {
        case .deepl:
            // Official needs a key; DeepLX needs a valid endpoint (token optional).
            let validEndpoint = TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "")
            return named && (keyPresent || validEndpoint)
        default:
            return named
                && TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "")
                && !(draft.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && keyPresent
                && TranslationServiceConfig.isValidExtraBody(draft.extraBodyJSON)
        }
    }

    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = draft
        testState = .testing
        Task {
            let provider: any TranslationProvider = config.kind == .deepl
                ? DeepLProvider(config: config, apiKey: trimmedKey)
                : OpenAICompatibleProvider(config: config, apiKey: trimmedKey)
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
