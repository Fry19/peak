import XCTest
@testable import PeakCore

/// Cases from a review of labels, trails and terrain data: each failed before its fix.
final class ForeSummitTests: XCTestCase {
    /// A fore-summit 1.5 km away and 1.5 km up, with a higher summit 400 m behind it. The
    /// straight-line distance is longer than the distance along the ground, so marching
    /// that far reached the summit behind and counted it as blocking the view.
    func testForeSummitIsNotHiddenByTerrainBehindIt() {
        let center = GeoPoint(latitude: 46, longitude: 8)
        let fore = destination(from: center, azimuth: 0, distance: 1_500)
        let main = destination(from: center, azimuth: 0, distance: 1_900)
        let terrain = TestTerrain.cones([
            .init(latitude: fore.latitude, longitude: fore.longitude, height: 1_500, radius: 1_500),
            .init(latitude: main.latitude, longitude: main.longitude, height: 2_500, radius: 700),
        ], size: 1_200)
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46, longitude: 8)
        let summit = GeoPoint(latitude: fore.latitude, longitude: fore.longitude, height: 2_000)
        let v = renderer.visibility(of: summit, from: observer)
        XCTAssertTrue(v.isVisible)
        XCTAssertGreaterThan(v.clearance, -0.5)
        // The distance shown is the one on the map, not the straight line up to the summit.
        XCTAssertEqual(v.distance, 1_500, accuracy: 5)
        let peak = Peak(id: 1, name: "Fore", latitude: fore.latitude, longitude: fore.longitude, elevation: 2_000)
        let seen = renderer.visiblePeaks([peak], from: observer, maxDistance: 10_000)
        XCTAssertEqual(seen.first?.distance ?? 0, 1_500, accuracy: 5)
    }

    func testGroundDistanceInvertsDestination() {
        let origin = GeoPoint(latitude: 46.3, longitude: 7.9)
        for (azimuth, distance) in [(0.0, 1_000.0), (73, 25_000), (190, 120_000), (300, 50)] {
            let p = destination(from: origin, azimuth: azimuth, distance: distance)
            let d = groundDistance(from: origin, to: GeoPoint(latitude: p.latitude, longitude: p.longitude, height: 4_000))
            XCTAssertEqual(d, distance, accuracy: distance * 1e-6 + 0.01)
        }
    }
}

final class PeakQueryTests: XCTestCase {
    /// Rainier, Fuji, Etna and Kilimanjaro are tagged natural=volcano.
    func testQueryAsksForVolcanoes() {
        let q = Overpass.peaksQuery(south: 46, west: 7, north: 47, east: 8)
        XCTAssertTrue(q.contains(#"node["natural"~"^(peak|volcano)$"]["name"]"#), q)
    }

    func testElevationTable() {
        let cases: [(String, Double?)] = [
            ("4478", 4478), ("4478.5", 4478.5), ("4,478", 4478), ("4478,5", 4478.5), ("4478 m", 4478),
            ("4478m", 4478), ("8848.86", 8848.86), ("3000 m.", 3000), ("3000;3010", 3000),
            ("4 478 m", 4478), ("4\u{00A0}478", 4478), ("4\u{202F}478 m", 4478), ("3 000", 3000),
            ("~3000", 3000), ("ca. 3000", 3000), ("ca 3000 m", 3000), ("4,478.5", 4478.5), ("4.478,5", 4478.5),
            ("14505 ft", 4421.1), ("14,505 ft", 4421.1), ("14 505 ft", 4421.1), ("1200 ft (approx)", 365.8),
            ("14505'", 4421.1), ("0", nil), ("-5", nil), ("0 m", nil), ("high", nil), ("", nil), ("44780", nil),
        ]
        for (raw, expected) in cases {
            let got = Overpass.parseElevation(raw)
            if let expected {
                XCTAssertEqual(got ?? .nan, expected, accuracy: 0.1, "\"\(raw)\"")
            } else {
                XCTAssertNil(got, "\"\(raw)\"")
            }
        }
    }
}

final class TIFFVoidTests: XCTestCase {
    /// A small uncompressed single-strip GeoTIFF, 1/3600° pixels, first pixel corner at 46°N 7°E.
    static func tiff(width: Int, height: Int, int16 samples: [Int16] = [], float floats: [Float] = [],
                     noData: String? = nil, tileWidth: Int? = nil, counts: Int = 1, offsets: Int = 1) -> Data {
        var b = [UInt8]()
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        b += [0x49, 0x49]; u16(42); u32(8)
        let isFloat = !floats.isEmpty
        let dataOffset = 1_000, doubles = 600, text = 800, arrays = 900
        let bytes = isFloat ? floats.count * 4 : samples.count * 2
        // tag, type, count, value or offset
        var entries: [(Int, Int, Int, Int)] = [
            (256, 3, 1, width), (257, 3, 1, height), (258, 3, 1, isFloat ? 32 : 16), (259, 3, 1, 1),
            (277, 3, 1, 1), (339, 3, 1, isFloat ? 3 : 2),
            (33550, 12, 3, doubles), (33922, 12, 6, doubles + 24),
        ]
        // Offsets and counts beyond the first live in arrays at `arrays`, all pointing at the data.
        func list(_ n: Int, _ at: Int) -> Int { n == 1 ? dataOffset : at }
        if let tw = tileWidth {
            entries += [(322, 3, 1, tw), (323, 3, 1, tw), (324, 4, offsets, list(offsets, arrays)), (325, 4, counts, counts == 1 ? bytes : arrays + 40)]
        } else {
            entries += [(273, 4, offsets, list(offsets, arrays)), (278, 3, 1, height), (279, 4, counts, counts == 1 ? bytes : arrays + 40)]
        }
        if let noData { entries.append((42113, 2, noData.utf8.count + 1, text)) }
        entries.sort { $0.0 < $1.0 }
        u16(entries.count)
        for e in entries {
            u16(e.0); u16(e.1); u32(e.2)
            if e.1 == 3 && e.2 == 1 {
                u16(e.3); u16(0)
            } else if e.1 == 2, e.2 <= 4, let noData {
                // Short text sits in the entry itself.
                b += Array((noData.utf8 + [0, 0, 0, 0]).prefix(4))
            } else {
                u32(e.3)
            }
        }
        u32(0)
        while b.count < doubles { b.append(0) }
        for d in [1.0 / 3600, 1.0 / 3600, 0, 0, 0, 0, 7.0, 46.0, 0] { withUnsafeBytes(of: d.bitPattern.littleEndian) { b += $0 } }
        while b.count < text { b.append(0) }
        if let noData { b += Array(noData.utf8) + [0] }
        while b.count < arrays { b.append(0) }
        for _ in 0..<10 { u32(dataOffset) }
        for _ in 0..<10 { u32(bytes) }
        while b.count < dataOffset { b.append(0) }
        for s in samples { u16(Int(UInt16(bitPattern: s))) }
        for f in floats { u32(Int(f.bitPattern)) }
        return Data(b)
    }

    func testVoidsBecomeNoData() throws {
        let ints = try GeoTIFF.elevationTile(Self.tiff(width: 3, height: 2, int16: [100, -32768, -9999, 120, -32767, 0]))
        XCTAssertEqual(ints.heightValues, [100, ElevationTile.noData, ElevationTile.noData, 120, ElevationTile.noData, 0])
        // The file's own no-data value, even one that could pass for a height.
        let tagged = try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, int16: [7, 100, 7, 120], noData: "7"))
        XCTAssertEqual(tagged.heightValues, [ElevationTile.noData, 100, ElevationTile.noData, 120])
        let floats = try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, float: [.nan, 812.4, -999_999, -430], noData: "-32767"))
        XCTAssertEqual(floats.heightValues, [ElevationTile.noData, 812, ElevationTile.noData, -430])
    }

    /// Next to a void, the terrain is interpolated from the pixels that have data rather
    /// than dropping toward −32768 m.
    func testTerrainSkipsVoids() {
        var tile = ElevationTile(south: 45, west: 7, size: 60) { _, _ in 1_000 }
        var heights = tile.heightValues
        heights[30 * 60 + 30] = ElevationTile.noData
        tile = ElevationTile(south: 45, west: 7, rows: 60, cols: 60, originLatitude: tile.originLatitude,
                             originLongitude: tile.originLongitude, stepLatitude: tile.stepLatitude,
                             stepLongitude: tile.stepLongitude, heights: heights)
        let terrain = Terrain(tiles: [tile])
        let lat = tile.originLatitude - 30.4 * tile.stepLatitude, lon = tile.originLongitude + 30.3 * tile.stepLongitude
        XCTAssertEqual(terrain.height(latitude: lat, longitude: lon), 1_000, accuracy: 0.01)
    }

    func testMalformedFilesThrow() {
        // Tile width 0 used to divide by zero.
        XCTAssertThrowsError(try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, int16: [1, 2, 3, 4], tileWidth: 0)))
        // Fewer sizes than offsets used to index out of range.
        XCTAssertThrowsError(try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, int16: [1, 2, 3, 4], counts: 1, offsets: 2)))
        // More blocks than the image has used to give negative rows.
        XCTAssertThrowsError(try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, int16: [1, 2, 3, 4], counts: 3, offsets: 3)))
        XCTAssertNoThrow(try GeoTIFF.elevationTile(Self.tiff(width: 2, height: 2, int16: [1, 2, 3, 4])))
    }
}

final class TerrainNaNTests: XCTestCase {
    func testNaNCoordinatesGiveNaN() {
        let terrain = Terrain(tiles: [ElevationTile(south: 45, west: 7, size: 60) { _, _ in 800 }])
        XCTAssertTrue(terrain.height(latitude: .nan, longitude: 7.5).isNaN)
        XCTAssertTrue(terrain.height(latitude: 45.5, longitude: .nan).isNaN)
        XCTAssertTrue(terrain.height(latitude: .infinity, longitude: 7.5).isNaN)
    }
}

final class TrailReviewTests: XCTestCase {
    /// Two unnamed paths meeting at a T: way 45 starts in the middle of way 40. Each is its
    /// own trail with its own id and its own difficulty.
    func testUnnamedPathsAtAJunctionKeepTheirOwnIdAndDifficulty() throws {
        let json = """
        {"elements":[
          {"type":"way","id":40,"tags":{"highway":"path"},"geometry":[{"lat":46.400,"lon":7.40},{"lat":46.403,"lon":7.40},{"lat":46.406,"lon":7.40}]},
          {"type":"way","id":45,"tags":{"highway":"path","sac_scale":"t5"},"geometry":[{"lat":46.403,"lon":7.40},{"lat":46.403,"lon":7.405}]}
        ]}
        """
        let trails = try Overpass.trails(fromJSON: Data(json.utf8))
        XCTAssertEqual(Set(trails.map(\.id)), ["u40", "u45"])
        XCTAssertNil(trails.first { $0.id == "u40" }?.difficulty)
        XCTAssertEqual(trails.first { $0.id == "u45" }?.difficulty, .demandingAlpineHiking)
    }

    func testDistanceTagInMiles() throws {
        let json = """
        {"elements":[
          {"type":"relation","id":7,"tags":{"route":"hiking","name":"Long way","distance":"7.5 miles"},
           "members":[{"type":"way","ref":99,"role":"","geometry":[{"lat":46.0,"lon":7.0},{"lat":46.01,"lon":7.0},null]}]}
        ]}
        """
        let trail = try XCTUnwrap(Overpass.trails(fromJSON: Data(json.utf8)).first)
        XCTAssertEqual(trail.taggedLength ?? 0, 7.5 * 1_609.344, accuracy: 1)
    }

    /// On flat ground, a few meters of terrain-model noise isn't climbing.
    func testNoiseIsNotGain() throws {
        var rng = SplitMix64(seed: 11)
        let tile = ElevationTile(south: 45, west: 7, size: 3_600) { _, _ in 1_000 + 8 * (rng.uniform() - 0.5) }
        let terrain = Terrain(tiles: [tile])
        let end = destination(from: GeoPoint(latitude: 45.5, longitude: 7.5), azimuth: 90, distance: 5_000)
        let trail = Trail(id: "t", name: "Flat", kind: .path, lines: [[LatLon(45.5, 7.5), LatLon(end.latitude, end.longitude)]])
        let profile = try XCTUnwrap(trail.profile(on: terrain))
        XCTAssertLessThan(profile.gain, 15)
        XCTAssertLessThan(profile.loss, 15)
    }

    /// A route in two pieces: down 1000 m from one summit, then (past a gap) up 600 m to
    /// another. Walked one way it climbs 600 and descends 1000 (or the reverse); turning
    /// each piece to climb made it 1600 up.
    func testRouteInPiecesIsWalkedOneWay() throws {
        let terrain = TestTerrain.cones([
            .init(latitude: 45.6, longitude: 7.5, height: 1_000, radius: 5_000),
            .init(latitude: 45.6, longitude: 7.65, height: 600, radius: 4_000),
        ], size: 1_200)
        let first = LatLon(45.6, 7.5), second = LatLon(45.6, 7.65)
        let valley = destination(from: GeoPoint(latitude: 45.6, longitude: 7.5), azimuth: 90, distance: 5_800)
        let gapEnd = destination(from: GeoPoint(latitude: 45.6, longitude: 7.5), azimuth: 90, distance: 6_000)
        let trail = Trail(id: "r", name: "Traverse", kind: .route,
                          lines: [[first, LatLon(valley.latitude, valley.longitude)], [LatLon(gapEnd.latitude, gapEnd.longitude), second]])
        let profile = try XCTUnwrap(trail.profile(on: terrain))
        XCTAssertEqual(profile.gain + profile.loss, 1_600, accuracy: 60)
        XCTAssertEqual(min(profile.gain, profile.loss), 600, accuracy: 40)
        // The main line (the longer one, off the higher summit) is walked up from the valley,
        // so the other is walked down.
        XCTAssertEqual(profile.gain, 1_000, accuracy: 40)
    }
}
