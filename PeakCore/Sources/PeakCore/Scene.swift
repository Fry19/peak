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
    public var distance: Double
    public var id: Int64 { peak.id }
}

extension HorizonRenderer {
    /// The peaks within `maxDistance` that aren't hidden behind nearer terrain.
    public func visiblePeaks(_ peaks: [Peak], from observer: GeoPoint, maxDistance: Double,
                             settings: HorizonSettings = HorizonSettings()) -> [VisiblePeak] {
        let frame = LocalFrame(origin: observer)
        let near = peaks.filter {
            let d = frame.look(at: $0.point).distance
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
}

extension HorizonProfile {
    /// Whether a point on the terrain, seen at (azimuth, elevation) from `distance` meters
    /// away, is in sight rather than behind nearer terrain. The depth map gives the distance
    /// to the first terrain in that direction; for a visible point that is the point itself.
    public func isInSight(azimuth: Double, elevation: Double, distance: Double) -> Bool {
        guard let hit = self.distance(atAzimuth: azimuth, elevation: elevation) else { return true }
        return hit >= distance * 0.97 - 30
    }
}

extension HorizonRenderer {
    /// A trail laid on the terrain as seen from `observer`: the stretches in sight, as runs
    /// of points about `spacing` meters apart and `lift` meters above the ground. Stretches
    /// hidden behind nearer terrain are left out, or with `includeHidden` kept and marked
    /// not in sight, for seeing through the ridge. Stretches outside the terrain or within
    /// `minDistance` of the observer are always left out.
    public func drape(_ lines: [[LatLon]], from observer: GeoPoint, horizon: HorizonProfile,
                      spacing: Double = 15, lift: Double = 2, minDistance: Double = 30,
                      includeHidden: Bool = false) -> [[DrapedPoint]] {
        let frame = LocalFrame(origin: observer)
        let here = LatLon(observer.latitude, observer.longitude)
        var runs: [[DrapedPoint]] = []
        for line in lines {
            var run: [DrapedPoint] = []
            func endRun() {
                if run.count >= 2 { runs.append(run) }
                run = []
            }
            for p in Trail.densify(line, spacing: spacing) {
                let ground = terrain.height(latitude: p.latitude, longitude: p.longitude)
                let horizontal = here.distance(to: p)
                guard ground.isFinite, horizontal >= minDistance else { endRun(); continue }
                let look = frame.look(at: GeoPoint(latitude: p.latitude, longitude: p.longitude, height: ground + lift),
                                      refraction: horizon.settings.refraction)
                let inSight = horizon.isInSight(azimuth: look.azimuth, elevation: look.elevation, distance: horizontal)
                guard inSight || includeHidden else {
                    endRun()
                    continue
                }
                run.append(DrapedPoint(azimuth: Float(look.azimuth), elevation: Float(look.elevation),
                                       distance: Float(horizontal), isInSight: inSight))
            }
            endRun()
        }
        return runs
    }
}
