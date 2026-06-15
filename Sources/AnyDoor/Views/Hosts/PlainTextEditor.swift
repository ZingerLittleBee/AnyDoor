import SwiftUI
import AppKit

/// An `NSTextView`-backed plain-text editor whose layout is identical whether or
/// not it is editable, so toggling edit mode never shifts the text (a plain
/// SwiftUI `Text` and `TextEditor` use different insets and visibly jump).
/// Monospaced, selectable, and scrollable; read-only when `isEditable` is false.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.isEditable = isEditable
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        init(text: Binding<String>) { self.text = text }

        // AppKit invokes delegate callbacks on the main thread; hop into the
        // MainActor context and read from the retained text view (not the
        // non-Sendable notification) to write back the SwiftUI binding.
        nonisolated func textDidChange(_ notification: Notification) {
            MainThreadIsolation.run {
                guard let textView else { return }
                text.wrappedValue = textView.string
            }
        }
    }
}
