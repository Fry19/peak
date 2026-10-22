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

    /// An eye looking past a ridge at someone on the ground beyond rises to see over it; with
    /// a clear view, or no terrain known, it stays put.
    func testRaisedToSeeOverTheGround() {
        let subject = SIMD3(0.0, 0, 1_000)
        // A ridge 200 m high, halfway between, on ground at the subject's level.
        let ridge: (SIMD2<Double>) -> Double = { p in 1_000 + 200 * max(0, 1 - abs(p.y + 300) / 50) }
        let low = SIMD3(0.0, -600, 1_050)
        let up = TrailWalk.raised(low, toSee: subject, clearance: 15, ground: ridge)
        XCTAssertEqual(up.x, low.x)
        XCTAssertEqual(up.y, low.y)
        XCTAssertGreaterThan(up.z * 0.5 + subject.z * 0.5, 1_200, "the line passes over the crest")
        XCTAssertEqual(TrailWalk.raised(low, toSee: subject, clearance: 15) { _ in 1_000 }, low)
        XCTAssertEqual(TrailWalk.raised(low, toSee: subject, clearance: 15) { _ in .nan }, low)
        // Right on top of the subject, it stays finite.
        let on = TrailWalk.raised(SIMD3(0, 0, 1_003), toSee: SIMD3(0, 0, 1_003), clearance: 15) { _ in 1_000 }
        XCTAssertTrue(on.z.isFinite)
    }

    /// The drawn surface follows the mesh's triangles: on a planar grid it's the plane, and
    /// across a diagonal ridge it keeps the crest the bilinear height rounds off.
    func testSurfaceHeightFollowsTheTriangles() {
        let plane = grid { x, y in 1_000 + 0.2 * x - 0.1 * y }
        XCTAssertEqual(plane.surfaceHeight(at: SIMD2(130, -270)), plane.height(at: SIMD2(130, -270)), accuracy: 1e-6)
        XCTAssertEqual(plane.surfaceHeight(at: SIMD2(500, 500)), 1_050, accuracy: 1e-6, "the corner")
        XCTAssertTrue(plane.surfaceHeight(at: SIMD2(0, 501)).isNaN, "off the grid")
        // A ridge from the south-west to the north-east, along the squares' diagonals.
        let ridge = grid { x, y in 1_000 + 0.1 * (x + y) - 0.8 * abs(x - y) }
        // The middle of the square from (0, 0) to (100, 100): on the crest, 1,010 m.
        XCTAssertEqual(ridge.surfaceHeight(at: SIMD2(50, 50)), 1_010, accuracy: 1e-6)
        XCTAssertLessThan(ridge.height(at: SIMD2(50, 50)), 1_000, "bilinear rounds the crest off")
        // Either side of the crest, on one of the two triangles, each corner matches.
        for (x, y) in [(10.0, 90.0), (90.0, 10.0), (0.0, 100.0), (100.0, 0.0)] {
            let z = ridge.surfaceHeight(at: SIMD2(x, y))
            XCTAssertLessThanOrEqual(z, 1_010 + 1e-6)
            if x.truncatingRemainder(dividingBy: 100) == 0 {
                XCTAssertEqual(z, 1_000 + 0.1 * (x + y) - 0.8 * abs(x - y), accuracy: 1e-6)
            }
        }
        // A square with a corner without terrain isn't drawn.
        var holes = plane.heights
        holes[5 * 11 + 5] = .nan
        let holed = ReliefMap(center: LatLon(46, 8), cellSize: 100, rows: 11, cols: 11, heights: holes)
        XCTAssertTrue(holed.surfaceHeight(at: SIMD2(50, 50)).isNaN)
        XCTAssertTrue(holed.surfaceHeight(at: SIMD2(250, 250)).isFinite)
        // All four corners must exist, including a corner outside the queried triangle.
        for missing in [0, 1, 2, 3] {
            var corners = [Float](repeating: 1_000, count: 4)
            corners[missing] = .nan
            let square = ReliefMap(center: LatLon(46, 8), cellSize: 100, rows: 2, cols: 2, heights: corners)
            XCTAssertTrue(square.surfaceHeight(at: SIMD2(-25, 25)).isNaN)
            XCTAssertTrue(square.surfaceHeight(at: SIMD2(25, -25)).isNaN)
        }
    }

    /// The line over the drawn mesh is checked exactly: never higher than very dense
    /// sampling finds, and as low as it, on rough random terrain.
    func testClearanceMatchesDenseSampling() {
        var noise = UInt64(42)
        func random() -> Double {
            noise = noise &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(noise >> 11) / Double(1 << 53)
        }
        let map = grid(n: 21, cell: 50) { _, _ in 1_000 + 300 * random() }
        for _ in 0..<200 {
            let eye = SIMD3(-480 + 960 * random(), -480 + 960 * random(), 1_000 + 400 * random())
            let target = SIMD3(-480 + 960 * random(), -480 + 960 * random(), 1_000 + 400 * random())
            let exact = map.clearance(from: eye, to: target)
            var dense = Double.infinity
            for k in 0...20_000 {
                let t = Double(k) / 20_000
                let p = eye + (target - eye) * t
                let g = map.surfaceHeight(at: SIMD2(p.x, p.y))
                if g.isFinite { dense = min(dense, p.z - g) }
            }
            XCTAssertLessThanOrEqual(exact, dense + 1e-6)
            XCTAssertEqual(exact, dense, accuracy: 0.5)
        }
    }

    func testClearanceOverARidge() {
        // A crest 200 m high and one square wide, running east–west at y = -300.
        let map = grid(n: 21, cell: 50) { _, y in y == -300 ? 1_200 : 1_000 }
        let target = SIMD3(0.0, 0, 1_100)
        // From 1,050 m, 450 m away, the line is at 1,066.7 m over the 1,200 m crest, a third
        // of the way.
        XCTAssertEqual(map.clearance(from: SIMD3(0, -450, 1_050), to: target), -400.0 / 3, accuracy: 1e-6)
        // From 1,400 m, it's at 1,300 m there: 100 m over it.
        XCTAssertEqual(map.clearance(from: SIMD3(0, -450, 1_400), to: target), 100, accuracy: 1e-6)
        // Drawn lower, the crest is lower; a hole the crest is in leaves it to a sharper mesh.
        XCTAssertEqual(map.clearance(from: SIMD3(0, -450, 1_050), to: target, sink: 150), 50.0 / 3, accuracy: 1e-6)
        let hole = (low: SIMD2(-500.0, -400), high: SIMD2(500.0, -200))
        XCTAssertGreaterThan(map.clearance(from: SIMD3(0, -450, 1_050), to: target, hole: hole), 0)
        XCTAssertEqual(map.clearance(from: SIMD3(0, 0, 3_000), to: target), .infinity, "straight down")
        // Standing on the crest, the target's own ground touches the line there: within
        // `contact` of it, ground up to `contactDepth` over the line is allowed.
        let onCrest = SIMD3(0.0, -300, 1_200)
        XCTAssertEqual(map.clearance(from: SIMD3(0, -450, 1_150), to: onCrest), 0, accuracy: 1e-6, "it touches")
        XCTAssertGreaterThan(map.clearance(from: SIMD3(0, -450, 1_150), to: onCrest, contact: 50, contactDepth: 10), 0)
        // Aimed 5 m into the crest, the allowance takes the contact, not a ridge further out.
        XCTAssertGreaterThan(map.clearance(from: SIMD3(0, -450, 1_150), to: onCrest - SIMD3(0, 0, 5), contact: 50,
                                           contactDepth: 10), 0)
        XCTAssertLessThan(map.clearance(from: SIMD3(0, -450, 1_050), to: target, contact: 50, contactDepth: 10), 0)
    }

    /// A diagonal ridge right beside the target, inside its own grid square's neighbor, is
    /// still in the way: the whole line is checked (a case Codex found against skipping a square).
    func testClearanceSeesARidgeBesideTheTarget() {
        // One 150 m square: south-west, north-west, south-east, north-east at 0, 200, 200, 100.
        let map = ReliefMap(center: LatLon(46, 8), cellSize: 150, rows: 2, cols: 2, heights: [200, 100, 0, 200])
        // From the south-west, down to the north-east corner (100 m): the diagonal ridge
        // (200 m) a square's half-diagonal from the target is in the way, by 57 m.
        let eye = SIMD3(-450.0, -450, 400), target = SIMD3(75.0, 75, 100)
        XCTAssertEqual(map.clearance(from: eye, to: target), 100 + 300.0 / 7 - 200, accuracy: 1e-6)
        XCTAssertLessThan(map.clearance(from: eye, to: target, contact: 150, contactDepth: 10), 0)
    }

    /// A line running exactly along a grid line sees the drawn edge even where the square on
    /// one side of it has no terrain.
    func testClearanceAlongAGridLine() {
        var heights = [Float](repeating: 1_000, count: 9)
        heights[4] = 1_300 // the middle point
        heights[0] = .nan  // drops the north-west square
        let map = ReliefMap(center: LatLon(46, 8), cellSize: 100, rows: 3, cols: 3, heights: heights)
        // Along the middle column from north to south, at 1,100 m: the 1,300 m point is in the way.
        XCTAssertEqual(map.clearance(from: SIMD3(0, 100, 1_100), to: SIMD3(0, -100, 1_100)), -200, accuracy: 1e-6)
        // Along the middle row, west to east.
        XCTAssertEqual(map.clearance(from: SIMD3(-100, 0, 1_100), to: SIMD3(100, 0, 1_100)), -200, accuracy: 1e-6)
    }

    func testSteepestSlope() {
        XCTAssertEqual(grid { x, y in 1_000 + 0.3 * x - 0.4 * y }.steepestSlope, 0.5, accuracy: 1e-6)
        XCTAssertEqual(grid { x, y in 1_000 + 0.1 * (x + y) - 0.8 * abs(x - y) }.steepestSlope,
                       (0.9 * 0.9 + 0.7 * 0.7).squareRoot(), accuracy: 1e-6)
    }

    /// An orbit's eye and its angles round-trip, with azimuth clockwise from north.
    func testOrbitAngles() {
        let subject = SIMD3(100.0, 200, 1_000)
        let east = TrailWalk.orbit(around: subject, azimuth: 90, elevation: 0, distance: 500)
        XCTAssertEqual(east.x, 600, accuracy: 1e-9)
        XCTAssertEqual(east.y, 200, accuracy: 1e-9)
        XCTAssertEqual(east.z, 1_000, accuracy: 1e-9)
        let eye = TrailWalk.orbit(around: subject, azimuth: -135, elevation: 25, distance: 640)
        let back = TrailWalk.orbitAngles(of: eye, around: subject)
        XCTAssertEqual(back.azimuth, -135, accuracy: 1e-9)
        XCTAssertEqual(back.elevation, 25, accuracy: 1e-9)
        XCTAssertEqual(back.distance, 640, accuracy: 1e-9)
    }

    /// Orbiting into a hillside, the camera stops at the lowest angle that clears it, keeping
    /// its distance and direction; already clear, it's left alone; never clear, there's none.
    func testLowestClearElevationOverAHill() throws {
        let subject = SIMD3(0.0, 0, 1_000)
        // Ground rising 1 m per meter to the north of the subject.
        let slope: (SIMD3<Double>) -> Bool = { eye in eye.z >= 1_000 + max(0, eye.y) + 15 }
        let e = try XCTUnwrap(TrailWalk.lowestClearElevation(around: subject, azimuth: 0, distance: 500, from: 10, isClear: slope))
        let eye = TrailWalk.orbit(around: subject, azimuth: 0, elevation: e, distance: 500)
        XCTAssertTrue(slope(eye))
        XCTAssertEqual(eye.z, 1_000 + eye.y + 15, accuracy: 0.2, "on the slope, not above it")
        XCTAssertGreaterThan(e, 45)
        // To the south, the ground falls away: nothing changes.
        XCTAssertEqual(TrailWalk.lowestClearElevation(around: subject, azimuth: 180, distance: 500, from: 10, isClear: slope), 10)
        XCTAssertNil(TrailWalk.lowestClearElevation(around: subject, azimuth: 0, distance: 500, from: 10) { _ in false })
        // Clear only in a band in between (not a landscape): what comes back was still found clear.
        let band: (SIMD3<Double>) -> Bool = { eye in eye.z > 1_200 && eye.z < 1_300 || eye.z > 1_490 }
        let b = try XCTUnwrap(TrailWalk.lowestClearElevation(around: subject, azimuth: 0, distance: 500, from: 0, isClear: band))
        XCTAssertTrue(band(TrailWalk.orbit(around: subject, azimuth: 0, elevation: b, distance: 500)))
    }

    /// The highest ground near a point takes in whole grid squares around it, never less than
    /// the bilinear height, and is NaN off the grid or without terrain.
    func testHighestGroundNearAPoint() {
        // 5 × 5 points 10 m apart, flat at 100 m but for a 300 m spike at row 1, column 3
        // (map x = 10, y = 10) and a hole at the far corner.
        var heights = [Float](repeating: 100, count: 25)
        heights[1 * 5 + 3] = 300
        heights[4 * 5 + 0] = .nan
        let grid = ReliefMap(center: LatLon(46, 7.7), cellSize: 10, rows: 5, cols: 5, heights: heights)
        // The spike is within reach of a point inside a square it's a corner of …
        XCTAssertEqual(grid.highest(within: 0, of: SIMD2(5, 5)), 300)
        XCTAssertGreaterThanOrEqual(grid.highest(within: 0, of: SIMD2(5, 5)), grid.height(at: SIMD2(5, 5)))
        // … and of one a square away once the radius takes it in, but not before.
        XCTAssertEqual(grid.highest(within: 0, of: SIMD2(-15, -15)), 100)
        XCTAssertEqual(grid.highest(within: 25, of: SIMD2(-15, -15)), 300)
        XCTAssertTrue(grid.highest(within: 5, of: SIMD2(500, 0)).isNaN)
        let empty = ReliefMap(center: LatLon(46, 7.7), cellSize: 10, rows: 3, cols: 3, heights: [Float](repeating: .nan, count: 9))
        XCTAssertTrue(empty.highest(within: 50, of: SIMD2(0, 0)).isNaN)
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
