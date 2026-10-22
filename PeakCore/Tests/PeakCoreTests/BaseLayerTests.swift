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

    func testNearOrMarginalSightlinesOverCoarseTerrainAreUncertain() {
        XCTAssertTrue(CoarseSight.isUncertain(distance: 8_000, clearance: 3))
        XCTAssertTrue(CoarseSight.isUncertain(distance: 40_000, clearance: 0.2))
        XCTAssertTrue(CoarseSight.isUncertain(distance: 40_000, clearance: -0.2))
        XCTAssertFalse(CoarseSight.isUncertain(distance: 40_000, clearance: 1.5))
        XCTAssertFalse(CoarseSight.isUncertain(distance: 40_000, clearance: -1.5))
    }
}
