import Foundation

/// When the sun is in sight over the real terrain on one day, for one observer: real
/// sunrise and sunset, not the flat-horizon ones.
public struct SunDay: Sendable {
    /// Which part of the sun has to clear the terrain to count as in sight.
    public enum Limb: Sendable {
        /// Any of it: first and last light.
        case upper
        /// Its center, as for the sun "half set".
        case center
    }

    /// The sun coming into sight (`rising`) or going out of it.
    public struct Crossing: Sendable, Equatable {
        public var date: Date
        public var azimuth: Double
        /// Apparent elevation of the terrain the sun crosses, degrees.
        public var elevation: Double
        public var rising: Bool
        /// Distance to the terrain it crosses, meters (0 for a flat horizon).
        public var distance: Double
    }

    /// The day searched, usually local midnight to midnight.
    public var interval: DateInterval
    public var limb: Limb
    /// Every crossing in the day, in order. A peak the sun dips behind and comes out from
    /// gives a setting crossing followed by a rising one.
    public var crossings: [Crossing]
    /// Whether the sun is in sight at the start of the day (midnight sun).
    public var inSightAtStart: Bool

    /// The stretches of the day with the sun in sight.
    public var periods: [DateInterval] {
        var out: [DateInterval] = []
        var start: Date? = inSightAtStart ? interval.start : nil
        for c in crossings {
            if c.rising {
                start = c.date
            } else if let s = start {
                out.append(DateInterval(start: s, end: c.date))
                start = nil
            }
        }
        if let s = start { out.append(DateInterval(start: s, end: interval.end)) }
        return out
    }

    /// The sun in sight all day (polar day, and nothing high enough in the way).
    public var alwaysInSight: Bool { inSightAtStart && crossings.isEmpty }
    /// The sun never in sight: polar night, or terrain higher than it ever gets.
    public var neverInSight: Bool { !inSightAtStart && crossings.isEmpty }
    /// The first time the sun comes into sight: real sunrise.
    public var firstLight: Crossing? { crossings.first(where: \.rising) }
    /// The last time it goes out of sight: real sunset.
    public var lastLight: Crossing? { crossings.last(where: { !$0.rising }) }
    /// Time with the sun in sight, seconds.
    public var duration: TimeInterval { periods.reduce(0) { $0 + $1.duration } }

    public func isInSight(at date: Date) -> Bool {
        periods.contains { $0.start <= date && date < $0.end }
    }

    /// When the sun is in sight over the terrain seen from `horizon`'s observer during
    /// `interval`. The sun is sampled every `step` seconds and each change refined to
    /// within a second, so a gap or a spire narrower than the sun moves in `step` (about
    /// 0.06° in 15 s) can be missed.
    public init(horizon: HorizonProfile, interval: DateInterval, limb: Limb = .upper, step: TimeInterval = 15) {
        let observer = horizon.observer
        self.init(latitude: observer.latitude, longitude: observer.longitude, height: observer.height,
                  interval: interval, limb: limb, refraction: horizon.settings.refraction, step: step) { azimuth in
            let i = Int((normalizedAzimuth(azimuth) / horizon.azimuthStep).rounded()) % horizon.count
            return (horizon.elevation(atAzimuth: azimuth), Double(horizon.distances[i]))
        }
    }

    /// The same over a flat horizon at elevation 0 seen from sea level: the astronomical
    /// sunrise and sunset almanacs give (the upper limb's center at −0.83°).
    public static func astronomical(latitude: Double, longitude: Double, interval: DateInterval,
                                    limb: Limb = .upper) -> SunDay {
        SunDay(latitude: latitude, longitude: longitude, height: 0, interval: interval, limb: limb,
               refraction: 0.13, step: 120) { _ in (0, 0) }
    }

    /// The general search, over a horizon given as azimuth → (apparent elevation, distance).
    public init(latitude: Double, longitude: Double, height: Double, interval: DateInterval, limb: Limb,
                refraction k: Double, step: TimeInterval, horizon: (Double) -> (elevation: Double, distance: Double)) {
        self.interval = interval
        self.limb = limb
        /// How far the chosen part of the sun clears the terrain (degrees; negative: hidden).
        func clearance(_ date: Date) -> (Double, SunPosition) {
            let sun = Sun.position(at: date, latitude: latitude, longitude: longitude)
            // Below −10° nothing on Earth hides it any further; skip the horizon lookup.
            if sun.elevation < -10 { return (sun.elevation + 5, sun) }
            let apparent = Sun.apparentElevation(sun.elevation, height: height, k: k)
            let top = apparent + (limb == .upper ? sun.semidiameter : 0)
            return (top - horizon(sun.azimuth).elevation, sun)
        }
        var crossings: [Crossing] = []
        var t0 = interval.start
        var (c0, _) = clearance(t0)
        inSightAtStart = c0 > 0
        let count = max(1, Int((interval.duration / step).rounded(.up)))
        for n in 1...count {
            let t1 = n == count ? interval.end : interval.start.addingTimeInterval(Double(n) * step)
            let (c1, _) = clearance(t1)
            if (c0 > 0) != (c1 > 0) {
                // Refine by bisection, keeping the sign change between lo and hi.
                var lo = t0, hi = t1
                while hi.timeIntervalSince(lo) > 0.5 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    if (clearance(mid).0 > 0) == (c0 > 0) { lo = mid } else { hi = mid }
                }
                let at = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                let sun = clearance(at).1
                let terrain = horizon(sun.azimuth)
                crossings.append(Crossing(date: at, azimuth: sun.azimuth, elevation: terrain.elevation,
                                          rising: c1 > 0, distance: terrain.distance))
            }
            t0 = t1
            c0 = c1
        }
        self.crossings = crossings
    }

    /// The sun's path over `interval`: where it is (apparent elevation, from `height`) every
    /// `step` seconds.
    public static func path(latitude: Double, longitude: Double, height: Double = 0, interval: DateInterval,
                            step: TimeInterval = 120, k: Double = 0.13) -> [(date: Date, azimuth: Double, elevation: Double)] {
        stride(from: 0, through: interval.duration, by: step).map { s in
            let date = interval.start.addingTimeInterval(s)
            let sun = Sun.position(at: date, latitude: latitude, longitude: longitude)
            return (date, sun.azimuth, Sun.apparentElevation(sun.elevation, height: height, k: k))
        }
    }
}

extension DateInterval {
    /// The calendar day containing `date` in `timeZone`: midnight to midnight there.
    public static func day(containing date: Date, in timeZone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }
}

/// When the sun reaches a summit in the morning and leaves it in the evening: the light
/// that makes alpenglow, seen from below.
public struct SummitLight: Sendable {
    public var day: SunDay
    /// How far the loaded terrain reaches toward the sun at last light, meters; nil when
    /// it reaches the renderer's full range.
    public var reachAtLastLight: Double?
    public var reachAtFirstLight: Double?
    /// The terrain ran out before it could rule out something farther hiding the sun at
    /// first or last light: those times may be later (morning) or earlier (evening).
    public var rangeLimited: Bool

    public var firstLight: Date? { day.firstLight?.date }
    public var lastLight: Date? { day.lastLight?.date }
}

extension HorizonRenderer {
    /// How far the terrain reaches from `observer` toward `azimuth`, meters, up to `limit`.
    public func reach(from observer: GeoPoint, azimuth: Double, upTo limit: Double,
                      settings: HorizonSettings = HorizonSettings()) -> Double {
        let march = March(observer: observer, settings: settings)
        let ray = GreatCircleRay(sphere: march.sphere, longitude: observer.longitude, azimuth: azimuth)
        var last = 0.0
        for (k, d) in march.samples.enumerated() {
            if d > limit { return limit }
            let p = ray.point(cosDelta: march.cosDelta[k], sinDelta: march.sinDelta[k])
            if terrain.height(latitude: p.latitude, longitude: p.longitude).isNaN { return last }
            last = d
        }
        return limit
    }

    /// The horizon from a summit standing at `height` (the peak database's elevation, not
    /// the terrain's), using only the terrain loaded. The ground within `clear` meters is
    /// ignored: it's the summit itself, where the DEM is coarse and often off by a few
    /// meters or pixels.
    public func summitHorizon(latitude: Double, longitude: Double, height: Double, clear: Double = 120,
                              maxDistance: Double = 150_000) -> HorizonProfile {
        var settings = HorizonSettings()
        settings.minDistance = clear
        settings.maxDistance = maxDistance
        return render(from: GeoPoint(latitude: latitude, longitude: longitude, height: height + 2), settings: settings)
    }

    /// When the sun reaches and leaves a summit on `day`. `ceiling` is the highest the
    /// terrain beyond the loaded area could plausibly be (meters): where the terrain runs
    /// out short of the renderer's range and something that high could stand above the
    /// sun's path at first or last light, the result says so.
    public func summitLight(horizon: HorizonProfile, day: DateInterval, ceiling: Double) -> SummitLight {
        let sun = SunDay(horizon: horizon, interval: day)
        let observer = horizon.observer
        let limit = horizon.settings.maxDistance
        let effectiveRadius = 6_371_000 / (1 - horizon.settings.refraction)
        func check(_ c: SunDay.Crossing?) -> (Double?, Bool) {
            guard let c else { return (nil, false) }
            let reach = self.reach(from: observer, azimuth: c.azimuth, upTo: limit, settings: horizon.settings)
            guard reach < limit - 1 else { return (nil, false) }
            // The steepest anything `ceiling` high beyond the edge could look. It falls off with
            // distance once past the edge, so the edge is the worst case.
            let d = max(reach, 1)
            let angle = atan((ceiling - observer.height) / d - d / (2 * effectiveRadius)) * 180 / .pi
            return (reach, angle > c.elevation)
        }
        let (first, firstLimited) = check(sun.firstLight)
        let (last, lastLimited) = check(sun.lastLight)
        return SummitLight(day: sun, reachAtLastLight: last, reachAtFirstLight: first,
                           rangeLimited: firstLimited || lastLimited)
    }
}

/// Walking time by DIN 33466, the German and Swiss standard for hiking signposts:
/// 4 km/h on the level, 300 m/h climbing and 500 m/h descending. The vertical and the
/// horizontal times are worked out apart; the larger counts in full and the smaller half.
public enum WalkingTime {
    public static func din33466(distance: Double, ascent: Double, descent: Double) -> TimeInterval {
        let horizontal = distance / 4_000
        let vertical = max(0, ascent) / 300 + max(0, descent) / 500
        return (max(horizontal, vertical) + min(horizontal, vertical) / 2) * 3_600
    }
}

extension TrailProfile {
    /// Index of the highest point along the main line.
    public var highestIndex: Int {
        points.indices.max { points[$0].elevation < points[$1].elevation } ?? 0
    }

    /// Climb and descent walking from point `from` to point `to` (either way), ignoring
    /// changes smaller than `threshold` meters, which are the terrain model's noise.
    public func climb(from: Int, to: Int, threshold: Double = 8) -> (ascent: Double, descent: Double) {
        guard points.indices.contains(from), points.indices.contains(to), from != to else { return (0, 0) }
        let indices = from < to ? Array(from...to) : Array((to...from).reversed())
        var anchor = points[indices[0]].elevation, up = 0.0, down = 0.0
        for i in indices.dropFirst() {
            let d = points[i].elevation - anchor
            if d >= threshold { up += d; anchor = points[i].elevation } else if d <= -threshold { down -= d; anchor = points[i].elevation }
        }
        let rest = points[indices.last!].elevation - anchor
        if rest > 0 { up += rest } else { down -= rest }
        return (up, down)
    }

    /// DIN 33466 walking time from point `from` to point `to`, seconds.
    public func walkingTime(from: Int, to: Int) -> TimeInterval {
        guard points.indices.contains(from), points.indices.contains(to) else { return 0 }
        let c = climb(from: from, to: to)
        return WalkingTime.din33466(distance: abs(points[to].distance - points[from].distance),
                                    ascent: c.ascent, descent: c.descent)
    }
}
