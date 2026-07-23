import Foundation

/// Stable identity of a Script Plugin.
///
/// Deliberately its own type, never interchangeable with `NativePluginID`
/// (ADR-0008/PRD): a Script Plugin id and a Native Plugin id can never collide
/// or route to each other even if their raw strings match. The raw value is the
/// plugin's manifest `id`; store-era ids will be author-namespaced
/// (`author.plugin`), a shape this type already permits.
public struct ScriptPluginID: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: ScriptPluginID, rhs: ScriptPluginID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
