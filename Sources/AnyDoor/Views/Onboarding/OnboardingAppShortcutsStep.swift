import SwiftUI

/// Step 3 — "One hotkey, any app": the product's core interaction. A mock
/// desktop replays the toggle loop: the Hyper Key + a letter press down, the
/// target app's window springs to the front over a dimmed background window;
/// a second press hides it again. Chips cycle through example apps, and the
/// trigger picker below drives the real `HyperKeyService` (the same setting
/// the Hyper Key page fine-tunes next), so a choice here takes effect.
struct OnboardingAppShortcutsStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hyperKey = HyperKeyService.shared
    @State private var exampleIndex = 0
    @State private var keyPressed = false
    @State private var windowVisible = false

    private struct AppExample {
        let name: String
        let symbol: String
        let tint: Color
        let key: String
    }

    private let examples = [
        AppExample(name: "Terminal", symbol: "terminal.fill", tint: .green, key: "T"),
        AppExample(name: "Safari", symbol: "safari.fill", tint: .blue, key: "B"),
        AppExample(name: "Notes", symbol: "note.text", tint: .yellow, key: "N"),
    ]

    private var example: AppExample { examples[exampleIndex] }

    var body: some View {
        OnboardingDemoStage(tint: .mint) {
            VStack(spacing: 10) {
                HStack {
                    hotkeyCombo
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(Array(examples.enumerated()), id: \.offset) { index, item in
                            OnboardingChip(title: item.name, symbol: item.symbol, selected: index == exampleIndex, tint: .mint)
                                .contentShape(Capsule())
                                .onTapGesture {
                                    if reduceMotion { exampleIndex = index }
                                    else { withAnimation(.easeInOut(duration: 0.2)) { exampleIndex = index } }
                                }
                        }
                    }
                }

                desktop
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                hyperKeyPicker

                Label {
                    LocalizedText(.onboardingAppShortcutsHint)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .task(id: exampleIndex) { await playToggleCycle() }
    }

    // MARK: Hotkey combo (Hyper Key + letter)

    /// Compact keycap face for the Hyper trigger: the glyph from the trigger's
    /// display label ("Caps Lock (⇪)" → "⇪"), or the raw label for F-keys.
    /// While no trigger is chosen, Caps Lock is shown as the suggestion —
    /// mirroring the Hyper Key page.
    private var triggerCapLabel: String {
        let trigger = hyperKey.trigger == .none ? .capsLock : hyperKey.trigger
        let label = trigger.displayLabel
        if let open = label.firstIndex(of: "("), let close = label.firstIndex(of: ")"), open < close {
            return String(label[label.index(after: open)..<close])
        }
        return label
    }

    private var hyperGlyphLabel: String {
        hyperKey.includeShift ? "⌃⌥⇧⌘" : "⌃⌥⌘"
    }

    private var hotkeyCombo: some View {
        HStack(spacing: 6) {
            OnboardingKeycap(label: triggerCapLabel, width: 34, highlighted: true, pressed: keyPressed, tint: .mint)
            OnboardingKeycap(label: example.key, width: 30, highlighted: true, pressed: keyPressed, tint: .mint)
                .id(exampleIndex)
            if hyperKey.isActive {
                Text(verbatim: "= \(hyperGlyphLabel)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: windowVisible ? "macwindow" : "macwindow.badge.plus")
                .font(.system(size: 12))
                .foregroundStyle(windowVisible ? example.tint : .secondary)
        }
        .onboardingAnimation(.spring(response: 0.25, dampingFraction: 0.6), reduceMotion: reduceMotion, value: keyPressed)
    }

    // MARK: Hyper Key trigger picker

    /// Drives the real `HyperKeyService`, exactly like the Hyper Key page's
    /// trigger control — picking a key here activates it for real.
    private var hyperKeyPicker: some View {
        HStack {
            LocalizedText(.settingsGeneralHyperKeyLabel)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
    }

    private var triggerBinding: Binding<HyperKeyTrigger> {
        Binding(
            get: { hyperKey.trigger },
            set: { new in Task { await hyperKey.setTrigger(new) } }
        )
    }

    // MARK: Mock desktop

    private var desktop: some View {
        VStack(spacing: 0) {
            OnboardingMenuBarStrip(iconHighlighted: false)

            ZStack {
                backgroundWindow
                    .offset(x: -46, y: -6)
                    .opacity(windowVisible ? 0.45 : 0.9)
                    .blur(radius: windowVisible ? 0.5 : 0)

                appWindow
                    .offset(x: 30, y: 10)
                    .scaleEffect(windowVisible ? 1 : 0.86, anchor: .bottom)
                    .opacity(windowVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onboardingAnimation(.spring(response: 0.38, dampingFraction: 0.78), reduceMotion: reduceMotion, value: windowVisible)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    /// The app the user was working in before the hotkey — a plain document
    /// window that dims once the target app takes the front.
    private var backgroundWindow: some View {
        mockWindow(width: 190, symbol: "doc.text", name: "Document", tint: .secondary) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(width: index == 2 ? 90 : 150, height: 5)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appWindow: some View {
        mockWindow(width: 215, symbol: example.symbol, name: example.name, tint: example.tint) {
            appContent
        }
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        .id(exampleIndex)
    }

    @ViewBuilder
    private var appContent: some View {
        switch example.name {
        case "Terminal":
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(verbatim: "$ swift build")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                    RoundedRectangle(cornerRadius: 1).fill(.green).frame(width: 5, height: 10)
                }
                Text(verbatim: "Build complete!")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(Color.black.opacity(0.82))
        case "Safari":
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                    Text(verbatim: "anydoor.app")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.35), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 5)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .top)
        default:
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.yellow.opacity(0.55))
                    .frame(width: 74, height: 6)
                ForEach(0..<2, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(width: index == 1 ? 96 : 140, height: 5)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        }
    }

    private func mockWindow(width: CGFloat, symbol: String, name: String, tint: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                HStack(spacing: 3) {
                    Circle().fill(.red.opacity(0.75)).frame(width: 5, height: 5)
                    Circle().fill(.yellow.opacity(0.75)).frame(width: 5, height: 5)
                    Circle().fill(.green.opacity(0.75)).frame(width: 5, height: 5)
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tint)
                Text(verbatim: name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 21, height: 1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial)
            Divider()
            content()
        }
        .frame(width: width)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    // MARK: Animation loop

    /// One full toggle for the current example: press → window springs front,
    /// press again → window hides — then advance to the next app, which
    /// restarts this task via `.task(id:)`.
    private func playToggleCycle() async {
        if reduceMotion {
            windowVisible = true
            return
        }

        windowVisible = false
        keyPressed = false
        try? await Task.sleep(for: .milliseconds(500))
        if Task.isCancelled { return }

        await pressHotkey()
        windowVisible = true
        try? await Task.sleep(for: .milliseconds(2100))
        if Task.isCancelled { return }

        await pressHotkey()
        windowVisible = false
        try? await Task.sleep(for: .milliseconds(700))
        if Task.isCancelled { return }

        exampleIndex = (exampleIndex + 1) % examples.count
    }

    private func pressHotkey() async {
        keyPressed = true
        try? await Task.sleep(for: .milliseconds(150))
        keyPressed = false
        try? await Task.sleep(for: .milliseconds(130))
    }
}
