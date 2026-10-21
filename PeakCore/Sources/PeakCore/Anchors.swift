import Foundation

/// A summit marked by hand in a photo: where it is in the world and where it is in the image.
public struct Anchor: Codable, Sendable {
    public var name: String?
    public var latitude: Double
    public var longitude: Double
    /// Summit elevation from the peak database, meters.
    public var elevation: Double
    /// Pixel position of the summit in the full-size photo.
    public var x: Double
    public var y: Double

    public init(name: String? = nil, latitude: Double, longitude: Double, elevation: Double, x: Double, y: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.x = x
        self.y = y
    }
}

/// Works out the true camera attitude of a real photo from marked summits, to measure
/// heading error without a survey. One anchor fixes heading and pitch (roll stays as
/// given); two or more fix all three.
public enum AnchorSolver {
    public static func attitude(anchors: [Anchor], observer: GeoPoint, intrinsics k: CameraIntrinsics,
                                initial: Attitude, refraction: Double = 0.13) -> (attitude: Attitude, rmsPixels: Double)? {
        guard let first = anchors.first else { return nil }
        let frame = LocalFrame(origin: observer)
        let looks = anchors.map {
            frame.look(at: GeoPoint(latitude: $0.latitude, longitude: $0.longitude, height: $0.elevation), refraction: refraction)
        }
        // Start with the first anchor straight on its pixel, ignoring roll.
        var q = [
            looks[0].azimuth - atan((first.x - k.cx) / k.fx) * 180 / .pi,
            looks[0].elevation + atan((first.y - k.cy) / k.fy) * 180 / .pi,
            initial.roll,
        ]
        let free = anchors.count >= 2 ? 3 : 2

        func residuals(_ q: [Double]) -> [Double]? {
            let projector = Camera(intrinsics: k, attitude: Attitude(heading: q[0], pitch: q[1], roll: q[2])).projector
            var r: [Double] = []
            for (a, look) in zip(anchors, looks) {
                guard let p = projector.pixel(azimuth: look.azimuth, elevation: look.elevation) else { return nil }
                r.append(p.x - a.x)
                r.append(p.y - a.y)
            }
            return r
        }

        guard var r = residuals(q) else { return nil }
        for _ in 0..<50 {
            var jac = [[Double]]()
            for j in 0..<free {
                var qp = q, qm = q
                qp[j] += 1e-4
                qm[j] -= 1e-4
                guard let rp = residuals(qp), let rm = residuals(qm) else { return nil }
                jac.append(zip(rp, rm).map { ($0 - $1) / 2e-4 })
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: free), count: free)
            var g = [Double](repeating: 0, count: free)
            for i in r.indices {
                for j in 0..<free {
                    g[j] -= jac[j][i] * r[i]
                    for l in 0..<free { a[j][l] += jac[j][i] * jac[l][i] }
                }
            }
            for j in 0..<free { a[j][j] *= 1 + 1e-9 }
            guard let step = solve(a, g) else { break }
            for j in 0..<free { q[j] += step[j] }
            guard let next = residuals(q) else { return nil }
            r = next
            if step.map(abs).max()! < 1e-7 { break }
        }
        let rms = (r.reduce(0) { $0 + $1 * $1 } / Double(anchors.count)).squareRoot()
        return (Attitude(heading: normalizedAzimuth(q[0]), pitch: q[1], roll: q[2]), rms)
    }
}
