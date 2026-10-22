import CoreMotion
import Foundation
import PeakCore

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

        /// Between two poses a short time apart, re-squared so the axes stay perpendicular.
        static func blend(_ a: Pose, _ b: Pose, _ f: Double) -> Pose {
            func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / max(1e-9, (v * v).sum().squareRoot()) }
            let out = unit(a.out + (b.out - a.out) * f)
            var up = a.up + (b.up - a.up) * f
            up = unit(up - out * (up * out).sum())
            let right = SIMD3(up.y * out.z - up.z * out.y, up.z * out.x - up.x * out.z, up.x * out.y - up.y * out.x)
            return Pose(right: right, up: up, out: out)
        }
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
    /// Recent poses with their sensor timestamps (seconds since boot, the same clock as
    /// camera frames), oldest first, and the back camera's heading by the gyroscope alone.
    private var history: [(time: TimeInterval, pose: Pose, gyroHeading: Double)] = []
    /// The phone's attitude by the gyroscope, kept level by gravity: its heading doesn't
    /// follow the magnetometer, so frames of a pan can be placed relative to each other
    /// even where the compass is pulled off (`SkylineStrip`).
    private var gyro: GyroAttitude?
    /// Counts restarts: gyroscope headings from different runs don't share a zero.
    private var gyroEpoch = 0
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
        // Readings in the old reference frame would mix two norths.
        history.removeAll()
        gyro = nil
        gyroEpoch += 1
        lock.unlock()
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 100
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

    /// The pose at `time` (seconds since boot), between the sensor readings around it. A
    /// camera frame reaches the screen a few hundredths of a second after it was taken, so
    /// drawing it with the pose of that moment keeps the lines on the mountains while the
    /// phone turns. Falls back to the latest pose for times far outside the readings.
    func pose(at time: TimeInterval) -> Pose? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = history.first, let last = history.last,
              time > first.time - 0.5, time < last.time + 0.5 else { return latest }
        if time <= first.time { return first.pose }
        if time >= last.time { return last.pose }
        // Readings are evenly spaced, so a binary search is plenty fast.
        var lo = 0, hi = history.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if history[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = history[lo], b = history[hi]
        let f = b.time > a.time ? (time - a.time) / (b.time - a.time) : 0
        return Pose.blend(a.pose, b.pose, max(0, min(1, f)))
    }

    /// The back camera's heading by the gyroscope alone at `time` (seconds since boot),
    /// from a zero that holds until the sensors restart (`epoch`); nil outside the readings.
    func gyroHeading(at time: TimeInterval) -> (heading: Double, epoch: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = history.first, let last = history.last, time >= first.time, time <= last.time + 0.05 else { return nil }
        if time >= last.time { return (last.gyroHeading, gyroEpoch) }
        var lo = 0, hi = history.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if history[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = history[lo], b = history[hi]
        let f = b.time > a.time ? max(0, min(1, (time - a.time) / (b.time - a.time))) : 0
        return (normalizedAzimuth(a.gyroHeading + f * azimuthDifference(b.gyroHeading, a.gyroHeading)), gyroEpoch)
    }

    /// Timestamp of the latest reading (seconds since boot).
    var latestTime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return history.last?.time
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
        if var g = gyro, let previous = history.last {
            g.rotate(rate: SIMD3(r.x, r.y, r.z), dt: motion.timestamp - previous.time)
            g.level(up: up, keeping: SIMD3(0, 0, -1))
            gyro = g
        } else {
            gyro = GyroAttitude(x: pose.right, y: pose.up, z: pose.out)
        }
        // The back camera looks along the phone's −z.
        history.append((motion.timestamp, pose, gyro?.heading(of: SIMD3(0, 0, -1)) ?? 0))
        if history.count > 150 { history.removeFirst(history.count - 150) }
        rotationRate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        lastUpdate = now
        recentUpdates.append(now)
        if recentUpdates.count > 150 { recentUpdates.removeFirst(recentUpdates.count - 150) }
        lock.unlock()
    }
}
