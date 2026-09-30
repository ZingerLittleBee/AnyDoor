import AppKit

/// Opt-in, bounded local diagnostics. This records routing and the app's cursor
/// stack only; NSCursor.current is not evidence of the pointer shown on screen.
@MainActor
final class PinnedImageCursorDiagnostics {
    static let shared = PinnedImageCursorDiagnostics(
        enabled: ProcessInfo.processInfo.environment["ANYDOOR_PIN_CURSOR_DEBUG"] == "1"
    ) { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    let isEnabled: Bool
    private let limit: Int
    private let write: (String) -> Void
    private var lastSignatures: [String: String] = [:]
    private var emittedCount = 0
    private var announced = false
    private var reportedLimit = false

    init(enabled: Bool, limit: Int = 300, write: @escaping (String) -> Void) {
        isEnabled = enabled
        self.limit = limit
        self.write = write
    }

    func record(key: String, signature: String, details: @autoclosure () -> String) {
        guard isEnabled else { return }
        if !announced {
            announced = true
            write("[PinnedCursor v1] enabled pid=\(ProcessInfo.processInfo.processIdentifier) os=\(ProcessInfo.processInfo.operatingSystemVersionString) bundle=\(Bundle.main.bundleIdentifier ?? "none") packaged=\(Bundle.main.bundleURL.pathExtension == "app"); app cursor stack is NOT the displayed cursor; limit=\(limit)")
        }
        guard lastSignatures[key] != signature else { return }
        guard emittedCount < limit else {
            if !reportedLimit {
                reportedLimit = true
                write("[PinnedCursor v1] diagnostic limit reached; restart to capture another sweep")
            }
            return
        }
        lastSignatures[key] = signature
        emittedCount += 1
        write("[PinnedCursor v1] seq=\(emittedCount) \(details())")
    }

    func context(source: String, decision: String, view: NSView,
                 point: CGPoint? = nil, frontmost: Int? = nil, style: PinnedImagePointerStyle? = nil,
                 eventWindow: Int? = nil) {
        guard isEnabled else { return }
        let window = view.window
        let own = window?.windowNumber ?? -1
        let local = point.flatMap { point in window.map { view.convert($0.convertPoint(fromScreen: point), from: nil) } }
        let children = window?.childWindows?.map { String($0.windowNumber) }.joined(separator: ",") ?? ""
        let selected = style.map { String(describing: $0) } ?? "none"
        let front = frontmost.map(String.init) ?? "unavailable"
        let event = eventWindow.map(String.init) ?? "unavailable"
        let frontWindow = frontmost.flatMap { number in NSApp.windows.first { $0.windowNumber == number } }
        let frontKind = frontWindow.map { String(describing: type(of: $0)) } ?? "external-or-unlisted"
        let frontIgnored = frontWindow.map { String($0.ignoresMouseEvents) } ?? "unavailable"
        let status = "decision=\(decision) active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false) visible=\(window?.isVisible ?? false) ignored=\(window?.ignoresMouseEvents ?? false) hidden=\(view.isHiddenOrHasHiddenAncestor) own=\(own) front=\(front) frontKind=\(frontKind) frontIgnored=\(frontIgnored) eventWindow=\(event) children=[\(children)] style=\(selected)"
        record(key: "\(own):\(source)", signature: status,
               details: "source=\(source) \(status) screen=\(String(describing: point)) local=\(String(describing: local)) bounds=\(view.bounds)")
    }

    func set(_ cursor: NSCursor, style: PinnedImagePointerStyle) {
        let beforeMatches = isEnabled && NSCursor.current === cursor
        cursor.set()
        guard isEnabled else { return }
        let status = "style=\(style) active=\(NSApp.isActive) requestedIsArrow=\(cursor === NSCursor.arrow) appCurrentMatchedBefore=\(beforeMatches) appCurrentMatchesAfter=\(NSCursor.current === cursor)"
        record(key: "NSCursor.set", signature: status,
               details: "source=NSCursor.set \(status) requestedClass=\(type(of: cursor)) imageSize=\(cursor.image.size) hotSpot=\(cursor.hotSpot)")
    }
}
