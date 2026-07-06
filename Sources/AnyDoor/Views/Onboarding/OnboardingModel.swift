import SwiftUI

// MARK: - First-run persistence

/// Persisted first-run state. Stored in `UserDefaults` (no SwiftData `@Model`)
/// so a clean install shows the flow exactly once. The `defaults` parameter is
/// injectable so the persistence behavior is unit-testable against an ephemeral
/// suite instead of the shared domain.
enum OnboardingState {
    /// Versioned so a future redesigned flow can re-show by bumping the suffix.
    static let completedKey = "onboarding.completed.v1"

    static func hasCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }
}

// MARK: - Steps

/// The pages of the first-run flow, in order. Raw value is the page index.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case menuBar
    case permissions
    case hyperKey
    case capture
    case clipboardPalette
    case translation
    case imageConversion
    case customize

    var id: Int { rawValue }

    /// Short label shown in the left progress rail.
    var sidebarTitleKey: L10n.Key {
        switch self {
        case .menuBar:          return .onboardingSidebarMenuBar
        case .permissions:      return .onboardingSidebarPermissions
        case .hyperKey:         return .onboardingSidebarHyperKey
        case .capture:          return .onboardingSidebarCapture
        case .clipboardPalette: return .onboardingSidebarClipboard
        case .translation:      return .onboardingSidebarTranslation
        case .imageConversion:  return .onboardingSidebarImageConversion
        case .customize:        return .onboardingSidebarCustomize
        }
    }

    var titleKey: L10n.Key {
        switch self {
        case .menuBar:          return .onboardingMenuBarTitle
        case .permissions:      return .onboardingPermissionsTitle
        case .hyperKey:         return .onboardingHyperKeyTitle
        case .capture:          return .onboardingCaptureTitle
        case .clipboardPalette: return .onboardingClipboardTitle
        case .translation:      return .onboardingTranslationTitle
        case .imageConversion:  return .onboardingImageConversionTitle
        case .customize:        return .onboardingCustomizeTitle
        }
    }

    var subtitleKey: L10n.Key {
        switch self {
        case .menuBar:          return .onboardingMenuBarSubtitle
        case .permissions:      return .onboardingPermissionsSubtitle
        case .hyperKey:         return .onboardingHyperKeySubtitle
        case .capture:          return .onboardingCaptureSubtitle
        case .clipboardPalette: return .onboardingClipboardSubtitle
        case .translation:      return .onboardingTranslationSubtitle
        case .imageConversion:  return .onboardingImageConversionSubtitle
        case .customize:        return .onboardingCustomizeSubtitle
        }
    }

    /// SF Symbol shown next to the step in the rail.
    var symbol: String {
        switch self {
        case .menuBar:          return "menubar.arrow.up.rectangle"
        case .permissions:      return "lock.shield"
        case .hyperKey:         return "command"
        case .capture:          return "camera.viewfinder"
        case .clipboardPalette: return "doc.on.clipboard"
        case .translation:      return "character.bubble"
        case .imageConversion:  return "photo.on.rectangle"
        case .customize:        return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .menuBar:          return .blue
        case .permissions:      return .green
        case .hyperKey:         return .purple
        case .capture:          return .orange
        case .clipboardPalette: return .teal
        case .translation:      return .indigo
        case .imageConversion:  return .cyan
        case .customize:        return .pink
        }
    }
}

// MARK: - Navigation

/// Pure, value-type navigation state for the flow. Kept free of SwiftUI/AppKit
/// so step progression is unit-testable.
struct OnboardingNavigation: Equatable {
    let stepCount: Int
    private(set) var index: Int

    init(stepCount: Int = OnboardingStep.allCases.count, index: Int = 0) {
        self.stepCount = max(1, stepCount)
        self.index = min(max(0, index), self.stepCount - 1)
    }

    var isFirst: Bool { index <= 0 }
    var isLast: Bool { index >= stepCount - 1 }

    /// 0...1 progress used by the rail. The first page reads as a non-zero sliver
    /// so the bar never looks empty.
    var progress: Double {
        guard stepCount > 1 else { return 1 }
        return Double(index) / Double(stepCount - 1)
    }

    var current: OnboardingStep {
        OnboardingStep(rawValue: index) ?? .menuBar
    }

    mutating func next() {
        if !isLast { index += 1 }
    }

    mutating func back() {
        if !isFirst { index -= 1 }
    }

    mutating func go(to step: OnboardingStep) {
        index = min(max(0, step.rawValue), stepCount - 1)
    }
}

// MARK: - Permission mapping

/// The three permissions surfaced by the onboarding flow.
enum OnboardingPermissionKind: CaseIterable, Sendable {
    case accessibility
    case screenRecording
    case automation
}

/// Display state for a single permission row.
enum OnboardingPermissionState: Equatable, Sendable {
    case granted
    case needsAction
}

/// A snapshot of the three permission grants, with a pure mapping to per-row
/// display state. Pure value type so the mapping is unit-testable without TCC.
struct OnboardingPermissionSnapshot: Equatable, Sendable {
    var accessibility: Bool = false
    var screenRecording: Bool = false
    var automation: Bool = false

    func isGranted(_ kind: OnboardingPermissionKind) -> Bool {
        switch kind {
        case .accessibility:   return accessibility
        case .screenRecording: return screenRecording
        case .automation:      return automation
        }
    }

    func state(for kind: OnboardingPermissionKind) -> OnboardingPermissionState {
        isGranted(kind) ? .granted : .needsAction
    }

    var grantedCount: Int {
        [accessibility, screenRecording, automation].lazy.filter { $0 }.count
    }

    var allGranted: Bool {
        accessibility && screenRecording && automation
    }
}
