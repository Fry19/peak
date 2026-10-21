import XCTest
@testable import PeakCore

final class ReliefTests: XCTestCase {
    /// Terrain over the test block given by height at (x meters east, y meters north) of
    /// 46°N 8°E, at 3 arc-second spacing.
    private func terrain(_ height: @escaping (Double, Double) -> Double) -> Terrain {
        let tiles = [(45, 7), (45, 8), (46, 7), (46, 8)].map { south, west in
            ElevationTile(south: south, west: west, size: 1200) { lat, lon in
                height((lon - 8) * 111_200 * cos(46 * .pi / 180), (lat - 46) * 111_200)
            }
        }
        return Terrain(tiles: tiles)
    }

    private let center = LatLon(46, 8)

    private func length(_ line: CrestLine) -> Double {
        line.length
    }

    func testProjectionRoundTrip() {
        let projection = MapProjection(center: center)
        let p = LatLon(46.01, 8.02)
        let xy = projection.point(p)
        XCTAssertEqual(xy.y, 1_111.5, accuracy: 2, "0.01° of latitude")
        XCTAssertEqual(xy.x, 1_548, accuracy: 3, "0.02° of longitude at 46°")
        let back = projection.latLon(xy)
        XCTAssertEqual(back.latitude, p.latitude, accuracy: 1e-12)
        XCTAssertEqual(back.longitude, p.longitude, accuracy: 1e-12)
        // The flat map agrees with the distance on a sphere to within its 0.3% difference
        // from the ellipsoid.
        XCTAssertEqual((xy * xy).sum().squareRoot(), center.distance(to: p), accuracy: 6)
    }

    func testExtentHoldsThePointsWithPadding() throws {
        let points = [LatLon(46.00, 8.00), LatLon(46.02, 8.00), LatLon(46.01, 8.03)]
        let extent = try XCTUnwrap(MapExtent.around(points, padding: 0.1, minimumSize: 1_000))
        XCTAssertEqual(extent.center.latitude, 46.01, accuracy: 1e-9)
        XCTAssertEqual(extent.center.longitude, 8.015, accuracy: 1e-9)
        XCTAssertEqual(extent.height, 2_223 * 1.2, accuracy: 10)
        XCTAssertEqual(extent.width, 2_322 * 1.2, accuracy: 10)
        let one = try XCTUnwrap(MapExtent.around([center], minimumSize: 1_500))
        XCTAssertEqual(one.width, 1_500)
        XCTAssertEqual(one.height, 1_500)
        XCTAssertNil(MapExtent.around([]))
    }

    func testGridIsNorthUpAroundItsCenter() {
        // Ground rising 0.1 m per meter to the north and 0.05 to the east.
        let map = ReliefMap(terrain: terrain { x, y in 1_000 + 0.1 * y + 0.05 * x },
                            extent: MapExtent(center: center, width: 2_000, height: 1_000), cellSize: 100)
        XCTAssertEqual(map.cols, 21)
        XCTAssertEqual(map.rows, 11)
        XCTAssertEqual(map.position(row: 5, col: 10), SIMD2(0, 0))
        XCTAssertEqual(map.position(row: 0, col: 0), SIMD2(-1_000, 500))
        XCTAssertEqual(Double(map.h(5, 10)), 1_000, accuracy: 1)
        XCTAssertEqual(Double(map.h(0, 10)), 1_050, accuracy: 1, "row 0 is the northern edge")
        XCTAssertEqual(Double(map.h(5, 20)), 1_050, accuracy: 1, "the last column is the eastern edge")
    }

    func testHillshadeLightsSlopesFacingTheLight() {
        func shade(_ height: (Double, Double) -> Double) -> [Float] {
            var heights: [Float] = []
            for r in 0..<9 {
                for c in 0..<9 { heights.append(Float(height(Double(c - 4) * 30, Double(4 - r) * 30))) }
            }
            return ReliefMap(center: center, cellSize: 30, rows: 9, cols: 9, heights: heights).hillshade()
        }
        let flat = shade { _, _ in 800 }
        // A slope climbing east faces west, half towards the light in the north-west;
        // one climbing west faces away from it. Edges get the same as the middle.
        let facingWest = shade { x, _ in 800 + 0.5 * x }
        let facingEast = shade { x, _ in 800 - 0.5 * x }
        for i in flat.indices {
            XCTAssertEqual(flat[i], Float(0.5.squareRoot()), accuracy: 1e-4)
            XCTAssertEqual(facingWest[i], Float((0.25 + 0.5.squareRoot()) / 1.25.squareRoot()), accuracy: 1e-4)
            XCTAssertEqual(facingEast[i], Float((-0.25 + 0.5.squareRoot()) / 1.25.squareRoot()), accuracy: 1e-4)
        }
        // Steeper in the shade, darker; no terrain, no shade.
        XCTAssertLessThan(shade { x, _ in 800 - 2 * x }[40], facingEast[40])
        var holes = [Float](repeating: 500, count: 25)
        holes[12] = .nan
        XCTAssertTrue(ReliefMap(center: center, cellSize: 30, rows: 5, cols: 5, heights: holes).hillshade()[12].isNaN)
    }

    /// A long straight ridge running north-south: one crest along its top, the length of
    /// the map, standing well above the valleys.
    func testCrestFollowsALongRidge() {
        let ridgeX = 300.0
        let map = ReliefMap(terrain: terrain { x, _ in 500 + max(0, 1_200 - 0.8 * abs(x - ridgeX)) },
                            extent: MapExtent(center: center, width: 6_000, height: 6_000), cellSize: 50)
        let lines = map.crestLines()
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            for p in line.points { XCTAssertEqual(p.x, ridgeX, accuracy: 75, "off the crest at \(p)") }
            XCTAssertGreaterThan(line.relief, 400)
            XCTAssertEqual(line.height, 1_700, accuracy: 40)
        }
        XCTAssertGreaterThan(lines.reduce(0) { $0 + length($1) }, 5_500, "the crest runs the map's length")
    }

    /// Flat ground has no crests, and a smooth cone has none on its flanks: across the
    /// slope it only curves gently. Its tip is too short a crest to draw.
    func testNoCrestsOnFlatGroundOrAConeFlank() {
        let extent = MapExtent(center: center, width: 10_000, height: 10_000)
        XCTAssertTrue(ReliefMap(terrain: terrain { _, _ in 700 }, extent: extent, cellSize: 50).crestLines().isEmpty)
        let cone = ReliefMap(terrain: terrain { x, y in 500 + max(0, 1_500 - 0.375 * (x * x + y * y).squareRoot()) },
                             extent: extent, cellSize: 50)
        XCTAssertTrue(cone.crestLines().isEmpty)
        // With no length asked of them, what's left is right at the tip.
        for line in cone.crestLines(minLength: 0) {
            for p in line.points { XCTAssertLessThan((p * p).sum().squareRoot(), 250) }
        }
    }

    /// Three ridges meeting at a summit: three crests that reach it, one along each ridge.
    func testCrestsBranchAtASummit() {
        let directions = [0.0, 120, 240].map { SIMD2(sin($0 * .pi / 180), cos($0 * .pi / 180)) }
        let map = ReliefMap(terrain: terrain { x, y in
            let p = SIMD2(x, y)
            var top = 0.0
            for d in directions {
                let along = max(0, (p * d).sum())
                let off = p - along * d
                top = max(top, 1_400 - 0.7 * (off * off).sum().squareRoot() - 0.08 * along)
            }
            return 500 + max(0, top)
        }, extent: MapExtent(center: center, width: 7_000, height: 7_000), cellSize: 40)
        let lines = map.crestLines()
        // Every crest point is on one of the ridges.
        for p in lines.flatMap(\.points) {
            let off = directions.map { d -> Double in
                let along = max(0, (p * d).sum())
                let o = p - along * d
                return (o * o).sum().squareRoot()
            }.min()!
            XCTAssertLessThan(off, 80, "\(p) isn't on a ridge")
        }
        // Each ridge has a crest that runs from near the summit most of the way out.
        for d in directions {
            let along = lines.filter { line in line.points.allSatisfy { p in
                let o = p - max(0, (p * d).sum()) * d
                return (o * o).sum().squareRoot() < 80
            } }
            let reach = along.flatMap(\.points).map { ($0 * d).sum() }
            XCTAssertLessThan(reach.min() ?? .infinity, 150, "the crest along \(d) reaches the summit")
            XCTAssertGreaterThan(reach.max() ?? 0, 2_800, "the crest along \(d) runs out along the ridge")
        }
    }

    func testTraceSplitsAtBranchesAndFollowsLoops() {
        func mask(_ rows: [String]) -> ([Bool], Int, Int) {
            (rows.flatMap { $0.map { $0 == "#" } }, rows.count, rows[0].count)
        }
        // A Y: three runs that all end at the branch.
        let (y, yr, yc) = mask(["#...#",
                                ".#.#.",
                                "..#..",
                                "..#..",
                                "..#.."])
        let runs = ReliefMap.trace(y, rows: yr, cols: yc)
        XCTAssertEqual(runs.count, 3)
        let branch = 2 * yc + 2
        XCTAssertTrue(runs.allSatisfy { $0.first == branch || $0.last == branch })
        XCTAssertEqual(runs.map(\.count).sorted(), [3, 3, 3])

        // A staircase is one line: its corners aren't branches.
        let (stairs, sr, sc) = mask(["##...",
                                     ".##..",
                                     "..##.",
                                     "...##"])
        let line = ReliefMap.trace(stairs, rows: sr, cols: sc)
        XCTAssertEqual(line.count, 1)
        XCTAssertEqual(line.first?.count, 8)

        // A ring is one closed run.
        let (ring, rr, rc) = mask([".###.",
                                   "#...#",
                                   "#...#",
                                   ".###."])
        let loop = ReliefMap.trace(ring, rows: rr, cols: rc)
        XCTAssertEqual(loop.count, 1)
        XCTAssertEqual(loop.first?.first, loop.first?.last)
        XCTAssertEqual(loop.first?.count, 11)
    }

    func testThinningLeavesLinesOnePointWide() {
        // A bar three points thick thins to its middle row.
        var bar = [Bool](repeating: false, count: 7 * 12)
        for r in 2...4 { for c in 1...10 { bar[r * 12 + c] = true } }
        let thin = ReliefMap.thin(bar, rows: 7, cols: 12)
        for c in 0..<12 {
            let column = (0..<7).filter { thin[$0 * 12 + c] }
            XCTAssertLessThanOrEqual(column.count, 1, "column \(c): \(column)")
        }
        XCTAssertGreaterThanOrEqual((0..<12).filter { c in thin[3 * 12 + c] }.count, 6)
    }

    func testSimplifyAndSmooth() {
        let zigzag = (0...10).map { SIMD2(Double($0) * 10, $0 % 2 == 0 ? 0 : 1) }
        let straight = ReliefMap.simplify(zigzag, tolerance: 2)
        XCTAssertEqual(straight, [zigzag[0], zigzag[10]])
        let corner = [SIMD2(0.0, 0), SIMD2(10.0, 0), SIMD2(10.0, 10)]
        let round = ReliefMap.chaikin(corner, iterations: 2)
        XCTAssertEqual(round.first, corner.first)
        XCTAssertEqual(round.last, corner.last)
        XCTAssertFalse(round.contains(corner[1]), "the corner is cut")
        XCTAssertEqual(round.count, 6)
    }
}
