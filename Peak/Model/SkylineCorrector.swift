import ARKit
import PeakCore

/// Runs skyline matching on camera frames in the background, one at a time.
final class SkylineCorrector: @unchecked Sendable {
    struct Outcome {
        /// Heading correction relative to the one the frame was matched with, degrees.
        var delta: Double
        var accepted: Bool
        var reason: String?
        var rms: Double
    }

    private let queue = DispatchQueue(label: "peak.skyline", qos: .userInitiated)
    /// Only touched on the main thread.
    private(set) var isBusy = false
    private var matcher: SkylineMatcher = {
        var m = SkylineMatcher()
        m.workingWidth = 640
        return m
    }()

    /// Starts matching `frame` against the scene's horizon, with the current correction
    /// applied to ARKit's compass heading. Call on the main thread.
    func submit(_ frame: ARFrame, scene: TerrainScene, correction: Double, completion: @escaping (Outcome?) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        let pixels = frame.capturedImage
        let camera = frame.camera
        let k = camera.intrinsics
        let resolution = camera.imageResolution
        let transform = camera.transform
        let matcher = self.matcher
        queue.async { [weak self] in
            var outcome: Outcome?
            if let image = Self.rgbImage(pixels, targetWidth: 640) {
                let full = CameraIntrinsics(width: Int(resolution.width), height: Int(resolution.height),
                                            fx: Double(k[0][0]), fy: Double(k[1][1]),
                                            cx: Double(k[2][0]), cy: Double(k[2][1]))
                let intrinsics = full.scaled(toWidth: image.width, height: image.height)
                // ARKit's world (with gravity and heading): x east, y up, z south. The image's
                // x axis is the camera's x, its y axis the camera's −y; the camera looks along −z.
                func enu(_ v: simd_float4) -> SIMD3<Double> { SIMD3(Double(v.x), Double(-v.z), Double(v.y)) }
                let upright = UprightFrame(image: image, intrinsics: intrinsics,
                                           right: enu(transform.columns.0), down: -enu(transform.columns.1),
                                           forward: -enu(transform.columns.2))
                var prior = upright.camera.attitude
                prior.heading = normalizedAzimuth(prior.heading + correction)
                let m = matcher.match(upright.image, intrinsics: upright.camera.intrinsics, prior: prior, horizon: scene.horizon)
                outcome = Outcome(delta: m.alignment.headingCorrection, accepted: m.alignment.accepted,
                                  reason: m.alignment.rejectionReason, rms: m.alignment.rms)
            }
            DispatchQueue.main.async {
                self?.isBusy = false
                completion(outcome)
            }
        }
    }

    /// Converts ARKit's YCbCr camera image to RGB, shrinking it by whole-pixel box averaging.
    static func rgbImage(_ buffer: CVPixelBuffer, targetWidth: Int) -> RGBImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let y = yBase.assumingMemoryBound(to: UInt8.self), c = cBase.assumingMemoryBound(to: UInt8.self)

        let step = max(1, width / targetWidth)
        let w = width / step, h = height / step
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for oy in 0..<h {
            for ox in 0..<w {
                var sum = 0
                for dy in 0..<step {
                    let row = (oy * step + dy) * yStride + ox * step
                    for dx in 0..<step { sum += Int(y[row + dx]) }
                }
                var luma = Double(sum) / Double(step * step)
                let cx = (ox * step + step / 2) / 2, cy = (oy * step + step / 2) / 2
                var cb = Double(c[cy * cStride + 2 * cx]) - 128, cr = Double(c[cy * cStride + 2 * cx + 1]) - 128
                if !fullRange {
                    luma = (luma - 16) * 255 / 219
                    cb *= 255 / 224
                    cr *= 255 / 224
                }
                let i = 3 * (oy * w + ox)
                out[i] = clampByte(luma + 1.402 * cr)
                out[i + 1] = clampByte(luma - 0.344136 * cb - 0.714136 * cr)
                out[i + 2] = clampByte(luma + 1.772 * cb)
            }
        }
        return RGBImage(width: w, height: h, pixels: out)
    }

    private static func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
}
