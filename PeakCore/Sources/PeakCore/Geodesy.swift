import Foundation

/// A position on the WGS84 ellipsoid. Heights are meters above sea level, the same
/// datum as the DEM (Copernicus heights are EGM2008 orthometric heights).
public struct GeoPoint: Equatable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }
}

public enum WGS84 {
    public static let a = 6_378_137.0
    public static let f = 1 / 298.257223563
    public static let e2 = f * (2 - f)
    public static let e = e2.squareRoot()

    /// Radius of curvature in the prime vertical (east-west), N.
    public static func primeVerticalRadius(latitude phi: Double) -> Double {
        let s = sin(phi)
        return a / (1 - e2 * s * s).squareRoot()
    }

    /// Radius of curvature in the meridian (north-south), M.
    public static func meridionalRadius(latitude phi: Double) -> Double {
        let s = sin(phi)
        let w = 1 - e2 * s * s
        return a * (1 - e2) / (w * w.squareRoot())
    }

    /// Radius of curvature of the ellipsoid along a given azimuth (Euler's formula).
    public static func radius(latitude phi: Double, azimuth alpha: Double) -> Double {
        let m = meridionalRadius(latitude: phi)
        let n = primeVerticalRadius(latitude: phi)
        let c = cos(alpha), s = sin(alpha)
        return 1 / (c * c / m + s * s / n)
    }

    public static func ecef(_ p: GeoPoint) -> SIMD3<Double> {
        let phi = p.latitude * .pi / 180, lambda = p.longitude * .pi / 180
        let n = primeVerticalRadius(latitude: phi)
        let cp = cos(phi), sp = sin(phi)
        return SIMD3((n + p.height) * cp * cos(lambda),
                     (n + p.height) * cp * sin(lambda),
                     (n * (1 - e2) + p.height) * sp)
    }
}

/// East-north-up frame at an observer, for exact directions to other points.
public struct LocalFrame: Sendable {
    public let origin: GeoPoint
    let originECEF: SIMD3<Double>
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    let up: SIMD3<Double>

    public init(origin: GeoPoint) {
        self.origin = origin
        originECEF = WGS84.ecef(origin)
        let phi = origin.latitude * .pi / 180, lambda = origin.longitude * .pi / 180
        east = SIMD3(-sin(lambda), cos(lambda), 0)
        north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        up = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    public func enu(_ p: GeoPoint) -> SIMD3<Double> {
        let d = WGS84.ecef(p) - originECEF
        return SIMD3((d * east).sum(), (d * north).sum(), (d * up).sum())
    }

    /// Azimuth (degrees clockwise from true north), apparent elevation angle (degrees,
    /// including atmospheric refraction with coefficient `refraction`) and straight-line
    /// distance (meters) from the origin to `p`.
    public func look(at p: GeoPoint, refraction: Double = 0) -> (azimuth: Double, elevation: Double, distance: Double) {
        let v = enu(p)
        let horizontal = (v.x * v.x + v.y * v.y).squareRoot()
        let azimuth = normalizedAzimuth(atan2(v.x, v.y) * 180 / .pi)
        // Refraction bends the line of sight down by about k·θ/2, where θ is the angle
        // the two points subtend at the Earth's center, so the target looks higher.
        let r = WGS84.radius(latitude: origin.latitude * .pi / 180, azimuth: azimuth * .pi / 180)
        let elevation = (atan2(v.z, horizontal) + refraction * horizontal / (2 * r)) * 180 / .pi
        return (azimuth, elevation, (horizontal * horizontal + v.z * v.z).squareRoot())
    }
}

/// Maps the ellipsoid onto a sphere with conformal latitude. The map preserves angles,
/// so a great circle leaving the observer at azimuth α stays at azimuth α as seen from
/// the observer (to about 0.002° at 150 km). A plain sphere gets this wrong by up to 0.2°.
struct ConformalSphere {
    let chi0: Double
    /// Sphere radians per ellipsoid meter near the observer.
    let radiansPerMeter: Double

    init(latitude: Double) {
        let phi0 = latitude * .pi / 180
        chi0 = Self.conformalLatitude(phi0)
        // Scale of the map at the observer: k = a·cos χ / (N·cos φ).
        let k0 = WGS84.a * cos(chi0) / (WGS84.primeVerticalRadius(latitude: phi0) * cos(phi0))
        radiansPerMeter = k0 / WGS84.a
    }

    static func conformalLatitude(_ phi: Double) -> Double {
        let e = WGS84.e, s = sin(phi)
        return 2 * atan(tan(.pi / 4 + phi / 2) * pow((1 - e * s) / (1 + e * s), e / 2)) - .pi / 2
    }

    /// Inverse of `conformalLatitude` from sin χ (series, error below 1e-9 rad).
    @inline(__always)
    static func geodeticLatitude(sinChi s: Double) -> Double {
        let c = (1 - s * s).squareRoot()
        let s2 = 2 * s * c, c2 = 1 - 2 * s * s
        let s4 = 2 * s2 * c2, c4 = 1 - 2 * s2 * s2
        let s6 = s4 * c2 + c4 * s2
        return asin(s) + seriesA * s2 + seriesB * s4 + seriesC * s6
    }

    static let seriesA = WGS84.e2 / 2 + 5 * pow(WGS84.e2, 2) / 24 + pow(WGS84.e2, 3) / 12
    static let seriesB = 7 * pow(WGS84.e2, 2) / 48 + 29 * pow(WGS84.e2, 3) / 240
    static let seriesC = 7 * pow(WGS84.e2, 3) / 120
}

/// A great circle on the conformal sphere leaving the observer at a fixed azimuth.
/// Points along it are cos δ·O + sin δ·T, so a ray costs one asin and one atan2 per sample.
struct GreatCircleRay {
    let o: SIMD3<Double>
    let t: SIMD3<Double>
    let longitude0: Double

    init(sphere: ConformalSphere, longitude: Double, azimuth: Double) {
        let c = sphere.chi0, a = azimuth * .pi / 180
        // Unit vectors with longitude measured from the observer's meridian.
        o = SIMD3(cos(c), 0, sin(c))
        let northDir = SIMD3(-sin(c), 0, cos(c))
        let eastDir = SIMD3<Double>(0, 1, 0)
        t = cos(a) * northDir + sin(a) * eastDir
        longitude0 = longitude
    }

    /// Geodetic latitude and longitude in degrees at arc angle δ (given as cos δ, sin δ).
    @inline(__always)
    func point(cosDelta: Double, sinDelta: Double) -> (latitude: Double, longitude: Double) {
        let p = cosDelta * o + sinDelta * t
        let lat = ConformalSphere.geodeticLatitude(sinChi: max(-1, min(1, p.z)))
        let lon = longitude0 + atan2(p.y, p.x) * 180 / .pi
        return (lat * 180 / .pi, lon)
    }
}

/// The point `distance` meters from `origin` along `azimuth` degrees.
public func destination(from origin: GeoPoint, azimuth: Double, distance: Double) -> (latitude: Double, longitude: Double) {
    let sphere = ConformalSphere(latitude: origin.latitude)
    let ray = GreatCircleRay(sphere: sphere, longitude: origin.longitude, azimuth: azimuth)
    let delta = distance * sphere.radiansPerMeter
    return ray.point(cosDelta: cos(delta), sinDelta: sin(delta))
}

/// Distance along the ground from `origin` to `p`, meters: the inverse of `destination`,
/// and the distance the horizon renderer marches. Heights don't count.
public func groundDistance(from origin: GeoPoint, to p: GeoPoint) -> Double {
    let sphere = ConformalSphere(latitude: origin.latitude)
    let c1 = sphere.chi0, c2 = ConformalSphere.conformalLatitude(p.latitude * .pi / 180)
    let dl = (p.longitude - origin.longitude) * .pi / 180
    let a = sin((c2 - c1) / 2) * sin((c2 - c1) / 2) + cos(c1) * cos(c2) * sin(dl / 2) * sin(dl / 2)
    return 2 * asin(min(1, a.squareRoot())) / sphere.radiansPerMeter
}

/// Azimuth in [0, 360).
public func normalizedAzimuth(_ degrees: Double) -> Double {
    let r = degrees.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

/// Signed difference a − b in (−180, 180].
public func azimuthDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
    return d
}
