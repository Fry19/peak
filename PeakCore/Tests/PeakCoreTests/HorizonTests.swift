import XCTest
@testable import PeakCore

final class HorizonTests: XCTestCase {
    /// Seen from 300 m above flat ground, the skyline is the dip of the horizon,
    /// −√(2h/R′) with R′ = R/(1 − k): an exact check of curvature and refraction.
    func testDipOfTheHorizon() {
        let flat = TestTerrain.cones([], base: 0)
        let renderer = HorizonRenderer(terrain: flat)
        // The horizon is about 66 km away, inside the 2°×2° test terrain.
        let observer = GeoPoint(latitude: 46, longitude: 8, height: 300)
        var settings = HorizonSettings()
        settings.azimuthStep = 15
        let profile = renderer.render(from: observer, settings: settings)
        for i in 0..<profile.count {
            let azimuth = profile.azimuth(ofRay: i)
            let r = WGS84.radius(latitude: 46 * .pi / 180, azimuth: azimuth * .pi / 180) / (1 - 0.13)
            let dip = -(2 * 300 / r).squareRoot() * 180 / .pi
            XCTAssertEqual(Double(profile.elevations[i]), dip, accuracy: 0.002, "azimuth \(azimuth)")
            // The horizon is √(2hR′) away.
            XCTAssertEqual(Double(profile.distances[i]), (2 * 300 * r).squareRoot(), accuracy: 8_000)
        }
    }

    /// A cone 12 km east with its tip on a DEM grid node: the skyline toward it must
    /// reach the summit's apparent elevation as computed independently on the ellipsoid.
    func testConeSummitMatchesExactGeometry() {
        // Tiles have 600 rows and columns per degree; node (row 0, col 93) of tile N45E008.
        let summit = GeoPoint(latitude: 46, longitude: 8 + 93.0 / 600, height: 2_500)
        let terrain = TestTerrain.cones([.init(latitude: summit.latitude, longitude: summit.longitude,
                                               height: 2_000, radius: 8_000)])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46, longitude: 8)
        XCTAssertEqual(observer.height, 501.6, accuracy: 0.01)
        var settings = HorizonSettings()
        settings.maxDistance = 40_000
        let profile = renderer.render(from: observer, settings: settings)
        XCTAssertEqual(profile.count, 3600)

        let exact = LocalFrame(origin: observer).look(at: summit, refraction: 0.13)
        let rendered = profile.elevation(atAzimuth: exact.azimuth)
        // Rays are 0.1° apart and samples 15 m apart, so they pass up to ~10 m from the tip
        // on a 1:4 slope: at most ~3 m low, 0.015° at this distance. Never high.
        XCTAssertEqual(rendered, exact.elevation, accuracy: 0.02)
        XCTAssertLessThanOrEqual(rendered, exact.elevation + 0.002)
        let peak = profile.elevations.indices.max { profile.elevations[$0] < profile.elevations[$1] }!
        XCTAssertEqual(azimuthDifference(profile.azimuth(ofRay: peak), exact.azimuth), 0, accuracy: 0.11)
        // Profile distances are along the ground.
        let enu = LocalFrame(origin: observer).enu(summit)
        XCTAssertEqual(Double(profile.distances[peak]), (enu.x * enu.x + enu.y * enu.y).squareRoot(), accuracy: 100)

        // Looking west over flat ground, the skyline is just below 0°.
        let west = profile.elevation(atAzimuth: 270)
        XCTAssertLessThan(west, 0)
        XCTAssertGreaterThan(west, -0.1)
    }

    /// A small near hill in front of a big far mountain: the hill's crest is a ridge,
    /// the mountain is the skyline, and depth queries find each one.
    func testRidgeInFrontOfMountain() {
        let near = destination(from: TestTerrain.center, azimuth: 0, distance: 4_000)
        let far = destination(from: TestTerrain.center, azimuth: 0, distance: 30_000)
        let terrain = TestTerrain.cones([
            .init(latitude: near.latitude, longitude: near.longitude, height: 300, radius: 1_500),
            .init(latitude: far.latitude, longitude: far.longitude, height: 3_000, radius: 6_000),
        ])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46, longitude: 8)
        var settings = HorizonSettings()
        settings.azimuthStep = 30
        settings.maxDistance = 60_000
        let profile = renderer.render(from: observer, settings: settings)

        let ridges = profile.ridges(ofRay: 0)
        XCTAssertEqual(ridges.count, 2, "\(ridges)")
        // The hill's crest is drawn as a ridge in front of the skyline (rays 1° apart, so that
        // the crest continues from ray to ray).
        settings.azimuthStep = 1
        let fine = renderer.render(from: observer, settings: settings)
        XCTAssertTrue(fine.ridgeSegments().contains { !$0.isSkyline && $0.azimuth0 < 3 && abs($0.distance - 4_000) < 300 })
        XCTAssertEqual(Double(ridges[0].distance), 4_000, accuracy: 200)
        XCTAssertEqual(Double(ridges[1].distance), 30_000, accuracy: 300)
        XCTAssertGreaterThan(ridges[1].elevation, ridges[0].elevation)

        // Just below the near crest we see the near hill; just above it, the far mountain.
        let crest = Double(ridges[0].elevation)
        XCTAssertEqual(profile.distance(atAzimuth: 0, elevation: crest - 0.05)!, 4_000, accuracy: 600)
        XCTAssertEqual(profile.distance(atAzimuth: 0, elevation: crest + 0.05)!, 30_000, accuracy: 6_000)
        XCTAssertNil(profile.distance(atAzimuth: 0, elevation: Double(profile.elevations[0]) + 0.1))
    }

    func testPeakBehindHigherRidgeIsHidden() {
        let wall = destination(from: TestTerrain.center, azimuth: 180, distance: 5_000)
        let hidden = destination(from: TestTerrain.center, azimuth: 180, distance: 20_000)
        let open = destination(from: TestTerrain.center, azimuth: 60, distance: 20_000)
        let terrain = TestTerrain.cones([
            .init(latitude: wall.latitude, longitude: wall.longitude, height: 1_500, radius: 3_000),
            .init(latitude: hidden.latitude, longitude: hidden.longitude, height: 2_000, radius: 4_000),
            .init(latitude: open.latitude, longitude: open.longitude, height: 2_000, radius: 4_000),
        ])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46, longitude: 8)
        let behind = renderer.visibility(of: GeoPoint(latitude: hidden.latitude, longitude: hidden.longitude, height: 2_500),
                                         from: observer)
        XCTAssertFalse(behind.isVisible)
        XCTAssertLessThan(behind.clearance, -1)
        let inTheOpen = renderer.visibility(of: GeoPoint(latitude: open.latitude, longitude: open.longitude, height: 2_500),
                                            from: observer)
        XCTAssertTrue(inTheOpen.isVisible)
        XCTAssertEqual(inTheOpen.azimuth, 60, accuracy: 0.01)
    }

    func testVisiblePeaksAndRidgeSegments() {
        let wall = destination(from: TestTerrain.center, azimuth: 180, distance: 5_000)
        let hidden = destination(from: TestTerrain.center, azimuth: 180, distance: 20_000)
        let open = destination(from: TestTerrain.center, azimuth: 60, distance: 20_000)
        let terrain = TestTerrain.cones([
            .init(latitude: wall.latitude, longitude: wall.longitude, height: 1_500, radius: 3_000),
            .init(latitude: hidden.latitude, longitude: hidden.longitude, height: 2_000, radius: 4_000),
            .init(latitude: open.latitude, longitude: open.longitude, height: 2_000, radius: 4_000),
        ])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46, longitude: 8)
        let peaks = [
            Peak(id: 1, name: "Hidden", latitude: hidden.latitude, longitude: hidden.longitude, elevation: 2_500),
            Peak(id: 2, name: "Open", latitude: open.latitude, longitude: open.longitude, elevation: 2_500),
            Peak(id: 3, name: "Too far", latitude: 47.5, longitude: 8, elevation: 4_000),
        ]
        let visible = renderer.visiblePeaks(peaks, from: observer, maxDistance: 80_000)
        XCTAssertEqual(visible.map(\.peak.name), ["Open"])
        XCTAssertEqual(visible[0].distance, 20_000, accuracy: 300)

        var settings = HorizonSettings()
        settings.azimuthStep = 1
        settings.maxDistance = 40_000
        let segments = renderer.render(from: observer, settings: settings).ridgeSegments()
        XCTAssertEqual(segments.filter(\.isSkyline).count, 360)
        // Looking south, the near cone hides the far one, so it is the skyline.
        XCTAssertTrue(segments.contains { $0.isSkyline && abs($0.azimuth0 - 180) < 1 && abs($0.distance - 5_000) < 300 })
    }

    /// Risen 1.5 km above the observer, the summit behind the wall comes into sight; the
    /// view's horizon then drops its depth map, which from up there holds far more points,
    /// and keeps the skyline as it was.
    func testSeenFromAboveTheWallAndWithoutDepth() {
        let wall = destination(from: TestTerrain.center, azimuth: 180, distance: 5_000)
        let hidden = destination(from: TestTerrain.center, azimuth: 180, distance: 20_000)
        let terrain = TestTerrain.cones([
            .init(latitude: wall.latitude, longitude: wall.longitude, height: 1_500, radius: 3_000),
            .init(latitude: hidden.latitude, longitude: hidden.longitude, height: 2_000, radius: 4_000),
        ])
        let renderer = HorizonRenderer(terrain: terrain)
        let ground = renderer.observer(latitude: 46, longitude: 8)
        var risen = ground
        risen.height += 1_500
        let summit = [Peak(id: 1, name: "Hidden", latitude: hidden.latitude, longitude: hidden.longitude, elevation: 2_500)]
        XCTAssertTrue(renderer.visiblePeaks(summit, from: ground, maxDistance: 80_000).isEmpty)
        XCTAssertEqual(renderer.visiblePeaks(summit, from: risen, maxDistance: 80_000).map(\.id), [1])

        var settings = HorizonSettings()
        settings.azimuthStep = 5
        settings.maxDistance = 40_000
        let below = renderer.render(from: ground, settings: settings)
        let above = renderer.render(from: risen, settings: settings)
        let points = { (p: HorizonProfile) in (0..<p.count).reduce(0) { $0 + p.envelope(ofRay: $1).count } }
        XCTAssertGreaterThan(points(above), 5 * points(below))

        let slim = above.withoutDepth()
        XCTAssertEqual(slim.elevations, above.elevations)
        XCTAssertEqual(slim.distances, above.distances)
        XCTAssertEqual(slim.count, above.count)
        XCTAssertEqual(points(slim), 0)
        XCTAssertNil(slim.distance(atAzimuth: 180, elevation: Double(above.elevations[36]) - 1))
        XCTAssertTrue(slim.ridges(ofRay: 36).isEmpty)
        XCTAssertEqual(slim.elevation(atAzimuth: 182.5), above.elevation(atAzimuth: 182.5))
    }

    func testEnvelopeIsSortedAndEndsAtTheSkyline() {
        let renderer = HorizonRenderer(terrain: TestTerrain.range())
        var settings = HorizonSettings()
        settings.azimuthStep = 4
        settings.maxDistance = 80_000
        let profile = renderer.render(from: renderer.observer(latitude: 46, longitude: 8), settings: settings)
        for i in 0..<profile.count {
            let env = Array(profile.envelope(ofRay: i))
            XCTAssertFalse(env.isEmpty)
            for j in 1..<env.count {
                XCTAssertGreaterThan(env[j].elevation, env[j - 1].elevation)
                XCTAssertGreaterThan(env[j].distance, env[j - 1].distance)
            }
            XCTAssertEqual(env.last!.elevation, profile.elevations[i])
        }
    }

    /// Flat ground at 300 m on a 1 arc-second grid, seen from 45.5°N 8.25°E: north, a rise
    /// 8 m high 370 m away (6.4 m above the eye) in front of a mountain 25 km off; east, a
    /// rise 25 m high in front of another; south-west, a mountain in the open; west, a rise
    /// 8 m high 120 m away, then a strip of missing data from 200 m. Each mountain has a summit just off the grid, 30 m above its cone.
    private func nearRiseScene() -> (terrain: Terrain, observer: GeoPoint, peaks: [Peak]) {
        let observer = GeoPoint(latitude: 45.5, longitude: 8.25, height: 301.6)
        let step = 1.0 / 3600, north = 45.8, west = 8.0, rows = 1_801, cols = 2_161
        struct Cone { var center: (latitude: Double, longitude: Double); var height: Double; var radius: Double }
        func at(_ azimuth: Double, _ distance: Double) -> (latitude: Double, longitude: Double) {
            destination(from: observer, azimuth: azimuth, distance: distance)
        }
        let cones = [Cone(center: at(0, 370), height: 8, radius: 250), Cone(center: at(90, 400), height: 25, radius: 250),
                     Cone(center: at(0, 25_000), height: 400, radius: 4_000), Cone(center: at(90, 25_000), height: 400, radius: 4_000),
                     Cone(center: at(225, 20_000), height: 400, radius: 4_000), Cone(center: at(270, 120), height: 8, radius: 60)]
        let gap = at(270, 200)
        var heights = [Int16](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            let lat = north - Double(r) * step
            for c in 0..<cols {
                let lon = west + Double(c) * step
                var h = 300.0
                for cone in cones {
                    let d = hypot((lat - cone.center.latitude) * 111_320, (lon - cone.center.longitude) * 111_320 * cos(lat * .pi / 180))
                    h = max(h, 300 + cone.height * max(0, 1 - d / cone.radius))
                }
                let missing = lon < gap.longitude && abs(lat - observer.latitude) < 0.0015
                heights[r * cols + c] = missing ? ElevationTile.noData : Int16(h.rounded())
            }
        }
        let tile = ElevationTile(south: 45, west: 8, rows: rows, cols: cols, originLatitude: north, originLongitude: west,
                                 stepLatitude: step, stepLongitude: step, heights: heights)
        let peaks = cones[2..<5].enumerated().map { i, cone in
            Peak(id: Int64(i + 1), name: "Summit \(i + 1)", latitude: cone.center.latitude + 0.37 * step,
                 longitude: cone.center.longitude - 0.41 * step, elevation: 730)
        }
        return (Terrain(tiles: [tile], missingIsSea: false), observer, peaks)
    }

    /// Ground near the eye only a few meters above it hides nothing with an allowance: the
    /// mountain behind the low rise comes into sight, as its skyline and as a peak, while the
    /// one behind the high rise stays hidden. A smaller allowance or range keeps the low rise,
    /// and without one nothing changes.
    func testLowRiseNearTheEyeHidesNothingWithAnAllowance() {
        let (terrain, observer, peaks) = nearRiseScene()
        XCTAssertEqual(terrain.raiseSummits(peaks), 3)
        let renderer = HorizonRenderer(terrain: terrain)
        var strict = HorizonSettings()
        strict.maxDistance = 30_000
        strict.azimuthStep = 1
        var relaxed = strict
        relaxed.nearAllowance = 10
        func inSight(_ peak: Peak, _ settings: HorizonSettings) -> Bool {
            renderer.visibility(of: peak.point, from: observer, settings: settings).isVisible
        }
        XCTAssertEqual(peaks.map { inSight($0, strict) }, [false, false, true])
        XCTAssertEqual(peaks.map { inSight($0, relaxed) }, [true, false, true])
        var small = relaxed
        small.nearAllowance = 5
        XCTAssertFalse(inSight(peaks[0], small), "the rise is 6.4 m above the eye")
        var short = relaxed
        short.nearRange = 300
        XCTAssertFalse(inSight(peaks[0], short), "the rise is 370 m away")

        let ground = renderer.render(from: observer, settings: strict)
        let seen = renderer.render(from: observer, settings: relaxed)
        XCTAssertEqual(Double(ground.distances[0]), 370, accuracy: 15)
        XCTAssertEqual(Double(seen.distances[0]), 25_000, accuracy: 100)
        XCTAssertEqual(Double(seen.distances[90]), Double(ground.distances[90]), accuracy: 1, "a 23 m rise still hides")
        XCTAssertEqual(seen.distances[225], ground.distances[225])
        // The mountain's crest is drawn, and the low rise isn't in the depth map.
        XCTAssertTrue(seen.ridgeSegments().contains { $0.isSkyline && $0.azimuth0 == 0 && $0.distance > 20_000 })
        XCTAssertGreaterThan(Double(seen.envelope(ofRay: 0).first!.distance), 1_000)
        XCTAssertNil(ground.withNearGround().nearGround, "nothing let through without an allowance")
    }

    /// What skyline matching gets, the relaxed view with the near ground put back, is the
    /// skyline a march without the allowance finds, ray for ray, summit tips and missing data
    /// included.
    func testSkylineWithNearGroundIsTheStrictOne() {
        let (terrain, observer, peaks) = nearRiseScene()
        terrain.raiseSummits(peaks)
        let renderer = HorizonRenderer(terrain: terrain)
        var strict = HorizonSettings()
        strict.maxDistance = 30_000
        strict.azimuthStep = 0.25
        var relaxed = strict
        relaxed.nearAllowance = 10
        let ground = renderer.render(from: observer, settings: strict)
        let seen = renderer.render(from: observer, settings: relaxed)
        let matched = seen.withNearGround()
        XCTAssertNotEqual(seen.elevations, ground.elevations)
        XCTAssertEqual(matched.elevations, ground.elevations)
        XCTAssertEqual(matched.distances, ground.distances)
        XCTAssertEqual(matched.settings.nearAllowance, 0)
        XCTAssertEqual(matched.coarseRays, ground.coarseRays)
        // The tips in sight are raised, off the grid between rays.
        for peak in [peaks[0], peaks[2]] {
            let look = LocalFrame(origin: observer).look(at: peak.point, refraction: strict.refraction)
            XCTAssertEqual(seen.elevation(atAzimuth: look.azimuth), look.elevation, accuracy: 0.02)
        }
        // West, the data ends 200 m out: nothing beyond is seen, and the ground before it
        // stays the skyline.
        let west = Int(270 / strict.azimuthStep)
        XCTAssertEqual(seen.elevations[west], ground.elevations[west])
        XCTAssertEqual(seen.envelope(ofRay: west).count, 1)
        XCTAssertLessThan(Double(seen.distances[west]), 250)
        // A summit out there, lower than the rise before the gap, is hidden as that skyline says.
        let out = destination(from: observer, azimuth: 270, distance: 5_000)
        let beyond = GeoPoint(latitude: out.latitude, longitude: out.longitude, height: 450)
        XCTAssertLessThan(LocalFrame(origin: observer).look(at: beyond, refraction: strict.refraction).elevation,
                          Double(seen.elevations[west]))
        XCTAssertFalse(renderer.visibility(of: beyond, from: observer, settings: relaxed).isVisible)
        XCTAssertFalse(renderer.visibility(of: beyond, from: observer, settings: strict).isVisible)
    }

    /// Flat ground at 300 m on a 1 arc-second grid seen from 45.5°N 8.25°E, with a bump of
    /// `bump` meters (a cone of `bumpRadius`, centered on a grid node) about `bumpDistance`
    /// away on `bumpBearing`, and a mountain `mountain` meters high 20 km away on `tipBearing`
    /// (the bump's own bearing when nil) whose summit OpenStreetMap puts 33 m above its cone.
    private func tipBehindBump(bumpBearing: Double, bumpDistance: Double, bump height: Double, bumpRadius: Double = 25,
                               tipBearing: Double? = nil, mountain: Double = 170) -> (terrain: Terrain, peak: Peak, observer: GeoPoint) {
        let observer = GeoPoint(latitude: 45.5, longitude: 8.25, height: 301.6)
        let step = 1.0 / 3600, north = 45.8, west = 8.0, rows = 1_261, cols = 1_261
        let rough = destination(from: observer, azimuth: bumpBearing, distance: bumpDistance)
        let bump = (latitude: north - ((north - rough.latitude) / step).rounded() * step,
                    longitude: west + ((rough.longitude - west) / step).rounded() * step)
        let bearing = tipBearing ?? LocalFrame(origin: observer).look(at: GeoPoint(latitude: bump.latitude, longitude: bump.longitude,
                                                                                   height: 300), refraction: 0).azimuth
        let summit = destination(from: observer, azimuth: bearing, distance: 20_000)
        var heights = [Int16](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            let lat = north - Double(r) * step
            for c in 0..<cols {
                let lon = west + Double(c) * step
                func cone(_ center: (latitude: Double, longitude: Double), _ height: Double, _ radius: Double) -> Double {
                    let d = hypot((lat - center.latitude) * 111_320, (lon - center.longitude) * 111_320 * cos(lat * .pi / 180))
                    return height * max(0, 1 - d / radius)
                }
                heights[r * cols + c] = Int16((300 + max(cone(bump, height, bumpRadius), cone(summit, mountain, 3_000))).rounded())
            }
        }
        let tile = ElevationTile(south: 45, west: 8, rows: rows, cols: cols, originLatitude: north, originLongitude: west,
                                 stepLatitude: step, stepLongitude: step, heights: heights)
        let peak = Peak(id: 1, name: "Tip", latitude: summit.latitude, longitude: summit.longitude, elevation: 300 + mountain + 33)
        return (Terrain(tiles: [tile], missingIsSea: false), peak, observer)
    }

    /// A summit tip between two rays whose own bearing passes a low bump 600 m away that the
    /// nearest ray misses: the bump hides the tip, so without the allowance the tip isn't
    /// raised, and what matching gets must not keep it either.
    func testTipHiddenByGroundLetThroughOnlyOnItsOwnBearing() {
        let (terrain, peak, observer) = tipBehindBump(bumpBearing: 4, bumpDistance: 600, bump: 8)
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let renderer = HorizonRenderer(terrain: terrain)
        var strict = HorizonSettings()
        strict.maxDistance = 25_000
        strict.azimuthStep = 10
        var relaxed = strict
        relaxed.nearAllowance = 10
        let tip = LocalFrame(origin: observer).look(at: peak.point, refraction: strict.refraction).elevation
        let ground = renderer.render(from: observer, settings: strict)
        let seen = renderer.render(from: observer, settings: relaxed)
        XCTAssertEqual(Double(seen.elevations[0]), tip, accuracy: 0.02, "raised past the bump")
        XCTAssertLessThan(Double(ground.elevations[0]), tip - 0.2, "hidden by the bump without the allowance")
        XCTAssertEqual(seen.withNearGround().elevations, ground.elevations)
        XCTAssertEqual(seen.withNearGround().distances, ground.distances)
        XCTAssertTrue(renderer.visibility(of: peak.point, from: observer, settings: relaxed).isVisible)
        XCTAssertFalse(renderer.visibility(of: peak.point, from: observer, settings: strict).isVisible)
    }

    /// The other way round: the bump stands on the nearest ray, higher than the tip, and the
    /// tip's own bearing passes beside it. Without the allowance that ray's skyline is the
    /// bump, so the tip is never tried, flanks and all; what matching gets must agree.
    func testTipBelowGroundLetThroughOnItsNearestRay() {
        let (terrain, peak, observer) = tipBehindBump(bumpBearing: 0, bumpDistance: 950, bump: 11, bumpRadius: 35,
                                                      tipBearing: 2.4, mountain: 80)
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let renderer = HorizonRenderer(terrain: terrain)
        var strict = HorizonSettings()
        strict.maxDistance = 25_000
        strict.azimuthStep = 5
        var relaxed = strict
        relaxed.nearAllowance = 10
        let tip = LocalFrame(origin: observer).look(at: peak.point, refraction: strict.refraction).elevation
        let ground = renderer.render(from: observer, settings: strict)
        let seen = renderer.render(from: observer, settings: relaxed)
        XCTAssertGreaterThan(Double(ground.elevations[0]), tip, "the bump, on the nearest ray")
        XCTAssertLessThan(Double(ground.distances[0]), 1_000)
        XCTAssertEqual(Double(seen.elevations[0]), tip, accuracy: 0.02, "raised, seen past the bump")
        XCTAssertEqual(seen.withNearGround().elevations, ground.elevations)
        XCTAssertEqual(seen.withNearGround().distances, ground.distances)
    }

    /// Seen from 45.5°N 8.25°E: bare ground at 300 m with a mountain 20 km north; the surface
    /// model (1″, like Copernicus) has a 20 m canopy over all of it and a building 55 m high
    /// 300 m north; the bare ground (⅓″, like USGS 3DEP, a patch around the eye) has a knoll
    /// 600 m east whose surveyed top is 25 m above it.
    private func canopyScene() -> (terrain: Terrain, observer: GeoPoint, mountain: GeoPoint, knoll: Peak) {
        let lat0 = 45.5, lon0 = 8.25, step = 1.0 / 3600
        let origin = GeoPoint(latitude: lat0, longitude: lon0, height: 0)
        let peak = destination(from: origin, azimuth: 0, distance: 20_000)
        let building = destination(from: origin, azimuth: 0, distance: 300)
        let knollAt = destination(from: origin, azimuth: 90, distance: 600)
        func cone(_ lat: Double, _ lon: Double, _ c: (latitude: Double, longitude: Double), _ height: Double, _ radius: Double) -> Double {
            height * max(0, 1 - hypot((lat - c.latitude) * 111_320, (lon - c.longitude) * 111_320 * cos(lat * .pi / 180)) / radius)
        }
        func grid(north: Double, south: Double, west: Double, east: Double, step: Double = step,
                  _ height: (Double, Double) -> Double) -> ElevationTile {
            let rows = Int(((north - south) / step).rounded()) + 1, cols = Int(((east - west) / step).rounded()) + 1
            var heights = [Int16](repeating: 0, count: rows * cols)
            for r in 0..<rows {
                for c in 0..<cols { heights[r * cols + c] = Int16(height(north - Double(r) * step, west + Double(c) * step).rounded()) }
            }
            return ElevationTile(south: 45, west: 8, rows: rows, cols: cols, originLatitude: north, originLongitude: west,
                                 stepLatitude: step, stepLongitude: step, heights: heights)
        }
        let bare = { (lat: Double, lon: Double) in 300 + cone(lat, lon, peak, 400, 4_000) }
        let surface = grid(north: 45.8, south: 45.4, west: 8.0, east: 8.5) { lat, lon in
            bare(lat, lon) + 20 + cone(lat, lon, building, 35, 40)
        }
        let ground = grid(north: 45.56, south: 45.44, west: 8.17, east: 8.33, step: step / 3) { lat, lon in
            bare(lat, lon) + cone(lat, lon, knollAt, 15, 150)
        }
        let terrain = Terrain(tiles: [surface], ground: [ground], missingIsSea: false)
        let knoll = Peak(id: 7, name: "Knoll", latitude: knollAt.latitude, longitude: knollAt.longitude, elevation: 325)
        return (terrain, HorizonRenderer(terrain: terrain).observer(latitude: lat0, longitude: lon0),
                GeoPoint(latitude: peak.latitude, longitude: peak.longitude, height: 720), knoll)
    }

    /// The view stands on bare ground near the eye: a building in the surface model no longer
    /// hides the mountain behind it, while matching's surface still has it. The eye stays on
    /// the surface model, so the canopy past the bare ground makes no skyline; from the bare
    /// ground it would, all around. The bare ground under trails is kept whole, and summits
    /// raised near the eye change only the copy.
    func testViewWithBareGroundNearTheEye() {
        let (terrain, observer, mountain, knoll) = canopyScene()
        XCTAssertEqual(observer.height, 321.6, accuracy: 0.01, "on the canopy, as before")
        let land = try! XCTUnwrap(terrain.withGround(within: 1_000, latitude: 45.5, longitude: 8.25))
        func at(_ azimuth: Double, _ distance: Double) -> Double {
            let p = destination(from: observer, azimuth: azimuth, distance: distance)
            return land.height(latitude: p.latitude, longitude: p.longitude)
        }
        XCTAssertEqual(at(0, 300), 300, accuracy: 0.5, "no building")
        XCTAssertEqual(at(180, 900), 300, accuracy: 0.5)
        XCTAssertEqual(at(45, 1_300), 300, accuracy: 0.5, "a box: farther along the diagonal")
        XCTAssertEqual(at(180, 2_000), 320, accuracy: 0.5, "the canopy past it")
        // Blended into the surface over the box's last 240 m (1,000–1,240 m), without a step.
        let ramp = stride(from: 950.0, through: 1_300, by: 10).map { at(180, $0) }
        XCTAssertEqual(ramp.first!, 300, accuracy: 0.5)
        XCTAssertEqual(ramp.last!, 320, accuracy: 0.5)
        XCTAssertTrue((300.0...318.0).contains(at(180, 1_150)) && at(180, 1_150) > 302, "\(at(180, 1_150))")
        for (a, b) in zip(ramp, ramp.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a - 0.3)
            XCTAssertLessThan(b - a, 2)
        }
        XCTAssertEqual(land.ground.height(latitude: 45.45, longitude: 8.25), 300, accuracy: 0.5, "all the bare ground kept")
        XCTAssertEqual(land.groundPatches.count, terrain.groundPatches.count)
        XCTAssertNil(Terrain(tiles: terrain.tiles, missingIsSea: false).withGround(within: 1_000, latitude: 45.5, longitude: 8.25))
        XCTAssertNil(terrain.withGround(within: 1_000, latitude: 45.75, longitude: 8.25), "no bare ground there")

        var settings = HorizonSettings()
        settings.maxDistance = 25_000
        settings.azimuthStep = 1
        settings.nearAllowance = 10
        XCTAssertFalse(HorizonRenderer(terrain: terrain).visibility(of: mountain, from: observer, settings: settings).isVisible)
        XCTAssertTrue(HorizonRenderer(terrain: land).visibility(of: mountain, from: observer, settings: settings).isVisible)
        let view = HorizonRenderer(terrain: land).render(from: observer, settings: settings)
        XCTAssertGreaterThan(Double(view.distances[0]), 15_000, "the mountain is the skyline north")
        XCTAssertFalse(view.distances.contains { $0 < 1_500 }, "nothing near makes a skyline")
        let lowEye = HorizonRenderer(terrain: land).observer(latitude: 45.5, longitude: 8.25)
        let fromBare = HorizonRenderer(terrain: land).render(from: lowEye, settings: settings)
        XCTAssertGreaterThan(fromBare.distances.filter { $0 < 1_500 }.count, 180, "the canopy's edge, most of the way round")

        // A summit near the eye is raised on the copy, not on the bare ground under trails.
        XCTAssertEqual(land.raiseSummits([knoll]), 1)
        let under = terrain.ground.height(latitude: knoll.latitude, longitude: knoll.longitude)
        XCTAssertEqual(under, 315, accuracy: 1.5)
        XCTAssertGreaterThan(land.height(latitude: knoll.latitude, longitude: knoll.longitude), under + 8)
    }
}
