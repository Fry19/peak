import Foundation

extension Attitude {
    /// The attitude of a camera whose image axes point along `right` and `down`, looking
    /// along `forward` (unit vectors in east-north-up coordinates).
    public init(right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        let heading = normalizedAzimuth(atan2(forward.x, forward.y) * 180 / .pi)
        let pitch = asin(max(-1, min(1, forward.z))) * 180 / .pi
        let h = heading * .pi / 180
        let right0 = SIMD3(cos(h), -sin(h), 0)
        let down0 = cross(forward, right0)
        let roll = atan2((right * down0).sum(), (right * right0).sum()) * 180 / .pi
        self.init(heading: heading, pitch: pitch, roll: roll)
    }
}

extension RGBImage {
    /// The image turned a quarter turn clockwise.
    public func rotatedClockwise() -> RGBImage {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let w = width, h = height
        for y in 0..<h {
            for x in 0..<w {
                let src = 3 * (y * w + x)
                let dst = 3 * (x * h + (h - 1 - y))
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
            }
        }
        return RGBImage(width: h, height: w, pixels: out)
    }
}

/// A camera frame turned so that the sky is at the top, which is what skyline detection
/// expects. Phone cameras deliver frames in the sensor's landscape orientation whatever
/// way the phone is held.
public struct UprightFrame: Sendable {
    public var image: RGBImage
    public var camera: Camera

    /// `right` and `down` are the directions of the image's x and y axes in east-north-up
    /// coordinates, and `forward` the optical axis.
    public init(image: RGBImage, intrinsics: CameraIntrinsics,
                right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        var image = image
        var k = intrinsics
        var right = right, down = down
        // Quarter turns until the world's up points up the image.
        let up = SIMD3<Double>(0, 0, 1)
        var turns = 0
        var best = -Double.infinity
        var dir = ((up * right).sum(), (up * down).sum())
        for t in 0..<4 {
            if -dir.1 > best { best = -dir.1; turns = t }
            dir = (-dir.1, dir.0)   // a clockwise turn maps (dx, dy) to (−dy, dx)
        }
        for _ in 0..<turns {
            image = image.rotatedClockwise()
            // New pixel (x′, y′) is old (y′, H − x′).
            k = CameraIntrinsics(width: k.height, height: k.width, fx: k.fy, fy: k.fx,
                                 cx: Double(k.height) - k.cy, cy: k.cx)
            (right, down) = (-down, right)
        }
        self.image = image
        camera = Camera(intrinsics: k, attitude: Attitude(right: right, down: down, forward: forward))
    }
}
