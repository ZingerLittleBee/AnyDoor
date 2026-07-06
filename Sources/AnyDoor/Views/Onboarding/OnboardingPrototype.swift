import SwiftUI
import AppKit
import TourKit

// ============================================================================
// PROTOTYPE — THROWAWAY. Do not ship.
//
// Question: should the first-run onboarding move from the current
// "sidebar rail + live demo pane" layout to a TourKit-style slideshow card
// (https://github.com/rampatra/TourKit)?
//
// Three variants of the onboarding window, switchable via a floating
// DEBUG-only bar at the bottom (click ‹ › or press ←/→). The selected variant
// persists in UserDefaults key "prototype.onboardingVariant" so it survives
// window reopen (Settings → 通用 → 重新打开引导).
//
//   A — 现状:      the existing OnboardingView (sidebar rail, baseline)
//   B — TourKit 原版: the real TourSlideshowView; the six live step demos are
//                    snapshotted to PNGs at runtime (frame 0, no animation)
//                    and fed to TourPage — TourKit only takes static images
//   C — TourKit 风格: TourKit's structure rebuilt natively (dark card, top
//                    visual, centered text, capsule CTA, glass controls) but
//                    the visual region hosts the LIVE animated step demos
//
// Cleanup when a variant wins: delete this file, revert the root swap in
// OnboardingWindowController, drop the TourKit dependency from Package.swift
// (unless B/C won and keeps it), and record the verdict.
// ============================================================================

// MARK: - Host + switcher

/// Prototype root mounted by `OnboardingWindowController` in place of
/// `OnboardingView`. In release builds it renders the baseline only.
@MainActor
struct OnboardingPrototypeHost: View {
    let onClose: () -> Void

    #if DEBUG
    private enum Variant: String, CaseIterable {
        case a = "A", b = "B", c = "C"

        var label: String {
            switch self {
            case .a: return "A — 现状 · 侧边栏"
            case .b: return "B — TourKit 原版 · 静态图"
            case .c: return "C — TourKit 风格 · 实时演示"
            }
        }
    }

    @AppStorage("prototype.onboardingVariant") private var variantRaw = "A"

    private var variant: Variant { Variant(rawValue: variantRaw) ?? .a }
    #endif

    var body: some View {
        #if DEBUG
        ZStack(alignment: .bottom) {
            Group {
                switch variant {
                case .a: OnboardingView(onClose: onClose)
                case .b: OnboardingTourKitStockVariant(onClose: onClose)
                case .c: OnboardingTourStyleVariant(onClose: onClose)
                }
            }
            .frame(width: 680, height: 520)

            switcher
                .padding(.bottom, 8)
        }
        .frame(width: 680, height: 520)
        #else
        OnboardingView(onClose: onClose)
        #endif
    }

    #if DEBUG
    private var switcher: some View {
        HStack(spacing: 12) {
            Button { cycle(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Text(verbatim: variant.label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()

            Button { cycle(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.78)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    private func cycle(_ delta: Int) {
        let all = Variant.allCases
        let index = all.firstIndex(of: variant) ?? 0
        variantRaw = all[(index + delta + all.count) % all.count].rawValue
    }
    #endif
}

// MARK: - Shared step demo switch

/// The per-step live demo views, duplicated from `OnboardingView.stepDemo`
/// (private there). Used by variant C's stage and variant B's snapshots.
private struct OnboardingPrototypeStepDemo: View {
    let step: OnboardingStep
    var onClose: () -> Void = {}

    var body: some View {
        switch step {
        case .menuBar:          OnboardingMenuBarStep()
        case .permissions:      OnboardingPermissionsStep()
        case .hyperKey:         OnboardingHyperKeyStep()
        case .capture:          OnboardingCaptureStep()
        case .clipboardPalette: OnboardingClipboardPaletteStep()
        case .customize:        OnboardingCustomizeStep(onClose: onClose)
        }
    }
}

// MARK: - Variant B: stock TourKit slideshow (static snapshots)

/// The real `TourSlideshowView`, unmodified. TourPage only accepts images, so
/// each step demo is rendered once via `ImageRenderer` (its entry animations
/// never run — this shows TourKit's stock look, not final artwork).
private struct OnboardingTourKitStockVariant: View {
    let onClose: () -> Void
    @State private var pages: [TourPage] = []

    var body: some View {
        ZStack {
            // Dark surround so TourKit's dark card doesn't sit on the host
            // window's light background (card-in-card would read as a bug).
            Color(white: 0.06)

            TourSlideshowView(
                pages: pages,
                // 560 wide → 350 image + 170 panel = exactly the 520 window height.
                width: 560,
                continueButtonTitle: LocalizedStringKey(L(.onboardingNavContinue)),
                finishButtonTitle: LocalizedStringKey(L(.onboardingNavDone)),
                onFinish: onClose,
                onClose: onClose
            )
        }
        .onAppear {
            if pages.isEmpty {
                pages = OnboardingPrototypeSnapshots.makePages()
            }
        }
    }
}

/// Renders each step demo to a 16:10 PNG in a temp directory
/// ("…-WIPE-ME") and wraps them as `TourPage`s loaded via `Bundle(url:)`.
@MainActor
private enum OnboardingPrototypeSnapshots {
    static func makePages() -> [TourPage] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("AnyDoorPrototype-OnboardingTour-WIPE-ME", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let bundle = Bundle(url: dir) else { return [] }

        return OnboardingStep.allCases.compactMap { step in
            let name = "onboarding-step-\(step.rawValue)"
            let url = dir.appendingPathComponent("\(name).png")
            guard writePNG(for: step, to: url) else { return nil }
            return TourPage(
                imageName: name,
                imageBundle: bundle,
                // TourKit resolves titles against its page bundle; the lookup
                // misses there, so the pre-localized string renders verbatim.
                title: LocalizedStringKey(L(step.titleKey)),
                description: LocalizedStringKey(L(step.subtitleKey))
            )
        }
    }

    private static func writePNG(for step: OnboardingStep, to url: URL) -> Bool {
        let content = ZStack {
            Color(nsColor: .windowBackgroundColor)
            OnboardingPrototypeStepDemo(step: step)
                .padding(18)
        }
        // 16:10, TourKit's fixed artwork aspect ratio.
        .frame(width: 560, height: 350)
        .environment(LocalizationManager.shared)
        .environment(\.locale, LocalizationManager.shared.effectiveLocale)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard
            let nsImage = renderer.nsImage,
            let tiff = nsImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}

// MARK: - Variant C: TourKit-style card hosting the live demos

/// TourKit's slideshow structure rebuilt natively: full-bleed dark card, top
/// visual region, bottom gradient blend, page dots, glass back/close buttons,
/// centered title/description, capsule CTA tinted per step. Unlike TourKit,
/// the visual region hosts the live animated step demos.
private struct OnboardingTourStyleVariant: View {
    let onClose: () -> Void

    @State private var index = 0

    private let steps = OnboardingStep.allCases
    private var step: OnboardingStep { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            stage
            panel
        }
        .background(Color(white: 0.10))
        .animation(.easeInOut(duration: 0.25), value: index)
    }

    // Top visual region (~60%): live demo + gradient blend + dots + controls.
    private var stage: some View {
        ZStack(alignment: .top) {
            OnboardingPrototypeStepDemo(step: step, onClose: onClose)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 30)
                .id(index)
                .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(white: 0.10).opacity(0.6), location: 0.6),
                    .init(color: Color(white: 0.10), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // Reuses TourKit's public page-indicator component directly.
            PageIndicator(totalPages: steps.count, currentIndex: index)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            topControls
        }
        .frame(height: 318)
        .clipped()
    }

    private var topControls: some View {
        HStack {
            glassButton(systemName: "chevron.left") {
                if index > 0 { index -= 1 }
            }
            .opacity(index > 0 ? 1 : 0)

            Spacer()

            glassButton(systemName: "xmark") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // Bottom panel: centered text + capsule CTA, TourKit's hierarchy.
    private var panel: some View {
        VStack(spacing: 6) {
            LocalizedText(step.titleKey)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            LocalizedText(step.subtitleKey)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.70))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 14)

            Button(action: advance) {
                LocalizedText(isLast ? .onboardingNavDone : .onboardingNavContinue)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 220, height: 42)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [step.tint, step.tint.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 44)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(index)
        .transition(.opacity)
    }

    private func glassButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func advance() {
        if isLast {
            onClose()
        } else {
            index += 1
        }
    }
}
