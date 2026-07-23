/// Permission state for a built-in item that requires external authorization.
public enum PermissionStatus: Sendable, Hashable {
    case granted
    case denied
    case undetermined
    case notRequired
}
