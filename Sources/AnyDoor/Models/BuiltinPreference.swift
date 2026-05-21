import SwiftData

@Model
final class BuiltinPreference {
    /// Stable key: `BuiltinItem.rawValue`. Orphans (no matching BuiltinItem) are skipped at read time.
    @Attribute(.unique) var itemKey: String = ""
    var isVisible: Bool = true
    var displayOrder: Double = 0
    var keyCode: Int?
    var modifierFlags: Int?

    init(
        itemKey: String,
        isVisible: Bool = true,
        displayOrder: Double = 0,
        keyCode: Int? = nil,
        modifierFlags: Int? = nil
    ) {
        self.itemKey = itemKey
        self.isVisible = isVisible
        self.displayOrder = displayOrder
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}
