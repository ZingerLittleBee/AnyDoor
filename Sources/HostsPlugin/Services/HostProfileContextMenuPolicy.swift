enum HostProfileContextAction: Hashable, Sendable {
    case enable
    case disable
    case rename
    case duplicate
    case delete

    var isDestructive: Bool {
        switch self {
        case .disable, .delete: true
        case .enable, .rename, .duplicate: false
        }
    }

    var togglesActivation: Bool {
        self == .enable || self == .disable
    }
}

enum HostProfileContextMenuPolicy {
    static func actions(isActive: Bool) -> [HostProfileContextAction] {
        [isActive ? .disable : .enable, .rename, .duplicate, .delete]
    }
}
