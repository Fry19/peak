import Foundation

public struct AlignmentSettings: Sendable {
    /// Heading corrections searched, ± degrees. Phone compasses are often 5–15° off. 180
    /// searches all the way around, for a photo without a heading.
    public var headingRange = 20.0
    public var headingStep = 0.1
    /// Largest pitch and roll corrections allowed, ± degrees: the best fit and every rival
    /// it's measured against stay within them. The motion sensors' gravity is good to a few
    /// tenths of a degree, and the camera's own tilt on the phone (`level`, learned from
    /// matches) is in the prior already. More freedom lets a short or flat skyline fit a
    /// wrong heading by tilting: a roof's slope taken for a ridge's. Pitch keeps a little
    /// more, for refraction and the eye's height. Photos without attitude data need wider ranges.
    public var pitchRange = 1.5
    public var rollRange = 1.0
    /// Roll seeds for the coarse search go out this far (nil: `rollRange`). A search all the
    /// way around keeps them near level, for speed, while the refinement may go further.
    public var coarseRollRange: Double?
    /// Prior spread of the pitch and roll estimates, in degrees.
    public var pitchSigma = 0.5
    public var rollSigma = 0.5
    /// Also solve for the field of view (when the lens data may be off).
    public var refineFieldOfView = false
    public var fieldOfViewSigma = 0.03
    /// How far off the GPS position may be, meters. A ridge d meters away can appear up to
    /// atan(positionUncertainty / d) off, so near terrain counts for less.
    public var positionUncertainty = 10.0
    /// Angular noise of a well-placed far skyline point (detection and DEM), degrees.
    public var measurementNoise = 0.08
    /// At most this many skyline points are used.
    public var maxPoints = 480
    /// Cost, in expected errors, of matching a column's lower candidate when it has a higher
    /// one: an edge with sky over it above another is the likelier skyline.
    public var lowerCandidatePenalty = 1.0

    // Acceptance gates.
    public var minValidFraction = 0.25
    public var minInlierFraction = 0.4
    public var maxAmbiguity = 0.75
    /// The same, for fits less than 1.5° from the best: a plain skyline's cost has shallow
    /// dips close together, and the best of them may not be the right one.
    public var maxNearAmbiguity = 0.9
    public var maxRMS = 0.2
    /// Skyline at least this far away is "far": a 10 m position error moves it by under 0.15°.
    public var farDistance = 4_000.0
    /// On the base layer's coarse terrain (`HorizonProfile.coarseRays`): its height error,
    /// meters, and how far its skyline must be to count as far. At Gornergrat its skyline
    /// is typically 75 m (and up to 400 m) off in height, at any distance.
    public var coarseError = 150.0
    public var coarseFarDistance = 20_000.0
    /// Matched far skyline needed, as a fraction of the points and as a span of azimuth.
    public var minFarFraction = 0.2
    public var minFarSpan = 4.0
    /// Frames matched together: how far any one of them, refit alone from the shared fit,
    /// may move the heading, degrees.
    public var maxViewDisagreement = 0.3

    public init() {}

    /// Settings for a still photo with a known location and compass heading but no pitch or roll.
    public static var photo: AlignmentSettings {
        var s = AlignmentSettings()
        s.pitchRange = 10
        s.rollRange = 5
        s.pitchSigma = 5
        s.rollSigma = 3
        return s
    }

    /// Expected angular error (degrees) of a skyline point `distance` meters away.
    func sigma(distance: Double, coarse: Bool = false) -> Double {
        let parallax = atan(positionUncertainty / max(distance, 1)) * 180 / .pi
        let terrain = coarse ? atan(coarseError / max(distance, 1)) * 180 / .pi : 0
        return (measurementNoise * measurementNoise + parallax * parallax + terrain * terrain).squareRoot()
    }

    /// Whether skyline `distance` meters away counts as far.
    func isFar(distance: Double, coarse: Bool = false) -> Bool {
        distance >= (coarse ? coarseFarDistance : farDistance)
    }
}

public struct AlignmentResult: Sendable {
    /// The corrected attitude.
    public var attitude: Attitude
    public var intrinsics: CameraIntrinsics
    public var headingCorrection: Double
    public var pitchCorrection: Double
    public var rollCorrection: Double
    /// RMS residual of the far inlier points, degrees.
    public var rms: Double
    public var inlierFraction: Double
    /// Fraction of points that match and lie at least `farDistance` away.
    public var farFraction: Double
    /// Robust cost of the best fit divided by that of the best fit at least 1.5° away:
    /// near 0 is a clear match, near 1 means another heading fits about as well (a flat or
    /// repetitive skyline).
    public var ambiguity: Double
    /// The same against fits 0.3–1.5° away: near 1 means the skyline doesn't pin the
    /// heading down to better than a degree or so.
    public var nearAmbiguity: Double
    /// The fits `ambiguity` and `nearAmbiguity` were measured against: the closest
    /// contenders more than 1.5° away and 0.3–1.5° away (nil when there was none).
    public var runnerUp: Rival?
    public var nearRunnerUp: Rival?
    public var pointCount: Int
    public var accepted: Bool
    public var rejectionReason: String?
    /// The coarse search: cost for each heading correction.
    public var headingCurve: [(correction: Double, cost: Double)]
    /// Each view's pitch and roll corrections, when several were matched at once (the
    /// first view's are `pitchCorrection` and `rollCorrection`).
    public var viewCorrections: [(pitch: Double, roll: Double)] = []

    /// Another fit, as corrections to the prior like the best one's.
    public struct Rival: Sendable {
        public var headingCorrection: Double
        public var pitchCorrection: Double
        public var rollCorrection: Double
        /// The best fit's cost over this one's, as in `ambiguity`.
        public var ratio: Double
    }
}

/// One frame's skyline and the camera it was seen with, for matching several frames at once.
public struct AlignmentView: Sendable {
    public var skyline: Skyline
    /// The camera before correction. Every view's heading must be under the same north:
    /// one heading correction moves them all (see `SkylineStrip`).
    public var camera: Camera

    public init(skyline: Skyline, camera: Camera) {
        self.skyline = skyline
        self.camera = camera
    }
}

/// Finds the camera attitude that makes the detected skyline match the rendered horizon.
///
/// Each skyline point is weighed by how much it can be trusted: far ridges pin the heading
/// down, near ones mostly reflect GPS error (parallax), so residuals are measured in units
/// of each point's expected error.
public enum SkylineAligner {
    public static func align(_ skyline: Skyline, camera: Camera, horizon: HorizonProfile,
                             settings: AlignmentSettings = AlignmentSettings()) -> AlignmentResult {
        align([AlignmentView(skyline: skyline, camera: camera)], horizon: horizon, settings: settings)
    }

    /// Several frames matched as one wider skyline: one heading correction for all of them
    /// (their headings are already under the same north), pitch and roll for each within the
    /// same ranges. The result is for the first view; the gates are the single frame's, over
    /// all the views' points. Where views overlap, their points share one view's weight, so
    /// looking at the same skyline again adds no evidence.
    public static func align(_ views: [AlignmentView], horizon: HorizonProfile,
                             settings: AlignmentSettings = AlignmentSettings()) -> AlignmentResult {
        precondition(!views.isEmpty, "no views to align")
        for v in views {
            precondition(v.skyline.width == v.camera.intrinsics.width && v.skyline.height == v.camera.intrinsics.height,
                         "skyline and intrinsics must be for the same image size")
        }
        let camera = views[0].camera
        let prior = camera.attitude
        // Each column's candidates: the detected boundary and a fainter edge above it, where
        // there is one. Whichever fits the terrain counts.
        var all: [(view: Int, x: Double, ys: [Double], weight: Double)] = []
        // Each point's share of a view: 1 over the number of views that see its azimuth.
        var allShares: [Double] = []
        for (v, view) in views.enumerated() {
            let coverage = views.count > 1 ? overlapCounts(views, view: v) : nil
            for c in view.skyline.candidates {
                let share = coverage.map { 1 / Double($0(c.x)) } ?? 1
                all.append((v, c.x, c.ys, coverage == nil ? c.weight : c.weight * share))
                allShares.append(share)
            }
        }
        let stride = max(1, Int((Double(all.count) / Double(settings.maxPoints)).rounded(.up)))
        let points = Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }
        let shares = Swift.stride(from: 0, to: all.count, by: stride).map { allShares[$0] }
        let viewPoints = views.indices.map { v in points.indices.filter { points[$0].view == v } }
        let candidateFraction = Double(views.reduce(0) { $0 + Int(($1.skyline.candidateFraction * Double($1.skyline.width)).rounded()) })
            / Double(max(views.reduce(0) { $0 + $1.skyline.width }, 1))

        func reject(_ reason: String, curve: [(Double, Double)] = []) -> AlignmentResult {
            AlignmentResult(attitude: prior, intrinsics: camera.intrinsics, headingCorrection: 0,
                            pitchCorrection: 0, rollCorrection: 0, rms: .nan, inlierFraction: 0, farFraction: 0,
                            ambiguity: 1, nearAmbiguity: 1, runnerUp: nil, nearRunnerUp: nil,
                            pointCount: points.count, accepted: false,
                            rejectionReason: reason, headingCurve: curve.map { ($0.0, $0.1) })
        }
        guard candidateFraction >= settings.minValidFraction, points.count >= 20 else {
            return reject("too little skyline found (\(Int(candidateFraction * 100))% of columns)")
        }

        // Expected error for every ray of the rendered horizon.
        let coarse = horizon.coarseRays.isEmpty ? [Bool](repeating: false, count: horizon.count) : horizon.coarseRays
        let raySigma = zip(horizon.distances, coarse).map { settings.sigma(distance: Double($0), coarse: $1) }
        let rayFar = zip(horizon.distances, coarse).map { settings.isFar(distance: Double($0), coarse: $1) }
        func ray(_ azimuth: Double) -> Int {
            Int((normalizedAzimuth(azimuth) / horizon.azimuthStep).rounded()) % horizon.count
        }

        // 1. Coarse search. Turning the heading rotates every viewing direction about the
        //    vertical, so it just shifts azimuths. Pitch and roll get a few candidates, and
        //    whatever pitch is left over is taken out as the median elevation offset of the
        //    far points, as far as the pitch range allows. Each point's candidate is picked
        //    before that offset comes out, so a narrow range gets pitch seeds 1° apart. With
        //    the heading fixed, each view's cost depends only on its own pitch and roll, so
        //    each picks its own.
        let cap = 3.0
        let pitchCandidates = candidates(range: settings.pitchRange, spacing: settings.pitchRange > 2 ? 2 : 1)
        let rollCandidates = candidates(range: settings.coarseRollRange ?? settings.rollRange, spacing: 1)
        let headingCount = Int((settings.headingRange / settings.headingStep).rounded())
        var curve = [(Double, Double)]()
        var curveArgs = [[(pitch: Double, roll: Double, offset: Double)]]()
        var combos: [(Double, Double)] = []
        for dp in pitchCandidates {
            for dr in rollCandidates { combos.append((dp, dr)) }
        }
        // directions[view][combo][point of the view][candidate]
        let directions: [[[[(azimuth: Double, elevation: Double)]]]] = views.indices.map { v in
            combos.map { dp, dr in
                var c = views[v].camera
                c.attitude.pitch += dp
                c.attitude.roll += dr
                let projector = c.projector
                return viewPoints[v].map { i in points[i].ys.map { projector.look(x: points[i].x, y: $0) } }
            }
        }
        let totalWeight = points.reduce(0) { $0 + $1.weight }
        var residuals = [Double]()
        var farResiduals: [Double] = []
        farResiduals.reserveCapacity(points.count)
        for step in -headingCount...headingCount {
            let dh = Double(step) * settings.headingStep
            var total = 0.0
            var args: [(pitch: Double, roll: Double, offset: Double)] = []
            for v in views.indices {
                var bestCost = Double.infinity
                var bestArgs = (pitch: 0.0, roll: 0.0, offset: 0.0)
                let members = viewPoints[v]
                for (k, dirs) in directions[v].enumerated() {
                    farResiduals.removeAll(keepingCapacity: true)
                    residuals.removeAll(keepingCapacity: true)
                    for n in members.indices {
                        // The candidate that fits best, for the pitch left over.
                        var best = (e: Double.infinity, r: 0.0, j: 0)
                        for (c, d) in dirs[n].enumerated() {
                            let az = d.azimuth + dh
                            let r = d.elevation - horizon.elevation(atAzimuth: az)
                            let j = ray(az)
                            let e = abs(r) / raySigma[j] + (c > 0 ? settings.lowerCandidatePenalty : 0)
                            if e < best.e { best = (e, r, j) }
                        }
                        residuals.append(best.r)
                        if rayFar[best.j] { farResiduals.append(best.r) }
                    }
                    // The pitch correction this makes, candidate less offset, stays in range.
                    let dp = combos[k].0
                    let offset = max(-1.5, dp - settings.pitchRange,
                                     min(1.5, dp + settings.pitchRange, median(farResiduals.count >= 10 ? farResiduals : residuals)))
                    var cost = 0.0
                    for (n, i) in members.enumerated() {
                        var e = Double.infinity
                        for (c, d) in dirs[n].enumerated() {
                            let az = d.azimuth + dh
                            e = min(e, abs(d.elevation - horizon.elevation(atAzimuth: az) - offset) / raySigma[ray(az)]
                                    + (c > 0 ? settings.lowerCandidatePenalty : 0))
                        }
                        cost += points[i].weight * min(e, cap)
                    }
                    cost /= totalWeight
                    if cost < bestCost {
                        bestCost = cost
                        bestArgs = (combos[k].0, combos[k].1, offset)
                    }
                }
                total += bestCost
                args.append(bestArgs)
            }
            curve.append((dh, total))
            curveArgs.append(args)
        }

        // 2. Refine the best few basins with all parameters free (pitch and roll within their
        //    ranges), and score each refined solution with the same robust cost as the coarse search.
        let separation = Int(1.5 / settings.headingStep)
        let cameras = views.map(\.camera)
        /// Each point's robust cost: its best candidate's error in expected errors, capped.
        func errors(_ q: [Double]) -> [Double] {
            let projectors = views.indices.map { apply(q, view: $0, to: cameras[$0]).projector }
            return points.map { p in
                var e = Double.infinity
                for (n, y) in p.ys.enumerated() {
                    let d = projectors[p.view].look(x: p.x, y: y)
                    e = min(e, abs(d.elevation - horizon.elevation(atAzimuth: d.azimuth)) / raySigma[ray(d.azimuth)]
                            + (n > 0 ? settings.lowerCandidatePenalty : 0))
                }
                return min(e, cap)
            }
        }
        func score(_ q: [Double]) -> Double {
            zip(points, errors(q)).reduce(0) { $0 + $1.0.weight * $1.1 } / totalWeight
        }
        var basins: [(params: [Double], cost: Double, score: Double)] = []
        for m in localMinima(curve.map(\.1), separation: separation).prefix(4) {
            var start = [curve[m].0]
            for a in curveArgs[m] { start += [a.pitch - a.offset, a.roll] }
            start.append(0)
            let refined = refine(start, points: points, cameras: cameras, horizon: horizon,
                                 sigma: { raySigma[ray($0)] }, settings: settings)
            basins.append((refined.params, refined.cost, score(refined.params)))
        }
        guard let first = basins.min(by: { $0.cost < $1.cost }) else { return reject("no heading fits", curve: curve) }
        // Start again a little to either side of the best, and keep any better fit found.
        for shift in [-1.5, -0.75, 0.75, 1.5] {
            var start = first.params
            start[0] += shift
            let refined = refine(start, points: points, cameras: cameras, horizon: horizon,
                                 sigma: { raySigma[ray($0)] }, settings: settings)
            basins.append((refined.params, refined.cost, score(refined.params)))
        }
        let best = basins.min(by: { $0.cost < $1.cost })!
        let q = best.params
        // Ambiguity: the best fit against the best fit with a clearly different heading, over
        // the points either one fits. A point neither fits (a roof, a wall, a tree in front)
        // costs both the same and can't tell them apart.
        let bestErrors = errors(q)
        func versus(_ rival: [Double]) -> Double {
            var a = 0.0, b = 0.0
            for (i, e) in errors(rival).enumerated() where min(e, bestErrors[i]) < cap {
                a += points[i].weight * bestErrors[i]
                b += points[i].weight * e
            }
            return b > 0 ? min(1, a / b) : 1
        }
        // Every basin was refined within the same pitch and roll ranges, so a rival can't
        // buy its fit with a tilt no photo has either.
        func closest(_ within: (Double) -> Bool) -> AlignmentResult.Rival? {
            basins.filter { within(abs(azimuthDifference($0.params[0], q[0]))) }
                .map { b in AlignmentResult.Rival(headingCorrection: b.params[0], pitchCorrection: b.params[1],
                                                  rollCorrection: b.params[2], ratio: versus(b.params)) }
                .max { $0.ratio < $1.ratio }
        }
        let runnerUp = closest { $0 > 1.5 }
        let nearRunnerUp = closest { (0.3...1.5).contains($0) }
        let ambiguity = runnerUp?.ratio ?? 0
        let nearAmbiguity = nearRunnerUp?.ratio ?? 0
        // Frames of a pan must agree: each one refit alone from the shared fit stays with its
        // heading. One the gyroscope placed wrong would otherwise pull the others its way.
        // A view with too little skyline can't be checked, and the result may be for it.
        var disagreement = 0.0
        let uncheckable = views.count > 1 && viewPoints.contains { $0.count < 20 }
        if views.count > 1, !uncheckable {
            for v in views.indices {
                let own = viewPoints[v].map { i in (view: 0, x: points[i].x, ys: points[i].ys, weight: points[i].weight) }
                let alone = refine([q[0], q[1 + 2 * v], q[2 + 2 * v], q[q.count - 1]], points: own, cameras: [cameras[v]],
                                   horizon: horizon, sigma: { raySigma[ray($0)] }, settings: settings)
                disagreement = max(disagreement, abs(azimuthDifference(alone.params[0], q[0])))
            }
        }

        // 3. Gate.
        let solvedViews = views.indices.map { apply(q, view: $0, to: cameras[$0]) }
        let solved = solvedViews[0]
        let projectors = solvedViews.map(\.projector)
        // Counted by share, so overlapping views count once (whole points for a single view).
        var inliers = 0.0, farInliers = 0.0, sumSq = 0.0
        var farOffsets: [Double] = []
        for (p, share) in zip(points, shares) {
            // The column's candidate that fits best.
            var best: (e: Double, r: Double, j: Int, d: (azimuth: Double, elevation: Double))?
            for (n, y) in p.ys.enumerated() {
                let d = projectors[p.view].look(x: p.x, y: y)
                let r = d.elevation - horizon.elevation(atAzimuth: d.azimuth)
                let j = ray(d.azimuth)
                let e = abs(r) / raySigma[j] + (n > 0 ? settings.lowerCandidatePenalty : 0)
                if best.map({ e < $0.e }) ?? true { best = (e, r, j, d) }
            }
            guard let (_, r, j, d) = best, abs(r) < 2.5 * raySigma[j] else { continue }
            inliers += share
            if rayFar[j] {
                farInliers += share
                sumSq += share * r * r
                farOffsets.append(azimuthDifference(d.azimuth, solved.attitude.heading))
            }
        }
        let total = shares.reduce(0, +)
        let inlierFraction = inliers / total
        let farFraction = farInliers / total
        let farSpan = (farOffsets.max() ?? 0) - (farOffsets.min() ?? 0)
        let rms = farInliers > 0 ? (sumSq / farInliers).squareRoot() : .nan

        var result = AlignmentResult(
            attitude: solved.attitude, intrinsics: solved.intrinsics,
            headingCorrection: q[0], pitchCorrection: solved.attitude.pitch - prior.pitch,
            rollCorrection: solved.attitude.roll - prior.roll, rms: rms, inlierFraction: inlierFraction,
            farFraction: farFraction, ambiguity: ambiguity, nearAmbiguity: nearAmbiguity,
            runnerUp: runnerUp, nearRunnerUp: nearRunnerUp,
            pointCount: points.count, accepted: true,
            rejectionReason: nil, headingCurve: curve.map { ($0.0, $0.1) })
        result.viewCorrections = views.indices.map { (q[1 + 2 * $0], q[2 + 2 * $0]) }
        if inlierFraction < settings.minInlierFraction {
            result.rejectionReason = "only \(Int(inlierFraction * 100))% of the skyline matches"
        } else if farFraction < settings.minFarFraction || farSpan < settings.minFarSpan {
            result.rejectionReason = "not enough distant skyline (\(Int(farFraction * 100))% over " +
                "\(Int(settings.farDistance / 1000)) km, spanning \(String(format: "%.1f", farSpan))°)"
        } else if ambiguity > settings.maxAmbiguity {
            result.rejectionReason = String(format: "ambiguous: another heading fits almost as well (%.2f)", ambiguity)
        } else if nearAmbiguity > settings.maxNearAmbiguity {
            result.rejectionReason = String(format: "heading not pinned down: a fit within 1.5° is almost as good (%.2f)",
                                            nearAmbiguity)
        } else if !(rms <= settings.maxRMS) {
            result.rejectionReason = String(format: "residual too large (%.2f°)", rms)
        } else if settings.headingRange < 180, abs(q[0]) > settings.headingRange - settings.headingStep {
            result.rejectionReason = "best heading is at the edge of the search range"
        } else if uncheckable {
            result.rejectionReason = "a frame of the pan has too little skyline to check"
        } else if disagreement > settings.maxViewDisagreement {
            result.rejectionReason = String(format: "frames disagree on the heading (%.2f°)", disagreement)
        }
        result.accepted = result.rejectionReason == nil
        return result
    }

    /// For each column x of view `v`, how many views see its azimuth (at the middle row,
    /// before correction), itself included.
    static func overlapCounts(_ views: [AlignmentView], view v: Int) -> (Double) -> Int {
        let reference = views[0].camera.attitude.heading
        let spans = views.map { view -> ClosedRange<Double> in
            let p = view.camera.projector, k = view.camera.intrinsics
            let a = azimuthDifference(p.look(x: 0, y: k.cy).azimuth, reference)
            let b = azimuthDifference(p.look(x: Double(k.width), y: k.cy).azimuth, reference)
            return min(a, b)...max(a, b)
        }
        let projector = views[v].camera.projector, cy = views[v].camera.intrinsics.cy
        return { x in
            let a = azimuthDifference(projector.look(x: x, y: cy).azimuth, reference)
            return max(1, spans.filter { $0.contains(a) }.count)
        }
    }

    /// Parameters: heading correction, then each view's pitch and roll corrections, then the
    /// log focal scale (last).
    static func apply(_ q: [Double], view v: Int, to camera: Camera) -> Camera {
        var c = camera
        c.attitude.heading = normalizedAzimuth(camera.attitude.heading + q[0])
        c.attitude.pitch += q[1 + 2 * v]
        c.attitude.roll += q[2 + 2 * v]
        let s = exp(q[q.count - 1])
        c.intrinsics.fx *= s
        c.intrinsics.fy *= s
        return c
    }

    /// Each point's residual in units of expected error, of its column's best candidate.
    static func residuals(_ q: [Double], points: [(view: Int, x: Double, ys: [Double], weight: Double)], cameras: [Camera],
                          horizon: HorizonProfile, sigma: (Double) -> Double, settings: AlignmentSettings) -> [Double] {
        let projectors = cameras.indices.map { apply(q, view: $0, to: cameras[$0]).projector }
        return points.map { p in
            var best = (cost: Double.infinity, e: 0.0)
            for (n, y) in p.ys.enumerated() {
                let d = projectors[p.view].look(x: p.x, y: y)
                let e = (d.elevation - horizon.elevation(atAzimuth: d.azimuth)) / sigma(d.azimuth)
                let cost = abs(e) + (n > 0 ? settings.lowerCandidatePenalty : 0)
                if cost < best.cost { best = (cost, e) }
            }
            return best.e
        }
    }

    /// Levenberg–Marquardt on residuals scaled by each point's expected error, with Cauchy
    /// weights (iteratively reweighted least squares) so outliers fade out.
    static func refine(_ start: [Double], points: [(view: Int, x: Double, ys: [Double], weight: Double)], cameras: [Camera],
                       horizon: HorizonProfile, sigma: (Double) -> Double,
                       settings: AlignmentSettings) -> (params: [Double], cost: Double) {
        let n = cameras.count
        let free = settings.refineFieldOfView ? 2 * n + 2 : 2 * n + 1
        let c = 2.0
        let tilt = (0..<n).flatMap { _ in [settings.pitchSigma, settings.rollSigma] }
        let priors = [Double.infinity] + tilt + [settings.fieldOfViewSigma]

        func residuals(_ q: [Double]) -> [Double] {
            Self.residuals(q, points: points, cameras: cameras, horizon: horizon, sigma: sigma, settings: settings)
        }
        func cost(_ r: [Double], _ q: [Double]) -> Double {
            var total = 0.0
            for (i, e) in r.enumerated() { total += points[i].weight * c * c * log(1 + (e / c) * (e / c)) }
            for j in 1..<free { total += (q[j] / priors[j]) * (q[j] / priors[j]) }
            return total
        }

        // Pitch and roll stay within their ranges.
        let limits = [Double.infinity] + (0..<n).flatMap { _ in [settings.pitchRange, settings.rollRange] } + [Double.infinity]
        func clamped(_ q: [Double]) -> [Double] {
            var q = q
            for j in 1...(2 * n) { q[j] = max(-limits[j], min(limits[j], q[j])) }
            return q
        }

        var q = clamped(start)
        var r = residuals(q)
        var current = cost(r, q)
        var lambda = 1e-2
        let h = [Double](repeating: 0.01, count: 2 * n + 1) + [1e-4]
        for _ in 0..<30 {
            // Jacobian by central differences.
            var jac = [[Double]](repeating: [Double](repeating: 0, count: points.count), count: free)
            for j in 0..<free {
                var qp = q, qm = q
                qp[j] += h[j]
                qm[j] -= h[j]
                let rp = residuals(qp), rm = residuals(qm)
                for i in points.indices { jac[j][i] = (rp[i] - rm[i]) / (2 * h[j]) }
            }
            // Normal equations with Cauchy weights, plus the priors.
            var a = [[Double]](repeating: [Double](repeating: 0, count: free), count: free)
            var g = [Double](repeating: 0, count: free)
            for i in points.indices {
                let w = points[i].weight / (1 + (r[i] / c) * (r[i] / c))
                for j in 0..<free {
                    g[j] += w * jac[j][i] * r[i]
                    for k in 0...j { a[j][k] += w * jac[j][i] * jac[k][i] }
                }
            }
            for j in 1..<free {
                a[j][j] += 1 / (priors[j] * priors[j])
                g[j] += q[j] / (priors[j] * priors[j])
            }
            for j in 0..<free { for k in 0..<j { a[k][j] = a[j][k] } }

            var improved = false
            for _ in 0..<8 {
                var damped = a
                for j in 0..<free { damped[j][j] *= 1 + lambda }
                guard let step = boundedStep(damped, g, q: q, limits: limits) else { lambda *= 10; continue }
                var candidate = q
                for j in 0..<free { candidate[j] += step[j] }
                candidate = clamped(candidate)
                let rc = residuals(candidate)
                let cc = cost(rc, candidate)
                if cc < current {
                    let delta = (0..<free).map { abs(candidate[$0] - q[$0]) }.max() ?? 0
                    q = candidate
                    r = rc
                    current = cc
                    lambda = max(lambda / 3, 1e-6)
                    improved = true
                    if delta < 1e-5 { return (q, current) }
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }
        return (q, current)
    }

    /// The damped Gauss–Newton step for `a` · step = −`g` with parameters held at the edges
    /// of their `limits` (an active set): one the step pushes further out is held there and
    /// the rest solved again without it, and a held one is let go again once moving it back
    /// inside would lower the cost. Clipping alone would leave the others where the held
    /// one's pull put them.
    static func boundedStep(_ a: [[Double]], _ g: [Double], q: [Double], limits: [Double]) -> [Double]? {
        var held = Set<Int>()
        var step: [Double]?
        for _ in 0..<(2 * g.count + 2) {
            let open = g.indices.filter { !held.contains($0) }
            guard let s = solve(open.map { j in open.map { a[j][$0] } }, open.map { -g[$0] }) else { return nil }
            var next = [Double](repeating: 0, count: g.count)
            for (n, j) in open.enumerated() { next[j] = s[n] }
            step = next
            // The cost's slope at the step: a held parameter it pulls back inside is let go.
            let slope = g.indices.map { j in g[j] + g.indices.reduce(0) { $0 + a[j][$1] * next[$1] } }
            if let j = held.first(where: { slope[$0] * q[$0] > 0 }) {
                held.remove(j)
                continue
            }
            // The one pushed furthest past its edge is held, then the rest solved again.
            guard let j = open.filter({ abs(q[$0]) >= limits[$0] - 1e-9 && next[$0] * q[$0] > 0 })
                .max(by: { abs(next[$0]) < abs(next[$1]) }) else { return next }
            held.insert(j)
        }
        return step
    }

    static func candidates(range: Double, spacing: Double) -> [Double] {
        let n = Int((range / spacing).rounded(.down))
        return (-n...n).map { Double($0) * spacing }
    }

    /// Lowest values first, each at least `separation` indices from the ones already picked.
    static func localMinima(_ v: [Double], separation: Int) -> [Int] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var picked: [Int] = []
        for i in order where picked.allSatisfy({ abs($0 - i) > separation }) {
            picked.append(i)
            if picked.count == 5 { break }
        }
        return picked
    }
}

func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}

/// Solves a small dense linear system by Gaussian elimination with partial pivoting.
func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var m = a
    var x = b
    for col in 0..<n {
        guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else {
            return nil
        }
        m.swapAt(col, pivot)
        x.swapAt(col, pivot)
        for row in (col + 1)..<n {
            let f = m[row][col] / m[col][col]
            for k in col..<n { m[row][k] -= f * m[col][k] }
            x[row] -= f * x[col]
        }
    }
    for row in stride(from: n - 1, through: 0, by: -1) {
        var s = x[row]
        for k in (row + 1)..<n { s -= m[row][k] * x[k] }
        x[row] = s / m[row][row]
    }
    return x
}
