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
        /// How many times the frame magnifies over the wide lens: the zoom of the telephoto
        /// that took it, or 1. The rest of the zoom is done on screen.
        var opticalZoom = 1.0
        /// The lens that took it, which its corrections are kept under (`LensSet.names`).
        var name = LensSet.wideName

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
    private var device: AVCaptureDevice?
    /// The lenses the camera can switch between: the wide and any telephotos. Only touched
    /// on `queue` after `configure`.
    private(set) var lenses = LensSet.wideOnly
    /// The camera's zoom where the wide lens takes over (above 1 when the camera starts at
    /// an ultra-wide), and the constituent lens behind each of `lenses`.
    private var wideFactor = 1.0
    private var constituents: [AVCaptureDevice] = []
    /// The lens in use (an index into `lenses`) and when it last changed, host clock.
    private var lensIndex = 0
    private var zoomChanged = 0.0
    private var wantedZoom = 1.0
    /// Called on the main thread with the lenses once the camera is set up.
    var onLenses: ((LensSet) -> Void)?
    /// Called on the camera queue for every frame. Must return quickly.
    var onFrame: ((Frame) -> Void)?
    /// Called on the main thread when the camera stops or comes back by itself (another app
    /// takes it, an error, the phone too hot).
    var onStateChange: ((AppStatus.Camera) -> Void)?
    /// Running is wanted (between `start` and `stop`); only touched on `queue`.
    private var wantsRunning = false
    private var pressureObservation: NSKeyValueObservation?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification,
                           object: session)
        center.addObserver(self, selector: #selector(runtimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    /// The lens of the latest frame.
    var lens: Lens? {
        lock.lock()
        defer { lock.unlock() }
        return lastLens
    }

    /// Asks for camera access and starts the camera. `completion` runs on the main thread
    /// with whether the camera is running, not allowed, or didn't start.
    func start(completion: @escaping (AppStatus.Camera) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else {
                DispatchQueue.main.async { completion(.denied) }
                return
            }
            self.queue.async {
                self.wantsRunning = true
                if self.session.inputs.isEmpty { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async { completion(running ? .running : .failed) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    private func report(_ state: AppStatus.Camera) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    @objc private func interrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let message: String?
        switch raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
        case .videoDeviceInUseByAnotherClient: message = "Another app is using the camera."
        case .videoDeviceNotAvailableWithMultipleForegroundApps: message = "The camera pauses while another app shares the screen."
        case .videoDeviceNotAvailableDueToSystemPressure: message = "The phone is too hot for the camera. It comes back as it cools."
        default: message = nil   // going to the background, which stops the camera anyway
        }
        if let message { report(.interrupted(message)) }
    }

    @objc private func interruptionEnded(_ note: Notification) {
        queue.async { [self] in
            if wantsRunning, !session.isRunning { session.startRunning() }
            report(session.isRunning || !wantsRunning ? .running : .failed)
        }
    }

    /// The session stopped on an error (most often the media services restarting): start it
    /// again, once, after a moment; if that doesn't work the pill offers to retry.
    @objc private func runtimeError(_ note: Notification) {
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard wantsRunning else { return }
            if !session.isRunning { session.startRunning() }
            report(session.isRunning ? .running : .failed)
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = Self.backCamera(), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        self.device = device
        configureLenses(device)
        // 1080p normally; 4K only while zoomed in (see `setZoom`), since every
        // frame of it costs memory bandwidth and power.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        self.output = output
        configureConnection()
        configureFocus()
        // When the phone heats up, ease off before the system stops the camera.
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            self?.queue.async {
                guard let self else { return }
                let throttled = level == .serious || level == .critical || level == .shutdown
                guard throttled != self.throttled else { return }
                self.throttled = throttled
                self.applyFormat()
            }
        }
    }

    /// With a telephoto, the camera that switches between it and the wide (wide and telephoto,
    /// or all three); the camera is only ever set to a lens's own zoom, so each frame is one
    /// lens's whole picture and its geometry stays known. Otherwise the plain wide camera.
    private static func backCamera() -> AVCaptureDevice? {
        for type in [AVCaptureDevice.DeviceType.builtInDualCamera, .builtInTripleCamera] {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back),
               d.constituentDevices.contains(where: { $0.deviceType == .builtInTelephotoCamera }) { return d }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// The lenses of a camera that switches between them, from where each takes over.
    private func configureLenses(_ device: AVCaptureDevice) {
        let parts = device.constituentDevices
        let factors = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
        guard let wide = parts.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
              factors.count == parts.count - 1 else { return }
        // Each constituent from the second takes over at its factor.
        func factor(_ i: Int) -> Double { i == 0 ? 1 : factors[i - 1] }
        wideFactor = factor(wide)
        let teles = (wide + 1..<parts.count).map { (zoom: factor($0) / wideFactor, name: parts[$0].deviceType.rawValue, device: parts[$0]) }
        lenses = LensSet(telephotos: teles.map { ($0.zoom, $0.name) })
        constituents = [parts[wide]] + teles.filter { $0.zoom > 1.2 }.sorted { $0.zoom < $1.zoom }.map(\.device)
        // Start at the wide (not an ultra-wide), or the lens for a zoom asked for already.
        applyLens(lenses.lens(for: wantedZoom, current: 0))
        let lenses = self.lenses
        DispatchQueue.main.async { [weak self] in self?.onLenses?(lenses) }
    }

    /// Zooms in `zoom` times over the wide lens: the camera moves to the longest lens that
    /// fits, and the picture on screen does the rest. 4K (when the phone can) while the
    /// on-screen part is large, so the picture stays sharp.
    func setZoom(_ zoom: Double) {
        queue.async { [self] in
            wantedZoom = zoom
            let next = lenses.lens(for: zoom, current: lensIndex)
            if next != lensIndex { applyLens(next) }
            let digital = zoom / lenses.zooms[lensIndex]
            // The gap between the two keeps it from switching back and forth.
            if digital >= 2, !wantsHighResolution {
                wantsHighResolution = true
                applyFormat()
            } else if digital <= 1.3, wantsHighResolution {
                wantsHighResolution = false
                applyFormat()
            }
        }
    }

    /// Sets the camera to a lens's own zoom. On `queue`.
    private func applyLens(_ index: Int) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let factor = CGFloat(lenses.zooms[index] * wideFactor)
        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(device.maxAvailableVideoZoomFactor, factor))
        device.unlockForConfiguration()
        lensIndex = index
        zoomChanged = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private var output: AVCaptureVideoDataOutput?
    private var highResolution = false
    private var wantsHighResolution = false
    /// The phone is hot: no 4K, and fewer frames a second.
    private var throttled = false
    /// Whether the frame rate set is the slow one.
    private var slowFrames = false

    /// Sets the resolution and frame rate for what's wanted and how hot the phone is. On `queue`.
    private func applyFormat() {
        guard !session.inputs.isEmpty else { return }
        let high = wantsHighResolution && !throttled
        var newFormat = false
        if high != highResolution {
            let preset: AVCaptureSession.Preset = high ? .hd4K3840x2160 : .hd1920x1080
            if session.canSetSessionPreset(preset) {
                highResolution = high
                newFormat = true
                session.beginConfiguration()
                session.sessionPreset = preset
                session.commitConfiguration()
                // A new format can reset these.
                configureConnection()
                configureFocus()
                if lenses.hasTelephoto { applyLens(lensIndex) }
            }
        }
        // 15 frames a second while hot; otherwise the format's own rate (an invalid time
        // puts it back). A new format starts at its own rate.
        guard throttled != slowFrames || (newFormat && throttled),
              let device, (try? device.lockForConfiguration()) != nil else { return }
        slowFrames = throttled
        if throttled, device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && 15 <= $0.maxFrameRate }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        } else {
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
        }
        device.unlockForConfiguration()
    }

    private func configureConnection() {
        guard let connection = output?.connection(with: .video) else { return }
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

    /// Mountains are far away: keep the focus there, which also keeps the lens still.
    private func configureFocus() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .far }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        // The format the preset picked, known once the session runs: the field of view at
        // the camera's zoom 1, which is the ultra-wide's on a camera that has one.
        if let device { formatFieldOfView = Self.narrowed(Double(device.activeFormat.videoFieldOfView), by: wideFactor) }
        // Frame times are on the session's clock; the motion sensors use the host clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMClockGetHostTimeClock()
        let time = CMTimeGetSeconds(CMSyncConvertTime(pts, from: session.synchronizationClock ?? host, to: host))
        let lens: Lens
        if lenses.hasTelephoto, let device {
            // Which lens the camera says it's on, and its zoom, as the frame arrives.
            let active = device.activePrimaryConstituent.flatMap { a in constituents.firstIndex { $0.uniqueID == a.uniqueID } } ?? lensIndex
            let reading = FrameLens.Reading(width: width, height: height,
                                            matrix: Self.matrix(for: sampleBuffer, width: width, height: height),
                                            zoom: Double(device.videoZoomFactor) / wideFactor, activeLens: active,
                                            sinceZoomChange: CMTimeGetSeconds(CMClockGetTime(host)) - zoomChanged)
            let resolved = FrameLens.resolve(reading, lenses: lenses, wideFOV: formatFieldOfView)
            lens = Lens(intrinsics: resolved.intrinsics, measured: resolved.measured, opticalZoom: resolved.opticalZoom,
                        name: lenses.names[resolved.lens])
        } else {
            lens = Self.lens(for: sampleBuffer, width: width, height: height, fallbackFOV: formatFieldOfView)
        }
        lock.lock()
        lastLens = lens
        lock.unlock()
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
        guard let k = matrix(for: sample, width: width, height: height) else { return estimate }
        let lens = Lens(intrinsics: k, measured: true)
        // Anything far from a phone's wide camera is a misreading.
        guard (40...90).contains(lens.fieldOfView), abs(k.fx / k.fy - 1) < 0.05,
              abs(k.cx / Double(width) - 0.5) < 0.1, abs(k.cy / Double(height) - 0.5) < 0.1 else { return estimate }
        return lens
    }

    /// The frame's intrinsic matrix turned and scaled to the frame, if it has one.
    static func matrix(for sample: CMSampleBuffer, width: Int, height: Int) -> CameraIntrinsics? {
        guard let data = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
              data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        let fx = Double(m.columns.0.x), fy = Double(m.columns.1.y)
        let cx = Double(m.columns.2.x), cy = Double(m.columns.2.y)
        guard fx > 0, fy > 0, cx > 0, cy > 0 else { return nil }
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
        return k
    }

    /// A field of view zoomed `factor` times.
    private static func narrowed(_ fov: Double, by factor: Double) -> Double {
        2 * atan(tan(fov * .pi / 360) / factor) * 180 / .pi
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

    /// The phone held sideways (landscape) rather than upright, from gravity.
    static func isSideways(_ pose: MotionTracker.Pose?) -> Bool {
        guard let pose else { return false }
        return abs(pose.right.z) > abs(pose.up.z)
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
