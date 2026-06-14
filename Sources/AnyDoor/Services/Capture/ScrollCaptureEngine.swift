import AppKit
import CoreGraphics

/// Drives a scrolling capture: repeatedly posts a scroll-wheel event over a fixed
/// viewport, grabs the viewport with synchronous CoreGraphics (`LegacyScreenCapture`
/// — never ScreenCaptureKit, to avoid the macOS 26 executor-corruption crash), and
/// composites the newly revealed rows into one tall image using `ScrollStitch`.
///
/// `@MainActor`, callback-based; the only `await` is `Task.sleep` (resumes on the
/// main actor), so it never crosses isolation — same safety contract as
/// `CaptureCoordinator`. Per-capture loop state lives in instance properties; one
/// capture runs at a time.
@MainActor
final class ScrollCaptureEngine {
    private var policy = ScrollCapturePolicy()
    private var viewport: CGRect = .zero
    private var display: TargetDisplay?
    private var completion: ((CGImage?) -> Void)?

    private var slices: [(image: CGImage, height: Int)] = []
    private var prevSig: [ScrollStitch.RowSig] = []
    private var viewportPx = 0
    private var minOverlap = 0
    private var frameIndex = 0
    private var noProgress = 0
    private var lastDelta: Int?
    private var scrollSign = -1            // negative wheel1 = scroll down (reveal below)
    private var flippedOnce = false
    private var savedCursor: CGPoint?
    private var isCapturing = false

    /// Capture a region taller than itself by auto-scrolling. `viewport` is the
    /// fixed grab rect in global AppKit coordinates (bottom-left origin); `display`
    /// is the screen it lives on. `completion` receives the stitched image (or nil).
    func capture(viewport: CGRect, display: TargetDisplay,
                 policy: ScrollCapturePolicy = ScrollCapturePolicy(),
                 completion: @escaping (CGImage?) -> Void) {
        guard !isCapturing else { completion(nil); return }
        self.policy = policy
        self.viewport = viewport
        self.display = display
        self.completion = completion
        self.slices = []
        self.prevSig = []
        self.frameIndex = 0
        self.noProgress = 0
        self.lastDelta = nil
        self.scrollSign = -1
        self.flippedOnce = false
        self.savedCursor = CGEvent(source: nil)?.location

        guard let first = grabViewport(), let sig = Self.rowSignatures(of: first) else {
            finish(nil); return
        }
        isCapturing = true
        slices = [(first, first.height)]
        prevSig = sig
        viewportPx = first.height
        minOverlap = min(policy.minOverlapRows(viewportHeight: viewportPx), viewportPx)
        frameIndex = 1
        scheduleStep()
    }

    // MARK: - Loop

    private func scheduleStep() {
        let totalH = slices.reduce(0) { $0 + $1.height }
        if policy.shouldStop(frameIndex: frameIndex, delta: lastDelta ?? 0,
                             totalHeight: totalH, viewportHeight: viewportPx,
                             noProgressStreak: noProgress) {
            finishStitched(); return
        }
        postScroll()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(policy.settleMillis))
            self.advance()
        }
    }

    private func advance() {
        guard isCapturing else { return }
        guard let cur = grabViewport(), let curSig = Self.rowSignatures(of: cur) else {
            finishStitched(); return
        }
        let match = ScrollStitch.detectOverlap(
            prev: prevSig, cur: curSig,
            minOverlap: minOverlap, minMatchRatio: policy.minMatchRatio, expected: lastDelta
        )

        if let m = match, m.delta > 0 {
            let rect = CGRect(x: 0, y: cur.height - m.delta, width: cur.width, height: m.delta)
            if let slice = cur.cropping(to: rect) {
                slices.append((slice, m.delta))
            }
            prevSig = curSig
            lastDelta = m.delta
            noProgress = 0
        } else if match == nil, !flippedOnce, frameIndex == 1 {
            // The first scroll revealed nothing alignable — the wheel sign may be
            // inverted (natural scrolling). Flip once and retry this frame.
            flippedOnce = true
            scrollSign = -scrollSign
            scheduleStep()
            return
        } else {
            noProgress += 1
        }
        frameIndex += 1
        scheduleStep()
    }

    private func finishStitched() {
        let image = Self.composite(slices: slices)
        finish(image)
    }

    private func finish(_ image: CGImage?) {
        if let saved = savedCursor { CGWarpMouseCursorPosition(saved) }
        let cb = completion
        completion = nil
        isCapturing = false
        slices = []
        prevSig = []
        cb?(image)
    }

    // MARK: - Capture / scroll

    private func grabViewport() -> CGImage? {
        guard let display, let full = LegacyScreenCapture.display(display.id) else { return nil }
        let scale = display.backingScale
        let localX = (viewport.minX - display.frame.minX) * scale
        let top = (display.frame.maxY - viewport.maxY) * scale
        var rect = CGRect(x: localX.rounded(), y: top.rounded(),
                          width: (viewport.width * scale).rounded(),
                          height: (viewport.height * scale).rounded())
        rect = rect.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return full.cropping(to: rect)
    }

    private func postScroll() {
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        CGWarpMouseCursorPosition(Self.cgPoint(fromAppKit: center))
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: Int32(scrollSign * policy.scrollLines), wheel2: 0, wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
    }

    /// AppKit global (bottom-left, primary-display origin) → CG global (top-left).
    private static func cgPoint(fromAppKit p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    // MARK: - Pixels

    /// Top-to-bottom per-row fingerprints of `image` (RGBA8, one FNV-1a hash/row).
    nonisolated static func rowSignatures(of image: CGImage) -> [ScrollStitch.RowSig]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        let drew: Bool = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var sigs = [ScrollStitch.RowSig](repeating: 0, count: h)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            // A CGBitmapContext stores its rows top-to-bottom in memory, so buffer
            // row `r` is already the image's top-to-bottom row `r`.
            for r in 0..<h {
                sigs[r] = fnv1a(base + r * bpr, bpr)
            }
        }
        return sigs
    }

    nonisolated private static func fnv1a(_ ptr: UnsafeRawPointer, _ count: Int) -> ScrollStitch.RowSig {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let p = ptr.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            hash ^= UInt64(p[i])
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Stacks pixel slices top-to-bottom into one tall image.
    nonisolated static func composite(slices: [(image: CGImage, height: Int)]) -> CGImage? {
        guard let width = slices.first?.image.width, width > 0 else { return nil }
        let totalH = slices.reduce(0) { $0 + $1.height }
        guard totalH > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: totalH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var fromTop = 0
        for s in slices {
            // Bottom-left origin: a slice whose top sits `fromTop` below the canvas
            // top is drawn at y = totalH - fromTop - sliceHeight.
            let y = totalH - fromTop - s.height
            ctx.draw(s.image, in: CGRect(x: 0, y: y, width: width, height: s.height))
            fromTop += s.height
        }
        return ctx.makeImage()
    }
}
