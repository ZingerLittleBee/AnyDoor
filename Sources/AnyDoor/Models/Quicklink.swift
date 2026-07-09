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
}
