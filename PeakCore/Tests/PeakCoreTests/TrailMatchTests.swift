import XCTest
@testable import PeakCore

final class TrailMatchTests: XCTestCase {
    private let projection = MapProjection(center: LatLon(46, 8))

    /// A line through map points (meters east and north of 46° N 8° E), with a profile whose
    /// elevation is `height` of the distance along it.
    private func profile(_ points: [SIMD2<Double>], height: (Double) -> Double = { _ in 1_000 }) -> TrailProfile {
        var out: [TrailProfile.Point] = []
        var along = 0.0
        for (i, p) in points.enumerated() {
            if i > 0 { along += ((p - points[i - 1]) * (p - points[i - 1])).sum().squareRoot() }
            out.append(.init(distance: along, elevation: height(along), position: projection.latLon(p)))
        }
        let h = out.map(\.elevation)
        return TrailProfile(points: out, gain: 0, loss: 0, highest: h.max()!, lowest: h.min()!)
    }

    /// The point `s` meters along a polyline of map points.
    private func point(_ points: [SIMD2<Double>], at s: Double) -> SIMD2<Double> {
        var left = s
        for (a, b) in zip(points, points.dropFirst()) {
            let d = ((b - a) * (b - a)).sum().squareRoot()
            if left <= d { return a + (b - a) * (left / d) }
            left -= d
        }
        return points.last!
    }

    /// Fixes every `interval` seconds walking at `speed` through the distances `path` (meters
    /// along the line, as a function of time, until `duration`), each 10 to 30 m out in a
    /// random direction, claiming 20 m accuracy.
    private func walk(_ points: [SIMD2<Double>], duration: Double, interval: Double = 3, seed: UInt64,
                      path: (Double) -> Double) -> [(fix: TrailFix, along: Double)] {
        var random = SplitMix64(seed: seed)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return stride(from: 0, through: duration, by: interval).map { t in
            let s = path(t)
            let angle = random.uniform() * 2 * .pi, r = 10 + 20 * random.uniform()
            let p = point(points, at: s) + SIMD2(cos(angle), sin(angle)) * r
            return (TrailFix(position: projection.latLon(p), accuracy: 20, time: start.addingTimeInterval(t)), s)
        }
    }

    /// Eight legs 400 m long and 50 m apart up a slope, each joined to the next by a hairpin.
    private var switchbacks: [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        for leg in 0..<8 {
            let y = Double(leg) * 50
            points += leg % 2 == 0 ? [SIMD2(0, y), SIMD2(400, y)] : [SIMD2(400, y), SIMD2(0, y)]
        }
        return points
    }

    func testSwitchbacksStayOnTheirLegWithNoisyFixes() {
        let line = switchbacks
        let trail = profile(line) { 1_500 + 0.12 * $0 }
        var matcher = TrailMatcher(profile: trail)
        let fixes = walk(line, duration: 3_000, seed: 7) { min(1.2 * $0, trail.points.last!.distance) }
        var errors: [Double] = [], naive: [Double] = []
        for (i, f) in fixes.enumerated() {
            let p = matcher.update(f.fix)!
            guard i >= 5 else { continue }
            errors.append(abs(p.along - f.along))
            // The nearest point alone, for comparison.
            let xy = projection.point(f.fix.position)
            let nearest = trail.points.min { a, b in
                let da = projection.point(a.position) - xy, db = projection.point(b.position) - xy
                return (da * da).sum() < (db * db).sum()
            }!
            naive.append(abs(nearest.distance - f.along))
        }
        errors.sort()
        XCTAssertLessThan(errors[errors.count * 95 / 100], 30, "95% within 30 m along the trail")
        XCTAssertLessThan(errors.last!, 60, "never on another leg (they're 450 m apart along the trail)")
        XCTAssertGreaterThan(naive.max()!, 300, "the nearest point alone jumps between legs")
        XCTAssertEqual(matcher.direction, .forward)
    }

    func testJoiningMidwayAndWhatIsLeft() throws {
        let line = switchbacks
        let trail = profile(line) { 1_500 + 0.12 * $0 }
        var matcher = TrailMatcher(profile: trail)
        let length = trail.points.last!.distance
        // Onto the trail 1 km along, at a leg's middle, walking up.
        let fixes = walk(line, duration: 900, seed: 11) { 1_000 + 1.2 * $0 }
        var last: TrailProgress?
        for (i, f) in fixes.enumerated() {
            last = matcher.update(f.fix)
            if i >= 15 { XCTAssertEqual(last!.along, f.along, accuracy: 40, "fix \(i)") }
        }
        let p = try XCTUnwrap(last)
        let at = fixes.last!.along
        XCTAssertEqual(p.direction, .forward)
        XCTAssertEqual(p.remaining, length - at, accuracy: 40)
        XCTAssertEqual(p.done, at, accuracy: 40)
        XCTAssertTrue(p.topAhead)
        XCTAssertEqual(p.climbToTop, 0.12 * (length - at), accuracy: 10)
        XCTAssertEqual(p.descentToTop, 0, accuracy: 1)
        XCTAssertEqual(p.timeToTop, WalkingTime.din33466(distance: length - at, ascent: 0.12 * (length - at), descent: 0), accuracy: 120)
        XCTAssertLessThan(p.offTrail, 35)
        XCTAssertGreaterThan(p.confidence, 0.6)
    }

    /// Up to the end of a line and back down it: the direction turns, and what's left is
    /// then the way back.
    func testOutAndBack() throws {
        let line = [SIMD2(0.0, 0), SIMD2(600, 300), SIMD2(900, 900), SIMD2(1_000, 1_600)]
        let trail = profile(line) { 1_200 + 0.2 * $0 }
        let length = trail.points.last!.distance
        let speed = 1.3, turn = length / speed
        var matcher = TrailMatcher(profile: trail)
        let fixes = walk(line, duration: 2 * turn, seed: 3) { t in t < turn ? speed * t : max(0, length - speed * (t - turn)) }
        var sawForward = false
        for (i, f) in fixes.enumerated() {
            let p = matcher.update(f.fix)!
            if i >= 5 { XCTAssertEqual(p.along, f.along, accuracy: 40, "fix \(i)") }
            if matcher.direction == .forward { sawForward = true }
            // Well on the way down: heading back to the start.
            let t = f.fix.time.timeIntervalSince(fixes[0].fix.time)
            if t > turn + 120, f.along > 100 {
                XCTAssertEqual(p.direction, .backward, "fix \(i)")
                XCTAssertEqual(p.remaining, f.along, accuracy: 40)
                XCTAssertEqual(p.descentToEnd, 0.2 * f.along, accuracy: 12)
                XCTAssertFalse(p.topAhead, "the top is behind on the way down")
                XCTAssertTrue(p.isBehind(f.along + 100))
            }
        }
        XCTAssertTrue(sawForward)
    }

    /// A loop starts and ends at one spot: the start is at the start, and coming back round
    /// is at the end, not back at zero. Walked the other way round, it's the same.
    func testLoopBothWays() {
        let line = (0...72).map { k -> SIMD2<Double> in
            let a = Double(k) / 72 * 2 * .pi
            return SIMD2(500 * sin(a), 500 - 500 * cos(a))
        }
        let trail = profile(line)
        let length = trail.points.last!.distance
        for reverse in [false, true] {
            var matcher = TrailMatcher(profile: trail)
            let fixes = walk(line, duration: length / 1.25, seed: reverse ? 5 : 9) { t in
                reverse ? length - 1.25 * t : 1.25 * t
            }
            for (i, f) in fixes.enumerated() {
                let p = matcher.update(f.fix)!
                if i >= 20 { XCTAssertEqual(p.along, f.along, accuracy: 40, "fix \(i), reverse \(reverse)") }
            }
            XCTAssertEqual(matcher.direction, reverse ? .backward : .forward)
            XCTAssertLessThan(matcher.progress!.remaining, 50, "back round where it started: at the end")
        }
    }

    func testOffTheTrail() throws {
        let line = [SIMD2(0.0, 0), SIMD2(2_000, 0)]
        var matcher = TrailMatcher(profile: profile(line))
        let start = Date()
        var p: TrailProgress?
        for k in 0..<20 {
            p = matcher.update(TrailFix(position: projection.latLon(SIMD2(500 + Double(k) * 3, 150)), accuracy: 10,
                                        time: start.addingTimeInterval(Double(k) * 3)))
        }
        let off = try XCTUnwrap(p)
        XCTAssertEqual(off.offTrail, 150, accuracy: 1)
        XCTAssertLessThan(off.confidence, 0.1)
        // Back on the trail somewhere else: picked up within a few fixes.
        for k in 0..<6 {
            p = matcher.update(TrailFix(position: projection.latLon(SIMD2(1_400 + Double(k) * 4, 5)), accuracy: 10,
                                        time: start.addingTimeInterval(200 + Double(k) * 3)))
        }
        XCTAssertEqual(try XCTUnwrap(p).along, 1_420, accuracy: 20)
        XCTAssertGreaterThan(try XCTUnwrap(p).confidence, 0.6)
    }

    func testPositionAlongTheLine() {
        let matcher = TrailMatcher(line: [projection.latLon(SIMD2(0, 0)), projection.latLon(SIMD2(0, 1_000))])
        XCTAssertEqual(matcher.length, 1_000, accuracy: 2)
        let p = projection.point(matcher.position(at: 333))
        XCTAssertEqual(p.y, 333, accuracy: 1)
        XCTAssertEqual(p.x, 0, accuracy: 0.5)
    }
}
