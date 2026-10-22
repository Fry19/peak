import Dispatch
import Foundation

/// A short piece of ridgeline between two neighboring rays of a horizon profile.
public struct RidgeSegment: Sendable {
    public var azimuth0: Float
    public var elevation0: Float
    public var azimuth1: Float
    public var elevation1: Float
    /// Distance to the ridge, meters, for fading far ridges like haze.
    public var distance: Float
    public var isSkyline: Bool
}

extension HorizonProfile {
    /// The skyline and the ridges in front of it as line segments ready to draw. Ridge crests
    /// on neighboring rays are joined when they are about the same distance away and height.
    public func ridgeSegments(minDepthRatio: Float = 0.15, maxElevationStep: Float = 0.3) -> [RidgeSegment] {
        let crests = (0..<count).map { ridges(ofRay: $0, minDepthRatio: minDepthRatio) }
        var segments: [RidgeSegment] = []
        for i in 0..<count {
            let j = (i + 1) % count
            let a0 = Float(azimuth(ofRay: i)), a1 = a0 + Float(azimuthStep)
            // The skyline is continuous: always join it.
            segments.append(RidgeSegment(azimuth0: a0, elevation0: elevations[i], azimuth1: a1, elevation1: elevations[j],
                                         distance: min(distances[i], distances[j]), isSkyline: true))
            for p in crests[i].dropLast() {
                let match = crests[j].dropLast()
                    .filter { abs($0.distance - p.distance) < 0.12 * p.distance && abs($0.elevation - p.elevation) < maxElevationStep }
                    .min { abs($0.elevation - p.elevation) < abs($1.elevation - p.elevation) }
                if let q = match {
                    segments.append(RidgeSegment(azimuth0: a0, elevation0: p.elevation, azimuth1: a1, elevation1: q.elevation,
                                                 distance: p.distance, isSkyline: false))
                }
            }
        }
        return segments
    }
}

/// A summit that can be seen from the observer, with where it appears.
public struct VisiblePeak: Sendable, Identifiable {
    public var peak: Peak
    public var azimuth: Double
    /// Apparent elevation angle, with refraction, degrees.
    public var elevation: Double
    /// Distance along the ground (horizontal, as on a map), meters.
    public var distance: Double
    public var id: Int64 { peak.id }

    public init(peak: Peak, azimuth: Double, elevation: Double, distance: Double) {
        self.peak = peak
        self.azimuth = azimuth
        self.elevation = elevation
        self.distance = distance
    }
}

extension HorizonRenderer {
    /// The peaks within `maxDistance` that aren't hidden behind nearer terrain.
    public func visiblePeaks(_ peaks: [Peak], from observer: GeoPoint, maxDistance: Double,
                             settings: HorizonSettings = HorizonSettings()) -> [VisiblePeak] {
        let near = peaks.filter {
            let d = groundDistance(from: observer, to: $0.point)
            return d > 200 && d < maxDistance
        }
        var results = [VisiblePeak?](repeating: nil, count: near.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: near.count) { i in
                let v = visibility(of: near[i].point, from: observer, settings: settings)
                if v.isVisible {
                    out[i] = VisiblePeak(peak: near[i], azimuth: v.azimuth, elevation: v.elevation, distance: v.distance)
                }
            }
        }
        return results.compactMap { $0 }
    }
}

/// A point of a trail as seen from the observer.
public struct DrapedPoint: Sendable {
    public var azimuth: Float
    public var elevation: Float
    /// Horizontal distance from the observer, meters.
    public var distance: Float
    /// In sight, rather than behind nearer terrain.
    public var isInSight = true
    /// Which of the lines draped it lies on, and how far along that line, meters.
    public var line: Int32 = 0
    public var along: Float = 0
}

extension HorizonProfile {
    /// Whether a point on the terrain, seen at (azimuth, elevation) from `distance` meters
    /// away (along the ground), is in sight rather than behind nearer terrain: nothing
    /// nearer than the point rises above it. The terrain within 0.2% + 30 m of the point is
    /// its own slope and doesn't count, and the point may sit 15 m below what's in front.
    /// (A wider window skips the crest itself for points just behind it: at 1% + 30 m,
    /// points 100 m behind a summit 17 km away passed as in sight.)
    /// The nearer terrain's height is interpolated between the two rays either side.
    public func isInSight(azimuth: Double, elevation: Double, distance: Double) -> Bool {
        let x = normalizedAzimuth(azimuth) / settings.azimuthStep
        let i = Int(x), f = x - Double(i)
        let limit = Float(distance * 0.998 - 30)
        func blocking(_ ray: Int) -> Double {
            let points = envelope(ofRay: ray % count)
            // Last point nearer than the limit; the envelope is sorted by distance.
            var lo = points.startIndex, hi = points.endIndex
            while lo < hi {
                let mid = (lo + hi) / 2
                if points[mid].distance < limit { lo = mid + 1 } else { hi = mid }
            }
            return lo > points.startIndex ? Double(points[lo - 1].elevation) : -90
        }
        let nearer = blocking(i) * (1 - f) + blocking(i + 1) * f
        let slack = atan(15 / max(distance, 1)) * 180 / .pi
        return nearer <= elevation + slack
    }
}

extension HorizonRenderer {
    /// A trail laid on the terrain as seen from `observer`: the stretches in sight, as runs
    /// of points about `spacing` meters apart and `lift` meters above the ground. Stretches
    /// hidden behind nearer terrain are left out, or with `includeHidden` kept and marked
    /// not in sight, for seeing through the ridge. Stretches outside the terrain or within
    /// `minDistance` of the observer are always left out. Points within `clearDistance`
    /// count as in sight: that near, the terrain model is too coarse to say what hides them,
    /// and it's the trail you're standing on.
    public func drape(_ lines: [[LatLon]], from observer: GeoPoint, horizon: HorizonProfile,
                      spacing: Double = 15, lift: Double = 2, minDistance: Double = 30,
                      clearDistance: Double = 0, includeHidden: Bool = false) -> [[DrapedPoint]] {
        let frame = LocalFrame(origin: observer)
        let here = LatLon(observer.latitude, observer.longitude)
        var runs: [[DrapedPoint]] = []
        for (index, line) in lines.enumerated() {
            var run: [DrapedPoint] = []
            func endRun() {
                if run.count >= 2 { runs.append(run) }
                run = []
            }
            var along = 0.0
            var last: LatLon?
            for p in Trail.densify(line, spacing: spacing) {
                if let last { along += last.distance(to: p) }
                last = p
                let ground = terrain.height(latitude: p.latitude, longitude: p.longitude)
                let horizontal = here.distance(to: p)
                guard ground.isFinite, horizontal >= minDistance else { endRun(); continue }
                // Near points lie on the ground: lifted, they'd rise to eye level at your feet.
                let near = horizontal <= clearDistance
                let look = frame.look(at: GeoPoint(latitude: p.latitude, longitude: p.longitude, height: ground + (near ? min(lift, 0.3) : lift)),
                                      refraction: horizon.settings.refraction)
                let inSight = near ||
                    horizon.isInSight(azimuth: look.azimuth, elevation: look.elevation, distance: horizontal)
                guard inSight || includeHidden else {
                    endRun()
                    continue
                }
                run.append(DrapedPoint(azimuth: Float(look.azimuth), elevation: Float(look.elevation),
                                       distance: Float(horizontal), isInSight: inSight, line: Int32(index), along: Float(along)))
            }
            endRun()
        }
        return runs
    }
}
