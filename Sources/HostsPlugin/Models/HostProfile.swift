import Foundation
import SwiftData

/// A user-defined hosts profile. Active profiles are merged into the AnyDoor
/// managed block in `/etc/hosts`. System hosts content is never stored here.
@Model
public final class HostProfile {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var content: String
    public var isActive: Bool = false
    public var displayOrder: Double = 0
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, content: String = "", isActive: Bool = false, displayOrder: Double = 0) {
        self.id = UUID()
        self.name = name
        self.content = content
        self.isActive = isActive
        self.displayOrder = displayOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
