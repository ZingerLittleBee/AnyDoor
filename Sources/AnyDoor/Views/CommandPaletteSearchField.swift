import AppKit
import SwiftUI

/// Reserves the search field's SwiftUI layout slot. The real NSTextField is an
/// AppKit sibling of the NSHostingView and is positioned over this anchor, so
/// SwiftUI never owns its field editor or cursor rects.
struct CommandPaletteSearchAnchor: NSViewRepresentable {
    let text: String
    let placeholder: String
    let registerAnchor: (CommandPaletteSearchAnchorView, String, String) -> Void

    func makeNSView(context: Context) -> CommandPaletteSearchAnchorView {
        let anchor = CommandPaletteSearchAnchorView()
        update(anchor)
        return anchor
    }

    func updateNSView(_ anchor: CommandPaletteSearchAnchorView, context: Context) {
        update(anchor)
    }

    static func dismantleNSView(_ anchor: CommandPaletteSearchAnchorView, coordinator: Void) {
        anchor.onLayout = nil
    }

    private func update(_ anchor: CommandPaletteSearchAnchorView) {
        let text = text
        let placeholder = placeholder
        let registerAnchor = registerAnchor
        anchor.onLayout = { anchor in
            registerAnchor(anchor, text, placeholder)
        }
        registerAnchor(anchor, text, placeholder)
    }
}

final class CommandPaletteSearchAnchorView: NSView {
    var onLayout: ((CommandPaletteSearchAnchorView) -> Void)?

    override func layout() {
        super.layout()
        onLayout?(self)
    }
}

@MainActor
enum CommandPaletteSearchField {
    static func make(coordinator: Coordinator) -> NSTextField {
        let field = NSTextField()
        configure(field)
        field.delegate = coordinator
        return field
    }

    static func configure(_ field: NSTextField) {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void = { _ in }) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}
