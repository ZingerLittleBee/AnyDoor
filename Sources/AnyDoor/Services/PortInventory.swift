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
    private static let viewModeKey = "PortInventory.viewMode"
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "PortInventory")

    // MARK: - Internal refresh state (Task 10)

    private var refreshGeneration: UInt64 = 0
    private var inflightCount: Int = 0

    // MARK: - Lifecycle

    static let shared: PortInventory = MainActor.assumeIsolated { PortInventory() }

    init(
        scanner: any PortScanning = PortScanner(),
        defaults: UserDefaults = .standard
    ) {
        self.scanner = scanner
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.viewModeKey)
        self.viewMode = raw.flatMap(ViewMode.init(rawValue:)) ?? .list
    }

    // Placeholder methods — real implementations land in Task 10 and Task 11.

    func refresh() async {
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
            } else {
                Self.logger.debug("dropping stale scan result (gen \(myGen), now \(self.refreshGeneration))")
            }
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

    func kill(pid: pid_t) async {
        killingPIDs.insert(pid)

        // Step 1: SIGTERM
        switch scanner.kill(pid: pid, signal: SIGTERM) {
        case .failure(.ESRCH):
            // Process already gone — treat as success.
            await refresh()
            killingPIDs.remove(pid)
            return
        case .failure(let code):
            let reason: KillFailure.Reason =
                (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
            failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
            scheduleAutoDismiss(for: pid)
            killingPIDs.remove(pid)
            return
        case .success:
            break
        }

        // Step 2: give the process time to handle SIGTERM, then re-scan.
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()

        // Step 3: if still alive, escalate.
        if records.contains(where: { $0.pid == pid }) {
            switch scanner.kill(pid: pid, signal: SIGKILL) {
            case .success:
                try? await Task.sleep(for: .milliseconds(200))
                await refresh()
            case .failure(.ESRCH):
                await refresh()
            case .failure(let code):
                let reason: KillFailure.Reason =
                    (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
                failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
                scheduleAutoDismiss(for: pid)
            }
        }

        killingPIDs.remove(pid)
    }

    private func scheduleAutoDismiss(for pid: pid_t) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                self?.failedKillPIDs.removeValue(forKey: pid)
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
