import AppKit
import Foundation

struct CommandPaletteWindowPlacement {
    static let defaultsKey = "commandPalette.windowPosition"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(origin: NSPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        defaults.set([Double(origin.x), Double(origin.y)], forKey: Self.defaultsKey)
    }

    func savedOrigin() -> NSPoint? {
        guard let values = defaults.array(forKey: Self.defaultsKey) as? [Double],
              values.count == 2,
              values.allSatisfy({ $0.isFinite })
        else { return nil }

        return NSPoint(x: values[0], y: values[1])
    }

    func restoredFrame(windowSize: NSSize, visibleFrames: [NSRect]) -> NSRect? {
        guard let origin = savedOrigin() else { return nil }
        let frame = NSRect(origin: origin, size: windowSize)
        return visibleFrames.contains(where: { $0.intersects(frame) }) ? frame : nil
    }

    static func defaultFrame(windowSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let origin = NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.maxY - windowSize.height - visibleFrame.height * 0.22
        )
        return NSRect(origin: origin, size: windowSize)
    }
}
