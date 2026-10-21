import AVFoundation
import PeakCore
import simd
import UIKit

/// The back camera. Every frame comes with the moment it was taken and the lens geometry
/// for it, so the picture and the lines drawn over it can be matched exactly.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// The lens for one frame, in the frame's pixels.
    struct Lens {
        var intrinsics: CameraIntrinsics
        /// Read from the frame's intrinsic matrix, rather than estimated from the format.
        var measured: Bool

        /// Field of view along the long side of the frame, degrees.
        var fieldOfView: Double {
            let k = intrinsics
            return k.width >= k.height ? k.horizontalFOV : k.verticalFOV
        }
    }

    struct Frame {
        var sample: CMSampleBuffer
        var pixels: CVPixelBuffer
        /// When the frame was taken: seconds since boot, the motion sensors' clock.
        var time: TimeInterval
        var lens: Lens
        /// The frame is turned to portrait; otherwise it is in the sensor's landscape orientation.
        var portrait: Bool
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "peak.camera", qos: .userInitiated)
    private let lock = NSLock()

    /// Field of view of the video format along its long side, degrees, for frames without
    /// an intrinsic matrix.
    private(set) var formatFieldOfView = 63.0
    private(set) var portraitFrames = false
    private(set) var measuresLens = false
    private var lastLens: Lens?
    /// Called on the camera queue for every frame. Must return quickly.
    var onFrame: ((Frame) -> Void)?

    /// The lens of the latest frame.
    var lens: Lens? {
        lock.lock()
        defer { lock.unlock() }
        return lastLens
    }

    /// Asks for camera access and starts the camera. `completion` runs on the main thread
    /// with whether the camera is running.
    func start(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.queue.async {
                if self.session.inputs.isEmpty { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async { completion(running) }
            }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        // The plain wide camera: a fixed lens, so the field of view stays known.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            // Stabilization crops and shifts the picture, which would throw off the geometry.
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            // Portrait frames if the lens can still be measured with them; the lens matters more.
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                portraitFrames = true
            }
            if !connection.isCameraIntrinsicMatrixDeliverySupported, portraitFrames {
                connection.videoRotationAngle = 0
                portraitFrames = false
                if !connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.videoRotationAngle = 90
                    portraitFrames = true
                }
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                measuresLens = true
            }
        }

        // Mountains are far away: keep the focus there, which also keeps the lens still.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .far }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        formatFieldOfView = Double(device.activeFormat.videoFieldOfView)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let lens = Self.lens(for: sampleBuffer, width: width, height: height, fallbackFOV: formatFieldOfView)
        lock.lock()
        lastLens = lens
        lock.unlock()
        // Frame times are on the session's clock; the motion sensors use the host clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMClockGetHostTimeClock()
        let time = CMTimeGetSeconds(CMSyncConvertTime(pts, from: session.synchronizationClock ?? host, to: host))
        onFrame?(Frame(sample: sampleBuffer, pixels: pixels, time: time, lens: lens, portrait: width < height))
    }

    /// The lens for a frame from its intrinsic matrix, when it has one that makes sense.
    /// The matrix may be given for the sensor's own orientation and resolution rather than
    /// the frame's, so it is turned and scaled to fit; a centered estimate from the
    /// format's field of view is the fallback.
    static func lens(for sample: CMSampleBuffer, width: Int, height: Int, fallbackFOV: Double) -> Lens {
        let estimate = Lens(intrinsics: CameraIntrinsics(width: width, height: height,
                                                         horizontalFOV: width >= height ? fallbackFOV : verticalToHorizontal(fallbackFOV, width, height)),
                            measured: false)
        guard let data = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
              data.count >= MemoryLayout<matrix_float3x3>.size else { return estimate }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        let fx = Double(m.columns.0.x), fy = Double(m.columns.1.y)
        let cx = Double(m.columns.2.x), cy = Double(m.columns.2.y)
        guard fx > 0, fy > 0, cx > 0, cy > 0 else { return estimate }
        // The frame's size in the matrix's orientation: the sensor's landscape one when the
        // frame was turned to portrait after the matrix was made.
        let turned = (cx > cy) != (width > height)
        let w = Double(turned ? height : width), h = Double(turned ? width : height)
        var k: CameraIntrinsics
        if abs(2 * cx / w - 1) < 0.08, abs(2 * cy / h - 1) < 0.08 {
            k = CameraIntrinsics(width: Int(w), height: Int(h), fx: fx, fy: fy, cx: cx, cy: cy)
        } else {
            // Given for another resolution: scale by the long side, assuming a centered lens.
            let s = max(w, h) / (2 * max(cx, cy))
            k = CameraIntrinsics(width: Int(w), height: Int(h), fx: fx * s, fy: fy * s, cx: w / 2, cy: h / 2)
        }
        if turned { k = k.rotatedClockwise() }
        let lens = Lens(intrinsics: k, measured: true)
        // Anything far from a phone's wide camera is a misreading.
        guard (40...90).contains(lens.fieldOfView), abs(k.fx / k.fy - 1) < 0.05,
              abs(k.cx / Double(width) - 0.5) < 0.1, abs(k.cy / Double(height) - 0.5) < 0.1 else { return estimate }
        return lens
    }

    /// Horizontal field of view of a portrait frame whose long side spans `fov` degrees.
    private static func verticalToHorizontal(_ fov: Double, _ width: Int, _ height: Int) -> Double {
        2 * atan(tan(fov * .pi / 360) * Double(width) / Double(height)) * 180 / .pi
    }
}

/// The compass and level corrections found by matching the skyline, degrees.
struct ViewCorrection: Equatable {
    var heading = 0.0
    var pitch = 0.0
    var roll = 0.0
}

/// Where the back camera looks, for a phone pose and the current corrections.
enum CameraGeometry {
    /// The image axes of a frame from the camera: turned to portrait, or in the sensor's
    /// landscape orientation, where the image's x runs toward the phone's bottom edge and
    /// its y toward the phone's left edge.
    static func axes(_ pose: MotionTracker.Pose, portrait: Bool = true)
        -> (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        portrait ? (pose.right, -pose.up, -pose.out) : (-pose.up, -pose.right, -pose.out)
    }

    /// The screen's axes for the interface orientation: which way its x and y run across
    /// the world, seen through the back camera.
    static func axes(_ pose: MotionTracker.Pose, orientation: UIInterfaceOrientation)
        -> (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        switch orientation {
        case .landscapeRight: return (-pose.up, -pose.right, -pose.out)   // top of the phone to the left
        case .landscapeLeft: return (pose.up, pose.right, -pose.out)      // top of the phone to the right
        case .portraitUpsideDown: return (-pose.right, pose.up, -pose.out)
        default: return (pose.right, -pose.up, -pose.out)
        }
    }

    /// Quarter turns clockwise from the sensor's landscape orientation to the interface's.
    static func quarterTurns(_ orientation: UIInterfaceOrientation) -> Int {
        switch orientation {
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 3
        case .landscapeLeft: return 2
        default: return 1
        }
    }

    static func attitude(_ axes: (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>),
                         correction: ViewCorrection) -> Attitude {
        var attitude = Attitude(right: axes.right, down: axes.down, forward: axes.forward)
        attitude.heading = normalizedAzimuth(attitude.heading + correction.heading)
        attitude.pitch += correction.pitch
        attitude.roll += correction.roll
        return attitude
    }

    /// The camera for a view of `size` points in `orientation` showing a frame with `lens`.
    static func screenCamera(pose: MotionTracker.Pose, lens: CameraFeed.Lens, portraitFrame: Bool,
                             orientation: UIInterfaceOrientation, size: CGSize, correction: ViewCorrection) -> Camera {
        var k = lens.intrinsics
        let turns = (quarterTurns(orientation) - (portraitFrame ? 1 : 0) + 4) % 4
        for _ in 0..<turns { k = k.rotatedClockwise() }
        return Camera(intrinsics: k.aspectFilled(width: Double(size.width), height: Double(size.height)),
                      attitude: attitude(axes(pose, orientation: orientation), correction: correction))
    }

    /// Compass heading of the middle of the view, without the skyline correction's level parts.
    static func heading(_ pose: MotionTracker.Pose, correction: ViewCorrection) -> Double {
        attitude(axes(pose, orientation: .portrait), correction: correction).heading
    }
}
