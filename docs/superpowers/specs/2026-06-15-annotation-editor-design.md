# Annotation Editor (Phase 1)

**Date:** 2026-06-15
**Status:** Approved design (autonomous) — ready for implementation
**Scope:** Phase 1 of the screenshot/recording suite — the real annotation editor
that replaces the Phase 0 placeholder window.

## Background

Phase 0 wires the capture overlay's **edit** button to a placeholder
`AnnotationEditorWindow` that just shows the image. Phase 1 replaces the body with
a real editor: draw arrows / shapes / text, redact via blur / pixelate / solid
bar, add numbered step counters, freehand + highlighter strokes, and crop — then
export back through the same copy / save / pin paths.

## Goals

- Tools: **select/move**, **arrow**, **line**, **rectangle**, **ellipse**,
  **freehand**, **highlighter**, **text**, **blur**, **pixelate**, **redaction**
  (solid bar), **numbered counter**, **crop**.
- Per-tool **style**: stroke color (palette), stroke width, fill (shapes), font
  size (text). A small inspector exposes the relevant controls for the active tool.
- **Undo / redo** of every edit (snapshot stack).
- **Export**: copy to clipboard, save to file, pin on screen — reusing the
  capture output paths. "Done" copies + closes.
- Non-destructive: the base capture pixels are kept; annotations are a layer list
  rendered on top, so order, crop, and undo all stay editable until export.

## Non-Goals (deferred)

- Multi-select / grouping, alignment guides, shadow/blur on shapes.
- Re-opening a saved annotated image to keep editing (export is one-way).
- Vector export (SVG/PDF). Output is a raster image (PNG), matching capture.

## Architecture

### Pure core (unit tested, no AppKit views)

```
Sources/AnyDoor/Services/Annotation/
  AnnotationModel.swift     # AnnotationTool, AnnotationStyle (RGBA), RGBAColor,
                            #   AnnotationElement (id + Kind enum + style)
  AnnotationDocument.swift  # base image + ordered elements + crop + counter,
                            #   snapshot-based undo/redo, mutation API
  AnnotationGeometry.swift  # arrowhead barbs, counter circle rect, hit-testing,
                            #   crop-clamp, point-in-element
  AnnotationRenderer.swift  # composites base + elements (+ crop) -> CGImage;
                            #   blur = CIGaussianBlur, pixelate = CIPixellate
```

- `AnnotationElement.Kind` (all geometry in **image pixel coordinates** so the
  render is resolution-independent and crop is exact):
  `arrow(from,to)`, `line(from,to)`, `rectangle(rect)`, `ellipse(rect)`,
  `freehand([pt])`, `highlighter([pt])`, `text(string,origin)`,
  `blur(rect)`, `pixelate(rect)`, `redaction(rect)`, `counter(number,center)`.
- `RGBAColor` is a Codable/Equatable value (0...1 components) so style is pure and
  testable; converted to `NSColor`/`CGColor` only at render time.
- `AnnotationDocument` holds `baseImage: CGImage`, `elements: [AnnotationElement]`,
  `cropRect: CGRect?`, `nextCounter: Int`. Mutations (`add`, `updateLast`,
  `update(id:)`, `remove(id:)`, `setCrop`, `clearCrop`) each push the prior state
  onto an undo stack; `undo()` / `redo()` swap snapshots. `addCounter` consumes and
  bumps `nextCounter`.
- `AnnotationRenderer.render(_:)` is pure given a document: draw base, apply
  blur/pixelate/redaction regions (sampled from the base via CoreImage), stroke/
  fill shapes and arrows, draw text and counters, then crop. Output `CGImage`.

### View layer (AppKit canvas + SwiftUI chrome)

```
Sources/AnyDoor/Views/Capture/
  AnnotationEditorWindow.swift  # real window (regular activation, isRestorable=false)
  AnnotationEditorView.swift    # SwiftUI: tool palette + inspector + canvas + toolbar
  AnnotationCanvasView.swift    # NSViewRepresentable wrapping an AppKit canvas that
                                #   handles tool mouse input, live preview, selection
```

- The drawing surface is an **AppKit `NSView`** (precise mouse handling and live
  preview, like `SelectionOverlayView`), wrapped via `NSViewRepresentable`. The
  palette, inspector, and toolbar are SwiftUI. Hover (if any) uses `.onHoverSafe`.
- The canvas converts view points <-> image pixels via a fitted scale, applies the
  active tool on mouse down/drag/up (creating or updating the document's last
  element), and renders the document for display.
- Text entry: clicking with the text tool drops an editable field; commit adds a
  `text` element. Counter: clicking drops the next number.

### Integration

- `CaptureCoordinator` already calls `AnnotationEditorWindow.shared.show(image:)`.
  The editor takes the `CGImage`/`NSImage` and, on export, routes through new
  coordinator entry points (`copyImage`, `saveImage`, `pinImage`) so copy / save /
  pin behave identically to the capture overlay.
- New `BuiltinItem` / providers are **not** needed; the editor is reached from the
  capture overlay edit button (and could later be reached from history).

## Concurrency (Swift 6 strict)

- Core model/renderer are plain value/`final class` types used on the `@MainActor`
  editor; `RGBAColor`/`AnnotationElement`/`AnnotationTool` are `Sendable` values.
- Rendering is synchronous CoreGraphics/CoreImage on the main actor (images are
  small; no cross-isolation await — consistent with the capture crash fix).

## Testing

Pure logic unit tests:

- Document: add pushes undo; undo/redo restore; counter increments and undo
  restores the counter; crop set/clear; remove by id.
- Geometry: arrowhead barb points for several angles; counter circle rect; crop
  clamp to image bounds; hit-test point in rect/ellipse/line.
- Style: RGBAColor round-trips to/from NSColor components; default styles per tool.
- Renderer: output size equals base (no crop) and crop size (with crop); a render
  with each element kind succeeds and is non-nil (smoke), blur/pixelate regions do
  not throw.

Manual verification: drawing each tool, live preview, text entry, undo/redo,
crop, and export (copy / save / pin).
