import CoreGraphics
import Foundation

/// Tools available in the annotation editor. `select` moves/edits existing
/// elements; `crop` sets the output crop; the rest create elements.
enum AnnotationTool: String, CaseIterable, Sendable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case freehand
    case highlighter
    case text
    case blur
    case pixelate
    case redaction
    case counter
    case crop

    /// Whether the tool creates a rectangular element by dragging a bounding box.
    var isRectDrag: Bool {
        switch self {
        case .rectangle, .ellipse, .blur, .pixelate, .redaction: return true
        default: return false
        }
    }

    /// Whether the tool creates a two-point element (drag from a to b).
    var isTwoPoint: Bool { self == .arrow || self == .line }

    /// Whether the tool accumulates a freehand point path while dragging.
    var isPath: Bool { self == .freehand || self == .highlighter }
}

/// An RGBA color as pure 0...1 components, so styling stays Codable and testable
/// without AppKit. Converted to NSColor / CGColor only at render time.
struct RGBAColor: Equatable, Sendable, Codable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Returns a copy with a replaced alpha.
    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    static let red = RGBAColor(r: 1.0, g: 0.23, b: 0.19)
    static let orange = RGBAColor(r: 1.0, g: 0.58, b: 0.0)
    static let yellow = RGBAColor(r: 1.0, g: 0.8, b: 0.0)
    static let green = RGBAColor(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBAColor(r: 0.0, g: 0.48, b: 1.0)
    static let black = RGBAColor(r: 0.0, g: 0.0, b: 0.0)
    static let white = RGBAColor(r: 1.0, g: 1.0, b: 1.0)

    /// The default swatch palette shown in the inspector.
    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .black, .white]
}

/// Per-element styling. `fillColor == nil` means a shape is stroked only.
struct AnnotationStyle: Equatable, Sendable {
    var strokeColor: RGBAColor
    var strokeWidth: CGFloat
    var fillColor: RGBAColor?
    var fontSize: CGFloat

    init(strokeColor: RGBAColor = .red, strokeWidth: CGFloat = 4, fillColor: RGBAColor? = nil, fontSize: CGFloat = 28) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.fontSize = fontSize
    }

    static let `default` = AnnotationStyle()
}

/// A single placed annotation. All geometry is in the base image's **pixel**
/// coordinate space (top-left origin), so rendering is resolution-independent and
/// crop is exact.
struct AnnotationElement: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: Kind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle = .default) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    enum Kind: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case freehand([CGPoint])
        case highlighter([CGPoint])
        case text(String, origin: CGPoint)
        case blur(CGRect)
        case pixelate(CGRect)
        case redaction(CGRect)
        case counter(Int, center: CGPoint)
    }
}
