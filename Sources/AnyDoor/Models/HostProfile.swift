import Foundation
import SwiftData

/// A user-defined hosts profile. Active profiles are merged into the AnyDoor
/// managed block in `/etc/hosts`. System hosts content is never stored here.
@Model
final class HostProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: String
    var isActive: Bool = false
    var displayOrder: Double = 0
    var createdAt: Date
    var updatedAt: Date

    init(name: String, content: String = "", isActive: Bool = false, displayOrder: Double = 0) {
        self.id = UUID()
        self.name = name
        self.content = content
        self.isActive = isActive
        self.displayOrder = displayOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
