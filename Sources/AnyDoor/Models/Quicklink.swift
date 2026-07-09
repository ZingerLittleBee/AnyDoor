import Foundation
import SwiftData

/// A user-defined command-palette entry that opens one untyped Link.
///
/// This model intentionally stores only scalar and optional-scalar fields so
/// SwiftData lightweight migration can add it without transformable columns.
@Model
final class Quicklink: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var keyword: String?
    var link: String = ""
    var openWithBundleID: String?
    var keyCode: Int?
    var modifierFlags: Int?
    var isVisible: Bool = true
    var displayOrder: Double = 0
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        keyword: String? = nil,
        link: String,
        openWithBundleID: String? = nil,
        keyCode: Int? = nil,
        modifierFlags: Int? = nil,
        isVisible: Bool = true,
        displayOrder: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.link = link
        self.openWithBundleID = openWithBundleID
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isVisible = isVisible
        self.displayOrder = displayOrder
        self.createdAt = createdAt
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? link : trimmedName
    }

    var hotkeyDescriptor: HotkeyDescriptor? {
        get {
            guard let keyCode, let modifierFlags else { return nil }
            return HotkeyDescriptor(keyCode: keyCode, modifierFlags: modifierFlags)
        }
        set {
            keyCode = newValue?.keyCode
            modifierFlags = newValue?.modifierFlags
        }
    }
}

enum QuicklinkOpenWith {
    static func normalizedBundleID(_ bundleID: String?) -> String? {
        let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
