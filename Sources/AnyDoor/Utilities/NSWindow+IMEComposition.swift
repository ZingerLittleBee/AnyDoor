import AppKit

extension NSWindow {
    /// Whether the focused text editor has an in-flight input-method
    /// composition (marked text — e.g. uncommitted Chinese pinyin). While
    /// composing, Return / arrows / Esc belong to the IME (commit the
    /// composition, navigate candidates, cancel), so local key monitors must
    /// let those events reach the field editor instead of acting on them.
    var hasIMEComposition: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}
