import CoreVideo
import UIKit
import Foundation
import PeakCore

/// Matches camera frames against the horizon in the background, about once a second while
/// the phone is held steady, to correct the compass.
final class SkylineCorrector: @unchecked Sendable {
    struct Outcome {
        /// Corrections relative to the ones the frame was matched with, degrees.
        var delta: Double
        var pitchDelta: Double
        var rollDelta: Double
        /// The phone was held sideways; pitch and roll belong to that way of holding it.
        var sideways: Bool
        var accepted: Bool
        var rms: Double
        /// Why a frame was turned away (nil when accepted).
        var reason: String?
        var seconds: Double
    }

    /// Called on the main thread with each finished match.
    var onResult: ((Outcome) -> Void)?

    private let work = DispatchQueue(label: "peak.skyline", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastStart = Date.distantPast
    private var horizon: HorizonProfile?
    private var upright = ViewCorrection()
    private var sideways = ViewCorrection()
    private let matcher: SkylineMatcher = {
        var m = SkylineMatcher()
        m.workingWidth = 640
        return m
    }()

    /// What to match against, and the corrections in use for the phone held upright and
    /// sideways. Call on any thread.
    func update(horizon: HorizonProfile?, upright: ViewCorrection, sideways: ViewCorrection) {
        lock.lock()
        self.horizon = horizon
        self.upright = upright
        self.sideways = sideways
        lock.unlock()
    }

    /// Offers a camera frame (on the camera queue) with the phone's pose when it was taken.
    /// Most are skipped: one is taken at a time, at most about once a second, and only
    /// while the phone is steady.
    func offer(_ frame: CameraFeed.Frame, pose: MotionTracker.Pose, steady: Bool) {
        lock.lock()
        guard !busy, steady, let horizon, Date().timeIntervalSince(lastStart) > 0.8 else {
            lock.unlock()
            return
        }
        busy = true
        lastStart = Date()
        // The correction covers both the compass's north (magnetic or true) and its error.
        let isSideways = CameraGeometry.isSideways(pose)
        let correction = isSideways ? sideways : upright
        lock.unlock()

        // Convert now so the camera gets its buffer back straight away.
        guard let image = Self.rgbImage(frame.pixels, maxSide: 800) else {
            finish(nil)
            return
        }
        let intrinsics = frame.lens.intrinsics.scaled(toWidth: image.width, height: image.height)
        let axes = CameraGeometry.axes(pose, portrait: frame.portrait)

        work.async { [weak self] in
            guard let self else { return }
            let upright = UprightFrame(image: image, intrinsics: intrinsics, right: axes.right, down: axes.down, forward: axes.forward)
            var prior = upright.camera.attitude
            prior.heading = normalizedAzimuth(prior.heading + correction.heading)
            prior.pitch += correction.pitch
            prior.roll += correction.roll
            let m = self.matcher.match(upright.image, intrinsics: upright.camera.intrinsics, prior: prior, horizon: horizon)
            let a = m.alignment
            self.finish(Outcome(delta: a.headingCorrection, pitchDelta: a.pitchCorrection, rollDelta: a.rollCorrection,
                                sideways: isSideways, accepted: a.accepted, rms: a.rms, reason: a.rejectionReason,
                                seconds: m.seconds))
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
