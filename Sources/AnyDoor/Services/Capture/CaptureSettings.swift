import Foundation
import CoreGraphics

/// UserDefaults-backed capture configuration. Mirrors the HyperKeyService pattern
/// (explicit setters that write through). `@MainActor @Observable` so SwiftUI
/// settings views can bind to it later.
@MainActor
@Observable
final class CaptureSettings {
    static let shared = CaptureSettings()

    static let saveDirectoryKey = "capture.saveDirectory"
    static let namingTemplateKey = "capture.namingTemplate"
    static let autoCopyKey = "capture.autoCopy"
    static let autoSaveKey = "capture.autoSave"
    static let delaySecondsKey = "capture.delaySeconds"
    static let overlayTimeoutKey = "capture.overlayTimeout"
    static let lastRegionRectKey = "capture.lastRegionRect"

    static let defaultNamingTemplate = "Screenshot YYYY-MM-DD at HH.mm.ss"

    private let defaults: UserDefaults

    private(set) var saveDirectory: URL
    private(set) var namingTemplate: String
    private(set) var autoCopy: Bool
    private(set) var autoSave: Bool
    private(set) var delaySeconds: Int
    private(set) var overlayTimeout: Int
    private(set) var lastRegionRect: CGRect?

    private static func readRect(_ defaults: UserDefaults, _ key: String) -> CGRect? {
        guard let a = defaults.array(forKey: key) as? [Double], a.count == 4,
              a.allSatisfy({ $0.isFinite }) else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent("Pictures/AnyDoor", isDirectory: true)
        if let path = defaults.string(forKey: Self.saveDirectoryKey), !path.isEmpty {
            self.saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.saveDirectory = defaultDir
        }
        self.namingTemplate = defaults.string(forKey: Self.namingTemplateKey) ?? Self.defaultNamingTemplate
        self.autoCopy = defaults.object(forKey: Self.autoCopyKey) as? Bool ?? true
        self.autoSave = defaults.object(forKey: Self.autoSaveKey) as? Bool ?? true
        self.delaySeconds = defaults.object(forKey: Self.delaySecondsKey) as? Int ?? 5
        self.overlayTimeout = defaults.object(forKey: Self.overlayTimeoutKey) as? Int ?? 8
        self.lastRegionRect = Self.readRect(defaults, Self.lastRegionRectKey)
    }

    func setSaveDirectory(_ url: URL) {
        saveDirectory = url
        defaults.set(url.path, forKey: Self.saveDirectoryKey)
    }

    func setNamingTemplate(_ value: String) {
        namingTemplate = value
        defaults.set(value, forKey: Self.namingTemplateKey)
    }

    func setAutoCopy(_ value: Bool) {
        autoCopy = value
        defaults.set(value, forKey: Self.autoCopyKey)
    }

    func setAutoSave(_ value: Bool) {
        autoSave = value
        defaults.set(value, forKey: Self.autoSaveKey)
    }

    func setDelaySeconds(_ value: Int) {
        delaySeconds = value
        defaults.set(value, forKey: Self.delaySecondsKey)
    }

    func setOverlayTimeout(_ value: Int) {
        overlayTimeout = value
        defaults.set(value, forKey: Self.overlayTimeoutKey)
    }

    func setLastRegionRect(_ rect: CGRect) {
        lastRegionRect = rect
        defaults.set([Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                     forKey: Self.lastRegionRectKey)
    }

    /// Re-read after a config import (parallels HyperKeyService.reloadFromDefaults).
    func reloadFromDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent("Pictures/AnyDoor", isDirectory: true)
        if let path = defaults.string(forKey: Self.saveDirectoryKey), !path.isEmpty {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = defaultDir
        }
        namingTemplate = defaults.string(forKey: Self.namingTemplateKey) ?? Self.defaultNamingTemplate
        autoCopy = defaults.object(forKey: Self.autoCopyKey) as? Bool ?? true
        autoSave = defaults.object(forKey: Self.autoSaveKey) as? Bool ?? true
        delaySeconds = defaults.object(forKey: Self.delaySecondsKey) as? Int ?? 5
        overlayTimeout = defaults.object(forKey: Self.overlayTimeoutKey) as? Int ?? 8
        lastRegionRect = Self.readRect(defaults, Self.lastRegionRectKey)
    }
}
