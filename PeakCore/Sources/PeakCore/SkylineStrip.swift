import Foundation

/// The skylines of the last few seconds of frames, matched together as the phone pans. A
/// view through a window or between roofs may show too little skyline in any one frame to
/// pin the heading down; turning the phone shows more of it, and the gyroscope knows how
/// far it turned between frames, so the pieces can be matched as one wider skyline with
/// one heading correction (`SkylineAligner.align(_:horizon:settings:)`).
///
/// The fused compass heading can't place the frames relative to each other: indoors, where
/// this is needed, the magnetometer is off by degrees and differently in each direction.
/// Each frame instead carries its heading by the gyroscope alone (`GyroAttitude`), which
/// drifts slowly; frames are kept only for `maxAge` seconds so the drift stays small.
///
/// Every frame counts once: after any accepted match, single or stitched, the frames it used
/// must be dropped (`removeAll`), so the next match (which `HeadingLock` may take as
/// confirmation) comes from frames of its own.
public struct SkylineStrip: Sendable {
    public struct Frame: Sendable {
        /// The skyline as detected, and the camera it was seen with (before correction: the
        /// sensors plus the corrections in use, as the frame was matched alone).
        public var skyline: Skyline
        public var camera: Camera
        /// Seconds, any clock that runs steadily.
        public var time: Double
        /// The camera's heading by the gyroscope alone, from any fixed zero, degrees.
        public var gyroHeading: Double
        /// Where the frame was taken (where the horizon was rendered for).
        public var position: GeoPoint
        /// What took it: lens name and the way the phone was held. Corrections and level are
        /// kept per lens and per way of holding, so frames from different ones don't mix.
        public var lens: String

        public init(skyline: Skyline, camera: Camera, time: Double, gyroHeading: Double, position: GeoPoint, lens: String) {
            self.skyline = skyline
            self.camera = camera
            self.time = time
            self.gyroHeading = gyroHeading
            self.position = position
            self.lens = lens
        }
    }

    /// Frames older than this (seconds before the newest) are dropped: the gyroscope's
    /// heading drifts, so the oldest frame's place relative to the newest grows less sure.
    public var maxAge = 8.0
    public var maxFrames = 5
    /// Frames taken further than this from the newest are dropped, meters: the horizon is
    /// rendered for one place.
    public var maxTranslation = 20.0
    /// A newer frame looking within this share of the field of view of an older one
    /// replaces it: the same skyline again adds nothing, and the strip stays wide.
    public var sameView = 0.05
    /// Frames are matched together only once they reach this share of the field of view
    /// further than the newest frame alone.
    public var minWidening = 0.25

    /// Newest first.
    public private(set) var frames: [Frame] = []

    public init() {}

    /// Adds the newest frame, dropping the ones it can't be matched with.
    public mutating func add(_ frame: Frame) {
        let k = frame.camera.intrinsics
        let fov = k.horizontalFOV
        // Per-frame lens data wobbles a little with focus; a zoom changes it by far more.
        frames = frames.filter { old in
            let o = old.camera.intrinsics
            return old.lens == frame.lens && o.width == k.width && o.height == k.height && abs(o.fx / k.fx - 1) < 0.01
                && old.time <= frame.time && frame.time - old.time <= maxAge
                && groundDistance(from: frame.position, to: old.position) <= maxTranslation
                && abs(azimuthDifference(old.gyroHeading, frame.gyroHeading)) > sameView * fov
        }
        frames.insert(frame, at: 0)
        if frames.count > maxFrames { frames.removeLast(frames.count - maxFrames) }
    }

    public mutating func removeAll() {
        frames.removeAll()
    }

    /// How far the frames' views reach beyond the newest's, degrees of heading.
    public var widening: Double {
        guard let newest = frames.first else { return 0 }
        let offsets = frames.map { azimuthDifference($0.gyroHeading, newest.gyroHeading) }
        return (offsets.max() ?? 0) - (offsets.min() ?? 0)
    }

    /// The frames as views to match together, newest first, every heading moved under the
    /// newest's north by the gyroscope's turn since: nil until there are two frames that
    /// reach `minWidening` further than the newest.
    public var views: [AlignmentView]? {
        guard frames.count >= 2, let newest = frames.first,
              widening >= minWidening * newest.camera.intrinsics.horizontalFOV else { return nil }
        return frames.map { f in
            var camera = f.camera
            camera.attitude.heading = normalizedAzimuth(newest.camera.attitude.heading
                                                        + azimuthDifference(f.gyroHeading, newest.gyroHeading))
            return AlignmentView(skyline: f.skyline, camera: camera)
        }
    }

    /// Matches the frames together (see `views`); the result is for the newest frame, as
    /// if it had been matched alone.
    public func match(horizon: HorizonProfile, settings: AlignmentSettings) -> AlignmentResult? {
        views.map { SkylineAligner.align($0, horizon: horizon, settings: settings) }
    }
}

/// Which way the phone points by its gyroscope, kept level by gravity: its heading turns
/// only with the gyroscope, so a magnetometer pulled off by steel nearby doesn't move it,
/// at the cost of a slow drift. Axes are the phone's x, y and z in east-north-up.
public struct GyroAttitude: Sendable {
    public private(set) var x: SIMD3<Double>
    public private(set) var y: SIMD3<Double>
    public private(set) var z: SIMD3<Double>

    /// Starts from a pose (say the fused one): only turns from here on count.
    public init(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Turns by the gyroscope's rotation rate (radians per second, about the phone's own
    /// axes) for `dt` seconds.
    public mutating func rotate(rate: SIMD3<Double>, dt: Double) {
        let w = rate.x * x + rate.y * y + rate.z * z
        let speed = (w * w).sum().squareRoot()
        guard speed > 0, dt > 0 else { return }
        turn(about: w / speed, angle: speed * dt)
    }

    /// Tips the axes so that up is where gravity says (`up` is the world's up in the phone's
    /// own axes), keeping the heading of `direction` (in the phone's axes, say the camera's
    /// −z): tipping about a level axis turns a tilted direction's heading a little, which is
    /// turned back about the vertical, so only the gyroscope moves it.
    public mutating func level(up: SIMD3<Double>, keeping direction: SIMD3<Double>) {
        let n = (up * up).sum().squareRoot()
        guard n > 0 else { return }
        let u = up / n
        let v = u.x * x + u.y * y + u.z * z
        let axis = cross(v, SIMD3(0, 0, 1))
        let s = (axis * axis).sum().squareRoot()
        guard s > 1e-12 else { return }
        let w = direction.x * x + direction.y * y + direction.z * z
        let before = heading(of: direction)
        turn(about: axis / s, angle: atan2(s, v.z))
        // Straight up or down, a direction has no heading to keep.
        guard abs(w.z) < 0.99 * (w * w).sum().squareRoot() else { return }
        turn(about: SIMD3(0, 0, 1), angle: azimuthDifference(heading(of: direction), before) * .pi / 180)
    }

    /// Heading of a direction given in the phone's axes (the back camera looks along −z),
    /// degrees clockwise from the zero it started from.
    public func heading(of v: SIMD3<Double>) -> Double {
        let w = v.x * x + v.y * y + v.z * z
        return normalizedAzimuth(atan2(w.x, w.y) * 180 / .pi)
    }

    private mutating func turn(about k: SIMD3<Double>, angle: Double) {
        let c = cos(angle), s = sin(angle)
        func rotated(_ v: SIMD3<Double>) -> SIMD3<Double> {
            v * c + cross(k, v) * s + k * ((k * v).sum() * (1 - c))
        }
        // Re-squared so rounding doesn't skew the axes over many steps.
        let nz = rotated(z), ny = rotated(y)
        z = nz / (nz * nz).sum().squareRoot()
        var y = ny - z * (ny * z).sum()
        y /= (y * y).sum().squareRoot()
        self.y = y
        x = cross(y, z)
    }
}
