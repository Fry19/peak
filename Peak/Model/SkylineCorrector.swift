import CoreVideo
import Foundation
import PeakCore

/// Matches camera frames against the horizon in the background, about once a second while
/// the phone is held steady, to correct the compass.
final class SkylineCorrector: @unchecked Sendable {
    struct Outcome {
        /// Heading correction relative to the one the frame was matched with, degrees.
        var delta: Double
        var accepted: Bool
        var rms: Double
    }

    /// Called on the main thread with each finished match.
    var onResult: ((Outcome) -> Void)?

    private let work = DispatchQueue(label: "peak.skyline", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastStart = Date.distantPast
    private var horizon: HorizonProfile?
    private var correction = 0.0
    private let matcher: SkylineMatcher = {
        var m = SkylineMatcher()
        m.workingWidth = 640
        return m
    }()

    /// What to match against, and the compass correction in use. Call on any thread.
    func update(horizon: HorizonProfile?, correction: Double) {
        lock.lock()
        self.horizon = horizon
        self.correction = correction
        lock.unlock()
    }

    /// Offers a camera frame (on the camera queue). Most are skipped: one is taken at a time,
    /// at most about once a second, and only while the phone is steady.
    func offer(_ buffer: CVPixelBuffer, pose: MotionTracker.Pose, steady: Bool, camera: CameraFeed) {
        lock.lock()
        guard !busy, steady, let horizon, Date().timeIntervalSince(lastStart) > 0.8 else {
            lock.unlock()
            return
        }
        busy = true
        lastStart = Date()
        let correction = self.correction
        lock.unlock()

        // Convert now so the camera gets its buffer back straight away.
        guard let image = Self.rgbImage(buffer, maxSide: 800) else {
            finish(nil)
            return
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let f = Double(max(w, h)) / 2 / tan(camera.fieldOfView * .pi / 360)
        let intrinsics = CameraIntrinsics(width: w, height: h, fx: f, fy: f, cx: Double(w) / 2, cy: Double(h) / 2)
            .scaled(toWidth: image.width, height: image.height)
        let axes = CameraGeometry.axes(pose, portrait: camera.portraitFrames)

        work.async { [weak self] in
            guard let self else { return }
            let frame = UprightFrame(image: image, intrinsics: intrinsics, right: axes.right, down: axes.down, forward: axes.forward)
            var prior = frame.camera.attitude
            prior.heading = normalizedAzimuth(prior.heading + correction)
            let m = self.matcher.match(frame.image, intrinsics: frame.camera.intrinsics, prior: prior, horizon: horizon)
            self.finish(Outcome(delta: m.alignment.headingCorrection, accepted: m.alignment.accepted, rms: m.alignment.rms))
        }
    }

    private func finish(_ outcome: Outcome?) {
        lock.lock()
        busy = false
        lock.unlock()
        guard let outcome else { return }
        DispatchQueue.main.async { [weak self] in self?.onResult?(outcome) }
    }

    /// Converts a YCbCr camera frame to RGB, shrunk by whole-pixel box averaging so the long
    /// side is at most `maxSide`.
    static func rgbImage(_ buffer: CVPixelBuffer, maxSide: Int) -> RGBImage? {
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

        let step = max(1, (max(width, height) + maxSide - 1) / maxSide)
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
