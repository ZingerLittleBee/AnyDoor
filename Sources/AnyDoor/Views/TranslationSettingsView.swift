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

    @State private var editingConfig: TranslationServiceConfig?
    @State private var isPresentingNew = false
    @State private var historyRetention: Int = 200

    var body: some View {
        Form {
            languageSection
            servicesSection
            historySection
        }
        .formStyle(.grouped)
        .sheet(item: $editingConfig) { config in
            TranslationServiceConfigSheet(
                config: config,
                isNew: isPresentingNew,
                keychain: keychain
            ) { saved, apiKey in
                if let apiKey { keychain.setAPIKey(apiKey, for: saved.id) }
                settings.upsertService(saved)
                editingConfig = nil
                isPresentingNew = false
            } onCancel: {
                editingConfig = nil
                isPresentingNew = false
            }
        }
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

    private var servicesSection: some View {
        Section {
            ForEach(settings.services) { config in
                serviceRow(config)
            }
            .onMove { indices, newOffset in
                var reordered = settings.services
                reordered.move(fromOffsets: indices, toOffset: newOffset)
                for (index, var config) in reordered.enumerated() {
                    config.order = index
                    reordered[index] = config
                }
                settings.setServices(reordered)
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
                isPresentingNew = true
                editingConfig = new
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
            Toggle(isOn: enabledBinding(config)) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)

            Image(systemName: config.iconName)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(config.displayName)
            Spacer()

            if config.kind == .openAICompatible {
                Button { isPresentingNew = false; editingConfig = config } label: {
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
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Stepper(value: $historyRetention, in: 20...2000, step: 20) {
                Text(L(.settingsTranslationHistoryRetention) + ": \(historyRetention)")
            }
            .onChange(of: historyRetention) { _, newValue in
                history.trim(retention: newValue)
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
private struct TranslationServiceConfigSheet: View {
    @State private var draft: TranslationServiceConfig
    @State private var apiKey: String
    @State private var testState: TestState = .idle
    private let isNew: Bool
    private let keychain: TranslationKeychainStore
    private let onSave: (TranslationServiceConfig, String?) -> Void
    private let onCancel: () -> Void

    private enum TestState: Equatable { case idle, testing, success, failure(String) }

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
                    TextField(text: baseURL) { LocalizedText(.settingsTranslationServiceBaseURL) }
                    TextField(text: model) { LocalizedText(.settingsTranslationServiceModel) }
                    SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
                }

                Section {
                    TextEditor(text: promptTemplate)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                } header: {
                    LocalizedText(.settingsTranslationServicePrompt)
                }

                Section {
                    HStack(spacing: 10) {
                        Button { runTest() } label: {
                            LocalizedText(.settingsTranslationServiceTest)
                        }
                        .disabled(testState == .testing)

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
                                .lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(role: .cancel) { onCancel() } label: { Text(verbatim: "Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft, trimmedKey.isEmpty ? nil : trimmedKey)
                } label: { Text(verbatim: "Save") }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 480)
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
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
