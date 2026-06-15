import SwiftUI
import AppKit

/// The annotation editor UI: a tool palette, the AppKit drawing canvas, a style
/// inspector, and a toolbar with undo/redo and export actions.
struct AnnotationEditorView: View {
    @Bindable var model: AnnotationEditorModel
    let onClose: () -> Void

    private static let toolOrder: [AnnotationTool] = [
        .select, .arrow, .line, .rectangle, .ellipse, .text,
        .freehand, .highlighter, .counter, .blur, .pixelate, .redaction, .crop,
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                toolPalette
                Divider()
                AnnotationCanvasView(model: model)
                    .frame(minWidth: 320, minHeight: 240)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
            Divider()
            inspector
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help(L(.captureEditorUndo))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help(L(.captureEditorRedo))
            Spacer()
            Button { export(.copy) } label: { Label(L(.captureOverlayCopy), systemImage: "doc.on.doc") }
            Button { export(.save) } label: { Label(L(.captureOverlaySave), systemImage: "square.and.arrow.down") }
            Button { export(.pin) } label: { Label(L(.captureOverlayPin), systemImage: "pin") }
            Button { export(.done) } label: { Text(L(.captureEditorDone)).bold() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tool palette

    private var toolPalette: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Self.toolOrder, id: \.self) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: symbol(for: tool))
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(model.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(L(helpKey(for: tool)))
                }
            }
            .padding(6)
        }
        .frame(width: 48)
    }

    // MARK: - Inspector

    private var inspector: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(Color.primary, lineWidth: model.style.strokeColor == color ? 2 : 0)
                        )
                        .onTapGesture { model.style.strokeColor = color }
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                Slider(value: strokeWidth, in: 1...24).frame(width: 100)
            }
            .help(L(.captureEditorStrokeWidth))

            if model.tool == .text || model.tool == .counter {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                    Slider(value: fontSize, in: 12...96).frame(width: 100)
                }
                .help(L(.captureEditorTextSize))
            }

            if model.tool == .rectangle || model.tool == .ellipse {
                Toggle(isOn: fillEnabled) { Text(L(.captureEditorFill)) }
                    .toggleStyle(.checkbox)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Bindings

    private var strokeWidth: Binding<Double> {
        Binding(get: { Double(model.style.strokeWidth) }, set: { model.style.strokeWidth = CGFloat($0) })
    }
    private var fontSize: Binding<Double> {
        Binding(get: { Double(model.style.fontSize) }, set: { model.style.fontSize = CGFloat($0) })
    }
    private var fillEnabled: Binding<Bool> {
        Binding(
            get: { model.style.fillColor != nil },
            set: { model.style.fillColor = $0 ? model.style.strokeColor.withAlpha(0.25) : nil }
        )
    }

    // MARK: - Export

    private enum ExportAction { case copy, save, pin, done }

    private func export(_ action: ExportAction) {
        guard let image = model.exportImage() else { return }
        switch action {
        case .copy:
            CaptureCoordinator.shared.editorCopy(image)
        case .save:
            CaptureCoordinator.shared.editorSave(image)
        case .pin:
            CaptureCoordinator.shared.editorPin(image)
        case .done:
            CaptureCoordinator.shared.editorCopy(image)
            onClose()
        }
    }

    // MARK: - Tool metadata

    private func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "character.textbox"
        case .freehand: return "scribble.variable"
        case .highlighter: return "highlighter"
        case .counter: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "square.grid.3x3"
        case .redaction: return "rectangle.fill"
        case .crop: return "crop"
        }
    }

    private func helpKey(for tool: AnnotationTool) -> L10n.Key {
        switch tool {
        case .select: return .captureEditorToolSelect
        case .arrow: return .captureEditorToolArrow
        case .line: return .captureEditorToolLine
        case .rectangle: return .captureEditorToolRectangle
        case .ellipse: return .captureEditorToolEllipse
        case .text: return .captureEditorToolText
        case .freehand: return .captureEditorToolFreehand
        case .highlighter: return .captureEditorToolHighlighter
        case .counter: return .captureEditorToolCounter
        case .blur: return .captureEditorToolBlur
        case .pixelate: return .captureEditorToolPixelate
        case .redaction: return .captureEditorToolRedaction
        case .crop: return .captureEditorToolCrop
        }
    }
}
