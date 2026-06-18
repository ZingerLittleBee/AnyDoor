import Foundation

/// Pure parsing + merging of the two public macOS battery sources:
///
/// 1. `system_profiler SPBluetoothDataType -json` — rich, gives the L/R/case
///    triple for earbuds and a `device_minorType` for every connected device,
///    but silently omits a battery field for some accessories (notably Logitech
///    HID++ mice like the MX Master series).
/// 2. `pmset -g accps` — a flat `name → percent` list that *does* cover those
///    HID++ devices, but only a single percentage and no device type.
///
/// We treat system_profiler as the canonical device set (for names + types +
/// earbud granularity) and fold pmset in as the fallback level for anything
/// system_profiler left blank. Everything here is deterministic and side-effect
/// free so it can run off the MainActor and be unit-tested with fixture strings.
enum BluetoothBatteryParser {
    /// A connected device as seen by system_profiler, before pmset is folded in.
    struct SystemProfilerDevice: Equatable, Sendable {
        var name: String
        var address: String?
        var minorType: String?
        var main: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?

        var hasAnyBattery: Bool {
            main != nil || left != nil || right != nil || caseLevel != nil
        }
    }

    // MARK: - Public entry point

    /// Merge both sources into the final, display-ready device list. Only devices
    /// that report at least one battery reading (from either source) are kept.
    static func merge(systemProfilerJSON: Data?, pmsetOutput: String?) -> [BluetoothBatteryDevice] {
        let spDevices = systemProfilerJSON.map(parseSystemProfiler) ?? []
        let accessories = pmsetOutput.map(parsePmsetAccessories) ?? []

        // Index pmset percentages by normalized name; consume as we match.
        var remaining: [String: Int] = [:]
        for acc in accessories {
            remaining[normalize(acc.name)] = acc.percent
        }

        var result: [BluetoothBatteryDevice] = []
        for device in spDevices {
            var main = device.main
            // Fold in pmset only when system_profiler gave us nothing for this
            // device (richer L/R/case data, when present, always wins).
            if !device.hasAnyBattery, let percent = remaining[normalize(device.name)] {
                main = percent
            }
            // Whether or not we used it, this device's pmset entry is now spoken
            // for so it isn't re-added as a standalone row below.
            remaining[normalize(device.name)] = nil

            let merged = BluetoothBatteryDevice(
                id: device.address.map(normalize) ?? normalize(device.name),
                name: device.name,
                minorType: device.minorType,
                main: main,
                left: device.left,
                right: device.right,
                caseLevel: device.caseLevel
            )
            if !merged.levels.isEmpty {
                result.append(merged)
            }
        }

        // pmset rows with no matching system_profiler device — keep them as
        // name-only entries so we never drop a device macOS clearly knows about.
        for acc in accessories where remaining[normalize(acc.name)] != nil {
            remaining[normalize(acc.name)] = nil
            result.append(
                BluetoothBatteryDevice(
                    id: normalize(acc.name),
                    name: acc.name,
                    minorType: nil,
                    main: acc.percent,
                    left: nil,
                    right: nil,
                    caseLevel: nil
                )
            )
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - system_profiler

    /// Parse the `device_connected` array out of `SPBluetoothDataType -json`.
    static func parseSystemProfiler(_ data: Data) -> [SystemProfilerDevice] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let top = (root as? [String: Any])?["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var devices: [SystemProfilerDevice] = []
        for section in top {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            // Each entry is a single-key dict: { "<device name>": { <props> } }.
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    devices.append(
                        SystemProfilerDevice(
                            name: name,
                            address: props["device_address"] as? String,
                            minorType: props["device_minorType"] as? String,
                            main: percent(props["device_batteryLevelMain"]),
                            left: percent(props["device_batteryLevelLeft"]),
                            right: percent(props["device_batteryLevelRight"]),
                            caseLevel: percent(props["device_batteryLevelCase"])
                        )
                    )
                }
            }
        }
        return devices
    }

    // MARK: - pmset

    struct Accessory: Equatable, Sendable {
        var name: String
        var percent: Int
    }

    /// Parse `pmset -g accps` lines such as `-MX Master 3S (id=38802333)\t55%;`.
    /// The internal battery row is skipped; only Bluetooth accessories remain.
    static func parsePmsetAccessories(_ output: String) -> [Accessory] {
        var accessories: [Accessory] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            // Name lives between the leading "-" and the " (id=" marker.
            let afterDash = line.dropFirst()
            guard let idRange = afterDash.range(of: " (id=") else { continue }
            let name = String(afterDash[..<idRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("InternalBattery") else { continue }
            guard let percent = firstPercent(in: afterDash[idRange.upperBound...]) else { continue }
            accessories.append(Accessory(name: name, percent: percent))
        }
        return accessories
    }

    // MARK: - Helpers

    /// Extract an integer percentage from a `"100%"`-style value of any JSON type.
    private static func percent(_ value: Any?) -> Int? {
        if let s = value as? String {
            let digits = s.filter(\.isNumber)
            return Int(digits)
        }
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// Find the first `NN%` token in a substring and return NN.
    private static func firstPercent(in text: Substring) -> Int? {
        guard let pctIndex = text.firstIndex(of: "%") else { return nil }
        var digits = ""
        var i = pctIndex
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i].isNumber {
                digits.insert(text[i], at: digits.startIndex)
            } else {
                break
            }
        }
        return Int(digits)
    }

    /// Canonical form for matching the same device across the two sources:
    /// lowercased, trimmed, with address separators normalized to ':'.
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: ":")
    }
}
