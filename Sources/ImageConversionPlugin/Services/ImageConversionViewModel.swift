import AppKit
import Foundation
import ImageCodec
import Observation
import PluginInterface
import SwiftUI
import UniformTypeIdentifiers

public struct ImageConversionBasketItem: Identifiable, Equatable, Sendable {
    /// A basket entry is either an on-disk file (output beside it) or an
    /// in-memory bitmap such as a pasted screenshot (output to Downloads).
    enum Payload: Equatable, Sendable {
        case file(URL)
        case bitmap(Data)
    }

    public let id: String
    let payload: Payload
    let displayName: String

    public static func file(_ url: URL) -> ImageConversionBasketItem {
        let standardized = url.standardizedFileURL
        return ImageConversionBasketItem(
            id: standardized.path,
            payload: .file(standardized),
            displayName: standardized.lastPathComponent
        )
    }

    public static func bitmap(_ data: Data, displayName: String) -> ImageConversionBasketItem {
        ImageConversionBasketItem(
            id: "bitmap:\(UUID().uuidString)",
            payload: .bitmap(data),
            displayName: displayName
        )
    }

    var fileURL: URL? {
        if case let .file(url) = payload { return url }
        return nil
    }

    /// Secondary row line: the source folder for files, empty for bitmaps.
    var subtitle: String {
        fileURL?.deletingLastPathComponent().path ?? ""
    }
}

/// Terminal per-item state of the last Target Size run, keyed by basket item.
enum ImageConversionItemStatus: Equatable, Sendable {
    case targetMiss(PreparedCandidate)
    case unsupported(ImageConversionPreflightIssue)
    case failed
}

enum ImageConversionSidebarTab: Hashable {
    case basket
    case history
}

@MainActor
@Observable
final class ImageConversionViewModel {
    private(set) var items: [ImageConversionBasketItem] = []
    private(set) var availableFormats: [ImageConversionFormat]
    var selectedFormat: ImageConversionFormat {
        didSet {
            ImageConversionPreferences.setTargetFormat(selectedFormat, defaults: defaults)
            scheduleQualityPreflightNotices()
            schedulePreview()
        }
    }
    /// Whole-percent quality (1–100) applied to lossy targets for the whole run.
    var qualityPercent: Int {
        didSet {
            ImageConversionPreferences.setQualityPercent(qualityPercent, defaults: defaults)
            schedulePreview()
        }
    }
    var isConverting = false
    var isDropTargeted = false
    var sidebarTab: ImageConversionSidebarTab = .basket
    /// Split-view sidebar collapse state, owned here so the window's ⌘B key
    /// monitor can toggle it. Session-only, deliberately not persisted.
    var isSidebarCollapsed = false

    func toggleSidebar() {
        // The toolbar button animates through the split view itself; a bare
        // state flip from the key monitor would snap instead, so match it.
        withAnimation {
            isSidebarCollapsed.toggle()
        }
    }

    // MARK: Target Size state

    var mode: ImageConversionMode {
        didSet {
            ImageConversionPreferences.setMode(mode, defaults: defaults)
            if mode != oldValue { invalidateTargetSizeOutcomes() }
            schedulePreview()
        }
    }
    /// The Per-Output Limit currently applied to conversion. Only a valid
    /// committed field edit changes it.
    private(set) var targetLimit: TargetSizeLimit
    /// Live text of the target field; parse errors surface inline without
    /// touching `targetLimit`.
    var targetText: String = ""
    private(set) var targetParseError: TargetSizeLimitParseError?
    /// Per-item outcome of the last run (miss/unsupported/failed items stay
    /// in the basket with their status; successes leave).
    private(set) var itemStatuses: [String: ImageConversionItemStatus] = [:]
    private(set) var qualityFirstFrameOnlyItemIDs: Set<String> = []

    // MARK: Selection & exact preview

    /// What the Comparison Workspace shows for the selected item. Stale
    /// metrics are never presented as current: any change flips to
    /// `.updating` before new bytes appear.
    /// Exact result of the quality-mode encode for the selected item: the
    /// same `ImageConverter.candidateData` bytes a run would commit.
    struct QualityPreviewCandidate: Equatable {
        /// Reload identity for the view: item + format + quality.
        var id: String
        var data: Data
    }

    enum PreviewState: Equatable {
        case empty
        case updating
        case ready(PreparedCandidate)
        case readyQuality(QualityPreviewCandidate)
        case unsupported(ImageConversionPreflightIssue)
        case invalidConfiguration
        case failed
    }

    var selectedItemID: String? {
        didSet { schedulePreview() }
    }
    private(set) var previewState: PreviewState = .empty
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var isWindowPresented = false
    @ObservationIgnored private var qualityPreflightTask: Task<Void, Never>?
    @ObservationIgnored private var qualityPreflightGeneration = 0

    var selectedItem: ImageConversionBasketItem? {
        items.first { $0.id == selectedItemID }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: ImageConversionEngine?
    /// Stable engine-side IDs for basket items, so preview/run/Save Anyway
    /// all address the same artifacts.
    @ObservationIgnored private var engineIDs: [String: UUID] = [:]
    @ObservationIgnored private var openPanelTask: Task<Void, Never>?
    @ObservationIgnored private var openPanel: NSOpenPanel?
    @ObservationIgnored private var outputPickerTask: Task<Void, Never>?
    @ObservationIgnored private var outputPanel: NSOpenPanel?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(
        availableFormats: [ImageConversionFormat] = ImageConversionFormat.availableTargets(),
        defaults: UserDefaults = .standard
    ) {
        self.availableFormats = availableFormats
        self.defaults = defaults
        self.selectedFormat = ImageConversionPreferences.targetFormat(
            availableFormats: availableFormats,
            defaults: defaults
        )
        self.qualityPercent = ImageConversionPreferences.qualityPercent(defaults: defaults)
        self.mode = ImageConversionPreferences.mode(defaults: defaults)
        self.targetLimit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        self.targetText = targetLimit.displayValue(locale: .current)
        self.engine = try? ImageConversionEngine()
    }

    /// Re-read every persisted conversion preference so a backup import
    /// applies to an already-open window without relaunching. Skipped during
    /// a run: the run froze its configuration at start, and the property
    /// observers would race the frozen state.
    func reloadFromDefaults() {
        guard !isConverting else { return }
        selectedFormat = ImageConversionPreferences.targetFormat(
            availableFormats: availableFormats,
            defaults: defaults
        )
        qualityPercent = ImageConversionPreferences.qualityPercent(defaults: defaults)
        mode = ImageConversionPreferences.mode(defaults: defaults)
        targetLimit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        targetText = targetLimit.displayValue(locale: .current)
        targetParseError = nil
        schedulePreview()
    }

    /// The quality slider is only meaningful for lossy targets.
    var isQualityAdjustable: Bool { selectedFormat.isLossy }

    var canConvert: Bool {
        guard !items.isEmpty, !isConverting else { return false }
        switch mode {
        case .quality:
            return availableFormats.contains(selectedFormat)
        case .targetSize:
            return engine != nil && targetParseError == nil
        }
    }

    // MARK: - Target field

    /// Parse and apply the edited target text. Invalid input surfaces an
    /// inline error and disables conversion; `targetLimit` keeps its last
    /// valid value.
    func commitTargetText(locale: Locale = .current) {
        do {
            let parsed = try TargetSizeLimit.parse(targetText, unit: targetLimit.unit, locale: locale)
            let changed = parsed != targetLimit || targetParseError != nil
            targetLimit = parsed
            targetParseError = nil
            ImageConversionPreferences.setTargetSizeLimit(parsed, defaults: defaults)
            if changed {
                invalidateTargetSizeOutcomes()
                schedulePreview()
            }
        } catch let error as TargetSizeLimitParseError {
            targetParseError = error
            invalidateTargetSizeOutcomes()
            schedulePreview()
        } catch {
            targetParseError = .malformed
            invalidateTargetSizeOutcomes()
            schedulePreview()
        }
    }

    /// Switching the unit converts only the displayed number — the effective
    /// byte limit never changes on a unit switch.
    func switchTargetUnit(to unit: TargetSizeUnit, locale: Locale = .current) {
        guard unit != targetLimit.unit else { return }
        targetLimit = targetLimit.converted(to: unit)
        targetText = targetLimit.displayValue(locale: locale)
        targetParseError = nil
        ImageConversionPreferences.setTargetSizeLimit(targetLimit, defaults: defaults)
        // Bytes are unchanged, so the preview candidate stays valid.
    }

    func addFiles(_ urls: [URL]) {
        guard !isConverting else { return }
        let imageURLs = urls
            .map { $0.standardizedFileURL }
            .filter { ImageConverter.isImageFile(at: $0) }

        var existing = Set(items.map(\.id))
        var next = items
        for url in imageURLs {
            let key = url.path
            guard existing.insert(key).inserted else { continue }
            next.append(.file(url))
        }
        items = next.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        scheduleQualityPreflightNotices()
        selectFirstIfNeeded()
    }

    /// Sidebar Add / ⌘O: non-modal open panel appending image files to the
    /// basket. The async `begin()` keeps the floating conversion panel usable
    /// while the picker is up.
    func presentOpenPanel() {
        guard !isConverting, openPanelTask == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        openPanel = panel
        openPanelTask = Task { @MainActor in
            defer {
                self.openPanel = nil
                self.openPanelTask = nil
            }
            let response = await panel.begin()
            guard !Task.isCancelled, response == .OK, !self.isConverting else { return }
            self.addFiles(panel.urls)
        }
    }

    /// Adds a pasted bitmap (e.g. a fresh screenshot) with a generic display name.
    func addBitmap(_ data: Data) {
        guard !isConverting else { return }
        items.append(.bitmap(data, displayName: L(.imageConversionClipboardItem)))
        scheduleQualityPreflightNotices()
        selectFirstIfNeeded()
    }

    /// Merges preloaded basket items (e.g. from a clipboard-history entry),
    /// deduping by id and preserving insertion order so a bitmap keeps its
    /// history-derived display name.
    func add(_ newItems: [ImageConversionBasketItem]) {
        guard !isConverting else { return }
        var existing = Set(items.map(\.id))
        var next = items
        for item in newItems where existing.insert(item.id).inserted {
            next.append(item)
        }
        items = next
        scheduleQualityPreflightNotices()
        selectFirstIfNeeded()
    }

    func remove(_ item: ImageConversionBasketItem) {
        guard !isConverting else { return }
        removeItems(withIDs: [item.id])
    }

    func clear() {
        guard !isConverting else { return }
        let removed = items
        items.removeAll()
        itemStatuses.removeAll()
        qualityFirstFrameOnlyItemIDs.removeAll()
        qualityPreflightGeneration += 1
        qualityPreflightTask?.cancel()
        qualityPreflightTask = nil
        for item in removed { releaseEngineArtifacts(for: item.id) }
        selectedItemID = nil
    }

    /// The first item added to an empty basket becomes selected; later
    /// additions never steal selection.
    private func selectFirstIfNeeded() {
        if selectedItemID == nil || selectedItem == nil {
            selectedItemID = items.first?.id
        }
    }

    func resetSidebarForPresentation() {
        sidebarTab = .basket
        isWindowPresented = true
        schedulePreview()
    }

    func windowDidHide() {
        isWindowPresented = false
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        previewState = .empty
        pruneIdlePreviewArtifactsIfNeeded()
    }

    /// Request Stop: takes effect at the current candidate/commit boundary.
    /// Completed outputs remain valid; there is no batch rollback.
    func stopConversion() {
        runTask?.cancel()
    }

    /// Plugin `deactivate` path: dismiss pending panels, cancel the folder
    /// selection workflow and Conversion Run, then wait for every owned task
    /// to wind down before the plugin's surfaces disappear.
    func cancelActiveWork() async {
        let pendingOpenPanel = openPanelTask
        let pendingOutputPicker = outputPickerTask
        let activeRun = runTask

        pendingOpenPanel?.cancel()
        pendingOutputPicker?.cancel()
        activeRun?.cancel()
        openPanel?.cancel(nil)
        outputPanel?.cancel(nil)

        await pendingOpenPanel?.value
        await pendingOutputPicker?.value
        await activeRun?.value
    }

    /// Injectable folder picker (given the remembered directory, returns the
    /// chosen one or nil on cancel) so tests can bypass the modal panel.
    @ObservationIgnored var outputDirectoryPicker: (@MainActor (URL?) async -> URL?)?

    /// Convert All first asks where to save; the last confirmed choice is
    /// remembered as the panel's starting directory. The run starts only
    /// after a confirmed pick — cancel converts nothing.
    func convert() {
        guard canConvert, outputPickerTask == nil else { return }
        let remembered = ImageConversionPreferences.outputDirectory(defaults: defaults)
        outputPickerTask = Task { @MainActor in
            defer { self.outputPickerTask = nil }
            let directory: URL?
            if let picker = outputDirectoryPicker {
                directory = await picker(remembered)
            } else {
                directory = await self.presentOutputDirectoryPanel(startingAt: remembered)
            }
            guard !Task.isCancelled, let directory, self.canConvert else { return }
            ImageConversionPreferences.setOutputDirectory(directory, defaults: self.defaults)
            switch self.mode {
            case .quality: self.convertQuality(outputDirectory: directory)
            case .targetSize: self.convertTargetSize(outputDirectory: directory)
            }
        }
    }

    private func presentOutputDirectoryPanel(startingAt remembered: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L(.imageConversionOutputPanelPrompt)
        panel.message = L(.imageConversionOutputPanelMessage)
        if let remembered {
            panel.directoryURL = remembered
        }
        outputPanel = panel
        defer { outputPanel = nil }
        let response = await panel.begin()
        guard !Task.isCancelled, response == .OK else { return nil }
        return panel.url
    }

    private func convertQuality(outputDirectory: URL) {
        isConverting = true
        let frozenItems = items
        let inputs: [ImageConversionInput] = frozenItems.map { item in
            switch item.payload {
            case let .file(url): return .file(url)
            case let .bitmap(data): return .bitmap(data)
            }
        }
        let target = selectedFormat
        let frozenQualityPercent = qualityPercent
        let quality = Double(qualityPercent) / 100.0

        runTask = Task { [weak self] in
            let summary = await ImageConversionSession().convertAll(
                inputs: inputs,
                target: target,
                quality: quality,
                outputDirectory: outputDirectory,
                downloadsDirectory: ImageConversionSession.defaultDownloadsDirectory
            )
            self?.finish(
                summary,
                frozenItems: frozenItems,
                target: target,
                qualityPercent: frozenQualityPercent
            )
        }
    }

    private func finish(
        _ summary: ImageConversionSummary,
        frozenItems: [ImageConversionBasketItem],
        target: ImageConversionFormat,
        qualityPercent: Int
    ) {
        isConverting = false
        runTask = nil
        var historyWarnings = 0
        if summary.converted > 0 {
            historyWarnings = recordHistory(
                summary.outputs,
                target: target,
                qualityPercent: qualityPercent
            )
            let completedIDs = Set(summary.outputs.compactMap { output in
                frozenItems.indices.contains(output.inputIndex)
                    ? frozenItems[output.inputIndex].id
                    : nil
            })
            removeItems(withIDs: completedIDs)
            copyOutputsToPasteboard(summary.outputURLs)
        }
        pruneIdlePreviewArtifactsIfNeeded()
        showConversionSummary(
            converted: summary.converted,
            skipped: summary.skipped,
            historyWarnings: historyWarnings
        )

        // Preview scheduling was suspended for the whole run; refresh the
        // workspace for the current selection now.
        schedulePreview()
    }

    /// Write one Conversion Record per produced output. The target format and
    /// quality are the whole run's config (one config per run).
    private func recordHistory(
        _ outputs: [ImageConversionOutput],
        target: ImageConversionFormat,
        qualityPercent: Int
    ) -> Int {
        outputs.reduce(into: 0) { warnings, output in
            let saved = ImageConversionHistoryStore.shared.record(
                sourceName: output.sourceName,
                sourceKind: output.sourceKind,
                targetFormat: target,
                qualityPercent: qualityPercent,
                outputPath: output.outputURL.path,
                firstFrameOnly: output.firstFrameOnly
            )
            if !saved { warnings += 1 }
        }
    }

    private func copyOutputsToPasteboard(_ outputURLs: [URL]) {
        guard !outputURLs.isEmpty else { return }
        PluginHost.pasteboardSelfWrite { pb in
            pb.clearContents()
            pb.writeObjects(outputURLs as [NSURL])
        }
    }

    // MARK: - Target Size run

    private func convertTargetSize(outputDirectory: URL) {
        guard let engine else { return }
        isConverting = true
        itemStatuses.removeAll()

        // Freeze configuration and item snapshots: config edits and basket
        // mutations are disabled until completion or Stop.
        let request = currentTargetSizeRequest()
        let frozen = items.map {
            (item: $0, snapshot: snapshot(for: $0, outputDirectory: outputDirectory))
        }

        // Retire the in-flight preview completely before any run work: its
        // pruneDisplayed must never interleave with the run's completion
        // state on the engine actor.
        previewTask?.cancel()
        let retiringPreview = previewTask
        previewTask = nil

        runTask = Task { [weak self] in
            await retiringPreview?.value
            var successes: [(item: ImageConversionBasketItem, conversion: CommittedConversion)] = []
            var interrupted = false
            var eligible: [(item: ImageConversionBasketItem, snapshot: ImageConversionItemSnapshot)] = []
            for entry in frozen {
                if Task.isCancelled { interrupted = true; break }
                switch await engine.preflight(item: entry.snapshot) {
                case .success:
                    eligible.append(entry)
                case .failure(let issue):
                    self?.itemStatuses[entry.item.id] = .unsupported(issue)
                }
            }
            if !interrupted {
                for entry in eligible {
                    if Task.isCancelled { interrupted = true; break }
                    let outcome = await engine.convertItem(entry.snapshot, request: request)
                    guard let self else { return }
                    switch outcome {
                    case .success(let conversion):
                        successes.append((entry.item, conversion))
                    case .targetMiss(let candidate):
                        self.itemStatuses[entry.item.id] = .targetMiss(candidate)
                    case .unsupported(let issue):
                        self.itemStatuses[entry.item.id] = .unsupported(issue)
                    case .failed:
                        self.itemStatuses[entry.item.id] = .failed
                    case .cancelled:
                        interrupted = true
                    }
                    if interrupted { break }
                }
            }
            self?.finishTargetSize(successes, interrupted: interrupted)
        }
    }

    private func finishTargetSize(
        _ successes: [(item: ImageConversionBasketItem, conversion: CommittedConversion)],
        interrupted: Bool
    ) {
        isConverting = false
        runTask = nil

        // A success here is always a within-limit result; a Best-Effort
        // candidate arrives as targetMiss and commits nothing.
        var historyWarnings = 0
        for (item, conversion) in successes {
            let saved = recordTargetSizeHistory(
                conversion.output,
                candidate: conversion.candidate,
                item: item,
                outcome: .targetReached
            )
            if !saved { historyWarnings += 1 }
        }

        // Successful items leave the basket together, in basket order, and
        // only their URLs reach the clipboard. Everything else stays.
        let succeededIDs = Set(successes.map(\.item.id))
        removeItems(withIDs: succeededIDs)
        copyOutputsToPasteboard(successes.map(\.conversion.output.url))
        pruneIdlePreviewArtifactsIfNeeded()

        if !successes.isEmpty || !interrupted {
            showConversionSummary(
                converted: successes.count,
                skipped: itemStatuses.count,
                historyWarnings: historyWarnings
            )
        }

        // Preview scheduling was suspended for the whole run; refresh the
        // workspace for the current selection now.
        schedulePreview()
    }

    /// Explicit Save Anyway for a target-missed item: commits the retained
    /// Best-Effort artifact byte-identically, writes its Conversion Record
    /// only then, and lets the item leave the basket.
    func saveBestEffort(_ item: ImageConversionBasketItem) {
        guard !isConverting,
              let engine,
              case .targetMiss(let candidate) = itemStatuses[item.id],
              let engineID = engineIDs[item.id] else { return }
        let destination = destinationPolicy(for: item, format: candidate.configuration.format)
        Task { [weak self] in
            do {
                let output = try await engine.saveBestEffort(
                    itemID: engineID,
                    expectedArtifact: candidate.artifact,
                    destination: destination
                )
                guard let self else { return }
                let historySaved = self.recordTargetSizeHistory(
                    output, candidate: candidate, item: item, outcome: .targetUnattainable
                )
                self.remove(item)
                PluginHost.showToast(historySaved
                    ? .success(L(.imageConversionSavedAnyway))
                    : .info(L(.imageConversionHistorySaveFailed)))
            } catch {
                PluginHost.showToast(.failure(L(.imageConversionFileMissing)))
            }
        }
    }

    // MARK: - Exact preview

    /// Regenerate the selected item's exact preview after a short debounce.
    /// Only the selected basket item is previewed; obsolete work can never
    /// replace a newer state thanks to the generation token.
    func schedulePreview() {
        // A run froze the basket, and its completion state lives on the engine
        // actor: preview work (including artifact pruning) must not interleave
        // with it. The finish path reschedules the preview.
        guard !isConverting else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        previewTask = nil

        guard isWindowPresented else {
            previewState = .empty
            pruneIdlePreviewArtifactsIfNeeded()
            return
        }
        switch mode {
        case .quality:
            // Displayed engine artifacts are Target Size state; this mode
            // previews in memory and keeps none of them.
            if let engine { Task { await engine.pruneDisplayed(keepingItem: nil) } }
            scheduleQualityPreview(generation: generation)
        case .targetSize:
            scheduleTargetSizePreview(generation: generation)
        }
    }

    /// Quality-mode exact preview: encode the selected item with the frozen
    /// format/quality through the same converter the run uses.
    private func scheduleQualityPreview(generation: Int) {
        guard let item = selectedItem else {
            previewState = .empty
            return
        }
        previewState = .updating
        let format = selectedFormat
        let qualityPercent = qualityPercent
        let payload = item.payload
        let previewID = "\(item.id)|\(format.fileExtension)|\(qualityPercent)"
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TargetSizePolicy.previewDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> Data? in
                let converter = ImageConverter()
                let quality = Double(qualityPercent) / 100.0
                switch payload {
                case .file(let url):
                    return try? converter.candidateData(fileAt: url, format: format, quality: quality)
                case .bitmap(let data):
                    return try? converter.candidateData(bitmapData: data, format: format, quality: quality)
                }
            }
            let encoded = await worker.value
            guard let self, self.previewGeneration == generation else { return }
            self.previewState = encoded.map {
                .readyQuality(QualityPreviewCandidate(id: previewID, data: $0))
            } ?? .failed
        }
    }

    private func scheduleTargetSizePreview(generation: Int) {
        guard let engine else {
            previewState = .empty
            return
        }
        guard let item = selectedItem else {
            previewState = .empty
            Task { await engine.pruneDisplayed(keepingItem: nil) }
            return
        }
        guard targetParseError == nil else {
            previewState = .invalidConfiguration
            Task { await engine.pruneDisplayed(keepingItem: nil) }
            return
        }

        previewState = .updating
        let request = currentTargetSizeRequest()
        let snapshot = snapshot(for: item)
        previewTask = Task { [weak self] in
            // A cancellation issued before this task first ran (e.g. by a run
            // starting) must also skip the prune, not just the preparation.
            guard !Task.isCancelled else { return }
            await engine.pruneDisplayed(keepingItem: snapshot.id)
            try? await Task.sleep(nanoseconds: UInt64(TargetSizePolicy.previewDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                let candidate = try await engine.prepareCandidate(
                    item: snapshot, request: request
                )
                guard let self, self.previewGeneration == generation else { return }
                self.previewState = .ready(candidate)
            } catch let issue as ImageConversionPreflightIssue {
                guard let self, self.previewGeneration == generation else { return }
                self.previewState = .unsupported(issue)
            } catch is CancellationError {
                // A newer preview superseded this one; its state already shows.
            } catch {
                guard let self, self.previewGeneration == generation else { return }
                self.previewState = .failed
            }
        }
    }

    // MARK: - Target Size helpers

    /// `outputDirectory` overrides the destination folder for a run; the
    /// preview path leaves it nil (destination is commit-time state, not part
    /// of the engine's job identity).
    private func snapshot(
        for item: ImageConversionBasketItem,
        outputDirectory: URL? = nil
    ) -> ImageConversionItemSnapshot {
        let engineID = engineIDs[item.id] ?? {
            let fresh = UUID()
            engineIDs[item.id] = fresh
            return fresh
        }()
        let input: ImageConversionInput = switch item.payload {
        case .file(let url): .file(url)
        case .bitmap(let data): .bitmap(data)
        }
        var destination = provisionalDestinationPolicy(for: item)
        if let outputDirectory {
            destination.directory = outputDirectory
        }
        return ImageConversionItemSnapshot(
            id: engineID,
            input: input,
            destination: destination
        )
    }

    /// Directory and base name for a snapshot. The commit path replaces the
    /// extension with the engine-resolved same-format output, so the extension
    /// here is only a provisional source-derived value.
    private func provisionalDestinationPolicy(
        for item: ImageConversionBasketItem
    ) -> AtomicOutputWriter.DestinationPolicy {
        if let url = item.fileURL {
            return AtomicOutputWriter.DestinationPolicy(
                directory: url.deletingLastPathComponent(),
                baseName: url.deletingPathExtension().lastPathComponent,
                fileExtension: url.pathExtension.lowercased()
            )
        }
        return AtomicOutputWriter.DestinationPolicy(
            directory: ImageConversionSession.defaultDownloadsDirectory,
            baseName: ImageConversionNaming.bitmapBaseName(timestamp: Date()),
            fileExtension: ImageConversionFormat.png.fileExtension
        )
    }

    /// Save Anyway destination: the remembered run directory, falling back to
    /// the legacy per-item placement when none was ever chosen.
    private func destinationPolicy(
        for item: ImageConversionBasketItem,
        format: ImageConversionFormat
    ) -> AtomicOutputWriter.DestinationPolicy {
        let remembered = ImageConversionPreferences.outputDirectory(defaults: defaults)
        if let url = item.fileURL {
            return AtomicOutputWriter.DestinationPolicy(
                directory: remembered ?? url.deletingLastPathComponent(),
                baseName: url.deletingPathExtension().lastPathComponent,
                fileExtension: format.fileExtension
            )
        }
        return AtomicOutputWriter.DestinationPolicy(
            directory: remembered ?? ImageConversionSession.defaultDownloadsDirectory,
            baseName: ImageConversionNaming.bitmapBaseName(timestamp: Date()),
            fileExtension: format.fileExtension
        )
    }

    private func currentTargetSizeRequest() -> TargetSizeRequest {
        TargetSizeRequest(
            targetBytes: targetLimit.bytes,
            transparencyBackgroundHex: ImageConversionPreferences
                .transparencyBackgroundHex(defaults: defaults)
        )
    }

    private func invalidateTargetSizeOutcomes() {
        itemStatuses.removeAll()
    }

    private func scheduleQualityPreflightNotices() {
        qualityPreflightGeneration += 1
        let generation = qualityPreflightGeneration
        qualityPreflightTask?.cancel()
        let frozenItems = items
        let target = selectedFormat
        let worker = Task.detached(priority: .utility) {
            let inspector = ImageIOSourceInspector(rejectsMultiImage: false)
            var notices: Set<String> = []
            for item in frozenItems {
                guard !Task.isCancelled else { return notices }
                let input: ImageConversionInput = switch item.payload {
                case .file(let url): .file(url)
                case .bitmap(let data): .bitmap(data)
                }
                if case .success(let preflight) = inspector.preflight(input: input, target: target),
                   preflight.firstFrameOnly {
                    notices.insert(item.id)
                }
            }
            return notices
        }
        qualityPreflightTask = Task { [weak self] in
            let notices = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.qualityPreflightGeneration == generation else { return }
            self.qualityFirstFrameOnlyItemIDs = notices
        }
    }

    private func pruneIdlePreviewArtifactsIfNeeded() {
        guard !isWindowPresented, !isConverting, let engine else { return }
        Task { await engine.pruneDisplayed(keepingItem: nil) }
    }

    private func showConversionSummary(converted: Int, skipped: Int, historyWarnings: Int) {
        if historyWarnings > 0 {
            PluginHost.showToast(.info(L(
                .imageConversionToastSummaryWithHistoryWarnings,
                converted,
                skipped,
                historyWarnings
            )))
        } else {
            PluginHost.showToast(.success(L(
                .imageConversionToastSummary,
                converted,
                skipped
            )))
        }
    }

    private func releaseEngineArtifacts(for itemID: String) {
        guard let engineID = engineIDs.removeValue(forKey: itemID), let engine else { return }
        Task { await engine.removeItem(engineID) }
    }

    /// Remove a completed set as one basket mutation and keep selection on the
    /// nearest surviving row when the selected item leaves.
    private func removeItems(withIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let previousItems = items
        let selectedIndex = selectedItemID.flatMap { selectedID in
            previousItems.firstIndex { $0.id == selectedID }
        }
        let selectedWasRemoved = selectedItemID.map(ids.contains) ?? false

        items.removeAll { ids.contains($0.id) }
        for id in ids {
            itemStatuses[id] = nil
            qualityFirstFrameOnlyItemIDs.remove(id)
            releaseEngineArtifacts(for: id)
        }

        if selectedWasRemoved {
            selectedItemID = selectedIndex.flatMap { index in
                previousItems.enumerated()
                    .filter { !ids.contains($0.element.id) }
                    .min { lhs, rhs in
                        let lhsDistance = abs(lhs.offset - index)
                        let rhsDistance = abs(rhs.offset - index)
                        if lhsDistance == rhsDistance {
                            return lhs.offset > rhs.offset
                        }
                        return lhsDistance < rhsDistance
                    }?
                    .element.id
            } ?? items.first?.id
        } else if selectedItem == nil {
            selectedItemID = items.first?.id
        }
        scheduleQualityPreflightNotices()
    }

    private func recordTargetSizeHistory(
        _ output: CommittedOutput,
        candidate: PreparedCandidate,
        item: ImageConversionBasketItem,
        outcome: ImageConversionOutcome
    ) -> Bool {
        let sourceKind: ImageConversionSourceKind = item.fileURL != nil ? .file : .bitmap
        return ImageConversionHistoryStore.shared.recordTargetSize(
            sourceName: item.displayName,
            sourceKind: sourceKind,
            targetFormat: candidate.configuration.format,
            outputPath: output.url.path,
            outcome: outcome,
            targetByteCount: candidate.configuration.targetBytes,
            candidate: candidate,
            outputByteCount: output.byteCount
        )
    }
}
