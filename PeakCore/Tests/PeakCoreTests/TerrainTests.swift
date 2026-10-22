import XCTest
@testable import PeakCore

final class TerrainTests: XCTestCase {
    /// A tilted plane is reproduced exactly by bilinear interpolation, so any error comes
    /// from indexing, including across the edges between tiles.
    func testBilinearIsExactOnAPlaneAcrossTileEdges() {
        func plane(_ lat: Double, _ lon: Double) -> Double { 1_000 + 900 * (lat - 45) + 1_300 * (lon - 7) }
        let tiles = [(45, 7), (45, 8), (46, 7), (46, 8)].map { ElevationTile(south: $0.0, west: $0.1, size: 120, height: plane) }
        let terrain = Terrain(tiles: tiles)
        var rng = SplitMix64(seed: 3)
        for _ in 0..<2_000 {
            let lat = 45.01 + 1.98 * rng.uniform(), lon = 7.01 + 1.98 * rng.uniform()
            XCTAssertEqual(terrain.height(latitude: lat, longitude: lon), plane(lat, lon), accuracy: 0.51)
        }
        // Right at and just around the seams.
        for lat in [45.9999, 46.0, 46.0001] {
            for lon in [7.9999, 8.0, 8.0001] {
                XCTAssertEqual(terrain.height(latitude: lat, longitude: lon), plane(lat, lon), accuracy: 0.51)
            }
        }
    }

    func testMissingTilesReadAsSeaAndOutsideIsNaN() {
        let terrain = Terrain(tiles: [ElevationTile(south: 45, west: 7, size: 60) { _, _ in 800 },
                                      ElevationTile(south: 46, west: 8, size: 60) { _, _ in 800 }])
        XCTAssertEqual(terrain.height(latitude: 45.5, longitude: 7.5), 800)
        XCTAssertEqual(terrain.height(latitude: 46.5, longitude: 7.5), 0, "inside the box, no tile: sea")
        XCTAssertTrue(terrain.height(latitude: 44.5, longitude: 7.5).isNaN)
        XCTAssertTrue(terrain.height(latitude: 45.5, longitude: 9.5).isNaN)
        // When missing means not downloaded, it must not pass for sea.
        let partial = Terrain(tiles: terrain.tiles, missingIsSea: false)
        XCTAssertTrue(partial.height(latitude: 46.5, longitude: 7.5).isNaN)
        XCTAssertEqual(partial.height(latitude: 45.5, longitude: 7.5), 800)
    }

    /// A sharp patch takes over wherever it has data, blending into the coarse tile over its
    /// last few pixels so there's no step at its edge; elsewhere the coarse tile answers.
    func testDetailPatchesOverrideTheCoarseTile() {
        let coarse = ElevationTile(south: 45, west: 7, size: 60) { _, _ in 1_000 }
        // A 40×40 patch at 1/600° spacing near the middle of the cell, with a hole.
        var values = [Int16](repeating: 1_500, count: 1_600)
        for r in 18..<22 { for c in 18..<22 { values[r * 40 + c] = ElevationTile.noData } }
        let patch = ElevationTile(south: 45, west: 7, rows: 40, cols: 40, originLatitude: 45.5, originLongitude: 7.5,
                                  stepLatitude: 1.0 / 600, stepLongitude: 1.0 / 600, heights: values)
        let terrain = Terrain(tiles: [coarse], detail: [patch])
        XCTAssertEqual(terrain.height(latitude: 45.5 - 10 / 600, longitude: 7.5 + 9 / 600), 1_500)
        XCTAssertEqual(terrain.height(latitude: 45.5 - 20 / 600, longitude: 7.5 + 20 / 600), 1_000, "hole in the patch")
        XCTAssertEqual(terrain.height(latitude: 45.2, longitude: 7.2), 1_000)
        XCTAssertEqual(terrain.height(latitude: 45.51, longitude: 7.51), 1_000, "north of the patch")
        // From the edge inward the height rises smoothly from the coarse tile's to the patch's.
        let ramp = (0...10).map { terrain.height(latitude: 45.5 - 10 / 600, longitude: 7.5 + Double($0) / 600) }
        XCTAssertEqual(ramp[0], 1_000, accuracy: 0.001)
        XCTAssertEqual(ramp[4], 1_250, accuracy: 0.001)
        XCTAssertEqual(ramp[8], 1_500, accuracy: 0.001)
        XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
        // A patch alone (its coarse tile failed to download) still answers where it can.
        let alone = Terrain(tiles: [], detail: [patch], missingIsSea: false)
        XCTAssertEqual(alone.height(latitude: 45.5 - 3.5 / 600, longitude: 7.5 + 2.5 / 600), 1_500)
        XCTAssertTrue(alone.height(latitude: 45.2, longitude: 7.2).isNaN)
    }

    /// A blunt top (a cone cut off 150 m below its tip) gets its tip back from the peak's
    /// elevation, without changing the terrain further out.
    func testRaiseSummitsRestoresBluntTips() {
        let summit = (lat: 45.5, lon: 7.5)
        func blunt(_ lat: Double, _ lon: Double) -> Double {
            let dy = (lat - summit.lat) * 111_320, dx = (lon - summit.lon) * 111_320 * cos(summit.lat * .pi / 180)
            return min(2_850, 3_000 - (dx * dx + dy * dy).squareRoot())   // 45° slopes, top cut at 2850 m
        }
        let terrain = Terrain(tiles: [ElevationTile(south: 45, west: 7, size: 3600, height: blunt)])
        let far = terrain.height(latitude: summit.lat + 0.004, longitude: summit.lon)
        XCTAssertEqual(terrain.height(latitude: summit.lat, longitude: summit.lon), 2_850, accuracy: 1)
        let peaks = [Peak(id: 1, name: "Tip", latitude: summit.lat, longitude: summit.lon, elevation: 3_000),
                     Peak(id: 2, name: "Already right", latitude: 45.2, longitude: 7.2, elevation: blunt(45.2, 7.2) + 3),
                     Peak(id: 3, name: "Wrong height", latitude: 45.8, longitude: 7.8, elevation: 9_000)]
        XCTAssertEqual(terrain.raiseSummits(peaks), 1)
        XCTAssertEqual(terrain.height(latitude: summit.lat, longitude: summit.lon), 3_000, accuracy: 1)
        // Halfway down the restored tip, 75 m out: about 75 m below it, the sides coming down
        // a little steeper than the 45° flanks so they land on them.
        let halfway = terrain.height(latitude: summit.lat + 75 / 111_320, longitude: summit.lon)
        XCTAssertLessThanOrEqual(halfway, 2_925 + 1)
        XCTAssertGreaterThan(halfway, 3_000 - 1.25 * 75)
        XCTAssertEqual(terrain.height(latitude: summit.lat + 0.004, longitude: summit.lon), far, "unchanged 450 m away")
        XCTAssertEqual(terrain.raiseSummits(peaks), 0, "raising again changes nothing")
    }

    /// A needle surveyed 150 m above a rounded top that falls away fast (the Matterhorn in a
    /// 30 m model): the restored tip comes down onto the dome's flanks rather than ending in a
    /// wall where the dome has fallen below its old top. Seen from 5 km, the skyline rises to
    /// the summit no steeper than the tip's own sides. The summit sits between grid points.
    func testRaisedTipJoinsARoundedTopWithoutAStep() {
        let summit = (lat: 45.5 + 0.4 / 3600, lon: 7.5 + 0.3 / 3600)
        func dome(_ lat: Double, _ lon: Double) -> Double {
            let dy = (lat - summit.lat) * 111_320, dx = (lon - summit.lon) * 111_320 * cos(summit.lat * .pi / 180)
            let d = (dx * dx + dy * dy).squareRoot()
            return max(1_500, 2_850 - 0.8 * ((d * d + 100 * 100).squareRoot() - 100))   // rounded over ~100 m, then 39°
        }
        let terrain = Terrain(tiles: [ElevationTile(south: 45, west: 7, size: 3600, height: dome)])
        let peaks = [Peak(id: 1, name: "Needle", latitude: summit.lat, longitude: summit.lon, elevation: 3_000)]
        XCTAssertEqual(terrain.raiseSummits(peaks), 1)
        let raised = terrain.tiles[0].heightValues
        XCTAssertEqual(terrain.raiseSummits(peaks), 0)
        XCTAssertTrue(terrain.tiles[0].heightValues == raised, "raising again changes nothing")
        XCTAssertEqual(terrain.height(latitude: 45.5, longitude: 7.5), 3_000, "the point is on the nearest grid point")

        let renderer = HorizonRenderer(terrain: terrain)
        let east = summit.lon + 5_000 / (111_320 * cos(summit.lat * .pi / 180))
        let observer = renderer.observer(latitude: summit.lat, longitude: east)
        var settings = HorizonSettings()
        settings.azimuthStep = 0.05
        settings.maxDistance = 10_000
        let profile = renderer.render(from: observer, settings: settings)
        let skyline = stride(from: 266.0, through: 274.0, by: 0.05).map { profile.elevation(atAzimuth: $0) }
        let steepest = zip(skyline, skyline.dropFirst()).map { abs($1 - $0) / 0.05 }.max()!
        XCTAssertLessThan(steepest, 1.5, "degrees up per degree across: no wall where the tip meets the dome")
        let top = atan((3_000 - observer.height) / 5_000) * 180 / .pi
        XCTAssertEqual(skyline.max()!, top, accuracy: 0.15, "the skyline reaches the summit")
    }

    /// Peaks without an elevation take the terrain's top near them; the rest are untouched.
    func testFillElevationsFromTheTerrain() {
        let cone = TestTerrain.Cone(latitude: 45.5, longitude: 7.5, height: 1_000, radius: 3_000)
        let terrain = TestTerrain.cones([cone])
        var unknown = Peak(id: 1, name: "Knob", latitude: 45.5003, longitude: 7.5, elevation: 0)
        unknown.estimatedElevation = true
        let known = Peak(id: 2, name: "Known", latitude: 45.6, longitude: 7.6, elevation: 1_234)
        var outside = unknown
        outside.latitude = 30
        let filled = terrain.fillElevations([unknown, known, outside])
        XCTAssertEqual(filled.map(\.id), [1, 2])
        // 33 m from the cone's tip; the search reaches the tip's grid neighborhood.
        XCTAssertEqual(filled[0].elevation, 1_500, accuracy: 30)
        XCTAssertTrue(filled[0].estimatedElevation)
        XCTAssertEqual(filled[1].elevation, 1_234)
    }

    func testPkdemRoundTrip() throws {
        let tile = ElevationTile(south: 46, west: 7, size: 90) { lat, lon in 100 * lat + 10 * lon }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).pkdem")
        defer { try? FileManager.default.removeItem(at: url) }
        try tile.write(to: url)
        let read = try ElevationTile(contentsOf: url)
        XCTAssertEqual(read.south, 46)
        XCTAssertEqual(read.west, 7)
        XCTAssertEqual(read.rows, 90)
        XCTAssertEqual(read.cols, 90)
        XCTAssertEqual(read.originLatitude, 47)
        XCTAssertEqual(read.stepLongitude, 1.0 / 90)
        XCTAssertEqual(Array(read.heights), Array(tile.heights))
    }
}
