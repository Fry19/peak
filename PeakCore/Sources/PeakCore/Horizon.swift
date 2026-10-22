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
    /// Ground within `nearRange` meters that rises less than this above the eye hides
    /// nothing, meters (0: all ground counts). That close, a few meters are within the
    /// terrain's error and where you really stand: a floor up, a deck, a step uphill. From
    /// a valley the far mountains can be only a degree or two up, and a rise 5 m above the
    /// eye 200 m away would hide them all. Higher ground still does.
    public var nearAllowance = 0.0
    public var nearRange = 1_000.0

    public init() {}

    /// For an observer on the base layer's coarse terrain: the first few kilometers are
    /// left out, since the ground there is kilometers of average (often above the eye, at
    /// the GPS altitude, or below it on a ridge) and would hide everything behind it.
    public static var coarse: HorizonSettings {
        var s = HorizonSettings()
        s.minDistance = 3_000
        return s
    }
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
    /// For each ray, whether its skyline is on the base layer's coarse terrain (`Terrain.hasCoarse`);
    /// empty when none is.
    public internal(set) var coarseRays: [Bool] = []
    let envelopeStart: [Int]
    let envelope: [EnvelopePoint]
    /// The skyline with the near ground `HorizonSettings.nearAllowance` let through put
    /// back; nil when it let none through that rises above the skyline.
    var nearGround: NearGround?

    struct NearGround: Sendable {
        var elevations: [Float]
        var distances: [Float]
        var coarseRays: [Bool]
    }

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

    /// The skyline alone, without the depth map below it: for a view that is only drawn,
    /// once its ridges are taken (`ridgeSegments`), never matched or draped against. Seen
    /// from high above, nearly every sample is in sight and the depth map grows to tens of
    /// megabytes; this keeps a few. Depth lookups on it find nothing (`distance` is nil,
    /// `ridges` has no crests).
    public func withoutDepth() -> HorizonProfile {
        var profile = HorizonProfile(observer: observer, settings: settings, elevations: elevations, distances: distances,
                                     envelopeStart: [Int](repeating: 0, count: count + 1), envelope: [])
        profile.coarseRays = coarseRays
        return profile
    }

    /// The skyline as the ground near the eye really stands, with what `nearAllowance` let
    /// through put back, and no depth map: what skyline matching compares camera frames
    /// against, since the camera sees that ground. This profile itself when nothing was.
    public func withNearGround() -> HorizonProfile {
        guard let near = nearGround else { return self }
        var settings = settings
        settings.nearAllowance = 0
        var profile = HorizonProfile(observer: observer, settings: settings, elevations: near.elevations,
                                     distances: near.distances, envelopeStart: [Int](repeating: 0, count: count + 1),
                                     envelope: [])
        profile.coarseRays = near.coarseRays
        return profile
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
    ///
    /// `accuracy` is how far off the position may be, meters. The ground is then the
    /// highest DEM height within that distance (at most `maxGroundSearch`): a fix a few
    /// meters off a knife-edge crest would otherwise put the eye down its side, with the
    /// crest blocking half the view, while people looking at the view mostly stand on top.
    public func observer(latitude: Double, longitude: Double, eyeHeight: Double = 1.6, accuracy: Double = 0) -> GeoPoint {
        let ground = groundHeight(latitude: latitude, longitude: longitude, within: min(max(accuracy, 0), Self.maxGroundSearch))
        return GeoPoint(latitude: latitude, longitude: longitude, height: (ground.isNaN ? 0 : ground) + eyeHeight)
    }

    /// The furthest `observer` looks for higher ground, meters.
    public static let maxGroundSearch = 30.0

    /// The highest DEM height within `radius` meters of a point, sampled about every 3 m;
    /// NaN where there is no terrain.
    public func groundHeight(latitude: Double, longitude: Double, within radius: Double) -> Double {
        var top = terrain.height(latitude: latitude, longitude: longitude)
        guard radius > 0 else { return top }
        let n = Int((radius / 3).rounded(.up))
        let step = radius / Double(n)
        let metersPerLat = 111_320.0, metersPerLon = 111_320 * max(cos(latitude * .pi / 180), 0.05)
        for i in -n...n {
            for j in -n...n where i * i + j * j <= n * n {
                let h = terrain.height(latitude: latitude + Double(i) * step / metersPerLat,
                                       longitude: longitude + Double(j) * step / metersPerLon)
                if h.isFinite, !(h <= top) { top = h }
            }
        }
        return top
    }

    /// Ray-marches the DEM in every direction from `observer`.
    public func render(from observer: GeoPoint, settings: HorizonSettings = HorizonSettings()) -> HorizonProfile {
        let rayCount = Int((360 / settings.azimuthStep).rounded())
        let march = March(observer: observer, settings: settings)
        var elevations = [Float](repeating: -90, count: rayCount)
        var distances = [Float](repeating: 0, count: rayCount)
        var perRay = [[HorizonProfile.EnvelopePoint]](repeating: [], count: rayCount)
        // The highest near ground `nearAllowance` let through on each ray, if any.
        var nearGround = [(elevation: Float, distance: Float)?](repeating: nil, count: settings.nearAllowance > 0 ? rayCount : 0)

        elevations.withUnsafeMutableBufferPointer { elev in
            distances.withUnsafeMutableBufferPointer { dist in
                perRay.withUnsafeMutableBufferPointer { env in
                    nearGround.withUnsafeMutableBufferPointer { near in
                        let chunk = 16
                        DispatchQueue.concurrentPerform(iterations: (rayCount + chunk - 1) / chunk) { block in
                            for i in block * chunk..<min(rayCount, (block + 1) * chunk) {
                                let azimuth = Double(i) * settings.azimuthStep
                                var points: [HorizonProfile.EnvelopePoint] = []
                                points.reserveCapacity(128)
                                let passed = march.run(terrain: terrain, azimuth: azimuth, upTo: settings.maxDistance, envelope: &points)
                                env[i] = points
                                if let last = points.last {
                                    elev[i] = last.elevation
                                    dist[i] = last.distance
                                }
                                if let passed, !near.isEmpty {
                                    near[i] = (Float(atan(passed.tan) * 180 / .pi), Float(passed.distance))
                                }
                            }
                        }
                    }
                }
            }
        }

        let tipsSeeNearGround = refineSummitTips(from: observer, march: march, elevations: &elevations,
                                                 distances: &distances, perRay: &perRay,
                                                 nearGround: nearGround.map { $0?.elevation ?? -90 })

        var start = [Int](repeating: 0, count: rayCount + 1)
        for i in 0..<rayCount { start[i + 1] = start[i] + perRay[i].count }
        var profile = HorizonProfile(observer: observer, settings: settings, elevations: elevations,
                                     distances: distances, envelopeStart: start, envelope: perRay.flatMap { $0 })
        func isCoarse(_ i: Int, _ distance: Float) -> Bool {
            let p = destination(from: observer, azimuth: Double(i) * settings.azimuthStep, distance: Double(distance))
            return terrain.isCoarse(latitude: p.latitude, longitude: p.longitude)
        }
        if terrain.hasCoarse {
            profile.coarseRays = (0..<rayCount).map { isCoarse($0, distances[$0]) }
        }
        // With ground let through about as high as a summit tip, on its nearest ray or its own
        // marches, the tip and its flanks might not be raised without the allowance: then the
        // skyline as it stands is marched again without it. That's rare.
        if tipsSeeNearGround {
            var strict = settings
            strict.nearAllowance = 0
            let ground = render(from: observer, settings: strict)
            profile.nearGround = HorizonProfile.NearGround(elevations: ground.elevations, distances: ground.distances,
                                                           coarseRays: ground.coarseRays)
            return profile
        }
        // Elsewhere, where the ground let through rises above everything beyond it, it is the
        // skyline as it stands: the highest of all the ground, as a march without it finds.
        if nearGround.contains(where: { $0 != nil }) {
            var near = HorizonProfile.NearGround(elevations: elevations, distances: distances, coarseRays: profile.coarseRays)
            for (i, n) in nearGround.enumerated() {
                guard let n, n.elevation > elevations[i] else { continue }
                near.elevations[i] = n.elevation
                near.distances[i] = n.distance
                if !near.coarseRays.isEmpty { near.coarseRays[i] = isCoarse(i, n.distance) }
            }
            if near.elevations != elevations { profile.nearGround = near }
        }
        return profile
    }

    /// A sharp tip can fall between both rays and distance samples. Each raised summit that
    /// rises above the regular skyline gets its exact bearing marched, with a sample on the
    /// apex, and that depth envelope goes in the nearest ray (at most half a ray sideways).
    /// A summit hidden on its own bearing, or past missing data, is never added. The tips
    /// are worked out in parallel against the regular rays, and each ray then keeps the
    /// highest skyline any of them gives it, so the order doesn't matter.
    ///
    /// `nearGround` is the highest ground `nearAllowance` let through on each regular ray
    /// (empty without one). Returns whether some tip that raises anything might go
    /// otherwise without the allowance: ground let through at least as high as the tip on
    /// its nearest ray, or as what one of its own marches raises.
    private func refineSummitTips(from observer: GeoPoint, march: March,
                                  elevations: inout [Float], distances: inout [Float],
                                  perRay: inout [[HorizonProfile.EnvelopePoint]], nearGround: [Float] = []) -> Bool {
        let tips = terrain.summitTips
        guard !tips.isEmpty else { return false }
        let frame = LocalFrame(origin: observer)
        var found = [(rays: [(ray: Int, points: [HorizonProfile.EnvelopePoint])], overNearGround: Bool)](
            repeating: ([], false), count: tips.count)
        elevations.withUnsafeBufferPointer { elev in
            perRay.withUnsafeBufferPointer { env in
                nearGround.withUnsafeBufferPointer { near in
                    found.withUnsafeMutableBufferPointer { out in
                        let chunk = 16
                        DispatchQueue.concurrentPerform(iterations: (tips.count + chunk - 1) / chunk) { block in
                            for t in block * chunk..<min(tips.count, (block + 1) * chunk) {
                                out[t] = rays(through: tips[t], from: observer, frame: frame, march: march,
                                              elevations: elev, envelopes: env, nearGround: near)
                            }
                        }
                    }
                }
            }
        }
        for (ray, points) in found.flatMap(\.rays) {
            guard let top = points.last, top.elevation > elevations[ray] else { continue }
            perRay[ray] = points
            elevations[ray] = top.elevation
            distances[ray] = top.distance
        }
        return found.contains { !$0.rays.isEmpty && $0.overNearGround }
    }

    /// How far in front of a tip its flanks are marched again, meters: past where any raised
    /// tip ends (within its reach plus three pixels of the summit, 720 m on 120 m tiles).
    static let flankDepth = 1_000.0

    /// The rays one summit tip raises above the regular `elevations`: its apex in the nearest
    /// ray, then that ray's neighbors eased onto its flanks. Empty when it raises none. Also
    /// whether near ground let through stands at least as high as the tip on its nearest ray
    /// (`nearGround`), or as the top of one of its own marches: without the allowance the
    /// tip, and so its flanks, might not be raised.
    private func rays(through tip: GeoPoint, from observer: GeoPoint, frame: LocalFrame, march: March,
                      elevations: UnsafeBufferPointer<Float>,
                      envelopes: UnsafeBufferPointer<[HorizonProfile.EnvelopePoint]>, nearGround: UnsafeBufferPointer<Float>)
        -> (rays: [(ray: Int, points: [HorizonProfile.EnvelopePoint])], overNearGround: Bool) {
        let settings = march.settings
        var tip = tip
        let distance = groundDistance(from: observer, to: tip)
        guard distance >= settings.minDistance, distance <= settings.maxDistance else { return ([], false) }
        tip.height = terrain.height(latitude: tip.latitude, longitude: tip.longitude)
        guard tip.height.isFinite else { return ([], false) }
        // Invert the same conformal sphere as the march, so the extra sample lands
        // on the grid node itself, even on a very steep tip.
        let chi = ConformalSphere.conformalLatitude(tip.latitude * .pi / 180)
        let dl = (tip.longitude - observer.longitude) * .pi / 180
        let east = cos(chi) * sin(dl)
        let north = cos(march.sphere.chi0) * sin(chi) - sin(march.sphere.chi0) * cos(chi) * cos(dl)
        let azimuth = normalizedAzimuth(atan2(east, north) * 180 / .pi)
        let i = Int((azimuth / settings.azimuthStep).rounded()) % elevations.count
        // Usually only a handful of tips can raise the existing skyline.
        let tipElevation = frame.look(at: tip, refraction: settings.refraction).elevation
        guard tipElevation > Double(elevations[i]) else { return ([], false) }
        var overNearGround = !nearGround.isEmpty && Double(nearGround[i]) >= tipElevation
        // The tip's rays end at it: everything the regular rays saw is below the tip, so
        // whatever lies beyond is out of sight.
        func isOver(_ passed: (tan: Double, distance: Double)?, _ top: HorizonProfile.EnvelopePoint) -> Bool {
            passed.map { atan($0.tan) * 180 / .pi >= Double(top.elevation) } ?? false
        }
        var apex: [HorizonProfile.EnvelopePoint] = []
        let apexPassed = march.sampling(from: 0, nearerThan: distance, then: [distance])
            .run(terrain: terrain, azimuth: azimuth, upTo: distance, envelope: &apex)
        guard let top = apex.last, top.distance == Float(distance), top.elevation > elevations[i] else { return ([], false) }
        overNearGround = overNearGround || isOver(apexPassed, top)
        var raised = [(ray: i, points: apex)]

        // Ease the half-ray rounding back to the original grid over four neighbors,
        // so snapping the apex does not leave a kink on either flank. Each sample
        // still moves by less than half a ray, and existing higher terrain is kept.
        let reach = min(4, elevations.count / 2)
        let rounding = azimuthDifference(azimuth, Double(i) * settings.azimuthStep)
        for offset in -reach...reach where offset != 0 {
            let j = (i + offset + elevations.count) % elevations.count
            let shift = rounding * (1 - Double(abs(offset)) / Double(reach))
            let flankAzimuth = normalizedAzimuth(Double(j) * settings.azimuthStep + shift)
            let delta = distance * march.sphere.radiansPerMeter
            let angle = azimuthDifference(flankAzimuth, azimuth) * .pi / 180
            let closest = atan2(sin(delta) * cos(angle), cos(delta)) / march.sphere.radiansPerMeter
            guard closest >= settings.minDistance, closest <= settings.maxDistance else { continue }
            // On a bilinear grid the flank's highest point need not be at closest
            // approach. Refine just one regular distance step around it.
            let span = max(settings.nearStep, settings.relativeStep * closest)
            let window = Array(stride(from: max(settings.minDistance, closest - span),
                                      through: min(settings.maxDistance, closest + span), by: span / 30))
            // Only the tip's part of the ray is marched again, carrying on from what ray j
            // sees nearer: in sight right up to it, or behind a ridge.
            let start = window[0] - Self.flankDepth
            let nearer = envelopes[j].prefix { Double($0.distance) < start }
            let inSight = envelopes[j].dropFirst(nearer.count).first.map { !$0.startsSegment } ?? false
            var flank = Array(nearer)
            let flankPassed = march.sampling(from: start, nearerThan: window[0], then: window)
                .run(terrain: terrain, azimuth: flankAzimuth, upTo: window[window.count - 1],
                     envelope: &flank, inSight: inSight)
            if let top = flank.last {
                overNearGround = overNearGround || isOver(flankPassed, top)
                if top.elevation > elevations[j] { raised.append((j, flank)) }
            }
        }
        return (raised, overNearGround)
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
    private(set) var samples: [Double]
    private(set) var cosDelta: [Double]
    private(set) var sinDelta: [Double]

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

    /// The regular samples from `start` to `end`, then `extra` (sorted, from `end` on): a ray
    /// ending on an exact summit, or a fine window. The regular trigonometry is reused, so
    /// only the extra samples cost anything.
    func sampling(from start: Double, nearerThan end: Double, then extra: [Double]) -> March {
        var m = self
        let a = samples.firstIndex { $0 >= start } ?? samples.count
        let b = max(a, samples.firstIndex { $0 >= end } ?? samples.count)
        m.samples = Array(samples[a..<b]) + extra
        m.cosDelta = Array(cosDelta[a..<b]) + extra.map { cos($0 * sphere.radiansPerMeter) }
        m.sinDelta = Array(sinDelta[a..<b]) + extra.map { sin($0 * sphere.radiansPerMeter) }
        return m
    }

    /// Marches one ray, appending every sample that rises above everything nearer.
    /// Consecutive visible samples are thinned to steps of `elevationResolution` degrees,
    /// but the last one of each visible stretch (a crest) is always kept.
    ///
    /// A non-empty `envelope` is what's been seen nearer, and the march carries on from it;
    /// `inSight` says whether the terrain just before the first sample was in sight.
    ///
    /// Near ground that `nearAllowance` lets through is left out, as if it weren't there;
    /// the highest of it (tan of its elevation angle, and its distance) is returned. If the
    /// data ends before anything else is seen, the highest of it stays, as the skyline.
    @discardableResult
    func run(terrain: Terrain, azimuth: Double, upTo maxDistance: Double,
             envelope: inout [HorizonProfile.EnvelopePoint], inSight: Bool = false) -> (tan: Double, distance: Double)? {
        let ray = GreatCircleRay(sphere: sphere, longitude: observer.longitude, azimuth: azimuth)
        // Refraction as a larger effective Earth: R' = R / (1 − k).
        let radius = WGS84.radius(latitude: observer.latitude * .pi / 180, azimuth: azimuth * .pi / 180)
        let effectiveRadius = radius / (1 - settings.refraction)
        let observerRadius = effectiveRadius + observer.height
        let elevationResolution = 0.01
        let passUnder = settings.nearAllowance > 0 ? observer.height + settings.nearAllowance : -Double.infinity
        var passed: (tan: Double, distance: Double)?

        var best = -Double.infinity            // tan of the highest elevation angle so far
        var lastKept = -Double.infinity        // elevation (degrees) of the last kept point
        var pending: (Double, Double)? = nil   // newest visible sample not yet kept
        var visible = inSight
        if let last = envelope.last {
            lastKept = Double(last.elevation)
            best = tan(lastKept * .pi / 180)
        }
        var newSegment = false

        for (k, d) in samples.enumerated() {
            if d > maxDistance { break }
            let p = ray.point(cosDelta: cosDelta[k], sinDelta: sinDelta[k])
            let h = terrain.height(latitude: p.latitude, longitude: p.longitude)
            if h.isNaN {
                if envelope.isEmpty, let passed {
                    envelope.append(.init(elevation: Float(atan(passed.tan) * 180 / .pi), distance: Float(passed.distance),
                                          startsSegment: false))
                }
                break
            }
            // Elevation angle on the effective sphere, with θ = d / R'.
            let theta = d / effectiveRadius
            let t2 = theta * theta
            let cosT = 1 - t2 / 2 + t2 * t2 / 24
            let sinT = theta * (1 - t2 / 6 + t2 * t2 / 120)
            let r = effectiveRadius + h
            let tanElevation = (cosT * r - observerRadius) / (sinT * r)

            if h < passUnder, d <= settings.nearRange {
                if tanElevation > passed?.tan ?? -.infinity { passed = (tanElevation, d) }
                continue
            }
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
        return passed
    }
}
