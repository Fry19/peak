import AVFoundation
import PeakCore
import UIKit

/// The back camera: a live preview, and frames for skyline matching.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "peak.camera", qos: .userInitiated)

    /// Horizontal field of view of the video format along its long side, degrees.
    private(set) var fieldOfView = 63.0
    /// Pixel size of the video format, long side first.
    private(set) var formatSize = (long: 1920.0, short: 1080.0)
    /// Frames arrive turned to portrait; otherwise in the sensor's landscape orientation.
    private(set) var portraitFrames = false
    /// Called on the camera queue for every frame. Must return quickly.
    var onFrame: ((CVPixelBuffer) -> Void)?

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
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                portraitFrames = true
            }
            // Stabilization crops and shifts the picture, which would throw off the geometry.
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }

        fieldOfView = Double(device.activeFormat.videoFieldOfView)
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        formatSize = (Double(max(dims.width, dims.height)), Double(min(dims.width, dims.height)))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame?(buffer) }
    }

    /// The pinhole camera seen on screen: the video fills a portrait view of `size` points
    /// (aspect fill), centered.
    func screenIntrinsics(for size: CGSize) -> CameraIntrinsics {
        let focalPixels = formatSize.long / 2 / tan(fieldOfView * .pi / 360)
        let scale = max(Double(size.width) / formatSize.short, Double(size.height) / formatSize.long)
        let f = focalPixels * scale
        return CameraIntrinsics(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                fx: f, fy: f, cx: Double(size.width) / 2, cy: Double(size.height) / 2)
    }
}

/// Where the back camera looks, for a phone pose and the current compass correction.
enum CameraGeometry {
    /// The camera's image axes for a frame shown in portrait (or delivered in the sensor's
    /// landscape orientation when `portrait` is false).
    static func axes(_ pose: MotionTracker.Pose, portrait: Bool = true)
        -> (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        let forward = -pose.out
        // Sensor landscape: the image's x runs toward the phone's bottom edge and its y
        // toward the phone's left edge.
        return portrait ? (pose.right, -pose.up, forward) : (-pose.up, -pose.right, forward)
    }

    /// The camera's attitude with the compass corrected by `correction` degrees.
    static func attitude(_ pose: MotionTracker.Pose, correction: Double) -> Attitude {
        let a = axes(pose)
        var attitude = Attitude(right: a.right, down: a.down, forward: a.forward)
        attitude.heading = normalizedAzimuth(attitude.heading + correction)
        return attitude
    }
}

/// The live camera picture.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
    }

    /// Freezes the picture on its last frame, or lets it run again.
    func setFrozen(_ frozen: Bool) {
        previewLayer.connection?.isEnabled = !frozen
    }
}
