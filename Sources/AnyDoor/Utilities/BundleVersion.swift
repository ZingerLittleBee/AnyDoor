import Foundation

extension Bundle {
    /// The version shown to people, e.g. `"4.3.0"` or `"4.3.0 Beta 5"`.
    var displayVersionString: String? {
        guard let shortVersion = infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return Self.displayVersion(
            shortVersion: shortVersion,
            buildVersion: infoDictionary?["CFBundleVersion"] as? String
        )
    }

    /// Appends the Beta number that the build version encodes. Decodes
    /// `scripts/resolve-release-version.sh`: `CFBundleVersion` is
    /// `X.Y.(Z * 100 + slot)`, where slot 99 is Stable and 1...98 is Beta N.
    /// Any other build version, such as a pre-scheme one, shows `shortVersion`.
    static func displayVersion(shortVersion: String, buildVersion: String?) -> String {
        guard let short = numericComponents(shortVersion),
              let build = buildVersion.flatMap(numericComponents),
              short.count == 3, build.count == 3,
              short[0] == build[0], short[1] == build[1],
              build[2] / 100 == short[2]
        else { return shortVersion }

        let slot = build[2] % 100
        guard (1...98).contains(slot) else { return shortVersion }
        return "\(shortVersion) Beta \(slot)"
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
}
