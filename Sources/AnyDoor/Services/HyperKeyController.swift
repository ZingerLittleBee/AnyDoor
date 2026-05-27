import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hyperKey.controller")

/// Owns hidutil UserKeyMapping mutations and the persisted OwnedSignatures
/// set. All hidutil reads/writes go through this actor.
actor HyperKeyController {
    static let shared = HyperKeyController()

    private let hidutilPath = "/usr/bin/hidutil"
    private let runner: CommandRunner
    private let defaultsKey = "hyperKey.ownedSignatures"

    init(runner: CommandRunner = DefaultCommandRunner()) {
        self.runner = runner
    }

    /// Synchronous probe used by `applicationShouldTerminate` to decide
    /// whether to delay termination.
    nonisolated var hasPersistedSignatures: Bool {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let set = try? JSONDecoder().decode(OwnedSignatures.self, from: data)
        else { return false }
        return !set.isEmpty
    }

    private func loadOwned() -> OwnedSignatures {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let set = try? JSONDecoder().decode(OwnedSignatures.self, from: data)
        else { return [] }
        return set
    }

    private func persistOwned(_ owned: OwnedSignatures) {
        guard let data = try? JSONEncoder().encode(owned) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Read-modify-write: remove all `removeAll` entries, optionally add `add`.
    /// Throws on `--get` or `--set` failure; never silently writes on a failed GET.
    /// The `didReachSet` flag is set to `true` immediately before the SET call so
    /// callers can detect whether hidutil was mutated (SET was attempted) even
    /// when the method throws.
    private func readModifyWrite(removeAll: OwnedSignatures, add: MappingSignature?, didReachSet: inout Bool) async throws {
        let getRes = try await runner.run(hidutilPath, args: ["property", "--get", "UserKeyMapping"], timeout: 2.0)
        guard getRes.isSuccess else {
            throw HyperKeyError.hidutilFailed(stderr: getRes.stderr)
        }

        var current = parseUserKeyMapping(getRes.stdout)
        current.removeAll { entry in removeAll.contains(MappingSignature(src: entry.src, dst: entry.dst)) }
        if let add { current.append(.init(src: add.src, dst: add.dst)) }

        let setArg = encodeUserKeyMapping(current)
        didReachSet = true // GET succeeded; SET is about to be invoked
        let setRes = try await runner.run(hidutilPath, args: ["property", "--set", setArg], timeout: 2.0)
        guard setRes.isSuccess else {
            throw HyperKeyError.hidutilFailed(stderr: setRes.stderr)
        }
    }

    /// Convenience overload for call sites that don't need to inspect the phase.
    private func readModifyWrite(removeAll: OwnedSignatures, add: MappingSignature?) async throws {
        var dummy = false
        try await readModifyWrite(removeAll: removeAll, add: add, didReachSet: &dummy)
    }

    struct ParsedEntry: Sendable { let src: UInt64; let dst: UInt64 }

    /// Parse `hidutil property --get` stdout. Accepts JSON, plist `(null)`, empty.
    private func parseUserKeyMapping(_ stdout: String) -> [ParsedEntry] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" { return [] }
        if let data = trimmed.data(using: .utf8),
           let arr = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] {
            return arr.compactMap { dict in
                guard let s = dict["HIDKeyboardModifierMappingSrc"] as? NSNumber,
                      let d = dict["HIDKeyboardModifierMappingDst"] as? NSNumber else { return nil }
                return ParsedEntry(src: s.uint64Value, dst: d.uint64Value)
            }
        }
        return []
    }

    private func encodeUserKeyMapping(_ entries: [ParsedEntry]) -> String {
        let arr = entries.map { e -> [String: Any] in
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: e.src),
             "HIDKeyboardModifierMappingDst": NSNumber(value: e.dst)]
        }
        let dict: [String: Any] = ["UserKeyMapping": arr]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }

    @discardableResult
    func apply(trigger: HyperKeyTrigger, virtualKey: HyperKeyVirtualKey) async throws -> MappingSignature {
        guard let src = trigger.hidUsage else { throw HyperKeyError.hidutilFailed(stderr: "trigger has no hidUsage") }
        let newSig = MappingSignature(src: src, dst: virtualKey.hidUsage)
        let oldOwned = loadOwned()

        persistOwned(oldOwned.union([newSig]))

        var setReached = false
        do {
            try await readModifyWrite(removeAll: oldOwned, add: newSig, didReachSet: &setReached)
        } catch {
            // Only attempt revert when the SET phase was reached (GET succeeded).
            // If the GET itself failed, hidutil is unchanged — no revert needed.
            if setReached {
                if (try? await readModifyWrite(removeAll: [newSig], add: nil)) != nil {
                    persistOwned(oldOwned)
                }
            }
            throw error
        }

        persistOwned([newSig])
        return newSig
    }

    func clear() async throws {
        let owned = loadOwned()
        guard !owned.isEmpty else { return }
        try await readModifyWrite(removeAll: owned, add: nil)
        persistOwned([])
    }

    func reconcile() async throws {
        try await clear()
    }
}
