import CoreMotion
import Foundation

/// Which way the phone points, from the gyroscope, accelerometer and compass, referenced to
/// true north. The mountains are kilometers away, so only the phone's rotation matters;
/// this works instantly and anywhere, unlike ARKit's world tracking, which needs nearby
/// detail to track and struggles in open landscapes.
final class MotionTracker: @unchecked Sendable {
    /// The phone's axes in east-north-up coordinates: right edge, top edge, and out of the
    /// screen (the back camera looks the other way).
    struct Pose {
        var right: SIMD3<Double>
        var up: SIMD3<Double>
        var out: SIMD3<Double>
    }

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let lock = NSLock()
    private var latest: Pose?
    private var rotationRate = 0.0

    /// True north needs location services; without it the compass gives magnetic north,
    /// and skyline matching corrects the difference.
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            if let motion { self?.update(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    var pose: Pose? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Held still enough for a sharp camera frame and a matching attitude.
    var isSteady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest != nil && rotationRate < 0.25
    }

    private func update(_ motion: CMDeviceMotion) {
        let m = motion.attitude.rotationMatrix
        // The matrix relates the phone's axes to the reference frame (x north, y west, z up).
        // Rather than trust one reading of it, take whichever of rows or columns agrees with
        // gravity, which is reported in the phone's own coordinates.
        let rows = [SIMD3(m.m11, m.m12, m.m13), SIMD3(m.m21, m.m22, m.m23), SIMD3(m.m31, m.m32, m.m33)]
        let cols = [SIMD3(m.m11, m.m21, m.m31), SIMD3(m.m12, m.m22, m.m32), SIMD3(m.m13, m.m23, m.m33)]
        let up = SIMD3(-motion.gravity.x, -motion.gravity.y, -motion.gravity.z)
        func mismatch(_ axes: [SIMD3<Double>]) -> Double {
            abs(axes[0].z - up.x) + abs(axes[1].z - up.y) + abs(axes[2].z - up.z)
        }
        let axes = mismatch(rows) <= mismatch(cols) ? rows : cols
        func enu(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(-v.y, v.x, v.z) }
        let pose = Pose(right: enu(axes[0]), up: enu(axes[1]), out: enu(axes[2]))
        let r = motion.rotationRate
        lock.lock()
        latest = pose
        rotationRate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        lock.unlock()
    }
}
