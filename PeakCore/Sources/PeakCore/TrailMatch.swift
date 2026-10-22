import Foundation

/// A location fix to place on a trail.
public struct TrailFix: Sendable {
    public var position: LatLon
    /// Horizontal accuracy, meters (Core Location's, roughly one standard deviation).
    public var accuracy: Double
    public var time: Date

    public init(position: LatLon, accuracy: Double, time: Date) {
        self.position = position
        self.accuracy = accuracy
        self.time = time
    }
}

/// Where you are on a trail and what's left of it.
public struct TrailProgress: Sendable, Equatable {
    /// Which way along the trail's line you're walking: `forward` from its start (the lower
    /// end, for a line from a `TrailProfile`) toward its end.
    public enum Direction: Sendable, Equatable {
        case forward, backward
    }

    /// Distance along the line from its start, meters.
    public var along: Double
    /// The point on the trail you're at.
    public var position: LatLon
    /// Nil until you've walked far enough along the trail to tell.
    public var direction: Direction?
    public var length: Double
    /// Along the trail from the end you're walking away from, and to the end you're walking
    /// toward (forward when it isn't clear yet), meters.
    public var done: Double
    public var remaining: Double
    /// How far the fix is from the nearest point of the trail, meters.
    public var offTrail: Double
    /// 0 to 1: how sure the match is. Low while the fixes are far from the trail, or fit
    /// two stretches of it equally well (parallel legs of a switchback before a turn).
    public var confidence: Double

    /// The highest point along the line: how far along the trail it is from you, and
    /// whether it's still ahead in the way you're walking.
    public var toTop: Double
    public var topAhead: Bool
    /// Climb and descent to the highest point and to the end you're walking toward, meters,
    /// and DIN 33466 walking times for them, seconds.
    public var climbToTop: Double
    public var descentToTop: Double
    public var timeToTop: TimeInterval
    public var climbToEnd: Double
    public var descentToEnd: Double
    public var timeToEnd: TimeInterval

    /// Whether a point `s` meters along the line is behind you: walked already, in the way
    /// you're going.
    public func isBehind(_ s: Double) -> Bool {
        direction == .backward ? s > along : s < along
    }
}

/// Snaps a stream of location fixes onto a trail's line, keeping to the trail's order.
///
/// The nearest point of the line is often the wrong one: legs of a switchback lie a few
/// tens of meters apart, as far as a fix can be out, and out-and-back sections lie on top
/// of each other. So this keeps a probability for every point along the line (a hidden
/// Markov model on a 10 m grid): each fix moves it along the line no faster than walking,
/// then weighs it by how well each point explains the fix. A leg that's near the fix but far
/// along the line from where you were gets little. A small part spreads over the whole line
/// each time, so walking onto the trail anywhere (or back onto it after a shortcut) is
/// picked up after a few fixes.
public struct TrailMatcher: Sendable {
    /// The grid: points about `spacing` apart along the line, their distance along it, and
    /// elevations (zero without a profile).
    private(set) var profile: TrailProfile
    let xy: [SIMD2<Double>]
    let projection: MapProjection
    public let spacing: Double
    public var length: Double { profile.points.last?.distance ?? 0 }

    /// Log probability of each grid point, nil before the first fix.
    var belief: [Double]?
    var lastTime: Date?
    /// Recent confident positions along the line, for the direction.
    var history: [(time: Date, along: Double)] = []
    public private(set) var direction: TrailProgress.Direction?
    public private(set) var progress: TrailProgress?

    /// How far apart the trail as mapped and the trail as walked can be, meters (mapping and
    /// the terrain model's error), added to each fix's own accuracy.
    static let mappingError = 8.0
    /// Fixes further than this many standard deviations from a point are no worse for it:
    /// a fix far off, or a wild one, doesn't drag the match along.
    static let outlierSigmas = 3.0
    /// Walking speed, meters per second, as a standard deviation of how far a fix can move
    /// along the line from the one before.
    static let walkingSpread = 1.6
    /// Distance along the line that must be covered one way, within `directionWindow`
    /// seconds, to tell which way you're walking.
    static let directionDistance = 15.0
    static let directionWindow: TimeInterval = 90

    /// Matches along the profile's line, using its elevations for what's left to climb.
    public init(profile: TrailProfile, spacing: Double = 10) {
        let line = profile.points.map(\.position)
        self.init(line: line, elevations: profile.points.map(\.elevation), spacing: spacing)
    }

    /// Matches along `line`; without `elevations` (one per point of `line`) climbs are zero.
    public init(line: [LatLon], elevations: [Double]? = nil, spacing: Double = 10) {
        self.spacing = spacing
        let center = line.first ?? LatLon(0, 0)
        projection = MapProjection(center: center)
        var points: [TrailProfile.Point] = []
        var along = 0.0
        for i in line.indices {
            let h = elevations.map { $0[i] } ?? 0
            if i == 0 {
                points.append(.init(distance: 0, elevation: h, position: line[0]))
                continue
            }
            let a = line[i - 1], b = line[i]
            let ha = elevations.map { $0[i - 1] } ?? 0
            let d = a.distance(to: b)
            let n = max(1, Int((d / spacing).rounded(.up)))
            for k in 1...n {
                let f = Double(k) / Double(n)
                points.append(.init(distance: along + d * f, elevation: ha + (h - ha) * f,
                                    position: LatLon(a.latitude + (b.latitude - a.latitude) * f,
                                                     a.longitude + (b.longitude - a.longitude) * f)))
            }
            along += d
        }
        let heights = points.map(\.elevation)
        profile = TrailProfile(points: points, gain: 0, loss: 0, highest: heights.max() ?? 0, lowest: heights.min() ?? 0)
        xy = points.map { [projection] in projection.point($0.position) }
    }

    /// The same matcher, with where you are on the trail and which way you're going, but
    /// `profile`'s elevations: for a profile of the same line from sharper terrain. Nil when
    /// `profile` is of another line, or of this one the other way round, which needs a
    /// matcher of its own.
    public func withElevations(of profile: TrailProfile) -> TrailMatcher? {
        let other = TrailMatcher(profile: profile, spacing: spacing)
        guard other.profile.points.count == self.profile.points.count,
              zip(other.profile.points, self.profile.points).allSatisfy({
                  abs($0.position.latitude - $1.position.latitude) < 1e-9 && abs($0.position.longitude - $1.position.longitude) < 1e-9
              }) else { return nil }
        var matcher = self
        matcher.profile = other.profile
        return matcher
    }

    public mutating func reset() {
        belief = nil
        lastTime = nil
        history = []
        direction = nil
        progress = nil
    }

    /// Takes in a fix and returns where it puts you on the trail. Nil for a trail with
    /// fewer than two points.
    @discardableResult
    public mutating func update(_ fix: TrailFix) -> TrailProgress? {
        let n = xy.count
        guard n >= 2 else { return nil }
        let p = projection.point(fix.position)
        let accuracy = fix.accuracy > 0 ? fix.accuracy : 50
        let sigma = (accuracy * accuracy + Self.mappingError * Self.mappingError).squareRoot()
        let floor = -0.5 * Self.outlierSigmas * Self.outlierSigmas
        let dt = lastTime.map { max(0, min(900, fix.time.timeIntervalSince($0))) } ?? 0
        lastTime = fix.time

        // Predict: spread the belief along the line by how far you could have walked.
        var prior: [Double]
        if let belief {
            let top = belief.max() ?? 0
            let weight = belief.map { exp($0 - top) }
            let spread = 4 + Self.walkingSpread * dt
            let reach = max(1, Int((3 * spread / spacing).rounded(.up)))
            let kernel = (-reach...reach).map { k -> Double in
                let s = Double(k) * spacing / spread
                return exp(-0.5 * s * s)
            }
            let ks = kernel.reduce(0, +)
            var moved = [Double](repeating: 0, count: n)
            for i in 0..<n where weight[i] > 1e-12 {
                for k in -reach...reach {
                    let j = i + k
                    // Walking off an end leaves you at it.
                    let jj = min(n - 1, max(0, j))
                    moved[jj] += weight[i] * kernel[k + reach] / ks
                }
            }
            let total = moved.reduce(0, +)
            // Joining anywhere: more of it the longer since the last fix.
            let jump = min(0.2, 0.002 + 2e-4 * dt)
            let uniform = jump * total / Double(n)
            prior = moved.map { log((1 - jump) * $0 + uniform) }
        } else {
            prior = [Double](repeating: 0, count: n)
        }

        // Weigh each point by how well it explains the fix.
        var posterior = prior
        for i in 0..<n {
            let d = p - xy[i]
            let z = -0.5 * (d.x * d.x + d.y * d.y) / (sigma * sigma)
            posterior[i] += max(z, floor) + log1p(exp(-abs(z - floor)))
        }
        let top = posterior.max() ?? 0
        for i in 0..<n { posterior[i] -= top }
        belief = posterior

        // The best point, refined by the belief around it.
        let weights = posterior.map { exp($0) }
        let total = weights.reduce(0, +)
        let best = posterior.indices.max { posterior[$0] < posterior[$1] }!
        let window = max(30, 2 * sigma)
        let bestAlong = profile.points[best].distance
        var near = 0.0, sum = 0.0
        var lo = best, hi = best
        while lo > 0, bestAlong - profile.points[lo - 1].distance <= window { lo -= 1 }
        while hi < n - 1, profile.points[hi + 1].distance - bestAlong <= window { hi += 1 }
        for i in lo...hi {
            near += weights[i]
            sum += weights[i] * profile.points[i].distance
        }
        let along = near > 0 ? sum / near : bestAlong
        let sharpness = total > 0 ? near / total : 0

        // How far off the trail, and how likely the fix is on it at all.
        var off = Double.infinity
        for i in 0..<(n - 1) { off = min(off, Self.distance(p, xy[i], xy[i + 1])) }
        let z = -0.5 * off * off / (sigma * sigma)
        let onTrail = 1 / (1 + exp(floor - z))
        let confidence = sharpness * onTrail

        // Which way: the distance covered along the line in the last minute or so.
        if confidence > 0.5 {
            history.append((fix.time, along))
            history.removeAll { fix.time.timeIntervalSince($0.time) > Self.directionWindow }
            if let first = history.first {
                let moved = along - first.along
                if moved > Self.directionDistance { direction = .forward } else if moved < -Self.directionDistance { direction = .backward }
                if abs(moved) > Self.directionDistance { history.removeAll { fix.time.timeIntervalSince($0.time) > 20 } }
            }
        }

        progress = report(along: along, offTrail: off, confidence: confidence)
        return progress
    }

    /// What's done and left from `along` meters along the line.
    func report(along: Double, offTrail: Double, confidence: Double) -> TrailProgress {
        let points = profile.points
        let length = self.length
        let i = index(at: along)
        let topIndex = profile.highestIndex
        let topAlong = points[topIndex].distance
        let forward = direction != .backward
        let end = forward ? points.count - 1 : 0
        let toTop = profile.climb(from: i, to: topIndex)
        let toEnd = profile.climb(from: i, to: end)
        let topAhead = abs(topAlong - along) < spacing ? false : (forward ? topAlong > along : topAlong < along)
        return TrailProgress(along: along, position: position(at: along), direction: direction, length: length,
                             done: forward ? along : length - along, remaining: forward ? length - along : along,
                             offTrail: offTrail, confidence: confidence,
                             toTop: abs(topAlong - along), topAhead: topAhead,
                             climbToTop: toTop.ascent, descentToTop: toTop.descent,
                             timeToTop: WalkingTime.din33466(distance: abs(topAlong - along), ascent: toTop.ascent, descent: toTop.descent),
                             climbToEnd: toEnd.ascent, descentToEnd: toEnd.descent,
                             timeToEnd: WalkingTime.din33466(distance: forward ? length - along : along,
                                                             ascent: toEnd.ascent, descent: toEnd.descent))
    }

    /// The grid point nearest `along`.
    func index(at along: Double) -> Int {
        let points = profile.points
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].distance <= along { lo = mid } else { hi = mid }
        }
        return along - points[lo].distance < points[hi].distance - along ? lo : hi
    }

    /// The point `along` meters along the line.
    public func position(at along: Double) -> LatLon {
        let points = profile.points
        let i = index(at: along)
        let j = points[i].distance <= along ? min(i + 1, points.count - 1) : max(i - 1, 0)
        let a = points[min(i, j)], b = points[max(i, j)]
        let span = b.distance - a.distance
        let f = span > 0 ? max(0, min(1, (along - a.distance) / span)) : 0
        return LatLon(a.position.latitude + (b.position.latitude - a.position.latitude) * f,
                      a.position.longitude + (b.position.longitude - a.position.longitude) * f)
    }

    static func distance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a, ap = p - a
        let len2 = (ab * ab).sum()
        let t = len2 > 0 ? max(0, min(1, (ap * ab).sum() / len2)) : 0
        let d = ap - t * ab
        return (d * d).sum().squareRoot()
    }
}
