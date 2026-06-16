import XCTest
import CoreGraphics
@testable import AnyDoor

/// Headless tests for the engine's pure pixel pipeline (row signatures +
/// compositing) and its integration with ScrollStitch — no display needed.
final class ScrollCaptureEngineTests: XCTestCase {

    /// Builds an RGBA8 image whose row `r` is a solid color from `colors[r]`.
    /// Data is laid out top-to-bottom (row 0 = top), matching CGImage semantics.
    private func image(width: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let h = colors.count
        let bpr = width * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        for row in 0..<h {
            let (r, g, b) = colors[row]
            for x in 0..<width {
                let o = row * bpr + x * 4
                data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    // Distinct color per row index (supports > 256 rows).
    private func distinctColors(_ n: Int, from start: Int = 0) -> [(UInt8, UInt8, UInt8)] {
        (0..<n).map { i in
            let v = i + start
            return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0)
        }
    }

    func testRowSignaturesAreDistinctAndOrdered() {
        let img = image(width: 4, colors: distinctColors(20))
        let sigs = ScrollCaptureEngine.rowSignatures(of: img)
        XCTAssertEqual(sigs?.count, 20)
        XCTAssertEqual(Set(sigs ?? []).count, 20) // every row distinct
    }

    func testWideRowSignaturesStayDistinctAndIdentical() {
        // Width far larger than the per-row sample budget forces the subsampling
        // path (column stride > 1). Distinct rows must still fingerprint distinctly
        // and identical rows must still collide.
        let width = 1024
        let distinct = ScrollCaptureEngine.rowSignatures(of: image(width: width, colors: distinctColors(40)))
        XCTAssertEqual(distinct?.count, 40)
        XCTAssertEqual(Set(distinct ?? []).count, 40) // every distinct row → distinct sig
        let solid = ScrollCaptureEngine.rowSignatures(of: image(width: width, colors:
            [(UInt8, UInt8, UInt8)](repeating: (5, 6, 7), count: 12)))
        XCTAssertEqual(Set(solid ?? [1, 2]).count, 1)  // identical rows → one sig
    }

    func testIdenticalRowsShareSignature() {
        let solid = [(UInt8, UInt8, UInt8)](repeating: (10, 20, 30), count: 8)
        let sigs = ScrollCaptureEngine.rowSignatures(of: image(width: 4, colors: solid))
        XCTAssertEqual(Set(sigs ?? [1]).count, 1)
    }

    func testEndToEndScrollDetection() {
        // A 120-row tall "document"; two 60-row viewports scrolled 20 apart.
        let tall = distinctColors(120)
        let frameA = image(width: 4, colors: Array(tall[0..<60]))
        let frameB = image(width: 4, colors: Array(tall[20..<80]))
        let sigA = ScrollCaptureEngine.rowSignatures(of: frameA)!
        let sigB = ScrollCaptureEngine.rowSignatures(of: frameB)!
        let r = ScrollStitch.detectOverlap(prev: sigA, cur: sigB,
                                           minOverlap: 15, minMatchRatio: 0.9, expected: nil)
        XCTAssertEqual(r?.delta, 20)
    }

    func testCompositeStacksTopToBottom() {
        let red = image(width: 4, colors: [(UInt8, UInt8, UInt8)](repeating: (255, 0, 0), count: 10))
        let green = image(width: 4, colors: [(UInt8, UInt8, UInt8)](repeating: (0, 255, 0), count: 5))
        let blue = image(width: 4, colors: [(UInt8, UInt8, UInt8)](repeating: (0, 0, 255), count: 8))
        let out = ScrollCaptureEngine.composite(slices: [(red, 10), (green, 5), (blue, 8)])
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.height, 23)
        XCTAssertEqual(out?.width, 4)

        let sigs = ScrollCaptureEngine.rowSignatures(of: out!)!
        XCTAssertEqual(sigs.count, 23)
        // Red band 0..9, green 10..14, blue 15..22 — uniform within, distinct across.
        XCTAssertEqual(Set(sigs[0..<10]).count, 1)
        XCTAssertEqual(Set(sigs[10..<15]).count, 1)
        XCTAssertEqual(Set(sigs[15..<23]).count, 1)
        XCTAssertEqual(Set([sigs[0], sigs[10], sigs[15]]).count, 3)
    }

    func testCompositeEmptyReturnsNil() {
        XCTAssertNil(ScrollCaptureEngine.composite(slices: []))
    }
}
