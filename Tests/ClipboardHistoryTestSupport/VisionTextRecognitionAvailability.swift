import CoreGraphics
import Foundation
import Vision
import XCTest

public extension XCTestCase {
    /// Skips a test that runs real Vision text recognition when this process
    /// runs in a virtual machine whose Vision cannot recognize text at all.
    /// GitHub's macOS 27 runner VM lacks the paravirtual scaler driver that
    /// accurate recognition loads, so every request fails there without a
    /// usable error ("nilError", "unknownError"). Physical Macs, and VMs where
    /// a probe request succeeds, always run the test strictly.
    func skipIfVisionTextRecognitionIsUnavailableInVirtualMachine() throws {
        guard runsInVirtualMachine, let failure = visionTextRecognitionProbeFailure else {
            return
        }
        throw XCTSkip("Vision text recognition is unavailable in this VM: \(failure)")
    }
}

private let runsInVirtualMachine: Bool = {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0
        && present == 1
}()

/// Nil when an accurate recognition request on a blank image completes.
private let visionTextRecognitionProbeFailure: String? = {
    guard
        let context = CGContext(
            data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        return "could not create a probe image"
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    guard let image = context.makeImage() else {
        return "could not create a probe image"
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return nil
    } catch {
        return String(describing: error)
    }
}()
