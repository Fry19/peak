import Dispatch
import Foundation

public struct HorizonSettings: Sendable {
    /// Spacing of the rays, in degrees of azimuth.
    public var azimuthStep = 0.1
    public var maxDistance = 150_000.0
    /// The first sample along each ray. Closer than this the DEM is too coarse to matter.
    public var minDistance = 20.0
    /// Step along the ray near the observer, and as a fraction of distance further out.
    public var nearStep = 15.0
    public var relativeStep = 0.001
    /// Atmospheric refraction coefficient k (0.13 is the standard atmosphere).
    public var refraction = 0.13

    public init() {}
}

/// What the terrain looks like from one point: for every azimuth, the elevation angle of
/// the skyline, plus the visible terrain below it as a depth envelope.
///
/// The envelope of a ray lists the terrain it sees from near to far, each entry higher than
/// the last. Any elevation angle below the skyline meets the terrain at the first entry
/// at or above it, which makes this a full depth map. An entry that starts a new segment
/// sits behind a ridge: the entry before it is that ridge's crest.
public struct HorizonProfile: Sendable {
    public struct EnvelopePoint: Sendable, Equatable {
        public var elevation: Float
        public var distance: Float
        /// True when this point is the first one seen past a nearer ridge.
        public var startsSegment: Bool
    }

    public let observer: GeoPoint
    public let settings: HorizonSettings
    /// Skyline elevation angle (degrees) for ray i, at azimuth i·azimuthStep.
    public let elevations: [Float]
    /// Distance to the skyline (meters) for ray i.
    public let distances: [Float]
    let envelopeStart: [Int]
    let envelope: [EnvelopePoint]

    public var count: Int { elevations.count }
    public var azimuthStep: Double { settings.azimuthStep }

    public func azimuth(ofRay i: Int) -> Double { Double(i) * settings.azimuthStep }

    public func envelope(ofRay i: Int) -> ArraySlice<EnvelopePoint> {
        envelope[envelopeStart[i]..<envelopeStart[i + 1]]
    }

    /// Skyline elevation angle at any azimuth, interpolated between rays.
    @inline(__always)
    public func elevation(atAzimuth azimuth: Double) -> Double {
        let x = normalizedAzimuth(azimuth) / settings.azimuthStep
        let i = Int(x)
        let f = x - Double(i)
        let a = Double(elevations[i % count]), b = Double(elevations[(i + 1) % count])
        return a + (b - a) * f
    }

    /// Distance to the terrain seen at (azimuth, elevation), or nil if that direction is sky.
    public func distance(atAzimuth azimuth: Double, elevation: Double) -> Double? {
        let i = Int((normalizedAzimuth(azimuth) / settings.azimuthStep).rounded()) % count
        let points = envelope(ofRay: i)
        guard let last = points.last, Double(last.elevation) >= elevation else { return nil }
        // First point at or above the requested angle; the envelope is sorted by elevation.
        var lo = points.startIndex, hi = points.endIndex - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if Double(points[mid].elevation) >= elevation { hi = mid } else { lo = mid + 1 }
        }
        return Double(points[lo].distance)
    }

    /// Ridge crests along ray i: points with farther terrain showing above them, plus the
    /// skyline itself. `minDepthRatio` is how much farther the terrain behind must be
    /// (0.15 means at least 15% farther) for a crest to count.
    public func ridges(ofRay i: Int, minDepthRatio: Float = 0.15) -> [EnvelopePoint] {
        let points = Array(envelope(ofRay: i))
        return points.indices.compactMap { j in
            guard j + 1 < points.count else { return points[j] }
            let next = points[j + 1]
            return next.startsSegment && next.distance > points[j].distance * (1 + minDepthRatio) ? points[j] : nil
        }
    }
}

public final class HorizonRenderer: @unchecked Sendable {
    public let terrain: Terrain

    public init(terrain: Terrain) {
        self.terrain = terrain
    }

    /// An observer standing on the terrain: the DEM height plus `eyeHeight`.
    /// The DEM height is used rather than GPS altitude, which is far less accurate.
    public func observer(latitude: Double, longitude: Double, eyeHeight: Double = 1.6) -> GeoPoint {
        let ground = terrain.height(latitude: latitude, longitude: longitude)
        return GeoPoint(latitude: latitude, longitude: longitude, height: (ground.isNaN ? 0 : ground) + eyeHeight)
    }

    /// Ray-marches the DEM in every direction from `observer`.
    public func render(from observer: GeoPoint, settings: HorizonSettings = HorizonSettings()) -> HorizonProfile {
        let rayCount = Int((360 / settings.azimuthStep).rounded())
        let march = March(observer: observer, settings: settings)
        var elevations = [Float](repeating: -90, count: rayCount)
        var distances = [Float](repeating: 0, count: rayCount)
        var perRay = [[HorizonProfile.EnvelopePoint]](repeating: [], count: rayCount)

        elevations.withUnsafeMutableBufferPointer { elev in
            distances.withUnsafeMutableBufferPointer { dist in
                perRay.withUnsafeMutableBufferPointer { env in
                    let chunk = 16
                    DispatchQueue.concurrentPerform(iterations: (rayCount + chunk - 1) / chunk) { block in
                        for i in block * chunk..<min(rayCount, (block + 1) * chunk) {
                            let azimuth = Double(i) * settings.azimuthStep
                            var points: [HorizonProfile.EnvelopePoint] = []
                            points.reserveCapacity(128)
                            march.run(terrain: terrain, azimuth: azimuth, upTo: settings.maxDistance, envelope: &points)
                            env[i] = points
                            if let last = points.last {
                                elev[i] = last.elevation
                                dist[i] = last.distance
                            }
                        }
                    }
                }
            }
        }

        var start = [Int](repeating: 0, count: rayCount + 1)
        for i in 0..<rayCount { start[i + 1] = start[i] + perRay[i].count }
        return HorizonProfile(observer: observer, settings: settings, elevations: elevations,
                              distances: distances, envelopeStart: start, envelope: perRay.flatMap { $0 })
    }

    /// Highest apparent elevation angle of the terrain along one azimuth, out to `distance`.
    public func maxElevation(from observer: GeoPoint, azimuth: Double, upTo distance: Double,
                             settings: HorizonSettings = HorizonSettings()) -> Double {
        var points: [HorizonProfile.EnvelopePoint] = []
        March(observer: observer, settings: settings).run(terrain: terrain, azimuth: azimuth, upTo: distance, envelope: &points)
        return Double(points.last?.elevation ?? -90)
    }

    public struct Visibility: Sendable {
        public var azimuth: Double
        public var elevation: Double
        /// Distance along the ground (horizontal, as on a map), meters.
        public var distance: Double
        /// How far the target clears the terrain in front of it, in degrees (negative: hidden).
        public var clearance: Double
        public var isVisible: Bool
    }

    /// Line of sight from `observer` to a summit. Peak heights come from the peak database,
    /// and DEM summits are often lower or slightly off, so the terrain within `summitRadius`
    /// of the target is ignored and the target may sit up to `tolerance` meters below it.
    public func visibility(of target: GeoPoint, from observer: GeoPoint,
                           summitRadius: Double = 250, tolerance: Double = 15,
                           settings: HorizonSettings = HorizonSettings()) -> Visibility {
        let look = LocalFrame(origin: observer).look(at: target, refraction: settings.refraction)
        // The march measures distance along the ground. The straight-line distance is longer
        // for a summit far above or below, and would let terrain behind the summit block it.
        let ground = groundDistance(from: observer, to: target)
        let blocking = maxElevation(from: observer, azimuth: look.azimuth,
                                    upTo: max(0, ground - summitRadius), settings: settings)
        let slack = atan(tolerance / max(look.distance, 1)) * 180 / .pi
        let clearance = look.elevation - blocking
        return Visibility(azimuth: look.azimuth, elevation: look.elevation, distance: ground,
                          clearance: clearance, isVisible: clearance + slack >= 0)
    }
}

/// The parts of a ray march that are the same for every azimuth.
struct March {
    let observer: GeoPoint
    let settings: HorizonSettings
    let sphere: ConformalSphere
    let samples: [Double]
    let cosDelta: [Double]
    let sinDelta: [Double]

    init(observer: GeoPoint, settings: HorizonSettings) {
        self.observer = observer
        self.settings = settings
        let sphere = ConformalSphere(latitude: observer.latitude)
        self.sphere = sphere
        var d = settings.minDistance
        var samples: [Double] = []
        while d <= settings.maxDistance {
            samples.append(d)
            d += max(settings.nearStep, settings.relativeStep * d)
        }
        self.samples = samples
        let radiansPerMeter = sphere.radiansPerMeter
        cosDelta = samples.map { cos($0 * radiansPerMeter) }
        sinDelta = samples.map { sin($0 * radiansPerMeter) }
    }

    /// Marches one ray, appending every sample that rises above everything nearer.
    /// Consecutive visible samples are thinned to steps of `elevationResolution` degrees,
    /// but the last one of each visible stretch (a crest) is always kept.
    func run(terrain: Terrain, azimuth: Double, upTo maxDistance: Double,
             envelope: inout [HorizonProfile.EnvelopePoint]) {
        let ray = GreatCircleRay(sphere: sphere, longitude: observer.longitude, azimuth: azimuth)
        // Refraction as a larger effective Earth: R' = R / (1 − k).
        let radius = WGS84.radius(latitude: observer.latitude * .pi / 180, azimuth: azimuth * .pi / 180)
        let effectiveRadius = radius / (1 - settings.refraction)
        let observerRadius = effectiveRadius + observer.height
        let elevationResolution = 0.01

        var best = -Double.infinity            // tan of the highest elevation angle so far
        var lastKept = -Double.infinity        // elevation (degrees) of the last kept point
        var pending: (Double, Double)? = nil   // newest visible sample not yet kept
        var visible = false
        var newSegment = false

        for (k, d) in samples.enumerated() {
            if d > maxDistance { break }
            let p = ray.point(cosDelta: cosDelta[k], sinDelta: sinDelta[k])
            let h = terrain.height(latitude: p.latitude, longitude: p.longitude)
            if h.isNaN { break }
            // Elevation angle on the effective sphere, with θ = d / R'.
            let theta = d / effectiveRadius
            let t2 = theta * theta
            let cosT = 1 - t2 / 2 + t2 * t2 / 24
            let sinT = theta * (1 - t2 / 6 + t2 * t2 / 120)
            let r = effectiveRadius + h
            let tanElevation = (cosT * r - observerRadius) / (sinT * r)

            if tanElevation > best {
                best = tanElevation
                let e = atan(tanElevation) * 180 / .pi
                // Seen again after a hidden stretch: this point is behind a ridge.
                if !visible, !envelope.isEmpty { newSegment = true }
                if newSegment || envelope.isEmpty || e - lastKept >= elevationResolution {
                    envelope.append(.init(elevation: Float(e), distance: Float(d), startsSegment: newSegment))
                    lastKept = e
                    newSegment = false
                    pending = nil
                } else {
                    pending = (e, d)
                }
                visible = true
            } else {
                // Just went out of sight: the last visible sample is a crest, keep it.
                if visible, let (e, dist) = pending {
                    envelope.append(.init(elevation: Float(e), distance: Float(dist), startsSegment: false))
                    lastKept = e
                    pending = nil
                }
                visible = false
            }
        }
        if let (e, dist) = pending {
            envelope.append(.init(elevation: Float(e), distance: Float(dist), startsSegment: false))
        }
    }
}
