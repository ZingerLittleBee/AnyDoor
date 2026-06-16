import XCTest
import CoreGraphics
@testable import AnyDoor

final class ScrollStitchAccumulatorTests: XCTestCase {
    private func image(width: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let h = colors.count, bpr = width * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        for row in 0..<h {
            let (r, g, b) = colors[row]
            for x in 0..<width {
                let o = row * bpr + x * 4
                data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func distinctColors(_ n: Int, from start: Int = 0) -> [(UInt8, UInt8, UInt8)] {
        (0..<n).map { i in let v = i + start; return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0) }
    }

    @MainActor func testFirstFrameSeeds() {
        let acc = ScrollStitchAccumulator()
        XCTAssertNil(acc.composite())
        XCTAssertEqual(acc.totalHeight, 0)
        XCTAssertTrue(acc.ingest(image(width: 4, colors: distinctColors(60))))
        XCTAssertEqual(acc.sliceCount, 1)
        XCTAssertEqual(acc.totalHeight, 60)
        XCTAssertEqual(acc.composite()?.height, 60)
    }

    @MainActor func testScrolledFrameAppendsOnlyNewRows() {
        let tall = distinctColors(120)
        let acc = ScrollStitchAccumulator()
        _ = acc.ingest(image(width: 4, colors: Array(tall[0..<60])))
        XCTAssertTrue(acc.ingest(image(width: 4, colors: Array(tall[20..<80])))) // scrolled 20
        XCTAssertEqual(acc.totalHeight, 80)        // 60 + 20 new rows
        XCTAssertEqual(acc.composite()?.height, 80)
    }

    @MainActor func testUpwardScrollPrependsNewRows() {
        // Viewport starts on page rows 40..<100, then the user scrolls UP so it moves
        // to rows 20..<80 (content shifts down, 20 new rows revealed at the TOP).
        let tall = distinctColors(120)
        let acc = ScrollStitchAccumulator()
        _ = acc.ingest(image(width: 4, colors: Array(tall[40..<100])))
        XCTAssertTrue(acc.ingest(image(width: 4, colors: Array(tall[20..<80])))) // scrolled up 20
        XCTAssertEqual(acc.sliceCount, 2)
        XCTAssertEqual(acc.totalHeight, 80)        // 60 + 20 new rows prepended at the top
        XCTAssertEqual(acc.composite()?.height, 80)
    }

    @MainActor func testIdenticalFrameAppendsNothing() {
        let frame = distinctColors(60)
        let acc = ScrollStitchAccumulator()
        _ = acc.ingest(image(width: 4, colors: frame))
        XCTAssertFalse(acc.ingest(image(width: 4, colors: frame)))
        XCTAssertEqual(acc.totalHeight, 60)
    }
}
