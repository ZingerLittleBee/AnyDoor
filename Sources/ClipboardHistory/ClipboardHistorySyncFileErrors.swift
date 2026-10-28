import Darwin
import Foundation

enum ClipboardSyncFileErrors {
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
