import Foundation

/// The installed development app owns separate files and credentials. Bare
/// SwiftPM executables retain the pinned production paths for compatibility.
public enum AppIdentity: Sendable {
    case production
    case development

    public static let current = Self(bundleIdentifier: Bundle.main.bundleIdentifier)

    public init(bundleIdentifier: String?) {
        self = bundleIdentifier == "dev.bybee.AnyDoor.Dev" ? .development : .production
    }

    public var bundleIdentifier: String {
        switch self {
        case .production: "dev.bybee.AnyDoor"
        case .development: "dev.bybee.AnyDoor.Dev"
        }
    }

    public var displayName: String {
        switch self {
        case .production: "AnyDoor"
        case .development: "AnyDoor Dev"
        }
    }
}
