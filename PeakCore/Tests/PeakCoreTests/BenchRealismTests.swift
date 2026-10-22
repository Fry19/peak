import XCTest
@testable import PeakCore

/// The helpers that make the benchmark harder than the matcher's own world: perturbed and
/// coarser terrain, a camera that isn't a perfect pinhole, and proposed anchors.
final class BenchRealismTests: XCTestCase {
    let k = CameraIntrinsics(width: 1280, height: 960, horizontalFOV: 65)

    // MARK: Lens and rolling shutter

    func testDistortionRoundTripsAndLeavesTheCenter() {
        let lens = CameraRealism(k1: 0.005)
        let c = lens.distort(x: k.cx, y: k.cy, k)
        XCTAssertEqual(c.x, k.cx, accuracy: 1e-12)
        XCTAssertEqual(c.y, k.cy, accuracy: 1e-12)
        for (x, y) in [(0.0, 0.0), (1280, 960), (100, 800), (640, 10), (1200, 480)] {
            let d = lens.distort(x: x, y: y, k)
            let u = lens.undistort(x: d.x, y: d.y, k)
            XCTAssertEqual(u.x, x, accuracy: 1e-6)
            XCTAssertEqual(u.y, y, accuracy: 1e-6)
        }
    }

    func testPincushionPushesCornersOutByK1RCubed() {
        let lens = CameraRealism(k1: 0.004)
        let d = lens.distort(x: 0, y: 0, k)
        let u = -k.cx / k.fx, v = -k.cy / k.fy
        let r2 = u * u + v * v
        // A point r focal lengths out moves k1·r³ further out.
        XCTAssertEqual(d.x, k.cx + k.fx * u * (1 + 0.004 * r2), accuracy: 1e-9)
        XCTAssertLessThan(d.x, 0, "pincushion moves the corner outward")
        XCTAssertGreaterThan(CameraRealism(k1: -0.004).distort(x: 0, y: 0, k).x, 0, "barrel moves it inward")
    }

    func testRollingShutterTurnsTheHeadingDownTheFrame() {
        let camera = Camera(intrinsics: k, attitude: Attitude(heading: 100))
        let rs = CameraRealism(rollingShutter: 0.3)
        XCTAssertEqual(rs.heading(row: 0, camera), 99.85, accuracy: 1e-12)
        XCTAssertEqual(rs.heading(row: 480, camera), 100, accuracy: 1e-12)
        XCTAssertEqual(rs.heading(row: 960, camera), 100.15, accuracy: 1e-12)
    }

    func testPinholeRealismRendersTheSamePhoto() {
        let observer = GeoPoint(latitude: 46, longitude: 8, height: 1_500)
        let world = HorizonRenderer(terrain: TestTerrain.range()).render(from: observer)
        let small = CameraIntrinsics(width: 160, height: 120, horizontalFOV: 60)
        let camera = Camera(intrinsics: small, attitude: Attitude(heading: 200, pitch: 2))
        XCTAssertEqual(SyntheticPhoto.render(world, camera: camera).pixels,
                       SyntheticPhoto.render(world, camera: camera, realism: CameraRealism()).pixels)
        XCTAssertNotEqual(SyntheticPhoto.render(world, camera: camera).pixels,
                          SyntheticPhoto.render(world, camera: camera, realism: CameraRealism(k1: 0.01, rollingShutter: 0.3)).pixels)
    }

    // MARK: Terrain

    func testDownsamplingAveragesAndCentersLikeAnOverview() {
        // A plane is kept exactly (up to rounding) by averaging with the centered grid.
        func plane(_ lat: Double, _ lon: Double) -> Double { 1_000 + 800 * (lat - 45) + 1_200 * (lon - 7) }
        let tile = ElevationTile(south: 45, west: 7, size: 120, height: plane)
        for factor in [2, 4] {
            let coarse = tile.downsampled(by: factor)
            XCTAssertEqual(coarse.rows, 120 / factor)
            XCTAssertEqual(coarse.stepLatitude, tile.stepLatitude * Double(factor), accuracy: 1e-15)
            let terrain = Terrain(tiles: [coarse])
            for (lat, lon) in [(45.3, 7.3), (45.71, 7.52), (45.5, 7.9)] {
                XCTAssertEqual(terrain.height(latitude: lat, longitude: lon), plane(lat, lon), accuracy: 1.01)
            }
        }
        // Pixels without data are left out of the mean.
        var values = [Int16](repeating: 100, count: 16)
        values[0] = ElevationTile.noData
        values[1] = 200
        let small = ElevationTile(south: 45, west: 7, rows: 4, cols: 4, originLatitude: 46, originLongitude: 7,
                                  stepLatitude: 0.25, stepLongitude: 0.25, heights: values)
        XCTAssertEqual(small.downsampled(by: 2).heightValues, [133, 100, 100, 100])
    }

    func testCroppingKeepsThePixelsInTheBox() {
        let tile = ElevationTile(south: 45, west: 7, size: 100) { lat, lon in (lat - 45) * 1000 + (lon - 7) * 100 }
        let patch = tile.cropped(south: 45.2, north: 45.4, west: 7.5, east: 7.6)!
        let terrain = Terrain(tiles: [tile])
        XCTAssertLessThanOrEqual(patch.originLatitude - 45.4, tile.stepLatitude)
        XCTAssertGreaterThanOrEqual(patch.originLatitude, 45.4)
        XCTAssertLessThanOrEqual(patch.originLongitude, 7.5)
        let lat = 45.3, lon = 7.55
        XCTAssertEqual(patch.interiorHeight(lat, lon)!, terrain.height(latitude: lat, longitude: lon), accuracy: 1e-9)
        XCTAssertNil(tile.cropped(south: 47, north: 47.5, west: 7, east: 8))
    }

    func testPerturbationStaysWithinItsBoundsAndShifts() {
        let base = TestTerrain.cones([.init(latitude: 46.5, longitude: 7.5, height: 2_000, radius: 6_000)])
        var p = DEMPerturbation(smoothing: 0, noise: 5, shiftEast: 0, shiftNorth: 0, seed: 3)
        let noisy = Terrain(tiles: base.tiles.map { $0.perturbed(p) })
        var rng = SplitMix64(seed: 1)
        var largest = 0.0, sum = 0.0
        for _ in 0..<2_000 {
            let lat = 45.1 + 1.8 * rng.uniform(), lon = 7.1 + 1.8 * rng.uniform()
            let d = noisy.height(latitude: lat, longitude: lon) - base.height(latitude: lat, longitude: lon)
            largest = max(largest, abs(d))
            sum += d * d
        }
        XCTAssertLessThanOrEqual(largest, 5.6, "within ±noise, plus rounding")
        XCTAssertGreaterThan((sum / 2_000).squareRoot(), 0.8, "and really there")
        // The noise is the same either side of a tile edge.
        XCTAssertEqual(p.noise(latitude: 46, longitude: 7.5), p.noise(latitude: 46 + 1e-9, longitude: 7.5), accuracy: 1e-3)

        // A shift moves the summit by about as many meters.
        p = DEMPerturbation(smoothing: 0, noise: 0, shiftEast: 300, shiftNorth: 0)
        let shifted = Terrain(tiles: base.tiles.map { $0.perturbed(p) })
        let east = 300 / (111_200 * cos(46.5 * .pi / 180))
        XCTAssertEqual(shifted.height(latitude: 46.5, longitude: 7.5 + east), base.height(latitude: 46.5, longitude: 7.5), accuracy: 6)
        XCTAssertLessThan(shifted.height(latitude: 46.5, longitude: 7.5), base.height(latitude: 46.5, longitude: 7.5) - 50)

        // Smoothing lowers a sharp tip.
        p = DEMPerturbation(smoothing: 1.5, noise: 0, shiftEast: 0, shiftNorth: 0)
        let smooth = Terrain(tiles: base.tiles.map { $0.perturbed(p) })
        XCTAssertLessThan(smooth.height(latitude: 46.5, longitude: 7.5), base.height(latitude: 46.5, longitude: 7.5) - 1)
    }

    func testAppTerrainIsSharpNearAndCoarseFar() {
        let terrain = TestTerrain.range()
        let app = Terrain.appDetail(from: terrain.tiles, latitude: 46, longitude: 8)
        XCTAssertEqual(app.tiles.first!.stepLatitude, terrain.tiles.first!.stepLatitude * 4, accuracy: 1e-15)
        XCTAssertEqual(Set(app.detail.map { Int(($0.stepLatitude / terrain.tiles[0].stepLatitude).rounded()) }), [1, 2])
        // Near the middle the full tiles show through; far out, the coarse ones.
        XCTAssertEqual(app.finestTile(latitude: 46.01, longitude: 8.01)!.stepLatitude, terrain.tiles[0].stepLatitude, accuracy: 1e-15)
        XCTAssertEqual(app.finestTile(latitude: 46.2, longitude: 8.2)!.stepLatitude, terrain.tiles[0].stepLatitude * 2, accuracy: 1e-15)
        XCTAssertEqual(app.finestTile(latitude: 45.3, longitude: 7.3)!.stepLatitude, terrain.tiles[0].stepLatitude * 4, accuracy: 1e-15)
    }

    // MARK: Anchor suggestions

    func testSuggestedAnchorsLandOnTheirPeaksAndSolveBack() {
        let observer = GeoPoint(latitude: 46, longitude: 8, height: 2_000)
        let truth = Attitude(heading: 211, pitch: 3, roll: -2)
        let camera = Camera(intrinsics: k, attitude: truth)
        let frame = LocalFrame(origin: observer)
        func visible(_ id: Int64, _ az: Double, _ d: Double, _ ele: Double, prominence: Double? = nil, estimated: Bool = false) -> VisiblePeak {
            let p = destination(from: observer, azimuth: az, distance: d)
            var peak = Peak(id: id, name: "P\(id)", latitude: p.latitude, longitude: p.longitude, elevation: ele, prominence: prominence)
            peak.estimatedElevation = estimated
            let look = frame.look(at: peak.point, refraction: 0.13)
            return VisiblePeak(peak: peak, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance)
        }
        let peaks = [
            visible(1, 204, 9_000, 3_100, prominence: 900),
            visible(2, 220, 24_000, 3_900, prominence: 1_500),
            visible(3, 220.05, 30_000, 3_960),      // a few pixels from 2, less prominent: dropped
            visible(4, 120, 10_000, 3_000),         // behind the camera's view
            visible(5, 196, 15_000, 3_200, estimated: true),   // no surveyed elevation
        ]
        let anchors = AnchorSuggester.suggest(peaks, camera: camera)
        XCTAssertEqual(anchors.map(\.name), ["P1", "P2"])
        XCTAssertTrue(anchors.allSatisfy { $0.confirmed == false && !$0.isChecked })
        let projector = camera.projector
        for a in anchors {
            let v = peaks.first { $0.peak.name == a.name }!
            let p = projector.pixel(azimuth: v.azimuth, elevation: v.elevation)!
            XCTAssertEqual(a.x, p.x, accuracy: 0.051)
            XCTAssertEqual(a.y, p.y, accuracy: 0.051)
        }
        // Solving from the proposals gives back the attitude they came from (to rounding).
        let solved = AnchorSolver.attitude(anchors: anchors, observer: observer, intrinsics: k, initial: Attitude(heading: 205))!
        XCTAssertEqual(solved.attitude.heading, truth.heading, accuracy: 0.005)
        XCTAssertEqual(AnchorSuggester.suggest(peaks, camera: camera, limit: 1).map(\.name), ["P2"])
    }

    func testAnchorsWithoutConfirmedDecodeAsChecked() throws {
        let typed = try JSONDecoder().decode(Anchor.self, from: Data(#"{"latitude":46,"longitude":7.6,"elevation":4478,"x":10,"y":20}"#.utf8))
        XCTAssertNil(typed.confirmed)
        XCTAssertTrue(typed.isChecked)
        let proposed = try JSONDecoder().decode(Anchor.self, from: Data(#"{"latitude":46,"longitude":7.6,"elevation":4478,"x":10,"y":20,"confirmed":false}"#.utf8))
        XCTAssertFalse(proposed.isChecked)
    }
}
