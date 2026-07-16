import AppKit
import Carbon.HIToolbox

/// Shared key-monitor policy for manually managed windows (Settings, plugin
/// workspace windows): whether a key event should be left to the focused
/// control instead of triggering a window-level shortcut — a text field
/// cancelling its edit on Esc, an editor consuming ⌘V.
public enum FocusedControlKeyPolicy {
    public static func shouldDefer(
        keyCode: Int,
        firstResponder: NSResponder?
    ) -> Bool {
        guard keyCode == kVK_Escape || keyCode == kVK_ANSI_V else { return false }
        return firstResponder is NSTextView
            || firstResponder is NSControl
            || firstResponder is NSCollectionView
    }
}
