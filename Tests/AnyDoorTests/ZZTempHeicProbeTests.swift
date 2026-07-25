import XCTest
@testable import ImageConversionPlugin

// TEMPORARY probe — delete after diagnosing the CI HEIC failure.
final class ZZTempHeicProbeTests: XCTestCase {
    func test_probeOddAndEvenHeicEncodes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeicProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a 1600x1200 HEIC the same way ImageConversionEngineTests does.
        let width = 1_600, height = 1_200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for x in stride(from: 0, to: width, by: 8) {
            ctx.setFillColor(red: Double(x) / Double(width), green: 0.4, blue: 0.7, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "fixture HEIC write")
        let url = dir.appendingPathComponent("source.heic")
        try (data as Data).write(to: url)

        let encoder = try ImageIOCandidateEncoder(input: .file(url))
        for edge in [1_600, 895, 894, 641, 640, 321, 320, 17] {
            let dims = PixelDimensions(width: width, height: height)
                .scaled(toLongestEdge: edge)
            let result: String
            do {
                let bytes = try encoder.encode(.init(
                    format: .heic, quality: TargetSizePolicy.losslessQuality,
                    dimensions: dims, transparencyBackgroundHex: nil
                ))
                result = "ok \(bytes.count) bytes"
            } catch {
                result = "FAILED \(error)"
            }
            print("PROBE heic \(dims.width)x\(dims.height): \(result)")
        }

        // Hypothesis 2: the runner has no hardware HEVC encoder, so concurrent
        // encode sessions fail where a single one succeeds.
        await withTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                group.addTask {
                    do {
                        let enc = try ImageIOCandidateEncoder(input: .file(url))
                        let bytes = try enc.encode(.init(
                            format: .heic, quality: TargetSizePolicy.losslessQuality,
                            dimensions: PixelDimensions(width: 800, height: 600),
                            transparencyBackgroundHex: nil
                        ))
                        return "concurrent#\(index) ok \(bytes.count) bytes"
                    } catch {
                        return "concurrent#\(index) FAILED \(error)"
                    }
                }
            }
            for await line in group { print("PROBE \(line)") }
        }
    }
}
