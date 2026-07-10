import Foundation

/// Frozen Target Size configuration for one preview/run job. Policy versions
/// are part of the fingerprint so a policy change can never reuse a stale
/// candidate.
struct TargetSizeJobConfiguration: Hashable, Sendable {
    var format: ImageConversionFormat
    var targetBytes: Int64
    var allowResize: Bool
    var transparencyBackgroundHex: String
    var compressionPolicyVersion: Int = TargetSizePolicy.version
    var metadataPolicyVersion: Int = TargetMetadataPolicy.version
}

/// One immutable prepared candidate: the exact artifact a matching run
/// commits without recompression.
struct PreparedCandidate: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case targetReached
        case passThrough
        case bestEffort(TargetSizeStopReason)
    }

    var kind: Kind
    var artifact: AtomicOutputWriter.CandidateArtifact
    /// Whole-percent encoder quality; 100 for a pass-through copy.
    var quality: Int
    var dimensions: PixelDimensions
    var sourceDimensions: PixelDimensions
    var sourceByteCount: Int64?
    var resizeFallbackApplied: Bool
    var hdrToSDR: Bool
    var firstFrameOnly: Bool
}

enum ImageConversionFailure: Error, Hashable, Sendable {
    /// The source changed between preparation and commit; the item stays in
    /// the basket for re-preflight and explicit retry.
    case sourceChanged
    /// A real candidate contradicted the cached alpha capability; capability
    /// was invalidated and preflight must rerun.
    case capabilityChanged
    case encodingFailed
    /// Orientation/color/metadata audit failed — never silently accepted.
    case policyAuditFailed
    case writeFailed(String)
}

/// One basket item frozen for a run.
struct ImageConversionItemSnapshot: Sendable {
    var id: UUID
    var input: ImageConversionInput
    var destination: AtomicOutputWriter.DestinationPolicy
}

/// A committed output together with the candidate metrics its Conversion
/// Record needs. The history layer never rereads mutable preferences.
struct CommittedConversion: Hashable, Sendable {
    var output: CommittedOutput
    var candidate: PreparedCandidate
}

enum ImageConversionItemOutcome: Sendable {
    case success(CommittedConversion)
    /// Not an error and not a commit: the retained Best-Effort candidate,
    /// written to disk only through an explicit Save Anyway.
    case targetMiss(PreparedCandidate)
    case unsupported(ImageConversionPreflightIssue)
    case failed(ImageConversionFailure)
    case cancelled
}

/// The deep Image I/O engine. One serialized actor owns preview and batch
/// encoding; `CGImageSource`/`CGImage` never cross its boundary. Candidate
/// jobs are owned by a per-item registry keyed by source and configuration
/// fingerprints: preview and run are consumers, a run keeps an abandoned
/// preview's job alive, and obsolete work stops at the next candidate
/// boundary.
actor ImageConversionEngine {
    private let store: CandidateArtifactStore
    private let inspector = ImageIOSourceInspector(rejectsMultiImage: true)

    private struct JobKey: Hashable {
        var itemID: UUID
        var source: SourceFingerprint
        var configuration: TargetSizeJobConfiguration
    }

    /// Synchronous cancellation state shared with `onCancel`, which runs
    /// outside actor isolation. The lock protects the complete mutable state;
    /// no consumer token is read or written without it.
    private final class ConsumerGate: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: Set<UUID> = []

        func attach() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            let token = UUID()
            tokens.insert(token)
            return token
        }

        /// Returns true when the detached token was the final consumer.
        @discardableResult
        func detach(_ token: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            tokens.remove(token)
            return tokens.isEmpty
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tokens.isEmpty
        }
    }

    private final class JobState {
        let id = UUID()
        let consumers = ConsumerGate()
        var task: Task<PreparedCandidate, Error>?
    }

    private var jobs: [JobKey: JobState] = [:]
    private var completed: [UUID: (key: JobKey, candidate: PreparedCandidate)] = [:]

    init() throws {
        store = try CandidateArtifactStore()
    }

    // MARK: - Preview / preparation

    enum Consumer: Sendable { case preview, run }

    /// Prepare (or reuse) the exact full-resolution candidate for one item.
    /// A completed candidate whose fingerprints match returns with zero
    /// additional encodes.
    func prepareCandidate(
        item: ImageConversionItemSnapshot,
        configuration: TargetSizeJobConfiguration,
        consumer: Consumer
    ) async throws -> PreparedCandidate {
        let preflight = try inspector.preflight(input: item.input, target: configuration.format).get()
        let source = try fingerprint(for: item)
        let key = JobKey(itemID: item.id, source: source, configuration: configuration)

        if let cached = completed[item.id], cached.key == key {
            return cached.candidate
        }
        // A changed source or configuration invalidates the stale candidate.
        invalidateCompleted(itemID: item.id)

        let state: JobState
        if let existing = jobs[key], existing.task != nil {
            state = existing
        } else {
            state = JobState()
            jobs[key] = state
        }

        let token = state.consumers.attach()
        if state.task == nil {
            let stateID = state.id
            let consumers = state.consumers
            state.task = Task {
                // Inherits actor isolation: preview and batch work stay serial.
                defer { self.finishJob(key: key, stateID: stateID) }
                let candidate = try await self.performPipeline(
                    key: key,
                    item: item,
                    preflight: preflight,
                    isAbandoned: { consumers.isEmpty }
                )
                self.completed[item.id] = (key, candidate)
                self.store.setDisplayed(candidate.artifact, forItem: item.id)
                if case .bestEffort = candidate.kind {
                    self.store.setRetainedBestEffort(candidate.artifact, forItem: item.id)
                }
                return candidate
            }
        }

        guard let pipelineTask = state.task else {
            state.consumers.detach(token)
            throw ImageConversionFailure.encodingFailed
        }
        let consumers = state.consumers
        defer { consumers.detach(token) }

        // Cancel the shared task only when this was its final consumer. A run
        // and a preview may safely share one candidate preparation.
        return try await withTaskCancellationHandler {
            try await pipelineTask.value
        } onCancel: {
            if consumers.detach(token) {
                pipelineTask.cancel()
            }
        }
    }

    // MARK: - Run

    /// Convert one frozen item. Serial by actor construction; the caller
    /// loops the basket in order and checks cancellation between items.
    func convertItem(
        _ item: ImageConversionItemSnapshot,
        configuration: TargetSizeJobConfiguration
    ) async -> ImageConversionItemOutcome {
        do {
            try Task.checkCancellation()
            let candidate = try await prepareCandidate(
                item: item, configuration: configuration, consumer: .run
            )

            // Revalidate the source immediately before the irreversible
            // commit; the frozen run prepares no replacement.
            let current = try fingerprint(for: item)
            guard current == completed[item.id]?.key.source else {
                invalidateCompleted(itemID: item.id)
                return .failed(.sourceChanged)
            }

            switch candidate.kind {
            case .targetReached, .passThrough:
                let output = try AtomicOutputWriter().commit(
                    candidate.artifact,
                    to: item.destination,
                    isCancelled: { Task.isCancelled }
                )
                return .success(CommittedConversion(output: output, candidate: candidate))
            case .bestEffort:
                store.setRetainedBestEffort(candidate.artifact, forItem: item.id)
                return .targetMiss(candidate)
            }
        } catch let issue as ImageConversionPreflightIssue {
            return .unsupported(issue)
        } catch let failure as ImageConversionFailure {
            return .failed(failure)
        } catch AtomicOutputWriterError.cancelled {
            return .cancelled
        } catch let writeError as AtomicOutputWriterError {
            return .failed(.writeFailed(String(describing: writeError)))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.encodingFailed)
        }
    }

    /// Explicit Save Anyway: commit the retained Best-Effort artifact for
    /// this item with zero re-encodes. Only after a successful commit does a
    /// Conversion Record become appropriate.
    func saveBestEffort(
        itemID: UUID,
        destination: AtomicOutputWriter.DestinationPolicy
    ) throws -> CommittedOutput {
        guard let artifact = store.retainedBestEffort(forItem: itemID) else {
            throw ImageConversionFailure.sourceChanged
        }
        return try AtomicOutputWriter().commit(artifact, to: destination)
    }

    // MARK: - Lifecycle

    func removeItem(_ id: UUID) {
        invalidateCompleted(itemID: id)
        store.removeItem(id)
    }

    func pruneDisplayed(keepingItem selected: UUID?) {
        store.pruneDisplayed(keepingItem: selected)
    }

    func reset() {
        for (_, state) in jobs { state.task?.cancel() }
        jobs.removeAll()
        completed.removeAll()
        store.reset()
    }

    /// Diagnostics used by lifecycle tests; production behavior never branches
    /// on this value.
    var activeJobCount: Int { jobs.count }

    private func finishJob(key: JobKey, stateID: UUID) {
        guard jobs[key]?.id == stateID else { return }
        jobs[key] = nil
    }

    private func invalidateCompleted(itemID: UUID) {
        guard completed.removeValue(forKey: itemID) != nil else { return }
        store.setDisplayed(nil, forItem: itemID)
    }

    private func fingerprint(for item: ImageConversionItemSnapshot) throws -> SourceFingerprint {
        switch item.input {
        case .file(let url):
            return try SourceFingerprint.forFile(at: url)
        case .bitmap(let data):
            return SourceFingerprint.forBitmap(data, basketItemID: item.id)
        }
    }

    // MARK: - Pipeline

    private func performPipeline(
        key: JobKey,
        item: ImageConversionItemSnapshot,
        preflight: ImageConversionPreflight,
        isAbandoned: @Sendable () -> Bool
    ) async throws -> PreparedCandidate {
        let configuration = key.configuration
        let encoder = try ImageIOCandidateEncoder(input: item.input)
        let sourceDimensions = encoder.originalDimensions
        let backgroundHex = preflight.requiresTransparencyBackground
            ? configuration.transparencyBackgroundHex : nil

        func checkBoundary() throws {
            if isAbandoned() { throw CancellationError() }
            try Task.checkCancellation()
        }

        // 1. Same-format pass-through when the source already fits.
        if let sourceBytes = preflight.sourceByteCount,
           sourceBytes <= configuration.targetBytes,
           encoder.sourceTypeIdentifier == configuration.format.typeIdentifier,
           let rewritten = encoder.losslessPassThrough(as: configuration.format),
           Int64(rewritten.count) <= configuration.targetBytes {
            let report = CandidateAuditor.audit(rewritten)
            if report.decodable,
               report.pixelDimensions == sourceDimensions,
               report.ancillaryMetadataAbsent {
                try checkBoundary()
                let artifact = try store.materialize(rewritten)
                return PreparedCandidate(
                    kind: .passThrough,
                    artifact: artifact,
                    quality: 100,
                    dimensions: sourceDimensions,
                    sourceDimensions: sourceDimensions,
                    sourceByteCount: preflight.sourceByteCount,
                    resizeFallbackApplied: false,
                    hdrToSDR: preflight.hasHDRGainMap && !report.hasHDRGainMap,
                    firstFrameOnly: false
                )
            }
            // Unsupported or ineffective rewrite: fall through to the search.
        }

        // 2. Bounded search. The measure closure mirrors the search's
        // retention so at most one best-qualifier and one smallest artifact
        // exist; the winning request's encoded bytes are reused, never
        // re-encoded.
        guard let floor = TargetSizePolicy.qualityFloor(for: configuration.format) else {
            throw ImageConversionFailure.encodingFailed
        }

        var encodedByRequest: [TargetSizeCandidateRequest: Data] = [:]
        var bestQualifier: (request: TargetSizeCandidateRequest, bytes: Int64)?
        var smallest: (request: TargetSizeCandidateRequest, bytes: Int64)?

        func retain(_ request: TargetSizeCandidateRequest, _ data: Data) {
            let bytes = Int64(data.count)
            if bytes <= configuration.targetBytes {
                let replaces = bestQualifier.map { current in
                    request.dimensions != current.request.dimensions
                        || request.quality > current.request.quality
                } ?? true
                if replaces {
                    if let old = bestQualifier, old.request != smallest?.request {
                        encodedByRequest[old.request] = nil
                    }
                    bestQualifier = (request, bytes)
                    encodedByRequest[request] = data
                }
            }
            let replacesSmallest = smallest.map { bytes < $0.bytes } ?? true
            if replacesSmallest {
                if let old = smallest, old.request != bestQualifier?.request {
                    encodedByRequest[old.request] = nil
                }
                smallest = (request, bytes)
                encodedByRequest[request] = data
            }
        }

        let search = TargetSizeSearch(
            targetBytes: configuration.targetBytes,
            qualityFloor: floor,
            originalDimensions: sourceDimensions,
            allowResize: configuration.allowResize
        )
        let result = try search.run { request in
            try checkBoundary()
            let data = try encoder.encode(ImageIOCandidateEncoder.EncodeSpec(
                format: configuration.format,
                quality: request.quality,
                dimensions: request.dimensions,
                transparencyBackgroundHex: backgroundHex
            ))
            retain(request, data)
            return Int64(data.count)
        }

        let winner: TargetSizeCandidateRequest
        let kind: PreparedCandidate.Kind
        switch result {
        case .reached(let candidate):
            winner = candidate.request
            kind = .targetReached
        case .bestEffort(let candidate, let reason):
            winner = candidate.request
            kind = .bestEffort(reason)
        }

        // The retention mirror should always hold the winner; a divergence
        // would force one extra encode, which the tests treat as a bug.
        let data: Data
        if let retained = encodedByRequest[winner] {
            data = retained
        } else {
            assertionFailure("search winner was not retained; re-encoding")
            data = try encoder.encode(ImageIOCandidateEncoder.EncodeSpec(
                format: configuration.format,
                quality: winner.quality,
                dimensions: winner.dimensions,
                transparencyBackgroundHex: backgroundHex
            ))
        }

        // 3. Full audit of the selected candidate only.
        let report = CandidateAuditor.audit(data)
        guard report.decodable, report.pixelDimensions == winner.dimensions else {
            throw ImageConversionFailure.encodingFailed
        }
        guard report.ancillaryMetadataAbsent,
              report.orientation == (encoder.orientation ?? 1) else {
            throw ImageConversionFailure.policyAuditFailed
        }
        let expectedAlpha = preflight.hasAlpha && backgroundHex == nil
        if report.hasAlpha != expectedAlpha {
            ImageIOCapabilityCache.invalidate()
            throw ImageConversionFailure.capabilityChanged
        }

        try checkBoundary()
        let artifact = try store.materialize(data)
        return PreparedCandidate(
            kind: kind,
            artifact: artifact,
            quality: winner.quality,
            dimensions: winner.dimensions,
            sourceDimensions: sourceDimensions,
            sourceByteCount: preflight.sourceByteCount,
            resizeFallbackApplied: winner.dimensions != sourceDimensions,
            hdrToSDR: preflight.hasHDRGainMap && !report.hasHDRGainMap,
            firstFrameOnly: false
        )
    }
}
