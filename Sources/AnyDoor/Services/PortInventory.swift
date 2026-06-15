import Foundation
import Darwin
import os

@MainActor
@Observable
final class PortInventory {
    // MARK: - Public state

    private(set) var records: [PortRecord] = []
    private(set) var isRefreshing: Bool = false
    private(set) var lastError: PortInventoryError? = nil
    private(set) var killingPIDs: Set<pid_t> = []
    private(set) var failedKillPIDs: [pid_t: KillFailure] = [:]

    var searchText: String = ""

    var viewMode: ViewMode {
        didSet {
            defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
        }
    }

    // MARK: - Dependencies

    private let scanner: any PortScanning
    private let defaults: UserDefaults
    private let cacheDuration: TimeInterval
    private let now: () -> Date
    private static let viewModeKey = "PortInventory.viewMode"
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "PortInventory")

    // MARK: - Internal refresh state (Task 10)

    private var refreshGeneration: UInt64 = 0
    private var inflightCount: Int = 0
    private var lastSuccessfulRefreshAt: Date?

    // MARK: - Lifecycle

    // This lazy initializer is first touched from main-actor UI code. Use
    // MainThreadIsolation rather than MainActor.assumeIsolated so that a first
    // access occurring after a ScreenCaptureKit capture (which can leave the main
    // thread's executor tracking dangling) does not fault the
    // swift_task_isCurrentExecutor check. See MainThreadIsolation.
    static let shared: PortInventory = MainThreadIsolation.run { PortInventory() }

    init(
        scanner: any PortScanning = PortScanner(),
        defaults: UserDefaults = .standard,
        cacheDuration: TimeInterval = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.scanner = scanner
        self.defaults = defaults
        self.cacheDuration = cacheDuration
        self.now = now
        let raw = defaults.string(forKey: Self.viewModeKey)
        self.viewMode = raw.flatMap(ViewMode.init(rawValue:)) ?? .list
    }

    // Placeholder methods — real implementations land in Task 10 and Task 11.

    func refresh(force: Bool = false) async {
        if !force, isCacheFresh {
            return
        }

        refreshGeneration &+= 1
        let myGen = refreshGeneration
        inflightCount += 1
        isRefreshing = true

        do {
            let scanned = try await scanner.scanTCPListening()
            inflightCount -= 1
            if myGen == refreshGeneration {
                records = scanned
                lastError = nil
                lastSuccessfulRefreshAt = now()
            } else {
                Self.logger.debug("dropping stale scan result (gen \(myGen), now \(self.refreshGeneration))")
            }
            isRefreshing = inflightCount > 0
        } catch is CancellationError {
            inflightCount -= 1
            isRefreshing = inflightCount > 0
        } catch {
            inflightCount -= 1
            if myGen == refreshGeneration {
                lastError = .scanFailed(String(describing: error))
                // records intentionally preserved
            }
            isRefreshing = inflightCount > 0
        }
    }

    private var isCacheFresh: Bool {
        guard lastError == nil,
              let lastSuccessfulRefreshAt else { return false }
        return now().timeIntervalSince(lastSuccessfulRefreshAt) < cacheDuration
    }

    @discardableResult
    func kill(pid: pid_t) async -> PortKillResult {
        killingPIDs.insert(pid)
        defer { killingPIDs.remove(pid) }

        // Step 1: SIGTERM
        switch scanner.kill(pid: pid, signal: SIGTERM) {
        case .failure(.ESRCH):
            // Process already gone — treat as success.
            await refresh(force: true)
            return .success
        case .failure(let code):
            let reason: KillFailure.Reason =
                (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
            failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
            scheduleAutoDismiss(for: pid)
            return .failure(reason)
        case .success:
            break
        }

        // Step 2: give the process time to handle SIGTERM, then re-scan.
        try? await Task.sleep(for: .milliseconds(500))
        await refresh(force: true)

        // Step 3: if still alive, escalate.
        if records.contains(where: { $0.pid == pid }) {
            switch scanner.kill(pid: pid, signal: SIGKILL) {
            case .success:
                try? await Task.sleep(for: .milliseconds(200))
                await refresh(force: true)
                return .success
            case .failure(.ESRCH):
                await refresh(force: true)
                return .success
            case .failure(let code):
                let reason: KillFailure.Reason =
                    (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
                failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
                scheduleAutoDismiss(for: pid)
                return .failure(reason)
            }
        }

        return .success
    }

    private func scheduleAutoDismiss(for pid: pid_t) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                _ = self?.failedKillPIDs.removeValue(forKey: pid)
            }
        }
    }

    func dismissError(for pid: pid_t) {
        failedKillPIDs.removeValue(forKey: pid)
    }

    // MARK: - Derived views

    var filteredRecords: [PortRecord] {
        guard !searchText.isEmpty else {
            return records.sorted { $0.port < $1.port }
        }
        let q = searchText.lowercased()
        var seen = Set<PortRecord.ID>()
        var ordered: [PortRecord] = []
        func add(_ bucket: [PortRecord]) {
            for r in bucket where !seen.contains(r.id) {
                seen.insert(r.id)
                ordered.append(r)
            }
        }
        add(records.filter { String($0.port).contains(q) })
        add(records.filter { $0.processName.lowercased().contains(q) })
        add(records.filter { String($0.pid).contains(q) })
        return ordered
    }

    var groupedByProcess: [ProcessGroup] {
        let grouped = Dictionary(grouping: filteredRecords, by: \.pid)
        return grouped.map { (pid, recs) in
            ProcessGroup(
                pid: pid,
                processName: recs.first?.processName ?? "",
                ports: recs.sorted { $0.port < $1.port }
            )
        }
        .sorted {
            $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
        }
    }
}

enum ViewMode: String, Sendable, Equatable {
    case list, tree
}

enum PortInventoryError: Equatable, Sendable {
    case scanFailed(String)
}

struct KillFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case permissionDenied
        case processGone
        case other(Int32)
    }
    let reason: Reason
    let timestamp: Date
}

enum PortKillResult: Equatable, Sendable {
    case success
    case failure(KillFailure.Reason)
}
