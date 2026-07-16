import PluginInterface
import SwiftUI

/// Module-level access point to the host services injected at plugin
/// construction. The module's singletons (window controller, history store)
/// and its SwiftUI views reach the host through this bridge rather than
/// threading the services through every initializer — mirroring the host
/// app's own shared-instance style. Set exactly once, by
/// `ImageConversionPlugin.init`.
///
/// Every accessor degrades safely when the bridge is unset (pure unit tests):
/// strings fall back to their raw keys, toasts and window tracking no-op, and
/// pasteboard writes go straight to the pasteboard.
@MainActor
enum PluginHost {
    private(set) static var services: (any PluginHostServices)?

    static func bootstrap(_ services: any PluginHostServices) {
        Self.services = services
    }

    static func showToast(_ toast: PluginToast) {
        services?.showToast(toast)
    }

    static func trackRegularWindow(_ window: NSWindow) {
        services?.trackRegularWindow(window)
    }

    static func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        if let services {
            try services.pasteboardSelfWrite(body)
        } else {
            try body(NSPasteboard.general)
        }
    }
}

/// Type-safe view of the shared string catalog's keys this module uses. The
/// entries live in the host's `Localizable.xcstrings` (user story 27:
/// plugin UI localizes through the existing catalog); resolution goes through
/// the host services so language switches apply without a relaunch.
enum L10n {
    enum Key: String, CaseIterable, Sendable {
        case clipboardActionRevealInFinder = "clipboard.action.revealInFinder"
        case commandPaletteActionOpen = "commandPalette.action.open"
        case imageConversionBasketCount = "imageConversion.basket.count"
        case imageConversionClear = "imageConversion.clear"
        case imageConversionClipboardItem = "imageConversion.clipboardItem"
        case imageConversionCompareEmpty = "imageConversion.compare.empty"
        case imageConversionCompareOriginal = "imageConversion.compare.original"
        case imageConversionCompareResult = "imageConversion.compare.result"
        case imageConversionCompareUpdating = "imageConversion.compare.updating"
        case imageConversionConvert = "imageConversion.convert"
        case imageConversionConvertAll = "imageConversion.convertAll"
        case imageConversionConverting = "imageConversion.converting"
        case imageConversionCopyAsFile = "imageConversion.copyAsFile"
        case imageConversionDropSubtitle = "imageConversion.drop.subtitle"
        case imageConversionDropTitle = "imageConversion.drop.title"
        case imageConversionFileMissing = "imageConversion.fileMissing"
        case imageConversionHistoryClear = "imageConversion.history.clear"
        case imageConversionHistoryEmpty = "imageConversion.history.empty"
        case imageConversionHistorySaveFailed = "imageConversion.history.saveFailed"
        case imageConversionHistoryTitle = "imageConversion.history.title"
        case imageConversionModeFormat = "imageConversion.mode.format"
        case imageConversionModeTargetSize = "imageConversion.mode.targetSize"
        case imageConversionNoFormats = "imageConversion.noFormats"
        case imageConversionOutputPanelMessage = "imageConversion.output.panelMessage"
        case imageConversionOutputPanelPrompt = "imageConversion.output.panelPrompt"
        case imageConversionQuality = "imageConversion.quality"
        case imageConversionRemove = "imageConversion.remove"
        case imageConversionSaveAnyway = "imageConversion.saveAnyway"
        case imageConversionSavedAnyway = "imageConversion.savedAnyway"
        case imageConversionSidebarBasket = "imageConversion.sidebar.basket"
        case imageConversionSourceMissing = "imageConversion.sourceMissing"
        case imageConversionStatusFailed = "imageConversion.status.failed"
        case imageConversionStatusFirstFrameOnly = "imageConversion.status.firstFrameOnly"
        case imageConversionStatusTargetMiss = "imageConversion.status.targetMiss"
        case imageConversionStatusUnsupported = "imageConversion.status.unsupported"
        case imageConversionStatusUnsupportedFormat = "imageConversion.status.unsupportedFormat"
        case imageConversionStop = "imageConversion.stop"
        case imageConversionTargetFormat = "imageConversion.targetFormat"
        case imageConversionTargetInvalid = "imageConversion.targetInvalid"
        case imageConversionTargetSizePNGNote = "imageConversion.targetSize.pngNote"
        case imageConversionTargetSizeSameFormat = "imageConversion.targetSize.sameFormat"
        case imageConversionTitle = "imageConversion.title"
        case imageConversionToastSummary = "imageConversion.toast.summary"
        case imageConversionToastSummaryWithHistoryWarnings = "imageConversion.toast.summaryWithHistoryWarnings"
        case imageConversionUnattainableHint = "imageConversion.unattainableHint"
        case pluginDescription = "plugin.imageConversion.description"
        case pluginName = "plugin.imageConversion.name"
        case pluginUninstallImpact = "plugin.imageConversion.uninstallImpact"
        case toastCopiedToClipboard = "toast.copiedToClipboard"
    }
}

/// Module-local counterpart of the host's `L(_:)`: resolves a catalog key via
/// the host services, applying format arguments in the host's active locale.
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    guard let services = PluginHost.services else { return key.rawValue }
    let template = services.localizedString(key.rawValue)
    if args.isEmpty {
        return template
    }
    return String(format: template, locale: services.effectiveLocale, arguments: args)
}

/// Module-local counterpart of the host's `LocalizedText`: reading the host's
/// locale in `body` establishes observation on the host's `@Observable`
/// localization state, so the view re-renders on a language switch.
@MainActor
struct LocalizedText: View {
    let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        _ = PluginHost.services?.effectiveLocale
        return Text(L(key))
    }
}
