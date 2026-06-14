import CoreGraphics
import Foundation

/// The editable annotation document: an immutable base image plus an ordered list
/// of annotation elements and an optional crop. Every mutation snapshots the prior
/// state for undo/redo. Used on the `@MainActor` editor; not `Sendable` (it holds
/// a `CGImage`).
@MainActor
final class AnnotationDocument {
    let baseImage: CGImage
    private(set) var elements: [AnnotationElement] = []
    private(set) var cropRect: CGRect?
    /// The number the next `counter` element will use (1-based).
    private(set) var nextCounter: Int = 1

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    /// The base image's full pixel bounds (top-left origin).
    var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
    }

    private struct Snapshot {
        var elements: [AnnotationElement]
        var cropRect: CGRect?
        var nextCounter: Int
    }

    private var snapshot: Snapshot {
        Snapshot(elements: elements, cropRect: cropRect, nextCounter: nextCounter)
    }

    private func checkpoint() {
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    // MARK: - Mutations

    /// Appends an element, returning its id.
    @discardableResult
    func add(_ element: AnnotationElement) -> UUID {
        checkpoint()
        elements.append(element)
        return element.id
    }

    /// Appends the next numbered counter at `center`, bumping the counter.
    @discardableResult
    func addCounter(at center: CGPoint, style: AnnotationStyle) -> UUID {
        checkpoint()
        let element = AnnotationElement(kind: .counter(nextCounter, center: center), style: style)
        elements.append(element)
        nextCounter += 1
        return element.id
    }

    /// Replaces the kind of the most-recently-added element (live drag preview
    /// commits via `add` first, then streams updates through this without piling
    /// up undo steps).
    func updateLastKind(_ kind: AnnotationElement.Kind) {
        guard !elements.isEmpty else { return }
        elements[elements.count - 1].kind = kind
    }

    /// Replaces an element by id (no-op if absent).
    func update(id: UUID, kind: AnnotationElement.Kind) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        elements[i].kind = kind
    }

    /// Removes an element by id (no-op if absent).
    func remove(id: UUID) {
        guard elements.contains(where: { $0.id == id }) else { return }
        checkpoint()
        elements.removeAll { $0.id == id }
    }

    /// Removes the most-recently-added element.
    func removeLast() {
        guard !elements.isEmpty else { return }
        checkpoint()
        elements.removeLast()
    }

    func setCrop(_ rect: CGRect) {
        checkpoint()
        cropRect = AnnotationGeometry.clampCrop(rect, to: imageBounds)
    }

    func clearCrop() {
        guard cropRect != nil else { return }
        checkpoint()
        cropRect = nil
    }

    // MARK: - Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        apply(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        apply(next)
    }

    private func apply(_ s: Snapshot) {
        elements = s.elements
        cropRect = s.cropRect
        nextCounter = s.nextCounter
    }
}
