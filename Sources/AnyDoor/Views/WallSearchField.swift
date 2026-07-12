import AppKit
import SwiftUI

/// A real, focusable search field for the clipboard wall, backed by an
/// `NSTextField` so an input method editor can compose CJK text — the previous
/// type-to-search key monitor only saw raw key codes and could never start an
/// IME composition.
///
/// Focus model: AppKit's first-responder status is the ground truth and
/// `state.isSearchFocused` mirrors it. The field reports every real focus
/// transition (a mouse click into the field, the editor resigning) through
/// `FocusReportingTextField`, and `updateNSView` applies commanded state the
/// other way only when the two disagree. Keeping a one-way commanded flag here
/// used to let a mouse click desync the mode — the caret sat in the field while
/// the controller still routed ⌫/space/arrows to card navigation, and the next
/// unrelated view update would then yank focus back out of the field.
struct WallSearchField: NSViewRepresentable {
    @Bindable var state: ClipboardWallState
    /// Hands the underlying field back to the controller. The ⌘F shortcut must
    /// make the field first responder *synchronously* inside the key monitor so
    /// the very next keystroke can start an IME composition in it; that needs a
    /// direct reference the controller can act on.
    let registerField: (NSTextField?) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
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
        let coordinator = context.coordinator
        field.onFocusChange = { focused in coordinator.focusDidChange(focused) }
        registerField(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != state.query { field.stringValue = state.query }
        // Reconcile commanded focus with reality. Placing the caret at the end
        // on focus (rather than NSTextField's default select-all) keeps the
        // query intact when the next keystroke arrives.
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

        /// Mirror the field's real focus into state so the controller's mode
        /// routing always matches where keys actually land. The equality guard
        /// also keeps the reconciliation in `updateNSView` from writing state
        /// mid-render: by the time it commands a focus change, state already
        /// holds the value this callback would set.
        func focusDidChange(_ focused: Bool) {
            if state.isSearchFocused != focused { state.isSearchFocused = focused }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            state.query = field.stringValue
        }

        func moveCaretToEnd(_ field: NSTextField) {
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }
}

/// An `NSTextField` that reports its real focus lifecycle. `becomeFirstResponder`
/// covers every way focus arrives (the controller's `makeFirstResponder` AND a
/// direct mouse click into the field); the end of editing is reported from
/// `textDidEndEditing` because NSTextField hands first-responder status to the
/// shared field editor immediately, which makes `resignFirstResponder` useless
/// as a "focus left" signal.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
