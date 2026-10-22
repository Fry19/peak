import XCTest
@testable import PeakCore

final class BaseLayerTests: XCTestCase {
    /// zlib of the small file `python3 Tools/build_base_layer.py --fixture --out FILE` writes:
    /// cell 45°N 7°E is 4 × 4 with value(r, c) = 125 + 6r − 4c + (r·c mod 3), cell 46°N 7°E
    /// 2 × 1 with values 300 and 301 (4 m steps), the rest sea; and three peaks.
    static let fixture: Data = {
        let z = Data(base64Encoded: """
        eNrtyj9LW1Ecx+FzNTqUVIcQFYeOloJddLFDJTj5p0gJXVuuNyJ0UUGUFKSIg4MZ3HwHikhncSzktlPIXKJL94LlZnBwUYNvQUR9
        Hvh+fmc4H+emPkTh1lap+6alcOeip3NG7u7hYG8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAgMcjlxvuXFVVVdX7alc00nmrqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq6nNvtXX1q9ls1tO0UU8b
        ab2Rplu94XUumqm2anGShBAth88BAADgGXhjZmZmZmZmZmZPcqtmZmZm9mCrtiqLcTzxv/1+7+zT74OdHyejpeXppDx/vL3y/euX
        mWTpVXc4Kr+Ibj4mcfxn9e+7/srG28rPhZ2Byf3Bb4317fzLzdF8/vJ0aLMwN1uujWW1bKgrG2/Plou7hfZuMcvWin0XCyFM/Suc
        XwO7uEQR
""", options: .ignoreUnknownCharacters)!
        return Data(try! Inflate.zlib([UInt8](z)))
    }()

    func layer() throws -> BaseLayer { try BaseLayer(data: Self.fixture) }

    func testReadsCellsWrittenByThePythonBuilder() throws {
        let base = try layer()
        XCTAssertEqual(base.heightStep, 4)
        XCTAssertEqual(base.peakCount, 3)
        let tile = try XCTUnwrap(base.tile(south: 45, west: 7))
        XCTAssertTrue(tile.isCoarse)
        XCTAssertEqual(tile.rows, 4)
        XCTAssertEqual(tile.cols, 4)
        // With its neighbors, which the last row and column interpolate toward.
        let terrain = Terrain(tiles: base.tiles(latitude: 45.5, longitude: 7.5, radius: 100_000))
        // Pixels are areas: each value sits at its pixel's center.
        for r in 0..<4 {
            for c in 0..<4 {
                let value = Double(125 + 6 * r - 4 * c + (r * c) % 3) * 4
                let h = terrain.height(latitude: 46 - (Double(r) + 0.5) / 4, longitude: 7 + (Double(c) + 0.5) / 4)
                XCTAssertEqual(h, value, accuracy: 1e-6, "pixel \(r), \(c)")
            }
        }
        let north = try XCTUnwrap(base.tile(south: 46, west: 7))
        XCTAssertEqual(north.rows, 2)
        XCTAssertEqual(north.cols, 1)
        XCTAssertEqual(north.heightValues, [1200, 1204])
    }

    func testSeaIsFlatAndExact() throws {
        let base = try layer()
        let sea = try XCTUnwrap(base.tile(south: 0, west: -30))
        XCTAssertFalse(sea.isCoarse, "sea level is exact")
        XCTAssertEqual(Set(sea.heightValues), [0])
        // Longitudes wrap.
        XCTAssertNotNil(base.tile(south: 45, west: 7 + 360))
        XCTAssertNil(base.tile(south: 90, west: 0))
    }

    func testPeaksNearAPoint() throws {
        let base = try layer()
        let near = base.peaks(latitude: 45.9763, longitude: 7.7, radius: 10_000)
        XCTAssertEqual(near.map(\.name), ["Matterhorn"])
        let m = near[0]
        XCTAssertEqual(m.id, 26863664)
        XCTAssertEqual(m.latitude, 45.976426, accuracy: 1e-5)
        XCTAssertEqual(m.longitude, 7.658602, accuracy: 1e-5)
        XCTAssertEqual(m.elevation, 4478)
        XCTAssertEqual(m.prominence, 1038)
        XCTAssertEqual(m.wikidata, "Q1374")
        XCTAssertFalse(m.estimatedElevation)

        let wide = base.peaks(latitude: 45.7, longitude: 7.4, radius: 80_000)
        let unnamed = try XCTUnwrap(wide.first { $0.id == 26863665 })
        XCTAssertEqual(unnamed.name, "Pointe sans nom ü")
        XCTAssertTrue(unnamed.estimatedElevation)
        XCTAssertNil(unnamed.prominence)
        XCTAssertNil(unnamed.wikidata)

        // A southern block.
        let cape = base.peaks(latitude: -33.95, longitude: 18.42, radius: 5_000)
        XCTAssertEqual(cape.map(\.name), ["Table Mountain"])
        XCTAssertEqual(cape[0].elevation, 1085)
        XCTAssertTrue(base.peaks(latitude: 10, longitude: 10, radius: 50_000).isEmpty)
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try BaseLayer(data: Data(count: 100)))
        var damaged = Self.fixture
        damaged.removeLast(5_000)
        XCTAssertThrowsError(try BaseLayer(data: damaged))
    }

    /// Real tiles where they are, the base layer around them; only its cells are coarse.
    func testTerrainFallsBackToTheBaseLayer() throws {
        let base = try layer()
        let fine = ElevationTile(south: 46, west: 7, size: 60) { _, _ in 2_000 }
        let terrain = Terrain(tiles: [fine], base: base, latitude: 45.9, longitude: 7.5, radius: 60_000)
        XCTAssertTrue(terrain.hasCoarse)
        XCTAssertEqual(terrain.height(latitude: 46.5, longitude: 7.5), 2_000, "the real tile wins")
        XCTAssertFalse(terrain.isCoarse(latitude: 46.5, longitude: 7.5))
        XCTAssertTrue(terrain.isCoarse(latitude: 45.5, longitude: 7.5))
        XCTAssertEqual(terrain.height(latitude: 46 - 1.5 / 4, longitude: 7 + 2.5 / 4), Double(125 + 6 - 8 + 2) * 4, accuracy: 1e-6)
        // Cells the file has as sea, inside the radius: sea level rather than missing.
        XCTAssertEqual(terrain.height(latitude: 45.75, longitude: 6.4), 0)
        XCTAssertFalse(Terrain(tiles: [fine]).hasCoarse)
    }

    /// A summit's cone on kilometer pixels would be a broad dome; coarse tiles are left alone.
    func testSummitsAreNotRaisedOnCoarseTerrain() throws {
        let base = try layer()
        let terrain = Terrain(tiles: [], base: base, latitude: 45.5, longitude: 7.5, radius: 10_000)
        let before = try XCTUnwrap(base.tile(south: 45, west: 7)).heightValues
        let peak = Peak(id: 1, name: "Spike", latitude: 45.625, longitude: 7.375, elevation: 900)
        XCTAssertEqual(terrain.raiseSummits([peak]), 0)
        XCTAssertEqual(try XCTUnwrap(base.tile(south: 45, west: 7)).heightValues, before)
    }

    func testHorizonMarksCoarseRays() throws {
        let base = try layer()
        let fine = ElevationTile(south: 46, west: 7, size: 60) { lat, _ in 1_000 + 2_000 * (lat - 46) }
        let terrain = Terrain(tiles: [fine], base: base, latitude: 46.0, longitude: 7.5, radius: 60_000)
        let renderer = HorizonRenderer(terrain: terrain)
        var settings = HorizonSettings()
        settings.maxDistance = 50_000
        settings.azimuthStep = 1
        let profile = renderer.render(from: renderer.observer(latitude: 46.01, longitude: 7.5), settings: settings)
        XCTAssertEqual(profile.coarseRays.count, profile.count)
        // Looking north the skyline is on the real tile's rising slope; south, the coarse cell.
        XCTAssertFalse(profile.coarseRays[0])
        XCTAssertTrue(profile.coarseRays[180])
        // Terrain without coarse tiles leaves it empty.
        XCTAssertTrue(HorizonRenderer(terrain: Terrain(tiles: [fine])).render(from: renderer.observer(latitude: 46.5, longitude: 7.5),
                                                                                settings: settings).coarseRays.isEmpty)
    }

    func testCoarseSkylineCountsForLessAndOnlyWhenFar() {
        let s = AlignmentSettings()
        XCTAssertGreaterThan(s.sigma(distance: 30_000, coarse: true), 2 * s.sigma(distance: 30_000))
        XCTAssertTrue(s.isFar(distance: 5_000))
        XCTAssertFalse(s.isFar(distance: 5_000, coarse: true))
        XCTAssertTrue(s.isFar(distance: s.coarseFarDistance, coarse: true))
    }

    func testPillSaysTheTerrainIsCoarse() {
        XCTAssertEqual(AppStatus.resolve(camera: .running, location: .granted, preciseLocation: true, load: .ready, coarseTerrain: true),
                       .ready(note: "Coarse terrain"))
        XCTAssertEqual(AppStatus.resolve(camera: .running, location: .granted, preciseLocation: true, load: .ready),
                       .ready(note: nil))
    }

    /// Peaks far past the tiles, on coarse terrain behind a wall about 84 km away, as the
    /// views from above see them: from 10,000 ft up, one clearing the wall by 0.5° is in sight,
    /// one by 0.03° can't be told, one 0.5° under it is hidden; from the ground all three are
    /// hidden by a wide margin. Only peaks within the reach (`maxDistance`) are looked at, and
    /// a peak on the fine tile near you is never uncertain. A rendered horizon sparing peaks
    /// deep behind the wall their own lines of sight changes none of that.
    func testFarPeaksOverCoarseTerrainAreCertainOnlyWithAMargin() {
        let wall = 8.3
        func cell(_ south: Int, _ west: Int) -> ElevationTile {
            let coarse = (south, west) != (46, 7)
            let tile = ElevationTile(south: south, west: west, size: coarse ? 120 : 600) { _, lon in
                coarse ? (abs(lon - wall) < 0.04 ? 3_200 : 300) : 500
            }
            tile.isCoarse = coarse
            return tile
        }
        let terrain = Terrain(tiles: [(46, 7), (45, 7), (45, 8), (46, 8), (45, 9), (46, 9)].map { cell($0.0, $0.1) },
                              missingIsSea: false)
        let renderer = HorizonRenderer(terrain: terrain)
        let ground = renderer.observer(latitude: 46.5, longitude: 7.2)
        var above = ground
        above.height += 3_048
        var settings = HorizonSettings()
        settings.maxDistance = 250_000
        settings.nearAllowance = 10

        // Peaks 150 km east, their heights set by how far they clear the wall from above.
        let distance = 150_000.0
        let at = destination(from: ground, azimuth: 90, distance: distance)
        let blocking = renderer.maxElevation(from: above, azimuth: 90, upTo: distance - 250, settings: settings)
        let frame = LocalFrame(origin: above)
        func peak(_ id: Int64, clearing margin: Double) -> Peak {
            var low = 0.0, high = 10_000.0
            for _ in 0..<60 {
                let mid = (low + high) / 2
                let look = frame.look(at: GeoPoint(latitude: at.latitude, longitude: at.longitude, height: mid), refraction: 0.13)
                if look.elevation < blocking + margin { low = mid } else { high = mid }
            }
            return Peak(id: id, name: "\(id)", latitude: at.latitude, longitude: at.longitude, elevation: low)
        }
        let near = destination(from: ground, azimuth: 90, distance: 15_000)
        let peaks = [peak(1, clearing: 0.5), peak(2, clearing: 0.03), peak(3, clearing: -0.5), peak(5, clearing: -3),
                     Peak(id: 4, name: "Near", latitude: near.latitude, longitude: near.longitude, elevation: 900)]

        func seen(from eye: GeoPoint, _ settings: HorizonSettings) -> [Int64: (visible: Bool, unsure: Bool)] {
            var out: [Int64: (visible: Bool, unsure: Bool)] = [:]
            for (p, v, unsure) in renderer.sightings(peaks, from: eye, settings: settings) {
                out[p.id] = (v.isVisible, unsure)
            }
            // The same with the horizon from there sparing the peaks deep behind the wall.
            let rendered = renderer.render(from: eye, settings: settings)
            let spared = renderer.sightings(peaks, from: eye, settings: settings, rendered: rendered)
            XCTAssertEqual(spared.count, out.count)
            for (p, v, unsure) in spared {
                XCTAssertEqual(v.isVisible, out[p.id]?.visible, "peak \(p.id)")
                XCTAssertEqual(unsure, out[p.id]?.unsure, "peak \(p.id)")
            }
            return out
        }
        let up = seen(from: above, settings)
        XCTAssertEqual(up[1]?.visible, true)
        XCTAssertEqual(up[1]?.unsure, false)
        XCTAssertEqual(up[2]?.unsure, true)
        XCTAssertEqual(up[3]?.visible, false)
        XCTAssertEqual(up[3]?.unsure, false)
        XCTAssertEqual(up[5]?.visible, false)
        XCTAssertEqual(up[5]?.unsure, false)
        XCTAssertEqual(up[4]?.unsure, false)
        let below = seen(from: ground, settings)
        for id: Int64 in [1, 2, 3, 5] {
            XCTAssertEqual(below[id]?.visible, false, "peak \(id) from the ground")
            XCTAssertEqual(below[id]?.unsure, false, "peak \(id) from the ground")
        }
        XCTAssertEqual(below[4]?.visible, true)
        XCTAssertEqual(below[4]?.unsure, false)
        // The ground view's reach: the far peaks aren't looked at.
        settings.maxDistance = 80_000
        XCTAssertEqual(Set(seen(from: above, settings).keys), [4])
    }

    /// The neighbouring 0.1° rays see a wall, but the peak's own bearing passes through a
    /// narrow opening. A rendered horizon may suggest an obstruction, never prove it.
    func testHiddenShortcutDoesNotCloseAGapBetweenHorizonRays() {
        let eye = GeoPoint(latitude: 46.5, longitude: 7.2, height: 2)
        let frame = LocalFrame(origin: eye)
        let azimuth = 90.05
        let wall = destination(from: eye, azimuth: azimuth, distance: 20_000)
        let step = 2.0 / 111_320
        let rows = 401, cols = 601
        let north = wall.latitude + 400.0 / 111_320
        let west = wall.longitude - 600.0 / 111_320
        var heights = [Int16](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let lat = north - Double(r) * step, lon = west + Double(c) * step
                let look = frame.look(at: GeoPoint(latitude: lat, longitude: lon))
                if abs(lon - wall.longitude) * 111_320 < 100,
                   abs(azimuthDifference(look.azimuth, azimuth)) > 0.025 {
                    heights[r * cols + c] = 1_000
                }
            }
        }
        let patch = ElevationTile(south: 46, west: 7, rows: rows, cols: cols,
                                  originLatitude: north, originLongitude: west,
                                  stepLatitude: step, stepLongitude: step, heights: heights)
        let terrain = Terrain(tiles: (45...47).flatMap { south in (6...10).map { west in
            let tile = ElevationTile(south: south, west: west, size: 2) { _, _ in 0 }
            tile.isCoarse = west >= 8
            return tile
        } }, detail: [patch])
        let renderer = HorizonRenderer(terrain: terrain)
        var settings = HorizonSettings()
        settings.maxDistance = 150_000
        let at = destination(from: eye, azimuth: azimuth, distance: 120_000)
        let peak = Peak(id: 1, name: "Through the gap", latitude: at.latitude, longitude: at.longitude, elevation: 2_000)
        let exact = renderer.sightings([peak], from: eye, settings: settings)
        let rendered = renderer.render(from: eye, settings: settings)
        let look = frame.look(at: peak.point, refraction: settings.refraction)
        XCTAssertGreaterThan(rendered.blocking(azimuth: look.azimuth, nearerThan: 119_750).elevation - look.elevation, 0.5)
        let shortcut = renderer.sightings([peak], from: eye, settings: settings, rendered: rendered)
        XCTAssertEqual(exact.first?.visibility.isVisible, true)
        XCTAssertEqual(exact.first?.isUncertain, false)
        XCTAssertEqual(shortcut.first?.visibility.isVisible, exact.first?.visibility.isVisible)
        XCTAssertEqual(shortcut.first?.isUncertain, exact.first?.isUncertain)
    }

    func testNearOrMarginalSightlinesOverCoarseTerrainAreUncertain() {
        XCTAssertTrue(CoarseSight.isUncertain(distance: 8_000, clearance: 3))
        XCTAssertTrue(CoarseSight.isUncertain(distance: 40_000, clearance: 0.2))
        XCTAssertTrue(CoarseSight.isUncertain(distance: 40_000, clearance: -0.2))
        XCTAssertFalse(CoarseSight.isUncertain(distance: 40_000, clearance: 1.5))
        XCTAssertFalse(CoarseSight.isUncertain(distance: 40_000, clearance: -1.5))
    }
}
