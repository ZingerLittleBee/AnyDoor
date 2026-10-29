import Darwin
import Foundation

enum ClipboardSyncFileErrors {
    /// Native errors from one file operation do not establish a database or
    /// authority failure, even when the destination volume is unavailable.
    static func isLocalOperationFailure(_ error: Error) -> Bool {
        let codes = [EEXIST, EROFS, ENAMETOOLONG, ENOSPC, EDQUOT]
        if case .fileOperationFailed(let code) = error as? ClipboardHistoryStorageError {
            return codes.contains(code)
        }
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                return codes.contains { Int($0) == current.code }
            }
            guard current.domain == NSCocoaErrorDomain else { return false }
            if [NSFileWriteFileExistsError, NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError].contains(current.code) {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }

    static func isSourceChanged(_ error: Error) -> Bool {
        if case .fileOperationFailed(let code) = error as? ClipboardHistoryStorageError { return code == ESTALE }
        return false
    }

    static func isAccessDenied(_ error: Error) -> Bool {
        if case .fileOperationFailed(let code) = error as? ClipboardHistoryStorageError {
            return code == EACCES || code == EPERM
        }
        var current = error as NSError
        // Foundation can wrap the POSIX cause. Bound malformed error chains.
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                return current.code == Int(EACCES) || current.code == Int(EPERM)
            }
            guard current.domain == NSCocoaErrorDomain else { return false }
            if current.code == NSFileReadNoPermissionError || current.code == NSFileWriteNoPermissionError {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}
