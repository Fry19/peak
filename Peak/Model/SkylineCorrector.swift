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
        /// The heading correction the frame was matched with (north included, the lens's
        /// offset not), so a match can be compared with ones made under other corrections.
        var from: Double
        var pitchDelta: Double
        var rollDelta: Double
        /// The phone was held sideways; pitch and roll belong to that way of holding it.
        var sideways: Bool
        /// The lens that took the frame (`CameraFeed.Lens.name`); the deltas are from the
        /// corrections plus its offset.
        var lens: String
        var accepted: Bool
        var rms: Double
        /// Why a frame was turned away (nil when accepted).
        var reason: String?
        var seconds: Double
    }

    /// Called on the main thread with each finished match.
    var onResult: ((Outcome) -> Void)?

    /// A frame kept for testing at a desk: the upright picture the matcher looked at (at up to
    /// 1920 pixels, before it shrinks it), and a case file for `peakbench align` that names
    /// it as `imageName`.
    struct TestFrame {
        var image: RGBImage
        var caseFile: Data
        var imageName: String
    }

    private var capture: ((TestFrame) -> Void)?

    /// Keeps the next frame matched, with what the sensors said and how the match went.
    /// `done` runs on the main thread.
    func captureNext(_ done: @escaping (TestFrame) -> Void) {
        lock.lock()
        capture = done
        lock.unlock()
    }

    // Below the interface's priority, so matching never makes the screen stutter.
    private let work = DispatchQueue(label: "peak.skyline", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastStart = Date.distantPast
    private var horizon: HorizonProfile?
    private var upright = ViewCorrection()
    private var sideways = ViewCorrection()
    private var lensOffsets = LensOffsets()
    private var positionUncertainty = LocationQuality.matchingAccuracy
    private let matcher = SkylineMatcher()
    /// The long side frames are matched at. What counts is pixels per degree: a far ridge in
    /// haze may stand only half a degree over a nearer one in front, a few pixels at this size.
    private static let workingSide = 960

    /// What to match against, the corrections in use for the phone held upright and
    /// sideways and each lens's offset on top, and how far you may be from where the horizon was rendered, meters
    /// (`LocationQuality.positionUncertainty`). Call on any thread.
    func update(horizon: HorizonProfile?, upright: ViewCorrection, sideways: ViewCorrection, lensOffsets: LensOffsets,
                positionUncertainty: Double) {
        lock.lock()
        self.horizon = horizon
        self.upright = upright
        self.sideways = sideways
        self.lensOffsets = lensOffsets
        self.positionUncertainty = positionUncertainty
        lock.unlock()
    }

    private var isPaused = false

    /// No frames are matched while paused (the view is frozen, so the results would be
    /// thrown away). Call on any thread.
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isPaused }
        set { lock.lock(); isPaused = newValue; lock.unlock() }
    }

    /// Offers a camera frame (on the camera queue) with the phone's pose when it was taken.
    /// Most are skipped: one is taken at a time, at most about once a second, only while
    /// the phone is steady, and none while paused.
    func offer(_ frame: CameraFeed.Frame, pose: MotionTracker.Pose, steady: Bool) {
        lock.lock()
        guard !busy, !isPaused, steady, let horizon, Date().timeIntervalSince(lastStart) > 0.8 else {
            lock.unlock()
            return
        }
        busy = true
        lastStart = Date()
        // The correction covers both the compass's north (magnetic or true) and its error.
        let isSideways = CameraGeometry.isSideways(pose)
        let base = isSideways ? sideways : upright
        let correction = base + lensOffsets.offset(lens: frame.lens.name, sideways: isSideways)
        let uncertainty = positionUncertainty
        let capture = self.capture
        self.capture = nil
        lock.unlock()

        let pixels = frame.pixels
        let lens = frame.lens
        let axes = CameraGeometry.axes(pose, portrait: frame.portrait)

        // Everything, the conversion included, happens off the camera's queue so frames keep
        // flowing to the screen.
        work.async { [weak self] in
            guard let self else { return }
            guard let image = Self.rgbImage(pixels, maxSide: 1920) else {
                self.finish(nil)
                return
            }
            let intrinsics = lens.intrinsics.scaled(toWidth: image.width, height: image.height)
            let upright = UprightFrame(image: image, intrinsics: intrinsics, right: axes.right, down: axes.down, forward: axes.forward)
            var prior = upright.camera.attitude
            prior.heading = normalizedAzimuth(prior.heading + correction.heading)
            prior.pitch += correction.pitch
            prior.roll += correction.roll
            var matcher = self.matcher
            // Near ridges shift with the position, so they count for less the less sure it is.
            matcher.settings.positionUncertainty = uncertainty
            // A telephoto's narrow view has less skyline across it.
            matcher.settings.adapt(toHorizontalFOV: upright.camera.intrinsics.horizontalFOV)
            let (w, h) = (upright.image.width, upright.image.height)
            matcher.workingWidth = w >= h ? Self.workingSide : Self.workingSide * w / h
            let m = matcher.match(upright.image, intrinsics: upright.camera.intrinsics, prior: prior, horizon: horizon)
            let a = m.alignment
            let outcome = Outcome(delta: a.headingCorrection, from: base.heading,
                                  pitchDelta: a.pitchCorrection, rollDelta: a.rollCorrection,
                                  sideways: isSideways, lens: lens.name, accepted: a.accepted, rms: a.rms, reason: a.rejectionReason,
                                  seconds: m.seconds)
            if let capture, let frame = Self.testFrame(upright, correction: correction, horizon: horizon,
                                                       measuredLens: lens.measured, outcome: outcome) {
                DispatchQueue.main.async { capture(frame) }
            }
            self.finish(outcome)
        }
    }

    /// The upright frame the matcher looked at, and its case: where it was taken and the
    /// attitude the matcher started from (the sensors with the corrections in use).
    private static func testFrame(_ frame: UprightFrame, correction: ViewCorrection, horizon: HorizonProfile,
                                  measuredLens: Bool, outcome: Outcome) -> TestFrame? {
        let sensors = frame.camera.attitude
        let k = frame.camera.intrinsics
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "peak-frame-\(formatter.string(from: Date()))"
        struct Case: Encodable {
            var image: String
            var latitude: Double
            var longitude: Double
            var altitude: Double
            var heading: Double
            var pitch: Double
            var roll: Double
            var horizontalFOV: Double
            var note: String
            var app: App
        }
        struct App: Encodable {
            var sensors: [String: Double]
            var correction: [String: Double]
            var intrinsics: [String: Double]
            var measuredLens: Bool
            var match: [String: String]
        }
        let file = Case(
            image: name + ".png", latitude: horizon.observer.latitude, longitude: horizon.observer.longitude,
            altitude: horizon.observer.height,
            heading: normalizedAzimuth(sensors.heading + correction.heading), pitch: sensors.pitch + correction.pitch,
            roll: sensors.roll + correction.roll, horizontalFOV: k.horizontalFOV,
            note: "Saved by the app. heading/pitch/roll are what the matcher started from: the sensors plus the " +
                "corrections in use. Add anchors (marked summits) to measure the error.",
            app: App(sensors: ["heading": sensors.heading, "pitch": sensors.pitch, "roll": sensors.roll],
                     correction: ["heading": correction.heading, "pitch": correction.pitch, "roll": correction.roll],
                     intrinsics: ["width": Double(k.width), "height": Double(k.height), "fx": k.fx, "fy": k.fy, "cx": k.cx, "cy": k.cy],
                     measuredLens: measuredLens,
                     match: ["accepted": outcome.accepted ? "yes" : "no", "reason": outcome.reason ?? "",
                             "heading": String(format: "%+.3f", outcome.delta), "pitch": String(format: "%+.3f", outcome.pitchDelta),
                             "roll": String(format: "%+.3f", outcome.rollDelta), "rms": String(format: "%.3f", outcome.rms)]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return nil }
        return TestFrame(image: frame.image, caseFile: data, imageName: name)
    }

    private func finish(_ outcome: Outcome?) {
        lock.lock()
        busy = false
        lock.unlock()
        guard let outcome else { return }
        DispatchQueue.main.async { [weak self] in self?.onResult?(outcome) }
    }

    /// Converts a YCbCr camera frame to RGB, shrunk by a whole factor so the long side is at
    /// most `maxSide`. Each output pixel averages the 2×2 pixels at the middle of the block
    /// it stands for, which is plenty for finding the skyline and far cheaper than the whole
    /// block on a 4K frame.
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
        let inner = min(2, step), offset = (step - inner) / 2
        var out = [UInt8](repeating: 0, count: w * h * 3)
        out.withUnsafeMutableBufferPointer { out in
            for oy in 0..<h {
                let y0 = oy * step + offset
                for ox in 0..<w {
                    let x0 = ox * step + offset
                    var sum = 0
                    for dy in 0..<inner {
                        let row = (y0 + dy) * yStride + x0
                        for dx in 0..<inner { sum += Int(y[row + dx]) }
                    }
                    var luma = Double(sum) / Double(inner * inner)
                    let cx = (x0 + inner / 2) / 2, cy = (y0 + inner / 2) / 2
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
        }
        return RGBImage(width: w, height: h, pixels: out)
    }

    private static func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
}
