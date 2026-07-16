import PluginInterface
import SwiftUI

/// Type-safe view of the shared string catalog's keys this module uses. The
/// entries live in the host's `Localizable.xcstrings` (user story 27:
/// plugin UI localizes through the existing catalog); resolution goes through
/// `PluginHost.localizedString` so language switches apply without a relaunch.
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

/// Module-typed front for the shared resolver (`PluginHost.localizedString`).
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    PluginHost.localizedString(key.rawValue, arguments: args)
}

/// Module-typed front for the shared reactive `PluginLocalizedText`: a `Text`
/// that re-renders on a host language switch.
@MainActor
struct LocalizedText: View {
    private let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        PluginLocalizedText(key: key.rawValue)
    }
}
