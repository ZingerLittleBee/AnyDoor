import SwiftUI

/// Step 3 — "Make Caps Lock your Hyper Key". A keycap presses down and the
/// modifier glyphs fan out; the controls below drive the real `HyperKeyService`
/// so a choice made here actually takes effect.
struct OnboardingHyperKeyStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hyperKey = HyperKeyService.shared
    @State private var glyphsOut = false
    @State private var pressed = false

    private var glyphs: [String] {
        hyperKey.includeShift ? ["⌃", "⌥", "⇧", "⌘"] : ["⌃", "⌥", "⌘"]
    }

    private var hyperGlyphLabel: String {
        hyperKey.includeShift ? "⌃⌥⇧⌘" : "⌃⌥⌘"
    }

    private var triggerCapLabel: String {
        hyperKey.trigger == .none ? "Caps Lock ⇪" : hyperKey.trigger.displayLabel
    }

    var body: some View {
        OnboardingDemoStage(tint: .purple) {
            VStack(spacing: 14) {
                keyboardDemo
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)

                exampleRow

                controls

                Label {
                    LocalizedText(.onboardingHyperKeyNote)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .onAppear { play() }
        .onChange(of: hyperKey.includeShift) { _, _ in play() }
    }

    // MARK: Keyboard demo

    private var keyboardDemo: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 8) {
                ForEach(glyphs, id: \.self) { glyph in
                    OnboardingModifierBadge(glyph: glyph, tint: .purple)
                }
            }
            .offset(y: glyphsOut ? -42 : 6)
            .opacity(glyphsOut ? 1 : 0)
            .onboardingAnimation(.spring(response: 0.45, dampingFraction: 0.7), reduceMotion: reduceMotion, value: glyphsOut)
            .onboardingAnimation(.spring(response: 0.45, dampingFraction: 0.7), reduceMotion: reduceMotion, value: hyperKey.includeShift)

            OnboardingKeycap(label: triggerCapLabel, width: 132, highlighted: true, pressed: pressed, tint: .purple)
                .onboardingAnimation(.spring(response: 0.25, dampingFraction: 0.6), reduceMotion: reduceMotion, value: pressed)
        }
        .frame(height: 78)
        .contentShape(Rectangle())
        .onTapGesture { play() }
    }

    private var exampleRow: some View {
        HStack(spacing: 8) {
            LocalizedText(.onboardingHyperKeyExampleCaption)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(hyperGlyphLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.purple)
            OnboardingKeycap(label: "V", width: 26, tint: .purple)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            OnboardingChip(title: L(.builtinClipboardWall), symbol: "doc.on.clipboard", selected: true, tint: .teal)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: hyperKey.includeShift)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 9) {
            HStack {
                LocalizedText(.onboardingHyperKeyTriggerLabel)
                    .font(.system(size: 12, weight: .medium))
                if hyperKey.isActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    LocalizedText(.onboardingHyperKeyEnabledNote)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Picker(selection: triggerBinding) {
                    ForEach(HyperKeyTrigger.allCases, id: \.self) { trigger in
                        Text(trigger == .none ? L(.settingsGeneralHyperKeyTriggerNone) : trigger.displayLabel)
                            .tag(trigger)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(hyperKey.isApplying)
            }

            HStack {
                LocalizedText(.settingsGeneralHyperKeyQuickPress)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker(selection: quickPressBinding) {
                    ForEach(HyperKeyQuickPress.allCases, id: \.self) { quickPress in
                        Text(quickPressLabel(quickPress)).tag(quickPress)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(hyperKey.trigger == .none || hyperKey.isApplying)
            }

            Toggle(isOn: includeShiftBinding) {
                LocalizedText(.settingsGeneralHyperKeyIncludeShift)
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .disabled(hyperKey.trigger == .none || hyperKey.isApplying)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
    }

    // MARK: Bindings & helpers

    private var triggerBinding: Binding<HyperKeyTrigger> {
        Binding(
            get: { hyperKey.trigger },
            set: { new in
                Task { await hyperKey.setTrigger(new) }
                play()
            }
        )
    }

    private var quickPressBinding: Binding<HyperKeyQuickPress> {
        Binding(
            get: { hyperKey.quickPress },
            set: { new in Task { await hyperKey.setQuickPress(new) } }
        )
    }

    private var includeShiftBinding: Binding<Bool> {
        Binding(
            get: { hyperKey.includeShift },
            set: { new in Task { await hyperKey.setIncludeShift(new) } }
        )
    }

    private func quickPressLabel(_ quickPress: HyperKeyQuickPress) -> String {
        switch quickPress {
        case .doesNothing: return L(.settingsGeneralHyperKeyQuickPressDoesNothing)
        case .escape:      return L(.settingsGeneralHyperKeyQuickPressEscape)
        case .original:    return L(.settingsGeneralHyperKeyQuickPressOriginal)
        }
    }

    private func play() {
        if reduceMotion {
            pressed = false
            glyphsOut = true
            return
        }
        glyphsOut = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { pressed = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { glyphsOut = true }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pressed = false }
        }
    }
}
