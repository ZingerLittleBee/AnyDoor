import AppKit
import SwiftUI

/// A real, focusable search field for the clipboard wall, backed by an
/// `NSTextField` so an input method editor can compose CJK text — the previous
/// type-to-search key monitor only saw raw key codes and could never start an
/// IME composition. Focus is driven by `state.isSearchFocused`: the window
/// controller decides which mode the wall is in and this view follows, grabbing
/// or releasing first responder to match.
struct WallSearchField: NSViewRepresentable {
    @Bindable var state: ClipboardWallState
    /// Hands the underlying field back to the controller. Type-to-focus must
    /// make the field first responder *synchronously* inside the key monitor so
    /// the triggering keystroke is delivered to it (IME included); that needs a
    /// direct reference the controller can act on.
    let registerField: (NSTextField?) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L(.clipboardSearchPlaceholder)
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        registerField(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != state.query { field.stringValue = state.query }
        // Follow the controller's focus mode. Placing the caret at the end on
        // focus (rather than NSTextField's default select-all) keeps the query
        // intact when the next keystroke arrives.
        let editing = field.currentEditor() != nil
        if state.isSearchFocused, !editing {
            field.window?.makeFirstResponder(field)
            context.coordinator.moveCaretToEnd(field)
        } else if !state.isSearchFocused, editing {
            field.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        // The field is going away with the rebuilt host; drop the controller's
        // dangling reference so it never makes a stale view first responder.
        coordinator.registerField(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state, registerField: registerField) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let state: ClipboardWallState
        let registerField: (NSTextField?) -> Void

        init(state: ClipboardWallState, registerField: @escaping (NSTextField?) -> Void) {
            self.state = state
            self.registerField = registerField
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            state.query = field.stringValue
        }

        func moveCaretToEnd(_ field: NSTextField) {
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }

        // Intercept the rightward caret move: once the caret sits at the end of a
        // non-empty query, a further → hands control to card navigation (focus
        // leaves the field). An empty query keeps focus so the field stays usable.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.moveRight(_:)) else { return false }
            let length = (textView.string as NSString).length
            let selection = textView.selectedRange()
            let caretAtEnd = selection.length == 0 && selection.location >= length
            guard caretAtEnd, !state.query.isEmpty else { return false }
            state.isSearchFocused = false
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
