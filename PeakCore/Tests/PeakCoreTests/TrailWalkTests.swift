import XCTest
@testable import PeakCore

final class TrailWalkTests: XCTestCase {
    /// A grid of heights given by f(x east, y north) in meters, `n` points each way.
    private func grid(n: Int = 11, cell: Double = 100, _ f: (Double, Double) -> Double) -> ReliefMap {
        var heights: [Float] = []
        let half = Double(n - 1) / 2
        for r in 0..<n {
            for c in 0..<n { heights.append(Float(f((Double(c) - half) * cell, (half - Double(r)) * cell))) }
        }
        return ReliefMap(center: LatLon(46, 8), cellSize: cell, rows: n, cols: n, heights: heights)
    }

    func testHeightIsBilinearOnTheGrid() {
        let map = grid { x, y in 1_000 + 0.2 * x - 0.1 * y }
        XCTAssertEqual(map.height(at: SIMD2(0, 0)), 1_000, accuracy: 1e-3)
        XCTAssertEqual(map.height(at: SIMD2(130, -270)), 1_000 + 26 + 27, accuracy: 1e-3)
        XCTAssertEqual(map.height(at: SIMD2(500, 500)), 1_000 + 100 - 50, accuracy: 1e-3, "the corner")
        XCTAssertTrue(map.height(at: SIMD2(501, 0)).isNaN, "off the grid")
    }

    func testMeshCoversTheGridFacingUp() {
        let map = grid { x, y in 1_000 + 0.5 * x }
        let mesh = map.mesh()
        XCTAssertEqual(mesh.positions.count, 121)
        XCTAssertEqual(mesh.indices.count, 10 * 10 * 6)
        XCTAssertEqual(mesh.positions[0], SIMD3(-500, 500, 750), "the north-west corner first")
        XCTAssertEqual(mesh.uvs[0], SIMD2(0, 0))
        XCTAssertEqual(mesh.uvs[120], SIMD2(1, 1))
        // Ground rising east faces west and up.
        let n = mesh.normals[60]
        XCTAssertEqual(Double(n.x), -0.5 / 1.25.squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(n.y, 0, accuracy: 1e-4)
        XCTAssertEqual(Double(n.z), 1 / 1.25.squareRoot(), accuracy: 1e-4)
        // Every triangle is counter-clockwise seen from above.
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])],
                c = mesh.positions[Int(mesh.indices[t + 2])]
            let ab = b - a, ac = c - a
            XCTAssertGreaterThan(ab.x * ac.y - ab.y * ac.x, 0)
        }
    }

    /// Squares inside a hole are left for a sharper mesh; those across its edge stay.
    func testMeshLeavesAHoleForASharperMesh() {
        let map = grid { _, _ in 300 }
        let mesh = map.mesh(hole: (low: SIMD2(-150, -150), high: SIMD2(150, 150)))
        // Grid points are 100 m apart, so the squares from −100 to 100 m each way, 2×2 of
        // them, lie inside; those reaching out to ±200 m cross its edge and stay.
        XCTAssertEqual(mesh.indices.count, (100 - 4) * 6)
        XCTAssertEqual(mesh.positions.count, 121, "vertices stay, so neighbors still share them")
    }

    func testMeshStepsAndHoles() {
        // Every third point, keeping the last row and column.
        let coarse = grid { _, _ in 300 }.mesh(step: 3)
        XCTAssertEqual(coarse.positions.count, 5 * 5)
        XCTAssertEqual(coarse.positions.map(\.x).max(), 500)
        // A point without terrain drops the four squares around it.
        var holes = grid { _, _ in 300 }.heights
        holes[5 * 11 + 5] = .nan
        let mesh = ReliefMap(center: LatLon(46, 8), cellSize: 100, rows: 11, cols: 11, heights: holes).mesh()
        XCTAssertEqual(mesh.indices.count, (100 - 4) * 6)
        XCTAssertTrue(mesh.positions.allSatisfy { $0.z.isFinite })
    }

    /// The diagonal splitting each square runs along a ridge, not across it, even where the
    /// ridge climbs.
    func testMeshKeepsDiagonalRidges() {
        let map = grid { x, y in 1_000 + 0.1 * (x + y) - 0.8 * abs(x - y) }
        let mesh = map.mesh()
        // The ridge runs from the south-west to the north-east, through the sw and ne corners
        // of this square, so the edge between them must be the shared one.
        let m = 11, i = 4, j = 5
        let nw = UInt32(i * m + j), ne = nw + 1, sw = UInt32((i + 1) * m + j), se = sw + 1
        let k = (0..<(mesh.indices.count / 6)).first { q in mesh.indices[6 * q] == nw }!
        let square = Array(mesh.indices[(6 * k)..<(6 * k + 6)])
        XCTAssertEqual(Set(square), [nw, ne, sw, se])
        XCTAssertEqual(square.filter { $0 == ne || $0 == sw }.count, 4, "both triangles use the ridge edge")
    }

    func testWalkAlongAStraightTrail() {
        let walk = TrailWalk(points: [SIMD3(0, 0, 1_000), SIMD3(0, 1_000, 1_200), SIMD3(0, 1_000, 1_200), SIMD3(0, 2_000, 1_300)])
        XCTAssertEqual(walk.points.count, 3, "repeated points are dropped")
        XCTAssertEqual(walk.length, 2_000, accuracy: 1e-9)
        XCTAssertEqual(walk.point(at: 500), SIMD3(0, 500, 1_100))
        XCTAssertEqual(walk.point(at: 1_500), SIMD3(0, 1_500, 1_250))
        XCTAssertEqual(walk.point(at: -10), walk.points[0])
        XCTAssertEqual(walk.point(at: 9_999), walk.points[2])
        for d in [0.0, 1_000, 2_000] {
            XCTAssertEqual(walk.heading(at: d).y, 1, accuracy: 1e-9)
        }
        // Flat ground well below: the camera is behind and above, looking down at the pitch
        // onto a point a little ahead; on a level stretch that's the pitch asked for.
        let level = TrailWalk(points: [SIMD3(0, 0, 1_000), SIMD3(0, 2_000, 1_000)])
        let view = level.camera(at: 1_000, range: 500, pitch: 30) { _ in 0 }
        XCTAssertEqual(view.target.x, 0, accuracy: 1e-9)
        XCTAssertEqual(view.target.y, 1_060, accuracy: 1e-9)
        XCTAssertEqual(view.target.z, 1_000, accuracy: 1e-9)
        let look = view.target - view.eye
        XCTAssertEqual((look * look).sum().squareRoot(), 500, accuracy: 1e-6)
        XCTAssertEqual(atan2(-look.z, look.y) * 180 / .pi, 30, accuracy: 1e-6)
        XCTAssertEqual(look.x, 0, accuracy: 1e-9, "straight along the trail")
    }

    /// Where the trail climbs, the camera looks down more steeply, up to a limit.
    func testCameraLooksDownMoreOnClimbs() {
        func pitch(_ grade: Double) -> Double {
            let walk = TrailWalk(points: [SIMD3(0, 0, 0), SIMD3(0, 2_000, 2_000 * grade)])
            let v = walk.camera(at: 1_000, range: 500, pitch: 30, clearance: 0) { _ in -10_000 }
            let look = v.target - v.eye
            return atan2(-look.z, look.y) * 180 / .pi
        }
        XCTAssertEqual(pitch(0), 30, accuracy: 1e-6)
        XCTAssertEqual(pitch(-0.5), 30, accuracy: 1e-6, "not on the way down")
        XCTAssertEqual(pitch(0.5), 30 + 0.5 * atan(0.5) * 180 / .pi, accuracy: 1e-6)
        XCTAssertEqual(pitch(5), 60, accuracy: 1e-6)
    }

    /// A trail turning a corner heads between its two legs near the corner, and along each
    /// leg away from it.
    func testHeadingRoundsCorners() {
        let walk = TrailWalk(points: [SIMD3(0, 0, 0), SIMD3(0, 1_000, 0), SIMD3(1_000, 1_000, 0)])
        XCTAssertEqual(walk.heading(at: 300), SIMD2(0, 1))
        XCTAssertEqual(walk.heading(at: 1_800), SIMD2(1, 0))
        let corner = walk.heading(at: 1_000)
        XCTAssertGreaterThan(corner.x, 0.5)
        XCTAssertGreaterThan(corner.y, 0.2)
    }

    /// A camera low behind a walker on a level path stays low: the walker stands on the
    /// ground, so the line of sight needn't clear it there.
    func testLowCameraStaysLowOverLevelGround() {
        let walk = TrailWalk(points: [SIMD3(0, 0, 1_000), SIMD3(0, 2_000, 1_000)])
        let view = walk.camera(at: 1_000, range: 400, pitch: 9, clearance: 40) { _ in 1_000 }
        XCTAssertEqual(view.eye.z, 1_000 + 400 * sin(9 * .pi / 180), accuracy: 1e-6)
    }

    /// Tight switchbacks gain height fast as the crow flies but climb gently along the path,
    /// and the camera goes by the path.
    func testCameraGoesByTheGradeAlongTheTrail() {
        // Zigzags 100 m wide, 20 m apart, each leg rising 10 m: a 10% grade.
        var points: [SIMD3<Double>] = []
        for k in 0...20 { points.append(SIMD3(k % 2 == 0 ? 0 : 100, Double(k) * 20, Double(k) * 10)) }
        let walk = TrailWalk(points: points)
        let view = walk.camera(at: 1_000, range: 500, pitch: 10, maxPitch: 60, clearance: 0) { _ in -10_000 }
        let look = view.target - view.eye
        let pitch = atan2(-look.z, (look.x * look.x + look.y * look.y).squareRoot()) * 180 / .pi
        XCTAssertLessThan(pitch, 14, "about 10° + half of a 6° grade, not the 27° the crow sees")
    }

    /// With a hill between the camera and the walker, the camera rises to see over it.
    func testCameraClearsTheGround() {
        let walk = TrailWalk(points: [SIMD3(0, 0, 1_000), SIMD3(0, 2_000, 1_000)])
        let hill: (SIMD2<Double>) -> Double = { p in 900 + 400 * max(0, 1 - abs(p.y - 700) / 150) }
        let view = walk.camera(at: 900, range: 500, pitch: 20, clearance: 40, ground: hill)
        // The line from the eye to the walker (at y = 900) clears the hill, by the clearance
        // tapering to nothing at the walker, give or take what falls between the points
        // checked.
        let y0 = view.eye.y
        XCTAssertLessThan(y0, 550)
        for y in stride(from: y0, through: 880, by: 5) {
            let f = (y - y0) / (900 - y0)
            XCTAssertGreaterThan(view.eye.z * (1 - f) + 1_000 * f, hill(SIMD2(0, y)) + 40 * (1 - f) - 5, "at y = \(y)")
        }
        // Over flat ground well below, the camera stays where the pitch puts it.
        let free = walk.camera(at: 900, range: 500, pitch: 20, clearance: 40) { _ in 900 }
        XCTAssertEqual(free.eye.z, 1_000 + 500 * sin(20 * .pi / 180), accuracy: 1e-6)
    }

    func testRibbonLiesOnTheSlope() {
        // Ground rising 0.5 m per meter to the east; a trail heading north.
        let slope: (SIMD2<Double>) -> Double = { 1_000 + 0.5 * $0.x }
        let band = TrailWalk.ribbon([SIMD2(0, 0), SIMD2(0, 100), SIMD2(0, 200)], width: 10, lift: 2, ground: slope)
        XCTAssertEqual(band.positions.count, 6)
        XCTAssertEqual(band.indices.count, 12)
        XCTAssertEqual(band.positions[0], SIMD3(-5, 0, 1_000 - 2.5 + 2), "left edge is to the west")
        XCTAssertEqual(band.positions[1], SIMD3(5, 0, 1_000 + 2.5 + 2))
        for t in stride(from: 0, to: band.indices.count, by: 3) {
            let a = band.positions[Int(band.indices[t])], b = band.positions[Int(band.indices[t + 1])],
                c = band.positions[Int(band.indices[t + 2])]
            let ab = b - a, ac = c - a
            XCTAssertGreaterThan(ab.x * ac.y - ab.y * ac.x, 0, "faces up")
        }
        XCTAssertTrue(TrailWalk.ribbon([SIMD2(0, 0)], width: 10, lift: 2, ground: slope).positions.isEmpty)
    }
}
