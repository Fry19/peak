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
