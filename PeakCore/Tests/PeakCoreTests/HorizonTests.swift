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
}
