import Foundation

/// Pinhole camera intrinsics in pixels. Image x grows right, y grows down.
public struct CameraIntrinsics: Equatable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double

    public init(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double) {
        self.width = width
        self.height = height
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// Square pixels and a centered principal point, from the horizontal field of view in degrees.
    public init(width: Int, height: Int, horizontalFOV: Double) {
        let f = Double(width) / 2 / tan(horizontalFOV * .pi / 360)
        self.init(width: width, height: height, fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2)
    }

    public var horizontalFOV: Double { 2 * atan(Double(width) / 2 / fx) * 180 / .pi }
    public var verticalFOV: Double { 2 * atan(Double(height) / 2 / fy) * 180 / .pi }

    /// The same camera for the image resized to `width` × `height`.
    public func scaled(toWidth width: Int, height: Int) -> CameraIntrinsics {
        let sx = Double(width) / Double(self.width), sy = Double(height) / Double(self.height)
        return CameraIntrinsics(width: width, height: height, fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }

    /// The same camera for the image turned a quarter turn clockwise: new pixel (x′, y′)
    /// is old pixel (y′, height − x′).
    public func rotatedClockwise() -> CameraIntrinsics {
        CameraIntrinsics(width: height, height: width, fx: fy, fy: fx, cx: Double(height) - cy, cy: cx)
    }

    /// The same view magnified `factor` times about the image's center, as when the picture
    /// is zoomed in on screen.
    public func zoomed(by factor: Double) -> CameraIntrinsics {
        let mx = Double(width) / 2, my = Double(height) / 2
        return CameraIntrinsics(width: width, height: height, fx: fx * factor, fy: fy * factor,
                                cx: mx + (cx - mx) * factor, cy: my + (cy - my) * factor)
    }

    /// The camera for the image shown in a `width` × `height` view, scaled to fill it and
    /// centered (the parts that don't fit are cut off).
    public func aspectFilled(width: Double, height: Double) -> CameraIntrinsics {
        let s = max(width / Double(self.width), height / Double(self.height))
        return CameraIntrinsics(width: Int(width.rounded()), height: Int(height.rounded()), fx: fx * s, fy: fy * s,
                                cx: width / 2 + (cx - Double(self.width) / 2) * s,
                                cy: height / 2 + (cy - Double(self.height) / 2) * s)
    }
}

/// Which way the camera points, in degrees.
///
/// `heading` is the azimuth of the optical axis (clockwise from true north), `pitch` its
/// elevation above the horizon, and `roll` the rotation about the optical axis: positive
/// roll turns the camera clockwise as seen from behind, which tilts the horizon in the
/// image counterclockwise.
public struct Attitude: Equatable, Codable, Sendable {
    public var heading: Double
    public var pitch: Double
    public var roll: Double

    public init(heading: Double, pitch: Double = 0, roll: Double = 0) {
        self.heading = heading
        self.pitch = pitch
        self.roll = roll
    }

    /// Camera axes in east-north-up world coordinates: right (image +x), down (image +y),
    /// and forward (the optical axis).
    public var axes: (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        let h = heading * .pi / 180, p = pitch * .pi / 180, r = roll * .pi / 180
        let forward = SIMD3(sin(h) * cos(p), cos(h) * cos(p), sin(p))
        let right0 = SIMD3(cos(h), -sin(h), 0)
        let down0 = cross(forward, right0)
        let right = cos(r) * right0 + sin(r) * down0
        let down = -sin(r) * right0 + cos(r) * down0
        return (right, down, forward)
    }
}

public struct Camera: Equatable, Codable, Sendable {
    public var intrinsics: CameraIntrinsics
    public var attitude: Attitude

    public init(intrinsics: CameraIntrinsics, attitude: Attitude) {
        self.intrinsics = intrinsics
        self.attitude = attitude
    }

    /// Precomputed axes for projecting many points with one attitude.
    public struct Projector: Sendable {
        let k: CameraIntrinsics
        let right: SIMD3<Double>
        let down: SIMD3<Double>
        let forward: SIMD3<Double>

        public init(_ camera: Camera) {
            k = camera.intrinsics
            (right, down, forward) = camera.attitude.axes
        }

        /// Azimuth and elevation (degrees) of the direction through pixel (x, y).
        @inline(__always)
        public func look(x: Double, y: Double) -> (azimuth: Double, elevation: Double) {
            let w = right * ((x - k.cx) / k.fx) + down * ((y - k.cy) / k.fy) + forward
            let azimuth = atan2(w.x, w.y) * 180 / .pi
            let elevation = atan2(w.z, (w.x * w.x + w.y * w.y).squareRoot()) * 180 / .pi
            return (normalizedAzimuth(azimuth), elevation)
        }

        /// Pixel for a direction, or nil if it is behind the camera.
        @inline(__always)
        public func pixel(azimuth: Double, elevation: Double) -> (x: Double, y: Double)? {
            let a = azimuth * .pi / 180, e = elevation * .pi / 180
            let w = SIMD3(sin(a) * cos(e), cos(a) * cos(e), sin(e))
            let z = (w * forward).sum()
            guard z > 1e-6 else { return nil }
            return (k.cx + k.fx * (w * right).sum() / z, k.cy + k.fy * (w * down).sum() / z)
        }
    }

    public var projector: Projector { Projector(self) }
}

@inline(__always)
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
