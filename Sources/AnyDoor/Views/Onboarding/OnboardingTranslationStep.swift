import SwiftUI

/// Step 6 — "Instant translation". A hand-drawn mock of the translation panel
/// that replays its core loop: the input auto-types an English sentence, the
/// detected-language chip appears, and two service cards stream their results
/// in parallel — mirroring the real toolbar, input well, and language bar.
struct OnboardingTranslationStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var typedInput = ""
    @State private var detected = false
    @State private var showCards = false
    @State private var typedResults = ["", ""]

    private let inputSample = "Make it feel effortless."
    private struct ServiceResult {
        let name: String
        let symbol: String
        let text: String
    }

    private let services = [
        ServiceResult(name: "Apple", symbol: "apple.logo", text: "让一切轻而易举。"),
        ServiceResult(name: "DeepL", symbol: "globe", text: "让它感觉毫不费力。"),
    ]

    var body: some View {
        OnboardingDemoStage(tint: .indigo) {
            VStack(spacing: 8) {
                mockPanel

                Spacer(minLength: 0)

                Label {
                    LocalizedText(.onboardingTranslationHint)
                } icon: {
                    Image(systemName: "return")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .task { await runLoop() }
    }

    // MARK: Mock translation panel

    private var mockPanel: some View {
        VStack(spacing: 8) {
            toolbar
            inputWell
            languageBar
            if showCards {
                ForEach(Array(services.enumerated()), id: \.offset) { index, service in
                    resultCard(service, streamed: typedResults[index])
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
        .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: showCards)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            ForEach(["pin", "clock.arrow.circlepath", "camera.viewfinder", "gearshape"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputWell: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 1) {
                Text(typedInput.isEmpty ? L(.translationInputPlaceholder) : typedInput)
                    .font(.system(size: 12))
                    .foregroundStyle(typedInput.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                if !typedInput.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(.indigo).frame(width: 1.5, height: 13)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if detected {
                    Text(L(.translationRecognizedAs, englishName))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .transition(.opacity)
                }
                Spacer()
                if !typedInput.isEmpty {
                    Image(systemName: "speaker.wave.2").font(.system(size: 9)).foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 14)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: detected)
    }

    // MARK: Language bar (auto-detect ⇄ target)

    private var languageBar: some View {
        HStack(spacing: 8) {
            languageCapsule(detected ? L(.translationAutoDetectHint, englishName) : L(.translationAutoDetect))
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.05), in: Circle())
            languageCapsule(chineseName)
                .frame(maxWidth: .infinity)
        }
        .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: detected)
    }

    private func languageCapsule(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    // MARK: Result cards

    private func resultCard(_ service: ServiceResult, streamed: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: service.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text(service.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if streamed == service.text {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(streamed.isEmpty ? " " : streamed)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: streamed)
    }

    // MARK: Localized language names

    private var englishName: String {
        TranslationLanguage.named("en")?.displayName(in: LocalizationManager.shared.effectiveLocale) ?? "English"
    }

    private var chineseName: String {
        TranslationLanguage.named("zh-Hans")?.displayName(in: LocalizationManager.shared.effectiveLocale) ?? "Chinese (Simplified)"
    }

    // MARK: Animation loop

    private func runLoop() async {
        if reduceMotion {
            typedInput = inputSample
            detected = true
            showCards = true
            typedResults = services.map(\.text)
            return
        }

        while !Task.isCancelled {
            typedInput = ""
            detected = false
            showCards = false
            typedResults = ["", ""]
            try? await Task.sleep(for: .milliseconds(500))

            for character in inputSample {
                if Task.isCancelled { return }
                typedInput.append(character)
                try? await Task.sleep(for: .milliseconds(55))
            }

            detected = true
            try? await Task.sleep(for: .milliseconds(400))
            showCards = true
            try? await Task.sleep(for: .milliseconds(300))

            // Both cards stream together (second one staggered), mirroring the
            // real fan-out translation where every service answers in parallel.
            let first = Array(services[0].text)
            let second = Array(services[1].text)
            let stagger = 5
            var tick = 0
            while typedResults[0].count < first.count || typedResults[1].count < second.count {
                if Task.isCancelled { return }
                if typedResults[0].count < first.count {
                    typedResults[0].append(first[typedResults[0].count])
                }
                if tick >= stagger, typedResults[1].count < second.count {
                    typedResults[1].append(second[typedResults[1].count])
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(60))
            }

            try? await Task.sleep(for: .milliseconds(2800))
        }
    }
}
