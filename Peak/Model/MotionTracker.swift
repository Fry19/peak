import CoreMotion
import Foundation

/// Which way the phone points, from the gyroscope, accelerometer and compass. The mountains
/// are kilometers away, so only the phone's rotation matters; this works instantly and
/// anywhere, unlike ARKit's world tracking, which needs nearby detail to track.
///
/// It starts referenced to magnetic north, which needs no permission, and switches to true
/// north once location access is granted (Core Motion needs the location to know the
/// declination). Until then, `declination` can be set from the compass heading. A watchdog
/// restarts the sensors if updates stop arriving.
final class MotionTracker: @unchecked Sendable {
    /// The phone's axes in east-north-up coordinates: right edge, top edge, and out of the
    /// screen (the back camera looks the other way).
    struct Pose {
        var right: SIMD3<Double>
        var up: SIMD3<Double>
        var out: SIMD3<Double>
    }

    struct Status {
        var trueNorth: Bool
        var updatesPerSecond: Double
        var secondsSinceUpdate: Double
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
    private var lastUpdate = Date.distantPast
    private var recentUpdates: [Date] = []
    private var useTrueNorth = false
    private var running = false
    private var watchdog: Timer?
    /// Magnetic declination in degrees (true = magnetic + declination), used while the
    /// sensors are referenced to magnetic north.
    private var magneticDeclination = 0.0

    /// Starts the sensors, or restarts them (for example with true north now available).
    /// Call on the main thread.
    func start(trueNorth: Bool) {
        guard manager.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let wantTrue = trueNorth && frames.contains(.xTrueNorthZVertical)
        if running, wantTrue == useTrueNorth, manager.isDeviceMotionActive { return }
        manager.stopDeviceMotionUpdates()
        lock.lock()
        useTrueNorth = wantTrue
        lastUpdate = Date()
        lock.unlock()
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 60
        let frame: CMAttitudeReferenceFrame = wantTrue ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, error in
            if let motion {
                self?.update(motion)
            } else if error != nil {
                // True north can fail without a location fix: fall back to magnetic north.
                DispatchQueue.main.async { self?.restart(trueNorth: false) }
            }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            if self.status.secondsSinceUpdate > 1.5 { self.restart(trueNorth: false) }
        }
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        manager.stopDeviceMotionUpdates()
    }

    private func restart(trueNorth: Bool) {
        guard running else { return }
        running = false
        start(trueNorth: trueNorth)
    }

    /// Magnetic declination from the compass (true heading minus magnetic heading).
    func setDeclination(_ degrees: Double) {
        lock.lock()
        magneticDeclination = degrees
        lock.unlock()
    }

    /// Degrees to add to the pose's heading to get true north.
    var northCorrection: Double {
        lock.lock()
        defer { lock.unlock() }
        return useTrueNorth ? 0 : magneticDeclination
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

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let rate = Double(recentUpdates.filter { now.timeIntervalSince($0) < 1 }.count)
        return Status(trueNorth: useTrueNorth, updatesPerSecond: rate, secondsSinceUpdate: now.timeIntervalSince(lastUpdate))
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
        let now = Date()
        lock.lock()
        latest = pose
        rotationRate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        lastUpdate = now
        recentUpdates.append(now)
        if recentUpdates.count > 90 { recentUpdates.removeFirst(recentUpdates.count - 90) }
        lock.unlock()
    }
}
