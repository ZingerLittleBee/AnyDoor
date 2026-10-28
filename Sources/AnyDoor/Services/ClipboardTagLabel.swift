import ClipboardHistory

enum ClipboardTagLabel {
    static func title(id: String, name: String, among definitions: [ClipboardHistoryTagDefinition]) -> String {
        let collisions = definitions.filter { $0.displayName == name && $0.id != id }
        guard !collisions.isEmpty else { return name }
        var length = min(8, id.count)
        while length < id.count, collisions.contains(where: { $0.id.prefix(length) == id.prefix(length) }) {
            length += 1
        }
        return "\(name) (\(id.prefix(length)))"
    }
}

extension ClipboardHistoryPresentationModel {
    func tagTitle(_ id: String) -> String {
        guard let definition = tags.first(where: { $0.id == id }) else { return "" }
        return ClipboardTagLabel.title(id: id, name: definition.displayName, among: tags)
    }
}
