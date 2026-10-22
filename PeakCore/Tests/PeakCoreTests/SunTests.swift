import XCTest
@testable import PeakCore

final class SunTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ hours: Double = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.timeZone = TimeZone(identifier: "UTC")
        let midnight = Calendar(identifier: .gregorian).date(from: c)!
        return midnight.addingTimeInterval(hours * 3_600)
    }

    /// Values from NOAA's solar calculator (gml.noaa.gov/grad/solcalc, its main.js run as
    /// published): azimuth, elevation before refraction, declination and equation of time.
    func testPositionMatchesNOAA() {
        let cases: [(date: Date, lat: Double, lon: Double, az: Double, el: Double, dec: Double, eot: Double)] = [
            (utc(2026, 6, 21, 10), 45.9837, 7.7856, 133.2381, 60.9666, 23.4381, -1.806),        // Gornergrat
            (utc(2026, 10, 21, 16.5), 45.9837, 7.7856, 254.6926, -0.4055, -10.8669, 15.442),
            (utc(2026, 1, 15, 2.5), -33.8688, 151.2093, 334.4354, 76.0751, -21.1408, -9.267),   // Sydney
            (utc(2026, 10, 21, 20), -54.8019, -68.303, 293.0485, 28.3486, -10.9186, 15.465),    // Ushuaia
            (utc(2026, 3, 20, 17), -0.1807, -78.4678, 87.6355, 84.6848, 0.0390, -7.371),        // Quito
            (utc(2026, 12, 21, 11), 69.6492, 18.9553, 184.0803, -3.1414, -23.4372, 1.944),      // Tromsø
            (utc(2024, 9, 1, 23.5), 40.015, -105.27, 261.1912, 22.3478, 7.8168, 0.291),         // Boulder
        ]
        for c in cases {
            let sun = Sun.position(at: c.date, latitude: c.lat, longitude: c.lon)
            let label = "\(c.lat), \(c.lon) at \(c.date)"
            // NOAA's azimuth goes through acos, which loses precision near the zenith (Quito).
            XCTAssertEqual(azimuthDifference(sun.azimuth, c.az), 0, accuracy: c.el > 80 ? 0.05 : 0.002, label)
            XCTAssertEqual(sun.elevation, c.el, accuracy: 0.002, label)
            XCTAssertEqual(sun.declination, c.dec, accuracy: 0.001, label)
            XCTAssertEqual(sun.equationOfTime, c.eot, accuracy: 0.002, label)
        }
    }

    /// At sea level the refraction model agrees with NOAA's (which is in terms of the
    /// elevation before refraction) to about 0.01°.
    func testRefractionAtSeaLevelMatchesNOAA() {
        func noaa(_ e: Double) -> Double {
            let te = tan(e * .pi / 180)
            let arcsec: Double
            if e > 5 { arcsec = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5) }
            else if e > -0.575 { arcsec = 1_735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711))) }
            else { arcsec = -20.774 / te }
            return arcsec / 3_600
        }
        for e in [-0.5, -0.2, 0, 0.5, 1, 2, 4, 6, 10, 20, 45] {
            XCTAssertEqual(Sun.apparentElevation(e) - e, noaa(e), accuracy: 0.012, "elevation \(e)")
        }
    }

    /// From a height, refraction is weaker above the eye's level (thinner air), and below
    /// it grows with the depression, continuously across the level.
    func testRefractionFromAHeight() {
        let sea = Sun.refraction(apparent: 0), high = Sun.refraction(apparent: 0, height: 4_000)
        XCTAssertEqual(sea, 0.568, accuracy: 0.005)
        XCTAssertEqual(high / sea, 0.67, accuracy: 0.02)
        XCTAssertEqual(Sun.refraction(apparent: -0.001, height: 4_000), high, accuracy: 0.002)
        let below = Sun.refraction(apparent: -2, height: 4_000)
        XCTAssertGreaterThan(below, high + 0.25)
        XCTAssertLessThan(below, 1.0)
    }

    /// Flat-horizon sunrise and sunset match NOAA's calculator to within a minute (NOAA
    /// iterates only twice). Times are UTC minutes after midnight of the NOAA day.
    func testAstronomicalSunriseAndSunsetMatchNOAA() {
        let cases: [(zone: String, day: Date, lat: Double, lon: Double, rise: Date, set: Date)] = [
            ("Europe/Zurich", utc(2026, 6, 21, 12), 45.9837, 7.7856, utc(2026, 6, 21, 218.08 / 60), utc(2026, 6, 21, 1_163.27 / 60)),
            ("Europe/Zurich", utc(2026, 10, 21, 12), 45.9837, 7.7856, utc(2026, 10, 21, 353.67 / 60), utc(2026, 10, 21, 992.54 / 60)),
            ("Australia/Sydney", utc(2026, 1, 15, 2), -33.8688, 151.2093, utc(2026, 1, 14, 1_139.50 / 60), utc(2026, 1, 15, 549.00 / 60)),
            ("America/Argentina/Ushuaia", utc(2026, 10, 21, 15), -54.8019, -68.303, utc(2026, 10, 21, 549.18 / 60), utc(2026, 10, 21, 1_407.67 / 60)),
        ]
        for c in cases {
            let day = DateInterval.day(containing: c.day, in: TimeZone(identifier: c.zone)!)
            let sun = SunDay.astronomical(latitude: c.lat, longitude: c.lon, interval: day)
            XCTAssertEqual(sun.crossings.count, 2, c.zone)
            XCTAssertEqual(sun.firstLight!.date.timeIntervalSince(c.rise), 0, accuracy: 60, "rise \(c.zone)")
            XCTAssertEqual(sun.lastLight!.date.timeIntervalSince(c.set), 0, accuracy: 60, "set \(c.zone)")
        }
    }

    func testPolarDayAndNight() {
        let tromso = TimeZone(identifier: "Europe/Oslo")!
        let winter = SunDay.astronomical(latitude: 69.6492, longitude: 18.9553,
                                         interval: .day(containing: utc(2026, 12, 21, 12), in: tromso))
        XCTAssertTrue(winter.neverInSight)
        XCTAssertNil(winter.firstLight)
        let summer = SunDay.astronomical(latitude: 69.6492, longitude: 18.9553,
                                         interval: .day(containing: utc(2026, 6, 21, 12), in: tromso))
        XCTAssertTrue(summer.alwaysInSight)
        XCTAssertEqual(summer.duration, 86_400, accuracy: 1)
    }

    // MARK: Terrain

    /// A horizon given ray by ray, as the renderer would.
    private func profile(at observer: GeoPoint, _ elevation: (Double) -> Double) -> HorizonProfile {
        var settings = HorizonSettings()
        settings.azimuthStep = 0.1
        let rays = 3_600
        let elevations = (0..<rays).map { Float(elevation(Double($0) * 0.1)) }
        let envelope = elevations.map { HorizonProfile.EnvelopePoint(elevation: $0, distance: 20_000, startsSegment: false) }
        return HorizonProfile(observer: observer, settings: settings, elevations: elevations,
                              distances: [Float](repeating: 20_000, count: rays),
                              envelopeStart: Array(0...rays), envelope: envelope)
    }

    private let gornergrat = GeoPoint(latitude: 45.9837, longitude: 7.7856, height: 3_100)
    private let zurich = TimeZone(identifier: "Europe/Zurich")!

    /// A ridge 6° high across the west: the sun sets when its upper limb, refracted, meets
    /// 6°, well before the flat-horizon sunset.
    func testSunsetBehindARidge() {
        let ridge = profile(at: gornergrat) { $0 > 200 && $0 < 320 ? 6 : -1.5 }
        let day = DateInterval.day(containing: utc(2026, 10, 21, 12), in: zurich)
        let sun = SunDay(horizon: ridge, interval: day)
        XCTAssertEqual(sun.crossings.count, 2)
        let set = try! XCTUnwrap(sun.lastLight)
        XCTAssertFalse(set.rising)
        XCTAssertEqual(set.elevation, 6, accuracy: 1e-6)
        let p = Sun.position(at: set.date, latitude: gornergrat.latitude, longitude: gornergrat.longitude)
        let top = Sun.apparentElevation(p.elevation, height: gornergrat.height) + p.semidiameter
        XCTAssertEqual(top, 6, accuracy: 0.003)
        let flat = SunDay.astronomical(latitude: gornergrat.latitude, longitude: gornergrat.longitude, interval: day)
        XCTAssertLessThan(set.date, flat.lastLight!.date.addingTimeInterval(-30 * 60))
        // Its center goes earlier than its top, by the time it takes to sink by its radius.
        let center = SunDay(horizon: ridge, interval: day, limb: .center)
        let gap = set.date.timeIntervalSince(center.lastLight!.date)
        XCTAssertGreaterThan(gap, 60)
        XCTAssertLessThan(gap, 180)
    }

    /// A spire 1° wide and 30° high in the sun's path in the afternoon: it goes behind it
    /// and comes back out, then sets.
    func testSunDipsBehindASpireAndComesBack() {
        let day = DateInterval.day(containing: utc(2026, 10, 21, 12), in: zurich)
        let when = utc(2026, 10, 21, 13)
        let at = Sun.position(at: when, latitude: gornergrat.latitude, longitude: gornergrat.longitude)
        let spire = profile(at: gornergrat) { abs(azimuthDifference($0, at.azimuth)) < 0.5 ? 30 : 0 }
        let sun = SunDay(horizon: spire, interval: day)
        XCTAssertEqual(sun.crossings.map(\.rising), [true, false, true, false])
        let periods = sun.periods
        XCTAssertEqual(periods.count, 2)
        XCTAssertTrue(periods[0].end < when && when < periods[1].start)
        XCTAssertFalse(sun.isInSight(at: when))
        // It's hidden while within 0.5° plus its radius of the spire's middle, a few minutes.
        let hidden = periods[1].start.timeIntervalSince(periods[0].end)
        XCTAssertGreaterThan(hidden, 3 * 60)
        XCTAssertLessThan(hidden, 8 * 60)
    }

    /// In a deep gorge the sun never clears the walls in winter.
    func testNeverAboveTheTerrain() {
        let gorge = profile(at: gornergrat) { _ in 40 }
        let day = DateInterval.day(containing: utc(2026, 12, 21, 12), in: zurich)
        let sun = SunDay(horizon: gorge, interval: day)
        XCTAssertTrue(sun.neverInSight)
        XCTAssertEqual(sun.duration, 0)
        // Flat, it's up for about 8.7 hours.
        let flat = SunDay.astronomical(latitude: gornergrat.latitude, longitude: gornergrat.longitude, interval: day)
        XCTAssertEqual(flat.duration / 3_600, 8.75, accuracy: 0.2)
    }

    /// Midnight sun with a peak low in the north: the sun goes behind it around midnight.
    func testMidnightSunBehindANorthernPeak() {
        let observer = GeoPoint(latitude: 69.6492, longitude: 18.9553, height: 10)
        let peak = profile(at: observer) { abs(azimuthDifference($0, 0)) < 15 ? 8 : 0 }
        let day = DateInterval.day(containing: utc(2026, 6, 21, 12), in: TimeZone(identifier: "Europe/Oslo")!)
        let sun = SunDay(horizon: peak, interval: day)
        XCTAssertFalse(sun.alwaysInSight)
        XCTAssertGreaterThan(sun.duration, 18 * 3_600)
        XCTAssertLessThan(sun.duration, 23 * 3_600)
    }

    /// Rendered terrain: a cone standing where the sun goes down. The sun sets behind it at
    /// its distance, early; on flat ground the same place gets the almanac's sunset.
    func testSunsetBehindARenderedCone() throws {
        let place = (lat: 46.0, lon: 8.0)
        let day = DateInterval.day(containing: utc(2026, 10, 21, 12), in: zurich)
        // Where the sun is when it's 6° up in the evening.
        var t = utc(2026, 10, 21, 14)
        while Sun.position(at: t, latitude: place.lat, longitude: place.lon).elevation > 6 { t += 60 }
        let azimuth = Sun.position(at: t, latitude: place.lat, longitude: place.lon).azimuth
        let distance = 15_000.0
        let rad = Double.pi / 180
        let coneLat = place.lat + distance * cos(azimuth * rad) / 111_200
        let coneLon = place.lon + distance * sin(azimuth * rad) / (111_200 * cos(place.lat * rad))
        let terrain = TestTerrain.cones([.init(latitude: coneLat, longitude: coneLon, height: 2_500, radius: 7_000)])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: place.lat, longitude: place.lon)
        var settings = HorizonSettings()
        settings.maxDistance = 50_000
        let horizon = renderer.render(from: observer, settings: settings)
        let sun = SunDay(horizon: horizon, interval: day)
        let set = try XCTUnwrap(sun.lastLight)
        XCTAssertEqual(set.distance, distance, accuracy: 7_000)
        XCTAssertGreaterThan(set.elevation, 2)
        XCTAssertLessThan(set.date, t)

        let flat = HorizonRenderer(terrain: TestTerrain.cones([]))
        let flatHorizon = flat.render(from: flat.observer(latitude: place.lat, longitude: place.lon), settings: settings)
        let flatSun = SunDay(horizon: flatHorizon, interval: day)
        let almanac = SunDay.astronomical(latitude: place.lat, longitude: place.lon, interval: day)
        XCTAssertEqual(flatSun.lastLight!.date.timeIntervalSince(almanac.lastLight!.date), 0, accuracy: 60)
        XCTAssertEqual(flatSun.firstLight!.date.timeIntervalSince(almanac.firstLight!.date), 0, accuracy: 60)
    }

    /// From a summit the sun stays later than in the valley, and the range check notices
    /// that the 2°×2° test terrain stops short of the renderer's 150 km.
    func testSummitLight() {
        let summit = (lat: 46.0, lon: 8.0)
        let terrain = TestTerrain.cones([.init(latitude: summit.lat, longitude: summit.lon, height: 3_000, radius: 6_000)])
        let renderer = HorizonRenderer(terrain: terrain)
        let horizon = renderer.summitHorizon(latitude: summit.lat, longitude: summit.lon, height: 3_500)
        let day = DateInterval.day(containing: utc(2026, 10, 21, 12), in: zurich)
        let light = renderer.summitLight(horizon: horizon, day: day, ceiling: 500)
        XCTAssertFalse(light.rangeLimited)
        XCTAssertNotNil(light.reachAtLastLight)
        let almanac = SunDay.astronomical(latitude: summit.lat, longitude: summit.lon, interval: day)
        // Seeing over the curve of the Earth from 3.5 km up (a dip of 1.8°, and more
        // refraction below the level): about a quarter of an hour later.
        let later = light.lastLight!.timeIntervalSince(almanac.lastLight!.date)
        XCTAssertGreaterThan(later, 10 * 60)
        XCTAssertLessThan(later, 20 * 60)
        XCTAssertLessThan(light.firstLight!, almanac.firstLight!.date)
        // Something 4,800 m high beyond the edge of the loaded terrain could hide it.
        XCTAssertTrue(renderer.summitLight(horizon: horizon, day: day, ceiling: 4_800).rangeLimited)
    }

    func testWalkingTime() {
        // 12 km with 600 m up and down: 3 h on the level, 3.2 h vertical → 3.2 + 1.5.
        XCTAssertEqual(WalkingTime.din33466(distance: 12_000, ascent: 600, descent: 600) / 3_600, 4.7, accuracy: 1e-9)
        // Flat: 4 km/h.
        XCTAssertEqual(WalkingTime.din33466(distance: 8_000, ascent: 0, descent: 0), 7_200, accuracy: 1e-9)
        let points = (0...100).map { TrailProfile.Point(distance: Double($0) * 50, elevation: 1_000 + Double(min($0, 60)) * 15,
                                                         position: LatLon(46, 8 + Double($0) * 0.0006)) }
        let profile = TrailProfile(points: points, gain: 900, loss: 0, highest: 1_900, lowest: 1_000)
        XCTAssertEqual(profile.highestIndex, 60)
        XCTAssertEqual(profile.climb(from: 0, to: 60).ascent, 900, accuracy: 1e-9)
        XCTAssertEqual(profile.climb(from: 60, to: 0).descent, 900, accuracy: 1e-9)
        // 3 km and 900 m up: 3 h vertical + 0.375 h.
        XCTAssertEqual(profile.walkingTime(from: 0, to: 60) / 3_600, 3.375, accuracy: 1e-9)
    }
}
