import SwiftUI
import AppKit

/// The annotation editor UI, styled after CleanShot X: a single top toolbar of
/// drawing tools, a contextual style bar beneath it, and the captured image
/// floating on a neutral backdrop. Export actions (copy / save / pin / done) sit
/// on the toolbar's trailing edge. The drawing surface, model, and renderer are
/// unchanged — this view is purely the chrome.
struct AnnotationEditorView: View {
    @Bindable var model: AnnotationEditorModel
    let onClose: () -> Void

    /// Tools grouped for the toolbar; a thin divider separates each group.
    private static let toolGroups: [[AnnotationTool]] = [
        [.select],
        [.arrow, .line, .rectangle, .ellipse],
        [.freehand, .highlighter, .text, .counter],
        [.blur, .pixelate, .redaction],
        [.crop],
    ]

    var body: some View {
        // Observe `revision` so the chrome re-evaluates on every document mutation:
        // this keeps the undo/redo buttons' enabled state current AND re-runs the
        // canvas's `updateNSView` (-> redraw) after a toolbar-triggered undo/redo.
        // `canUndo`/`canRedo` read the non-Observable AnnotationDocument, so without
        // this dependency SwiftUI never refreshes when only the document changes.
        let _ = model.revision
        return VStack(spacing: 0) {
            toolbar
            Divider()
            styleBar
            Divider()
            AnnotationCanvasView(model: model)
                .frame(minWidth: 360, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                .padding(16)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        // Suppress the blue keyboard-focus ring on the toolbar buttons and color
        // picker; selection (filled tool, ringed swatch) and hover styling stay.
        .focusEffectDisabled()
    }

    // MARK: - Top toolbar (undo/redo · tools · export)

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                iconButton("arrow.uturn.backward", help: L(.captureEditorUndo), enabled: model.canUndo) { model.undo() }
                iconButton("arrow.uturn.forward", help: L(.captureEditorRedo), enabled: model.canRedo) { model.redo() }
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider().frame(height: 18) }
                    ForEach(group, id: \.self) { tool in
                        toolButton(tool)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                iconButton("doc.on.doc", help: L(.captureOverlayCopy)) { export(.copy) }
                iconButton("square.and.arrow.down", help: L(.captureOverlaySave)) { export(.save) }
                iconButton("pin", help: L(.captureOverlayPin)) { export(.pin) }
                Button { export(.done) } label: {
                    Text(L(.captureEditorDone)).fontWeight(.semibold).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let selected = model.tool == tool
        return Button { model.tool = tool } label: {
            Image(systemName: symbol(for: tool))
                .font(.system(size: 15))
                .frame(width: 30, height: 28)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L(helpKey(for: tool)))
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    // MARK: - Contextual style bar

    private var styleBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { _, color in
                    swatch(color)
                }
                CustomColorButton(
                    isCustomActive: !RGBAColor.palette.contains(model.style.strokeColor),
                    currentColor: model.style.strokeColor,
                    onPick: { model.style.strokeColor = $0 }
                )
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: strokeWidth, in: 1...24).frame(width: 110)
            }
            .help(L(.captureEditorStrokeWidth))

            if model.tool == .text || model.tool == .counter {
                Divider().frame(height: 22)
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size").foregroundStyle(.secondary)
                    Slider(value: fontSize, in: 12...96).frame(width: 110)
                }
                .help(L(.captureEditorTextSize))
            }

            if model.tool == .rectangle || model.tool == .ellipse {
                Divider().frame(height: 22)
                Toggle(isOn: fillEnabled) { Text(L(.captureEditorFill)) }
                    .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(_ color: RGBAColor) -> some View {
        let selected = model.style.strokeColor == color
        return Button { model.style.strokeColor = color } label: {
            SwatchDot(
                fill: .solid(Color(nsColor: color.nsColor)),
                selected: selected,
                needsEdge: color == .black || color == .white
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// One color swatch dot drawn entirely in a single `Canvas`: the dot and the
/// selection ring are rasterized from one shared center, so they can never drift
/// apart at sub-pixel layout offsets — which is what made two independently-framed
/// concentric circles look off-center. A fixed 28pt footprint keeps the row from
/// reflowing when selection moves. The result is the standard "ring + gap" look,
/// done pixel-perfectly.
private struct SwatchDot: View {
    enum Fill { case solid(Color), rainbow }
    let fill: Fill
    let selected: Bool
    var needsEdge: Bool = false

    private static let rainbow = Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red])

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let dot = Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
            switch fill {
            case let .solid(color):
                ctx.fill(dot, with: .color(color))
            case .rainbow:
                ctx.fill(dot, with: .conicGradient(Self.rainbow, center: c))
            }
            // Hairline so near-black / near-white dots read on the dark bar.
            if needsEdge {
                ctx.stroke(dot, with: .color(.gray.opacity(0.5)), lineWidth: 1)
            }
            // Concentric selection ring with a 2pt gap, sharing the dot's center.
            if selected {
                let ring = Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24))
                ctx.stroke(ring, with: .color(.accentColor), lineWidth: 2)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// A circular swatch — same shape, size, and spacing as the preset color dots —
/// that opens the system color panel and applies the chosen color as the stroke
/// color. Used instead of the native `ColorPicker`, which renders as a wide pill,
/// keeps its own (unsuppressable) focus ring, and applied changes unreliably.
/// Shows a rainbow until a non-preset color is active, then shows that color.
private struct CustomColorButton: View {
    let isCustomActive: Bool
    let currentColor: RGBAColor
    let onPick: (RGBAColor) -> Void
    @State private var coordinator = ColorPanelCoordinator()

    var body: some View {
        Button {
            coordinator.present(initial: currentColor.nsColor, onChange: onPick)
        } label: {
            SwatchDot(
                fill: isCustomActive ? .solid(Color(nsColor: currentColor.nsColor)) : .rainbow,
                selected: isCustomActive
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bridges the shared `NSColorPanel` to a SwiftUI button: presents the panel and
/// forwards every color change to `onChange` in sRGB. Lives on the main actor
/// since it touches AppKit and the editor model.
@MainActor
private final class ColorPanelCoordinator: NSObject {
    private var onChange: ((RGBAColor) -> Void)?

    func present(initial: NSColor, onChange: @escaping (RGBAColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let srgb = sender.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGBAColor(
            r: Double(srgb.redComponent), g: Double(srgb.greenComponent),
            b: Double(srgb.blueComponent), a: Double(srgb.alphaComponent)
        ))
    }
}
