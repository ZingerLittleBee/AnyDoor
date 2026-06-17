import SwiftUI

/// Step 5 — "Clipboard wall & command palette". Top half mocks the clipboard
/// wall (tabs, search, favorite, source filter); bottom half mocks the command
/// palette auto-typing `300 usd`, `:3000`, and `hosts` with their results.
struct OnboardingClipboardPaletteStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exampleIndex = 0
    @State private var typed = ""

    private struct PaletteExample {
        let query: String
        let symbol: String
        let resultKey: L10n.Key
        let sectionKey: L10n.Key
        let tint: Color
    }

    private let examples: [PaletteExample] = [
        PaletteExample(query: "300 usd = rmb", symbol: "dollarsign.arrow.circlepath",
                       resultKey: .onboardingDemoCurrencyResult, sectionKey: .commandPaletteSectionConversion, tint: .green),
        PaletteExample(query: ":3000", symbol: "network",
                       resultKey: .onboardingDemoPortResult, sectionKey: .commandPaletteSectionPorts, tint: .blue),
        PaletteExample(query: "hosts", symbol: "list.bullet.rectangle",
                       resultKey: .onboardingDemoHostsResult, sectionKey: .commandPaletteSectionHosts, tint: .orange),
    ]

    private var example: PaletteExample { examples[exampleIndex] }

    var body: some View {
        OnboardingDemoStage(tint: .teal) {
            VStack(spacing: 12) {
                clipboardWall
                commandPalette
            }
            .padding(14)
        }
        // Retype whenever the example changes (chip tap or auto-advance).
        .task(id: exampleIndex) {
            let query = example.query
            if reduceMotion {
                typed = query
                return
            }
            typed = ""
            for character in query {
                typed.append(character)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        // Auto-advance the example loop (disabled under Reduce Motion).
        .task {
            if reduceMotion { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2600))
                if Task.isCancelled { return }
                exampleIndex = (exampleIndex + 1) % examples.count
            }
        }
    }

    // MARK: Clipboard wall

    private var clipboardWall: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { LocalizedText(.onboardingClipboardWallCaption) } icon: { Image(systemName: "doc.on.clipboard") }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.teal)
                Spacer()
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L(.clipboardSourceFilterHelp))
            }

            HStack(spacing: 6) {
                OnboardingChip(title: L(.clipboardCategoryAll), selected: true, tint: .teal)
                OnboardingChip(title: L(.clipboardCategoryFavorites), symbol: "star", tint: .teal)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    Text(L(.clipboardSearchPlaceholder)).font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 8) {
                clipboardCard(symbol: "link", tint: .blue, kindKey: .clipboardKindText, sample: "anydoor.app", favorite: true)
                clipboardCard(symbol: "photo", tint: .pink, kindKey: .clipboardKindImage, sample: nil, favorite: false)
                clipboardCard(symbol: "eyedropper", tint: .purple, kindKey: .clipboardKindColor, sample: "#3B82F6", favorite: false)
                clipboardCard(symbol: "text.viewfinder", tint: .orange, kindKey: .clipboardKindOcr, sample: "Invoice #42", favorite: false)
            }
        }
    }

    private func clipboardCard(symbol: String, tint: Color, kindKey: L10n.Key, sample: String?, favorite: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Spacer()
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            }
            if let sample {
                Text(sample)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
            LocalizedText(kindKey).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    // MARK: Command palette

    private var commandPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { LocalizedText(.onboardingClipboardPaletteCaption) } icon: { Image(systemName: "command") }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(Array(examples.enumerated()), id: \.offset) { index, item in
                        OnboardingChip(title: item.query, selected: index == exampleIndex, tint: .indigo)
                            .contentShape(Capsule())
                            .onTapGesture {
                                if reduceMotion { exampleIndex = index }
                                else { withAnimation(.easeInOut(duration: 0.2)) { exampleIndex = index } }
                            }
                    }
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 1) {
                        Text(typed.isEmpty ? L(.commandPaletteSearchPlaceholder) : typed)
                            .font(.system(size: 13, design: typed.isEmpty ? .default : .monospaced))
                            .foregroundStyle(typed.isEmpty ? .tertiary : .primary)
                        if !typed.isEmpty {
                            RoundedRectangle(cornerRadius: 1).fill(.indigo).frame(width: 1.5, height: 15)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                resultRow
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .id(exampleIndex)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
            }
            .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: exampleIndex)
        }
    }

    private var resultRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(example.tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: example.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(example.tint)
                }
            VStack(alignment: .leading, spacing: 1) {
                LocalizedText(example.resultKey).font(.system(size: 12, weight: .medium))
                LocalizedText(example.sectionKey).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "return")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
