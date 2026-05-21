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
        // Implemented in Task 10.
    }

    func kill(pid: pid_t) async {
        // Implemented in Task 11.
    }

    func dismissError(for pid: pid_t) {
        failedKillPIDs.removeValue(forKey: pid)
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
