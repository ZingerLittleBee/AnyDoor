import SwiftUI
import AppKit

/// The first-run onboarding flow: a left progress rail and a right content pane
/// whose body is a hand-drawn, animated SwiftUI mock of each feature. Never
/// blocks the app — every page can be skipped (Esc), advanced (Return), or
/// stepped back. Honors Reduce Motion.
@MainActor
struct OnboardingView: View {
    /// Closes the hosting window (Skip / Done / finishing the flow).
    let onClose: () -> Void

    @State private var nav = OnboardingNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: OnboardingStep { nav.current }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                contentPane
                Divider()
                footer
            }
        }
        .frame(width: 680, height: 520)
        .focusEffectDisabled()
    }

    // MARK: Sidebar (progress rail)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: MenuBarIcon.defaultName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: "AnyDoor")
                    .font(.headline)
            }
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(OnboardingStep.allCases) { item in
                    sidebarRow(item)
                }
            }

            Spacer()

            ProgressView(value: Double(nav.index) + 1, total: Double(nav.stepCount))
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .onboardingAnimation(.easeInOut(duration: 0.3), reduceMotion: reduceMotion, value: nav.index)
        }
        .padding(18)
        .frame(width: 188)
        .background(.regularMaterial)
    }

    private func sidebarRow(_ item: OnboardingStep) -> some View {
        let isCurrent = item == step
        let isDone = item.rawValue < nav.index
        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(isCurrent ? item.tint : (isDone ? item.tint.opacity(0.25) : Color.secondary.opacity(0.12)))
                    .frame(width: 22, height: 22)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(item.tint)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }
            LocalizedText(item.sidebarTitleKey)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? item.tint.opacity(0.12) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { navigate(to: item) }
        .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: nav.index)
    }

    // MARK: Content pane

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText(step.titleKey)
                    .font(.title2.bold())
                LocalizedText(step.subtitleKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stepDemo(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 14)),
                    removal: .opacity
                ))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onboardingAnimation(.spring(response: 0.4, dampingFraction: 0.85), reduceMotion: reduceMotion, value: nav.index)
    }

    @ViewBuilder
    private func stepDemo(_ step: OnboardingStep) -> some View {
        switch step {
        case .menuBar:          OnboardingMenuBarStep()
        case .permissions:      OnboardingPermissionsStep()
        case .appShortcuts:     OnboardingAppShortcutsStep()
        case .hyperKey:         OnboardingHyperKeyStep()
        case .capture:          OnboardingCaptureStep()
        case .clipboardPalette: OnboardingClipboardPaletteStep()
        case .translation:      OnboardingTranslationStep()
        case .imageConversion:  OnboardingImageConversionStep()
        case .customize:        OnboardingCustomizeStep(onClose: onClose)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onClose) { LocalizedText(.onboardingNavSkip) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if !nav.isFirst {
                Button(action: goBack) { LocalizedText(.onboardingNavBack) }
            }

            Button(action: advance) {
                LocalizedText(nav.isLast ? .onboardingNavDone : .onboardingNavContinue)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Navigation

    private func advance() {
        if nav.isLast {
            onClose()
        } else {
            withMotion { nav.next() }
        }
    }

    private func goBack() {
        withMotion { nav.back() }
    }

    private func navigate(to item: OnboardingStep) {
        guard item != step else { return }
        withMotion { nav.go(to: item) }
    }

    private func withMotion(_ mutate: () -> Void) {
        if reduceMotion {
            mutate()
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { mutate() }
        }
    }
}
