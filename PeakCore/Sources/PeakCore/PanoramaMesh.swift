import Dispatch
import Foundation

/// How a `PanoramaMesh` samples the terrain.
public struct PanoramaMeshSettings: Sendable {
    /// Degrees between the rays out from the eye.
    public var azimuthStep = 0.5
    /// Distance of the first ring, meters; inside it a fan closes the hole.
    public var minDistance = 20.0
    public var maxDistance = 80_000.0
    /// Rings are `nearStep` meters apart near the eye and `relativeStep` of their distance
    /// beyond: about square cells where the azimuth step is as wide.
    public var nearStep = 15.0
    public var relativeStep = 0.01
    /// Atmospheric refraction, as for the horizon (`HorizonSettings.refraction`).
    public var refraction = 0.13
    /// The light the slopes are shaded by: the usual north-west, but low, 30° up, so the
    /// relief shows seen from the side as well as from above.
    public var lightAzimuth = 315.0
    public var lightAltitude = 30.0
    /// How bright ground facing away from the light still is, 0 to 1.
    public var ambient: Float = 0.3

    public init() {}
}

/// The terrain around a viewpoint as triangles, for drawing it in 3D from there or from
/// straight above it: a polar grid of rays out from the eye, with rings close together near
/// it and farther apart away from it, so cells look about the same size from the eye.
///
/// Each vertex is placed in the direction the horizon renderer sees that point (the same
/// effective sphere for the Earth's curvature and refraction), so the skyline and labels
/// drawn over the mesh sit on it. Seen from higher up, a camera raised by the lift sees
/// those directions to within about the eye height over the Earth's radius.
public struct PanoramaMesh: Sendable {
    /// Per vertex: x east, y north and z up in meters from the eye, and in w how brightly
    /// the ground there is lit, 0 to 1. The last vertex is the ground under the eye.
    public var vertices: [SIMD4<Float>]
    /// Triangles, three vertex indices each. Triangles touching ground without terrain are
    /// left out.
    public var indices: [UInt32]
    /// Distance of each ring along the ground, meters.
    public let rings: [Double]
    public let rays: Int
    public let settings: PanoramaMeshSettings

    /// The vertex of ray `ray` (azimuth ray × azimuthStep) on ring `ring`.
    public func vertex(ray: Int, ring: Int) -> SIMD4<Float> {
        vertices[ray * rings.count + ring]
    }

    /// Samples `terrain` around `observer` (its height is the eye's).
    public static func build(terrain: Terrain, from observer: GeoPoint, settings: PanoramaMeshSettings = .init()) -> PanoramaMesh {
        var rings: [Double] = []
        var d = settings.minDistance
        while d <= settings.maxDistance {
            rings.append(d)
            d += max(settings.nearStep, settings.relativeStep * d)
        }
        let rays = Int((360 / settings.azimuthStep).rounded())
        let n = rings.count
        let sphere = ConformalSphere(latitude: observer.latitude)
        let cosDelta = rings.map { cos($0 * sphere.radiansPerMeter) }
        let sinDelta = rings.map { sin($0 * sphere.radiansPerMeter) }
        let az = settings.lightAzimuth * .pi / 180, alt = settings.lightAltitude * .pi / 180
        let light = SIMD3(sin(az) * cos(alt), cos(az) * cos(alt), sin(alt))

        // Heights first, then positions and shading from them.
        var heights = [Float](repeating: .nan, count: rays * n)
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rays) { i in
                let ray = GreatCircleRay(sphere: sphere, longitude: observer.longitude, azimuth: Double(i) * settings.azimuthStep)
                for j in 0..<n {
                    let p = ray.point(cosDelta: cosDelta[j], sinDelta: sinDelta[j])
                    out[i * n + j] = Float(terrain.height(latitude: p.latitude, longitude: p.longitude))
                }
            }
        }
        let below = terrain.height(latitude: observer.latitude, longitude: observer.longitude)

        var vertices = [SIMD4<Float>](repeating: .zero, count: rays * n + 1)
        vertices.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rays) { i in
                let a = Double(i) * settings.azimuthStep * .pi / 180
                let east = sin(a), north = cos(a)
                // Refraction as a larger effective Earth, R' = R / (1 − k), as in the march.
                let radius = WGS84.radius(latitude: observer.latitude * .pi / 180, azimuth: a) / (1 - settings.refraction)
                let eye = radius + observer.height
                let prev = (i + rays - 1) % rays, next = (i + 1) % rays
                for j in 0..<n {
                    let h = Double(heights[i * n + j])
                    let d = rings[j]
                    // The elevation angle on the effective sphere, θ = d / R'.
                    let theta = d / radius
                    let r = radius + (h.isFinite ? h : 0)
                    let up = d * (cos(theta) * r - eye) / (sin(theta) * r)
                    // Shading from the true heights of the neighbors around, across the ray
                    // and along it; a missing neighbor takes this vertex's height.
                    func ground(_ ii: Int, _ jj: Int) -> SIMD3<Double> {
                        let aa = Double(ii) * settings.azimuthStep * .pi / 180, dd = rings[jj]
                        let hh = Double(heights[ii * n + jj])
                        return SIMD3(dd * sin(aa), dd * cos(aa), hh.isFinite ? hh : (h.isFinite ? h : 0))
                    }
                    let across = ground(next, j) - ground(prev, j)
                    let along = ground(i, min(n - 1, j + 1)) - ground(i, max(0, j - 1))
                    var normal = SIMD3(along.y * across.z - along.z * across.y, along.z * across.x - along.x * across.z,
                                       along.x * across.y - along.y * across.x)
                    if normal.z < 0 { normal = -normal }
                    let length = (normal * normal).sum().squareRoot()
                    let lit = length > 0 ? max(0, (normal * light).sum() / length) : light.z
                    let shade = settings.ambient + (1 - settings.ambient) * Float(lit)
                    out[i * n + j] = SIMD4(Float(d * east), Float(d * north), Float(up), shade)
                }
            }
        }
        let center = rays * n
        vertices[center] = SIMD4(0, 0, Float((below.isFinite ? below : 0) - observer.height),
                                 settings.ambient + (1 - settings.ambient) * Float(light.z))

        var indices: [UInt32] = []
        indices.reserveCapacity(rays * n * 6 + rays * 3)
        func has(_ k: Int) -> Bool { k == center ? below.isFinite : heights[k].isFinite }
        func triangle(_ a: Int, _ b: Int, _ c: Int) {
            guard has(a), has(b), has(c) else { return }
            indices.append(UInt32(a))
            indices.append(UInt32(b))
            indices.append(UInt32(c))
        }
        for i in 0..<rays {
            let next = (i + 1) % rays
            triangle(center, i * n, next * n)
            for j in 0..<(n - 1) {
                let a = i * n + j, b = next * n + j
                triangle(a, b, a + 1)
                triangle(b, b + 1, a + 1)
            }
        }
        return PanoramaMesh(vertices: vertices, indices: indices, rings: rings, rays: rays, settings: settings)
    }
}
